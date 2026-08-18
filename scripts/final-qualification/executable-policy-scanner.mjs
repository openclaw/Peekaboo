#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  aggregateSHA256,
  exactKeys,
  parseOptions,
  readStableFile,
  readStableJSON,
  requireCondition,
  sameJSON,
  sha256,
  writePrivateExclusive,
} from './lib.mjs';

const ARTIFACTS = ['openclaw_app', 'peekaboo_app', 'peekaboo_cli'];
const HOST_ROLES = ['local', 'studio'];
const HOST_UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;
const HEX40 = /^[0-9a-f]{40}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const SCRIPT_EXTENSIONS = new Set([
  '.applescript', '.bash', '.cjs', '.command', '.js', '.jxa', '.mjs', '.osa', '.pl', '.py',
  '.rb', '.sh', '.swift', '.zsh',
]);
const MACH_O_MAGICS = new Set([
  'feedface', 'cefaedfe',
  'feedfacf', 'cffaedfe',
  'cafebabe', 'bebafeca',
  'cafebabf', 'bfbafeca',
]);
const FORBIDDEN_MARKERS = [
  ['apple-script', /(^|[^a-z0-9])(osascript|osascriptd|applescript|nsapplescript|jxa|osaexecute|javascript for automation)([^a-z0-9]|$)/],
  ['cua-driver', /(^|[^a-z0-9])cua-driver([^a-z0-9]|$)/],
  ['virtualization', /(^|[^a-z0-9])(lume|parallels|vmware|virtualbox|virtualization|utm|tart|vfkit|qemu)([^a-z0-9]|$)/],
  ['remote-desktop', /(^|[^a-z0-9])(vnc|screen sharing|screensharing|remote desktop|remotedesktop)([^a-z0-9]|$)/],
];

function safeRelativePath(value, label) {
  requireCondition(typeof value === 'string' && value.length > 0 && !path.isAbsolute(value)
    && !value.includes('\0') && !value.includes('\n')
    && !value.split('/').some((component) => component === '' || component === '.' || component === '..'),
  `${label} is not one safe relative path`);
  return value;
}

function inventory(filePath) {
  const retained = readStableJSON(filePath, 'policy scanner installed inventory', {
    maximumBytes: 256 * 1024 * 1024,
  });
  const value = retained.value;
  exactKeys(value, [
    'version', 'role', 'host_uuid', 'hostname', 'deployment_envelope_sha256',
    'peekaboo_source_commit', 'openclaw_source_commit', 'qualification_tools_aggregate_sha256',
    'elevation_receipt_sha256', 'captured_at_milliseconds', 'entries', 'aggregate_sha256',
  ], 'policy scanner installed inventory');
  requireCondition(value.version === 1 && HOST_ROLES.includes(value.role)
    && HOST_UUID.test(value.host_uuid) && HEX64.test(value.deployment_envelope_sha256)
    && HEX40.test(value.peekaboo_source_commit) && HEX40.test(value.openclaw_source_commit)
    && HEX64.test(value.qualification_tools_aggregate_sha256)
    && HEX64.test(value.elevation_receipt_sha256)
    && Number.isSafeInteger(value.captured_at_milliseconds)
    && value.captured_at_milliseconds > 0 && Array.isArray(value.entries)
    && value.entries.length > 0,
  'policy scanner installed inventory is malformed');
  const entries = value.entries.map((entry, index) => {
    const common = ['artifact', 'relative_path', 'type', 'mode'];
    const specific = entry?.type === 'file' ? ['size', 'sha256']
      : entry?.type === 'symlink' ? ['target'] : [];
    exactKeys(entry, [...common, ...specific], `policy scanner inventory entry ${index}`);
    requireCondition(ARTIFACTS.includes(entry.artifact)
      && Number.isSafeInteger(entry.mode) && entry.mode >= 0 && entry.mode <= 0o7777,
    `policy scanner inventory entry ${index} is malformed`);
    safeRelativePath(entry.relative_path, `policy scanner inventory entry ${index}`);
    if (entry.type === 'file') {
      requireCondition(Number.isSafeInteger(entry.size) && entry.size >= 0
        && HEX64.test(entry.sha256), `policy scanner inventory entry ${index} file is malformed`);
    } else {
      requireCondition(entry.type === 'symlink' && typeof entry.target === 'string'
        && entry.target.length > 0 && !/[\0\n]/.test(entry.target),
      `policy scanner inventory entry ${index} symlink is malformed`);
    }
    return entry;
  });
  const keys = entries.map((entry) => `${entry.artifact}\0${entry.relative_path}`);
  requireCondition(new Set(keys).size === keys.length
    && keys.every((key, index) => index === 0 || keys[index - 1] < key)
    && ARTIFACTS.every((artifact) => entries.some((entry) => entry.artifact === artifact)),
  'policy scanner installed inventory is not canonical and complete');
  const projection = {
    deployment_envelope_sha256: value.deployment_envelope_sha256,
    peekaboo_source_commit: value.peekaboo_source_commit,
    openclaw_source_commit: value.openclaw_source_commit,
    qualification_tools_aggregate_sha256: value.qualification_tools_aggregate_sha256,
    entries,
  };
  requireCondition(value.aggregate_sha256 === aggregateSHA256('installed-inventory', projection),
    'policy scanner installed inventory aggregate is invalid');
  return { retained, value, entries };
}

