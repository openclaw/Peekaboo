#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  aggregateSHA256 as multiTargetAggregateSHA256,
  validateSuccessfulCertificationSummary,
} from '../finalize-multi-target-certification.mjs';
import {
  aggregateSHA256,
  authenticateLiveBridgeBundle,
  authenticatedBridgeReceiptIdentity,
  controlledFixtureBindings,
  corroboratedObservationTime,
  exactKeys,
  fileReceipt,
  parseOptions,
  readStableJSON,
  readStableJSONLines,
  readStableFile,
  requireCondition,
  requireStableExecutable,
  requireUniqueAuthenticatedBridgeReceipts,
  sameJSON,
  sha256,
  validateControlledFixtureSummary,
  writePrivateExclusive,
} from './lib.mjs';

const QUALIFICATION_TOOL_FILES = [
  'scripts/finalize-multi-target-certification.mjs',
  'scripts/run-live-multi-target-certification.mjs',
  'scripts/final-qualification/README.md',
  'scripts/final-qualification/atomic-publish-no-replace.swift',
  'scripts/final-qualification/executable-policy-scanner.mjs',
  'scripts/final-qualification/integrated-cu-emitter-calibrator.swift',
  'scripts/final-qualification/managed-launch-suspended.c',
  'scripts/final-qualification/lib.mjs',
  'scripts/final-qualification/managed-launcher.mjs',
  'scripts/final-qualification/project-live-bindings.mjs',
  'scripts/final-qualification/process-lifecycle-guard.c',
  'scripts/final-qualification/process-tree-collector.mjs',
  'scripts/final-qualification/publish-coordinator-marker.mjs',
  'scripts/final-qualification/qualification-manifest.mjs',
  'scripts/final-qualification/validate-concurrent-run.mjs',
  'scripts/final-qualification/test/qualification-tools.test.mjs',
  'scripts/multi-target-certification-catalog.json',
  'scripts/support/background-computer-use-probe.swift',
];

function git(directory, arguments_, label, { binary = false } = {}) {
  const result = spawnSync('/usr/bin/git', ['-C', directory, ...arguments_], {
    encoding: binary ? null : 'utf8',
    timeout: 30_000,
    maxBuffer: 512 * 1024 * 1024,
    env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LANG: 'C', LC_ALL: 'C' },
  });
  requireCondition(!result.error && result.status === 0,
    `${label} failed: ${String(result.stderr ?? result.error?.message ?? result.status).trim()}`);
  return result.stdout;
}

function cleanGitStatus(directory, label) {
  const output = git(directory, [
    'status', '--porcelain=v2', '--untracked-files=all', '--ignore-submodules=none',
  ], label);
  requireCondition(output.length === 0, `${label} is not clean`);
}

function validateGitSourceTree(directory, files, sourceCommit, label) {
  const repositoryRoot = git(directory, ['rev-parse', '--show-toplevel'], `${label} repository`)
    .trim();
  requireCondition(repositoryRoot === directory && fs.realpathSync(repositoryRoot) === directory,
    `${label} directory is not the canonical Git repository root`);
  const headCommit = git(directory, ['rev-parse', '--verify', 'HEAD^{commit}'], `${label} HEAD`)
    .trim();
  requireCondition(headCommit === sourceCommit, `${label} commit is not the exact repository HEAD`);
  cleanGitStatus(directory, `${label} pre-read tree`);
  for (const [index, entry] of files.entries()) {
    const listing = git(
      directory,
      ['ls-tree', '-z', sourceCommit, '--', entry.relative_path],
      `${label} file ${index} Git entry`,
      { binary: true },
    );
    const match = listing.toString('utf8').match(/^100(?:644|755) blob ([0-9a-f]{40})\t([^\0]+)\0$/);
    requireCondition(match && match[2] === entry.relative_path,
      `${label} file ${index} is not one tracked regular Git blob`);
    const blob = git(
      directory,
      ['cat-file', 'blob', match[1]],
      `${label} file ${index} Git blob`,
      { binary: true },
    );
    const current = readStableFile(
      path.join(directory, entry.relative_path),
      `${label} file ${index} working tree`,
      { privateFile: false, maximumBytes: 512 * 1024 * 1024 },
    );
    requireCondition(blob.equals(current.bytes)
      && current.bytes.length === entry.size && current.sha256 === entry.sha256,
    `${label} file ${index} differs from commit ${sourceCommit}`);
  }
  requireCondition(
    git(directory, ['rev-parse', '--verify', 'HEAD^{commit}'], `${label} final HEAD`).trim()
      === sourceCommit,
    `${label} HEAD changed during validation`,
  );
  cleanGitStatus(directory, `${label} post-read tree`);
}

function sourceAggregate(files) {
  return sha256(Buffer.from(files.map((entry) => (
    `${entry.sha256}  ${entry.relative_path}\n`
  )).join(''), 'utf8'));
}

function sourceFile(directory, relativePath, label) {
  requireCondition(typeof relativePath === 'string' && relativePath.length > 0
    && !path.isAbsolute(relativePath) && !relativePath.split('/').includes('..'),
  `${label} relative path is unsafe`);
  const absolute = path.join(directory, relativePath);
  requireCondition(path.relative(directory, absolute) === relativePath,
    `${label} escapes its source directory`);
  const retained = readStableFile(absolute, label, { privateFile: false });
  return { relative_path: relativePath, size: retained.bytes.length, sha256: retained.sha256 };
}

export function generateSourceManifest(directory, relativeFiles, outputPath, sourceCommit) {
  requireCondition(path.isAbsolute(directory) && fs.realpathSync(directory) === directory,
    'source-manifest directory must be canonical absolute');
  requireCondition(SOURCE_COMMIT.test(sourceCommit), 'source-manifest commit must be full lowercase hex');
  requireCondition(Array.isArray(relativeFiles) && relativeFiles.length > 0
    && new Set(relativeFiles).size === relativeFiles.length,
  'source-manifest files must be one nonempty unique list');
  const files = relativeFiles.map((relativePath, index) => (
    sourceFile(directory, relativePath, `source-manifest file ${index}`)
  ));
  validateGitSourceTree(directory, files, sourceCommit, 'source manifest');
  const value = {
    version: 2,
    source_commit: sourceCommit,
    directory,
    files,
    aggregate_sha256: sourceAggregate(files),
  };
  const written = writePrivateExclusive(outputPath, value);
  return { value, sha256: written.sha256 };
}

function semanticSourceManifest(filePath, label, expectedFiles = null, expectedSourceCommit = null) {
  const retained = readStableJSON(filePath, label);
  exactKeys(retained.value, [
    'version', 'source_commit', 'directory', 'files', 'aggregate_sha256',
  ], label);
  requireCondition(retained.value.version === 2 && SOURCE_COMMIT.test(retained.value.source_commit)
    && path.isAbsolute(retained.value.directory)
    && fs.realpathSync(retained.value.directory) === retained.value.directory
    && Array.isArray(retained.value.files) && retained.value.files.length > 0,
  `${label} is malformed`);
  const files = retained.value.files.map((entry, index) => {
    exactKeys(entry, ['relative_path', 'size', 'sha256'], `${label}.files[${index}]`);
    const current = sourceFile(retained.value.directory, entry.relative_path, `${label}.files[${index}]`);
    requireCondition(sameJSON(current, entry), `${label}.files[${index}] changed`);
    return current;
  });
  requireCondition(new Set(files.map((entry) => entry.relative_path)).size === files.length,
    `${label} reuses a relative path`);
  if (expectedFiles !== null) {
    requireCondition(sameJSON(files.map((entry) => entry.relative_path), expectedFiles),
      `${label} file list is not canonical`);
  }
  if (expectedSourceCommit !== null) {
    requireCondition(retained.value.source_commit === expectedSourceCommit,
      `${label} source commit differs from installed Peekaboo`);
  }
  requireCondition(sourceAggregate(files) === retained.value.aggregate_sha256,
    `${label} aggregate is invalid`);
  validateGitSourceTree(
    retained.value.directory,
    files,
    retained.value.source_commit,
    label,
  );
  requireCondition((retained.info.mode & 0o222n) === 0n,
    `${label} must be non-writable before qualification`);
  return { retained, value: retained.value };
}

export function verifySourceManifest(filePath, expectedFiles = null, expectedSourceCommit = null) {
  return semanticSourceManifest(
    filePath,
    'source manifest verification',
    expectedFiles,
    expectedSourceCommit,
  );
}

function immutableReceipt(filePath, label) {
  const retained = readStableFile(filePath, label);
  requireCondition((retained.info.mode & 0o222n) === 0n, `${label} must be non-writable`);
  return { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 };
}

function immutableRetainedReceipt(retained, label) {
  requireCondition((retained.info.mode & 0o222n) === 0n, `${label} must be non-writable`);
  return { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 };
}

function stableSourceReceipt(filePath, label) {
  const retained = readStableFile(filePath, label, { privateFile: false });
  return { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 };
}

function executableIdentity(filePath, label) {
  const retained = requireStableExecutable(filePath, label, { allowRootOwner: true });
  const verify = spawnSync('/usr/bin/codesign', ['--verify', '--strict', retained.path], {
    encoding: 'utf8', timeout: 10_000, maxBuffer: 1024 * 1024,
    env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LANG: 'C', LC_ALL: 'C' },
  });
  requireCondition(!verify.error && verify.status === 0, `${label} signature is invalid`);
  const display = spawnSync('/usr/bin/codesign', ['-dvvv', retained.path], {
    encoding: 'utf8', timeout: 10_000, maxBuffer: 1024 * 1024,
    env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LANG: 'C', LC_ALL: 'C' },
  });
  const text = `${display.stdout ?? ''}\n${display.stderr ?? ''}`;
  const matches = [...text.matchAll(/^CDHash=([0-9a-f]{40})$/gm)].map((match) => match[1]);
  requireCondition(!display.error && display.status === 0 && matches.length === 1,
    `${label} CDHash is invalid`);
  return { retained, codeSignatureHash: matches[0] };
}

function semanticPeekabooArtifactManifest(filePath, label, expectedSourceCommit) {
  const retained = readStableJSON(filePath, label);
  const value = retained.value;
  requireCondition(Number.isSafeInteger(value.schema) && value.schema >= 6
    && value.phase === 'candidate_verified_not_installed'
    && value.source_commit === expectedSourceCommit
    && value.version === '4.2.1'
    && value.app?.source_commit === expectedSourceCommit
    && value.playground?.source_commit === expectedSourceCommit
    && SHA256.test(value.cli?.sha256 ?? '')
    && CODE_SIGNATURE_HASH.test(value.cli?.cdhash ?? '')
    && value.monitor?.source_commit === expectedSourceCommit
    && value.monitor?.source_path === 'scripts/support/background-computer-use-probe.swift'
    && SHA256.test(value.monitor?.source_sha256 ?? '')
    && SHA256.test(value.monitor?.executable_sha256 ?? '')
    && CODE_SIGNATURE_HASH.test(value.monitor?.cdhash ?? '')
    && SHA256.test(value.app?.zip_sha256 ?? '')
    && CODE_SIGNATURE_HASH.test(value.app?.cdhash ?? '')
    && SHA256.test(value.playground?.zip_sha256 ?? '')
    && CODE_SIGNATURE_HASH.test(value.playground?.cdhash ?? '')
    && value.verification?.cli_source === true
    && value.verification?.cli_native_only === true
    && value.verification?.monitor_source === true
    && value.verification?.monitor_native_only === true
    && value.verification?.app_source === true
    && value.verification?.app_native_only === true
    && value.verification?.playground_native_only === true,
  `${label} is not one complete source-bound Peekaboo artifact manifest`);
  return {
    value,
    receipt: immutableRetainedReceipt(retained, label),
  };
}

function semanticOpenClawArtifactReceipt(filePath, label, expected) {
  const retained = readStableJSON(filePath, label);
  const value = retained.value;
  exactKeys(value, [
    'schemaVersion', 'kind', 'archive', 'archiveSha256', 'archiveChecksum', 'installer',
    'installerSha256', 'installerChecksum', 'sourceCommit', 'peekabooCommit', 'version',
    'build', 'authority', 'teamIdentifier', 'cdhashes', 'architectures',
    'entitlementsSha256', 'notarizationId',
  ], label);
  exactKeys(value.cdhashes, ['arm64', 'x86_64'], `${label}.cdhashes`);
  exactKeys(value.architectures, ['main', 'helper'], `${label}.architectures`);
  exactKeys(value.entitlementsSha256, ['main', 'helper'], `${label}.entitlementsSha256`);
  requireCondition(value.schemaVersion === 1 && value.kind === 'openclaw-elevation-artifact'
    && value.sourceCommit === expected.openclawSourceCommit
    && value.peekabooCommit === expected.peekabooSourceCommit
    && typeof value.archive === 'string' && value.archive.length > 0
    && value.archiveChecksum === `${value.archive}.sha256`
    && SHA256.test(value.archiveSha256)
    && typeof value.installer === 'string' && value.installer.length > 0
    && value.installerChecksum === `${value.installer}.sha256`
    && SHA256.test(value.installerSha256)
    && typeof value.version === 'string' && value.version.length > 0
    && typeof value.build === 'string' && value.build.length > 0
    && typeof value.authority === 'string' && value.authority.length > 0
    && TEAM.test(value.teamIdentifier)
    && CODE_SIGNATURE_HASH.test(value.cdhashes.arm64)
    && CODE_SIGNATURE_HASH.test(value.cdhashes.x86_64)
    && typeof value.architectures.main === 'string' && value.architectures.main.length > 0
    && typeof value.architectures.helper === 'string' && value.architectures.helper.length > 0
    && SHA256.test(value.entitlementsSha256.main)
    && SHA256.test(value.entitlementsSha256.helper)
    && typeof value.notarizationId === 'string'
    && /^[0-9a-fA-F-]{36}$/.test(value.notarizationId),
  `${label} is not one authenticated source-bound OpenClaw artifact receipt`);
  return {
    value,
    receipt: immutableRetainedReceipt(retained, label),
  };
}

function semanticArtifactBinding(filePath, label, deployment) {
  const retained = readStableJSON(filePath, label);
  const value = retained.value;
  exactKeys(value, [
    'version', 'deployment_envelope_sha256', 'peekaboo_source_commit',
    'openclaw_source_commit', 'qualification_tools_aggregate_sha256',
    'peekaboo_artifact_manifest', 'openclaw_artifact_receipt',
  ], label);
  exactKeys(value.peekaboo_artifact_manifest, ['path', 'sha256'],
    `${label}.peekaboo_artifact_manifest`);
  exactKeys(value.openclaw_artifact_receipt, ['path', 'sha256'],
    `${label}.openclaw_artifact_receipt`);
  requireCondition(value.version === 2
    && value.deployment_envelope_sha256 === deployment.installed[0].envelopeSHA256
    && value.peekaboo_source_commit === deployment.peekabooSourceCommit
    && value.openclaw_source_commit === deployment.installed[0].projection.openclaw_source_commit
    && value.qualification_tools_aggregate_sha256
      === deployment.qualificationToolsAggregateSHA256,
  `${label} differs from deployed envelope/source/tool identity`);
  const peekaboo = semanticPeekabooArtifactManifest(
    value.peekaboo_artifact_manifest.path,
    `${label} Peekaboo artifact manifest`,
    value.peekaboo_source_commit,
  );
  const openclaw = semanticOpenClawArtifactReceipt(
    value.openclaw_artifact_receipt.path,
    `${label} OpenClaw artifact receipt`,
    {
      openclawSourceCommit: value.openclaw_source_commit,
      peekabooSourceCommit: value.peekaboo_source_commit,
    },
  );
  requireCondition(value.peekaboo_artifact_manifest.sha256 === peekaboo.receipt.sha256
    && value.openclaw_artifact_receipt.sha256 === openclaw.receipt.sha256,
  `${label} nested artifact digest is invalid`);
  return {
    evidence: {
      binding: immutableRetainedReceipt(retained, label),
      peekaboo_artifact_manifest: peekaboo.receipt,
      openclaw_artifact_receipt: openclaw.receipt,
    },
    peekaboo: peekaboo.value,
    openclaw: openclaw.value,
  };
}

function semanticElevationInstallReceipt(filePath, label, installed) {
  const retained = readStableJSON(filePath, label);
  const value = retained.value;
  exactKeys(value, [
    'schemaVersion', 'kind', 'transactionState', 'transactionId', 'sourceCommit',
    'peekabooCommit', 'archiveSha256', 'artifactReceiptSha256', 'installerSha256',
    'cdhashes', 'nodeId', 'nodeProfile', 'appPath', 'stateDir', 'configPath',
    'backupPath', 'backupCDHashes', 'plistPath', 'previousPlist',
    'previousPlistSha256', 'previousPlistWasLoaded', 'previousReceipt',
    'previousReceiptSha256', 'migration', 'adoptedApp',
  ], label);
  exactKeys(value.cdhashes, ['arm64', 'x86_64'], `${label}.cdhashes`);
  exactKeys(value.backupCDHashes, ['arm64', 'x86_64'], `${label}.backupCDHashes`);
  exactKeys(value.adoptedApp, ['wasRunning', 'attachOnly'], `${label}.adoptedApp`);
  requireCondition(value.schemaVersion === 3 && value.kind === 'openclaw-elevation-install'
    && value.transactionState === 'installed'
    && typeof value.transactionId === 'string' && /^[0-9A-F-]{36}$/.test(value.transactionId)
    && value.sourceCommit === installed.projection.openclaw_source_commit
    && value.peekabooCommit === installed.projection.peekaboo_source_commit
    && SHA256.test(value.archiveSha256)
    && SHA256.test(value.artifactReceiptSha256)
    && SHA256.test(value.installerSha256)
    && CODE_SIGNATURE_HASH.test(value.cdhashes.arm64)
    && CODE_SIGNATURE_HASH.test(value.cdhashes.x86_64)
    && typeof value.nodeId === 'string' && value.nodeId.length >= 8 && value.nodeId.length <= 256
    && /^[A-Za-z0-9._:-]+$/.test(value.nodeId)
    && ['primary', 'node'].includes(value.nodeProfile)
    && value.appPath === '/Applications/OpenClaw.app'
    && typeof value.stateDir === 'string' && path.isAbsolute(value.stateDir)
    && typeof value.configPath === 'string' && path.isAbsolute(value.configPath)
    && typeof value.plistPath === 'string' && path.isAbsolute(value.plistPath)
    && typeof value.previousPlistWasLoaded === 'boolean'
    && (value.migration === null || (value.migration && typeof value.migration === 'object'))
    && typeof value.adoptedApp.wasRunning === 'boolean'
    && typeof value.adoptedApp.attachOnly === 'boolean',
  `${label} is not one installed source-bound elevation receipt`);
  return {
    value,
    receipt: { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 },
  };
}

