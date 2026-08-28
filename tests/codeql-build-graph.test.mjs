import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';

const workflow = readFileSync(new URL('../.github/workflows/codeql.yml', import.meta.url), 'utf8');
const workspace = readFileSync(new URL('../Apps/Peekaboo.xcworkspace/contents.xcworkspacedata', import.meta.url), 'utf8');
const codeQLScheme = readFileSync(
  new URL('../Apps/Peekaboo.xcworkspace/xcshareddata/xcschemes/CodeQL.xcscheme', import.meta.url),
  'utf8');

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
  const entries = [...codeQLScheme.matchAll(/<BuildActionEntry(?<entry>[\s\S]*?)<\/BuildActionEntry>/g)]
    .map(({ groups }) => groups.entry)
    .map((entry) => {
      assert.match(entry, /buildForAnalyzing = "YES"/);
      return {
        id: entry.match(/BlueprintIdentifier = "(?<value>[^"]+)"/)?.groups?.value,
        name: entry.match(/BlueprintName = "(?<value>[^"]+)"/)?.groups?.value,
        product: entry.match(/BuildableName = "(?<value>[^"]+)"/)?.groups?.value,
        container: entry.match(/ReferencedContainer = "container:(?<value>[^"]*)"/)?.groups?.value,
      };
    });

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

test('workspace CLI entry point avoids main.swift special-file semantics', () => {
  const sourceDirectory = new URL('../Apps/CLI/Sources/PeekabooExec/', import.meta.url);
  const sourceFiles = readdirSync(sourceDirectory);
  assert.ok(!sourceFiles.some((file) => file.toLowerCase() === 'main.swift'),
    'The workspace CLI must not contain a main.swift entry point');
  const mainFiles = sourceFiles.filter((file) => file.endsWith('.swift'))
    .filter((file) => /@main\b/.test(readFileSync(new URL(file, sourceDirectory), 'utf8')));

  assert.deepEqual(mainFiles, ['PeekabooMain.swift']);
});
