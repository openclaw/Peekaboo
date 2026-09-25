import assert from 'node:assert/strict';
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const workflow = readFileSync(new URL('../.github/workflows/codeql.yml', import.meta.url), 'utf8');
const macOSCI = readFileSync(new URL('../.github/workflows/macos-ci.yml', import.meta.url), 'utf8');
const workspace = readFileSync(new URL('../Apps/Peekaboo.xcworkspace/contents.xcworkspacedata', import.meta.url), 'utf8');
const codeQLScheme = readFileSync(
  new URL('../Apps/Peekaboo.xcworkspace/xcshareddata/xcschemes/CodeQL.xcscheme', import.meta.url),
  'utf8');
const cliPackage = readFileSync(new URL('../Apps/CLI/Package.swift', import.meta.url), 'utf8');

function cliCacheSteps() {
  const start = macOSCI.indexOf('      - name: Compute SwiftPM cache key (CLI)');
  const cache = macOSCI.indexOf('      - name: Cache SwiftPM (CLI)', start);
  const cleanup = macOSCI.indexOf('      - name: Clean SwiftPM trait state (CLI)', cache);
  const next = macOSCI.indexOf('      - name: Show Swift toolchain version', cleanup);
  assert.ok(start > 0 && cache > start && cleanup > cache && next > cleanup);
  return { key: macOSCI.slice(start, cache), cache: macOSCI.slice(cache, cleanup),
    cleanup: macOSCI.slice(cleanup, next) };
}

test('CLI cache retains dependency state without restoring its discarded build tree', () => {
  const { key, cache, cleanup } = cliCacheSteps();
  assert.match(cache, /~\/\.swiftpm/);
  assert.match(cache, /~\/\.cache\/org\.swift\.swiftpm/);
  assert.doesNotMatch(cache, /Apps\/CLI\/\.build/);
  assert.doesNotMatch(key, /GITHUB_SHA|Apps\/CLI\/Package\.resolved/);
  assert.match(key, /git ls-files --stage/);
  for (const input of ['Package.swift', '**/Package.swift', '**/Package.resolved', '.gitmodules',
    'AXorcist', 'Commander', 'Swiftdansi', 'Tachikoma', 'TauTUI']) assert.ok(key.includes(input), input);
  assert.match(cache, /restore-keys:\s*\|\s*\$\{\{ steps\.cache-key-cli\.outputs\.restore-prefix \}\}/);
  assert.match(cleanup, /manifest\.db/);
  assert.match(cleanup, /traits\.json/);
  assert.match(cleanup, /rm -rf Apps\/CLI\/\.build/);
});

test('CLI cache fingerprint tracks toolchain and graph inputs, not unrelated commit SHAs', () => {
  const step = cliCacheSteps().key;
  const script = step.split('        run: |\n')[1]?.replace(/^          /gm, '');
  assert.ok(script);
  const root = mkdtempSync(join(tmpdir(), 'peekaboo-cli-cache-key-'));
  try {
    for (const [name, variable] of [['swift', 'SWIFT_ID'], ['xcodebuild', 'XCODE_ID'], ['git', 'GRAPH_RECORDS']]) {
      writeFileSync(join(root, name), `#!/bin/sh\nif [ "\${FAIL_TOOL:-}" = "${name}" ]; then exit 12; fi\nprintf '%s\\n' "$${variable}"\n`, { mode: 0o700 });
    }
    let invocation = 0;
    const run = (overrides = {}) => {
      const output = join(root, `output-${invocation++}`);
      const result = spawnSync('/bin/bash', ['-c', script], { cwd: root, encoding: 'utf8', timeout: 5000,
        env: { PATH: `${root}:/usr/bin:/bin`, CACHE_PREFIX: 'macOS-spm-cli-dependencies-v2-', GITHUB_OUTPUT: output,
          SWIFT_ID: 'Swift fixture 6.2', XCODE_ID: 'Xcode fixture 26.6', GRAPH_RECORDS: 'manifest-a\ngitlink-a',
          GITHUB_SHA: 'unrelated-commit-a', ...overrides } });
      return { result, values: result.status === 0
        ? Object.fromEntries(readFileSync(output, 'utf8').trim().split('\n').map(line => line.split('='))) : null };
    };
    const baseline = run();
    assert.equal(baseline.result.status, 0, baseline.result.stderr);
    assert.deepEqual(run({ GITHUB_SHA: 'unrelated-commit-b' }).values, baseline.values);
    for (const GRAPH_RECORDS of ['manifest-b\ngitlink-a', 'manifest-a\ngitlink-b']) {
      const changed = run({ GRAPH_RECORDS });
      assert.equal(changed.result.status, 0, changed.result.stderr);
      assert.notEqual(changed.values.key, baseline.values.key);
      assert.equal(changed.values['restore-prefix'], baseline.values['restore-prefix']);
    }
    for (const changedToolchain of [{ SWIFT_ID: 'Swift fixture 6.3' }, { XCODE_ID: 'Xcode fixture 27.0' }]) {
      const changed = run(changedToolchain);
      assert.equal(changed.result.status, 0, changed.result.stderr);
      assert.notEqual(changed.values.key, baseline.values.key);
      assert.notEqual(changed.values['restore-prefix'], baseline.values['restore-prefix']);
    }
    for (const FAIL_TOOL of ['swift', 'xcodebuild', 'git']) assert.notEqual(run({ FAIL_TOOL }).result.status, 0);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

function buildEntries() {
  return [...codeQLScheme.matchAll(/<BuildActionEntry(?<entry>[\s\S]*?)<\/BuildActionEntry>/g)]
    .map(({ groups }) => groups.entry)
    .map((entry) => {
      assert.match(entry, /buildForAnalyzing = "YES"/);
      assert.match(entry, /buildForRunning = "YES"/);
      return {
        id: entry.match(/BlueprintIdentifier = "(?<value>[^"]+)"/)?.groups?.value,
        name: entry.match(/BlueprintName = "(?<value>[^"]+)"/)?.groups?.value,
        product: entry.match(/BuildableName = "(?<value>[^"]+)"/)?.groups?.value,
        container: entry.match(/ReferencedContainer = "container:(?<value>[^"]*)"/)?.groups?.value,
      };
    });
}

