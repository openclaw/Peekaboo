import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, mkdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const workflow = readFileSync(new URL('../.github/workflows/release-validation.yml', import.meta.url), 'utf8');
const macosWorkflow = readFileSync(new URL('../.github/workflows/macos-ci.yml', import.meta.url), 'utf8');
const tachikomaJob = macosWorkflow.match(/^  tachikoma:\n[\s\S]*?(?=^  [\w-]+:)/m)?.[0];
const tachikomaStep = () => {
  const found = tachikomaJob?.split(/^      - /m).find((value) => value.startsWith('name: Run Tachikoma package tests\n'));
  assert.ok(found, 'Missing normal macOS CI Tachikoma package step');
  return found;
};
const diagnosticPath = fileURLToPath(new URL('../.github/scripts/core-sigpipe-diagnostic.py', import.meta.url));
const steps = workflow.split(/^      - /m).slice(1);
const step = (name) => {
  const found = steps.find((value) => value.startsWith(`name: ${name}\n`));
  assert.ok(found, `Missing step: ${name}`);
  return found;
};
const scriptFromStep = (name, entry) => {
  const body = entry.match(/^        run: \|\n((?: {10}[^\n]*\n|\n)+)/m)?.[1];
  assert.ok(body, `Missing Bash body: ${name}`);
  return body.replace(/^ {10}/gm, '');
};
const script = (name) => scriptFromStep(name, step(name));
const allGroups = [...workflow.matchAll(/^          - group: ([\w-]+)\n([\s\S]*?)(?=^          - group:|^    defaults:)/gm)]
  .map(([, name, body]) => ({
    name,
    jobMinutes: Number(body.match(/job_minutes: (\d+)/)?.[1]),
    testMinutes: Number(body.match(/test_minutes: (\d+)/)?.[1]),
    packages: body.match(/packages: ([^\n]+)/)?.[1] === '|'
      ? [...body.matchAll(/^              (\S+)$/gm)].map((match) => match[1])
      : body.includes("packages: ''") ? [] : [body.match(/packages: (\S+)/)?.[1]],
  }));
const groups = allGroups.filter(({ name }) => name !== 'full-safe');

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'release-validation-contract-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}

test('normal macOS CI runs the complete serial Tachikoma suite in its existing hosted job', () => {
  const entry = tachikomaStep();
  const command = scriptFromStep('Run Tachikoma package tests', entry);
  assert.match(macosWorkflow, /\npermissions:\n  contents: read\n/);
  assert.equal(macosWorkflow.match(/^\s*permissions:/gm)?.length, 1);
  assert.match(tachikomaJob, /^  tachikoma:\n    name: Tachikoma build & tests\n    runs-on: macos-26\n    needs: peekaboo-cli\n/);
  assert.match(tachikomaJob, /uses: actions\/checkout@v7\n        with:\n          submodules: recursive\n          fetch-depth: 1\n          persist-credentials: false\n/);
  assert.doesNotMatch(macosWorkflow.split('\njobs:\n')[0], /\bsecrets\./,
    'Workflow-wide secrets must not reach the mock suite');
  assert.doesNotMatch(tachikomaJob, /\bsecrets\.|(?:OPENAI|ANTHROPIC)_API_KEY/,
    'Provider credentials must not reach package builds or test discovery');
  assert.doesNotMatch(tachikomaJob, /^\s*(?:ref|if|continue-on-error|timeout-minutes):|self-hosted/m);
  assert.doesNotMatch(tachikomaJob, /^\s*(?:export\s+)?(?:CI|HOME|RUNNER_\w+|GITHUB_\w+)\s*[:=]/m);
  assert.match(tachikomaJob, /name: Build Tachikoma\n        working-directory: Tachikoma\n        run: \|\n          swift build --configuration debug\n/);
  assert.match(macosWorkflow, /\n  mac-apps:\n    name: Build macOS apps \(Peekaboo \+ Inspector\)\n    runs-on: macos-26\n    needs: \[peekaboo-cli, tachikoma\]/);
  assert.match(macosWorkflow, /name: Run Mac package tests \(secretless hosted runner only\)\n        working-directory: Apps\/Mac\n[\s\S]*?        run: swift test --no-parallel\n/);
  assert.match(entry, /working-directory: Tachikoma\n        env:\n          TACHIKOMA_TEST_MODE: "mock"\n          TACHIKOMA_DISABLE_API_TESTS: "true"\n        run:/);
  assert.equal(macosWorkflow.match(/TACHIKOMA_TEST_MODE:/g)?.length, 1);
  assert.equal(macosWorkflow.match(/TACHIKOMA_DISABLE_API_TESTS:/g)?.length, 1);
  assert.match(command, /^set -euo pipefail\n/);
  assert.match(command, /^test_log="\$RUNNER_TEMP\/tachikoma-tests\.log"$/m);
  assert.deepEqual(command.match(/^swift .+$/gm), ['swift test --no-parallel 2>&1 | tee "$test_log"']);
  assert.doesNotMatch(entry, /--filter\b|--skip\b|--skip-build\b|--disable-swift-testing|--disable-xctest|set \+e|\|\| true/);
  assert.doesNotMatch(command, /\|[^\n]*grep/, 'Never inspect a live producer with an early-exiting consumer');
  assert.match(command, /if ! grep -Eq '[^'\n]+' "\$test_log"; then/);
});