function artifactRoots(value) {
  exactKeys(value, ARTIFACTS, 'policy scanner artifact roots');
  return Object.fromEntries(ARTIFACTS.map((artifact) => {
    const root = value[artifact];
    requireCondition(typeof root === 'string' && path.isAbsolute(root)
      && fs.realpathSync(root) === root, `policy scanner ${artifact} root is not canonical`);
    const info = fs.lstatSync(root, { bigint: true });
    requireCondition(info.isDirectory() && !info.isSymbolicLink(),
      `policy scanner ${artifact} root is not one real directory`);
    return [artifact, root];
  }));
}

export function classifyPolicyFile(relativePath, mode, bytes) {
  if (bytes.subarray(0, 2).equals(Buffer.from('#!'))
    || SCRIPT_EXTENSIONS.has(path.extname(relativePath).toLowerCase())) return 'script';
  const magic = bytes.length >= 4 ? bytes.subarray(0, 4).toString('hex') : null;
  if (MACH_O_MAGICS.has(magic) || (mode & 0o111) !== 0) return 'executable';
  return 'data';
}

function findingsFor(entry, bytes, kind) {
  if (kind === 'data') return [];
  const searchable = bytes.toString('latin1').toLowerCase();
  return FORBIDDEN_MARKERS.filter(([, expression]) => expression.test(searchable)).map(([family]) => ({
    artifact: entry.artifact,
    relative_path: entry.relative_path,
    family,
  }));
}