function assertCaseFoldedUnique(identities, label) {
  const owners = new Map();
  for (const identity of identities) {
    const folded = identity.toLowerCase();
    assert.ok(!owners.has(folded), `${label} collision: ${owners.get(folded)} and ${identity}`);
    owners.set(folded, identity);
  }
}

function cliExecutableTargets() {
  return [...cliPackage.matchAll(/\.executableTarget\(\s*name: "(?<name>[^"]+)"(?<body>[\s\S]*?)(?=\n    \.(?:executableTarget|testTarget|target)\()/g)]
    .map(({ groups }) => ({
      ...groups,
      path: groups.body.match(/path: "([^"]+)"/)?.[1],
    }));
}

function nativeTarget(entry) {
  const project = readFileSync(new URL(`../Apps/${entry.container}/project.pbxproj`, import.meta.url), 'utf8');
  const section = project.match(/\/\* Begin PBXNativeTarget section \*\/(?<body>[\s\S]*?)\/\* End PBXNativeTarget section \*\//)?.groups?.body;
  assert.ok(section, `${entry.container} must declare native targets`);
  const targets = [...section.matchAll(/(?<id>[A-F0-9]{24}) \/\* [^\n]+ \*\/ = \{(?<body>[\s\S]*?)\n\t\t\};/g)];
  const target = targets.find(({ groups }) => groups.id === entry.id)?.groups;
  assert.ok(target, `Missing ${entry.id} in ${entry.container}`);
  const name = target.body.match(/\n\s*name = "?([^";]+)"?;/)?.[1];
  assert.equal(name, entry.name, 'Scheme and native target identities must agree');
  assert.match(target.body, /productType = "com\.apple\.product-type\.application"/);
  return name;
}

