#!/usr/bin/env node

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  exactKeys,
  parseOptions,
  readStableJSON,
  requireCondition,
  writePrivateExclusive,
} from './lib.mjs';

const SOURCE_COMMIT = /^[0-9a-f]{40}$/;
const SHA256 = /^[0-9a-f]{64}$/;
const HOST_UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[1-5][0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$/;

function hashStableFile(filePath) {
  const before = fs.lstatSync(filePath);
  requireCondition(before.isFile() && !before.isSymbolicLink(),
    `crash entry is not regular: ${filePath}`);
  const bytes = fs.readFileSync(filePath);
  const after = fs.lstatSync(filePath);
  requireCondition(before.dev === after.dev && before.ino === after.ino
    && before.size === after.size && before.mtimeMs === after.mtimeMs
    && bytes.length === after.size, `crash entry changed during capture: ${filePath}`);
  return {
    name: path.basename(filePath),
    size: after.size,
    modified_at_milliseconds: Math.floor(after.mtimeMs),
    sha256: createHash('sha256').update(bytes).digest('hex'),
  };
}

function validateInventory(value, label) {
  exactKeys(value, ['version', 'directory', 'prefixes', 'entries', 'captured_at_milliseconds'], label);
  requireCondition(value.version === 1 && Number.isSafeInteger(value.captured_at_milliseconds)
    && value.captured_at_milliseconds > 0
    && Array.isArray(value.prefixes) && value.prefixes.length > 0
    && value.prefixes.every((entry) => typeof entry === 'string'
      && /^[A-Za-z0-9._-]+$/.test(entry))
    && new Set(value.prefixes).size === value.prefixes.length
    && Array.isArray(value.entries), `${label} is malformed`);
  value.entries.forEach((entry, index) => {
    exactKeys(entry, ['name', 'size', 'modified_at_milliseconds', 'sha256'],
      `${label}.entries[${index}]`);
    requireCondition(/^[A-Za-z0-9._-]+$/.test(entry.name)
      && Number.isSafeInteger(entry.size) && entry.size >= 0
      && Number.isSafeInteger(entry.modified_at_milliseconds)
      && SHA256.test(entry.sha256), `${label}.entries[${index}] is malformed`);
  });
  requireCondition(new Set(value.entries.map((entry) => entry.name)).size === value.entries.length,
    `${label} contains duplicate crash names`);
  return value;
}

function validateCycleBinding(value) {
  exactKeys(value, [
    'version', 'cycle', 'success', 'catalog_version', 'expected_cases', 'observed_cases',
    'failures', 'execution_nonce', 'host_uuid', 'peekaboo_source_commit',
    'bridge_source_commit', 'deployment_envelope_sha256',
    'installed_inventory_aggregate_sha256', 'peekaboo_artifact_manifest_sha256',
    'started_at_milliseconds', 'completed_at_milliseconds',
  ], 'matrix cycle binding');
  requireCondition(value.version === 2
    && Number.isSafeInteger(value.cycle) && value.cycle >= 1 && value.cycle <= 5
    && value.success === true && value.catalog_version === 2
    && value.expected_cases === 42 && value.observed_cases === 42
    && Array.isArray(value.failures) && value.failures.length === 0
    && SHA256.test(value.execution_nonce ?? '') && HOST_UUID.test(value.host_uuid ?? '')
    && SOURCE_COMMIT.test(value.peekaboo_source_commit ?? '')
    && value.bridge_source_commit === value.peekaboo_source_commit
    && SHA256.test(value.deployment_envelope_sha256 ?? '')
    && SHA256.test(value.installed_inventory_aggregate_sha256 ?? '')
    && SHA256.test(value.peekaboo_artifact_manifest_sha256 ?? '')
    && Number.isSafeInteger(value.started_at_milliseconds)
    && Number.isSafeInteger(value.completed_at_milliseconds)
    && value.completed_at_milliseconds > value.started_at_milliseconds,
  'matrix cycle binding is not one passing 42/42 certificate');
  return value;
}

export function captureCrashInventory({ catalogPath, directory }) {
  const canonicalDirectory = path.join(os.homedir(), 'Library', 'Logs', 'DiagnosticReports');
  requireCondition(path.resolve(directory) === canonicalDirectory
    && fs.realpathSync(directory) === canonicalDirectory,
  'directory must be the canonical current-user DiagnosticReports directory');
  const catalog = readStableJSON(catalogPath, 'crash catalog', { privateFile: false }).value;
  const prefixes = catalog?.monitor_contract?.crash_report_prefixes;
  requireCondition(Array.isArray(prefixes) && prefixes.length > 0
    && prefixes.every((entry) => typeof entry === 'string'
      && /^[A-Za-z0-9._-]+$/.test(entry))
    && new Set(prefixes).size === prefixes.length,
  'catalog crash prefixes are malformed');
  const entries = fs.readdirSync(directory, { withFileTypes: true })
    .filter((entry) => entry.isFile()
      && prefixes.some((prefix) => entry.name.startsWith(prefix)))
    .map((entry) => hashStableFile(path.join(directory, entry.name)))
    .sort((left, right) => left.name.localeCompare(right.name));
  return {
    version: 1,
    directory: canonicalDirectory,
    prefixes: [...prefixes],
    entries,
    captured_at_milliseconds: Date.now(),
  };
}

export function compareCrashInventories(baselineValue, finalValue, cycleBinding = null) {
  const baseline = validateInventory(baselineValue, 'baseline');
  const final = validateInventory(finalValue, 'final');
  requireCondition(baseline.directory === final.directory
    && JSON.stringify(baseline.prefixes) === JSON.stringify(final.prefixes)
    && final.captured_at_milliseconds >= baseline.captured_at_milliseconds,
  'inventory capture domains or ordering differ');
  const before = new Map(baseline.entries.map((entry) => [entry.name, entry]));
  const after = new Map(final.entries.map((entry) => [entry.name, entry]));
  const added = final.entries.filter((entry) => !before.has(entry.name));
  const removed = baseline.entries.filter((entry) => !after.has(entry.name));
  const changed = final.entries.filter((entry) => {
    const prior = before.get(entry.name);
    return prior && JSON.stringify(prior) !== JSON.stringify(entry);
  });
  const passed = added.length === 0 && removed.length === 0 && changed.length === 0;
  if (cycleBinding === null) return { version: 1, passed, added, changed, removed };
  const binding = validateCycleBinding(cycleBinding);
  requireCondition(baseline.captured_at_milliseconds <= binding.started_at_milliseconds
    && final.captured_at_milliseconds >= binding.completed_at_milliseconds,
  'crash inventories do not bracket the bound matrix cycle');
  return {
    version: 2,
    cycle: binding.cycle,
    execution_nonce: binding.execution_nonce,
    host_uuid: binding.host_uuid,
    peekaboo_source_commit: binding.peekaboo_source_commit,
    deployment_envelope_sha256: binding.deployment_envelope_sha256,
    installed_inventory_aggregate_sha256: binding.installed_inventory_aggregate_sha256,
    peekaboo_artifact_manifest_sha256: binding.peekaboo_artifact_manifest_sha256,
    started_at_milliseconds: baseline.captured_at_milliseconds,
    completed_at_milliseconds: final.captured_at_milliseconds,
    passed,
    added,
    changed,
    removed,
  };
}

function invokedAsScript() {
  return process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
}

if (invokedAsScript()) {
  try {
    const [action, ...arguments_] = process.argv.slice(2);
    let result;
    let output;
    if (action === 'capture') {
      const options = parseOptions(arguments_, ['catalog', 'directory', 'output']);
      output = options.output;
      result = captureCrashInventory({
        catalogPath: options.catalog,
        directory: options.directory,
      });
    } else if (action === 'compare') {
      const names = arguments_.includes('--binding')
        ? ['baseline', 'final', 'binding', 'output']
        : ['baseline', 'final', 'output'];
      const options = parseOptions(arguments_, names);
      output = options.output;
      const baseline = readStableJSON(options.baseline, 'baseline').value;
      const final = readStableJSON(options.final, 'final').value;
      const binding = options.binding === undefined
        ? null
        : readStableJSON(options.binding, 'matrix cycle binding').value;
      result = compareCrashInventories(baseline, final, binding);
    } else {
      throw new Error('first argument must be capture or compare');
    }
    writePrivateExclusive(output, result);
    if (result.passed === false) process.exitCode = 1;
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
