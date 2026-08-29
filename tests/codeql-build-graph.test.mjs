import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';

const workflow = readFileSync(new URL('../.github/workflows/codeql.yml', import.meta.url), 'utf8');
const macOSCI = readFileSync(new URL('../.github/workflows/macos-ci.yml', import.meta.url), 'utf8');
const workspace = readFileSync(new URL('../Apps/Peekaboo.xcworkspace/contents.xcworkspacedata', import.meta.url), 'utf8');
const codeQLScheme = readFileSync(
  new URL('../Apps/Peekaboo.xcworkspace/xcshareddata/xcschemes/CodeQL.xcscheme', import.meta.url),
  'utf8');
const cliPackage = readFileSync(new URL('../Apps/CLI/Package.swift', import.meta.url), 'utf8');

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