function scanInstalledInventory(inventoryPath, rootsValue) {
  const installed = inventory(inventoryPath);
  const roots = artifactRoots(rootsValue);
  const fileCoverage = [];
  const forbiddenFindings = [];
  for (const [index, entry] of installed.entries.entries()) {
    const root = roots[entry.artifact];
    const filePath = path.join(root, entry.relative_path);
    requireCondition(path.relative(root, filePath) === entry.relative_path,
      `policy scanner inventory entry ${index} escapes its artifact root`);
    const info = fs.lstatSync(filePath, { bigint: true });
    const mode = Number(info.mode & 0o7777n);
    requireCondition(mode === entry.mode, `policy scanner inventory entry ${index} mode changed`);
    if (entry.type === 'symlink') {
      requireCondition(info.isSymbolicLink() && fs.readlinkSync(filePath) === entry.target
        && fs.realpathSync(path.dirname(filePath)) === path.dirname(filePath),
        `policy scanner inventory entry ${index} symlink changed`);
      continue;
    }
    requireCondition(info.isFile() && !info.isSymbolicLink() && info.nlink === 1n
      && fs.realpathSync(filePath) === filePath,
      `policy scanner inventory entry ${index} is not one regular file`);
    const retained = readStableFile(filePath, `policy scanner inventory entry ${index}`, {
      privateFile: false,
      maximumBytes: 512 * 1024 * 1024,
    });
    requireCondition(retained.bytes.length === entry.size && retained.sha256 === entry.sha256,
      `policy scanner inventory entry ${index} bytes changed`);
    const kind = classifyPolicyFile(entry.relative_path, entry.mode, retained.bytes);
    fileCoverage.push({
      artifact: entry.artifact,
      relative_path: entry.relative_path,
      sha256: retained.sha256,
      classification: kind,
    });
    forbiddenFindings.push(...findingsFor(entry, retained.bytes, kind));
  }
  const scannerPath = fs.realpathSync(fileURLToPath(import.meta.url));
  const scanner = readStableFile(scannerPath, 'executable policy scanner source', {
    privateFile: false,
  });
  const coverage = {
    scanner_sha256: scanner.sha256,
    installed_inventory_sha256: installed.retained.sha256,
    installed_inventory_aggregate_sha256: installed.value.aggregate_sha256,
    artifact_roots: roots,
    scanned_roots: ARTIFACTS,
    covered_entries: installed.entries,
    file_coverage: fileCoverage,
  };
  return {
    version: 2,
    role: installed.value.role,
    host_uuid: installed.value.host_uuid,
    deployment_envelope_sha256: installed.value.deployment_envelope_sha256,
    scanner_path: scannerPath,
    scanner_sha256: scanner.sha256,
    complete: true,
    installed_inventory_path: installed.retained.path,
    installed_inventory_sha256: installed.retained.sha256,
    installed_inventory_aggregate_sha256: installed.value.aggregate_sha256,
    artifact_roots: roots,
    scanned_roots: ARTIFACTS,
    covered_entries: installed.entries,
    file_coverage: fileCoverage,
    coverage_aggregate_sha256: aggregateSHA256('executable-policy-coverage', coverage),
    scanned_executable_count: fileCoverage.filter((entry) => entry.classification === 'executable').length,
    scanned_script_count: fileCoverage.filter((entry) => entry.classification === 'script').length,
    forbidden_findings: forbiddenFindings,
  };
}

export function generatePolicyReport(specPath, outputPath) {
  const spec = readStableJSON(specPath, 'policy scanner spec').value;
  exactKeys(spec, ['version', 'installed_inventory', 'artifact_roots'], 'policy scanner spec');
  requireCondition(spec.version === 1 && typeof spec.installed_inventory === 'string',
    'policy scanner spec is malformed');
  const report = scanInstalledInventory(spec.installed_inventory, spec.artifact_roots);
  requireCondition(report.forbidden_findings.length === 0,
    'policy scanner found forbidden executable or script markers');
  const written = writePrivateExclusive(outputPath, report);
  return { report, sha256: written.sha256 };
}

export function verifyPolicyReport(inventoryPath, reportPath) {
  const retained = readStableJSON(reportPath, 'executable policy report');
  const report = retained.value;
  requireCondition(report && typeof report === 'object' && !Array.isArray(report)
    && report.installed_inventory_path === inventoryPath,
  'executable policy report names another installed inventory');
  const expected = scanInstalledInventory(inventoryPath, report.artifact_roots);
  requireCondition(expected.forbidden_findings.length === 0,
    'executable policy scan has forbidden findings');
  requireCondition(sameJSON(report, expected),
    'executable policy report differs from a fresh source-owned scan');
  return {
    version: 1,
    valid: true,
    report_sha256: retained.sha256,
    coverage_aggregate_sha256: expected.coverage_aggregate_sha256,
  };
}

function invokedAsScript() {
  return process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
}

if (invokedAsScript()) {
  try {
    const [action, ...argv] = process.argv.slice(2);
    if (action === 'generate') {
      const options = parseOptions(argv, ['spec', 'output']);
      const result = generatePolicyReport(options.spec, options.output);
      process.stdout.write(`${JSON.stringify({ output: options.output, sha256: result.sha256 })}\n`);
    } else if (action === 'verify') {
      const options = parseOptions(argv, ['inventory', 'report']);
      process.stdout.write(`${JSON.stringify(verifyPolicyReport(options.inventory, options.report))}\n`);
    } else {
      throw new Error('usage: executable-policy-scanner.mjs generate|verify ...');
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