const DEPLOYMENT_HOST_ROLES = ['local', 'studio'];
const PROCESS_TREE_EPOCHS = ['before', 'during', 'after'];
const INSTALLED_ARTIFACTS = ['openclaw_app', 'peekaboo_app', 'peekaboo_cli'];
const PROCESS_ROOT_CLASSES = ['agent', 'bridge', 'coordinator', 'elevation', 'fixture', 'integrated_cu'];
const REQUIRED_ROOT_CLASSES = {
  local: {
    before: ['bridge', 'elevation', 'integrated_cu'],
    during: ['agent', 'bridge', 'coordinator', 'elevation', 'fixture', 'integrated_cu'],
    after: ['bridge', 'elevation', 'integrated_cu'],
  },
  studio: {
    before: ['bridge', 'elevation'],
    during: ['bridge', 'elevation', 'fixture'],
    after: ['bridge', 'elevation'],
  },
};
const HOST_UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;
const SOURCE_COMMIT = /^[0-9a-f]{40}$/;
const CODE_SIGNATURE_HASH = /^[0-9a-f]{40}$/;
const SHA256 = /^[0-9a-f]{64}$/;
const TEAM = /^[A-Z0-9]{10}$/;

function safeRelativePath(value, label) {
  requireCondition(typeof value === 'string' && value.length > 0 && !path.isAbsolute(value)
    && !value.includes('\0') && !value.includes('\n')
    && !value.split('/').some((component) => component === '' || component === '.' || component === '..'),
  `${label} must be one safe relative path`);
  return value;
}

function installedEntry(value, label) {
  requireCondition(value && typeof value === 'object' && !Array.isArray(value),
    `${label} must be one object`);
  const common = ['artifact', 'relative_path', 'type', 'mode'];
  const specific = value.type === 'file' ? ['size', 'sha256']
    : value.type === 'symlink' ? ['target'] : [];
  exactKeys(value, [...common, ...specific], label);
  requireCondition(INSTALLED_ARTIFACTS.includes(value.artifact), `${label} artifact is unsupported`);
  safeRelativePath(value.relative_path, `${label}.relative_path`);
  requireCondition(Number.isSafeInteger(value.mode) && value.mode >= 0 && value.mode <= 0o7777,
    `${label} mode is invalid`);
  if (value.type === 'file') {
    requireCondition(Number.isSafeInteger(value.size) && value.size >= 0 && SHA256.test(value.sha256),
      `${label} file metadata is invalid`);
  } else if (value.type === 'symlink') {
    requireCondition(typeof value.target === 'string' && value.target.length > 0
      && !value.target.includes('\0') && !value.target.includes('\n'),
    `${label} symlink target is invalid`);
  } else {
    requireCondition(false, `${label} type is unsupported`);
  }
  return value;
}

function installedInventoryProjection(value) {
  return {
    deployment_envelope_sha256: value.deployment_envelope_sha256,
    peekaboo_source_commit: value.peekaboo_source_commit,
    openclaw_source_commit: value.openclaw_source_commit,
    qualification_tools_aggregate_sha256: value.qualification_tools_aggregate_sha256,
    entries: value.entries,
  };
}

function semanticInstalledInventory(filePath, label) {
  const retained = readStableJSON(filePath, label, { maximumBytes: 256 * 1024 * 1024 });
  const value = retained.value;
  exactKeys(value, [
    'version', 'role', 'host_uuid', 'hostname', 'deployment_envelope_sha256',
    'peekaboo_source_commit', 'openclaw_source_commit', 'qualification_tools_aggregate_sha256',
    'elevation_receipt_sha256', 'captured_at_milliseconds', 'entries', 'aggregate_sha256',
  ], label);
  requireCondition(value.version === 1 && DEPLOYMENT_HOST_ROLES.includes(value.role)
    && HOST_UUID.test(value.host_uuid)
    && typeof value.hostname === 'string' && /^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$/.test(value.hostname)
    && SHA256.test(value.deployment_envelope_sha256)
    && SOURCE_COMMIT.test(value.peekaboo_source_commit)
    && SOURCE_COMMIT.test(value.openclaw_source_commit)
    && SHA256.test(value.qualification_tools_aggregate_sha256)
    && SHA256.test(value.elevation_receipt_sha256)
    && Number.isSafeInteger(value.captured_at_milliseconds) && value.captured_at_milliseconds > 0
    && Array.isArray(value.entries) && value.entries.length > 0,
  `${label} is malformed`);
  const entries = value.entries.map((entry, index) => installedEntry(entry, `${label}.entries[${index}]`));
  const keys = entries.map((entry) => `${entry.artifact}\0${entry.relative_path}`);
  requireCondition(new Set(keys).size === keys.length, `${label} contains duplicate installed paths`);
  requireCondition(keys.every((key, index) => index === 0 || keys[index - 1] < key),
    `${label} entries are not in canonical order`);
  requireCondition(INSTALLED_ARTIFACTS.every((artifact) => (
    entries.some((entry) => entry.artifact === artifact)
  )), `${label} does not cover all installed artifacts`);
  const projection = installedInventoryProjection(value);
  requireCondition(value.aggregate_sha256 === aggregateSHA256('installed-inventory', projection),
    `${label} aggregate is invalid`);
  return {
    role: value.role,
    hostUUID: value.host_uuid,
    envelopeSHA256: value.deployment_envelope_sha256,
    aggregateSHA256: value.aggregate_sha256,
    elevationReceiptSHA256: value.elevation_receipt_sha256,
    qualificationToolsAggregateSHA256: value.qualification_tools_aggregate_sha256,
    capturedAtMilliseconds: value.captured_at_milliseconds,
    projection,
    receipt: { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 },
  };
}

function processIdentity(value, label) {
  exactKeys(value, ['pid', 'start_identity'], label);
  requireCondition(Number.isSafeInteger(value.pid) && value.pid > 0
    && typeof value.start_identity === 'string' && /^[1-9][0-9]*$/.test(value.start_identity),
  `${label} is malformed`);
  return `${value.pid}:${value.start_identity}`;
}

function processRoot(value, label) {
  exactKeys(value, ['root_id', 'root_class', 'pid', 'start_identity', 'code_signature_hash'], label);
  requireCondition(typeof value.root_id === 'string' && /^[a-z][a-z0-9_-]{0,63}$/.test(value.root_id)
    && PROCESS_ROOT_CLASSES.includes(value.root_class)
    && CODE_SIGNATURE_HASH.test(value.code_signature_hash),
  `${label} authority is malformed`);
  return {
    rootID: value.root_id,
    rootClass: value.root_class,
    pid: value.pid,
    startIdentity: value.start_identity,
    identity: processIdentity(
      { pid: value.pid, start_identity: value.start_identity },
      `${label} process`,
    ),
    codeSignatureHash: value.code_signature_hash,
  };
}

function processRecord(value, label) {
  exactKeys(value, [
    'pid', 'start_identity', 'parent_pid', 'parent_start_identity', 'executable_path',
    'executable_name', 'executable_sha256', 'code_signature_hash', 'signing_identifier', 'team_id',
  ], label);
  requireCondition(Number.isSafeInteger(value.pid) && value.pid > 0
    && typeof value.start_identity === 'string' && /^[1-9][0-9]*$/.test(value.start_identity),
  `${label} identity is malformed`);
  const identity = `${value.pid}:${value.start_identity}`;
  const parentIsNull = value.parent_pid === null && value.parent_start_identity === null;
  const parentIsValid = Number.isSafeInteger(value.parent_pid) && value.parent_pid > 0
    && typeof value.parent_start_identity === 'string'
    && /^[1-9][0-9]*$/.test(value.parent_start_identity);
  requireCondition(parentIsNull || parentIsValid, `${label} parent identity is malformed`);
  requireCondition(typeof value.executable_path === 'string' && path.isAbsolute(value.executable_path)
    && !value.executable_path.includes('\0') && !value.executable_path.includes('\n')
    && typeof value.executable_name === 'string' && value.executable_name.length > 0
    && path.basename(value.executable_path) === value.executable_name
    && SHA256.test(value.executable_sha256)
    && CODE_SIGNATURE_HASH.test(value.code_signature_hash)
    && (value.signing_identifier === null || (
      typeof value.signing_identifier === 'string' && value.signing_identifier.length > 0
        && !/[\0\n]/.test(value.signing_identifier)
    ))
    && (value.team_id === null || TEAM.test(value.team_id)),
  `${label} executable identity is malformed`);
  return {
    identity,
    parent: parentIsNull ? null : `${value.parent_pid}:${value.parent_start_identity}`,
    value,
  };
}

function forbiddenProcessMarker(process) {
  const executableName = process.executable_name.toLowerCase();
  const executablePath = process.executable_path.toLowerCase();
  const signingIdentifier = (process.signing_identifier ?? '').toLowerCase();
  const exactNames = new Set([
    'cua-driver', 'osascript', 'osascriptd', 'applescript', 'jxa', 'osa', 'lume',
    'prl_disp_service', 'prl_naptd', 'vmware-vmx', 'virtualboxvm', 'vncserver',
    'screensharingagent', 'screen sharing', 'utm', 'tart', 'vfkit', 'qemu',
    'remote desktop',
  ]);
  if (exactNames.has(executableName)) return executableName;
  const pathPattern = /(^|[\/._ -])(cua-driver|osascript|applescript|jxa|lume|parallels|prl_|vmware|virtualbox|virtualization|utm|tart|vfkit|qemu|vnc|screen sharing|screensharing|remote desktop|remotedesktop)([\/._ -]|$)/;
  if (pathPattern.test(executablePath)) return executablePath;
  const identifierPattern = /(^|[.-])(cua-driver|osascript|applescript|jxa|lume|parallels|vmware|virtualbox|virtualization|utm|tart|vfkit|qemu|vnc|screensharing|remotedesktop)([.-]|$)/;
  if (identifierPattern.test(signingIdentifier)) return signingIdentifier;
  return null;
}

function semanticProcessTree(filePath, label) {
  const retained = readStableJSON(filePath, label, { maximumBytes: 256 * 1024 * 1024 });
  const value = retained.value;
  exactKeys(value, [
    'version', 'role', 'host_uuid', 'deployment_envelope_sha256', 'epoch', 'scope',
    'requested_observation_milliseconds', 'target_sample_interval_milliseconds',
    'coverage_started_at_milliseconds', 'final_sample_started_at_milliseconds',
    'coverage_completed_at_milliseconds', 'captured_at_milliseconds',
    'sample_count', 'maximum_sample_gap_milliseconds',
    'observed_maximum_sample_gap_milliseconds', 'continuous_lifecycle_observation',
    'lifecycle_guard_sha256', 'lifecycle_guard_binary_sha256',
    'lifecycle_started_at_milliseconds',
    'lifecycle_completed_at_milliseconds', 'lifecycle_watched_pids',
    'lifecycle_event_count', 'collector_sha256', 'complete',
    'monitor_executable_path', 'monitor_executable_sha256', 'monitor_code_signature_hash',
    'roots', 'processes',
  ], label);
  requireCondition(value.version === 3 && DEPLOYMENT_HOST_ROLES.includes(value.role)
    && HOST_UUID.test(value.host_uuid) && SHA256.test(value.deployment_envelope_sha256)
    && PROCESS_TREE_EPOCHS.includes(value.epoch) && value.scope === 'task_owned_descendants'
    && Number.isSafeInteger(value.requested_observation_milliseconds)
    && value.requested_observation_milliseconds >= 50
    && value.requested_observation_milliseconds <= 7_200_000
    && Number.isSafeInteger(value.target_sample_interval_milliseconds)
    && value.target_sample_interval_milliseconds >= 5
    && value.target_sample_interval_milliseconds <= 100
    && Number.isSafeInteger(value.coverage_started_at_milliseconds)
    && value.coverage_started_at_milliseconds > 0
    && Number.isSafeInteger(value.final_sample_started_at_milliseconds)
    && value.final_sample_started_at_milliseconds
      >= value.coverage_started_at_milliseconds + value.requested_observation_milliseconds
    && Number.isSafeInteger(value.coverage_completed_at_milliseconds)
    && value.coverage_completed_at_milliseconds >= value.final_sample_started_at_milliseconds
    && Number.isSafeInteger(value.captured_at_milliseconds) && value.captured_at_milliseconds > 0
    && value.captured_at_milliseconds >= value.coverage_completed_at_milliseconds
    && Number.isSafeInteger(value.sample_count) && value.sample_count >= 2
    && Number.isSafeInteger(value.maximum_sample_gap_milliseconds)
    && value.maximum_sample_gap_milliseconds >= value.target_sample_interval_milliseconds
    && value.maximum_sample_gap_milliseconds <= 10_000
    && Number.isSafeInteger(value.observed_maximum_sample_gap_milliseconds)
    && value.observed_maximum_sample_gap_milliseconds >= 0
    && value.observed_maximum_sample_gap_milliseconds
      <= value.maximum_sample_gap_milliseconds
    && value.sample_count >= Math.ceil(
      value.requested_observation_milliseconds / value.maximum_sample_gap_milliseconds,
    ) + 1
    && value.continuous_lifecycle_observation === true
    && SHA256.test(value.lifecycle_guard_sha256)
    && SHA256.test(value.lifecycle_guard_binary_sha256)
    && Number.isSafeInteger(value.lifecycle_started_at_milliseconds)
    && value.lifecycle_started_at_milliseconds > 0
    && value.lifecycle_started_at_milliseconds <= value.coverage_started_at_milliseconds
    && Number.isSafeInteger(value.lifecycle_completed_at_milliseconds)
    && value.lifecycle_completed_at_milliseconds >= value.captured_at_milliseconds
    && Array.isArray(value.lifecycle_watched_pids) && value.lifecycle_watched_pids.length > 0
    && value.lifecycle_watched_pids.every((pid) => Number.isSafeInteger(pid) && pid > 0)
    && new Set(value.lifecycle_watched_pids).size === value.lifecycle_watched_pids.length
    && value.lifecycle_watched_pids.every((pid, index) => index === 0
      || value.lifecycle_watched_pids[index - 1] < pid)
    && value.lifecycle_event_count === 0
    && SHA256.test(value.collector_sha256)
    && typeof value.monitor_executable_path === 'string'
    && path.isAbsolute(value.monitor_executable_path)
    && SHA256.test(value.monitor_executable_sha256)
    && CODE_SIGNATURE_HASH.test(value.monitor_code_signature_hash)
    && value.complete === true
    && Array.isArray(value.roots) && value.roots.length > 0
    && Array.isArray(value.processes) && value.processes.length > 0,
  `${label} is malformed`);
  const roots = value.roots.map((root, index) => processRoot(root, `${label}.roots[${index}]`));
  requireCondition(new Set(roots.map((root) => root.rootID)).size === roots.length,
    `${label} repeats a root ID`);
  requireCondition(new Set(roots.map((root) => root.identity)).size === roots.length,
    `${label} repeats a root identity`);
  requireCondition(roots.every((root, index) => index === 0 || roots[index - 1].rootID < root.rootID),
    `${label} roots are not in canonical order`);
  const records = value.processes.map((process, index) => (
    processRecord(process, `${label}.processes[${index}]`)
  ));
  const byIdentity = new Map(records.map((record) => [record.identity, record]));
  requireCondition(byIdentity.size === records.length, `${label} repeats a process identity`);
  requireCondition(new Set(records.map((record) => record.value.pid)).size === records.length,
    `${label} contains PID reuse in one epoch`);
  requireCondition(roots.every((root) => byIdentity.has(root.identity)),
    `${label} root is absent from the tree`);
  requireCondition(roots.every((root) => (
    byIdentity.get(root.identity).value.code_signature_hash === root.codeSignatureHash
  )), `${label} root code identity differs from its process record`);
  const rootSet = new Set(roots.map((root) => root.identity));
  for (const record of records) {
    if (!rootSet.has(record.identity)) {
      requireCondition(record.parent !== null && byIdentity.has(record.parent),
        `${label} contains a process outside the task-owned descendant tree`);
    }
    requireCondition(forbiddenProcessMarker(record.value) === null,
      `${label} contains forbidden task-owned process ${record.value.executable_name}`);
  }
  const reachable = new Set(roots.map((root) => root.identity));
  let changed = true;
  while (changed) {
    changed = false;
    for (const record of records) {
      if (!reachable.has(record.identity) && record.parent !== null && reachable.has(record.parent)) {
        reachable.add(record.identity);
        changed = true;
      }
    }
  }
  requireCondition(reachable.size === records.length,
    `${label} contains a cycle or process outside its declared task roots`);
  requireCondition(sameJSON(
    value.lifecycle_watched_pids,
    records.map((record) => record.value.pid),
  ), `${label} continuous lifecycle coverage differs from its process inventory`);
  return {
    role: value.role,
    hostUUID: value.host_uuid,
    envelopeSHA256: value.deployment_envelope_sha256,
    epoch: value.epoch,
    coverageStartedAtMilliseconds: value.coverage_started_at_milliseconds,
    finalSampleStartedAtMilliseconds: value.final_sample_started_at_milliseconds,
    coverageCompletedAtMilliseconds: value.coverage_completed_at_milliseconds,
    capturedAtMilliseconds: value.captured_at_milliseconds,
    collectorSHA256: value.collector_sha256,
    lifecycleGuardSHA256: value.lifecycle_guard_sha256,
    lifecycleGuardBinarySHA256: value.lifecycle_guard_binary_sha256,
    monitorExecutablePath: value.monitor_executable_path,
    monitorExecutableSHA256: value.monitor_executable_sha256,
    monitorCodeSignatureHash: value.monitor_code_signature_hash,
    roots,
    records,
    byIdentity,
    receipt: { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 },
  };
}

