import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

const workflow = readFileSync(new URL('../.github/workflows/release-validation.yml', import.meta.url), 'utf8');
const steps = workflow.split(/^      - /m).slice(1);
const step = (name) => {
  const found = steps.find((value) => value.startsWith(`name: ${name}\n`));
  assert.ok(found, `Missing step: ${name}`);
  return found;
};
const script = (name) => {
  const body = step(name).match(/^        run: \|\n((?: {10}[^\n]*\n|\n)+)/m)?.[1];
  assert.ok(body, `Missing Bash body: ${name}`);
  return body.replace(/^ {10}/gm, '');
};
const groups = [...workflow.matchAll(/^          - group: ([\w-]+)\n([\s\S]*?)(?=^          - group:|^    defaults:)/gm)]
  .map(([, name, body]) => ({
    name,
    jobMinutes: Number(body.match(/job_minutes: (\d+)/)?.[1]),
    testMinutes: Number(body.match(/test_minutes: (\d+)/)?.[1]),
    packages: body.match(/packages: ([^\n]+)/)?.[1] === '|'
      ? [...body.matchAll(/^              (\S+)$/gm)].map((match) => match[1])
      : [body.match(/packages: (\S+)/)?.[1]],
  }));

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'release-validation-contract-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}

test('only manual exact-source validation and preparation-file PRs trigger the lane', () => {
  const triggers = workflow.split('\npermissions:')[0];
  assert.match(triggers, /workflow_dispatch:\n    inputs:\n      target_ref:\n        description: [^\n]+\n        required: true\n        type: string/);
  assert.equal(triggers.match(/^  \w+:/gm)?.length, 2);
  assert.match(triggers, /  pull_request:\n    paths:\n      - '\.github\/workflows\/release-validation\.yml'\n      - 'tests\/release-validation-workflow\.test\.mjs'\n$/);
  const source = step('Validate exact source and hosted environment');
  assert.match(source, /TARGET_REF: \$\{\{ inputs\.target_ref \|\| github\.event\.pull_request\.head\.sha }}/);
  assert.match(source, /\[\[ "\$TARGET_REF" =~ \^\[0-9a-fA-F\]\{40\}\$ \]\] \|\| .*exit 1/);
  assert.match(workflow, /ref: \$\{\{ steps\.source\.outputs\.sha }}/);
  assert.match(workflow, /submodules: recursive\n          fetch-depth: 1\n          persist-credentials: false/);
  const checkoutProof = script('Verify checkout and pinned submodules');
  assert.match(checkoutProof, /actual_sha="\$\(git rev-parse HEAD\)"\n\[\[ "\$actual_sha" == "\$EXPECTED_SHA" \]\]/);
  assert.match(checkoutProof, /git submodule status --recursive/);
  assert.match(checkoutProof, /grep -Eq '\^\[\^ \]'[\s\S]*?exit 1/);
  assert.ok(workflow.indexOf('Verify checkout') < workflow.indexOf('Run complete package suites'));
  for (const entry of steps) {
    const run = entry.match(/^        run: [\s\S]*/m)?.[0] ?? '';
    assert.doesNotMatch(run, /\$\{\{/, 'Actions expressions must not be interpolated into shell code');
  }
});

test('invalid refs cannot become shell commands, refs, or multiline outputs', (t) => {
  const root = fixture(t);
  for (const value of ['', 'main', 'a'.repeat(39), 'a'.repeat(41), 'g'.repeat(40), 'a'.repeat(40) + '\nsha=main', '$(touch injected)', '`touch injected`']) {
    const result = spawnSync('/bin/bash', ['--noprofile', '--norc', '-c', script('Validate exact source and hosted environment')], {
      cwd: root,
      env: { PATH: '/usr/bin:/bin', TARGET_REF: value, GITHUB_OUTPUT: join(root, 'output') },
      encoding: 'utf8',
    });
    assert.equal(result.status, 1, value);
    assert.match(result.stderr, /target_ref must be an exact 40-hex SHA/);
  }
  assert.equal(existsSync(join(root, 'output')), false);
  assert.equal(existsSync(join(root, 'injected')), false);
  for (const value of ['abcdef0123'.repeat(4), 'ABCDEF0123'.repeat(4)]) {
    const result = spawnSync('/bin/bash', ['--noprofile', '--norc', '-c', script('Validate exact source and hosted environment')], {
      cwd: root,
      env: { PATH: '/usr/bin:/bin', TARGET_REF: value, GITHUB_OUTPUT: join(root, 'output') },
      encoding: 'utf8',
    });
    assert.equal(result.status, 1, 'A valid ref must still require the real hosted environment');
    assert.match(result.stderr, /GITHUB_ACTIONS: unbound variable/);
  }
});

test('the complete supplemental inventory is bounded and uses independent hosted jobs', () => {
  assert.deepEqual(groups.map(({ name, packages }) => ({ name, packages })), [
    { name: 'core', packages: ['Core/PeekabooCore'] },
    { name: 'libraries-apps', packages: [
      'Core/PeekabooAutomationKit', 'Core/PeekabooProtocols', 'Core/PeekabooVisualizer',
      'Core/PeekabooUICore', 'Apps/PeekabooInspector', 'Apps/Playground',
    ] },
    { name: 'dependencies', packages: ['Tachikoma', 'AXorcist', 'Commander', 'Swiftdansi', 'TauTUI'] },
  ]);
  assert.equal(workflow.match(/^  [\w-]+:\n    name:/gm)?.length, 1);
  assert.match(workflow, /runs-on: macos-26\n/);
  assert.match(workflow, /fail-fast: false\n      max-parallel: 2/);
  assert.match(workflow, /timeout-minutes: \$\{\{ matrix\.job_minutes }}/);
  assert.match(step('Run complete package suites serially'), /timeout-minutes: \$\{\{ matrix\.test_minutes }}/);
  for (const group of groups) {
    assert.ok(group.testMinutes >= 60 && group.jobMinutes <= 150);
    assert.ok(group.jobMinutes >= group.testMinutes + 10);
    for (const packagePath of group.packages) {
      assert.ok(existsSync(new URL(`../${packagePath}/Package.swift`, import.meta.url)), packagePath);
    }
  }
  assert.doesNotMatch(workflow, /actions\/cache|download-artifact|--parallel\b|--filter\b|--skip\b|--skip-build\b|--disable-swift-testing|--disable-xctest|continue-on-error|--remote\b/);
  assert.match(workflow, /swift test --package-path "\$package" --jobs 4 --no-parallel/);
  assert.match(workflow, /cmp "\$VALIDATION_RESULTS\/workspace-Package\.resolved" \\\n            Apps\/Peekaboo\.xcworkspace\/xcshareddata\/swiftpm\/Package\.resolved/);
  assert.doesNotMatch(workflow, /xcodebuild.*(?:-workspace|-scheme)|build-playground|release-macos-app/);
});

test('permissions, configuration and toolchain preserve the secretless hosted boundary', () => {
  assert.equal(workflow.match(/^\s*permissions:/gm)?.length, 1);
  assert.match(workflow, /\npermissions:\n  contents: read\n\njobs:/);
  assert.doesNotMatch(workflow, /secrets\s*[.\[]|id-token:|write-all|: write\b|self-hosted|INTEGRATION_TESTS|LIVE_PROVIDER_TESTS|ALLOW_UNSAFE|ALLOW_UNSIGNED|API_KEY|ACCESS_TOKEN|SIGN_IDENTITY|codesign|security import/);
  assert.match(workflow, /printf 'PEEKABOO_CONFIG_DIR=%s\/peekaboo-release-validation\\n' "\$RUNNER_TEMP" >> "\$GITHUB_ENV"/);
  assert.match(workflow, /PEEKABOO_CONFIG_DISABLE_MIGRATION: '1'/);
  assert.match(workflow, /PEEKABOO_RUN_LIVE_AGENT_TESTS: '0'/);
  assert.match(workflow, /PEEKABOO_INCLUDE_AUTOMATION_TESTS: 'false'/);
  assert.doesNotMatch(workflow, /^\s*(?:export\s+)?(?:CI|HOME|RUNNER_\w+|GITHUB_\w+)\s*[:=]/m);
  assert.match(workflow, /"\$RUNNER_ENVIRONMENT" == github-hosted/);
  const toolchain = script('Select installed Xcode 26.x and record actual toolchain');
  assert.match(toolchain, /Xcode_26\.6\.app/);
  assert.match(toolchain, /xcodebuild -version/);
  assert.match(toolchain, /xcrun --sdk macosx --show-sdk-version/);
  assert.match(toolchain, /command -v swift\n[ ]*swift --version/);
  assert.doesNotMatch(toolchain, /Xcode_27|xcode-select|xcodes install|curl|wget/);
});

test('toolchain validation drains version output and preserves producer failures', (t) => {
  const root = fixture(t);
  const bin = join(root, 'bin');
  const toolchains = join(root, 'toolchains');
  mkdirSync(bin);
  mkdirSync(join(toolchains, 'Xcode_26.6.app', 'Contents', 'Developer'), { recursive: true });
  // Substitute only fixture-owned installation paths; every tool probe is a fake executable.
  const command = script('Select installed Xcode 26.x and record actual toolchain')
    .replaceAll('/Applications/', `${toolchains}/`);
  const tail = 'version detail\n'.repeat(32768);
  writeFileSync(join(bin, 'xcodebuild'), `#!${process.execPath}
const { appendFileSync, writeFileSync } = require('node:fs');
appendFileSync(process.env.FIXTURE_CALLS, 'started\\n');
writeFileSync(1, process.env.FIXTURE_VERSION + '\\n');
writeFileSync(1, ${JSON.stringify(tail)});
writeFileSync(1, 'Build version 17F113\\n');
appendFileSync(process.env.FIXTURE_CALLS, 'completed\\n');
process.exit(process.env.FIXTURE_FAILURE === 'xcodebuild' ? 23 : 0);
`, { mode: 0o755 });
  for (const name of ['sw_vers', 'xcrun', 'swift']) {
    writeFileSync(join(bin, name), `#!/bin/bash
echo '${name} fixture output'
if [[ "$FIXTURE_FAILURE" == '${name}' ]]; then exit 23; fi
`, { mode: 0o755 });
  }
  const cases = [
    ['Xcode 26.6', '', 0],
    ['Xcode 26.4.1', '', 0],
    ['Xcode 27.0', '', 1],
    ['Xcode 126.6', '', 1],
    ['Xcode 26.6 unexpected suffix', '', 1],
    ...['sw_vers', 'xcodebuild', 'xcrun', 'swift'].map((name) => ['Xcode 26.6', name, 23]),
  ];
  for (const [index, [version, failure, expectedExit]] of cases.entries()) {
    const results = join(root, `results-${index}`);
    mkdirSync(results);
    const calls = join(results, 'calls');
    const outputEnv = join(results, 'output-env');
    const result = spawnSync('/bin/bash', ['--noprofile', '--norc', '-c', command], {
      cwd: root,
      env: {
        PATH: `${bin}:/usr/bin:/bin`, VALIDATION_RESULTS: results, GITHUB_ENV: outputEnv,
        FIXTURE_VERSION: version, FIXTURE_FAILURE: failure, FIXTURE_CALLS: calls,
      },
      encoding: 'utf8', timeout: 10000, maxBuffer: 2 * 1024 * 1024,
    });
    assert.equal(result.status, expectedExit, `${version} / ${failure}: ${result.stderr}`);
    if (failure !== 'sw_vers') {
      assert.equal(readFileSync(calls, 'utf8'), 'started\ncompleted\n', 'Version producer must complete exactly once');
      const record = readFileSync(join(results, 'toolchain.txt'), 'utf8');
      const completeVersion = `${version}\n${tail}Build version 17F113\n`;
      assert.ok(record.includes(completeVersion), 'The complete version/build output must survive in the record');
      assert.ok(result.stdout.includes(completeVersion), 'The complete version/build output must reach the log');
    }
    assert.equal(existsSync(outputEnv), expectedExit === 0, 'Only successful validation can export the toolchain');
  }
});

test('suite failures remain failures, later packages run, and skips remain visible', (t) => {
  const root = fixture(t);
  const bin = join(root, 'bin');
  mkdirSync(bin);
  // This stub is the only Swift executable available to the fixture; no native build or host flags.
  writeFileSync(join(bin, 'swift'), `#!/bin/bash
printf '%s\\n' "$*" >> "$CALLS"
echo 'Test permission fixture skipped: permission unavailable'
if [[ "$3" == "$FAIL_PACKAGE" ]]; then echo 'Test fixture failed'; exit 7; fi
echo 'Test fixture passed'
`, { mode: 0o755 });
  const packages = groups.flatMap((group) => group.packages);
  for (const failedPackage of ['', packages[0], packages[5]]) {
    const results = join(root, `results-${failedPackage.replaceAll('/', '-') || 'success'}`);
    mkdirSync(results);
    const calls = join(results, 'calls');
    const result = spawnSync('/bin/bash', ['--noprofile', '--norc', '-c', script('Run complete package suites serially')], {
      cwd: root,
      env: {
        PATH: `${bin}:/usr/bin:/bin`, PACKAGE_PATHS: packages.join('\n') + '\n',
        VALIDATION_RESULTS: results, CALLS: calls, FAIL_PACKAGE: failedPackage,
      },
      encoding: 'utf8',
    });
    assert.equal(result.status, failedPackage ? 1 : 0, result.stderr);
    assert.deepEqual(readFileSync(calls, 'utf8').trim().split('\n'),
      packages.map((value) => `test --package-path ${value} --jobs 4 --no-parallel`));
    for (const packagePath of packages) {
      const directory = join(results, packagePath.replaceAll('/', '-'));
      const failed = packagePath === failedPackage;
      assert.equal(readFileSync(join(directory, 'status.txt'), 'utf8'), failed ? 'failed\n' : 'passed\n');
      assert.equal(readFileSync(join(directory, 'exit-code.txt'), 'utf8'), failed ? '7\n' : '0\n');
      assert.match(readFileSync(join(directory, 'failures-skips.txt'), 'utf8'), /permission fixture skipped/);
      assert.match(readFileSync(join(directory, 'test.log'), 'utf8'), failed ? /fixture failed/ : /fixture passed/);
    }
  }
  assert.match(step('Summarize all packages and verify canonical workspace lock'), /if: always\(\) && steps\.source\.outcome == 'success'/);
  assert.match(step('Retain per-package evidence'), /if: always\(\) && steps\.source\.outcome == 'success'/);
  assert.match(workflow, /uses: actions\/upload-artifact@v7/);
  assert.match(workflow, /name: release-validation-\$\{\{ matrix\.group }}-\$\{\{ steps\.source\.outputs\.sha }}/);
  assert.match(workflow, /path: \$\{\{ env\.VALIDATION_RESULTS }}/);
});
