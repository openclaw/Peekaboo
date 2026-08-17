import assert from 'node:assert/strict';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  REMOVED_ROOT_COMMANDS,
  parseMigrationAdvisorForms,
  parseRegistryCommands,
  validateChangelogContract,
  validateCommandDocsContract,
  validateMigrationGuideContract,
  validateSourceDocumentationContracts,
  validateVersionConsistency,
  validateVersionValues
} from '../scripts/release-preflight-contract.mjs';

const projectRoot = fileURLToPath(new URL('..', import.meta.url));

test('CLI preflight covers all ten removed v4 root commands', () => {
  assert.deepEqual(REMOVED_ROOT_COMMANDS, [
    'image',
    'list',
    'hotkey',
    'inspect-ui',
    'perform-action',
    'swipe',
    'sleep',
    'open',
    'run',
    'commander'
  ]);
});

test('preparation accepts Unreleased while publication requires a dated heading', () => {
  const changelogSource = '# Changelog\n\n## [4.0.0] - Unreleased\n\n- Pending.\n';
  assert.deepEqual(validateChangelogContract({
    changelogSource,
    version: '4.0.0',
    requireDatedHeading: false
  }), []);
  assert.deepEqual(validateChangelogContract({
    changelogSource,
    version: '4.0.0',
    requireDatedHeading: true
  }), ["full publication preflight requires '## [4.0.0] - YYYY-MM-DD'; found Unreleased"]);
});

test('publication accepts only an exact heading with a valid ISO calendar date', () => {
  assert.deepEqual(validateChangelogContract({
    changelogSource: '## [4.0.0] - 2026-08-10\n',
    version: '4.0.0',
    requireDatedHeading: true
  }), []);
  assert.match(validateChangelogContract({
    changelogSource: '### 4.0.0 (2026-08-10)\n',
    version: '4.0.0',
    requireDatedHeading: true
  })[0], /must contain exactly/);
  assert.match(validateChangelogContract({
    changelogSource: '## [4.0.0] - 2026-02-30\n',
    version: '4.0.0',
    requireDatedHeading: true
  })[0], /invalid release date/);
  assert.deepEqual(validateChangelogContract({
    changelogSource: '## [4.0.0] - Unreleased\n\n## [4.0.0] - 2026-08-10\n',
    version: '4.0.0',
    requireDatedHeading: false
  }), [
    "CHANGELOG.md must contain exactly one '## [4.0.0] - Unreleased' or dated ISO heading; found 2"
  ]);
});

test('command registry roots must have exact page, index, and reference parity', () => {
  const registrySource = `
    .init(type: AlphaCommand.self, category: .core),
    .init(type: MenuBarCommand.self, category: .system),
    .init(type: SetValueCommand.self, category: .interaction),
  `;
  assert.deepEqual(parseRegistryCommands(registrySource), ['alpha', 'menubar', 'set-value']);

  const values = {
    registrySource,
    commandPages: ['README.md', 'alpha.md', 'menubar.md', 'set-value.md'],
    indexSource: '[`alpha`](alpha.md) [`menubar`](menubar.md) [`set-value`](set-value.md)',
    referenceSource: '[`alpha`](commands/alpha.md) [`menubar`](commands/menubar.md) ' +
      '[`set-value`](commands/set-value.md)',
    expectedCount: 3
  };
  assert.deepEqual(validateCommandDocsContract(values), []);

  const failures = validateCommandDocsContract({
    ...values,
    commandPages: ['README.md', 'alpha.md', 'menubar.md'],
    referenceSource: '[`alpha`](commands/alpha.md) [`menubar`](commands/menubar.md) ' +
      '[`wrong-label`](commands/set-value.md)'
  });
  assert.ok(failures.some((failure) => failure.includes('docs/commands pages missing: set-value')));
  assert.ok(failures.some((failure) => failure.includes("label 'wrong-label'")));
});

test('migration guide covers every mapping extracted from CommanderMigrationAdvisor', () => {
  const advisorSource = `
    private static let removedRootReplacements: [String: String] = ["hotkey": "press"]
    private static let removedPathReplacements: [String: String] = ["config add": "config credential set"]
    private static let removedOptionReplacements: [String: String] = ["--old": "--new"]
    private static let removedAgentModeReplacements: [String: String] = ["--chat": "agent chat"]
    private static let removedTypeKeyReplacements = Set(["--return"])
  `;
  assert.deepEqual(parseMigrationAdvisorForms(advisorSource), [
    'hotkey', 'config add', '--old', '--chat', '--return'
  ]);

  const removedRootRows = REMOVED_ROOT_COMMANDS.map((command) =>
    `| \`peekaboo ${command} example\` | \`replacement for ${command}\` |`
  );
  const guide = [
    '| Old | New |',
    '|---|---|',
    ...removedRootRows,
    '| `config add value` | `config credential set` |',
    '| `--old` | `--new` |',
    '| `--chat` | `agent chat` |',
    '| `--return` | `press Return` |'
  ].join('\n');
  assert.deepEqual(validateMigrationGuideContract({ advisorSource, migrationGuideSource: guide }), []);

  const failures = validateMigrationGuideContract({
    advisorSource,
    migrationGuideSource: guide.replace('| `--old` | `--new` |', '')
  });
  assert.deepEqual(failures, [
    'docs/v4-migration.md is missing CommanderMigrationAdvisor mappings for: --old'
  ]);
});

test('version parity reports missing and stale release surfaces', () => {
  const failures = validateVersionValues({
    expectedVersion: '4.0.0',
    values: {
      package: '4.0.0',
      CLI: '3.10.0',
      Playground: [],
      Inspector: ['4.0.0', '4.0.0']
    }
  });
  assert.deepEqual(failures, [
    'CLI version mismatch: expected 4.0.0, found 3.10.0',
    'Playground version field is missing'
  ]);
});

test('repository release source surfaces remain internally consistent', () => {
  const versionResult = validateVersionConsistency(projectRoot);
  assert.equal(versionResult.version, '4.2.1');
  assert.deepEqual(versionResult.failures, []);
  assert.deepEqual(validateSourceDocumentationContracts(projectRoot), []);
});