test('normal Tachikoma step requires a positive completed summary and preserves producer and log failures', (t) => {
  const root = fixture(t);
  const bin = join(root, 'bin');
  const packageRoot = join(root, 'Tachikoma');
  mkdirSync(bin);
  mkdirSync(packageRoot);
  const entry = tachikomaStep();
  const command = scriptFromStep('Run Tachikoma package tests', entry);
  const mockEnv = Object.fromEntries([...entry.matchAll(/^          (TACHIKOMA_\w+): "([^"\n]+)"$/gm)]
    .map(([, name, value]) => [name, value]));
  const tail = 'fixture output detail\n'.repeat(32768) + 'fixture output end\n';
  writeFileSync(join(bin, 'swift'), `#!${process.execPath}
const { appendFileSync, writeFileSync } = require('node:fs');
if (process.argv.slice(2).join(' ') !== 'test --no-parallel' ||
    process.cwd() !== process.env.FIXTURE_PACKAGE ||
    process.env.TACHIKOMA_TEST_MODE !== 'mock' ||
    process.env.TACHIKOMA_DISABLE_API_TESTS !== 'true') process.exit(99);
appendFileSync(process.env.FIXTURE_CALLS, 'swift started\\n');
writeFileSync(1, process.env.FIXTURE_SUMMARY);
writeFileSync(1, ${JSON.stringify(tail)});
writeFileSync(2, 'fixture stderr end\\n');
appendFileSync(process.env.FIXTURE_CALLS, 'swift completed\\n');
process.exit(Number(process.env.FIXTURE_SWIFT_EXIT));
`, { mode: 0o755 });
  writeFileSync(join(bin, 'tee'), `#!/bin/bash
/usr/bin/tee "$@" || exit $?
printf 'tee completed\\n' >> "$FIXTURE_CALLS"
exit "$FIXTURE_TEE_EXIT"
`, { mode: 0o755 });
  const positive = '✔ Test run with 17 tests in 3 suites passed after 0.123 seconds.\n';
  const cases = [
    ['positive', positive, 0, 0, 0],
    ['single test', '✔ Test run with 1 test in 1 suite passed after 0.001 seconds.\n', 0, 0, 0],
    ['without suites', '✔ Test run with 2 tests passed after 0.001 seconds.\n', 0, 0, 0],
    ['zero', '✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.\n', 0, 0, 1],
    ['missing', '', 0, 0, 1],
    ['XCTest only', 'Executed 17 tests, with 0 failures (0 unexpected) in 0.123 seconds\n', 0, 0, 1],
    ['invalid count', '✔ Test run with -1 tests in 3 suites passed after 0.001 seconds.\n', 0, 0, 1],
    ['failed summary', '✘ Test run with 17 tests in 3 suites failed after 0.123 seconds.\n', 0, 0, 1],
    ['Swift failure after positive', positive, 7, 0, 7],
    ['writer failure after positive', positive, 0, 23, 23],
    ['both failures after positive', positive, 7, 23, 23],
  ];
  for (const [index, [name, summary, swiftExit, teeExit, expectedExit]] of cases.entries()) {
    const runnerTemp = join(root, `runner temp ${index}`);
    mkdirSync(runnerTemp);
    const calls = join(runnerTemp, 'calls');
    const log = join(runnerTemp, 'tachikoma-tests.log');
    writeFileSync(log, positive);
    const result = spawnSync('/bin/bash', ['--noprofile', '--norc', '-e', '-c', command], {
      cwd: packageRoot,
      env: { PATH: `${bin}:/usr/bin:/bin`, RUNNER_TEMP: runnerTemp, ...mockEnv,
        FIXTURE_PACKAGE: realpathSync(packageRoot), FIXTURE_CALLS: calls, FIXTURE_SUMMARY: summary,
        FIXTURE_SWIFT_EXIT: String(swiftExit), FIXTURE_TEE_EXIT: String(teeExit) },
      // Only a fake-process watchdog; no Swift runtime or hosted identity is used here.
      encoding: 'utf8', timeout: 30000, maxBuffer: 2 * 1024 * 1024,
    });
    assert.equal(result.error?.code ?? null, null, `${name}: fixture launch must complete`);
    assert.equal(result.signal, null, `${name}: fixture must not terminate by signal`);
    assert.equal(result.status, expectedExit, `${name}: ${result.stderr}`);
    assert.equal(result.stderr, '', name);
    assert.equal(readFileSync(calls, 'utf8'), 'swift started\nswift completed\ntee completed\n', name);
    const completeOutput = summary + tail + 'fixture stderr end\n';
    assert.equal(readFileSync(log, 'utf8'), completeOutput, `${name}: all output must drain into the retained log`);
    if (expectedExit === 1) {
      assert.ok(result.stdout.startsWith(completeOutput), name);
      assert.match(result.stdout.slice(completeOutput.length), /::error::Tachikoma produced no positive Swift Testing test count/);
      assert.ok(result.stdout.slice(completeOutput.length).includes(log), 'Diagnostic must locate the completed log');
    } else {
      assert.equal(result.stdout, completeOutput, `${name}: pipeline failure must stop before summary inspection`);
    }
  }
});

test('only manual exact-source validation and preparation-file PRs trigger the lane', () => {
  const triggers = workflow.split('\npermissions:')[0];
  assert.match(triggers, /workflow_dispatch:\n    inputs:\n      target_ref:\n        description: [^\n]+\n        required: true\n        type: string/);
  assert.equal(triggers.match(/^  \w+:/gm)?.length, 2);
  assert.match(triggers, /  pull_request:\n    paths:\n      - '\.github\/workflows\/release-validation\.yml'\n      - '\.github\/workflows\/macos-ci\.yml'\n      - '\.github\/scripts\/core-sigpipe-diagnostic\.py'\n      - 'tests\/release-validation-workflow\.test\.mjs'\n$/);
  const source = step('Validate exact source and hosted environment');
  assert.match(source, /SOURCE_EVENT: \$\{\{ github\.event_name }}/);
  assert.match(source, /TARGET_REF: \$\{\{ inputs\.target_ref }}/);
  assert.match(source, /WORKFLOW_COMMIT: \$\{\{ github\.sha }}/);
  assert.match(source, /PR_HEAD_SHA: \$\{\{ github\.event\.pull_request\.head\.sha }}/);
  assert.match(source, /\[\[ "\$TARGET_REF" =~ \^\[0-9a-fA-F\]\{40\}\$ \]\] \|\| .*exit 1/);
  const checkouts = steps.filter((entry) => /uses: actions\/checkout@/.test(entry));
  assert.deepEqual(checkouts.map((entry) => [
    entry.match(/^        if: (.+)$/m)?.[1], entry.match(/^          ref: (.+)$/m)?.[1],
  ]), [
    ["github.event_name == 'workflow_dispatch'", '${{ github.sha }}'],
    ["github.event_name == 'pull_request'", '${{ github.event.pull_request.head.sha }}'],
  ]);
  for (const checkout of checkouts) {
    assert.match(checkout, /submodules: recursive\n          fetch-depth: 1\n          persist-credentials: false/);
    assert.doesNotMatch(checkout, /inputs\.|steps\.|\|\|/, 'Checkout authority must be a direct event-specific GitHub ref');
    assert.ok(steps.indexOf(checkout) > steps.indexOf(source), 'Source assertion must precede checkout');
  }
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
      env: { PATH: '/usr/bin:/bin', SOURCE_EVENT: 'workflow_dispatch', TARGET_REF: value,
        WORKFLOW_COMMIT: 'abcdef0123'.repeat(4), GITHUB_OUTPUT: join(root, 'output') },
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
      env: { PATH: '/usr/bin:/bin', SOURCE_EVENT: 'workflow_dispatch', TARGET_REF: value,
        WORKFLOW_COMMIT: 'abcdef0123'.repeat(4), GITHUB_OUTPUT: join(root, 'output') },
      encoding: 'utf8',
    });
    assert.equal(result.status, 1, 'A valid ref must still require the real hosted environment');
    assert.match(result.stderr, /GITHUB_ACTIONS: unbound variable/);
  }
});