function verifyExecutablePolicyReport(scanner, installed, filePath, expectedReportSHA256, label) {
  const result = spawnSync(process.execPath, [
    scanner.path,
    'verify',
    '--inventory', installed.receipt.path,
    '--report', filePath,
  ], {
    encoding: 'utf8',
    timeout: 120_000,
    maxBuffer: 16 * 1024 * 1024,
    env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LANG: 'C', LC_ALL: 'C' },
  });
  requireCondition(!result.error && result.status === 0,
    `${label} source-owned scanner execution failed: ${String(result.stderr ?? '').trim()}`);
  let verification;
  try {
    verification = JSON.parse(result.stdout);
  } catch {
    requireCondition(false, `${label} source-owned scanner verification is not JSON`);
  }
  exactKeys(verification, [
    'version', 'valid', 'report_sha256', 'coverage_aggregate_sha256',
  ], `${label} source-owned scanner verification`);
  requireCondition(verification.version === 1 && verification.valid === true
    && verification.report_sha256 === expectedReportSHA256
    && SHA256.test(verification.coverage_aggregate_sha256),
  `${label} source-owned scanner did not authenticate its report`);
  return verification;
}

function semanticExecutablePolicyReport(filePath, label, installed, scanner) {
  const retained = readStableJSON(filePath, label);
  const value = retained.value;
  exactKeys(value, [
    'version', 'role', 'host_uuid', 'deployment_envelope_sha256', 'scanner_path',
    'scanner_sha256', 'complete', 'installed_inventory_path', 'installed_inventory_sha256',
    'installed_inventory_aggregate_sha256', 'artifact_roots', 'scanned_roots',
    'covered_entries', 'file_coverage', 'coverage_aggregate_sha256',
    'scanned_executable_count', 'scanned_script_count', 'forbidden_findings',
  ], label);
  requireCondition(value.version === 2 && DEPLOYMENT_HOST_ROLES.includes(value.role)
    && HOST_UUID.test(value.host_uuid) && SHA256.test(value.deployment_envelope_sha256)
    && value.scanner_path === scanner.path && value.scanner_sha256 === scanner.sha256
    && value.complete === true
    && value.installed_inventory_path === installed.receipt.path
    && value.installed_inventory_sha256 === installed.receipt.sha256
    && SHA256.test(value.installed_inventory_aggregate_sha256)
    && value.artifact_roots && typeof value.artifact_roots === 'object'
    && sameJSON(value.scanned_roots, INSTALLED_ARTIFACTS)
    && Array.isArray(value.covered_entries) && Array.isArray(value.file_coverage)
    && SHA256.test(value.coverage_aggregate_sha256)
    && Number.isSafeInteger(value.scanned_executable_count) && value.scanned_executable_count > 0
    && Number.isSafeInteger(value.scanned_script_count) && value.scanned_script_count > 0
    && Array.isArray(value.forbidden_findings) && value.forbidden_findings.length === 0,
  `${label} is not one complete clean executable/script policy report`);
  requireCondition(value.installed_inventory_aggregate_sha256 === installed.aggregateSHA256,
    `${label} installed inventory aggregate is not bound`);
  requireCondition(sameJSON(value.covered_entries, installed.projection.entries),
    `${label} does not cover the complete installed inventory`);
  const installedFiles = installed.projection.entries.filter((entry) => entry.type === 'file');
  requireCondition(value.file_coverage.length === installedFiles.length,
    `${label} does not classify every installed file`);
  const classifications = ['data', 'executable', 'script'];
  value.file_coverage.forEach((entry, index) => {
    exactKeys(entry, ['artifact', 'relative_path', 'sha256', 'classification'],
      `${label}.file_coverage[${index}]`);
    const installedFile = installedFiles[index];
    requireCondition(entry.artifact === installedFile.artifact
      && entry.relative_path === installedFile.relative_path
      && entry.sha256 === installedFile.sha256
      && classifications.includes(entry.classification),
    `${label}.file_coverage[${index}] differs from its installed file`);
  });
  requireCondition(value.scanned_executable_count === value.file_coverage.filter((entry) => (
    entry.classification === 'executable'
  )).length, `${label} executable count differs from per-file coverage`);
  requireCondition(value.scanned_script_count === value.file_coverage.filter((entry) => (
    entry.classification === 'script'
  )).length, `${label} script count differs from per-file coverage`);
  const coverage = {
    scanner_sha256: value.scanner_sha256,
    installed_inventory_sha256: value.installed_inventory_sha256,
    installed_inventory_aggregate_sha256: value.installed_inventory_aggregate_sha256,
    artifact_roots: value.artifact_roots,
    scanned_roots: value.scanned_roots,
    covered_entries: value.covered_entries,
    file_coverage: value.file_coverage,
  };
  requireCondition(value.coverage_aggregate_sha256
    === aggregateSHA256('executable-policy-coverage', coverage),
  `${label} coverage aggregate is invalid`);
  const scannerVerification = verifyExecutablePolicyReport(
    scanner,
    installed,
    retained.path,
    retained.sha256,
    label,
  );
  requireCondition(scannerVerification.coverage_aggregate_sha256
    === value.coverage_aggregate_sha256,
  `${label} fresh scanner coverage differs from the report`);
  return {
    role: value.role,
    hostUUID: value.host_uuid,
    envelopeSHA256: value.deployment_envelope_sha256,
    scannerSHA256: value.scanner_sha256,
    receipt: { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 },
  };
}

function semanticDeploymentEvidence(value, label) {
  exactKeys(value, [
    'installed_inventories', 'elevation_receipts', 'process_tree_collector',
    'process_tree_monitor', 'process_trees',
    'executable_policy_scanner', 'executable_policy_reports',
  ], label);
  requireCondition(Array.isArray(value.installed_inventories)
    && value.installed_inventories.length === DEPLOYMENT_HOST_ROLES.length,
  `${label} must contain local and Studio inventories`);
  requireCondition(Array.isArray(value.elevation_receipts)
    && value.elevation_receipts.length === DEPLOYMENT_HOST_ROLES.length,
  `${label} must contain local and Studio elevation receipts`);
  requireCondition(Array.isArray(value.process_trees)
    && value.process_trees.length === DEPLOYMENT_HOST_ROLES.length * PROCESS_TREE_EPOCHS.length,
  `${label} must contain before/during/after trees for both hosts`);
  requireCondition(Array.isArray(value.executable_policy_reports)
    && value.executable_policy_reports.length === DEPLOYMENT_HOST_ROLES.length,
  `${label} must contain local and Studio executable policy reports`);
  const installed = value.installed_inventories.map((filePath, index) => (
    semanticInstalledInventory(filePath, `${label}.installed_inventories[${index}]`)
  ));
  requireCondition(sameJSON(installed.map((entry) => entry.role), DEPLOYMENT_HOST_ROLES),
    `${label} inventory role ordering is invalid`);
  requireCondition(new Set(installed.map((entry) => entry.hostUUID)).size === installed.length,
    `${label} host UUIDs are not distinct`);
  requireCondition(installed.slice(1).every((entry) => (
    sameJSON(entry.projection, installed[0].projection)
  )), `${label} local and Studio installed inventories differ`);
  const elevations = value.elevation_receipts.map((filePath, index) => (
    semanticElevationInstallReceipt(
      filePath,
      `${label}.elevation_receipts[${index}]`,
      installed[index],
    )
  ));
  requireCondition(elevations.every((elevation, index) => (
    elevation.receipt.sha256 === installed[index].elevationReceiptSHA256
  )), `${label} elevation receipt differs from its installed inventory`);
  requireCondition(new Set(elevations.map((entry) => entry.value.transactionId)).size
    === elevations.length, `${label} elevation transaction IDs are not host-distinct`);
  requireCondition(new Set(elevations.map((entry) => entry.value.nodeId)).size
    === elevations.length, `${label} elevation node IDs are not host-distinct`);
  requireCondition(new Set(elevations.map((entry) => entry.receipt.sha256)).size
    === elevations.length, `${label} elevation receipts are not host-distinct`);
  const collector = stableSourceReceipt(
    value.process_tree_collector,
    `${label}.process_tree_collector`,
  );
  const processTreeMonitor = executableIdentity(
    value.process_tree_monitor,
    `${label}.process_tree_monitor`,
  );
  const lifecycleGuard = stableSourceReceipt(
    path.join(path.dirname(value.process_tree_collector), 'process-lifecycle-guard.c'),
    `${label}.process_lifecycle_guard`,
  );
  const expectedTrees = DEPLOYMENT_HOST_ROLES.flatMap((role) => (
    PROCESS_TREE_EPOCHS.map((epoch) => ({ role, epoch }))
  ));
  const trees = value.process_trees.map((filePath, index) => (
    semanticProcessTree(filePath, `${label}.process_trees[${index}]`)
  ));
  requireCondition(trees.every((tree, index) => tree.role === expectedTrees[index].role
    && tree.epoch === expectedTrees[index].epoch), `${label} process-tree ordering is invalid`);
  requireCondition(trees.every((tree) => tree.collectorSHA256 === collector.sha256),
    `${label} process tree collector differs from the bound source`);
  requireCondition(trees.every((tree) => tree.monitorExecutablePath === processTreeMonitor.retained.path
    && tree.monitorExecutableSHA256 === processTreeMonitor.retained.sha256
    && tree.monitorCodeSignatureHash === processTreeMonitor.codeSignatureHash),
  `${label} process tree monitor differs from the exact authenticated executable`);
  requireCondition(trees.every((tree) => (
    tree.lifecycleGuardSHA256 === lifecycleGuard.sha256
  )), `${label} process lifecycle guard differs from the bound source`);
  requireCondition(DEPLOYMENT_HOST_ROLES.every((role) => new Set(
    trees.filter((tree) => tree.role === role).map((tree) => tree.lifecycleGuardBinarySHA256),
  ).size === 1), `${label} process lifecycle guard binary differs within one host`);
  for (const tree of trees) {
    const host = installed.find((entry) => entry.role === tree.role);
    requireCondition(tree.hostUUID === host.hostUUID && tree.envelopeSHA256 === host.envelopeSHA256,
      `${label} process tree differs from its installed host identity`);
    const requiredClasses = REQUIRED_ROOT_CLASSES[tree.role][tree.epoch];
    const rootClasses = [...new Set(tree.roots.map((root) => root.rootClass))].sort();
    requireCondition(sameJSON(rootClasses, [...requiredClasses].sort()),
      `${label} ${tree.role}/${tree.epoch} root coverage is incomplete`);
    requireCondition(tree.roots.every((root) => root.rootClass === 'fixture'
      || tree.roots.filter((candidate) => candidate.rootClass === root.rootClass).length === 1),
    `${label} ${tree.role}/${tree.epoch} repeats a singleton root class`);
  }
  for (const role of DEPLOYMENT_HOST_ROLES) {
    const hostTrees = trees.filter((tree) => tree.role === role);
    requireCondition(hostTrees.every((tree, index) => index === 0
      || hostTrees[index - 1].capturedAtMilliseconds < tree.capturedAtMilliseconds),
    `${label} ${role} process-tree timestamps are not strictly ordered`);
    requireCondition(hostTrees.every((tree, index) => index === 0
      || hostTrees[index - 1].coverageCompletedAtMilliseconds
        < tree.coverageStartedAtMilliseconds),
    `${label} ${role} process-tree coverage intervals overlap or are not ordered`);
    const persistentClasses = role === 'local'
      ? ['bridge', 'elevation', 'integrated_cu'] : ['bridge', 'elevation'];
    for (const rootClass of persistentClasses) {
      const authorities = hostTrees.map((tree) => tree.roots.find((root) => root.rootClass === rootClass));
      requireCondition(authorities.every((authority) => authority
        && authority.identity === authorities[0].identity
        && authority.codeSignatureHash === authorities[0].codeSignatureHash),
      `${label} ${role} ${rootClass} root generation drifted across epochs`);
    }
    const elevation = elevations[DEPLOYMENT_HOST_ROLES.indexOf(role)];
    const admittedCDHashes = new Set(Object.values(elevation.value.cdhashes));
    requireCondition(hostTrees.every((tree) => {
      const root = tree.roots.find((entry) => entry.rootClass === 'elevation');
      return root && admittedCDHashes.has(root.codeSignatureHash);
    }), `${label} ${role} elevation root differs from its installed receipt`);
  }
  const scannerExecutable = requireStableExecutable(
    value.executable_policy_scanner,
    `${label}.executable_policy_scanner`,
  );
  const scanner = {
    path: scannerExecutable.path,
    size: scannerExecutable.bytes.length,
    sha256: scannerExecutable.sha256,
  };
  const policyReports = value.executable_policy_reports.map((filePath, index) => (
    semanticExecutablePolicyReport(
      filePath,
      `${label}.executable_policy_reports[${index}]`,
      installed[index],
      scanner,
    )
  ));
  requireCondition(sameJSON(policyReports.map((entry) => entry.role), DEPLOYMENT_HOST_ROLES),
    `${label} executable policy report role ordering is invalid`);
  requireCondition(policyReports.every((report, index) => report.hostUUID === installed[index].hostUUID
    && report.envelopeSHA256 === installed[index].envelopeSHA256
    && report.scannerSHA256 === scanner.sha256),
  `${label} executable policy report differs from its bound host/scanner`);
  return {
    evidence: {
      installed_inventories: installed.map((entry) => entry.receipt),
      elevation_receipts: elevations.map((entry) => entry.receipt),
      process_tree_collector: collector,
      process_tree_monitor: {
        path: processTreeMonitor.retained.path,
        size: processTreeMonitor.retained.bytes.length,
        sha256: processTreeMonitor.retained.sha256,
      },
      process_trees: trees.map((entry) => entry.receipt),
      executable_policy_scanner: scanner,
      executable_policy_reports: policyReports.map((entry) => entry.receipt),
    },
    peekabooSourceCommit: installed[0].projection.peekaboo_source_commit,
    qualificationToolsAggregateSHA256: installed[0].qualificationToolsAggregateSHA256,
    installed,
    elevations,
    trees,
    collectorSource: collector,
    processTreeMonitor,
    lifecycleGuardSource: lifecycleGuard,
  };
}

function validatePeekabooArtifactDeployment(artifact, deployment, label) {
  const cliCandidates = deployment.installed[0].projection.entries.filter((entry) => (
    entry.artifact === 'peekaboo_cli'
      && entry.type === 'file'
      && path.basename(entry.relative_path) === 'peekaboo'
      && (entry.mode & 0o111) !== 0
  ));
  requireCondition(cliCandidates.length === 1
    && cliCandidates[0].sha256 === artifact.cli.sha256,
  `${label} CLI artifact differs from the installed executable`);
  for (const role of DEPLOYMENT_HOST_ROLES) {
    const hostTrees = deployment.trees.filter((tree) => tree.role === role);
    requireCondition(hostTrees.length === PROCESS_TREE_EPOCHS.length
      && hostTrees.every((tree) => {
        const bridge = tree.roots.find((root) => root.rootClass === 'bridge');
        return bridge?.codeSignatureHash === artifact.app.cdhash;
      }), `${label} Peekaboo.app artifact differs from the ${role} Bridge root`);
    const during = hostTrees.find((tree) => tree.epoch === 'during');
    const fixtures = during?.roots.filter((root) => root.rootClass === 'fixture') ?? [];
    requireCondition(fixtures.length > 0 && fixtures.every((root) => (
      root.codeSignatureHash === artifact.playground.cdhash
    )), `${label} Playground artifact differs from the ${role} fixture root`);
  }
}

function validateDeploymentToolSources(deployment, toolsManifest, artifact, label) {
  const files = new Map(toolsManifest.files.map((entry) => [entry.relative_path, entry]));
  const expected = [
    ['scripts/final-qualification/process-tree-collector.mjs', deployment.collectorSource],
    ['scripts/final-qualification/process-lifecycle-guard.c', deployment.lifecycleGuardSource],
    ['scripts/final-qualification/executable-policy-scanner.mjs', deployment.evidence.executable_policy_scanner],
  ];
  for (const [relativePath, receipt] of expected) {
    const entry = files.get(relativePath);
    requireCondition(entry
      && receipt.path === path.join(toolsManifest.directory, relativePath)
      && receipt.sha256 === entry.sha256
      && receipt.size === entry.size,
    `${label} ${relativePath} differs from the reviewed qualification tools`);
  }
  const monitorSource = files.get(artifact.monitor.source_path);
  requireCondition(monitorSource && monitorSource.sha256 === artifact.monitor.source_sha256,
    `${label} monitor source differs from the reviewed Git tree`);
  const catalogPath = 'scripts/multi-target-certification-catalog.json';
  const catalogEntry = files.get(catalogPath);
  requireCondition(catalogEntry !== undefined, `${label} monitor catalog is not source-bound`);
  const catalog = readStableJSON(
    path.join(toolsManifest.directory, catalogPath),
    `${label} monitor catalog`,
    { privateFile: false },
  );
  requireCondition(catalog.sha256 === catalogEntry.sha256
    && catalog.value.monitor_source?.probe_sha256 === monitorSource.sha256,
  `${label} monitor source differs from the source-owned catalog`);
  requireCondition(deployment.processTreeMonitor.retained.sha256
    === artifact.monitor.executable_sha256
    && deployment.processTreeMonitor.codeSignatureHash === artifact.monitor.cdhash,
  `${label} process monitor differs from the candidate-bound monitor`);
}

function exactTarget(value, label) {
  exactKeys(value, ['pid', 'start_identity', 'window_id'], label);
  requireCondition(Number.isSafeInteger(value.pid) && value.pid > 0
    && typeof value.start_identity === 'string' && /^[1-9][0-9]*$/.test(value.start_identity)
    && Number.isSafeInteger(value.window_id) && value.window_id > 0,
  `${label} is malformed`);
  return value;
}

