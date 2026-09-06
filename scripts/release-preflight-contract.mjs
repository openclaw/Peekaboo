import { readFileSync, readdirSync } from 'node:fs';
import { basename, join } from 'node:path';

export const EXPECTED_ROOT_COMMAND_COUNT = 33;

export const MIGRATION_ADVISOR_PATH =
  'Apps/CLI/Sources/PeekabooCLI/CLI/CommanderMigrationAdvisor.swift';

export const REMOVED_ROOT_COMMANDS = Object.freeze([
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

const registryNameOverrides = new Map([
  ['AgentRootCommand', 'agent'],
  ['MenuBarCommand', 'menubar']
]);

const migrationDictionaryNames = [
  'removedRootReplacements',
  'removedPathReplacements',
  'removedOptionReplacements',
  'removedAgentModeReplacements'
];

const migrationSetNames = ['removedTypeKeyReplacements'];

const versionFiles = Object.freeze({
  packageJson: 'package.json',
  rootVersionJson: 'version.json',
  cliVersionJson: 'Apps/CLI/Sources/Resources/version.json',
  cliPlist: 'Apps/CLI/Sources/Resources/Info.plist',
  testHostPlist: 'Apps/CLI/TestHost/Info.plist',
  mcpVersion: 'Core/PeekabooCore/Sources/PeekabooAgentRuntime/MCP/PeekabooMCPVersion.swift',
  macProject: 'Apps/Mac/Peekaboo.xcodeproj/project.pbxproj',
  inspectorProject: 'Apps/PeekabooInspector/Inspector.xcodeproj/project.pbxproj',
  playgroundProject: 'Apps/Playground/Playground.xcodeproj/project.pbxproj'
});

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function unique(values) {
  return [...new Set(values)];
}

function duplicates(values) {
  const seen = new Set();
  const repeated = new Set();
  for (const value of values) {
    if (seen.has(value)) repeated.add(value);
    seen.add(value);
  }
  return [...repeated].sort();
}

function compareCommandSets(label, actual, expected) {
  const failures = [];
  const actualSet = new Set(actual);
  const expectedSet = new Set(expected);
  const missing = expected.filter((command) => !actualSet.has(command));
  const extra = actual.filter((command) => !expectedSet.has(command));
  const repeated = duplicates(actual);

  if (missing.length > 0) failures.push(`${label} missing: ${missing.join(', ')}`);
  if (extra.length > 0) failures.push(`${label} has unexpected entries: ${unique(extra).join(', ')}`);
  if (repeated.length > 0) failures.push(`${label} has duplicate entries: ${repeated.join(', ')}`);
  return failures;
}

function swiftTypeToCommandName(typeName) {
  const override = registryNameOverrides.get(typeName);
  if (override) return override;

  const stem = typeName.replace(/(?:Root)?Command$/, '');
  return stem
    .replace(/([A-Z]+)([A-Z][a-z])/g, '$1-$2')
    .replace(/([a-z0-9])([A-Z])/g, '$1-$2')
    .toLowerCase();
}

export function parseRegistryCommands(source) {
  const types = [...source.matchAll(/\.init\(\s*type:\s*([A-Za-z][A-Za-z0-9_]*)\.self,\s*category:/g)]
    .map((match) => match[1]);
  return types.map(swiftTypeToCommandName);
}

export function parseCommandIndexLinks(source) {
  return [...source.matchAll(/\[`([^`]+)`\]\(([^)\s]+\.md)\)/g)]
    .filter((match) => !match[2].includes('/'))
    .map((match) => ({ label: match[1], command: basename(match[2], '.md') }));
}

export function parseCommandReferenceLinks(source) {
  return [...source.matchAll(/\[`([^`]+)`\]\(commands\/([a-z0-9-]+)\.md\)/g)]
    .map((match) => ({ label: match[1], command: match[2] }));
}

export function validateCommandDocsContract({
  registrySource,
  commandPages,
  indexSource,
  referenceSource,
  expectedCount = EXPECTED_ROOT_COMMAND_COUNT
}) {
  const failures = [];
  const registryCommands = parseRegistryCommands(registrySource);
  const pageCommands = commandPages
    .filter((page) => page !== 'README.md')
    .map((page) => basename(page, '.md'))
    .sort();
  const indexLinks = parseCommandIndexLinks(indexSource);
  const referenceLinks = parseCommandReferenceLinks(referenceSource);
  const indexCommands = indexLinks.map((link) => link.command);
  const referenceCommands = referenceLinks.map((link) => link.command);

  if (registryCommands.length !== expectedCount) {
    failures.push(`command registry has ${registryCommands.length} roots; expected exactly ${expectedCount}`);
  }

  const repeatedRegistryCommands = duplicates(registryCommands);
  if (repeatedRegistryCommands.length > 0) {
    failures.push(`command registry has duplicate roots: ${repeatedRegistryCommands.join(', ')}`);
  }

  const expected = [...registryCommands].sort();
  failures.push(...compareCommandSets('docs/commands pages', pageCommands, expected));
  failures.push(...compareCommandSets('docs/commands/README.md index', indexCommands, expected));
  failures.push(...compareCommandSets('docs/cli-command-reference.md', referenceCommands, expected));

  for (const { label, command } of [...indexLinks, ...referenceLinks]) {
    if (label !== command) {
      failures.push(`command doc link label '${label}' does not match page '${command}.md'`);
    }
  }

  return failures;
}

function collectionBody(source, name) {
  const pattern = new RegExp(
    `(?:private\\s+)?static\\s+let\\s+${name}[^=]*=\\s*(?:Set\\s*\\(\\s*)?\\[([\\s\\S]*?)\\]`
  );
  return source.match(pattern)?.[1] ?? null;
}

// Replacement text per removed root, derived from the advisor itself so the
// preflight cannot drift from what the binary actually prints.
export function parseRemovedRootReplacements(source) {
  const body = collectionBody(source, 'removedRootReplacements');
  if (!body) throw new Error('Could not parse CommanderMigrationAdvisor.removedRootReplacements');
  const replacements = new Map();
  for (const match of body.matchAll(/^\s*"([^"]+)"\s*:\s*"([^"]*)"/gm)) {
    replacements.set(match[1], match[2]);
  }
  // `list` is not a dictionary entry: removedListError picks a replacement from
  // the subcommand, and a bare `list` falls through to its default branch.
  const listDefault = source.match(/default:\s*"([^"]+)"/);
  if (listDefault) replacements.set('list', listDefault[1]);
  return replacements;
}

export function parseMigrationAdvisorForms(source) {
  const forms = [];
  for (const name of migrationDictionaryNames) {
    const body = collectionBody(source, name);
    if (!body) throw new Error(`Could not parse CommanderMigrationAdvisor.${name}`);
    forms.push(...[...body.matchAll(/^\s*"([^"]+)"\s*:/gm)].map((match) => match[1]));
  }
  for (const name of migrationSetNames) {
    const body = collectionBody(source, name);
    if (!body) throw new Error(`Could not parse CommanderMigrationAdvisor.${name}`);
    forms.push(...[...body.matchAll(/"([^"]+)"/g)].map((match) => match[1]));
  }
  return forms;
}

function inlineCodeSpans(source) {
  return [...source.matchAll(/`([^`\n]+)`/g)].map((match) => match[1]);
}

function markdownMappingRows(source) {
  const rows = [];
  for (const line of source.split('\n')) {
    if (!line.trimStart().startsWith('|')) continue;
    const cells = [];
    let start = 0;
    for (let index = 0; index < line.length; index += 1) {
      if (line[index] === '|' && (index === 0 || line[index - 1] !== '\\')) {
        cells.push(line.slice(start, index));
        start = index + 1;
      }
    }
    cells.push(line.slice(start));
    if (cells.length !== 4) continue;
    const oldCell = cells[1].trim();
    const newCell = cells[2].trim();
    if (!oldCell || /^-+$/.test(oldCell.replace(/\s/g, ''))) continue;
    rows.push({ oldCell, newCell });
  }
  return rows;
}

function codeSpanContainsForm(span, form) {
  const escaped = escapeRegExp(form);
  const prefix = form.startsWith('-') ? '(^|[\\s/|])' : '(^|[\\s])';
  const suffix = form.startsWith('-') ? '(?=$|[\\s=</|])' : '(?=$|[\\s<|])';
  return new RegExp(`${prefix}${escaped}${suffix}`).test(span);
}

export function validateMigrationGuideContract({ advisorSource, migrationGuideSource }) {
  let advisorForms;
  try {
    advisorForms = parseMigrationAdvisorForms(advisorSource);
  } catch (error) {
    return [error.message];
  }

  const failures = [];
  const repeatedForms = duplicates(advisorForms);
  if (repeatedForms.length > 0) {
    failures.push(`CommanderMigrationAdvisor repeats deprecated forms: ${repeatedForms.join(', ')}`);
  }

  const rows = markdownMappingRows(migrationGuideSource);
  const missing = advisorForms.filter((form) => !rows.some((row) =>
    inlineCodeSpans(row.oldCell).some((span) => codeSpanContainsForm(span, form)) && row.newCell.length > 0
  ));
  if (missing.length > 0) {
    failures.push(`docs/v4-migration.md is missing CommanderMigrationAdvisor mappings for: ${missing.join(', ')}`);
  }

  for (const command of REMOVED_ROOT_COMMANDS) {
    const oldInvocation = `peekaboo ${command}`;
    const hasMapping = rows.some((row) => inlineCodeSpans(row.oldCell).some((span) =>
      span === command || span.startsWith(`${oldInvocation} `) || span === oldInvocation
    ) && row.newCell.length > 0);
    if (!hasMapping) {
      failures.push(`docs/v4-migration.md is missing removed root command: ${command}`);
    }
  }

  return failures;
}

function isValidCalendarDate(value) {
  const match = value.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!match) return false;
  const [, year, month, day] = match.map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day;
}

export function validateChangelogContract({ changelogSource, version, requireDatedHeading }) {
  const escapedVersion = escapeRegExp(version);
  const headingPattern = new RegExp(
    `^## (?:\\[${escapedVersion}\\]|${escapedVersion}) - (Unreleased|\\d{4}-\\d{2}-\\d{2})$`, 'gm');
  const matches = [...changelogSource.matchAll(headingPattern)];
  if (matches.length !== 1) {
    return [
      `CHANGELOG.md must contain exactly one '## ${version} - Unreleased' or dated ISO heading ` +
      `(version brackets optional); ` +
      `found ${matches.length}`
    ];
  }
  const match = matches[0];
  if (requireDatedHeading && match[1] === 'Unreleased') {
    return [`full publication preflight requires '## ${version} - YYYY-MM-DD' ` +
      `(version brackets optional); found Unreleased`];
  }
  if (match[1] !== 'Unreleased' && !isValidCalendarDate(match[1])) {
    return [`CHANGELOG.md has an invalid release date for ${version}: ${match[1]}`];
  }
  return [];
}

export function validateNpmVersionAvailability({ packageName, version, registryOutput }) {
  const retryCommand = `npm view ${packageName} versions --json`;
  if (typeof registryOutput !== 'string' || registryOutput.trim().length === 0) {
    return [
      `Could not confirm ${packageName}@${version} availability: the npm registry query failed or returned no data. ` +
      `Run '${retryCommand}' and verify registry connectivity or authentication before releasing.`
    ];
  }

  let publishedVersions;
  try {
    const parsed = JSON.parse(registryOutput);
    publishedVersions = typeof parsed === 'string' ? [parsed] : parsed;
  } catch {
    return [
      `Could not confirm ${packageName}@${version} availability: the npm registry returned invalid JSON. ` +
      `Run '${retryCommand}' and verify the registry response before releasing.`
    ];
  }

  if (!Array.isArray(publishedVersions) || publishedVersions.some((entry) =>
    typeof entry !== 'string' || entry.trim().length === 0
  )) {
    return [
      `Could not confirm ${packageName}@${version} availability: the npm registry returned an invalid version list. ` +
      `Run '${retryCommand}' and verify the registry response before releasing.`
    ];
  }

  if (publishedVersions.includes(version)) {
    return [
      `Version ${version} is already published on npm!`,
      'Please update the version in package.json before releasing.'
    ];
  }

  return [];
}

function plistValue(source, key) {
  const escapedKey = escapeRegExp(key);
  return source.match(new RegExp(`<key>${escapedKey}</key>\\s*<string>([^<]+)</string>`))?.[1] ?? null;
}

function mcpVersionValue(source) {
  return source.match(/static\s+let\s+current\s*=\s*"([^"]+)"/)?.[1] ?? null;
}

function marketingVersions(source) {
  return [...source.matchAll(/\bMARKETING_VERSION\s*=\s*([^;\s]+)\s*;/g)].map((match) => match[1]);
}

export function validateVersionValues({ expectedVersion, values }) {
  const failures = [];
  for (const [label, actualValues] of Object.entries(values)) {
    const entries = Array.isArray(actualValues) ? actualValues : [actualValues];
    if (entries.length === 0 || entries.some((value) => value == null)) {
      failures.push(`${label} version field is missing`);
      continue;
    }
    const mismatches = unique(entries.filter((value) => value !== expectedVersion));
    if (mismatches.length > 0) {
      failures.push(`${label} version mismatch: expected ${expectedVersion}, found ${mismatches.join(', ')}`);
    }
  }
  return failures;
}

export function validateVersionConsistency(projectRoot) {
  const read = (relativePath) => readFileSync(join(projectRoot, relativePath), 'utf8');
  const packageVersion = JSON.parse(read(versionFiles.packageJson)).version;
  const cliPlist = read(versionFiles.cliPlist);
  const testHostPlist = read(versionFiles.testHostPlist);
  const values = {
    'root version.json': JSON.parse(read(versionFiles.rootVersionJson)).version,
    'CLI version.json': JSON.parse(read(versionFiles.cliVersionJson)).version,
    'CLI CFBundleShortVersionString': plistValue(cliPlist, 'CFBundleShortVersionString'),
    'CLI CFBundleVersion': plistValue(cliPlist, 'CFBundleVersion'),
    'CLI PeekabooVersionDisplayString': plistValue(cliPlist, 'PeekabooVersionDisplayString')
      ?.replace(/^Peekaboo\s+/, ''),
    'TestHost CFBundleShortVersionString': plistValue(testHostPlist, 'CFBundleShortVersionString'),
    'TestHost CFBundleVersion': plistValue(testHostPlist, 'CFBundleVersion'),
    'MCP server': mcpVersionValue(read(versionFiles.mcpVersion)),
    'Mac app MARKETING_VERSION': marketingVersions(read(versionFiles.macProject)),
    'Inspector MARKETING_VERSION': marketingVersions(read(versionFiles.inspectorProject)),
    'Playground MARKETING_VERSION': marketingVersions(read(versionFiles.playgroundProject))
  };
  return {
    version: packageVersion,
    failures: validateVersionValues({ expectedVersion: packageVersion, values })
  };
}

export function validateSourceDocumentationContracts(projectRoot) {
  const commandDocsPath = join(projectRoot, 'docs', 'commands');
  const commandFailures = validateCommandDocsContract({
    registrySource: readFileSync(
      join(projectRoot, 'Apps/CLI/Sources/PeekabooCLI/CLI/Configuration/CommandRegistry.swift'),
      'utf8'
    ),
    commandPages: readdirSync(commandDocsPath).filter((name) => name.endsWith('.md')),
    indexSource: readFileSync(join(commandDocsPath, 'README.md'), 'utf8'),
    referenceSource: readFileSync(join(projectRoot, 'docs/cli-command-reference.md'), 'utf8')
  });
  const migrationFailures = validateMigrationGuideContract({
    advisorSource: readFileSync(join(projectRoot, MIGRATION_ADVISOR_PATH), 'utf8'),
    migrationGuideSource: readFileSync(join(projectRoot, 'docs/v4-migration.md'), 'utf8')
  });
  return [...commandFailures, ...migrationFailures];
}