test('Swift CodeQL uses one complete shared Xcode build graph', () => {
  const swiftJob = workflow.slice(workflow.indexOf('  analyze-swift:'));

  assert.match(swiftJob, /build-mode: manual/);
  assert.equal(swiftJob.match(/\n\s*xcodebuild \\/g)?.length, 1);
  assert.match(swiftJob, /-workspace Apps\/Peekaboo\.xcworkspace/);
  assert.match(swiftJob, /-scheme CodeQL/);
  assert.match(swiftJob, /-derivedDataPath "\$CODEQL_DERIVED_DATA"/);
  assert.doesNotMatch(swiftJob, /schemes=\(/);
  assert.doesNotMatch(swiftJob, /swift build --package-path Apps\/CLI/);
  assert.match(workspace, /location = "group:CLI"/);
});

test('CodeQL workspace scheme covers every analyzed product exactly once', () => {
  const entries = buildEntries();

  assert.deepEqual(entries, [
    { id: 'peekaboo', name: 'peekaboo', product: 'peekaboo', container: 'CLI' },
    {
      id: 'peekaboo-certification-controller',
      name: 'peekaboo-certification-controller',
      product: 'peekaboo-certification-controller',
      container: 'CLI',
    },
    {
      id: '7814F1052E1BD4C8000995F8',
      name: 'Peekaboo',
      product: 'Peekaboo.app',
      container: 'Mac/Peekaboo.xcodeproj',
    },
    {
      id: '7814F1052E1BD4C8000995F8',
      name: 'Playground',
      product: 'Playground.app',
      container: 'Playground/Playground.xcodeproj',
    },
    {
      id: '7814F0DD2E1B0A20000995F8',
      name: 'Inspector',
      product: 'Inspector.app',
      container: 'PeekabooInspector/Inspector.xcodeproj',
    },
  ]);
  assert.match(codeQLScheme, /<AnalyzeAction\s+buildConfiguration = "Debug">/);
});

test('shared graph separates case-folded project, module, and intermediate ownership', () => {
  const packageName = cliPackage.match(/let package = Package\(\s*name: "([^"]+)"/)?.[1];
  assert.ok(packageName, 'CLI package must have an explicit project identity');
  const entries = buildEntries();
  const appEntries = entries.filter(({ container }) => container.endsWith('.xcodeproj'));
  const appProjects = appEntries.map(({ container }) => container.split('/').at(-1).replace(/\.xcodeproj$/, ''));
  const cliModules = [...cliPackage.matchAll(/\.(?:target|executableTarget|testTarget)\(\s*name: "([^"]+)"/g)]
    .map((match) => match[1]);

  assertCaseFoldedUnique([packageName, ...appProjects], 'Project');
  assertCaseFoldedUnique([...cliModules, ...appEntries.map(nativeTarget)], 'Module');
  // Xcode 26 names executable product targets after the product, not the Swift entry target.
  const intermediateOwners = entries.map(({ name, container }) => {
    const project = container === 'CLI' ? packageName : container.split('/').at(-1).replace(/\.xcodeproj$/, '');
    return `${project}.build/Debug/${name}.build`;
  });
  assertCaseFoldedUnique(intermediateOwners, 'Intermediate directory');
  assert.equal(packageName, 'PeekabooCLIPackage');
});

test('public executable products retain their exact internal entry targets and coverage', () => {
  const products = [...cliPackage.matchAll(/\.executable\(\s*name: "([^"]+)",\s*targets: \["([^"]+)"\]\)/g)]
    .map((match) => ({ product: match[1], target: match[2] }));
  assert.deepEqual(products, [
    { product: 'peekaboo', target: 'PeekabooExec' },
    { product: 'peekaboo-certification-controller', target: 'PeekabooCertificationController' },
  ]);
  assert.deepEqual(buildEntries().filter(({ container }) => container === 'CLI').map(({ id }) => id),
    products.map(({ product }) => product));
  const targets = cliExecutableTargets();
  assert.deepEqual(targets.map(({ name, path }) => ({ name, path })), [
    { name: 'PeekabooExec', path: 'Sources/PeekabooExec' },
    { name: 'PeekabooCertificationController', path: 'Sources/PeekabooCertificationController' },
  ]);
  assert.match(targets[0].body, /dependencies: \[\s*"PeekabooCLI",?\s*\]/);
  for (const { body } of targets) {
    assert.doesNotMatch(body, /\b(?:exclude|sources):/, 'Do not silently narrow executable source coverage');
    assert.match(body, /"__TEXT"[\s\S]*"__info_plist"[\s\S]*infoPlistPath/);
    assert.match(body, /"-random_uuid"/);
  }
});

test('macOS CI links and runs the public CLI product', () => {
  const start = macOSCI.indexOf('  peekaboo-cli:');
  const end = macOSCI.indexOf('\n  tachikoma:', start);
  const cliJob = macOSCI.slice(start, end);

  assert.ok(start >= 0 && end > start, 'macOS CI must retain its dedicated CLI job');
  assert.match(cliJob, /name: Peekaboo CLI build & tests/);
  assert.match(cliJob, /working-directory: Apps\/CLI/);
  assert.match(cliJob, /swift build --configuration debug/);
  assert.match(cliJob, /PEEKABOO_CLI_BINARY=.*\/peekaboo/);
  assert.match(cliJob, /swift test --no-parallel/);
});

test('workspace CLI entry point avoids main.swift special-file semantics', () => {
  const sourceDirectory = new URL('../Apps/CLI/Sources/PeekabooExec/', import.meta.url);
  const sourceFiles = readdirSync(sourceDirectory, { recursive: true });
  assert.ok(!sourceFiles.some((file) => file.split('/').at(-1).toLowerCase() === 'main.swift'),
    'The workspace CLI must not contain a main.swift entry point');
  const mainFiles = sourceFiles.filter((file) => file.endsWith('.swift'))
    .filter((file) => /@main\b/.test(readFileSync(new URL(file, sourceDirectory), 'utf8')));

  assert.deepEqual(mainFiles, ['PeekabooMain.swift']);
});