function qualificationAdjunctBinding(deployment, plan, label) {
  const expectedHost = plan?.bridge?.expected_host;
  exactKeys(expectedHost, [
    'host_kind', 'process_identifier', 'process_start_identity_decimal',
    'code_signature_hash', 'source_commit',
  ], `${label}.expected_host`);
  requireCondition(['gui', 'daemon'].includes(expectedHost.host_kind)
    && Number.isSafeInteger(expectedHost.process_identifier)
    && expectedHost.process_identifier > 0
    && typeof expectedHost.process_start_identity_decimal === 'string'
    && /^[1-9][0-9]*$/.test(expectedHost.process_start_identity_decimal)
    && CODE_SIGNATURE_HASH.test(expectedHost.code_signature_hash ?? '')
    && expectedHost.source_commit === deployment.peekabooSourceCommit,
  `${label} Bridge host is not bound to the exact candidate source`);
  requireCondition(Array.isArray(plan.controllers) && plan.controllers.length === 2,
    `${label} does not contain both controlled fixture targets`);
  const fixtureBinding = controlledFixtureBindings(plan, label);
  const controlledFixtureTargets = fixtureBinding.targets;
  const fixtureTargets = controlledFixtureTargets.map((binding) => binding.target);
  requireCondition(new Set(fixtureTargets.map((target) => (
    `${target.pid}:${target.start_identity}:${target.window_id}`
  ))).size === fixtureTargets.length, `${label} controlled fixture targets are not distinct`);
  return {
    sourceCommit: deployment.peekabooSourceCommit,
    expectedHost: {
      host_kind: expectedHost.host_kind,
      pid: expectedHost.process_identifier,
      start_identity: expectedHost.process_start_identity_decimal,
      code_signature_hash: expectedHost.code_signature_hash,
    },
    fixtureTargets,
    fixtureBinding,
    controlledFixtureTargets,
  };
}

function requireFixtureTarget(target, binding, label) {
  requireCondition(binding.fixtureTargets.some((candidate) => sameJSON(candidate, target)),
    `${label} is not one exact controlled fixture target`);
}

function semanticCertificate(filePath, label, expected) {
  const retained = readStableJSON(filePath, label);
  const value = retained.value;
  exactKeys(value, [
    'version', 'cycle', 'success', 'catalog_version', 'expected_cases', 'observed_cases',
    'failures', 'execution_nonce', 'host_uuid', 'peekaboo_source_commit',
    'bridge_source_commit', 'deployment_envelope_sha256',
    'installed_inventory_aggregate_sha256', 'peekaboo_artifact_manifest_sha256',
    'started_at_milliseconds', 'completed_at_milliseconds',
  ], label);
  requireCondition(value.version === 2 && value.cycle === expected.cycle
    && value.success === true && value.catalog_version === 2
    && value.expected_cases === 42 && value.observed_cases === 42
    && Array.isArray(value.failures) && value.failures.length === 0
    && SHA256.test(value.execution_nonce) && value.host_uuid === expected.hostUUID
    && value.peekaboo_source_commit === expected.sourceCommit
    && value.bridge_source_commit === expected.sourceCommit
    && value.deployment_envelope_sha256 === expected.deploymentEnvelopeSHA256
    && value.installed_inventory_aggregate_sha256 === expected.installedInventoryAggregateSHA256
    && value.peekaboo_artifact_manifest_sha256 === expected.peekabooArtifactManifestSHA256
    && Number.isSafeInteger(value.started_at_milliseconds) && value.started_at_milliseconds > 0
    && Number.isSafeInteger(value.completed_at_milliseconds)
    && value.completed_at_milliseconds > value.started_at_milliseconds,
  `${label} is not one passing 42/42 certificate`);
  return {
    receipt: { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 },
    value,
  };
}

function semanticCrashComparison(filePath, label, expected = null) {
  const retained = readStableJSON(filePath, label);
  const value = retained.value;
  if (expected === null) {
    exactKeys(value, ['version', 'passed', 'added', 'changed', 'removed'], label);
    requireCondition(value.version === 1 && value.passed === true
      && ['added', 'changed', 'removed'].every((key) => (
        Array.isArray(value[key]) && value[key].length === 0
      )), `${label} is not one passing zero-delta crash comparison`);
  } else {
    exactKeys(value, [
      'version', 'cycle', 'execution_nonce', 'host_uuid', 'peekaboo_source_commit',
      'deployment_envelope_sha256', 'installed_inventory_aggregate_sha256',
      'peekaboo_artifact_manifest_sha256', 'started_at_milliseconds',
      'completed_at_milliseconds', 'passed', 'added',
      'changed', 'removed',
    ], label);
    requireCondition(value.version === 2 && value.cycle === expected.cycle
      && value.execution_nonce === expected.execution_nonce
      && value.host_uuid === expected.host_uuid
      && value.peekaboo_source_commit === expected.peekaboo_source_commit
      && value.deployment_envelope_sha256 === expected.deployment_envelope_sha256
      && value.installed_inventory_aggregate_sha256
        === expected.installed_inventory_aggregate_sha256
      && value.peekaboo_artifact_manifest_sha256
        === expected.peekaboo_artifact_manifest_sha256
      && Number.isSafeInteger(value.started_at_milliseconds)
      && value.started_at_milliseconds <= expected.started_at_milliseconds
      && Number.isSafeInteger(value.completed_at_milliseconds)
      && value.completed_at_milliseconds >= expected.completed_at_milliseconds
      && value.passed === true && ['added', 'changed', 'removed'].every((key) => (
        Array.isArray(value[key]) && value[key].length === 0
      )), `${label} is not one run-bound zero-delta crash comparison`);
  }
  return { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 };
}

function semanticConcurrentValidation(filePath) {
  const retained = readStableJSON(filePath, 'Agent/CU concurrent validation report');
  const value = retained.value;
  exactKeys(value, [
    'version', 'passed', 'execution_nonce', 'monitor_instance_id', 'coordinator', 'agent',
    'monitor', 'integrated_cu', 'overlap', 'externally_supplied_authority',
  ], 'Agent/CU concurrent validation report');
  exactKeys(value.monitor, [
    'executable_path', 'executable_sha256', 'code_signature_hash',
  ], 'Agent/CU concurrent validation report monitor');
  const actionIntervals = value.agent?.progress_interleaving?.action_intervals;
  exactKeys(value.agent?.progress_interleaving, [
    'integrated_cu_perform_at_milliseconds',
    'integrated_cu_perform_readback_mtime_milliseconds',
    'action_intervals',
  ], 'Agent/CU concurrent validation report progress_interleaving');
  requireCondition(Array.isArray(actionIntervals),
    'Agent/CU concurrent validation report action intervals are absent');
  actionIntervals.forEach((entry, index) => {
    exactKeys(entry, [
      'trace_call_id', 'started_at_milliseconds', 'completed_at_milliseconds',
    ], `Agent/CU concurrent validation report action_intervals[${index}]`);
    requireCondition(typeof entry.trace_call_id === 'string' && entry.trace_call_id.length > 0
      && Number.isSafeInteger(entry.started_at_milliseconds)
      && Number.isSafeInteger(entry.completed_at_milliseconds)
      && entry.completed_at_milliseconds > entry.started_at_milliseconds,
    `Agent/CU concurrent validation report action_intervals[${index}] is malformed`);
  });
  const controlledFixtureTargets = value.agent?.controlled_fixture_targets;
  requireCondition(Array.isArray(controlledFixtureTargets)
    && controlledFixtureTargets.length === 2,
  'Agent/CU concurrent validation report controlled fixture targets are absent');
  controlledFixtureTargets.forEach((binding, index) => {
    const suffix = index === 0 ? 'a' : 'b';
    exactKeys(binding, ['label', 'controller_id', 'target'],
      `Agent/CU concurrent validation report controlled_fixture_targets[${index}]`);
    requireCondition(binding.label === `target-${suffix}`
      && binding.controller_id === `controller-${suffix}`,
    `Agent/CU concurrent validation report controlled_fixture_targets[${index}] is not canonical`);
    exactTarget(
      binding.target,
      `Agent/CU concurrent validation report controlled_fixture_targets[${index}].target`,
    );
  });
  requireCondition(new Set(controlledFixtureTargets.map((binding) => (
    `${binding.target.pid}:${binding.target.start_identity}:${binding.target.window_id}`
  ))).size === controlledFixtureTargets.length,
  'Agent/CU concurrent validation report controlled fixture targets are not distinct');
  const overlap = value.overlap;
  requireCondition(value.version === 1 && value.passed === true
    && value.coordinator?.exit_code === 0
    && CODE_SIGNATURE_HASH.test(value.coordinator?.code_signature_hash ?? '')
    && value.coordinator?.completed_event === 'completed'
    && value.coordinator?.certification_eligible === true
    && value.agent?.exit_code === 0
    && typeof value.agent?.executable_path === 'string'
    && path.isAbsolute(value.agent.executable_path)
    && SHA256.test(value.agent?.executable_sha256 ?? '')
    && CODE_SIGNATURE_HASH.test(value.agent?.code_signature_hash ?? '')
    && typeof value.monitor.executable_path === 'string'
    && path.isAbsolute(value.monitor.executable_path)
    && SHA256.test(value.monitor.executable_sha256)
    && CODE_SIGNATURE_HASH.test(value.monitor.code_signature_hash)
    && Array.isArray(value.agent?.mapped_call_ids) && value.agent.mapped_call_ids.length === 4
    && new Set(value.agent.mapped_call_ids).size === 4
    && Array.isArray(value.agent?.mutation_families) && value.agent.mutation_families.length >= 2
    && Number.isSafeInteger(value.agent?.progress_interleaving?.integrated_cu_perform_at_milliseconds)
    && Number.isSafeInteger(
      value.agent?.progress_interleaving?.integrated_cu_perform_readback_mtime_milliseconds,
    )
    && actionIntervals.length === 4
    && new Set(actionIntervals.map((entry) => entry.trace_call_id)).size === actionIntervals.length
    && sameJSON(
      actionIntervals.map((entry) => entry.trace_call_id).sort(),
      [...value.agent.mapped_call_ids].sort(),
    )
    && actionIntervals.some((entry) => (
      entry.completed_at_milliseconds
        < value.agent.progress_interleaving.integrated_cu_perform_at_milliseconds
    ))
    && actionIntervals.some((entry) => (
      entry.started_at_milliseconds
        > value.agent.progress_interleaving.integrated_cu_perform_at_milliseconds
    ))
    && Number.isSafeInteger(value.agent?.signed_bundle_count) && value.agent.signed_bundle_count >= 4
    && Array.isArray(value.agent?.signed_bundles)
    && value.agent.signed_bundles.length === value.agent.signed_bundle_count
    && Array.isArray(value.agent?.semantic_readbacks) && value.agent.semantic_readbacks.length === 6
    && Number.isSafeInteger(overlap?.agent_started_at_milliseconds)
    && Number.isSafeInteger(overlap?.operations_started_at_milliseconds)
    && Number.isSafeInteger(overlap?.operations_completed_at_milliseconds)
    && Number.isSafeInteger(overlap?.agent_completed_at_milliseconds)
    && overlap.agent_started_at_milliseconds <= overlap.operations_started_at_milliseconds
    && overlap.operations_started_at_milliseconds < overlap.operations_completed_at_milliseconds
    && overlap.operations_completed_at_milliseconds <= overlap.agent_completed_at_milliseconds
    && overlap.agent_covers_operation_interval === true,
  'Agent/CU concurrent validation report is not semantically complete');
  return { retained, value, receipt: { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 } };
}

function validateLocalDuringConcurrentBinding(deployment, concurrent, plan, label) {
  const candidates = deployment.trees.filter((tree) => (
    tree.role === 'local' && tree.epoch === 'during'
  ));
  requireCondition(candidates.length === 1, `${label} lacks one local/during process tree`);
  const during = candidates[0];
  requireCondition(
    during.coverageStartedAtMilliseconds <= concurrent.overlap.operations_started_at_milliseconds
      && during.finalSampleStartedAtMilliseconds
        >= concurrent.overlap.operations_completed_at_milliseconds,
    `${label} local/during process coverage does not bracket the concurrent operation interval`,
  );
  const expected = {
    agent: {
      pid: concurrent.agent.pid,
      startIdentity: concurrent.agent.start_identity,
      codeSignatureHash: concurrent.agent.code_signature_hash,
    },
    coordinator: {
      pid: concurrent.coordinator.pid,
      startIdentity: concurrent.coordinator.start_identity,
      codeSignatureHash: concurrent.coordinator.code_signature_hash,
    },
    bridge: {
      pid: plan.bridge?.expected_host?.process_identifier,
      startIdentity: plan.bridge?.expected_host?.process_start_identity_decimal,
      codeSignatureHash: plan.bridge?.expected_host?.code_signature_hash,
    },
    integrated_cu: {
      pid: concurrent.integrated_cu?.emitter?.pid,
      startIdentity: concurrent.integrated_cu?.emitter?.start_identity,
      codeSignatureHash: concurrent.integrated_cu?.emitter?.code_signature_hash,
    },
  };
  for (const [rootClass, identity] of Object.entries(expected)) {
    const roots = during.roots.filter((root) => root.rootClass === rootClass);
    requireCondition(roots.length === 1 && Number.isSafeInteger(identity.pid) && identity.pid > 0
      && typeof identity.startIdentity === 'string' && /^[1-9][0-9]*$/.test(identity.startIdentity)
      && CODE_SIGNATURE_HASH.test(identity.codeSignatureHash ?? '')
      && roots[0].pid === identity.pid
      && roots[0].startIdentity === identity.startIdentity
      && roots[0].codeSignatureHash === identity.codeSignatureHash,
    `${label} local/during ${rootClass} root differs from the concurrent run`);
  }
  const fixtureRoots = during.roots.filter((root) => root.rootClass === 'fixture');
  const controlledTargets = plan.controllers?.map((controller) => ({
    pid: controller?.target?.process_identifier,
    startIdentity: controller?.target?.process_start_identity_decimal,
  })) ?? [];
  requireCondition(controlledTargets.length === 2 && controlledTargets.every((target) => (
    fixtureRoots.some((root) => root.pid === target.pid
      && root.startIdentity === target.startIdentity)
  )), `${label} local/during fixture roots omit a controlled Agent target generation`);
}

function validateExercisedCandidateBindings(
  artifact,
  deployment,
  concurrent,
  agentInvocation,
  label,
) {
  const during = deployment.trees.find((tree) => tree.role === 'local' && tree.epoch === 'during');
  const agentRoot = during?.roots.find((root) => root.rootClass === 'agent');
  const sampledAgent = agentRoot ? during.byIdentity.get(agentRoot.identity)?.value : null;
  requireCondition(sampledAgent
    && artifact.cli.sha256 === concurrent.agent.executable_sha256
    && artifact.cli.sha256 === agentInvocation.executable_sha256
    && artifact.cli.sha256 === sampledAgent.executable_sha256
    && artifact.cli.cdhash === concurrent.agent.code_signature_hash
    && artifact.cli.cdhash === sampledAgent.code_signature_hash
    && agentInvocation.executable_path === concurrent.agent.executable_path
    && sampledAgent.executable_path === concurrent.agent.executable_path,
  `${label} exercised Agent CLI differs from the candidate/deployed executable`);
  requireCondition(artifact.monitor.executable_sha256 === concurrent.monitor.executable_sha256
    && artifact.monitor.executable_sha256 === agentInvocation.monitor_executable_sha256
    && artifact.monitor.executable_sha256 === deployment.processTreeMonitor.retained.sha256
    && artifact.monitor.cdhash === concurrent.monitor.code_signature_hash
    && artifact.monitor.cdhash === agentInvocation.monitor_code_signature_hash
    && artifact.monitor.cdhash === deployment.processTreeMonitor.codeSignatureHash
    && concurrent.monitor.executable_path === agentInvocation.monitor_executable_path
    && concurrent.monitor.executable_path === deployment.processTreeMonitor.retained.path,
  `${label} exercised process monitor differs from the candidate-bound executable`);
}

function bundlePayload(bundle, label) {
  const payload = bundle.value?.receipt?.payload;
  requireCondition(payload?.schemaVersion === 1 && typeof payload.operation === 'string',
    `${label} signed payload is malformed`);
  return payload;
}

function semanticValidatorPair(bundlePath, validatorPath, label, {
  expectedOperation = null,
  requireMutation = false,
  authentication = null,
  adjunctBinding = null,
} = {}) {
  const bundle = readStableJSON(bundlePath, `${label} bundle`, {
    maximumBytes: 256 * 1024 * 1024,
  });
  const payload = bundlePayload(bundle, label);
  const validator = readStableJSON(validatorPath, `${label} validator`);
  exactKeys(validator.value, ['success', 'data'], `${label} validator`);
  let report = validator.value.data;
  if (authentication !== null) {
    const authenticatedReport = authentication.authenticateBundle({
      executablePath: authentication.executable_path,
      expectedExecutableSHA256: authentication.executable_sha256,
      socketPath: authentication.bridge_socket,
      trustedHostTeamIDs: authentication.trusted_host_team_ids,
      expectedHost: authentication.expected_host,
      bundlePath: bundle.path,
      label,
    });
    requireCondition(sameJSON(report, authenticatedReport),
      `${label} retained validator differs from authenticated live validation`);
    report = authenticatedReport;
  }
  const identity = authenticatedBridgeReceiptIdentity(payload, report, label);
  requireCondition(validator.value.success === true
    && report?.valid === true
    && report.validator_id === 'peekaboo-bridge-receipt-validate-v1'
    && report.trust_source === 'authenticated_live_listener'
    && report.minimum_protocol_version === '1.29'
    && report.host_protocol_version === '1.30'
    && /^[0-9a-f]{40}$/.test(report.host_source_commit ?? '')
    && report.terminal_receipt_attested === true
    && report.retention_basis === 'exported_bundle'
    && report.bundle_sha256 === bundle.sha256
    && report.operation === payload.operation
    && Number.isSafeInteger(report.host?.pid) && report.host.pid > 0
    && typeof report.host?.start_identity === 'string'
    && /^[0-9a-f]{40}$/.test(report.host?.code_signature_hash ?? '')
    && Number.isSafeInteger(payload.client?.processIdentifier)
    && payload.client.processIdentifier > 0
    && typeof payload.client.processStartIdentity === 'string'
    && report.client?.pid === payload.client.processIdentifier
    && report.client?.start_identity === payload.client.processStartIdentity
    && report.client?.code_signature_hash === payload.client.codeSignatureHash,
  `${label} validator is not bound to one authenticated live bundle`);
  if (adjunctBinding !== null) {
    requireCondition(report.host_source_commit === adjunctBinding.sourceCommit
      && report.host.pid === adjunctBinding.expectedHost.pid
      && report.host.start_identity === adjunctBinding.expectedHost.start_identity
      && report.host.code_signature_hash === adjunctBinding.expectedHost.code_signature_hash,
    `${label} validator differs from the exact candidate Bridge host`);
  }
  if (expectedOperation !== null) {
    requireCondition(payload.operation === expectedOperation,
      `${label} operation is not ${expectedOperation}`);
  }
  if (requireMutation) {
    requireCondition(report.target_attested === true && report.outcome_attested === true
      && payload.outcome?.delivery_mode === 'background'
      && payload.outcome?.dispatch_state === 'dispatched'
      && payload.outcome?.mutation_dispatched === true,
    `${label} lacks one target-attested background mutation`);
  }
  return { bundle, validator, payload, report, identity };
}