test('manual expected SHA cannot select code and PR source ignores manual inputs', (t) => {
  const root = fixture(t);
  const source = script('Validate exact source and hosted environment');
  const hostGuard = '[[ "$GITHUB_ACTIONS"';
  assert.equal(source.split(hostGuard).length, 2);
  // Exercise the actual decision block without supplying any synthetic hosted identity.
  const decision = source.slice(0, source.indexOf(hostGuard)) + 'printf "%s\\n" "$source_sha"\n';
  const workflowSHA = 'abcdef0123'.repeat(4);
  const prSHA = '123456abcd'.repeat(4);
  const evaluate = (overrides, throughHost = false) => spawnSync('/bin/bash', [
    '--noprofile', '--norc', '-c', throughHost ? source : decision,
  ], {
    cwd: root,
    env: { PATH: '/usr/bin:/bin', SOURCE_EVENT: 'workflow_dispatch', TARGET_REF: workflowSHA,
      WORKFLOW_COMMIT: workflowSHA, PR_HEAD_SHA: prSHA, ...overrides },
    encoding: 'utf8',
  });
  for (const value of [workflowSHA, workflowSHA.toUpperCase()]) {
    const accepted = evaluate({ TARGET_REF: value });
    assert.equal(accepted.status, 0, accepted.stderr);
    assert.equal(accepted.stdout, workflowSHA + '\n');
    const guarded = evaluate({ TARGET_REF: value }, true);
    assert.equal(guarded.status, 1);
    assert.match(guarded.stderr, /GITHUB_ACTIONS: unbound variable/);
  }
  for (const overrides of [{ TARGET_REF: prSHA }, { WORKFLOW_COMMIT: prSHA }]) {
    const rejected = evaluate(overrides, true);
    assert.equal(rejected.status, 1);
    assert.match(rejected.stderr, /target_ref must match the selected workflow revision/);
    assert.doesNotMatch(rejected.stderr, /GITHUB_ACTIONS/);
    assert.equal(rejected.stdout, '');
  }
  for (const input of ['', workflowSHA, '$(touch injected)', 'not-a-sha']) {
    const accepted = evaluate({ SOURCE_EVENT: 'pull_request', TARGET_REF: input });
    assert.equal(accepted.status, 0, accepted.stderr);
    assert.equal(accepted.stdout, prSHA + '\n');
  }
  const prGuard = evaluate({ SOURCE_EVENT: 'pull_request', TARGET_REF: workflowSHA }, true);
  assert.equal(prGuard.status, 1);
  assert.match(prGuard.stderr, /GITHUB_ACTIONS: unbound variable/);
  assert.equal(evaluate({ SOURCE_EVENT: 'pull_request', PR_HEAD_SHA: 'main' }).status, 1);
  assert.equal(evaluate({ WORKFLOW_COMMIT: 'main' }).status, 1);
  assert.equal(evaluate({ SOURCE_EVENT: 'push' }).status, 1);
  assert.equal(existsSync(join(root, 'injected')), false);
});