function agentBundleAuthentication(plan, invocation, authenticateBundle, label) {
  requireCondition(typeof authenticateBundle === 'function'
    && plan?.bridge && typeof plan.bridge.socket_path === 'string'
    && path.isAbsolute(plan.bridge.socket_path)
    && Array.isArray(plan.bridge.trusted_host_team_ids)
    && plan.bridge.trusted_host_team_ids.length > 0
    && plan.bridge.trusted_host_team_ids.every((teamID) => /^[A-Z0-9]{10}$/.test(teamID))
    && new Set(plan.bridge.trusted_host_team_ids).size
      === plan.bridge.trusted_host_team_ids.length,
  `${label} Bridge validation policy is malformed`);
  requireCondition(path.isAbsolute(invocation?.executable_path)
    && /^[0-9a-f]{64}$/.test(invocation.executable_sha256 ?? '')
    && invocation.executable_path === plan.peekaboo_executable
    && invocation.bridge_socket === plan.bridge.socket_path,
  `${label} Agent validator executable/socket differs from the live plan`);
  return {
    authenticateBundle,
    executable_path: invocation.executable_path,
    executable_sha256: invocation.executable_sha256,
    bridge_socket: plan.bridge.socket_path,
    trusted_host_team_ids: plan.bridge.trusted_host_team_ids,
    expected_host: plan.bridge.expected_host,
  };
}

function validateConcurrentInterleavingBinding(
  concurrent,
  agentReadbacksPath,
  bundlePairs,
  performReadbackPath,
  controlledFixtureTargets,
  label,
) {
  const readbacks = readStableJSON(agentReadbacksPath, `${label} Agent readback map`).value;
  exactKeys(readbacks, ['version', 'agent', 'targets'], `${label} Agent readback map`);
  requireCondition(readbacks.version === 1 && Array.isArray(readbacks.targets)
    && readbacks.targets.length === 2, `${label} Agent readback map is malformed`);
  requireCondition(sameJSON(
    concurrent.agent.controlled_fixture_targets,
    controlledFixtureTargets,
  ), `${label} controlled fixture targets differ from the live-v4 plan`);
  const pairsByBundlePath = new Map(bundlePairs.map((pair) => [pair.bundle.path, pair]));
  requireCondition(pairsByBundlePath.size === bundlePairs.length,
    `${label} Agent bundle paths are not unique`);
  const actionIntervals = [];
  for (const [targetIndex, target] of readbacks.targets.entries()) {
    exactKeys(target, [
      'label', 'target', 'baseline_readback_path', 'mutation', 'restoration',
    ], `${label} Agent target ${targetIndex}`);
    const expectedTarget = exactTarget(
      target.target,
      `${label} Agent target ${targetIndex}.target`,
    );
    requireCondition(target.label === controlledFixtureTargets[targetIndex].label
      && sameJSON(expectedTarget, controlledFixtureTargets[targetIndex].target),
    `${label} Agent target ${targetIndex} is not its exact live-v4 controlled fixture target`);
    const baseline = semanticAgentReadback(
      target.baseline_readback_path,
      `${label} Agent target ${targetIndex}.baseline`,
    );
    requireCondition(baseline.phase === 'baseline',
      `${label} Agent target ${targetIndex} baseline phase is invalid`);
    requireCondition(sameJSON(baseline.target, expectedTarget),
      `${label} Agent target ${targetIndex} baseline belongs to another target`);
    const actionEvidence = {};
    for (const [kind, phase] of [['mutation', 'mutated'], ['restoration', 'restored']]) {
      const action = target[kind];
      exactKeys(action, [
        'trace_call_id', 'family', 'readback_path', 'bundle_path', 'validator_report_path',
      ], `${label} Agent target ${targetIndex}.${kind}`);
      const pair = pairsByBundlePath.get(action.bundle_path);
      requireCondition(pair && pair.validator.path === action.validator_report_path,
        `${label} Agent target ${targetIndex}.${kind} is absent from the bound corpus`);
      requireCondition(pair.report.target_attested === true
        && pair.report.outcome_attested === true
        && pair.payload.outcome?.delivery_mode === 'background'
        && pair.payload.outcome?.dispatch_state === 'dispatched'
        && pair.payload.outcome?.mutation_dispatched === true,
      `${label} Agent target ${targetIndex}.${kind} lacks an authenticated background mutation`);
      requireCondition(sameJSON(
        targetFromPayload(pair.payload, `${label} Agent target ${targetIndex}.${kind}`),
        expectedTarget,
      ), `${label} Agent target ${targetIndex}.${kind} signed target differs`);
      const startedAt = pair.payload.startedAtUnixMilliseconds;
      const completedAt = pair.payload.completedAtUnixMilliseconds;
      requireCondition(typeof action.trace_call_id === 'string' && action.trace_call_id.length > 0
        && Number.isSafeInteger(startedAt) && startedAt > 0
        && Number.isSafeInteger(completedAt) && completedAt > startedAt,
      `${label} Agent target ${targetIndex}.${kind} interval is malformed`);
      actionIntervals.push({
        trace_call_id: action.trace_call_id,
        started_at_milliseconds: startedAt,
        completed_at_milliseconds: completedAt,
      });
      const readback = semanticAgentReadback(
        action.readback_path,
        `${label} Agent target ${targetIndex}.${kind} readback`,
      );
      requireCondition(readback.phase === phase,
        `${label} Agent target ${targetIndex}.${kind} readback phase is invalid`);
      requireCondition(sameJSON(readback.target, expectedTarget),
        `${label} Agent target ${targetIndex}.${kind} readback belongs to another target`);
      requireCondition(completedAt < readback.observed_at_milliseconds,
        `${label} Agent target ${targetIndex}.${kind} readback does not strictly follow dispatch completion`);
      actionEvidence[kind] = { startedAt, completedAt, readback };
    }
    requireCondition(
      baseline.observed_at_milliseconds < actionEvidence.mutation.startedAt
        && actionEvidence.mutation.readback.observed_at_milliseconds
          < actionEvidence.restoration.startedAt,
      `${label} Agent target ${targetIndex} baseline/mutation/restoration order is invalid`,
    );
    requireCondition(actionEvidence.mutation.completedAt < actionEvidence.restoration.startedAt,
      `${label} Agent target ${targetIndex} restoration dispatch predates mutation completion`);
  }
  const retainedPerform = readStableJSON(
    performReadbackPath,
    `${label} integrated-CU perform readback`,
  );
  const perform = retainedPerform.value;
  const performObservation = corroboratedObservationTime(
    retainedPerform,
    `${label} integrated-CU perform readback`,
  );
  const derived = {
    integrated_cu_perform_at_milliseconds: perform.observed_at_milliseconds,
    integrated_cu_perform_readback_mtime_milliseconds:
      performObservation.retained_mtime_milliseconds,
    action_intervals: actionIntervals,
  };
  requireCondition(sameJSON(concurrent.agent.progress_interleaving, derived),
    `${label} progress interleaving differs from the bound bundles/readback`);
  requireCondition(sameJSON(
    [...concurrent.agent.mapped_call_ids].sort(),
    actionIntervals.map((entry) => entry.trace_call_id).sort(),
  ), `${label} mapped call IDs differ from the bound Agent readback map`);
  requireCondition(perform.observed_at_milliseconds
    >= concurrent.overlap.operations_started_at_milliseconds
    && perform.observed_at_milliseconds <= concurrent.overlap.operations_completed_at_milliseconds,
  `${label} integrated-CU perform time is outside the operation interval`);
  requireCondition(actionIntervals.every((entry) => (
    entry.started_at_milliseconds >= concurrent.overlap.operations_started_at_milliseconds
      && entry.completed_at_milliseconds <= concurrent.overlap.operations_completed_at_milliseconds
  )), `${label} Agent interval is outside the operation interval`);
  requireCondition(actionIntervals.some((entry) => (
    entry.completed_at_milliseconds < perform.observed_at_milliseconds
  )) && actionIntervals.some((entry) => (
    entry.started_at_milliseconds > perform.observed_at_milliseconds
  )), `${label} does not prove strict Agent progress before and after integrated Computer Use`);
}

function targetFromPayload(payload, label) {
  const target = payload?.target;
  requireCondition(target?.kind === 'window', `${label} payload target is not a window`);
  return exactTarget({
    pid: target.processIdentifier,
    start_identity: target.processStartIdentity,
    window_id: target.windowID,
  }, `${label} payload target`);
}

function semanticRestoration(filePath, kind, expectedTarget, label) {
  const retained = readStableJSON(filePath, label);
  exactKeys(retained.value, [
    'version', 'kind', 'target', 'baseline_value', 'restored_value',
    'observed_at_milliseconds', 'passed',
  ], label);
  requireCondition(retained.value.version === 1 && retained.value.kind === kind
    && retained.value.passed === true
    && sameJSON(exactTarget(retained.value.target, `${label}.target`), expectedTarget)
    && typeof retained.value.baseline_value === 'string'
    && retained.value.restored_value === retained.value.baseline_value
    && Number.isSafeInteger(retained.value.observed_at_milliseconds)
    && retained.value.observed_at_milliseconds > 0,
  `${label} does not prove exact restoration`);
  return {
    retained,
    value: retained.value,
    receipt: { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 },
  };
}

function semanticMiddleReadback(filePath) {
  const label = 'middle-click readback';
  const retained = readStableJSON(filePath, label);
  const value = retained.value;
  exactKeys(value, [
    'version', 'kind', 'target', 'before_sequence', 'after_sequence', 'events',
    'observed_at_milliseconds', 'passed',
  ], label);
  const target = exactTarget({
    pid: value.target.pid,
    start_identity: value.target.start_identity,
    window_id: value.target.window_id,
  }, `${label}.target`);
  requireCondition(Array.isArray(value.events) && value.events.length === 2,
    `${label} must contain exact down/up events`);
  value.events.forEach((event, index) => {
    exactKeys(event, ['sequence', 'button', 'phase', 'window_id'], `${label}.events[${index}]`);
  });
  requireCondition(value.version === 1 && value.kind === 'middle_click' && value.passed === true
    && Number.isSafeInteger(value.before_sequence) && value.before_sequence >= 0
    && value.after_sequence === value.before_sequence + 2
    && value.events[0].sequence === value.before_sequence + 1
    && value.events[1].sequence === value.after_sequence
    && value.events[0].button === 'middle' && value.events[1].button === 'middle'
    && value.events[0].phase === 'down' && value.events[1].phase === 'up'
    && value.events.every((event) => event.window_id === target.window_id)
    && Number.isSafeInteger(value.observed_at_milliseconds) && value.observed_at_milliseconds > 0,
  `${label} does not prove one exact middle-click down/up log delta`);
  return { retained, target, receipt: { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 } };
}

function semanticHeldKeyReadback(filePath) {
  const label = 'held-key readback';
  const retained = readStableJSON(filePath, label);
  const value = retained.value;
  exactKeys(value, [
    'version', 'kind', 'target', 'key', 'hold_milliseconds', 'baseline_value',
    'observed_value', 'observed_at_milliseconds', 'passed',
  ], label);
  const target = exactTarget(value.target, `${label}.target`);
  requireCondition(value.version === 1 && value.kind === 'held_key' && value.passed === true
    && value.key === 'a' && value.hold_milliseconds === 500
    && typeof value.baseline_value === 'string'
    && value.observed_value === `${value.baseline_value}a`
    && Number.isSafeInteger(value.observed_at_milliseconds) && value.observed_at_milliseconds > 0,
  `${label} does not prove the exact held-key effect`);
  return { retained, target, receipt: { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 } };
}

function semanticHeldPointerReadback(filePath) {
  const label = 'held-pointer readback';
  const retained = readStableJSON(filePath, label);
  const value = retained.value;
  exactKeys(value, [
    'version', 'kind', 'target', 'before_sequence', 'after_sequence', 'events',
    'observed_at_milliseconds', 'passed',
  ], label);
  const target = exactTarget(value.target, `${label}.target`);
  requireCondition(Array.isArray(value.events) && value.events.length === 2,
    `${label} must contain exact down/up events`);
  value.events.forEach((event, index) => {
    exactKeys(event, ['sequence', 'button', 'phase', 'window_id'], `${label}.events[${index}]`);
  });
  requireCondition(value.version === 1 && value.kind === 'held_pointer' && value.passed === true
    && Number.isSafeInteger(value.before_sequence) && value.before_sequence >= 0
    && value.after_sequence === value.before_sequence + 2
    && value.events[0].sequence === value.before_sequence + 1
    && value.events[1].sequence === value.after_sequence
    && value.events[0].button === 'left' && value.events[1].button === 'left'
    && value.events[0].phase === 'down' && value.events[1].phase === 'up'
    && value.events.every((event) => event.window_id === target.window_id)
    && Number.isSafeInteger(value.observed_at_milliseconds) && value.observed_at_milliseconds > 0,
  `${label} does not prove an exact held-pointer down/up log delta`);
  return { retained, target, receipt: { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 } };
}