test('the complete supplemental inventory is bounded and uses independent hosted jobs', () => {
  assert.deepEqual(allGroups.map(({ name }) => name), ['core', 'libraries-apps', 'dependencies', 'full-safe']);
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

test('full safe lane shares source gates and runs only the complete pinned command', () => {
  assert.deepEqual(allGroups.find(({ name }) => name === 'full-safe'), {
    name: 'full-safe', jobMinutes: 180, testMinutes: 150, packages: [],
  });
  const safe = step('Run full repository safe suite');
  const install = step('Record safe-suite runtime and frozen dependency install');
  const pnpm = step('Set up repository-pinned pnpm');
  const tools = step('Install safe-suite system tools');
  assert.match(tools, /if: matrix.group == 'full-safe'\n        timeout-minutes: 10/);
  assert.match(tools, /HOMEBREW_NO_AUTO_UPDATE: '1'/);
  assert.match(script('Install safe-suite system tools'), /^brew install ripgrep uv 2>&1 \| tee /m);
  assert.match(script('Install safe-suite system tools'), /^rg --version \| tee /m);
  assert.match(script('Install safe-suite system tools'), /^uv --version \| tee /m);
  assert.deepEqual(steps.filter((entry) => /\bbrew install\b|\brg --version\b|\buv --version\b/.test(entry)), [tools]);
  assert.match(safe, /if: matrix.group == 'full-safe'\n        id: safe\n        timeout-minutes: \$\{\{ matrix.test_minutes }}/);
  assert.match(install, /if: matrix.group == 'full-safe'\n        id: safe-install\n        timeout-minutes: 10/);
  assert.match(pnpm, /if: matrix.group == 'full-safe'\n        timeout-minutes: 5\n        uses: pnpm\/action-setup@v6\.0\.9/);
  assert.match(pnpm, /run_install: false\n          cache: false/);
  assert.doesNotMatch(pnpm, /\n\s+version:/, 'pnpm version must come from package.json');
  assert.match(workflow, /uses: actions\/setup-node@v6\n        with:\n          node-version: '24'\n          package-manager-cache: false/);
  assert.match(script('Record safe-suite runtime and frozen dependency install'), /^pnpm install --frozen-lockfile 2>&1 \| tee /m);
  assert.match(script('Run full repository safe suite'), /^pnpm run test:safe 2>&1 \| tee /m);
  assert.equal(script('Run full repository safe suite').match(/^pnpm /gm)?.length, 1);
  assert.doesNotMatch(safe, /env:|swift|--filter|--skip|retry|set \+e|timeout /);
  const sharedEnv = workflow.split('\n    env:\n')[1].split('\n    steps:')[0];
  assert.doesNotMatch(sharedEnv + install + safe, /RUN_LOCAL_TESTS|RUN_AUTOMATION_TESTS|PEEKABOO_INCLUDE_AUTOMATION_TESTS|PEEKABOO_INCLUDE_AMBIENT_STATE_TESTS/);
  for (const name of ['Run complete package suites serially', 'Diagnose Core SIGPIPE without changing the failed result']) {
    assert.match(step(name), /PEEKABOO_INCLUDE_AUTOMATION_TESTS: 'false'\n          RUN_AUTOMATION_TESTS: 'false'\n          RUN_LOCAL_TESTS: 'false'/);
  }
  assert.match(step('Run complete package suites serially'), /if: matrix.group != 'full-safe'/);
  const ordered = ['Validate exact source and hosted environment', 'Verify checkout and pinned submodules',
    'Select installed Xcode 26.x and record actual toolchain', 'Install safe-suite system tools',
    'Set up repository-pinned pnpm',
    'Record safe-suite runtime and frozen dependency install', 'Run full repository safe suite'];
  assert.deepEqual(ordered.map((name) => steps.indexOf(step(name))),
    ordered.map((name) => steps.indexOf(step(name))).sort((a, b) => a - b));
  assert.match(step('Summarize full safe suite and verify canonical workspace lock'),
    /if: always\(\) && steps.source.outcome == 'success' && matrix.group == 'full-safe'/);
  assert.match(step('Retain per-package evidence'), /if: always\(\) && steps.source.outcome == 'success'/);
});

test('safe system tools retain complete versions and failures before frozen install and safe execution', (t) => {
  const root = fixture(t);
  const bin = join(root, 'bin');
  mkdirSync(bin);
  writeFileSync(join(bin, 'brew'), `#!/bin/bash
printf '%s\\n' "$*" >> "$FIXTURE_CALLS"
[[ "$*" == 'install ripgrep uv' && "$HOMEBREW_NO_AUTO_UPDATE" == 1 ]] || exit 99
echo 'fixture system tool install'
exit "$FIXTURE_INSTALL_EXIT"
`, { mode: 0o755 });
  const versions = { rg: 'ripgrep fixture version\n', uv: 'uv fixture version\n' };
  for (const name of ['rg', 'uv']) {
    versions[name] += `${name} version detail\n`.repeat(8192) + `${name} version end\n`;
    writeFileSync(join(root, `${name}-expected.txt`), versions[name]);
    writeFileSync(join(bin, name), `#!${process.execPath}
const { appendFileSync, writeFileSync } = require('node:fs');
if (process.argv.slice(2).join(' ') !== '--version') process.exit(99);
appendFileSync(process.env.FIXTURE_CALLS, '${name} --version\\n');
writeFileSync(1, ${JSON.stringify(versions[name])});
appendFileSync(process.env.FIXTURE_CALLS, '${name} completed\\n');
process.exit(Number(process.env.FIXTURE_${name.toUpperCase()}_EXIT));
`, { mode: 0o755 });
  }
  symlinkSync(process.execPath, join(bin, 'node'));
  writeFileSync(join(root, 'package.json'), JSON.stringify({ packageManager: 'pnpm@11.21.0+sha512.1234',
    scripts: { 'test:safe': 'fixture complete safe definition' } }));
  writeFileSync(join(root, 'pnpm-lock.yaml'), 'fixture lock');
  writeFileSync(join(bin, 'pnpm'), `#!/bin/bash
set -euo pipefail
cmp rg-expected.txt "$VALIDATION_RESULTS/full-safe/ripgrep-version.txt"
cmp uv-expected.txt "$VALIDATION_RESULTS/full-safe/uv-version.txt"
printf 'pnpm %s\\n' "$*" >> "$FIXTURE_CALLS"
case "$*" in
  --version) echo '11.21.0' ;;
  'install --frozen-lockfile') echo 'fixture frozen install output' ;;
  'run test:safe') echo 'fixture safe output' ;;
  *) exit 99 ;;
esac
`, { mode: 0o755 });
  writeFileSync(join(bin, 'tee'), `#!/bin/bash
/usr/bin/tee "$@" || exit $?
if [[ "$1" == */"$FIXTURE_TEE_FAILURE" ]]; then exit 23; fi
`, { mode: 0o755 });
  const cases = [[0, 0, 0, ''], [17, 0, 0, ''], [0, 29, 0, ''], [0, 0, 31, ''],
    ...['system-tools-install.log', 'ripgrep-version.txt', 'uv-version.txt'].map((file) => [0, 0, 0, file])];
  for (const [index, [installExit, rgExit, uvExit, teeFailure]] of cases.entries()) {
    const results = join(root, `tools-${index}`);
    const calls = results + '-calls';
    const result = spawnSync('/bin/bash', ['--noprofile', '--norc', '-c',
      'set -euo pipefail\nfor command; do /bin/bash --noprofile --norc -c "$command"; done', 'fixture',
      ...['Install safe-suite system tools', 'Record safe-suite runtime and frozen dependency install',
        'Run full repository safe suite'].map(script)], {
      cwd: root, env: { PATH: `${bin}:/usr/bin:/bin`, VALIDATION_RESULTS: results,
        HOMEBREW_NO_AUTO_UPDATE: '1', FIXTURE_CALLS: calls, FIXTURE_INSTALL_EXIT: String(installExit),
        FIXTURE_RG_EXIT: String(rgExit), FIXTURE_UV_EXIT: String(uvExit), FIXTURE_TEE_FAILURE: teeFailure },
      // Only a fake subprocess watchdog; every tool and pnpm command is a fixture.
      encoding: 'utf8', timeout: 30000, maxBuffer: 2 * 1024 * 1024,
    });
    assert.equal(result.error?.code ?? null, null, 'Fixture process launch must complete');
    assert.equal(result.signal, null, 'Fixture must not terminate by signal');
    const expectedExit = installExit || rgExit || uvExit || (teeFailure ? 23 : 0);
    assert.equal(result.status, expectedExit, result.stderr);
    assert.equal(result.stderr, '');
    let expectedCalls = 'install ripgrep uv\n';
    let expectedOutput = 'fixture system tool install\n';
    assert.equal(readFileSync(join(results, 'full-safe/system-tools-install.log'), 'utf8'), expectedOutput);
    let stopped = installExit !== 0 || teeFailure === 'system-tools-install.log';
    for (const [name, file, exit] of [['rg', 'ripgrep-version.txt', rgExit], ['uv', 'uv-version.txt', uvExit]]) {
      const record = join(results, 'full-safe', file);
      assert.equal(existsSync(record), !stopped);
      if (!stopped) {
        assert.equal(readFileSync(record, 'utf8'), versions[name]);
        expectedCalls += `${name} --version\n${name} completed\n`;
        expectedOutput += versions[name];
        stopped = exit !== 0 || teeFailure === file;
      }
    }
    if (expectedExit === 0) {
      expectedCalls += 'pnpm --version\npnpm install --frozen-lockfile\npnpm run test:safe\n';
      expectedOutput += `Node: ${process.version}\npnpm: 11.21.0\npackageManager: pnpm@11.21.0+sha512.1234\n`;
      expectedOutput += 'fixture frozen install output\nfixture safe output\n';
    }
    assert.equal(readFileSync(calls, 'utf8'), expectedCalls);
    assert.equal(result.stdout, expectedOutput, 'Complete producer output must reach the log before later stages');
    assert.equal(existsSync(join(results, 'full-safe/install-exit-code.txt')), expectedExit === 0);
    assert.equal(existsSync(join(results, 'full-safe/exit-code.txt')), expectedExit === 0);
  }
});

test('full safe command preserves exact failures, all emitted logs and incomplete evidence', (t) => {
  const root = fixture(t);
  const bin = join(root, 'bin');
  mkdirSync(bin);
  writeFileSync(join(bin, 'pnpm'), `#!/bin/bash
printf '%s\\n' "$*" >> "$FIXTURE_CALLS"
[[ "$*" == 'run test:safe' ]] || exit 99
echo 'stage one: fixture passed'
echo 'stage two: permission fixture skipped' >&2
echo 'stage three: fixture failure or completion'
exit "$FIXTURE_EXIT"
`, { mode: 0o755 });
  writeFileSync(join(bin, 'tee'), `#!/bin/bash
/usr/bin/tee "$@" || exit $?
exit "$FIXTURE_TEE_EXIT"
`, { mode: 0o755 });
  for (const [commandExit, teeExit] of [[0, 0], [7, 0], [0, 23], [7, 23]]) {
    const results = join(root, `results-${commandExit}-${teeExit}`);
    const calls = join(root, `calls-${commandExit}-${teeExit}`);
    const result = spawnSync('/bin/bash', ['--noprofile', '--norc', '-c', script('Run full repository safe suite')], {
      cwd: root, env: { PATH: `${bin}:/usr/bin:/bin`, VALIDATION_RESULTS: results,
        FIXTURE_CALLS: calls, FIXTURE_EXIT: String(commandExit), FIXTURE_TEE_EXIT: String(teeExit) },
      // Fake subprocess startup watchdog only; the hosted step keeps its own minute deadline.
      encoding: 'utf8', timeout: 30000,
    });
    assert.equal(result.error, undefined);
    assert.equal(result.status, commandExit || teeExit, result.stderr);
    assert.equal(readFileSync(calls, 'utf8'), 'run test:safe\n', 'Exactly one full command, no retries or stages');
    assert.equal(readFileSync(join(results, 'full-safe/command.txt'), 'utf8'), 'pnpm run test:safe\n');
    assert.equal(readFileSync(join(results, 'full-safe/exit-code.txt'), 'utf8'), `${commandExit}\n`);
    assert.equal(readFileSync(join(results, 'full-safe/log-exit-code.txt'), 'utf8'), `${teeExit}\n`);
    assert.equal(readFileSync(join(results, 'full-safe/status.txt'), 'utf8'), commandExit || teeExit ? 'failed\n' : 'passed\n');
    assert.equal(readFileSync(join(results, 'full-safe/test.log'), 'utf8'), result.stdout);
    assert.match(readFileSync(join(results, 'full-safe/failures-skips.txt'), 'utf8'), /permission fixture skipped\nstage three: fixture failure/);
  }
  const calls = join(root, 'forbidden-calls');
  for (const target of ['a'.repeat(40), 'b'.repeat(40)]) {
    const guarded = spawnSync('/bin/bash', ['--noprofile', '--norc', '-c',
      script('Validate exact source and hosted environment') + script('Run full repository safe suite')], {
      cwd: root, env: { PATH: `${bin}:/usr/bin:/bin`, SOURCE_EVENT: 'workflow_dispatch',
        TARGET_REF: target, WORKFLOW_COMMIT: 'a'.repeat(40), FIXTURE_CALLS: calls },
      encoding: 'utf8', timeout: 30000,
    });
    assert.equal(guarded.status, 1);
    assert.match(guarded.stderr, /GITHUB_ACTIONS: unbound variable|target_ref must match/);
  }
  assert.equal(existsSync(calls), false, 'Neither mismatched source nor absent hosted identity may execute pnpm');

  const lock = join(root, 'Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved');
  mkdirSync(join(lock, '..'), { recursive: true });
  writeFileSync(lock, 'fixture lock');
  for (const state of ['not-run', 'running', 'failed']) {
    const results = join(root, `summary-${state}`);
    mkdirSync(join(results, 'full-safe'), { recursive: true });
    writeFileSync(join(results, 'workspace-Package.resolved'), 'fixture lock');
    if (state !== 'not-run') writeFileSync(join(results, 'full-safe/status.txt'), state + '\n');
    writeFileSync(join(results, 'full-safe/test.log'), 'original partial output\nfixture skipped\n');
    const result = spawnSync('/bin/bash', ['--noprofile', '--norc', '-c',
      script('Summarize full safe suite and verify canonical workspace lock')], {
      cwd: root, env: { PATH: '/usr/bin:/bin', VALIDATION_RESULTS: results,
        GITHUB_STEP_SUMMARY: join(results, 'step-summary'), SAFE_STEP_OUTCOME: 'failure', INSTALL_STEP_OUTCOME: 'success' },
      encoding: 'utf8', timeout: 30000,
    });
    assert.equal(result.status, 0, result.stderr);
    const summary = readFileSync(join(results, 'summary.md'), 'utf8');
    assert.ok(summary.includes(`${state}; command exit: unavailable; step: failure`));
    assert.match(summary, /incomplete, never a pass/);
    assert.match(summary, /not live proof/);
    assert.equal(readFileSync(join(results, 'full-safe/test.log'), 'utf8'), 'original partial output\nfixture skipped\n');
    assert.equal(readFileSync(join(results, 'full-safe/failures-skips.txt'), 'utf8'), 'fixture skipped\n');
  }
});

test('safe dependency install enforces the repository pnpm pin and frozen lock', (t) => {
  const root = fixture(t);
  const bin = join(root, 'bin');
  mkdirSync(bin);
  symlinkSync(process.execPath, join(bin, 'node'));
  writeFileSync(join(root, 'package.json'), JSON.stringify({ packageManager: 'pnpm@11.21.0+sha512.1234',
    scripts: { 'test:safe': 'fixture complete safe definition' } }));
  writeFileSync(join(root, 'pnpm-lock.yaml'), 'fixture lock');
  writeFileSync(join(bin, 'pnpm'), `#!/bin/bash
if [[ "$*" == '--version' ]]; then echo "$FIXTURE_VERSION"; exit 0; fi
printf '%s\\n' "$*" >> "$FIXTURE_CALLS"
[[ "$*" == 'install --frozen-lockfile' ]] || exit 99
echo 'fixture frozen install output'
exit "$FIXTURE_EXIT"
`, { mode: 0o755 });
  for (const [version, installExit] of [['11.21.0', 0], ['11.21.0', 17], ['11.20.0', 0]]) {
    const results = join(root, `install-${version}-${installExit}`);
    const calls = results + '-calls';
    const result = spawnSync('/bin/bash', ['--noprofile', '--norc', '-c',
      script('Record safe-suite runtime and frozen dependency install')], {
      cwd: root, env: { PATH: `${bin}:/usr/bin:/bin`, VALIDATION_RESULTS: results,
        FIXTURE_CALLS: calls, FIXTURE_VERSION: version, FIXTURE_EXIT: String(installExit) },
      encoding: 'utf8', timeout: 30000,
    });
    assert.equal(result.error, undefined);
    assert.equal(result.status, version === '11.21.0' ? installExit : 1, result.stderr);
    assert.match(readFileSync(join(results, 'full-safe/runtime.txt'), 'utf8'), /Node: v\d+/);
    assert.equal(readFileSync(join(results, 'full-safe/pnpm-lock.yaml'), 'utf8'), 'fixture lock');
    if (version === '11.21.0') {
      assert.equal(readFileSync(calls, 'utf8'), 'install --frozen-lockfile\n');
      assert.equal(readFileSync(join(results, 'full-safe/install-exit-code.txt'), 'utf8'), `${installExit}\n`);
      assert.equal(readFileSync(join(results, 'full-safe/install-status.txt'), 'utf8'), installExit ? 'failed\n' : 'passed\n');
      assert.equal(readFileSync(join(results, 'full-safe/test-safe-definition.txt'), 'utf8'), 'fixture complete safe definition\n');
    } else {
      assert.match(result.stderr, /pnpm must match the repository pin/);
      assert.equal(existsSync(calls), false, 'Wrong pnpm must fail before install');
    }
  }
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
      // Only a fixture-process watchdog; native builds can delay local tool launches.
      encoding: 'utf8', timeout: 30000, maxBuffer: 2 * 1024 * 1024,
    });
    assert.equal(result.error?.code ?? null, null, `${version} / ${failure}: fixture launch error`);
    assert.equal(result.signal, null, `${version} / ${failure}: fixture terminated by signal`);
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

test('Core signal diagnostic is bounded and cannot replace the fatal full-suite result', () => {
  const diagnostic = step('Diagnose Core SIGPIPE without changing the failed result');
  assert.match(diagnostic, /if: failure\(\) && matrix\.group == 'core' && steps\.suites\.outcome == 'failure'/);
  assert.match(diagnostic, /timeout-minutes: 10/);
  assert.match(step('Run complete package suites serially'), /id: suites/);
  assert.match(script('Run complete package suites serially'), /exit "\$failed"/);
  assert.ok(workflow.indexOf('Diagnose Core SIGPIPE') > workflow.indexOf('exit "$failed"'));
  assert.ok(workflow.indexOf('Diagnose Core SIGPIPE') < workflow.indexOf('Retain per-package evidence'));
  assert.deepEqual(groups.map(({ jobMinutes, testMinutes }) => [jobMinutes, testMinutes]), [[120, 90], [140, 130], [100, 90]]);
  const source = readFileSync(diagnosticPath, 'utf8');
  assert.match(source, /min\(480, max\(1, deadline - time\.monotonic\(\) - 30\)\)/);
  assert.match(source, /deadline = time\.monotonic\(\) \+ 540/);
  assert.match(source, /child\.wait\(timeout=max\(1, deadline - time\.monotonic\(\)\)\)/);
  assert.match(source, /resource\.setrlimit\(resource\.RLIMIT_CORE, \(0, 0\)\)/);
  assert.match(source, /GetFunctionName\(\)/);
  assert.doesNotMatch(source, /GetVariables\(|GetRegisters\(|ReadMemory\(|EvaluateExpression\(|GetDescription\(|thread backtrace|frame variable|register read|process save-core|signal\.signal\(/);
  assert.match(source, /os\.environ\.get\("RUNNER_ENVIRONMENT"\) == "github-hosted"/);
});

test('diagnostic gating, symbol-only capture and helper launch use hermetic fixtures', (t) => {
  const root = fixture(t);
  const result = spawnSync('python3', ['-c', String.raw`
import importlib.util, json, os, sys
from pathlib import Path
from types import SimpleNamespace as NS
spec = importlib.util.spec_from_file_location('diagnostic', sys.argv[1])
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
root = Path.cwd()
results = root / 'results'
suite = results / 'Core-PeekabooCore'
suite.mkdir(parents=True)
status = suite / 'status.txt'
log = suite / 'test.log'
status.write_text('failed\n')
for marker, expected in [('ordinary assertion failure', False), ('exited with unexpected signal code 130', False),
                         ("error: Process 'other-helper' exited with unexpected signal code 13\n", False),
                         ("buffered prefix error: Process '/fixture/swiftpm-testing-helper --test-bundle-path /fixture/tests' exited with unexpected signal code 13\n", True)]:
    log.write_text(marker)
    assert d.eligible('core', 'failure', results) == expected
    assert not d.eligible('dependencies', 'failure', results)
    assert not d.eligible('core', 'success', results)
status.write_text('passed\n')
assert not d.eligible('core', 'failure', results)
status.write_text('failed\n')
original = (status.read_bytes(), log.read_bytes())
os.environ.update(VALIDATION_RESULTS=str(results), DIAGNOSTIC_GROUP='core', ORIGINAL_SUITE_OUTCOME='failure')
try:
    d.main()
    raise AssertionError('personal host must be refused')
except RuntimeError as error:
    assert 'genuine hosted' in str(error)

class Error:
    def Fail(self): return False
    def Success(self): return True
    def Succeeded(self): return True
class Frame:
    def GetFunctionName(self): return 'Fixture.closedPeerWrite()'
    def GetLineEntry(self): return self
    def IsValid(self): return True
    def GetFileSpec(self): return self
    def GetFilename(self): return 'Fixture.swift'
    def GetLine(self): return 42
class Thread(list):
    def __init__(self, process): super().__init__([Frame()]); self.process = process
    def GetStopReason(self): return self.process.reason
    def GetStopReasonDataCount(self): return 1 if self.process.reason == 99 else 2
    def GetStopReasonDataAtIndex(self, index):
        assert self.process.reason == 99 and index == 0, 'Do not read exception payloads or other stop data'
        return self.process.signal
    def GetNumFrames(self): return len(self)
class Process(list):
    def __init__(self, scenario):
        super().__init__([Thread(self), Thread(self)])
        self.state, self.scenario, self.killed = 1, scenario, False
        self.stop_id, self.reason, self.signal = 7, 101, None
        self.observations, self.continues = iter(()), 0
    def IsValid(self): return True
    def GetState(self):
        observation = next(self.observations, None)
        if observation is not None: self.state, self.stop_id, self.reason, self.signal = observation
        return self.state
    def GetStopID(self): return self.stop_id
    def GetUnixSignals(self): return self
    def GetSignalNumberFromName(self, name): assert name == 'SIGPIPE'; return 13
    def SetShouldSuppress(self, sig, value): assert sig == 13 and value is False; return True
    def SetShouldStop(self, sig, value): assert sig == 13 and value is True; return True
    def GetShouldSuppress(self, sig): return False
    def Continue(self):
        self.continues += 1
        assert self.continues == 1, 'Never resume an unexpected new stop'
        entry = (1, 7, 101, None)
        running = (3, 7, 101, None)
        sigpipe = (1, 11, 99, 13)  # Stop IDs can skip values; running may never be observed.
        exited = (2, 7, 101, None)
        self.observations = iter({
            'stale-signal': [entry, entry, sigpipe], 'signal': [sigpipe],
            'running-signal': [entry, running, sigpipe], 'exit': [exited],
            'stale-exit': [entry, entry, exited], 'timeout': [running], 'stale-timeout': [entry],
            'unexpected-signal': [entry, (1, 12, 99, 5)],
            'unexpected-breakpoint': [entry, (1, 12, 100, None)],
            'unexpected-exception': [entry, (1, 12, 102, None)],
            'unexpected-crash': [entry, (5, 12, 102, None)],
        }[self.scenario])
        return Error()
    def GetExitStatus(self): return 7
    def Kill(self): self.killed = True; self.state = 2; return Error()
class Target:
    def __init__(self, process): self.process, self.io = process, []
    def IsValid(self): return True
    def GetLaunchInfo(self): return self
    def SetArguments(self, args, append):
        assert args == ['--test-bundle-path', 'fixture-bundle', '--package-path', 'Core/PeekabooCore',
                        '--jobs', '4', '--no-parallel', 'fixture-bundle', '--testing-library', 'swift-testing']
        assert append is False
    def SetWorkingDirectory(self, path): assert path == str(root)
    def GetLaunchFlags(self): return 8
    def SetLaunchFlags(self, flags): assert flags == 12
    def AddOpenFileAction(self, fd, path, read, write):
        assert path == '/dev/null' and read == (fd == 0) and write == (fd != 0)
        self.io.append(fd); return True
    def Launch(self, info, error): assert self.io == [0, 1, 2]; return self.process
class Debugger:
    def __init__(self, process): self.target = Target(process)
    def GetCommandInterpreter(self): return self
    def HandleCommand(self, command, result): assert command == 'settings set target.load-script-from-symbol-file false'
    def SetAsync(self, value): assert value is True
    def CreateTarget(self, helper): assert helper == 'fixture-helper'; return self.target
lldb = NS(SBError=Error, SBCommandReturnObject=Error, eLaunchFlagStopAtEntry=4, eStopReasonSignal=99,
          eStateStopped=1, eStateExited=2, eStateRunning=3, eStateLaunching=4, eStateCrashed=5,
          eStateDetached=6, eStateInvalid=7)
request = dict(helper='fixture-helper', bundle='fixture-bundle', root=str(root), timeout_seconds=480,
               report=str(results / 'capture.json'), toolchain_record='fixture-toolchain.txt')
for scenario, expected in [
    ('stale-signal', 'sigpipe-reproduced'), ('signal', 'sigpipe-reproduced'),
    ('running-signal', 'sigpipe-reproduced'), ('exit', 'exited-without-sigpipe'),
    ('stale-exit', 'exited-without-sigpipe'), ('timeout', 'diagnostic-timeout'),
    ('stale-timeout', 'diagnostic-timeout'), ('unexpected-signal', 'stopped-without-sigpipe'),
    ('unexpected-breakpoint', 'stopped-without-sigpipe'), ('unexpected-exception', 'stopped-without-sigpipe'),
    ('unexpected-crash', 'stopped-without-sigpipe'),
]:
    clock = iter(range(0, 10000, 100))
    d.time = NS(monotonic=lambda: next(clock), sleep=lambda _: None)
    process = Process(scenario)
    d.capture(Debugger(process), lldb, request)
    report = json.loads(Path(request['report']).read_text())
    assert report['outcome'] == expected, (scenario, report)
    assert process.continues == 1
    assert process.killed == (expected != 'exited-without-sigpipe')
    if expected in ('sigpipe-reproduced', 'stopped-without-sigpipe'):
        assert report['stage'] == 'post-resume-stop'
        assert report['entry_stop_id'] == 7 and report['stop_id'] > 7
        assert report['process_state'] == (5 if scenario == 'unexpected-crash' else 1)
        assert len(report['threads']) == 2
        assert report['threads'][0]['frames'] == [dict(function='Fixture.closedPeerWrite()', file='Fixture.swift', line=42)]
        assert report['threads'][0]['reason_code'] == process.reason
        assert report['threads'][0]['signal_code'] == process.signal
        assert all(set(thread) == {'index', 'sigpipe', 'reason_code', 'signal_code', 'frames', 'frames_truncated'}
                   for thread in report['threads'])
    if expected == 'exited-without-sigpipe': assert report['helper_exit_code'] == 7
    if expected == 'diagnostic-timeout': assert 'threads' not in report
assert (status.read_bytes(), log.read_bytes()) == original
print('gating, symbol/source-only capture, no-repro, timeout, cleanup and fatal original state verified')
`, diagnosticPath], {
    cwd: root, env: { PATH: process.env.PATH, PYTHONDONTWRITEBYTECODE: '1' }, encoding: 'utf8', timeout: 10000,
  });
  assert.equal(result.status, 0, result.stderr);
});

test('diagnostic derives existing helper/bundle paths and discards debugger output', (t) => {
  const root = fixture(t);
  const bin = join(root, 'bin');
  const compiler = join(root, 'toolchain/usr/bin/swiftc');
  const helper = join(root, 'toolchain/usr/libexec/swift/pm/swiftpm-testing-helper');
  const build = join(root, 'Core/PeekabooCore/.build/fixture/debug');
  const bundle = join(build, 'PeekabooCorePackageTests.xctest/Contents/MacOS/PeekabooCorePackageTests');
  for (const path of [compiler, helper, bundle]) {
    mkdirSync(join(path, '..'), { recursive: true });
    writeFileSync(path, '#!/bin/bash\nexit 99\n', { mode: 0o755 });
  }
  mkdirSync(bin);
  writeFileSync(join(bin, 'xcrun'), `#!${process.execPath}
const args = process.argv.slice(2);
if (args.join(' ') === '--find swiftc') console.log(${JSON.stringify(compiler)});
else if (args.join(' ') === '--find lldb') console.log(${JSON.stringify(join(bin, 'lldb'))});
else if (args.join(' ') === 'swift build --package-path Core/PeekabooCore --configuration debug --show-bin-path') console.log(${JSON.stringify(build)});
else process.exit(99);
`, { mode: 0o755 });
  writeFileSync(join(bin, 'lldb'), `#!${process.execPath}
const fs = require('node:fs');
const request = JSON.parse(fs.readFileSync(process.env.CORE_SIGPIPE_REQUEST));
fs.writeFileSync(${JSON.stringify(join(root, 'debugger-args.json'))}, JSON.stringify(process.argv.slice(2)));
console.log('PRIVATE_DEBUGGER_STDOUT'); console.error('PRIVATE_DEBUGGER_STDERR');
if (process.env.FIXTURE_MODE === 'fail') process.exit(19);
fs.writeFileSync(request.report, JSON.stringify({outcome: process.env.FIXTURE_MODE}));
`, { mode: 0o755 });
  for (const [mode, exit] of [['sigpipe-reproduced', 0], ['exited-without-sigpipe', 0], ['fail', 1]]) {
    const result = spawnSync('python3', ['-c', String.raw`
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('diagnostic', sys.argv[1])
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
results = Path.cwd() / 'results'
results.mkdir(exist_ok=True)
raise SystemExit(d.diagnose(Path.cwd(), results))
`, diagnosticPath], {
      cwd: root, env: { PATH: `${bin}:${process.env.PATH}`, PYTHONDONTWRITEBYTECODE: '1', FIXTURE_MODE: mode },
      // Allows startup of the fake probes/debugger, not a longer real diagnostic deadline.
      encoding: 'utf8', timeout: 30000,
    });
    assert.equal(result.error?.code ?? null, null, `${mode}: fixture launch error`);
    assert.equal(result.signal, null, `${mode}: fixture terminated by signal`);
    assert.equal(result.status, exit, result.stderr);
    assert.equal(result.stdout + result.stderr, '', 'Debugger/test output must never be captured');
    const request = JSON.parse(readFileSync(join(root, 'results/core-sigpipe-diagnostic-request.json'), 'utf8'));
    assert.equal(request.helper, realpathSync(helper));
    assert.equal(request.bundle, realpathSync(bundle));
    const args = JSON.parse(readFileSync(join(root, 'debugger-args.json'), 'utf8'));
    assert.deepEqual(args.slice(0, 3), ['--batch', '--no-lldbinit', '--one-line']);
    assert.match(args[3], /runpy\.run_path/);
    assert.equal(args.length, 4);
    const report = JSON.parse(readFileSync(join(root, 'results/core-sigpipe-diagnostic.json'), 'utf8'));
    assert.equal(report.outcome, mode === 'fail' ? 'debugger-failed' : mode);
    if (mode === 'fail') assert.equal(report.debugger_exit_code, 19);
  }
});