function derivedHeldPointerClientID(executionNonce) {
  requireCondition(/^[0-9a-f]{64}$/.test(executionNonce ?? ''),
    'held-pointer execution nonce is malformed');
  const digest = Buffer.from(sha256(Buffer.concat([
    Buffer.from('peekaboo.held-pointer-certification.client.v1\0', 'utf8'),
    Buffer.from(executionNonce, 'utf8'),
  ])), 'hex').subarray(0, 16);
  digest[6] = (digest[6] & 0x0f) | 0x80;
  digest[8] = (digest[8] & 0x3f) | 0x80;
  const hex = digest.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function semanticHeldControllerResult(filePath, adjunctBinding) {
  const label = 'held-pointer controller result';
  const retained = readStableJSON(filePath, label);
  const value = retained.value;
  exactKeys(value, [
    'version', 'result', 'execution_nonce', 'controller', 'build', 'handshake', 'target',
    'point', 'button', 'hold_milliseconds', 'interval', 'begin_dispatched_units',
    'release_dispatched_units', 'lifecycle_dispatched_units', 'terminal_reason',
    'cleanup_state', 'operations',
  ], label);
  exactKeys(value.controller, ['pid', 'start_identity', 'code_signature_hash'], `${label}.controller`);
  exactKeys(value.build, ['source_commit', 'executable_path', 'executable_sha256', 'team_id'], `${label}.build`);
  exactKeys(value.handshake, [
    'socket_path', 'negotiated_version', 'host_kind', 'build', 'listener_instance_id',
    'host', 'session',
  ], `${label}.handshake`);
  exactKeys(value.handshake.negotiated_version, ['major', 'minor'], `${label}.handshake.negotiated_version`);
  exactKeys(value.handshake.host, [
    'process', 'bundle_identifier', 'bundle_short_version', 'bundle_version', 'source_commit',
  ], `${label}.handshake.host`);
  exactKeys(value.handshake.host.process, ['pid', 'start_identity', 'code_signature_hash'], `${label}.handshake.host.process`);
  exactKeys(value.handshake.session, [
    'id', 'client_instance_id', 'maximum_request_count', 'initial_remaining_claim_count',
  ], `${label}.handshake.session`);
  exactKeys(value.target, ['scope', 'pid', 'start_identity', 'window_id', 'bounds', 'is_minimized'], `${label}.target`);
  exactKeys(value.target.bounds, ['x', 'y', 'width', 'height'], `${label}.target.bounds`);
  exactKeys(value.point, ['x', 'y'], `${label}.point`);
  exactKeys(value.interval, ['started_at_milliseconds', 'completed_at_milliseconds'], `${label}.interval`);
  const target = exactTarget({
    pid: value.target.pid,
    start_identity: value.target.start_identity,
    window_id: value.target.window_id,
  }, `${label}.target`);
  const controller = {
    pid: value.controller.pid,
    start_identity: value.controller.start_identity,
    code_signature_hash: value.controller.code_signature_hash,
  };
  requireCondition(value.version === 1 && value.result === 'passed'
    && value.cleanup_state === 'owner_disconnected'
    && /^[0-9a-f]{64}$/.test(value.execution_nonce ?? '')
    && Number.isSafeInteger(controller.pid) && controller.pid > 0
    && /^[1-9][0-9]*$/.test(controller.start_identity ?? '')
    && /^[0-9a-f]{40}$/.test(controller.code_signature_hash ?? '')
    && /^[0-9a-f]{40}$/.test(value.build.source_commit ?? '')
    && path.isAbsolute(value.build.executable_path)
    && /^[0-9a-f]{64}$/.test(value.build.executable_sha256 ?? '')
    && /^[A-Z0-9]{10}$/.test(value.build.team_id ?? '')
    && value.handshake.negotiated_version.major === 1
    && value.handshake.negotiated_version.minor === 30
    && value.handshake.host.source_commit === value.build.source_commit
    && value.handshake.session.client_instance_id === derivedHeldPointerClientID(value.execution_nonce)
    && value.target.scope === 'window' && value.target.is_minimized === false
    && [value.target.bounds.x, value.target.bounds.y, value.target.bounds.width,
      value.target.bounds.height].every((entry) => typeof entry === 'number' && Number.isFinite(entry))
    && value.target.bounds.width > 0 && value.target.bounds.height > 0
    && typeof value.point.x === 'number' && Number.isFinite(value.point.x)
    && typeof value.point.y === 'number' && Number.isFinite(value.point.y)
    && value.point.x >= value.target.bounds.x
    && value.point.x <= value.target.bounds.x + value.target.bounds.width
    && value.point.y >= value.target.bounds.y
    && value.point.y <= value.target.bounds.y + value.target.bounds.height
    && value.button === 'left' && value.hold_milliseconds === 500
    && Number.isSafeInteger(value.interval.started_at_milliseconds)
    && Number.isSafeInteger(value.interval.completed_at_milliseconds)
    && value.interval.completed_at_milliseconds >= value.interval.started_at_milliseconds
    && value.begin_dispatched_units === 2 && value.release_dispatched_units === 1
    && value.lifecycle_dispatched_units === 3 && value.terminal_reason === 'released'
    && Array.isArray(value.operations) && value.operations.length === 6,
  `${label} is not the closed source-owned 6-receipt result`);
  requireCondition(value.build.source_commit === adjunctBinding.sourceCommit
    && value.handshake.host.source_commit === adjunctBinding.sourceCommit
    && value.handshake.host_kind === adjunctBinding.expectedHost.host_kind
    && value.handshake.host.process.pid === adjunctBinding.expectedHost.pid
    && value.handshake.host.process.start_identity === adjunctBinding.expectedHost.start_identity
    && value.handshake.host.process.code_signature_hash
      === adjunctBinding.expectedHost.code_signature_hash,
  `${label} differs from the exact candidate Bridge host/build`);
  requireFixtureTarget(target, adjunctBinding, `${label} target`);
  const expectedOperations = [
    'listWindows', 'listWindows', 'createExactWindowHeldPointerOwner',
    'beginExactWindowHeldPointer', 'releaseExactWindowHeldPointer',
    'disconnectExactWindowHeldPointerOwner',
  ];
  const operations = value.operations.map((operation, index) => {
    exactKeys(operation, [
      'operation', 'request_id', 'session_sequence', 'listener_instance_id',
      'interval', 'outcome', 'bundle',
    ], `${label}.operations[${index}]`);
    exactKeys(operation.interval, ['started_at_milliseconds', 'completed_at_milliseconds'], `${label}.operations[${index}].interval`);
    exactKeys(operation.bundle, ['file', 'sha256', 'request_sha256', 'response_sha256'], `${label}.operations[${index}].bundle`);
    requireCondition(operation.operation === expectedOperations[index]
      && operation.session_sequence === String(index)
      && operation.listener_instance_id === value.handshake.listener_instance_id
      && /^[0-9a-f-]{36}$/.test(operation.request_id ?? '')
      && /^[0-9a-f]{64}$/.test(operation.bundle.sha256 ?? ''),
    `${label}.operations[${index}] is not closed and ordered`);
    return operation;
  });
  return {
    retained, value, target, controller, host: value.handshake.host.process, operations,
    receipt: { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 },
  };
}

function semanticAgentReadback(filePath, label) {
  const retained = readStableJSON(filePath, label);
  exactKeys(retained.value, [
    'version', 'target', 'phase', 'value', 'observed_at_milliseconds', 'passed',
  ], label);
  requireCondition(retained.value.version === 1
    && ['baseline', 'mutated', 'restored'].includes(retained.value.phase)
    && retained.value.passed === true
    && typeof retained.value.value === 'string'
    && Buffer.byteLength(retained.value.value) <= 4096
    && Number.isSafeInteger(retained.value.observed_at_milliseconds)
    && retained.value.observed_at_milliseconds > 0,
  `${label} is not one closed passing semantic readback`);
  const observation = corroboratedObservationTime(retained, label);
  const target = exactTarget(retained.value.target, `${label}.target`);
  return {
    receipt: { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 },
    target,
    phase: retained.value.phase,
    observed_at_milliseconds: observation.observed_at_milliseconds,
    retained_mtime_milliseconds: observation.retained_mtime_milliseconds,
    value_sha256: sha256(Buffer.from(retained.value.value, 'utf8')),
  };
}

function receiptArray(paths, label, exactCount = null) {
  requireCondition(Array.isArray(paths) && paths.length > 0, `${label} must be a nonempty file list`);
  if (exactCount !== null) requireCondition(paths.length === exactCount, `${label} must contain exactly ${exactCount} files`);
  requireCondition(new Set(paths).size === paths.length, `${label} reuses an evidence file`);
  return paths.map((filePath, index) => fileReceipt(filePath, `${label}[${index}]`));
}

function boundReceipt(filePath, expectedSHA256, label) {
  const receipt = fileReceipt(filePath, label);
  requireCondition(receipt.sha256 === expectedSHA256, `${label} differs from concurrent validation`);
  return receipt;
}

function semanticCertificationSummary(retained, expectedSHA256, monitorEvidencePath, label) {
  validateSuccessfulCertificationSummary(retained.value, label);
  const monitorEvidence = readStableJSON(
    monitorEvidencePath,
    `${label} monitor evidence`,
  );
  requireCondition(retained.value.monitor_evidence_sha256
    === multiTargetAggregateSHA256('monitor-evidence', monitorEvidence.value),
  `${label} belongs to another monitor run`);
  requireCondition(retained.sha256 === expectedSHA256,
    `${label} differs from concurrent validation`);
  return { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 };
}

function validateCertificationSummaryEventBinding(eventsPath, summary, label) {
  const events = readStableJSONLines(eventsPath, `${label} coordinator events`);
  const completed = events.values.at(-1);
  requireCondition(completed?.event === 'completed'
    && completed.certification_eligible === true
    && completed.summary_path === summary.path
    && completed.summary_size === summary.size
    && completed.summary_sha256 === summary.sha256,
  `${label} certification summary is not the coordinator's eligible completion output`);
}

function semanticTargetProcessReceipt(filePath, label) {
  const retained = readStableJSON(filePath, label);
  exactKeys(retained.value, ['pid', 'startIdentity'], label);
  requireCondition(Number.isSafeInteger(retained.value.pid) && retained.value.pid > 0
    && typeof retained.value.startIdentity === 'string'
    && /^[1-9][0-9]*$/.test(retained.value.startIdentity),
  `${label} is not one exact process generation`);
  return {
    retained,
    process: { pid: retained.value.pid, start_identity: retained.value.startIdentity },
    receipt: { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 },
  };
}

function adjunct(value, label, { kind, binding }) {
  const pointer = kind === 'held_pointer';
  const keys = ['raw_bundles', 'live_validator_reports', 'readbacks', 'restorations'];
  if (pointer) keys.push('controller_results', 'target_process_receipts', 'crash_inventories');
  exactKeys(value, keys, label);
  const rawCount = pointer ? 6 : 1;
  requireCondition(value.readbacks.length === 1 && value.restorations.length === 1,
    `${label} must contain exactly one semantic readback and restoration`);
  const projection = {
    raw_bundles: receiptArray(value.raw_bundles, `${label}.raw_bundles`, rawCount),
    live_validator_reports: receiptArray(value.live_validator_reports, `${label}.live_validator_reports`, rawCount),
    readbacks: receiptArray(value.readbacks, `${label}.readbacks`),
    restorations: receiptArray(value.restorations, `${label}.restorations`),
  };
  if (kind === 'middle_click') {
    const readback = semanticMiddleReadback(value.readbacks[0]);
    requireFixtureTarget(readback.target, binding, `${label} readback target`);
    const restoration = semanticRestoration(
      value.restorations[0], kind, readback.target, `${label} restoration`,
    );
    requireCondition(restoration.value.observed_at_milliseconds
      >= readback.retained.value.observed_at_milliseconds,
    `${label} restoration predates its effect readback`);
    const pair = semanticValidatorPair(
      value.raw_bundles[0],
      value.live_validator_reports[0],
      label,
      {
        expectedOperation: 'exactWindowTargetedClick',
        requireMutation: true,
        adjunctBinding: binding,
      },
    );
    requireCondition(sameJSON(targetFromPayload(pair.payload, label), readback.target),
      `${label} signed target differs from its semantic readback`);
  } else if (kind === 'held_key') {
    const readback = semanticHeldKeyReadback(value.readbacks[0]);
    requireFixtureTarget(readback.target, binding, `${label} readback target`);
    const restoration = semanticRestoration(
      value.restorations[0], kind, readback.target, `${label} restoration`,
    );
    requireCondition(restoration.value.observed_at_milliseconds
      >= readback.retained.value.observed_at_milliseconds
      && restoration.value.baseline_value === readback.retained.value.baseline_value,
    `${label} restoration predates or differs from its held-key baseline`);
    const pair = semanticValidatorPair(
      value.raw_bundles[0],
      value.live_validator_reports[0],
      label,
      {
        expectedOperation: 'exactWindowTargetedHotkey',
        requireMutation: true,
        adjunctBinding: binding,
      },
    );
    requireCondition(sameJSON(targetFromPayload(pair.payload, label), readback.target),
      `${label} signed target differs from its semantic readback`);
  } else if (pointer) {
    projection.controller_results = receiptArray(value.controller_results, `${label}.controller_results`, 1);
    projection.target_process_receipts = receiptArray(
      value.target_process_receipts, `${label}.target_process_receipts`, 2,
    );
    projection.crash_inventories = receiptArray(value.crash_inventories, `${label}.crash_inventories`, 1);
    const controller = semanticHeldControllerResult(value.controller_results[0], binding);
    const readback = semanticHeldPointerReadback(value.readbacks[0]);
    requireCondition(sameJSON(controller.target, readback.target),
      `${label} controller target differs from its semantic readback`);
    const restoration = semanticRestoration(
      value.restorations[0], kind, readback.target, `${label} restoration`,
    );
    requireCondition(restoration.value.observed_at_milliseconds
      >= readback.retained.value.observed_at_milliseconds,
    `${label} restoration predates its effect readback`);
    const targetProcesses = value.target_process_receipts.map((filePath, index) => (
      semanticTargetProcessReceipt(filePath, `${label} target process ${index}`)
    ));
    requireCondition(targetProcesses.every((entry) => (
      entry.process.pid === controller.target.pid
        && entry.process.start_identity === controller.target.start_identity
    )), `${label} target generation changed across the physical lifecycle`);
    semanticCrashComparison(value.crash_inventories[0], `${label} crash comparison`);
    const operations = [];
    const listenerIDs = new Set();
    const expectedOperations = controller.operations.map((entry) => entry.operation);
    for (let index = 0; index < value.raw_bundles.length; index += 1) {
      const pair = semanticValidatorPair(
        value.raw_bundles[index],
        value.live_validator_reports[index],
        `${label}[${index}]`,
        { adjunctBinding: binding },
      );
      requireCondition(pair.report.host_source_commit === controller.value.build.source_commit,
        `${label}[${index}] host source differs from the controller result`);
      operations.push(pair.payload.operation);
      listenerIDs.add(pair.report.listener_instance_id);
      requireCondition(pair.report.host.pid === controller.host.pid
        && pair.report.host.start_identity === controller.host.start_identity
        && pair.report.host.code_signature_hash === controller.host.code_signature_hash
        && pair.report.client.pid === controller.controller.pid
        && pair.report.client.start_identity === controller.controller.start_identity
        && pair.report.client.code_signature_hash === controller.controller.code_signature_hash
        && pair.report.listener_instance_id === controller.value.handshake.listener_instance_id
        && pair.report.client_instance_id
          === controller.value.handshake.session.client_instance_id
        && pair.report.session_sequence === controller.operations[index].session_sequence
        && pair.report.request_id === controller.operations[index].request_id
        && pair.payload.operation === expectedOperations[index]
        && pair.bundle.sha256 === controller.operations[index].bundle.sha256
        && sameJSON(pair.payload.outcome ?? null, controller.operations[index].outcome),
      `${label}[${index}] signed controller, host, listener, request, or operation differs`);
      const targetBoundOperations = [
        'listWindows', 'beginExactWindowHeldPointer', 'releaseExactWindowHeldPointer',
      ];
      if (targetBoundOperations.includes(pair.payload.operation)) {
        requireCondition(pair.report.target_attested === true
          && sameJSON(targetFromPayload(pair.payload, `${label}[${index}]`), controller.target),
        `${label}[${index}] held-pointer target-bearing operation differs from the controlled fixture`);
        if (pair.payload.operation !== 'listWindows') {
          requireCondition(pair.report.outcome_attested === true
            && pair.payload.outcome?.delivery_mode === 'background'
            && pair.payload.outcome?.delivery_mechanism === 'window_targeted_events'
            && pair.payload.outcome?.dispatched_unit_count
              === (pair.payload.operation === 'beginExactWindowHeldPointer' ? 2 : 1),
          `${label}[${index}] held-pointer mutation is not target-attested background delivery`);
        }
      } else {
        requireCondition(pair.payload.target == null && pair.report.target_attested === false,
          `${label}[${index}] targetless held-pointer operation claimed a target`);
      }
      if (pair.payload.operation === 'disconnectExactWindowHeldPointerOwner') {
        requireCondition(pair.payload.target == null
          && pair.report.target_attested === false
          && pair.report.outcome_attested === true
          && pair.payload.outcome?.state === 'confirmed_no_change'
          && pair.payload.outcome?.evidence === 'verified_no_change'
          && pair.payload.outcome?.dispatch_state === 'none'
          && pair.payload.outcome?.mutation_dispatched === false,
        `${label}[${index}] owner disconnect is not one signed successful no-change cleanup`);
      }
    }
    requireCondition(sameJSON(operations, [
      'listWindows',
      'listWindows',
      'createExactWindowHeldPointerOwner',
      'beginExactWindowHeldPointer',
      'releaseExactWindowHeldPointer',
      'disconnectExactWindowHeldPointerOwner',
    ]), `${label} six-bundle operation sequence is not closed`);
    requireCondition(listenerIDs.size === 1,
      `${label} six-bundle corpus spans multiple live listeners`);
  } else {
    throw new Error(`${label} kind is unsupported`);
  }
  return projection;
}

function projectInput(input, authenticateBundle) {
  exactKeys(input, [
    'version', 'artifact_manifest', 'deployment', 'tooling', 'live_v4', 'matrix_cycles',
    'agent_cu', 'adjuncts', 'restoration_cleanup',
  ], 'qualification manifest input');
  requireCondition(input.version === 2, 'qualification manifest input version is not 2');
  exactKeys(input.tooling, [
    'qualification_tools_manifest', 'plan_constructor', 'crash_scanner',
  ], 'tooling');
  exactKeys(input.live_v4, [
    'plan', 'coordinator_identity_handshake', 'coordinator_invocation',
    'coordinator_events', 'coordinator_exit', 'certification_summary', 'monitor_evidence',
  ], 'live_v4');
  exactKeys(input.agent_cu, [
    'task', 'agent_result', 'agent_exit', 'agent_invocation', 'agent_process_receipts', 'agent_readbacks',
    'signed_bundles', 'live_validator_reports', 'semantic_readbacks',
    'integrated_cu_emitter_receipt', 'perform_readback', 'restore_readback', 'validation_report',
  ], 'agent_cu');
  exactKeys(input.adjuncts, ['middle_click', 'held_key', 'held_pointer'], 'adjuncts');
  exactKeys(input.restoration_cleanup, ['restoration_evidence', 'cleanup_evidence'], 'restoration_cleanup');
  const deployment = semanticDeploymentEvidence(input.deployment, 'deployment');
  const artifacts = semanticArtifactBinding(input.artifact_manifest, 'artifact manifest', deployment);
  validatePeekabooArtifactDeployment(artifacts.peekaboo, deployment, 'artifact manifest');
  requireCondition(deployment.elevations.every((elevation) => (
    elevation.value.artifactReceiptSha256 === artifacts.evidence.openclaw_artifact_receipt.sha256
      && elevation.value.archiveSha256 === artifacts.openclaw.archiveSha256
      && elevation.value.installerSha256 === artifacts.openclaw.installerSha256
      && sameJSON(elevation.value.cdhashes, artifacts.openclaw.cdhashes)
  )), 'elevation receipts differ from the authenticated OpenClaw artifact');
  requireCondition(Array.isArray(input.matrix_cycles) && input.matrix_cycles.length === 5, 'exactly five matrix cycles are required');
  const matrixCycles = input.matrix_cycles.map((cycle, index) => {
    exactKeys(cycle, ['certificate', 'crash_inventory'], `matrix_cycles[${index}]`);
    const certificate = semanticCertificate(
      cycle.certificate,
      `matrix cycle ${index + 1} certificate`,
      {
        cycle: index + 1,
        hostUUID: deployment.installed[0].hostUUID,
        sourceCommit: deployment.peekabooSourceCommit,
        deploymentEnvelopeSHA256: deployment.installed[0].envelopeSHA256,
        installedInventoryAggregateSHA256: deployment.installed[0].aggregateSHA256,
        peekabooArtifactManifestSHA256: artifacts.evidence.peekaboo_artifact_manifest.sha256,
      },
    );
    return {
      cycle: index + 1,
      certificate: certificate.receipt,
      crash_inventory: semanticCrashComparison(
        cycle.crash_inventory,
        `matrix cycle ${index + 1} crash comparison`,
        certificate.value,
      ),
      binding: certificate.value,
    };
  });
  requireCondition(new Set(matrixCycles.map((cycle) => cycle.binding.execution_nonce)).size
    === matrixCycles.length, 'matrix cycle nonces are not distinct');
  requireCondition(matrixCycles.every((cycle, index) => index === 0
    || matrixCycles[index - 1].binding.completed_at_milliseconds
      < cycle.binding.started_at_milliseconds), 'matrix cycle intervals overlap or are not ordered');
  const concurrentValidation = semanticConcurrentValidation(input.agent_cu.validation_report);
  const concurrentValue = concurrentValidation.value;
  const boundCertificationSummary = readStableJSON(
    input.live_v4.certification_summary,
    'bound certification summary',
  );
  const boundLive = {
    plan: boundReceipt(input.live_v4.plan, concurrentValue.coordinator.plan_sha256, 'bound live-v4 plan'),
    coordinator_invocation: boundReceipt(
      input.live_v4.coordinator_invocation,
      concurrentValue.coordinator.invocation_sha256,
      'bound coordinator invocation',
    ),
    coordinator_events: boundReceipt(
      input.live_v4.coordinator_events,
      concurrentValue.coordinator.events_sha256,
      'bound coordinator events',
    ),
    coordinator_exit: boundReceipt(
      input.live_v4.coordinator_exit,
      concurrentValue.coordinator.exit_receipt_sha256,
      'bound coordinator exit',
    ),
    certification_summary: semanticCertificationSummary(
      boundCertificationSummary,
      concurrentValue.coordinator.summary_sha256,
      input.live_v4.monitor_evidence,
      'bound certification summary',
    ),
    monitor_evidence: boundReceipt(
      input.live_v4.monitor_evidence,
      concurrentValue.coordinator.monitor_evidence_sha256,
      'bound monitor evidence',
    ),
  };
  validateCertificationSummaryEventBinding(
    boundLive.coordinator_events.path,
    boundLive.certification_summary,
    'bound live-v4',
  );
  const boundPlanValue = readStableJSON(
    boundLive.plan.path,
    'bound live-v4 plan semantics',
  ).value;
  validateLocalDuringConcurrentBinding(
    deployment,
    concurrentValue,
    boundPlanValue,
    'deployment',
  );
  const adjunctBinding = qualificationAdjunctBinding(
    deployment,
    boundPlanValue,
    'bound live-v4 plan',
  );
  validateControlledFixtureSummary(
    boundCertificationSummary,
    adjunctBinding.fixtureBinding,
    'bound final certification summary',
  );
  const coordinatorInvocation = readStableJSON(
    input.live_v4.coordinator_invocation,
    'bound coordinator invocation semantics',
  ).value;
  const boundCoordinatorHandshake = fileReceipt(
    input.live_v4.coordinator_identity_handshake,
    'bound coordinator identity handshake',
  );
  requireCondition(coordinatorInvocation.identity_handshake_path
    === input.live_v4.coordinator_identity_handshake
    && coordinatorInvocation.identity_handshake_sha256 === boundCoordinatorHandshake.sha256,
  'coordinator identity handshake differs from its invocation');
  const boundAgent = {
    invocation: boundReceipt(
      input.agent_cu.agent_invocation,
      concurrentValue.agent.invocation_sha256,
      'bound Agent invocation',
    ),
    result: boundReceipt(input.agent_cu.agent_result, concurrentValue.agent.result_sha256, 'bound Agent result'),
    exit: boundReceipt(input.agent_cu.agent_exit, concurrentValue.agent.exit_receipt_sha256, 'bound Agent exit'),
    readbacks: boundReceipt(
      input.agent_cu.agent_readbacks,
      concurrentValue.agent.readbacks_sha256,
      'bound Agent readback map',
    ),
    emitter: boundReceipt(
      input.agent_cu.integrated_cu_emitter_receipt,
      concurrentValue.integrated_cu.calibration_sha256,
      'bound integrated-CU emitter',
    ),
    perform: boundReceipt(
      input.agent_cu.perform_readback,
      concurrentValue.integrated_cu.perform_readback_sha256,
      'bound integrated-CU perform readback',
    ),
    restore: boundReceipt(
      input.agent_cu.restore_readback,
      concurrentValue.integrated_cu.restore_readback_sha256,
      'bound integrated-CU restore readback',
    ),
  };
  const agentInvocation = readStableJSON(
    input.agent_cu.agent_invocation,
    'bound Agent invocation semantics',
  ).value;
  const authentication = agentBundleAuthentication(
    boundPlanValue,
    agentInvocation,
    authenticateBundle,
    'Agent manifest',
  );
  const boundAgentTask = fileReceipt(input.agent_cu.task, 'bound Agent task');
  requireCondition(agentInvocation.task_path === input.agent_cu.task
    && agentInvocation.task_sha256 === boundAgentTask.sha256,
  'Agent task differs from its invocation');
  validateExercisedCandidateBindings(
    artifacts.peekaboo,
    deployment,
    concurrentValue,
    agentInvocation,
    'qualification',
  );
  const processPhases = ['launch', 'perform', 'restore'];
  requireCondition(input.agent_cu.agent_process_receipts.length === processPhases.length,
    'Agent process receipt ordering is incomplete');
  const boundAgentProcessReceipts = input.agent_cu.agent_process_receipts.map((filePath, index) => (
    boundReceipt(
      filePath,
      concurrentValue.agent.process_receipt_sha256[processPhases[index]],
      `bound Agent ${processPhases[index]} process receipt`,
    )
  ));
  requireCondition(Array.isArray(input.agent_cu.signed_bundles)
    && input.agent_cu.signed_bundles.length >= 4
    && Array.isArray(input.agent_cu.live_validator_reports)
    && input.agent_cu.live_validator_reports.length === input.agent_cu.signed_bundles.length,
  'Agent manifest evidence needs every signed bundle and matching live validator');
  const bundleReceipts = [];
  const validatorReceipts = [];
  const semanticBundleProjection = [];
  const semanticBundlePairs = [];
  for (let index = 0; index < input.agent_cu.signed_bundles.length; index += 1) {
    const pair = semanticValidatorPair(
      input.agent_cu.signed_bundles[index],
      input.agent_cu.live_validator_reports[index],
      `Agent manifest bundle ${index}`,
      { authentication },
    );
    semanticBundlePairs.push(pair);
    bundleReceipts.push({ path: pair.bundle.path, size: pair.bundle.bytes.length, sha256: pair.bundle.sha256 });
    validatorReceipts.push({
      path: pair.validator.path,
      size: pair.validator.bytes.length,
      sha256: pair.validator.sha256,
    });
    semanticBundleProjection.push({
      bundle_path: pair.bundle.path,
      bundle_sha256: pair.bundle.sha256,
      validator_report_path: pair.validator.path,
      validator_report_sha256: pair.validator.sha256,
      operation: pair.payload.operation,
    });
  }
  requireUniqueAuthenticatedBridgeReceipts(
    semanticBundlePairs,
    'Agent manifest bundle corpus',
  );
  requireCondition(sameJSON(
    semanticBundleProjection.sort((left, right) => left.bundle_path.localeCompare(right.bundle_path)),
    [...concurrentValidation.value.agent.signed_bundles]
      .sort((left, right) => left.bundle_path.localeCompare(right.bundle_path)),
  ), 'Agent manifest bundle corpus differs from concurrent validation');
  validateConcurrentInterleavingBinding(
    concurrentValue,
    input.agent_cu.agent_readbacks,
    semanticBundlePairs,
    input.agent_cu.perform_readback,
    adjunctBinding.controlledFixtureTargets,
    'Agent manifest',
  );
  requireCondition(Array.isArray(input.agent_cu.semantic_readbacks)
    && input.agent_cu.semantic_readbacks.length === 6,
  'Agent manifest needs exactly six semantic readbacks');
  const semanticReadbacks = input.agent_cu.semantic_readbacks.map((filePath, index) => (
    semanticAgentReadback(filePath, `Agent manifest semantic readback ${index}`)
  ));
  const phaseCounts = Object.fromEntries(['baseline', 'mutated', 'restored'].map((phase) => [
    phase,
    semanticReadbacks.filter((entry) => entry.phase === phase).length,
  ]));
  requireCondition(phaseCounts.baseline === 2 && phaseCounts.mutated === 2 && phaseCounts.restored === 2,
    'Agent semantic readback phases are not exactly 2 baseline/2 mutated/2 restored');
  requireCondition(sameJSON(
    semanticReadbacks.map((entry) => ({
      path: entry.receipt.path,
      sha256: entry.receipt.sha256,
      observed_at_milliseconds: entry.observed_at_milliseconds,
      value_sha256: entry.value_sha256,
    }))
      .sort((left, right) => left.path.localeCompare(right.path)),
    concurrentValidation.value.agent.semantic_readbacks
      .map((entry) => ({
        path: entry.path,
        sha256: entry.sha256,
        observed_at_milliseconds: entry.observed_at_milliseconds,
        value_sha256: entry.value_sha256,
      })).sort((left, right) => left.path.localeCompare(right.path)),
  ), 'Agent semantic readbacks differ from concurrent validation');
  const qualificationTools = semanticSourceManifest(
    input.tooling.qualification_tools_manifest,
    'qualification tools source manifest',
    QUALIFICATION_TOOL_FILES,
    deployment.peekabooSourceCommit,
  );
  requireCondition(qualificationTools.value.aggregate_sha256
    === deployment.qualificationToolsAggregateSHA256,
  'qualification tools aggregate differs from installed inventories');
  validateDeploymentToolSources(
    deployment,
    qualificationTools.value,
    artifacts.peekaboo,
    'deployment',
  );
  return {
    artifact_manifest: artifacts.evidence,
    deployment: deployment.evidence,
    tooling: {
      qualification_tools_manifest: {
        path: qualificationTools.retained.path,
        size: qualificationTools.retained.bytes.length,
        sha256: qualificationTools.retained.sha256,
      },
      plan_constructor: fileReceipt(input.tooling.plan_constructor, 'live-v4 plan constructor'),
      crash_scanner: fileReceipt(input.tooling.crash_scanner, 'crash scanner'),
    },
    live_v4: {
      plan: boundLive.plan,
      coordinator_identity_handshake: boundCoordinatorHandshake,
      coordinator_invocation: boundLive.coordinator_invocation,
      coordinator_events: boundLive.coordinator_events,
      coordinator_exit: boundLive.coordinator_exit,
      certification_summary: boundLive.certification_summary,
      monitor_evidence: boundLive.monitor_evidence,
    },
    matrix_cycles: matrixCycles.map(({ binding: _binding, ...cycle }) => cycle),
    agent_cu: {
      task: boundAgentTask,
      agent_result: boundAgent.result,
      agent_exit: boundAgent.exit,
      agent_invocation: boundAgent.invocation,
      agent_process_receipts: boundAgentProcessReceipts,
      agent_readbacks: boundAgent.readbacks,
      controlled_fixture_targets: structuredClone(adjunctBinding.controlledFixtureTargets),
      signed_bundles: bundleReceipts,
      live_validator_reports: validatorReceipts,
      semantic_readbacks: semanticReadbacks.map((entry) => entry.receipt),
      integrated_cu_emitter_receipt: boundAgent.emitter,
      perform_readback: boundAgent.perform,
      restore_readback: boundAgent.restore,
      validation_report: concurrentValidation.receipt,
    },
    adjuncts: {
      middle_click: adjunct(input.adjuncts.middle_click, 'adjuncts.middle_click', {
        kind: 'middle_click', binding: adjunctBinding,
      }),
      held_key: adjunct(input.adjuncts.held_key, 'adjuncts.held_key', {
        kind: 'held_key', binding: adjunctBinding,
      }),
      held_pointer: adjunct(input.adjuncts.held_pointer, 'adjuncts.held_pointer', {
        kind: 'held_pointer', binding: adjunctBinding,
      }),
    },
    restoration_cleanup: {
      restoration_evidence: receiptArray(input.restoration_cleanup.restoration_evidence, 'restoration evidence'),
      cleanup_evidence: receiptArray(input.restoration_cleanup.cleanup_evidence, 'cleanup evidence'),
    },
  };
}

function validateEvidenceShape(evidence, visitReceipt) {
  exactKeys(evidence, [
    'artifact_manifest', 'deployment', 'tooling', 'live_v4', 'matrix_cycles', 'agent_cu',
    'adjuncts', 'restoration_cleanup',
  ], 'qualification evidence');
  exactKeys(evidence.artifact_manifest, [
    'binding', 'peekaboo_artifact_manifest', 'openclaw_artifact_receipt',
  ], 'evidence.artifact_manifest');
  for (const [key, receipt] of Object.entries(evidence.artifact_manifest)) {
    visitReceipt(receipt, `evidence.artifact_manifest.${key}`);
  }
  exactKeys(evidence.deployment, [
    'installed_inventories', 'elevation_receipts', 'process_tree_collector',
    'process_tree_monitor', 'process_trees',
    'executable_policy_scanner', 'executable_policy_reports',
  ], 'evidence.deployment');
  requireCondition(Array.isArray(evidence.deployment.installed_inventories)
    && evidence.deployment.installed_inventories.length === DEPLOYMENT_HOST_ROLES.length,
  'qualification evidence must contain local and Studio installed inventories');
  requireCondition(Array.isArray(evidence.deployment.process_trees)
    && evidence.deployment.process_trees.length
      === DEPLOYMENT_HOST_ROLES.length * PROCESS_TREE_EPOCHS.length,
  'qualification evidence must contain all host process-tree epochs');
  requireCondition(Array.isArray(evidence.deployment.elevation_receipts)
    && evidence.deployment.elevation_receipts.length === DEPLOYMENT_HOST_ROLES.length,
  'qualification evidence must contain both elevation receipts');
  requireCondition(Array.isArray(evidence.deployment.executable_policy_reports)
    && evidence.deployment.executable_policy_reports.length === DEPLOYMENT_HOST_ROLES.length,
  'qualification evidence must contain both executable policy reports');
  for (const key of [
    'installed_inventories', 'elevation_receipts', 'process_trees', 'executable_policy_reports',
  ]) {
    evidence.deployment[key].forEach((receipt, index) => visitReceipt(
      receipt,
      `evidence.deployment.${key}[${index}]`,
    ));
  }
  visitReceipt(evidence.deployment.process_tree_collector, 'evidence.deployment.process_tree_collector');
  visitReceipt(evidence.deployment.process_tree_monitor, 'evidence.deployment.process_tree_monitor');
  visitReceipt(evidence.deployment.executable_policy_scanner, 'evidence.deployment.executable_policy_scanner');
  exactKeys(evidence.tooling, [
    'qualification_tools_manifest', 'plan_constructor', 'crash_scanner',
  ], 'evidence.tooling');
  for (const [key, receipt] of Object.entries(evidence.tooling)) {
    visitReceipt(receipt, `evidence.tooling.${key}`);
  }
  exactKeys(evidence.live_v4, [
    'plan', 'coordinator_identity_handshake', 'coordinator_invocation',
    'coordinator_events', 'coordinator_exit', 'certification_summary', 'monitor_evidence',
  ], 'evidence.live_v4');
  for (const [key, receipt] of Object.entries(evidence.live_v4)) {
    visitReceipt(receipt, `evidence.live_v4.${key}`);
  }
  requireCondition(Array.isArray(evidence.matrix_cycles) && evidence.matrix_cycles.length === 5,
    'qualification evidence must contain five matrix cycles');
  evidence.matrix_cycles.forEach((cycle, index) => {
    exactKeys(cycle, ['cycle', 'certificate', 'crash_inventory'], `evidence.matrix_cycles[${index}]`);
    requireCondition(cycle.cycle === index + 1, `evidence matrix cycle ${index + 1} is misnumbered`);
    visitReceipt(cycle.certificate, `evidence.matrix_cycles[${index}].certificate`);
    visitReceipt(cycle.crash_inventory, `evidence.matrix_cycles[${index}].crash_inventory`);
  });
  exactKeys(evidence.agent_cu, [
    'task', 'agent_result', 'agent_exit', 'agent_invocation', 'agent_process_receipts', 'agent_readbacks',
    'controlled_fixture_targets', 'signed_bundles', 'live_validator_reports', 'semantic_readbacks',
    'integrated_cu_emitter_receipt', 'perform_readback', 'restore_readback', 'validation_report',
  ], 'evidence.agent_cu');
  requireCondition(Array.isArray(evidence.agent_cu.controlled_fixture_targets)
    && evidence.agent_cu.controlled_fixture_targets.length === 2,
  'qualification evidence must contain both controlled Agent fixture targets');
  evidence.agent_cu.controlled_fixture_targets.forEach((binding, index) => {
    const suffix = index === 0 ? 'a' : 'b';
    exactKeys(binding, ['label', 'controller_id', 'target'],
      `evidence.agent_cu.controlled_fixture_targets[${index}]`);
    requireCondition(binding.label === `target-${suffix}`
      && binding.controller_id === `controller-${suffix}`,
    `evidence.agent_cu.controlled_fixture_targets[${index}] is not canonical`);
    exactTarget(binding.target, `evidence.agent_cu.controlled_fixture_targets[${index}].target`);
  });
  for (const key of [
    'task', 'agent_result', 'agent_exit', 'agent_invocation', 'agent_readbacks', 'integrated_cu_emitter_receipt',
    'perform_readback', 'restore_readback', 'validation_report',
  ]) visitReceipt(evidence.agent_cu[key], `evidence.agent_cu.${key}`);
  requireCondition(Array.isArray(evidence.agent_cu.agent_process_receipts)
    && evidence.agent_cu.agent_process_receipts.length === 3,
  'qualification evidence must contain three Agent process receipts');
  evidence.agent_cu.agent_process_receipts.forEach((receipt, index) => (
    visitReceipt(receipt, `evidence.agent_cu.agent_process_receipts[${index}]`)
  ));
  requireCondition(Array.isArray(evidence.agent_cu.signed_bundles)
    && evidence.agent_cu.signed_bundles.length >= 4
    && Array.isArray(evidence.agent_cu.live_validator_reports)
    && evidence.agent_cu.live_validator_reports.length === evidence.agent_cu.signed_bundles.length,
  'qualification evidence Agent bundle/validator corpus is incomplete');
  requireCondition(Array.isArray(evidence.agent_cu.semantic_readbacks)
    && evidence.agent_cu.semantic_readbacks.length === 6,
  'qualification evidence must contain six Agent semantic readbacks');
  for (const key of ['signed_bundles', 'live_validator_reports', 'semantic_readbacks']) {
    evidence.agent_cu[key].forEach((receipt, index) => visitReceipt(
      receipt,
      `evidence.agent_cu.${key}[${index}]`,
    ));
  }
  exactKeys(evidence.adjuncts, ['middle_click', 'held_key', 'held_pointer'], 'evidence.adjuncts');
  for (const [name, expectedRawCount, pointer] of [
    ['middle_click', 1, false], ['held_key', 1, false], ['held_pointer', 6, true],
  ]) {
    const value = evidence.adjuncts[name];
    const keys = ['raw_bundles', 'live_validator_reports', 'readbacks', 'restorations'];
    if (pointer) keys.push('controller_results', 'target_process_receipts', 'crash_inventories');
    exactKeys(value, keys, `evidence.adjuncts.${name}`);
    requireCondition(Array.isArray(value.raw_bundles) && value.raw_bundles.length === expectedRawCount,
      `evidence.adjuncts.${name} raw bundle count is invalid`);
    requireCondition(Array.isArray(value.live_validator_reports)
      && value.live_validator_reports.length === expectedRawCount,
    `evidence.adjuncts.${name} validator count is invalid`);
    for (const key of ['raw_bundles', 'live_validator_reports', 'readbacks', 'restorations']) {
      requireCondition(Array.isArray(value[key]) && value[key].length > 0,
        `evidence.adjuncts.${name}.${key} must be nonempty`);
      value[key].forEach((receipt, index) => visitReceipt(
        receipt,
        `evidence.adjuncts.${name}.${key}[${index}]`,
      ));
    }
    requireCondition(value.readbacks.length === 1 && value.restorations.length === 1,
      `evidence.adjuncts.${name} must have exactly one readback/restoration`);
    if (pointer) {
      requireCondition(Array.isArray(value.controller_results)
        && value.controller_results.length === 1,
      'held-pointer controller result count is invalid');
      requireCondition(Array.isArray(value.target_process_receipts)
        && value.target_process_receipts.length === 2,
      'held-pointer target process receipt count is invalid');
      requireCondition(Array.isArray(value.crash_inventories)
        && value.crash_inventories.length === 1,
      'held-pointer crash comparison count is invalid');
      for (const key of ['controller_results', 'target_process_receipts', 'crash_inventories']) {
        value[key].forEach((receipt, index) => visitReceipt(
          receipt,
          `evidence.adjuncts.${name}.${key}[${index}]`,
        ));
      }
    }
  }
  exactKeys(evidence.restoration_cleanup, ['restoration_evidence', 'cleanup_evidence'],
    'evidence.restoration_cleanup');
  for (const key of ['restoration_evidence', 'cleanup_evidence']) {
    requireCondition(Array.isArray(evidence.restoration_cleanup[key])
      && evidence.restoration_cleanup[key].length > 0,
    `evidence.restoration_cleanup.${key} must be nonempty`);
    evidence.restoration_cleanup[key].forEach((receipt, index) => visitReceipt(
      receipt,
      `evidence.restoration_cleanup.${key}[${index}]`,
    ));
  }
}

function validateSemanticEvidence(evidence, authenticateBundle) {
  const deployment = semanticDeploymentEvidence({
    installed_inventories: evidence.deployment.installed_inventories.map((entry) => entry.path),
    elevation_receipts: evidence.deployment.elevation_receipts.map((entry) => entry.path),
    process_tree_collector: evidence.deployment.process_tree_collector.path,
    process_tree_monitor: evidence.deployment.process_tree_monitor.path,
    process_trees: evidence.deployment.process_trees.map((entry) => entry.path),
    executable_policy_scanner: evidence.deployment.executable_policy_scanner.path,
    executable_policy_reports: evidence.deployment.executable_policy_reports.map((entry) => entry.path),
  }, 'verified deployment');
  const artifacts = semanticArtifactBinding(
    evidence.artifact_manifest.binding.path,
    'verified artifact manifest',
    deployment,
  );
  requireCondition(sameJSON(artifacts.evidence, evidence.artifact_manifest),
    'verified artifact evidence differs from the manifest');
  validatePeekabooArtifactDeployment(
    artifacts.peekaboo,
    deployment,
    'verified artifact manifest',
  );
  requireCondition(deployment.elevations.every((elevation) => (
    elevation.value.artifactReceiptSha256 === artifacts.evidence.openclaw_artifact_receipt.sha256
      && elevation.value.archiveSha256 === artifacts.openclaw.archiveSha256
      && elevation.value.installerSha256 === artifacts.openclaw.installerSha256
      && sameJSON(elevation.value.cdhashes, artifacts.openclaw.cdhashes)
  )), 'verified elevation receipts differ from the authenticated OpenClaw artifact');
  const qualificationTools = semanticSourceManifest(
    evidence.tooling.qualification_tools_manifest.path,
    'verified qualification tools source manifest',
    QUALIFICATION_TOOL_FILES,
    deployment.peekabooSourceCommit,
  );
  requireCondition(qualificationTools.value.aggregate_sha256
    === deployment.qualificationToolsAggregateSHA256,
  'verified qualification tools aggregate differs from installed inventories');
  validateDeploymentToolSources(
    deployment,
    qualificationTools.value,
    artifacts.peekaboo,
    'verified deployment',
  );
  const matrixBindings = evidence.matrix_cycles.map((cycle, index) => {
    const certificate = semanticCertificate(
      cycle.certificate.path,
      `verified matrix cycle ${index + 1} certificate`,
      {
        cycle: index + 1,
        hostUUID: deployment.installed[0].hostUUID,
        sourceCommit: deployment.peekabooSourceCommit,
        deploymentEnvelopeSHA256: deployment.installed[0].envelopeSHA256,
        installedInventoryAggregateSHA256: deployment.installed[0].aggregateSHA256,
        peekabooArtifactManifestSHA256: artifacts.evidence.peekaboo_artifact_manifest.sha256,
      },
    );
    semanticCrashComparison(
      cycle.crash_inventory.path,
      `verified matrix cycle ${index + 1} crash comparison`,
      certificate.value,
    );
    return certificate.value;
  });
  requireCondition(new Set(matrixBindings.map((cycle) => cycle.execution_nonce)).size
    === matrixBindings.length, 'verified matrix cycle nonces are not distinct');
  requireCondition(matrixBindings.every((cycle, index) => index === 0
    || matrixBindings[index - 1].completed_at_milliseconds < cycle.started_at_milliseconds),
  'verified matrix cycle intervals overlap or are not ordered');
  const concurrent = semanticConcurrentValidation(evidence.agent_cu.validation_report.path);
  const concurrentValue = concurrent.value;
  for (const [receipt, expected, label] of [
    [evidence.live_v4.plan, concurrentValue.coordinator.plan_sha256, 'verified live-v4 plan'],
    [evidence.live_v4.coordinator_invocation, concurrentValue.coordinator.invocation_sha256, 'verified coordinator invocation'],
    [evidence.live_v4.coordinator_events, concurrentValue.coordinator.events_sha256, 'verified coordinator events'],
    [evidence.live_v4.coordinator_exit, concurrentValue.coordinator.exit_receipt_sha256, 'verified coordinator exit'],
    [evidence.live_v4.certification_summary, concurrentValue.coordinator.summary_sha256, 'verified certification summary'],
    [evidence.live_v4.monitor_evidence, concurrentValue.coordinator.monitor_evidence_sha256, 'verified monitor evidence'],
    [evidence.agent_cu.agent_invocation, concurrentValue.agent.invocation_sha256, 'verified Agent invocation'],
    [evidence.agent_cu.agent_result, concurrentValue.agent.result_sha256, 'verified Agent result'],
    [evidence.agent_cu.agent_exit, concurrentValue.agent.exit_receipt_sha256, 'verified Agent exit'],
    [evidence.agent_cu.agent_readbacks, concurrentValue.agent.readbacks_sha256, 'verified Agent readbacks'],
    [evidence.agent_cu.integrated_cu_emitter_receipt, concurrentValue.integrated_cu.calibration_sha256, 'verified CU emitter'],
    [evidence.agent_cu.perform_readback, concurrentValue.integrated_cu.perform_readback_sha256, 'verified CU perform'],
    [evidence.agent_cu.restore_readback, concurrentValue.integrated_cu.restore_readback_sha256, 'verified CU restore'],
  ]) requireCondition(receipt.sha256 === expected, `${label} differs from concurrent validation`);
  const verifiedCertificationSummary = readStableJSON(
    evidence.live_v4.certification_summary.path,
    'verified final certification summary',
  );
  semanticCertificationSummary(
    verifiedCertificationSummary,
    concurrentValue.coordinator.summary_sha256,
    evidence.live_v4.monitor_evidence.path,
    'verified certification summary',
  );
  validateCertificationSummaryEventBinding(
    evidence.live_v4.coordinator_events.path,
    evidence.live_v4.certification_summary,
    'verified live-v4',
  );
  const verifiedPlanValue = readStableJSON(
    evidence.live_v4.plan.path,
    'verified live-v4 plan semantics',
  ).value;
  requireCondition(sameJSON(evidence.live_v4.certification_summary, {
    path: verifiedCertificationSummary.path,
    size: verifiedCertificationSummary.bytes.length,
    sha256: verifiedCertificationSummary.sha256,
  }), 'verified final certification summary changed after manifest generation');
  validateLocalDuringConcurrentBinding(
    deployment,
    concurrentValue,
    verifiedPlanValue,
    'verified deployment',
  );
  const adjunctBinding = qualificationAdjunctBinding(
    deployment,
    verifiedPlanValue,
    'verified live-v4 plan',
  );
  validateControlledFixtureSummary(
    verifiedCertificationSummary,
    adjunctBinding.fixtureBinding,
    'verified final certification summary',
  );
  const phases = ['launch', 'perform', 'restore'];
  evidence.agent_cu.agent_process_receipts.forEach((receipt, index) => {
    requireCondition(receipt.sha256 === concurrentValue.agent.process_receipt_sha256[phases[index]],
      `verified Agent ${phases[index]} process receipt differs from concurrent validation`);
  });
  const coordinatorInvocation = readStableJSON(
    evidence.live_v4.coordinator_invocation.path,
    'verified coordinator invocation semantics',
  ).value;
  requireCondition(coordinatorInvocation.identity_handshake_path
    === evidence.live_v4.coordinator_identity_handshake.path
    && coordinatorInvocation.identity_handshake_sha256
      === evidence.live_v4.coordinator_identity_handshake.sha256,
  'verified coordinator identity handshake differs from its invocation');
  const agentInvocation = readStableJSON(
    evidence.agent_cu.agent_invocation.path,
    'verified Agent invocation semantics',
  ).value;
  const authentication = agentBundleAuthentication(
    verifiedPlanValue,
    agentInvocation,
    authenticateBundle,
    'verified Agent manifest',
  );
  requireCondition(agentInvocation.task_path === evidence.agent_cu.task.path
    && agentInvocation.task_sha256 === evidence.agent_cu.task.sha256,
  'verified Agent task differs from its invocation');
  validateExercisedCandidateBindings(
    artifacts.peekaboo,
    deployment,
    concurrentValue,
    agentInvocation,
    'verified qualification',
  );
  const verifiedBundlePairs = [];
  const bundleProjection = evidence.agent_cu.signed_bundles.map((bundle, index) => {
    const validator = evidence.agent_cu.live_validator_reports[index];
    const pair = semanticValidatorPair(
      bundle.path,
      validator.path,
      `verified Agent bundle ${index}`,
      { authentication },
    );
    verifiedBundlePairs.push(pair);
    return {
      bundle_path: pair.bundle.path,
      bundle_sha256: pair.bundle.sha256,
      validator_report_path: pair.validator.path,
      validator_report_sha256: pair.validator.sha256,
      operation: pair.payload.operation,
    };
  });
  requireUniqueAuthenticatedBridgeReceipts(
    verifiedBundlePairs,
    'verified Agent bundle corpus',
  );
  requireCondition(sameJSON(
    bundleProjection.sort((left, right) => left.bundle_path.localeCompare(right.bundle_path)),
    [...concurrent.value.agent.signed_bundles]
      .sort((left, right) => left.bundle_path.localeCompare(right.bundle_path)),
  ), 'verified Agent corpus differs from concurrent validation');
  requireCondition(sameJSON(
    evidence.agent_cu.controlled_fixture_targets,
    adjunctBinding.controlledFixtureTargets,
  ), 'verified Agent controlled fixture targets differ from the live-v4 plan');
  validateConcurrentInterleavingBinding(
    concurrentValue,
    evidence.agent_cu.agent_readbacks.path,
    verifiedBundlePairs,
    evidence.agent_cu.perform_readback.path,
    adjunctBinding.controlledFixtureTargets,
    'verified Agent manifest',
  );
  const semanticReadbacks = evidence.agent_cu.semantic_readbacks.map((receipt, index) => (
    semanticAgentReadback(receipt.path, `verified Agent semantic readback ${index}`)
  ));
  requireCondition(sameJSON(
    semanticReadbacks.map((entry) => ({
      path: entry.receipt.path,
      sha256: entry.receipt.sha256,
      observed_at_milliseconds: entry.observed_at_milliseconds,
      value_sha256: entry.value_sha256,
    }))
      .sort((left, right) => left.path.localeCompare(right.path)),
    concurrent.value.agent.semantic_readbacks.map((entry) => ({
      path: entry.path,
      sha256: entry.sha256,
      observed_at_milliseconds: entry.observed_at_milliseconds,
      value_sha256: entry.value_sha256,
    })).sort((left, right) => left.path.localeCompare(right.path)),
  ), 'verified Agent semantic readbacks differ from concurrent validation');
  const adjunctPaths = (value, pointer) => ({
    raw_bundles: value.raw_bundles.map((entry) => entry.path),
    live_validator_reports: value.live_validator_reports.map((entry) => entry.path),
    readbacks: value.readbacks.map((entry) => entry.path),
    restorations: value.restorations.map((entry) => entry.path),
    ...(pointer ? {
      controller_results: value.controller_results.map((entry) => entry.path),
      target_process_receipts: value.target_process_receipts.map((entry) => entry.path),
      crash_inventories: value.crash_inventories.map((entry) => entry.path),
    } : {}),
  });
  adjunct(
    adjunctPaths(evidence.adjuncts.middle_click, false),
    'verified adjuncts.middle_click',
    { kind: 'middle_click', binding: adjunctBinding },
  );
  adjunct(
    adjunctPaths(evidence.adjuncts.held_key, false),
    'verified adjuncts.held_key',
    { kind: 'held_key', binding: adjunctBinding },
  );
  adjunct(
    adjunctPaths(evidence.adjuncts.held_pointer, true),
    'verified adjuncts.held_pointer',
    { kind: 'held_pointer', binding: adjunctBinding },
  );
}

export function generateManifest(inputPath, outputPath, {
  authenticateBundle = authenticateLiveBridgeBundle,
} = {}) {
  const input = readStableJSON(inputPath, 'qualification manifest input').value;
  const evidence = projectInput(input, authenticateBundle);
  const generatedPaths = new Set();
  validateEvidenceShape(evidence, (receipt, label) => {
    exactKeys(receipt, ['path', 'size', 'sha256'], label);
    requireCondition(!generatedPaths.has(receipt.path), `${label} reuses an evidence path`);
    generatedPaths.add(receipt.path);
  });
  const manifest = {
    version: 2,
    qualification_claim: 'release-qualification',
    adjuncts_are_live_v4_slots: false,
    evidence,
    evidence_aggregate_sha256: aggregateSHA256('evidence-manifest', evidence),
  };
  const written = writePrivateExclusive(outputPath, manifest);
  return { manifest, manifest_sha256: written.sha256 };
}

export function verifyManifest(manifestPath, {
  authenticateBundle = authenticateLiveBridgeBundle,
} = {}) {
  const retained = readStableJSON(manifestPath, 'qualification manifest');
  const manifest = retained.value;
  exactKeys(manifest, [
    'version', 'qualification_claim', 'adjuncts_are_live_v4_slots', 'evidence',
    'evidence_aggregate_sha256',
  ], 'qualification manifest');
  requireCondition(manifest.version === 2
    && manifest.qualification_claim === 'release-qualification'
    && manifest.adjuncts_are_live_v4_slots === false,
  'qualification manifest claim metadata is invalid');
  const checkedPaths = new Set();
  const checkReceipt = (receipt, label) => {
    exactKeys(receipt, ['path', 'size', 'sha256'], label);
    requireCondition(!checkedPaths.has(receipt.path), `${label} reuses an evidence path`);
    checkedPaths.add(receipt.path);
    const current = label.startsWith('evidence.artifact_manifest.')
      ? immutableReceipt(receipt.path, label)
      : ['evidence.deployment.process_tree_collector', 'evidence.deployment.executable_policy_scanner']
          .includes(label)
        ? stableSourceReceipt(receipt.path, label)
        : label === 'evidence.deployment.process_tree_monitor'
          ? (() => {
              const executable = requireStableExecutable(receipt.path, label, { allowRootOwner: true });
              return { path: executable.path, size: executable.bytes.length, sha256: executable.sha256 };
            })()
        : fileReceipt(receipt.path, label);
    requireCondition(sameJSON(current, receipt), `${label} changed after manifest generation`);
  };
  validateEvidenceShape(manifest.evidence, checkReceipt);
  validateSemanticEvidence(manifest.evidence, authenticateBundle);
  requireCondition(
    aggregateSHA256('evidence-manifest', manifest.evidence) === manifest.evidence_aggregate_sha256,
    'qualification evidence aggregate is invalid',
  );
  return {
    version: 2,
    valid: true,
    manifest_sha256: retained.sha256,
    evidence_aggregate_sha256: manifest.evidence_aggregate_sha256,
    adjuncts_are_live_v4_slots: false,
  };
}

function invokedAsScript() {
  return process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
}

if (invokedAsScript()) {
  try {
    const [action, ...argv] = process.argv.slice(2);
    if (action === 'generate') {
      const options = parseOptions(argv, ['input', 'output']);
      const result = generateManifest(options.input, options.output);
      process.stdout.write(`${JSON.stringify({ output: options.output, sha256: result.manifest_sha256 })}\n`);
    } else if (action === 'verify') {
      const options = parseOptions(argv, ['manifest']);
      process.stdout.write(`${JSON.stringify(verifyManifest(options.manifest))}\n`);
    } else if (action === 'tooling') {
      if (argv.length !== 6) {
        throw new Error('tooling requires --directory DIR --source-commit SHA --output OUTPUT');
      }
      const value = (name) => {
        const index = argv.indexOf(name);
        if (index < 0 || index + 1 >= argv.length) throw new Error(`missing ${name}`);
        return argv[index + 1];
      };
      const directory = path.resolve(value('--directory'));
      const output = path.resolve(value('--output'));
      const result = generateSourceManifest(
        directory,
        QUALIFICATION_TOOL_FILES,
        output,
        value('--source-commit'),
      );
      process.stdout.write(`${JSON.stringify({ output, sha256: result.sha256 })}\n`);
    } else if (action === 'source') {
      if (argv.length !== 8) {
        throw new Error(
          'source requires --directory DIR --files COMMA_LIST --source-commit SHA --output OUTPUT',
        );
      }
      const value = (name) => {
        const index = argv.indexOf(name);
        if (index < 0 || index + 1 >= argv.length) throw new Error(`missing ${name}`);
        return argv[index + 1];
      };
      const directory = path.resolve(value('--directory'));
      const output = path.resolve(value('--output'));
      const files = value('--files').split(',');
      const result = generateSourceManifest(directory, files, output, value('--source-commit'));
      process.stdout.write(`${JSON.stringify({ output, sha256: result.sha256 })}\n`);
    } else {
      throw new Error('usage: qualification-manifest generate|verify|tooling|source ...');
    }
  } catch (error) {
    process.stderr.write(`qualification-manifest: ${error.message}\n`);
    process.exitCode = 1;
  }
}
