#!/usr/bin/env node

import {
  createHash,
  createPublicKey,
  randomBytes,
  verify as verifySignature,
} from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const HEX40 = /^[0-9a-f]{40}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const DECIMAL = /^(0|[1-9][0-9]*)$/;
const POSITIVE_DECIMAL = /^[1-9][0-9]*$/;
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const UUID_V8 = /^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const UINT64_MAX = 0xffff_ffff_ffff_ffffn;
const REQUEST_ID_DOMAIN = Buffer.from('peekaboo.bridge.operation-request.v1\0', 'utf8');
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const BUILTIN_CATALOG_SHA256 = '5fc91ee5006e58003aeffd9a3e4991d7c2d405e83f828aebd7c4a09fc0512a8d';
const BUILTIN_DIGEST_SPEC_SHA256 = '6d80d6264a4d3b80c69cee0c68ce3b5c2fd801e8483bb4bbddd4402d87066a33';
const CLI_VERSION = '2';
const LIVE_CERTIFICATION_AUTHORITY = Symbol('peekaboo-live-certification-authority');
const LIVE_CERTIFICATION_RESULT = Symbol('peekaboo-live-certification-result');
const FINALIZER_CATALOG_DIGEST_PROJECTION = 'normalize-builtin-catalog-sha256-to-zero-v1';

class LosslessJSONInteger {
  constructor(source) {
    this.source = source;
    Object.freeze(this);
  }
}
const CONTROLLER_SOURCE_DIRECTORY = 'Apps/CLI/Sources/PeekabooCertificationController/';
const CONTROLLER_SOURCE_PATHS = [
  'Apps/CLI/Sources/PeekabooCertificationController/CodeIdentityRunner.swift',
  'Apps/CLI/Sources/PeekabooCertificationController/ControllerBuildIdentity.swift',
  'Apps/CLI/Sources/PeekabooCertificationController/ControllerEvidence.swift',
  'Apps/CLI/Sources/PeekabooCertificationController/ControllerMain.swift',
  'Apps/CLI/Sources/PeekabooCertificationController/ControllerPlan.swift',
  'Apps/CLI/Sources/PeekabooCertificationController/ControllerRunner.swift',
  'Apps/CLI/Sources/PeekabooCertificationController/ForegroundSemanticObserver.swift',
  'Apps/CLI/Sources/PeekabooCertificationController/HeldPointerPlan.swift',
  'Apps/CLI/Sources/PeekabooCertificationController/HeldPointerRunner.swift',
  'Apps/CLI/Sources/PeekabooCertificationController/LiveCertificationBridge.swift',
  'Apps/CLI/Sources/PeekabooCertificationController/LocalPIDAttestation.swift',
  'Apps/CLI/Sources/PeekabooCertificationController/MonitorAttestationRunner.swift',
  'Apps/CLI/Sources/PeekabooCertificationController/ObserveOnlyRunner.swift',
  'Apps/CLI/Sources/PeekabooCertificationController/ObserverPlan.swift',
  'Apps/CLI/Sources/PeekabooCertificationController/PrivateArtifacts.swift',
];
const CLI_HELP = `\
Finalize one authenticated live-physical multi-target Peekaboo certification run.

Usage:
  peekaboo-certify finalize --artifacts DIR --peekaboo PATH [--output FILE]
  peekaboo-certify prepare --controller-receipts DIR --bundles DIR --artifacts DIR
                    --monitor-evidence FILE --foreground-postcondition FILE
                    --peekaboo PATH [--output FILE]
  peekaboo-certify digest --kind KIND --input FILE [--projection NAME]
  peekaboo-certify digest --spec
  peekaboo-certify verify-digests --artifacts DIR --summary FILE

Required:
  --artifacts DIR   Owner-private directory containing contract.json,
                    operation-manifest.json, raw-evidence.json, and bundles/
  --peekaboo PATH   Exact signed Peekaboo executable used for live receipt validation

Prepare input:
  --controller-receipts DIR
                    Two owner-private receipts from long-lived certification controllers
  --bundles DIR     Owner-private raw protocol-1.29 export directory
  --monitor-evidence FILE
                    Owner-private monitor corpus emitted by the source-owned coordinator
  --foreground-postcondition FILE
                    Independent fresh readback and restoration witness for the foreground task

Options:
  -o, --output FILE Write the owner-private JSON summary to a new file
  -h, --help        Show this help
  --version         Print the certification schema version

Digest commands:
  digest            Recompute one documented digest projection
  verify-digests    Recompute and verify every digest claimed by a summary
  --spec             Print the closed version-2 digest specification

The command revalidates every bundle against the contracted live Bridge listener,
reruns offline receipt validation from raw bytes, validates the source-bound monitor
grant/activity/revoke corpus, and emits JSON. Exit status is
0 for a valid certificate, 1 for rejected evidence, and 2 for usage/runtime errors.
`;

function failure(rule, message, slotID = null) {
  return { rule, message, slot_id: slotID };
}

function isPlainObject(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function exactKeys(value, expected) {
  if (!isPlainObject(value)) return false;
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  return actual.length === wanted.length
    && actual.every((key, index) => key === wanted[index]);
}

function onlyKeys(value, allowed) {
  return isPlainObject(value) && Object.keys(value).every((key) => allowed.includes(key));
}

function canonicalValue(value) {
  if (value === null || typeof value === 'boolean' || typeof value === 'string') return value;
  if (typeof value === 'number') {
    if (!Number.isFinite(value) || Object.is(value, -0)
        || (Number.isInteger(value) && !Number.isSafeInteger(value))) {
      throw new TypeError('canonical JSON only accepts finite lossless numbers and excludes negative zero');
    }
    return value;
  }
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (!isPlainObject(value)) throw new TypeError('canonical JSON only accepts plain JSON values');
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalValue(value[key])]));
}

export function canonicalBytes(value) {
  return Buffer.from(JSON.stringify(canonicalValue(value)), 'utf8');
}

export function canonicalSHA256(value) {
  return sha256(canonicalBytes(value));
}

export function aggregateSHA256(name, value) {
  return sha256(Buffer.concat([
    Buffer.from(`peekaboo.multi-target-certification.${name}.v2\0`, 'utf8'),
    canonicalBytes(value),
  ]));
}

function digestSpecPath() {
  return path.join(path.dirname(fileURLToPath(import.meta.url)), 'multi-target-digest-spec.json');
}

function loadDigestSpec() {
  const specPath = digestSpecPath();
  const bytes = fs.readFileSync(specPath);
  if (sha256(bytes) !== BUILTIN_DIGEST_SPEC_SHA256) {
    throw new TypeError('built-in multi-target digest specification digest is invalid');
  }
  const spec = parseJSON(bytes, 'digest specification');
  if (!exactKeys(spec, [
    'version', 'algorithm', 'text_encoding', 'canonical_json', 'domain_separation',
    'run_binding_projection', 'kinds',
  ]) || spec.version !== 2 || spec.algorithm !== 'sha256' || spec.text_encoding !== 'utf-8'
      || !Array.isArray(spec.kinds) || spec.kinds.length === 0
      || spec.kinds.some((entry) => !exactKeys(entry, [
        'id', 'input', 'projection', 'domain',
      ]) || typeof entry.id !== 'string' || entry.id.length === 0
        || !['raw-bytes', 'json'].includes(entry.input)
        || typeof entry.projection !== 'string' || entry.projection.length === 0
        || !(entry.domain === null || (typeof entry.domain === 'string' && entry.domain.length > 0)))
      || new Set(spec.kinds.map((entry) => entry.id)).size !== spec.kinds.length) {
    throw new TypeError('built-in multi-target digest specification is malformed');
  }
  return { path: specPath, bytes, spec };
}

function projectDigestJSON(kind, value) {
  if (kind.projection === 'omit-offline_protocol_validation') {
    if (!isPlainObject(value)) throw new TypeError('raw-evidence digest input must be one JSON object');
    const projected = structuredClone(value);
    delete projected.offline_protocol_validation;
    return projected;
  }
  if (kind.projection === 'omit-summary_core_sha256') {
    if (!isPlainObject(value) || !('summary_core_sha256' in value)) {
      throw new TypeError('summary-core digest input must contain summary_core_sha256');
    }
    const projected = structuredClone(value);
    delete projected.summary_core_sha256;
    return projected;
  }
  if (kind.projection === 'contract-run-binding') {
    if (!isPlainObject(value) || value.version !== 4
        || typeof value.catalog_sha256 !== 'string'
        || !isPlainObject(value.listener)
        || !HEX64.test(value.execution_nonce ?? '')
        || !isPlainObject(value.monitor_binding)
        || !Array.isArray(value.operation_slots)) {
      throw new TypeError('run-binding digest input must be one version-4 live contract object');
    }
    return certificationRunBinding({
      catalogSHA256: value.catalog_sha256,
      listenerInstanceID: value.listener.instance_id,
      executionNonce: value.execution_nonce,
      currentBuildSource: value.current_build_source,
      monitorBinding: value.monitor_binding,
      controllerBuild: value.controller_build,
      operationSlots: value.operation_slots,
    });
  }
  if (kind.projection === 'monitor-history') {
    return monitorHistoryProjection(value);
  }
  if (kind.projection === 'monitor-baseline') {
    return monitorBaselineProjection(value);
  }
  if (['whole-document', 'preprojected-array-sorted-by-file']
    .includes(kind.projection)) {
    return value;
  }
  throw new TypeError(`Unsupported digest projection in built-in specification: ${kind.projection}`);
}

export function computeDigestClaim({ kindID, inputBytes, projection = null }) {
  const { spec } = loadDigestSpec();
  const kind = spec.kinds.find((entry) => entry.id === kindID);
  if (!kind) throw new TypeError(`Unknown digest kind: ${kindID}`);
  if (projection !== null && projection !== kind.projection) {
    throw new TypeError(`Digest kind ${kindID} requires projection ${kind.projection}`);
  }
  if (kind.input === 'raw-bytes') {
    if (kind.projection !== 'identity' || kind.domain !== null) {
      throw new TypeError(`Raw digest kind ${kindID} has an invalid built-in contract`);
    }
    return { kind, digest: sha256(inputBytes) };
  }
  const value = parseJSON(inputBytes, `${kindID} digest input`);
  const projected = projectDigestJSON(kind, value);
  const digest = kind.domain === null
    ? canonicalSHA256(projected)
    : aggregateSHA256(kind.domain, projected);
  return { kind, digest };
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

export function projectFinalizerSourceBytes(bytes) {
  const source = Buffer.from(bytes).toString('utf8');
  const expression = /^const BUILTIN_CATALOG_SHA256 = '[0-9a-f]{64}';$/gm;
  const matches = source.match(expression) ?? [];
  if (matches.length !== 1) {
    throw new TypeError('finalizer source must contain exactly one built-in catalog digest declaration');
  }
  return Buffer.from(source.replace(
    expression,
    `const BUILTIN_CATALOG_SHA256 = '${'0'.repeat(64)}';`,
  ), 'utf8');
}

function gitOutput(repositoryRoot, args, label) {
  const run = spawnSync('/usr/bin/git', ['-C', repositoryRoot, ...args], {
    encoding: 'utf8',
    timeout: 10_000,
    maxBuffer: 4 * 1024 * 1024,
  });
  if (run.status !== 0) throw new TypeError(`${label} is unavailable`);
  return run.stdout.trim();
}

function sourceFileBytes(repositoryRoot, binding, label) {
  const filePath = path.join(repositoryRoot, binding.path);
  const relative = path.relative(repositoryRoot, filePath);
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new TypeError(`${label} escapes the repository`);
  }
  const file = readStableRegularFile(filePath, label);
  if (file.info.nlink !== 1) {
    throw new TypeError(`${label} is not one regular source file`);
  }
  gitOutput(repositoryRoot, ['ls-files', '--error-unmatch', '--', binding.path], label);
  return file.bytes;
}

export function verifyCurrentBuildSourceBinding(catalog, repositoryRoot, { requireClean = true } = {}) {
  const failures = validateCatalog(catalog);
  if (failures.length > 0) {
    throw new TypeError(`catalog is invalid: ${failures.map((entry) => entry.rule).join(', ')}`);
  }
  const root = fs.realpathSync(repositoryRoot);
  const commit = gitOutput(root, ['rev-parse', '--verify', 'HEAD'], 'current Git HEAD');
  if (!HEX40.test(commit)) throw new TypeError('current Git HEAD is not one exact commit');
  const statusArguments = ['status', '--porcelain=v1', '--untracked-files=all', '--ignore-submodules=none'];
  const initialStatus = gitOutput(root, statusArguments, 'Git worktree state');
  if (requireClean && initialStatus !== '') {
    throw new TypeError('current-build certification requires a clean Git worktree');
  }
  const binding = catalog.current_build_source;
  const controllerEntries = fs.readdirSync(path.join(root, CONTROLLER_SOURCE_DIRECTORY), {
    withFileTypes: true,
  }).filter((entry) => entry.name.endsWith('.swift'));
  if (controllerEntries.some((entry) => !entry.isFile() || entry.isSymbolicLink())) {
    throw new TypeError('controller source directory contains a non-regular Swift source');
  }
  const actualControllerPaths = controllerEntries
    .map((entry) => `${CONTROLLER_SOURCE_DIRECTORY}${entry.name}`).sort();
  const boundControllerPaths = binding.controller_source_manifest.map((entry) => entry.path);
  if (!sameJSON(actualControllerPaths, boundControllerPaths)) {
    throw new TypeError('controller source manifest differs from the exact source directory');
  }
  for (const entry of binding.controller_source_manifest) {
    if (sha256(sourceFileBytes(root, entry, `controller source ${entry.path}`)) !== entry.sha256) {
      throw new TypeError(`controller source ${entry.path} differs from the catalog binding`);
    }
  }
  for (const [label, entry] of [
    ['coordinator source', binding.coordinator],
    ['receipt validator source', binding.receipt_validator],
  ]) {
    if (sha256(sourceFileBytes(root, entry, label)) !== entry.sha256) {
      throw new TypeError(`${label} differs from the catalog binding`);
    }
  }
  const finalizerBytes = sourceFileBytes(root, binding.finalizer, 'certification finalizer source');
  if (sha256(projectFinalizerSourceBytes(finalizerBytes)) !== binding.finalizer.projected_sha256) {
    throw new TypeError('certification finalizer projected bytes differ from the catalog binding');
  }
  const finalCommit = gitOutput(root, ['rev-parse', '--verify', 'HEAD'], 'final Git HEAD');
  const finalStatus = gitOutput(root, statusArguments, 'final Git worktree state');
  if (finalCommit !== commit || finalStatus !== initialStatus) {
    throw new TypeError('Git HEAD or worktree state changed while current-build sources were verified');
  }
  return { commit, repository_root: root };
}

function positiveInteger(value) {
  return Number.isSafeInteger(value) && value > 0;
}

function finiteLosslessNumber(value) {
  return typeof value === 'number'
    && Number.isFinite(value)
    && !Object.is(value, -0)
    && (!Number.isInteger(value) || Number.isSafeInteger(value));
}

function milliseconds(value) {
  return Number.isSafeInteger(value) && value > 0;
}

function normalizedUUID(value, pattern) {
  if (typeof value !== 'string') return null;
  const normalized = value.toLowerCase();
  return pattern.test(normalized) ? normalized : null;
}

function normalizedDecimal(value, positive = false) {
  if (typeof value !== 'string' || !(positive ? POSITIVE_DECIMAL : DECIMAL).test(value)) return null;
  return BigInt(value) <= UINT64_MAX ? value : null;
}

function uuidBytes(value) {
  return Buffer.from(value.replaceAll('-', ''), 'hex');
}

export function deterministicRequestID(sessionID, sequence) {
  const normalizedSessionID = normalizedUUID(sessionID, UUID_V4);
  const normalizedSequence = normalizedDecimal(sequence);
  if (!normalizedSessionID || normalizedSequence === null) return null;
  const sequenceBytes = Buffer.alloc(8);
  sequenceBytes.writeBigUInt64BE(BigInt(normalizedSequence));
  const bytes = Buffer.from(createHash('sha256')
    .update(REQUEST_ID_DOMAIN)
    .update(uuidBytes(normalizedSessionID))
    .update(sequenceBytes)
    .digest()
    .subarray(0, 16));
  bytes[6] = (bytes[6] & 0x0f) | 0x80;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function uuidV8FromDigest(digest) {
  const bytes = Buffer.from(digest.slice(0, 32), 'hex');
  bytes[6] = (bytes[6] & 0x0f) | 0x80;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function certificationRunBinding({
  catalogSHA256,
  listenerInstanceID,
  executionNonce,
  currentBuildSource,
  monitorBinding,
  controllerBuild,
  operationSlots,
}) {
  const signedBindings = operationSlots.map((slot) => ({
    slot_id: slot.slot_id,
    controller_id: slot.controller_id,
    target_id: slot.target_id,
    client: slot.client,
    request_id: slot.request_id,
    session: slot.session,
    operation: slot.operation,
    request_binding: slot.request_binding,
    request_sha256: slot.request_sha256,
    response_sha256: slot.response_sha256,
    target: slot.target,
    interval: slot.interval,
    expected_outcome: slot.expected_outcome,
  }));
  return {
    catalog_sha256: catalogSHA256,
    listener_instance_id: listenerInstanceID,
    execution_nonce: executionNonce,
    current_build_source: currentBuildSource,
    monitor_binding: monitorBinding,
    controller_build: controllerBuild,
    slots: signedBindings,
  };
}

export function certificationRunBindingSHA256(input) {
  return aggregateSHA256('run-binding', certificationRunBinding(input));
}

export function deriveCertificationRunID(input) {
  const digest = certificationRunBindingSHA256(input);
  return `multi-target-${uuidV8FromDigest(digest)}`;
}

function sameJSON(left, right) {
  try {
    return canonicalBytes(left).equals(canonicalBytes(right));
  } catch {
    return false;
  }
}

function validProcess(value) {
  return exactKeys(value, ['pid', 'start_identity', 'code_signature_hash'])
    && positiveInteger(value.pid)
    && normalizedDecimal(value.start_identity, true) !== null
    && HEX40.test(value.code_signature_hash ?? '');
}

function validBounds(value) {
  return exactKeys(value, ['x', 'y', 'width', 'height'])
    && [value.x, value.y, value.width, value.height].every(finiteLosslessNumber)
    && value.width > 0 && value.height > 0;
}

function validTarget(value) {
  return exactKeys(value, ['scope', 'pid', 'start_identity', 'window_id', 'bounds', 'is_minimized'])
    && value.scope === 'window'
    && positiveInteger(value.pid)
    && normalizedDecimal(value.start_identity, true) !== null
    && positiveInteger(value.window_id)
    && value.window_id <= 0xffff_ffff
    && validBounds(value.bounds)
    && (value.is_minimized === null || typeof value.is_minimized === 'boolean');
}

function validSemanticElement(value) {
  return exactKeys(value, ['role', 'identifier', 'title'])
    && typeof value.role === 'string' && value.role.length > 0
    && Buffer.byteLength(value.role, 'utf8') <= 256 && !value.role.includes('\0')
    && (value.identifier === null || (typeof value.identifier === 'string' && value.identifier.length > 0))
    && (value.title === null || (typeof value.title === 'string' && value.title.length > 0))
    && (value.identifier !== null || value.title !== null)
    && Buffer.byteLength(value.identifier ?? '', 'utf8') <= 1024
    && Buffer.byteLength(value.title ?? '', 'utf8') <= 1024
    && !(value.identifier ?? '').includes('\0')
    && !(value.title ?? '').includes('\0');
}

function boundsContain(outer, inner) {
  return inner.x >= outer.x && inner.y >= outer.y
    && inner.x + inner.width <= outer.x + outer.width
    && inner.y + inner.height <= outer.y + outer.height;
}

function sameProcessGeneration(left, right) {
  return left?.pid === right?.pid && left?.start_identity === right?.start_identity;
}

function sameWindowGeneration(left, right) {
  return sameProcessGeneration(left, right) && left?.window_id === right?.window_id;
}

function validMonitorProcess(value) {
  return exactKeys(value, [
    'pid', 'start_identity', 'executable_path', 'executable_sha256',
    'code_signature_hash', 'team_id', 'source_commit', 'heartbeat_path',
  ])
    && positiveInteger(value.pid)
    && normalizedDecimal(value.start_identity, true) !== null
    && typeof value.executable_path === 'string' && path.isAbsolute(value.executable_path)
    && typeof value.heartbeat_path === 'string' && path.isAbsolute(value.heartbeat_path)
    && HEX64.test(value.executable_sha256 ?? '')
    && HEX40.test(value.code_signature_hash ?? '')
    && typeof value.team_id === 'string' && /^[A-Z0-9]{5,20}$/.test(value.team_id)
    && HEX40.test(value.source_commit ?? '');
}

function validUnixSocketPath(value) {
  return typeof value === 'string'
    && path.isAbsolute(value)
    && Buffer.byteLength(value, 'utf8') < 104
    && !value.includes('\0')
    && !value.split('/').includes('..');
}

function validMonitorBinding(value, catalog, executionNonce, currentBuildCommit) {
  if (!exactKeys(value, [
    'version', 'monitor_instance_id', 'execution_nonce',
    'monitor_source_commit', 'monitor_source_sha256',
    'coordinator_runtime_commit', 'coordinator_source_sha256',
    'monitor_process', 'monitor_attestation_socket_path',
    'sentinel', 'foreground_controller', 'foreground_target', 'revisions',
  ]) || value.version !== 1
      || normalizedUUID(value.monitor_instance_id, UUID_V4) === null
      || value.execution_nonce !== executionNonce
      || value.monitor_source_commit !== catalog.monitor_source.commit
      || value.monitor_source_sha256 !== catalog.monitor_source.probe_sha256
      || value.coordinator_runtime_commit !== currentBuildCommit
      || value.coordinator_source_sha256 !== catalog.current_build_source.coordinator.sha256
      || !validMonitorProcess(value.monitor_process)
      || !validUnixSocketPath(value.monitor_attestation_socket_path)
      || !catalog.trusted_monitor_team_ids.includes(value.monitor_process.team_id)
      || value.monitor_process.source_commit !== catalog.monitor_source.commit
      || !validTarget(value.sentinel)
      || !validProcess(value.foreground_controller)
      || !validTarget(value.foreground_target)
      || !exactKeys(value.revisions, ['baseline', 'grant', 'revoke'])
      || !positiveInteger(value.revisions.baseline)
      || value.revisions.grant !== value.revisions.baseline + 1
      || value.revisions.revoke !== value.revisions.grant + 1) {
    return false;
  }
  return true;
}

function validControllerBuild(value, catalog, currentBuildCommit) {
  return exactKeys(value, [
    'source_commit', 'executable_path', 'executable_sha256', 'team_id',
  ])
    && HEX40.test(value.source_commit ?? '')
    && (currentBuildCommit === null || value.source_commit === currentBuildCommit)
    && typeof value.executable_path === 'string' && path.isAbsolute(value.executable_path)
    && HEX64.test(value.executable_sha256 ?? '')
    && catalog.trusted_controller_team_ids.includes(value.team_id);
}

const OUTCOME_KEYS = [
  'state', 'route', 'delivery_mechanism', 'delivery_mode', 'effect', 'evidence',
  'dispatch_state', 'dispatched_unit_count', 'retry_safety', 'escalation', 'refusal_reason',
  'mutation_dispatched', 'retry_safe', 'requires_fresh_observation',
];

// The Swift verifier owns OperationSemanticPlan. This layer only freezes and compares the
// complete projection that verifier attested; it deliberately does not reimplement the plan.
function validExpectedOutcome(value) {
  return exactKeys(value, OUTCOME_KEYS)
    && typeof value.state === 'string' && value.state.length > 0
    && value.route === 'bridge'
    && typeof value.delivery_mechanism === 'string' && value.delivery_mechanism.length > 0
    && value.delivery_mode === 'background'
    && typeof value.effect === 'string' && value.effect.length > 0
    && typeof value.evidence === 'string' && value.evidence.length > 0
    && typeof value.dispatch_state === 'string' && value.dispatch_state.length > 0
    && (value.dispatched_unit_count === null || positiveInteger(value.dispatched_unit_count))
    && typeof value.retry_safety === 'string' && value.retry_safety.length > 0
    && typeof value.escalation === 'string' && value.escalation.length > 0
    && (value.refusal_reason === null || (typeof value.refusal_reason === 'string'
      && value.refusal_reason.length > 0))
    && value.mutation_dispatched === true
    && value.retry_safe === false
    && typeof value.requires_fresh_observation === 'boolean';
}

function validInterval(value, enclosing = null) {
  if (!exactKeys(value, ['started_at_milliseconds', 'completed_at_milliseconds'])
      || !milliseconds(value.started_at_milliseconds)
      || !milliseconds(value.completed_at_milliseconds)
      || value.completed_at_milliseconds < value.started_at_milliseconds) return false;
  return enclosing === null
    || (value.started_at_milliseconds >= enclosing.started_at_milliseconds
      && value.completed_at_milliseconds <= enclosing.completed_at_milliseconds);
}

function validSource(value, contract) {
  return exactKeys(value, [
    'protocol_source_commit', 'host_source_commit', 'listener_instance_id', 'host',
  ])
    && value.protocol_source_commit === contract.source.commit
    && value.host_source_commit === contract.listener.source_commit
    && value.listener_instance_id === contract.listener.instance_id
    && sameJSON(value.host, contract.listener.host);
}

function validProtocolVersion(value, major, minor) {
  return exactKeys(value, ['major', 'minor'])
    && value.major === major && value.minor === minor;
}

const LIVE_CERTIFICATION_KIND = 'live-physical';
const LIVE_CLAIM_SCOPE = 'multi-target-background-with-attributed-foreground-overlap';

function expectedForegroundValueSHA256(executionNonce) {
  return sha256(Buffer.from(`peekaboo-foreground-postcondition:${executionNonce}`, 'utf8'));
}

export function validateCatalog(catalog) {
  const failures = [];
  const sourceKeys = [
    'commit', 'tree', 'peer_binding', 'operation_semantic_plan_sha256',
    'operation_receipts_sha256', 'operation_receipt_models_sha256',
    'operation_receipt_archive_maintenance_sha256', 'socket_io_sha256',
    'host_clients_sha256', 'private_archive_sha256', 'bridge_constants_sha256',
    'bridge_models_sha256', 'server_handshake_sha256', 'operation_session_claim_sha256',
    'server_operation_receipts_sha256', 'request_desktop_mutation_sha256',
    'bridge_server_sha256',
  ];
  if (!exactKeys(catalog, [
    'version', 'certification_kind', 'claim_scope', 'minimum_controlled_targets',
    'protocol', 'protocol_source', 'monitor_source', 'current_build_source',
    'monitor_contract',
    'trusted_first_party_validator_team_ids', 'trusted_bridge_host_team_ids',
    'trusted_monitor_team_ids', 'trusted_controller_team_ids', 'controlled_target_ids', 'slots',
  ]) || catalog.version !== 2 || catalog.certification_kind !== LIVE_CERTIFICATION_KIND
      || catalog.claim_scope !== LIVE_CLAIM_SCOPE
      || !positiveInteger(catalog.minimum_controlled_targets)
      || catalog.minimum_controlled_targets < 2) {
    return [failure('catalog_schema', 'Catalog must be one closed live-physical version-2 contract')];
  }
  if (!exactKeys(catalog.protocol, [
    'host_handshake', 'receipt_protocol_floor', 'required_operation',
  ]) || !validProtocolVersion(catalog.protocol.host_handshake, 1, 30)
      || !validProtocolVersion(catalog.protocol.receipt_protocol_floor, 1, 29)
      || catalog.protocol.required_operation !== 'exactWindowTargetedClick') {
    failures.push(failure(
      'catalog_protocol',
      'Catalog must separate the protocol-1.30 live handshake from the protocol-1.29 receipt floor',
    ));
  }
  if (!exactKeys(catalog.protocol_source, sourceKeys)
      || !HEX40.test(catalog.protocol_source.commit ?? '')
      || !HEX40.test(catalog.protocol_source.tree ?? '')
      || catalog.protocol_source.peer_binding !== 'darwin-audit-token-pidversion-euid-cdhash-v1'
      || sourceKeys.slice(3).some((key) => !HEX64.test(catalog.protocol_source[key] ?? ''))) {
    failures.push(failure('catalog_source', 'Catalog does not pin the exact protocol and semantic-plan owners'));
  }
  if (!exactKeys(catalog.monitor_source, ['commit', 'probe_sha256'])
      || !HEX40.test(catalog.monitor_source.commit ?? '')
      || !HEX64.test(catalog.monitor_source.probe_sha256 ?? '')) {
    failures.push(failure('catalog_live_source', 'Catalog must pin the physical monitor owner'));
  }
  const currentBuild = catalog.current_build_source;
  const controllerManifest = currentBuild?.controller_source_manifest;
  const controllerPaths = Array.isArray(controllerManifest)
    ? controllerManifest.map((entry) => entry?.path) : [];
  if (!exactKeys(currentBuild, [
    'kind', 'version', 'commit_derivation', 'controller_source_manifest',
    'coordinator', 'receipt_validator', 'finalizer',
  ]) || currentBuild.kind !== 'peekaboo-current-build-source'
      || currentBuild.version !== 1 || currentBuild.commit_derivation !== 'clean-git-head'
      || !Array.isArray(controllerManifest) || controllerManifest.length === 0
      || controllerManifest.some((entry) => !exactKeys(entry, ['path', 'sha256'])
        || typeof entry.path !== 'string'
        || !entry.path.startsWith(CONTROLLER_SOURCE_DIRECTORY)
        || !/^Apps\/CLI\/Sources\/PeekabooCertificationController\/[A-Za-z0-9+._-]+\.swift$/.test(entry.path)
        || !HEX64.test(entry.sha256 ?? ''))
      || new Set(controllerPaths).size !== controllerPaths.length
      || !sameJSON(controllerPaths, CONTROLLER_SOURCE_PATHS)
      || !exactKeys(currentBuild.coordinator, ['path', 'sha256'])
      || currentBuild.coordinator.path !== 'scripts/run-live-multi-target-certification.mjs'
      || !HEX64.test(currentBuild.coordinator.sha256 ?? '')
      || !exactKeys(currentBuild.receipt_validator, ['path', 'sha256'])
      || currentBuild.receipt_validator.path
        !== 'Apps/CLI/Sources/PeekabooCLI/Commands/Core/BridgeCommand+Receipt.swift'
      || !HEX64.test(currentBuild.receipt_validator.sha256 ?? '')
      || !exactKeys(currentBuild.finalizer, ['path', 'projection', 'projected_sha256'])
      || currentBuild.finalizer.path !== 'scripts/finalize-multi-target-certification.mjs'
      || currentBuild.finalizer.projection !== FINALIZER_CATALOG_DIGEST_PROJECTION
      || !HEX64.test(currentBuild.finalizer.projected_sha256 ?? '')) {
    failures.push(failure(
      'catalog_current_build_source',
      'Catalog current-build source binding must be exact, sorted, acyclic, and commit-free',
    ));
  }
  const requiredFences = [
    'baseline-stable', 'grant-stable', 'operations-start',
    'operations-complete', 'revoke-stable', 'final-stable',
  ];
  if (!exactKeys(catalog.monitor_contract, [
    'version', 'required_fences', 'overlap_slot_ids', 'crash_report_prefixes',
    'physical_input_policy',
    'require_foreground_activity', 'require_distinct_foreground_target',
  ]) || catalog.monitor_contract.version !== 1
      || !sameJSON(catalog.monitor_contract.required_fences, requiredFences)
      || !Array.isArray(catalog.monitor_contract.overlap_slot_ids)
      || catalog.monitor_contract.overlap_slot_ids.length < 2
      || new Set(catalog.monitor_contract.overlap_slot_ids).size
        !== catalog.monitor_contract.overlap_slot_ids.length
      || !Array.isArray(catalog.monitor_contract.crash_report_prefixes)
      || catalog.monitor_contract.crash_report_prefixes.length === 0
      || catalog.monitor_contract.crash_report_prefixes.some((prefix) => (
        typeof prefix !== 'string' || !/^[A-Za-z0-9._-]+$/.test(prefix)
      ))
      || new Set(catalog.monitor_contract.crash_report_prefixes).size
        !== catalog.monitor_contract.crash_report_prefixes.length
      || catalog.monitor_contract.physical_input_policy !== 'mouse-move-observational'
      || catalog.monitor_contract.require_foreground_activity !== true
      || catalog.monitor_contract.require_distinct_foreground_target !== true) {
    failures.push(failure('catalog_monitor', 'Catalog monitor contract is incomplete or can weaken live attribution'));
  }
  if (!Array.isArray(catalog.trusted_first_party_validator_team_ids)
      || catalog.trusted_first_party_validator_team_ids.length === 0
      || catalog.trusted_first_party_validator_team_ids.some((value) => (
        typeof value !== 'string' || !/^[A-Z0-9]{5,20}$/.test(value)
      ))
      || new Set(catalog.trusted_first_party_validator_team_ids).size
        !== catalog.trusted_first_party_validator_team_ids.length) {
    failures.push(failure('catalog_first_party_validator', 'Catalog must pin trusted validator signing teams'));
  }
  if (!Array.isArray(catalog.trusted_bridge_host_team_ids)
      || catalog.trusted_bridge_host_team_ids.length === 0
      || catalog.trusted_bridge_host_team_ids.some((value) => (
        typeof value !== 'string' || !/^[A-Z0-9]{5,20}$/.test(value)
      ))
      || new Set(catalog.trusted_bridge_host_team_ids).size
        !== catalog.trusted_bridge_host_team_ids.length) {
    failures.push(failure('catalog_bridge_host', 'Catalog must pin trusted Bridge host signing teams'));
  }
  if (!Array.isArray(catalog.trusted_monitor_team_ids)
      || catalog.trusted_monitor_team_ids.length === 0
      || catalog.trusted_monitor_team_ids.some((value) => (
        typeof value !== 'string' || !/^[A-Z0-9]{5,20}$/.test(value)
      ))
      || new Set(catalog.trusted_monitor_team_ids).size
        !== catalog.trusted_monitor_team_ids.length) {
    failures.push(failure('catalog_monitor_team', 'Catalog must pin trusted monitor signing teams'));
  }
  if (!Array.isArray(catalog.trusted_controller_team_ids)
      || catalog.trusted_controller_team_ids.length === 0
      || catalog.trusted_controller_team_ids.some((value) => (
        typeof value !== 'string' || !/^[A-Z0-9]{5,20}$/.test(value)
      ))
      || new Set(catalog.trusted_controller_team_ids).size
        !== catalog.trusted_controller_team_ids.length) {
    failures.push(failure('catalog_controller_team', 'Catalog must pin trusted controller signing teams'));
  }
  const targetIDs = catalog.controlled_target_ids;
  if (!Array.isArray(targetIDs) || targetIDs.length < catalog.minimum_controlled_targets
      || targetIDs.some((value) => typeof value !== 'string' || value.length === 0)
      || new Set(targetIDs).size !== targetIDs.length) {
    failures.push(failure('catalog_targets', 'Catalog controlled target IDs must be closed, unique, and multi-target'));
  }
  const slots = catalog.slots;
  if (!Array.isArray(slots) || slots.length === 0
      || slots.some((slot) => !exactKeys(slot, [
        'slot_id', 'kind', 'controller_id', 'target_id', 'operation',
        'request_binding_path', 'checkpoint',
      ]) || typeof slot.slot_id !== 'string' || slot.slot_id.length === 0
        || !['operation', 'checkpoint'].includes(slot.kind)
        || typeof slot.controller_id !== 'string' || slot.controller_id.length === 0
        || !targetIDs.includes(slot.target_id)
        || typeof slot.operation !== 'string' || slot.operation.length === 0
        || !Array.isArray(slot.request_binding_path) || slot.request_binding_path.length === 0
        || slot.request_binding_path.some((component) => (
          typeof component !== 'string' || !/^[A-Za-z0-9_]+$/.test(component)
        ))
        || (slot.kind === 'operation' ? slot.checkpoint !== null
          : (typeof slot.checkpoint !== 'string' || slot.checkpoint.length === 0)))) {
    failures.push(failure('catalog_slots', 'Catalog slots must be one closed exact operation/checkpoint set'));
  } else {
    if (new Set(slots.map((slot) => slot.slot_id)).size !== slots.length) {
      failures.push(failure('catalog_slots', 'Catalog slot IDs must be unique'));
    }
    for (const targetID of targetIDs) {
      const targetSlots = slots.filter((slot) => slot.target_id === targetID);
      const controllerIDs = new Set(targetSlots.map((slot) => slot.controller_id));
      if (targetSlots.length === 0 || controllerIDs.size !== 1
          || targetSlots.filter((slot) => slot.checkpoint === 'final-bounds').length !== 1) {
        failures.push(failure(
          'catalog_slots',
          `Target ${targetID} needs one controller and exactly one explicit final-bounds slot`,
        ));
      }
    }
    const protocolSlots = slots.filter((slot) => slot.operation === catalog.protocol.required_operation);
    if (protocolSlots.length !== targetIDs.length
        || new Set(protocolSlots.map((slot) => slot.target_id)).size !== targetIDs.length) {
      failures.push(failure(
        'catalog_protocol_slots',
        'Every controlled target needs one protocol-1.30-only operation slot',
      ));
    }
    const slotIDs = new Set(slots.map((slot) => slot.slot_id));
    if (catalog.monitor_contract.overlap_slot_ids.some((slotID) => !slotIDs.has(slotID))) {
      failures.push(failure('catalog_monitor_slots', 'Every live overlap slot must exist in the closed catalog'));
    }
  }
  return failures;
}

function validateContract(catalog, catalogSHA256, contract) {
  const failures = [];
  if (!exactKeys(contract, [
    'version', 'certification_kind', 'claim_scope', 'execution_nonce',
    'catalog_sha256', 'certification_run_id', 'protocol', 'source', 'current_build_source',
    'first_party_validator', 'listener', 'socket_endpoint', 'interval',
    'monitor_binding', 'controller_build', 'controlled_targets', 'operation_slots',
  ]) || contract.version !== 4
      || contract.certification_kind !== LIVE_CERTIFICATION_KIND
      || contract.claim_scope !== LIVE_CLAIM_SCOPE
      || !HEX64.test(contract.execution_nonce ?? '')) {
    return [failure('contract_schema', 'Contract must be one closed version-4 live-physical object')];
  }
  if (contract.catalog_sha256 !== catalogSHA256) {
    failures.push(failure('contract_catalog', 'Contract is not bound to the exact source-controlled catalog'));
  }
  if (typeof contract.certification_run_id !== 'string'
      || !/^multi-target-[0-9a-f-]{36}$/.test(contract.certification_run_id)) {
    failures.push(failure('contract_run', 'Certification run ID must be one canonical multi-target UUID'));
  }
  if (!exactKeys(contract.protocol, ['host_handshake', 'receipt_protocol_floor'])
      || !sameJSON(contract.protocol.host_handshake, catalog.protocol.host_handshake)
      || !sameJSON(contract.protocol.receipt_protocol_floor, catalog.protocol.receipt_protocol_floor)) {
    failures.push(failure(
      'contract_protocol',
      'Contract must bind the protocol-1.30 host handshake and protocol-1.29 receipt floor separately',
    ));
  }
  if (!sameJSON(contract.source, catalog.protocol_source)) {
    failures.push(failure('contract_source', 'Contract source differs from the source-controlled protocol owner'));
  }
  const currentBuildCommit = contract.current_build_source?.commit;
  if (!exactKeys(contract.current_build_source, ['commit']) || !HEX40.test(currentBuildCommit ?? '')) {
    failures.push(failure(
      'contract_current_build_source',
      'Contract must bind the exact clean Git HEAD used for every current-build executable',
    ));
  }
  if (!exactKeys(contract.first_party_validator, [
    'id', 'source_commit', 'executable_sha256', 'code_signature_hash', 'team_id',
    'runtime_libraries', 'trusted_host_team_ids',
  ])
      || contract.first_party_validator.id !== 'peekaboo-bridge-receipt-validate-v1'
      || !HEX40.test(contract.first_party_validator.source_commit ?? '')
      || contract.first_party_validator.source_commit !== currentBuildCommit
      || !HEX64.test(contract.first_party_validator.executable_sha256 ?? '')
      || !HEX40.test(contract.first_party_validator.code_signature_hash ?? '')
      || !catalog.trusted_first_party_validator_team_ids.includes(contract.first_party_validator.team_id)
      || !Array.isArray(contract.first_party_validator.runtime_libraries)
      || contract.first_party_validator.runtime_libraries.some((entry) => !exactKeys(entry, [
        'name', 'sha256', 'code_signature_hash',
      ]) || typeof entry.name !== 'string'
        || !/^libswiftCompatibility[A-Za-z0-9._-]*\.dylib$/.test(entry.name)
        || !HEX64.test(entry.sha256 ?? '')
        || !HEX40.test(entry.code_signature_hash ?? ''))
      || new Set(contract.first_party_validator.runtime_libraries.map((entry) => entry.name)).size
        !== contract.first_party_validator.runtime_libraries.length
      || !sameJSON(
        contract.first_party_validator.runtime_libraries.map((entry) => entry.name),
        contract.first_party_validator.runtime_libraries.map((entry) => entry.name).sort(),
      )
      || !Array.isArray(contract.first_party_validator.trusted_host_team_ids)
      || contract.first_party_validator.trusted_host_team_ids.some((value) => (
        typeof value !== 'string' || !catalog.trusted_bridge_host_team_ids.includes(value)
      ))
      || new Set(contract.first_party_validator.trusted_host_team_ids).size
        !== contract.first_party_validator.trusted_host_team_ids.length) {
    failures.push(failure('contract_first_party_validator', 'Contract must pin the first-party validator executable'));
  }
  if (!exactKeys(contract.listener, [
    'instance_id', 'public_key_base64', 'public_key_sha256', 'host', 'source_commit',
    'created_at_milliseconds', 'receipt_archive_directory',
  ])
      || normalizedUUID(contract.listener.instance_id, UUID_V4) === null
      || typeof contract.listener.public_key_base64 !== 'string'
      || Buffer.from(contract.listener.public_key_base64, 'base64').length !== 32
      || !HEX64.test(contract.listener.public_key_sha256 ?? '')
      || sha256(Buffer.from(contract.listener.public_key_base64, 'base64'))
        !== contract.listener.public_key_sha256
      || !validProcess(contract.listener.host)
      || !HEX40.test(contract.listener.source_commit ?? '')
      || contract.listener.source_commit !== contract.first_party_validator.source_commit
      || contract.listener.source_commit !== currentBuildCommit
      || !milliseconds(contract.listener.created_at_milliseconds)
      || contract.listener.created_at_milliseconds > contract.interval?.started_at_milliseconds
      || typeof contract.listener.receipt_archive_directory !== 'string'
      || !path.isAbsolute(contract.listener.receipt_archive_directory)) {
    failures.push(failure('contract_listener', 'Contract listener identity or signing key is malformed'));
  }
  if (!exactKeys(contract.socket_endpoint, ['path', 'device', 'inode'])
      || typeof contract.socket_endpoint.path !== 'string'
      || !path.isAbsolute(contract.socket_endpoint.path)
      || normalizedDecimal(contract.socket_endpoint.device, true) === null
      || normalizedDecimal(contract.socket_endpoint.inode, true) === null) {
    failures.push(failure('contract_socket', 'Contract socket endpoint must pin path, device, and inode'));
  }
  if (!validInterval(contract.interval)) {
    failures.push(failure('contract_interval', 'Contract interval is malformed'));
  }
  if (!validMonitorBinding(
    contract.monitor_binding,
    catalog,
    contract.execution_nonce,
    currentBuildCommit,
  )) {
    failures.push(failure('contract_monitor', 'Contract monitor binding is incomplete or not source/run bound'));
  }
  if (!validControllerBuild(contract.controller_build, catalog, currentBuildCommit)) {
    failures.push(failure('contract_controller_build', 'Controller build is not source/team pinned'));
  }

  const controlledTargets = contract.controlled_targets;
  const expectedTargetIDs = catalog.controlled_target_ids;
  if (!Array.isArray(controlledTargets)
      || controlledTargets.length !== expectedTargetIDs.length
      || controlledTargets.map((entry) => entry?.id).join('\0') !== expectedTargetIDs.join('\0')
      || controlledTargets.some((entry) => !exactKeys(entry, [
        'id', 'controller_id', 'controller', 'target',
      ]) || entry.controller_id !== catalog.slots.find((slot) => slot.target_id === entry.id)?.controller_id
        || !validProcess(entry.controller) || !validTarget(entry.target))) {
    failures.push(failure('contract_targets', 'Contract must close every independently controlled exact target'));
  } else {
    const controllerIDs = controlledTargets.map((entry) => entry.controller_id);
    const controllers = controlledTargets.map((entry) => canonicalSHA256(entry.controller));
    const targetProcesses = controlledTargets.map((entry) => `${entry.target.pid}:${entry.target.start_identity}`);
    const targetWindows = controlledTargets.map((entry) => (
      `${entry.target.pid}:${entry.target.start_identity}:${entry.target.window_id}`
    ));
    if (new Set(controllerIDs).size !== controlledTargets.length
        || new Set(controllers).size !== controlledTargets.length
        || new Set(targetProcesses).size !== controlledTargets.length
        || new Set(targetWindows).size !== controlledTargets.length) {
      failures.push(failure('contract_target_isolation', 'Controlled targets and controller generations must be distinct'));
    }
    const foregroundTarget = contract.monitor_binding?.foreground_target;
    const foregroundController = contract.monitor_binding?.foreground_controller;
    if (controlledTargets.some((entry) => (
      sameWindowGeneration(entry.target, foregroundTarget)
        || sameProcessGeneration(entry.controller, foregroundController)
    ))) {
      failures.push(failure(
        'contract_foreground_isolation',
        'Foreground controller and target must be distinct from every background controller and target',
      ));
    }
  }

  const templateSlots = catalog.slots;
  const slots = contract.operation_slots;
  if (!Array.isArray(slots) || slots.length !== templateSlots.length) {
    failures.push(failure('contract_slots', 'Contract must bind every source-controlled slot exactly once'));
    return failures;
  }
  const operationIDs = [];
  const requestIDs = [];
  const sessionClaims = [];
  slots.forEach((slot, index) => {
    const template = templateSlots[index];
    const targetOwner = controlledTargets?.find((entry) => entry?.id === template.target_id);
    const slotKeys = [
      'slot_id', 'operation_id', 'kind', 'checkpoint', 'controller_id', 'target_id',
      'controller', 'client', 'request_id', 'session', 'operation', 'request_envelope_case',
      'request_binding', 'request_case', 'response_envelope_case', 'response_case', 'request_sha256',
      'response_sha256', 'target', 'focused_element', 'selected_leaf_evidence',
      'interval', 'source', 'expected_outcome',
    ];
    const validSession = exactKeys(slot?.session, [
      'id', 'sequence', 'predecessor_id', 'client_instance_id', 'attestation_sha256',
      'listener_instance_id', 'listener_public_key_sha256',
    ]) && normalizedUUID(slot.session.id, UUID_V4) !== null
      && normalizedDecimal(slot.session.sequence) !== null
      && (slot.session.predecessor_id === null
        || normalizedUUID(slot.session.predecessor_id, UUID_V4) !== null)
      && normalizedUUID(slot.session.client_instance_id, UUID_V4) !== null
      && HEX64.test(slot.session.attestation_sha256 ?? '')
      && slot.session.listener_instance_id === contract.listener.instance_id
      && slot.session.listener_public_key_sha256 === contract.listener.public_key_sha256;
    const expectedOutcomeValid = template.kind === 'operation'
      ? validExpectedOutcome(slot?.expected_outcome)
      : slot?.expected_outcome === null;
    if (!exactKeys(slot, slotKeys)
        || slot.slot_id !== template.slot_id
        || slot.operation_id !== `${contract.certification_run_id}:${slot.slot_id}`
        || slot.kind !== template.kind || slot.checkpoint !== template.checkpoint
        || slot.controller_id !== template.controller_id
        || slot.target_id !== template.target_id
        || !sameJSON(slot.controller, targetOwner?.controller)
        || !validProcess(slot.client)
        || !sameJSON(slot.client, targetOwner?.controller)
        || normalizedUUID(slot.request_id, UUID_V8) === null
        || !validSession
        || slot.request_id !== deterministicRequestID(slot.session.id, slot.session.sequence)
        || slot.operation !== template.operation
        || typeof slot.request_envelope_case !== 'string' || slot.request_envelope_case.length === 0
        || !exactKeys(slot.request_binding, ['path', 'value'])
        || !sameJSON(slot.request_binding.path, template.request_binding_path)
        || slot.request_binding.value
          !== `peekaboo-certification-run:${contract.execution_nonce}:slot:${slot.slot_id}`
        || typeof slot.request_case !== 'string' || slot.request_case.length === 0
        || typeof slot.response_envelope_case !== 'string' || slot.response_envelope_case.length === 0
        || typeof slot.response_case !== 'string' || slot.response_case.length === 0
        || !HEX64.test(slot.request_sha256 ?? '') || !HEX64.test(slot.response_sha256 ?? '')
        || !sameJSON(slot.target, targetOwner?.target)
        || !(slot.focused_element === null || isPlainObject(slot.focused_element))
        || !(slot.selected_leaf_evidence === null || Array.isArray(slot.selected_leaf_evidence))
        || !validInterval(slot.interval, contract.interval)
        || !validSource(slot.source, contract)
        || !expectedOutcomeValid) {
      failures.push(failure('contract_slot', `Contract slot ${template.slot_id} is incomplete or contradictory`, template.slot_id));
    }
    operationIDs.push(slot?.operation_id);
    requestIDs.push(slot?.request_id);
    sessionClaims.push(`${slot?.session?.id}:${slot?.session?.sequence}`);
  });
  if (new Set(operationIDs).size !== slots.length
      || new Set(requestIDs).size !== slots.length
      || new Set(sessionClaims).size !== slots.length) {
    failures.push(failure('contract_slot_identity', 'Operation IDs, request IDs, and session claims must be bijective'));
  }
  if (contract.certification_run_id !== deriveCertificationRunID({
    catalogSHA256,
    listenerInstanceID: contract.listener.instance_id,
    executionNonce: contract.execution_nonce,
    currentBuildSource: contract.current_build_source,
    monitorBinding: contract.monitor_binding,
    controllerBuild: contract.controller_build,
    operationSlots: slots,
  })) {
    failures.push(failure('contract_run', 'Certification run ID is not derived from the exact signed corpus'));
  }
  const intervalStart = Math.min(...slots.map((slot) => slot?.interval?.started_at_milliseconds ?? Infinity));
  const intervalEnd = Math.max(...slots.map((slot) => slot?.interval?.completed_at_milliseconds ?? -Infinity));
  if (contract.interval.started_at_milliseconds > intervalStart
      || contract.interval.completed_at_milliseconds < intervalEnd) {
    failures.push(failure('contract_interval', 'Run interval must enclose every signed slot'));
  }
  const operationSlots = slots.filter((slot) => slot?.kind === 'operation');
  for (let leftIndex = 0; leftIndex < expectedTargetIDs.length; leftIndex += 1) {
    for (let rightIndex = leftIndex + 1; rightIndex < expectedTargetIDs.length; rightIndex += 1) {
      const leftID = expectedTargetIDs[leftIndex];
      const rightID = expectedTargetIDs[rightIndex];
      const overlaps = operationSlots.some((left) => left.target_id === leftID
        && operationSlots.some((right) => right.target_id === rightID
          && Math.max(
            left.interval.started_at_milliseconds,
            right.interval.started_at_milliseconds,
          ) < Math.min(
            left.interval.completed_at_milliseconds,
            right.interval.completed_at_milliseconds,
          )));
      if (!overlaps) {
        failures.push(failure(
          'contract_concurrency',
          `Controlled targets ${leftID} and ${rightID} have no signed operation overlap`,
        ));
      }
    }
  }
  const finalBounds = slots.filter((slot) => slot?.checkpoint === 'final-bounds');
  const nonFinalSlots = slots.filter((slot) => slot?.checkpoint !== 'final-bounds');
  const globalNonFinalCompletion = Math.max(...nonFinalSlots.map((slot) => (
    slot.interval.completed_at_milliseconds
  )));
  for (const targetID of expectedTargetIDs) {
    const mutations = slots.filter((slot) => slot.target_id === targetID && slot.kind === 'operation');
    const postMutation = slots.filter((slot) => (
      slot.target_id === targetID && slot.checkpoint === 'post-mutation'
    ));
    const targetFinalBounds = finalBounds.filter((slot) => slot.target_id === targetID);
    const mutationCompletion = Math.max(...mutations.map((slot) => slot.interval.completed_at_milliseconds));
    const postMutationStart = Math.min(...postMutation.map((slot) => slot.interval.started_at_milliseconds));
    const postMutationCompletion = Math.max(...postMutation.map((slot) => slot.interval.completed_at_milliseconds));
    const finalBoundsStart = Math.min(...targetFinalBounds.map((slot) => slot.interval.started_at_milliseconds));
    if (mutations.length === 0 || postMutation.length === 0 || targetFinalBounds.length !== 1
        || mutationCompletion > postMutationStart
        || postMutationCompletion > finalBoundsStart
        || globalNonFinalCompletion > finalBoundsStart) {
      failures.push(failure(
        'contract_checkpoint_order',
        `Target ${targetID} checkpoints do not follow all signed mutations and non-final evidence`,
      ));
    }
  }
  return failures;
}

function validateManifest(catalog, catalogSHA256, contract, contractSHA256, manifest) {
  const failures = [];
  if (!exactKeys(manifest, ['version', 'catalog_sha256', 'contract_sha256', 'slots'])
      || manifest.version !== 1
      || manifest.catalog_sha256 !== catalogSHA256
      || manifest.contract_sha256 !== contractSHA256
      || !Array.isArray(manifest.slots)
      || manifest.slots.length !== catalog.slots.length) {
    return [failure('manifest_schema', 'Operation manifest must be one closed exact version-1 slot set')];
  }
  const files = [];
  const bundleSHA256s = [];
  manifest.slots.forEach((row, index) => {
    const slot = contract.operation_slots?.[index];
    if (!exactKeys(row, [
      'slot_id', 'operation_id', 'bundle_file', 'bundle_sha256', 'controller_id', 'target_id',
      'client', 'request_id', 'session_id', 'session_sequence', 'session_attestation_sha256',
      'predecessor_session_id', 'client_instance_id', 'operation', 'request_binding',
      'request_sha256', 'response_sha256',
    ]) || row.slot_id !== slot?.slot_id || row.operation_id !== slot?.operation_id
        || typeof row.bundle_file !== 'string'
        || !/^[a-z0-9][a-z0-9._-]*\.json$/.test(row.bundle_file)
        || row.bundle_file.includes('..') || !HEX64.test(row.bundle_sha256 ?? '')
        || row.controller_id !== slot?.controller_id || row.target_id !== slot?.target_id
        || !sameJSON(row.client, slot?.client)
        || row.request_id !== slot?.request_id
        || row.session_id !== slot?.session?.id
        || row.session_sequence !== slot?.session?.sequence
        || row.session_attestation_sha256 !== slot?.session?.attestation_sha256
        || row.predecessor_session_id !== slot?.session?.predecessor_id
        || row.client_instance_id !== slot?.session?.client_instance_id
        || row.operation !== slot?.operation
        || !sameJSON(row.request_binding, slot?.request_binding)
        || row.request_sha256 !== slot?.request_sha256
        || row.response_sha256 !== slot?.response_sha256) {
      failures.push(failure('manifest_slot', `Manifest slot ${slot?.slot_id ?? index} does not bind its contract row`, slot?.slot_id));
    }
    files.push(row?.bundle_file);
    bundleSHA256s.push(row?.bundle_sha256);
  });
  if (new Set(files).size !== manifest.slots.length
      || new Set(bundleSHA256s).size !== manifest.slots.length) {
    failures.push(failure('manifest_bijection', 'Manifest bundle files and file digests must be one-to-one'));
  }
  return failures;
}

function decodeBase64(value, context) {
  if (typeof value !== 'string' || value.length === 0 || value.length % 4 !== 0) {
    throw new TypeError(`${context} must be nonempty canonical base64`);
  }
  const bytes = Buffer.from(value, 'base64');
  if (bytes.length === 0 || bytes.toString('base64') !== value) {
    throw new TypeError(`${context} must be nonempty canonical base64`);
  }
  return bytes;
}

function parseCanonicalJSON(bytes, context) {
  let value;
  try {
    value = JSON.parse(bytes.toString('utf8'), (_key, parsed, sourceContext) => {
      if (typeof parsed !== 'number' || !Number.isInteger(parsed) || Number.isSafeInteger(parsed)) {
        return parsed;
      }
      const source = sourceContext?.source;
      if (typeof source !== 'string' || !/^-?(?:0|[1-9][0-9]*)$/.test(source)) {
        throw new TypeError('unsafe numeric literal is not one canonical decimal integer');
      }
      return new LosslessJSONInteger(source);
    });
  } catch (error) {
    throw new TypeError(`${context} is not JSON: ${error.message}`);
  }
  // Canonicality belongs to the fresh Swift verifier. Re-serializing with V8 would reject
  // valid Foundation exponent/decimal spellings even though the signed raw bytes are exact.
  return value;
}

function publicKeyFromRaw(rawKey) {
  if (!Buffer.isBuffer(rawKey) || rawKey.length !== 32) {
    throw new TypeError('listener public key must be exactly 32 bytes');
  }
  return createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, rawKey]),
    format: 'der',
    type: 'spki',
  });
}

function verifyEd25519(bytes, signatureBase64, rawKey, context) {
  const signature = decodeBase64(signatureBase64, `${context} signature`);
  if (signature.length !== 64
      || !verifySignature(null, bytes, publicKeyFromRaw(rawKey), signature)) {
    throw new TypeError(`${context} Ed25519 signature is invalid`);
  }
}

function normalizeWireProcess(value, context) {
  if (!exactKeys(value, ['processIdentifier', 'processStartIdentity', 'codeSignatureHash'])) {
    throw new TypeError(`${context} process identity is not closed`);
  }
  const normalized = {
    pid: value.processIdentifier,
    start_identity: value.processStartIdentity,
    code_signature_hash: value.codeSignatureHash,
  };
  if (!validProcess(normalized)) throw new TypeError(`${context} process identity is malformed`);
  return normalized;
}

function normalizeWireBounds(value, context) {
  if (!Array.isArray(value) || value.length !== 2
      || !Array.isArray(value[0]) || value[0].length !== 2
      || !Array.isArray(value[1]) || value[1].length !== 2) {
    throw new TypeError(`${context} must be one encoded CGRect`);
  }
  const normalized = {
    x: value[0][0],
    y: value[0][1],
    width: value[1][0],
    height: value[1][1],
  };
  if (!validBounds(normalized)) throw new TypeError(`${context} is malformed`);
  return normalized;
}

function normalizeWireTarget(value) {
  const required = [
    'kind', 'processIdentifier', 'processStartIdentity', 'windowID', 'capturedBounds',
  ];
  if (!onlyKeys(value, [...required, 'isMinimized'])
      || required.some((key) => !(key in value)) || value.kind !== 'window') {
    throw new TypeError('operation target must be one exact window-generation receipt');
  }
  const normalized = {
    scope: 'window',
    pid: value.processIdentifier,
    start_identity: value.processStartIdentity,
    window_id: value.windowID,
    bounds: normalizeWireBounds(value.capturedBounds, 'captured bounds'),
    is_minimized: value.isMinimized ?? null,
  };
  if (!validTarget(normalized)) throw new TypeError('operation target is malformed');
  return normalized;
}

function normalizeWireOutcome(value) {
  if (!onlyKeys(value, OUTCOME_KEYS)) throw new TypeError('operation outcome must be one closed object');
  const normalized = {
    state: value.state,
    route: value.route,
    delivery_mechanism: value.delivery_mechanism ?? null,
    delivery_mode: value.delivery_mode ?? null,
    effect: value.effect,
    evidence: value.evidence,
    dispatch_state: value.dispatch_state,
    dispatched_unit_count: value.dispatched_unit_count ?? null,
    retry_safety: value.retry_safety,
    escalation: value.escalation,
    refusal_reason: value.refusal_reason ?? null,
    mutation_dispatched: value.mutation_dispatched,
    retry_safe: value.retry_safe,
    requires_fresh_observation: value.requires_fresh_observation,
  };
  if (!exactKeys(normalized, OUTCOME_KEYS)) throw new TypeError('operation outcome is malformed');
  return normalized;
}

function enumCase(value, context) {
  if (!isPlainObject(value) || Object.keys(value).length !== 1) {
    throw new TypeError(`${context} must contain exactly one enum case`);
  }
  return Object.keys(value)[0];
}

function associatedValue(value, caseName, context) {
  const wrapper = value?.[caseName];
  if (!exactKeys(wrapper, ['_0']) || !isPlainObject(wrapper._0)) {
    throw new TypeError(`${context} associated value is malformed`);
  }
  return wrapper._0;
}

function wireFacts(requestBytes, responseBytes) {
  const request = parseCanonicalJSON(requestBytes, 'canonical request');
  const response = parseCanonicalJSON(responseBytes, 'canonical response');
  const outerRequestCase = enumCase(request, 'canonical request');
  const requestAttestation = outerRequestCase === 'attestedOperation'
    ? associatedValue(request, outerRequestCase, 'canonical request')
    : null;
  if (requestAttestation !== null && !exactKeys(requestAttestation, [
    'requestID', 'sessionID', 'sessionSequence', 'expectedListenerInstanceID',
    'clientInstanceID', 'client', 'request',
  ])) {
    throw new TypeError('attested canonical request carriage is malformed');
  }
  const attestedRequest = requestAttestation?.request ?? request;
  if (!isPlainObject(attestedRequest)) {
    throw new TypeError('attested canonical request is incomplete');
  }
  const requestProjectionCase = enumCase(attestedRequest, 'attested canonical request');
  const projectedRequest = requestProjectionCase === 'projectedAction'
    ? associatedValue(attestedRequest, requestProjectionCase, 'attested canonical request').request
    : attestedRequest;
  const requestCase = enumCase(projectedRequest, 'operation request');
  const responseEnvelopeCase = enumCase(response, 'canonical response');
  let projectedResponse = response;
  let responseOutcome = null;
  if (responseEnvelopeCase === 'projectedAction') {
    const projected = associatedValue(response, responseEnvelopeCase, 'canonical response');
    if (!isPlainObject(projected.response) || !isPlainObject(projected.outcome)) {
      throw new TypeError('projected response is incomplete');
    }
    projectedResponse = projected.response;
    responseOutcome = normalizeWireOutcome(projected.outcome);
  }
  return {
    request_document: attestedRequest,
    request_attestation: requestAttestation,
    request_operation_document: projectedRequest,
    request_envelope_case: outerRequestCase,
    request_projection_case: requestProjectionCase,
    request_case: requestCase,
    response_document: projectedResponse,
    response_envelope_case: responseEnvelopeCase,
    response_case: enumCase(projectedResponse, 'operation response'),
    response_outcome: responseOutcome,
  };
}

function validateAttestedRequestCarriage(facts, payload, contract) {
  const attested = facts.request_attestation;
  if (facts.request_envelope_case !== 'attestedOperation' || !isPlainObject(attested)) {
    throw new TypeError('canonical request lost its attested session carriage');
  }
  const normalized = {
    request_id: normalizedUUID(attested.requestID, UUID_V8),
    session_id: normalizedUUID(attested.sessionID, UUID_V4),
    session_sequence: normalizedDecimal(attested.sessionSequence),
    listener_instance_id: normalizedUUID(attested.expectedListenerInstanceID, UUID_V4),
    client_instance_id: normalizedUUID(attested.clientInstanceID, UUID_V4),
    client: normalizeWireProcess(attested.client, 'attested request client'),
  };
  if (normalized.request_id !== normalizedUUID(payload.requestID, UUID_V8)
      || normalized.session_id !== normalizedUUID(payload.sessionID, UUID_V4)
      || normalized.session_sequence !== normalizedDecimal(payload.sessionSequence)
      || normalized.listener_instance_id !== contract.listener.instance_id
      || normalized.client_instance_id !== normalizedUUID(payload.clientInstanceID, UUID_V4)
      || !sameJSON(normalized.client, normalizeWireProcess(payload.client, 'receipt client'))) {
    throw new TypeError('attested canonical request differs from its signed receipt and listener');
  }
}

function wireBoundsMatchTarget(value, target) {
  return sameJSON(value, [
    [target.bounds.x, target.bounds.y],
    [target.bounds.width, target.bounds.height],
  ]);
}

function wireUInt64MatchesDecimal(value, expected) {
  const normalizedExpected = normalizedDecimal(expected, true);
  if (normalizedExpected === null) return false;
  if (value instanceof LosslessJSONInteger) {
    return normalizedDecimal(value.source, true) === normalizedExpected;
  }
  return Number.isSafeInteger(value) && value > 0
    && BigInt(value) === BigInt(normalizedExpected);
}

function wireWindowIdentityMatchesTarget(value, target) {
  return isPlainObject(value)
    && onlyKeys(value, [
      'windowID', 'ownerProcessIdentifier', 'ownerProcessStartIdentity',
      'capturedBounds', 'isMinimized',
    ])
    && value.windowID === target.window_id
    && value.ownerProcessIdentifier === target.pid
    && wireUInt64MatchesDecimal(value.ownerProcessStartIdentity, target.start_identity)
    && wireBoundsMatchTarget(value.capturedBounds, target)
    && (value.isMinimized ?? null) === target.is_minimized;
}

function textCharacterCount(text) {
  return Array.from(new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(text)).length;
}

function wireEmptyEnumCase(value, caseName) {
  return exactKeys(value, [caseName]) && exactKeys(value[caseName], []);
}

function wireWindowIDCase(value, expectedWindowID) {
  return exactKeys(value, ['windowID'])
    && exactKeys(value.windowID, ['_0'])
    && value.windowID._0 === expectedWindowID;
}

function wireLogical1xSizeMatchesTarget(value, target) {
  return sameJSON(value, [
    Math.max(Math.trunc(target.bounds.width), 1),
    Math.max(Math.trunc(target.bounds.height), 1),
  ]);
}

function validateObservationSemantics(facts, slot, controllerResult) {
  if (facts.request_projection_case !== 'desktopObservation'
      || facts.request_case !== 'desktopObservation'
      || facts.response_envelope_case !== 'desktopObservation'
      || facts.response_case !== 'desktopObservation') {
    throw new TypeError('observation slot does not use desktop-observation carriage');
  }
  const payload = associatedValue(
    facts.request_operation_document,
    'desktopObservation',
    'desktop observation request',
  );
  if (!exactKeys(payload, ['target', 'capture', 'detection', 'output', 'timeout'])
      || !wireWindowIDCase(payload.target, slot.target.window_id)
      || !onlyKeys(payload.capture, [
        'engine', 'scale', 'focus', 'visualizerMode', 'includeMenuBar', 'roi',
      ])
      || payload.capture.engine !== 'auto'
      || !wireEmptyEnumCase(payload.capture.scale, 'logical1x')
      || payload.capture.focus !== 'background'
      || !wireEmptyEnumCase(payload.capture.visualizerMode, 'none')
      || payload.capture.includeMenuBar !== false
      || (payload.capture.roi ?? null) !== null
      || !onlyKeys(payload.detection, [
        'mode', 'allowWebFocusFallback', 'includeMenuBarElements',
        'preferOCR', 'traversalBudget',
      ])
      || !wireEmptyEnumCase(payload.detection.mode, 'none')
      || payload.detection.allowWebFocusFallback !== false
      || payload.detection.includeMenuBarElements !== false
      || payload.detection.preferOCR !== false
      || !exactKeys(payload.output, [
        'path', 'format', 'saveRawScreenshot', 'saveAnnotatedScreenshot',
        'saveSnapshot', 'snapshotID',
      ])
      || typeof payload.output.path !== 'string' || !path.isAbsolute(payload.output.path)
      || path.basename(payload.output.path) !== `${slot.slot_id}.png`
      || payload.output.format !== 'png'
      || payload.output.saveRawScreenshot !== true
      || payload.output.saveAnnotatedScreenshot !== false
      || payload.output.saveSnapshot !== false
      || payload.output.snapshotID !== slot.request_binding.value
      || !exactKeys(payload.timeout, ['overall'])
      || payload.timeout.overall !== 30) {
    throw new TypeError('desktop observation request is not one background raw exact-window capture');
  }

  const result = associatedValue(
    facts.response_document,
    'desktopObservation',
    'desktop observation response',
  );
  const target = result.target;
  const capture = result.capture;
  const metadata = capture?.metadata;
  const windowInfo = metadata?.windowInfo;
  const files = result.files;
  const digest = result.captureContentDigest;
  if (!isPlainObject(result) || !isPlainObject(target)
      || !wireWindowIDCase(target.kind, slot.target.window_id)
      || target.app?.processIdentifier !== slot.target.pid
      || !wireUInt64MatchesDecimal(target.app?.processStartIdentity, slot.target.start_identity)
      || target.window?.windowID !== slot.target.window_id
      || !wireBoundsMatchTarget(target.window?.bounds, slot.target)
      || !wireBoundsMatchTarget(target.bounds, slot.target)
      || !isPlainObject(capture) || !isPlainObject(metadata)
      || metadata.mode !== 'window'
      || !wireLogical1xSizeMatchesTarget(metadata.size, slot.target)
      || windowInfo?.window_id !== slot.target.window_id
      || !wireBoundsMatchTarget(windowInfo?.bounds, slot.target)
      || (windowInfo?.isMinimized ?? null) !== (slot.target.is_minimized ?? false)
      || !wireWindowIdentityMatchesTarget(windowInfo?.mutationIdentity, slot.target)
      || !isPlainObject(files)
      || files.rawScreenshotPath !== payload.output.path
      || (files.annotatedScreenshotPath ?? null) !== null
      || (files.publishedSnapshotID ?? null) !== null
      || !isPlainObject(digest)
      || !onlyKeys(digest, [
        'captureImageSHA256', 'rawScreenshotSHA256', 'annotatedScreenshotSHA256',
      ])
      || !HEX64.test(digest.captureImageSHA256 ?? '')
      || !HEX64.test(digest.rawScreenshotSHA256 ?? '')
      || digest.rawScreenshotSHA256 !== digest.captureImageSHA256
      || (digest.annotatedScreenshotSHA256 ?? null) !== null) {
    throw new TypeError('desktop observation response does not bind its exact target and raw pixels');
  }
  if (controllerResult !== null && (!exactKeys(controllerResult, [
    'status', 'total_characters', 'key_presses', 'observation_file',
    'observation_sha256', 'observed_bounds',
  ])
      || controllerResult.status !== 'passed'
      || controllerResult.total_characters !== null
      || controllerResult.key_presses !== null
      || controllerResult.observation_file !== `observations/${slot.slot_id}.png`
      || !payload.output.path.endsWith(`/${controllerResult.observation_file}`)
      || controllerResult.observation_sha256 !== digest.rawScreenshotSHA256
      || !sameJSON(controllerResult.observed_bounds, slot.target.bounds))) {
    throw new TypeError('controller observation result differs from its signed response');
  }
}

function validateOperationSemantics(facts, slot, controllerResult = null) {
  if (slot.operation === 'exactWindowTargetedTypeActions') {
    if (facts.request_projection_case !== 'projectedAction'
        || facts.request_case !== 'exactWindowTargetedTypeActions'
        || facts.response_envelope_case !== 'projectedAction'
        || facts.response_case !== 'typeResult') {
      throw new TypeError('type slot does not use exact-window action result carriage');
    }
    const payload = associatedValue(
      facts.request_operation_document,
      'exactWindowTargetedTypeActions',
      'exact-window type request',
    );
    const result = associatedValue(
      facts.response_document,
      'typeResult',
      'exact-window type response',
    );
    if (!onlyKeys(payload, [
      'actions', 'cadence', 'snapshotId', 'expectedWindowIdentity',
      'expectedWindowBounds', 'expectedFocusedElement',
    ])
        || !Array.isArray(payload.actions) || payload.actions.length !== 1
        || !exactKeys(payload.actions[0], ['kind', 'text'])
        || payload.actions[0].kind !== 'text'
        || typeof payload.actions[0].text !== 'string'
        || payload.actions[0].text.length === 0
        || payload.snapshotId !== slot.request_binding.value
        || !wireWindowIdentityMatchesTarget(payload.expectedWindowIdentity, slot.target)
        || !wireBoundsMatchTarget(payload.expectedWindowBounds, slot.target)
        || !exactKeys(result, ['totalCharacters', 'keyPresses'])) {
      throw new TypeError('type request or response does not bind its exact target and text');
    }
    const count = textCharacterCount(payload.actions[0].text);
    if (result.totalCharacters !== count || result.keyPresses !== count) {
      throw new TypeError('type response counts differ from the signed request text');
    }
    if (controllerResult !== null && (!exactKeys(controllerResult, [
      'status', 'total_characters', 'key_presses', 'observation_file',
      'observation_sha256', 'observed_bounds',
    ])
        || controllerResult.status !== 'passed'
        || controllerResult.total_characters !== count
        || controllerResult.key_presses !== count
        || controllerResult.observation_file !== null
        || controllerResult.observation_sha256 !== null
        || controllerResult.observed_bounds !== null)) {
      throw new TypeError('controller type result differs from its signed response');
    }
    return;
  }
  if (slot.operation === 'desktopObservation') {
    validateObservationSemantics(facts, slot, controllerResult);
    return;
  }
  validateProtocol130Request(facts, slot);
  if (controllerResult !== null && (!exactKeys(controllerResult, [
    'status', 'total_characters', 'key_presses', 'observation_file',
    'observation_sha256', 'observed_bounds',
  ])
      || controllerResult.status !== 'passed'
      || controllerResult.total_characters !== null
      || controllerResult.key_presses !== null
      || controllerResult.observation_file !== null
      || controllerResult.observation_sha256 !== null
      || controllerResult.observed_bounds !== null)) {
    throw new TypeError('controller click result differs from its signed response');
  }
}

function valueAtPath(value, components) {
  let cursor = value;
  for (const component of components) {
    if (!isPlainObject(cursor) || !(component in cursor)) return undefined;
    cursor = cursor[component];
  }
  return cursor;
}

function validateProtocol130Request(facts, slot) {
  if (slot.operation !== 'exactWindowTargetedClick') return;
  if (facts.request_envelope_case !== 'attestedOperation'
      || facts.request_projection_case !== 'projectedAction'
      || facts.request_case !== 'targetedClick'
      || facts.response_envelope_case !== 'projectedAction'
      || facts.response_case !== 'ok') {
    throw new TypeError('protocol-1.30 slot is not one exact-window targeted click');
  }
  const projected = associatedValue(
    facts.request_document,
    'projectedAction',
    'protocol-1.30 request',
  );
  const payload = associatedValue(
    projected.request,
    'targetedClick',
    'protocol-1.30 targeted click',
  );
  const coordinateWrapper = payload.target?.coordinates;
  const coordinate = exactKeys(coordinateWrapper, ['_0'])
    && Array.isArray(coordinateWrapper._0) && coordinateWrapper._0.length === 1
    && Array.isArray(coordinateWrapper._0[0]) && coordinateWrapper._0[0].length === 2
    ? coordinateWrapper._0[0]
    : null;
  const coordinateInTarget = Array.isArray(coordinate)
    && coordinate.every(Number.isFinite)
    && coordinate[0] >= slot.target.bounds.x
    && coordinate[0] <= slot.target.bounds.x + slot.target.bounds.width
    && coordinate[1] >= slot.target.bounds.y
    && coordinate[1] <= slot.target.bounds.y + slot.target.bounds.height;
  if (payload.clickType !== 'triple'
      || !coordinateInTarget
      || payload.snapshotId !== slot.request_binding.value
      || payload.targetProcessIdentifier !== slot.target.pid
      || payload.targetWindowID !== slot.target.window_id
      || !exactKeys(payload.expectedProcessIdentity, [
        'processIdentifier', 'processStartIdentity',
      ])
      || payload.expectedProcessIdentity.processIdentifier !== slot.target.pid
      || !wireUInt64MatchesDecimal(
        payload.expectedProcessIdentity.processStartIdentity,
        slot.target.start_identity,
      )
      || !wireBoundsMatchTarget(payload.expectedWindowBounds, slot.target)
      || !wireWindowIdentityMatchesTarget(payload.expectedWindowIdentity, slot.target)) {
    throw new TypeError('protocol-1.30 click does not bind triple delivery to the exact target receipt');
  }
}

function unsignedListenerAttestation(value) {
  return {
    schemaVersion: value.schemaVersion,
    listenerInstanceID: value.listenerInstanceID,
    publicKey: value.publicKey,
    host: value.host,
    createdAtUnixMilliseconds: value.createdAtUnixMilliseconds,
    receiptArchiveDirectory: value.receiptArchiveDirectory,
  };
}

function unsignedSessionAttestation(value) {
  return {
    schemaVersion: value.schemaVersion,
    sessionID: value.sessionID,
    listenerInstanceID: value.listenerInstanceID,
    listenerPublicKeySHA256: value.listenerPublicKeySHA256,
    clientInstanceID: value.clientInstanceID,
    client: value.client,
    maximumRequestCount: value.maximumRequestCount,
    remainingClaimCount: value.remainingClaimCount,
    ...(value.predecessorSessionID === undefined ? {} : {
      predecessorSessionID: value.predecessorSessionID,
    }),
    createdAtUnixMilliseconds: value.createdAtUnixMilliseconds,
  };
}

function validateCanonicalPayload(encoded, expected, context) {
  const bytes = decodeBase64(encoded, context);
  const decoded = parseCanonicalJSON(bytes, context);
  if (!sameJSON(decoded, expected)) throw new TypeError(`${context} differs from the exported object`);
  return bytes;
}

function decodeBundle(bundle, slot, contract) {
  if (!exactKeys(bundle, [
    'operationAttestation', 'operationSessionAttestation', 'receipt',
    'canonicalListenerAttestationPayload', 'canonicalSessionAttestationPayload',
    'canonicalReceiptPayload', 'canonicalRequest', 'canonicalResponse',
  ])) {
    throw new TypeError('verification bundle must be one closed protocol-1.29 object');
  }
  const rawKey = decodeBase64(contract.listener.public_key_base64, 'contract listener key');
  const listener = bundle.operationAttestation;
  if (!exactKeys(listener, [
    'schemaVersion', 'listenerInstanceID', 'publicKey', 'host', 'createdAtUnixMilliseconds',
    'receiptArchiveDirectory', 'signature',
  ]) || listener.schemaVersion !== 1) {
    throw new TypeError('listener attestation is malformed');
  }
  const listenerPayload = validateCanonicalPayload(
    bundle.canonicalListenerAttestationPayload,
    unsignedListenerAttestation(listener),
    'canonical listener attestation payload',
  );
  verifyEd25519(listenerPayload, listener.signature, rawKey, 'listener attestation');
  const listenerIdentity = {
    instance_id: normalizedUUID(listener.listenerInstanceID, UUID_V4),
    public_key_base64: listener.publicKey,
    public_key_sha256: sha256(decodeBase64(listener.publicKey, 'listener public key')),
    host: normalizeWireProcess(listener.host, 'listener host'),
    created_at_milliseconds: listener.createdAtUnixMilliseconds,
    receipt_archive_directory: listener.receiptArchiveDirectory,
  };
  const { source_commit: _listenerSourceCommit, ...contractedListenerAttestation } = contract.listener;
  if (!sameJSON(listenerIdentity, contractedListenerAttestation)) {
    throw new TypeError('listener attestation differs from the original contract');
  }

  const session = bundle.operationSessionAttestation;
  const sessionKeys = [
    'schemaVersion', 'sessionID', 'listenerInstanceID', 'listenerPublicKeySHA256',
    'clientInstanceID', 'client', 'maximumRequestCount', 'remainingClaimCount',
    'createdAtUnixMilliseconds', 'signature',
  ];
  if (!onlyKeys(session, [...sessionKeys, 'predecessorSessionID'])
      || sessionKeys.some((key) => !(key in session))
      || session.schemaVersion !== 1 || !positiveInteger(session.maximumRequestCount)
      || !Number.isSafeInteger(session.remainingClaimCount)
      || session.remainingClaimCount !== session.maximumRequestCount) {
    throw new TypeError('operation session attestation is malformed');
  }
  const sessionPayload = validateCanonicalPayload(
    bundle.canonicalSessionAttestationPayload,
    unsignedSessionAttestation(session),
    'canonical session attestation payload',
  );
  verifyEd25519(sessionPayload, session.signature, rawKey, 'operation session attestation');
  const normalizedSession = {
    id: normalizedUUID(session.sessionID, UUID_V4),
    sequence: slot.session.sequence,
    predecessor_id: session.predecessorSessionID === undefined
      ? null
      : normalizedUUID(session.predecessorSessionID, UUID_V4),
    client_instance_id: normalizedUUID(session.clientInstanceID, UUID_V4),
    attestation_sha256: sha256(canonicalBytes(session)),
    listener_instance_id: normalizedUUID(session.listenerInstanceID, UUID_V4),
    listener_public_key_sha256: session.listenerPublicKeySHA256,
  };
  if (!sameJSON(normalizedSession, slot.session)
      || normalizedUUID(session.listenerInstanceID, UUID_V4) !== contract.listener.instance_id
      || session.listenerPublicKeySHA256 !== contract.listener.public_key_sha256
      || !sameJSON(normalizeWireProcess(session.client, 'session client'), slot.client)
      || !milliseconds(session.createdAtUnixMilliseconds)
      || session.createdAtUnixMilliseconds > slot.interval.started_at_milliseconds
      || session.maximumRequestCount > 16384) {
    throw new TypeError('operation session differs from its exact contract slot');
  }

  const signedReceipt = bundle.receipt;
  if (!exactKeys(signedReceipt, ['payload', 'signature']) || !isPlainObject(signedReceipt.payload)) {
    throw new TypeError('signed operation receipt is malformed');
  }
  const payload = signedReceipt.payload;
  const requiredPayloadKeys = [
    'schemaVersion', 'requestID', 'sessionID', 'sessionSequence', 'sessionAttestationSHA256',
    'listenerInstanceID', 'listenerPublicKeySHA256', 'clientInstanceID', 'host', 'client',
    'operation', 'requestSHA256', 'responseSHA256', 'target', 'remainingClaimCount',
    'startedAtUnixMilliseconds', 'completedAtUnixMilliseconds',
  ];
  const optionalPayloadKeys = [
    'focusedElement', 'targetAttributionFailure', 'targetAttributionEvidence',
    'selectedLeafEvidence', 'outcome',
  ];
  if (!onlyKeys(payload, [...requiredPayloadKeys, ...optionalPayloadKeys])
      || requiredPayloadKeys.some((key) => !(key in payload))
      || payload.schemaVersion !== 1
      || payload.targetAttributionFailure !== undefined
      || payload.targetAttributionEvidence !== undefined) {
    throw new TypeError('signed operation payload is not a closed certification receipt');
  }
  const receiptPayload = validateCanonicalPayload(
    bundle.canonicalReceiptPayload,
    payload,
    'canonical operation receipt payload',
  );
  verifyEd25519(receiptPayload, signedReceipt.signature, rawKey, 'operation receipt');

  const requestBytes = decodeBase64(bundle.canonicalRequest, 'canonical request');
  const responseBytes = decodeBase64(bundle.canonicalResponse, 'canonical response');
  const facts = wireFacts(requestBytes, responseBytes);
  validateAttestedRequestCarriage(facts, payload, contract);
  validateOperationSemantics(facts, slot);
  const requestBinding = {
    path: structuredClone(slot.request_binding.path),
    value: valueAtPath(facts.request_document, slot.request_binding.path),
  };
  const normalizedOutcome = payload.outcome === undefined ? null : normalizeWireOutcome(payload.outcome);
  const row = {
    slot_id: slot.slot_id,
    operation_id: slot.operation_id,
    kind: slot.kind,
    checkpoint: slot.checkpoint,
    controller_id: slot.controller_id,
    target_id: slot.target_id,
    controller: structuredClone(slot.controller),
    client: normalizeWireProcess(payload.client, 'receipt client'),
    request_id: normalizedUUID(payload.requestID, UUID_V8),
    session: {
      ...structuredClone(normalizedSession),
      id: normalizedUUID(payload.sessionID, UUID_V4),
      sequence: normalizedDecimal(payload.sessionSequence),
      client_instance_id: normalizedUUID(payload.clientInstanceID, UUID_V4),
    },
    operation: payload.operation,
    request_binding: requestBinding,
    request_envelope_case: facts.request_envelope_case,
    request_case: facts.request_case,
    response_envelope_case: facts.response_envelope_case,
    response_case: facts.response_case,
    request_sha256: payload.requestSHA256,
    response_sha256: payload.responseSHA256,
    target: normalizeWireTarget(payload.target),
    focused_element: payload.focusedElement ?? null,
    selected_leaf_evidence: payload.selectedLeafEvidence ?? null,
    interval: {
      started_at_milliseconds: payload.startedAtUnixMilliseconds,
      completed_at_milliseconds: payload.completedAtUnixMilliseconds,
    },
    source: {
      protocol_source_commit: contract.source.commit,
      host_source_commit: contract.listener.source_commit,
      listener_instance_id: normalizedUUID(payload.listenerInstanceID, UUID_V4),
      host: normalizeWireProcess(payload.host, 'receipt host'),
    },
    expected_outcome: normalizedOutcome,
  };
  const mismatchedSlotFields = Object.keys(slot).filter((key) => !sameJSON(row[key], slot[key]));
  const integrityFailures = [
    [payload.listenerPublicKeySHA256 === contract.listener.public_key_sha256, 'listener key'],
    [payload.sessionAttestationSHA256 === row.session.attestation_sha256, 'session digest'],
    [Number.isSafeInteger(payload.remainingClaimCount)
      && payload.remainingClaimCount >= 0
      && payload.remainingClaimCount < session.remainingClaimCount, 'remaining claim count'],
    [row.request_id === deterministicRequestID(row.session.id, row.session.sequence), 'request ID'],
    [sha256(requestBytes) === row.request_sha256, 'request digest'],
    [sha256(responseBytes) === row.response_sha256, 'response digest'],
    [sameJSON(facts.response_outcome, row.expected_outcome), 'response outcome'],
  ].filter(([passed]) => !passed).map(([, name]) => name);
  if (mismatchedSlotFields.length > 0 || integrityFailures.length > 0) {
    const details = [
      ...(mismatchedSlotFields.length > 0 ? [`slot fields: ${mismatchedSlotFields.join(', ')}`] : []),
      ...(integrityFailures.length > 0 ? [`integrity: ${integrityFailures.join(', ')}`] : []),
    ].join('; ');
    throw new TypeError(`signed operation receipt differs from its exact contract slot (${details})`);
  }
  return {
    row,
    session_metadata: {
      id: normalizedSession.id,
      predecessor_id: normalizedSession.predecessor_id,
      listener_instance_id: normalizedUUID(session.listenerInstanceID, UUID_V4),
      listener_public_key_sha256: session.listenerPublicKeySHA256,
      client_instance_id: normalizedSession.client_instance_id,
      client: normalizeWireProcess(session.client, 'session client'),
      maximum_request_count: session.maximumRequestCount,
      initial_remaining_claim_count: session.remainingClaimCount,
      receipt_remaining_claim_count: payload.remainingClaimCount,
      created_at_milliseconds: session.createdAtUnixMilliseconds,
    },
  };
}

function validateSessionCorpus(decoded, failures) {
  const sessions = new Map();
  const claimsBySession = new Map();
  const claims = new Set();
  const remainingClaims = new Set();
  for (const entry of decoded) {
    const session = entry.session_metadata;
    const prior = sessions.get(session.id);
    if (prior && !sameJSON(prior, session)) {
      // Per-operation remaining claim counts differ by design; compare the signed session only.
      const stablePrior = { ...prior, receipt_remaining_claim_count: null };
      const stableCurrent = { ...session, receipt_remaining_claim_count: null };
      if (!sameJSON(stablePrior, stableCurrent)) {
        failures.push(failure('offline_session_fork', `Session ${session.id} has conflicting attestations`));
      }
    } else if (!prior) {
      sessions.set(session.id, session);
    }
    const claim = `${entry.row.session.id}:${entry.row.session.sequence}`;
    const remaining = `${entry.row.session.id}:${session.receipt_remaining_claim_count}`;
    if (claims.has(claim)) {
      failures.push(failure('offline_session_replay', 'One signed session sequence appears twice', entry.row.slot_id));
    }
    if (remainingClaims.has(remaining)) {
      failures.push(failure('offline_session_replay', 'One signed session claim budget appears twice', entry.row.slot_id));
    }
    claims.add(claim);
    remainingClaims.add(remaining);
    if (!claimsBySession.has(session.id)) claimsBySession.set(session.id, []);
    claimsBySession.get(session.id).push({
      sequence: BigInt(entry.row.session.sequence),
      remaining: session.receipt_remaining_claim_count,
    });
  }
  for (const [sessionID, sessionClaims] of claimsBySession) {
    const session = sessions.get(sessionID);
    const sequences = sessionClaims.map((entry) => entry.sequence).sort((left, right) => (
      left < right ? -1 : left > right ? 1 : 0
    ));
    const remaining = sessionClaims.map((entry) => entry.remaining).sort((left, right) => right - left);
    const sequencesComplete = sequences.every((value, index) => value === BigInt(index));
    const remainingComplete = remaining.every((value, index) => (
      value === session.initial_remaining_claim_count - index - 1
    ));
    if (!sequencesComplete || !remainingComplete) {
      failures.push(failure(
        'offline_session_completeness',
        `Session ${sessionID} does not contain one complete claim prefix`,
      ));
    }
  }
  const successorCounts = new Map();
  for (const session of sessions.values()) {
    if (session.predecessor_id === null) continue;
    successorCounts.set(session.predecessor_id, (successorCounts.get(session.predecessor_id) ?? 0) + 1);
    const predecessor = sessions.get(session.predecessor_id);
    if (!predecessor
        || predecessor.listener_instance_id !== session.listener_instance_id
        || predecessor.listener_public_key_sha256 !== session.listener_public_key_sha256
        || predecessor.client_instance_id !== session.client_instance_id
        || !sameJSON(predecessor.client, session.client)
        || predecessor.created_at_milliseconds > session.created_at_milliseconds) {
      failures.push(failure(
        'offline_session_predecessor',
        `Session ${session.id} has no exact predecessor in the closed corpus`,
      ));
    }
    const visited = new Set([session.id]);
    let cursor = session.predecessor_id;
    while (cursor !== null) {
      if (visited.has(cursor)) {
        failures.push(failure('offline_session_fork', `Session chain cycles at ${cursor}`));
        break;
      }
      visited.add(cursor);
      cursor = sessions.get(cursor)?.predecessor_id ?? null;
    }
  }
  for (const [sessionID, count] of successorCounts) {
    if (count > 1) {
      failures.push(failure('offline_session_fork', `Session ${sessionID} has more than one successor`));
    }
  }
}

export function runOfflineValidatorV3({
  catalog,
  catalogSHA256,
  contract,
  manifest,
  bundles,
}) {
  const contractSHA256 = canonicalSHA256(contract);
  const manifestSHA256 = aggregateSHA256('operation-manifest', manifest);
  const failures = [
    ...validateCatalog(catalog),
    ...validateContract(catalog, catalogSHA256, contract),
    ...validateManifest(catalog, catalogSHA256, contract, contractSHA256, manifest),
  ];
  const manifestFiles = manifest?.slots?.map((entry) => entry?.bundle_file) ?? [];
  const bundleFiles = bundles.map((entry) => entry.file).sort();
  if (!sameJSON([...manifestFiles].sort(), bundleFiles)) {
    failures.push(failure(
      'offline_bundle_inventory',
      'Raw export corpus must equal the manifest exactly; missing, auxiliary, and extra bundles are forbidden',
    ));
  }
  const bundleByFile = new Map(bundles.map((entry) => [entry.file, entry]));
  if (bundleByFile.size !== bundles.length) {
    failures.push(failure('offline_bundle_inventory', 'Raw export corpus contains duplicate filenames'));
  }
  const decoded = [];
  for (const [index, manifestRow] of (manifest?.slots ?? []).entries()) {
    const slot = contract?.operation_slots?.[index];
    const bundle = bundleByFile.get(manifestRow?.bundle_file);
    if (!bundle) continue;
    if (bundle.sha256 !== manifestRow.bundle_sha256) {
      failures.push(failure('offline_bundle_digest', 'Raw bundle bytes differ from their manifest digest', slot?.slot_id));
      continue;
    }
    try {
      const result = decodeBundle(bundle.document, slot, contract);
      decoded.push({
        ...result,
        file: bundle.file,
        file_sha256: bundle.sha256,
      });
    } catch (error) {
      failures.push(failure('offline_bundle_validation', error.message, slot?.slot_id));
    }
  }
  validateSessionCorpus(decoded, failures);
  if (decoded.length !== manifest?.slots?.length) {
    failures.push(failure('offline_receipt_bijection', 'Every manifest slot requires one validated raw receipt'));
  }
  const receiptRows = decoded.map((entry) => ({
    slot_id: entry.row.slot_id,
    operation_id: entry.row.operation_id,
    request_id: entry.row.request_id,
    session_id: entry.row.session.id,
    session_sequence: entry.row.session.sequence,
    operation: entry.row.operation,
    controller_id: entry.row.controller_id,
    target_id: entry.row.target_id,
    target: entry.row.target,
    interval: entry.row.interval,
    source: entry.row.source,
    expected_outcome: entry.row.expected_outcome,
    request_sha256: entry.row.request_sha256,
    response_sha256: entry.row.response_sha256,
    file: entry.file,
    file_sha256: entry.file_sha256,
  }));
  return {
    version: 3,
    success: failures.length === 0,
    contract_sha256: contractSHA256,
    operation_manifest_sha256: manifestSHA256,
    receipts: receiptRows,
    failures,
  };
}

function validFirstPartyVerdict(value, slot, manifestRow, contract) {
  const keys = [
    'valid', 'validator_id', 'trust_source', 'minimum_protocol_version',
    'host_protocol_version', 'request_id',
    'session_id', 'session_sequence', 'predecessor_session_id', 'operation',
    'listener_instance_id', 'listener_public_key_sha256', 'host', 'client_instance_id',
    'host_source_commit', 'client', 'request_sha256', 'response_sha256', 'bundle_sha256',
    'terminal_receipt_attested', 'target_attested', 'outcome_attested', 'retention_basis',
  ];
  return exactKeys(value, keys)
    && value.valid === true
    && value.validator_id === 'peekaboo-bridge-receipt-validate-v1'
    && value.trust_source === 'authenticated_live_listener'
    && value.minimum_protocol_version === '1.29'
    && value.host_protocol_version === '1.31'
    && value.request_id === slot.request_id
    && value.session_id === slot.session.id
    && value.session_sequence === slot.session.sequence
    && value.predecessor_session_id === slot.session.predecessor_id
    && value.operation === slot.operation
    && value.listener_instance_id === contract.listener.instance_id
    && value.listener_public_key_sha256 === contract.listener.public_key_sha256
    && sameJSON(value.host, contract.listener.host)
    && value.host_source_commit === contract.listener.source_commit
    && value.client_instance_id === slot.session.client_instance_id
    && sameJSON(value.client, slot.client)
    && value.request_sha256 === slot.request_sha256
    && value.response_sha256 === slot.response_sha256
    && value.bundle_sha256 === manifestRow.bundle_sha256
    && value.terminal_receipt_attested === true
    && value.target_attested === true
    && value.outcome_attested === (slot.expected_outcome !== null)
    && value.retention_basis === 'exported_bundle';
}

function producerDocumentIdentity(processIdentity, role) {
  return {
    pid: processIdentity.pid,
    startIdentity: processIdentity.start_identity,
    role,
  };
}

function foregroundDocumentTarget(target) {
  return {
    pid: target.pid,
    startIdentity: target.start_identity,
    windowID: target.window_id,
  };
}

function sortedProducerDocumentRows(rows) {
  return [...rows].sort((left, right) => (
    left.pid - right.pid || left.startIdentity.localeCompare(right.startIdentity)
      || left.role.localeCompare(right.role)
  ));
}

function validProducerDocument(value, contract, revision, foregroundActive) {
  if (!exactKeys(value, [
    'revision', 'executionNonce', 'monitorInstanceID', 'producers', 'foreground',
  ]) || value.revision !== revision
      || value.executionNonce !== contract.execution_nonce
      || value.monitorInstanceID !== contract.monitor_binding.monitor_instance_id
      || !Array.isArray(value.producers)
      || value.producers.some((producer) => !exactKeys(producer, [
        'pid', 'startIdentity', 'role',
      ]) || !positiveInteger(producer.pid)
        || normalizedDecimal(producer.startIdentity, true) === null
        || !['bridge', 'foreground-controller'].includes(producer.role))
      || new Set(value.producers.map((producer) => producer.pid)).size !== value.producers.length
      || !exactKeys(value.foreground, ['active', 'target'])
      || value.foreground.active !== foregroundActive) {
    return false;
  }
  const baselineProducers = [
    producerDocumentIdentity(contract.listener.host, 'bridge'),
    ...contract.controlled_targets.map((entry) => producerDocumentIdentity(entry.controller, 'bridge')),
  ];
  const expectedProducers = foregroundActive
    ? [...baselineProducers, producerDocumentIdentity(
      contract.monitor_binding.foreground_controller,
      'foreground-controller',
    )]
    : baselineProducers;
  if (!sameJSON(
    sortedProducerDocumentRows(value.producers),
    sortedProducerDocumentRows(expectedProducers),
  )) return false;
  const expectedTarget = foregroundActive
    ? foregroundDocumentTarget(contract.monitor_binding.foreground_target)
    : null;
  return sameJSON(value.foreground.target, expectedTarget);
}

function validMonitorHeartbeat(value, contract) {
  return exactKeys(value, [
    'sequence', 'monotonicMicroseconds', 'wallClockMilliseconds',
    'lastCleanSequence', 'contaminationRetries',
    'contaminationBlocked', 'inputAttributionAvailable', 'allowedProducerRevision',
    'phase', 'cursorMovementObserved', 'pendingActivationCount',
    'pendingFocusedWindowChange', 'authorizationEpoch', 'transitionAcknowledged',
    'foregroundActive', 'foregroundTargetPID', 'foregroundTargetWindowID',
    'attributedForegroundEventCount', 'attributedForegroundSourcePIDs',
    'foregroundActivityObserved', 'executionNonce', 'monitorInstanceID',
    'historyCommitmentSHA256',
  ])
    && positiveInteger(value.sequence)
    && positiveInteger(value.monotonicMicroseconds)
    && milliseconds(value.wallClockMilliseconds)
    && positiveInteger(value.lastCleanSequence)
    && Number.isSafeInteger(value.contaminationRetries) && value.contaminationRetries >= 0
    && value.contaminationBlocked === false
    && value.inputAttributionAvailable === true
    && positiveInteger(value.allowedProducerRevision)
    && typeof value.phase === 'string' && value.phase.length > 0
    && typeof value.cursorMovementObserved === 'boolean'
    && value.pendingActivationCount === 0
    && value.pendingFocusedWindowChange === false
    && positiveInteger(value.authorizationEpoch)
    && value.transitionAcknowledged === false
    && typeof value.foregroundActive === 'boolean'
    && (value.foregroundTargetPID === null || positiveInteger(value.foregroundTargetPID))
    && (value.foregroundTargetWindowID === null || positiveInteger(value.foregroundTargetWindowID))
    && Number.isSafeInteger(value.attributedForegroundEventCount)
    && value.attributedForegroundEventCount >= 0
    && Array.isArray(value.attributedForegroundSourcePIDs)
    && value.attributedForegroundSourcePIDs.every(positiveInteger)
    && new Set(value.attributedForegroundSourcePIDs).size
      === value.attributedForegroundSourcePIDs.length
    && typeof value.foregroundActivityObserved === 'boolean'
    && value.executionNonce === contract.execution_nonce
    && value.monitorInstanceID === contract.monitor_binding.monitor_instance_id
    && HEX64.test(value.historyCommitmentSHA256 ?? '')
    // A stable clean heartbeat is the durable post-ack fence. The transient
    // acknowledgement heartbeat can be overwritten before a poller observes it.
    && value.lastCleanSequence === value.sequence;
}

function validMonitorClockTransition(previous, current) {
  if (current.monotonicMicroseconds <= previous.monotonicMicroseconds
      || current.wallClockMilliseconds < previous.wallClockMilliseconds) {
    return false;
  }
  const monotonicDelta = current.monotonicMicroseconds - previous.monotonicMicroseconds;
  const wallDelta = current.wallClockMilliseconds - previous.wallClockMilliseconds;
  if (!Number.isSafeInteger(monotonicDelta) || !Number.isSafeInteger(wallDelta)
      || wallDelta > Math.floor(Number.MAX_SAFE_INTEGER / 1000)) {
    return false;
  }
  const wallDeltaMicroseconds = wallDelta * 1000;
  return Number.isSafeInteger(wallDeltaMicroseconds)
    && Math.abs(wallDeltaMicroseconds - monotonicDelta) <= 2_000_000;
}

function validMonitorSample(value, sentinel) {
  return exactKeys(value, [
    'frontmost_pid', 'frontmost_window_id', 'clipboard_change_count', 'clipboard_digest',
  ])
    && value.frontmost_pid === sentinel.pid
    && value.frontmost_window_id === sentinel.window_id
    && Number.isSafeInteger(value.clipboard_change_count) && value.clipboard_change_count >= 0
    && HEX64.test(value.clipboard_digest ?? '');
}

function validCrashInventoryRow(value) {
  return exactKeys(value, ['name', 'size', 'modified_at_milliseconds', 'sha256'])
    && typeof value.name === 'string' && /^[A-Za-z0-9._-]+$/.test(value.name)
    && Number.isSafeInteger(value.size) && value.size > 0
    && milliseconds(value.modified_at_milliseconds)
    && HEX64.test(value.sha256 ?? '');
}

function validCrashEvidence(catalog, value) {
  if (!exactKeys(value, [
    'version', 'directory', 'prefixes', 'baseline', 'final', 'new_reports',
  ]) || value.version !== 1
      || typeof value.directory !== 'string' || !path.isAbsolute(value.directory)
      || !sameJSON(value.prefixes, catalog.monitor_contract.crash_report_prefixes)
      || !Array.isArray(value.baseline) || !Array.isArray(value.final)
      || value.baseline.some((row) => !validCrashInventoryRow(row))
      || value.final.some((row) => !validCrashInventoryRow(row))
      || new Set(value.baseline.map((row) => row.name)).size !== value.baseline.length
      || new Set(value.final.map((row) => row.name)).size !== value.final.length
      || !sameJSON(value.baseline, [...value.baseline].sort((left, right) => (
        left.name.localeCompare(right.name)
      )))
      || !sameJSON(value.final, [...value.final].sort((left, right) => (
        left.name.localeCompare(right.name)
      )))
      || !sameJSON(value.baseline, value.final)
      || !Array.isArray(value.new_reports) || value.new_reports.length !== 0) {
    return false;
  }
  return true;
}

export function requireCanonicalDiagnosticReportsDirectory(
  directory,
  {
    homeDirectory = os.userInfo().homedir,
    realpathSync = fs.realpathSync,
    lstatSync = fs.lstatSync,
  } = {},
) {
  const expected = path.join(homeDirectory, 'Library', 'Logs', 'DiagnosticReports');
  if (directory !== expected) {
    throw new TypeError('live crash evidence must use the current user DiagnosticReports directory');
  }
  let canonical;
  let info;
  try {
    canonical = realpathSync(directory);
    info = lstatSync(directory);
  } catch {
    throw new TypeError('live crash evidence DiagnosticReports directory is unavailable');
  }
  if (canonical !== expected || !info.isDirectory() || info.isSymbolicLink()) {
    throw new TypeError('live crash evidence DiagnosticReports directory is not canonical');
  }
  return canonical;
}

function monitorHistoryProjection(monitorEvidence) {
  const fences = Array.isArray(monitorEvidence?.fences)
    ? monitorEvidence.fences.map((entry) => {
      const heartbeat = structuredClone(entry?.heartbeat);
      if (isPlainObject(heartbeat)) delete heartbeat.historyCommitmentSHA256;
      return { name: entry?.name, heartbeat };
    })
    : [];
  return {
    execution_nonce: monitorEvidence?.execution_nonce,
    monitor_instance_id: monitorEvidence?.monitor_instance_id,
    monitor_attestation_socket_path: monitorEvidence?.monitor_attestation_socket_path,
    baseline_commitment_sha256: monitorEvidence?.baseline_commitment_sha256,
    producer_sets: monitorEvidence?.producer_sets,
    fences,
    baseline_sample: monitorEvidence?.baseline_sample,
    final_sample: monitorEvidence?.final_sample,
    foreground_plan: monitorEvidence?.foreground_plan,
    violation_records: monitorEvidence?.violation_records,
    contamination_records: monitorEvidence?.contamination_records,
    crash_evidence: monitorEvidence?.crash_evidence,
    restoration: monitorEvidence?.restoration,
  };
}

export function monitorHistoryCommitmentSHA256(monitorEvidence) {
  return aggregateSHA256('monitor-history', monitorHistoryProjection(monitorEvidence));
}

function monitorBaselineProjection(monitorEvidence) {
  return {
    execution_nonce: monitorEvidence?.execution_nonce,
    monitor_instance_id: monitorEvidence?.monitor_instance_id,
    monitor_attestation_socket_path: monitorEvidence?.monitor_attestation_socket_path,
    producer_set: monitorEvidence?.producer_sets?.baseline,
    baseline_sample: monitorEvidence?.baseline_sample,
    foreground_plan: monitorEvidence?.foreground_plan,
    crash_baseline: {
      directory: monitorEvidence?.crash_evidence?.directory,
      prefixes: monitorEvidence?.crash_evidence?.prefixes,
      baseline: monitorEvidence?.crash_evidence?.baseline,
    },
  };
}

export function monitorBaselineCommitmentSHA256(monitorEvidence) {
  return aggregateSHA256('monitor-baseline', monitorBaselineProjection(monitorEvidence));
}

function validateLiveMonitorEvidence(catalog, contract, monitorEvidence) {
  const failures = [];
  if (!exactKeys(monitorEvidence, [
    'version', 'execution_nonce', 'monitor_instance_id', 'monitor_source_sha256',
    'coordinator_source_sha256', 'monitor_process', 'monitor_attestation_socket_path', 'sentinel',
    'foreground_controller', 'foreground_target', 'producer_sets', 'fences',
    'baseline_sample', 'final_sample', 'foreground_plan',
    'violation_records', 'contamination_records',
    'baseline_commitment_sha256', 'history_commitment_sha256',
    'crash_evidence', 'restoration',
  ]) || monitorEvidence.version !== 1
      || monitorEvidence.execution_nonce !== contract.execution_nonce
      || monitorEvidence.monitor_instance_id !== contract.monitor_binding.monitor_instance_id
      || monitorEvidence.monitor_source_sha256 !== catalog.monitor_source.probe_sha256
      || monitorEvidence.coordinator_source_sha256 !== catalog.current_build_source.coordinator.sha256
      || !HEX64.test(monitorEvidence.history_commitment_sha256 ?? '')
      || !HEX64.test(monitorEvidence.baseline_commitment_sha256 ?? '')
      || !sameJSON(monitorEvidence.monitor_process, contract.monitor_binding.monitor_process)
      || monitorEvidence.monitor_attestation_socket_path
        !== contract.monitor_binding.monitor_attestation_socket_path
      || !sameJSON(monitorEvidence.sentinel, contract.monitor_binding.sentinel)
      || !sameJSON(
        monitorEvidence.foreground_controller,
        contract.monitor_binding.foreground_controller,
      )
      || !sameJSON(monitorEvidence.foreground_target, contract.monitor_binding.foreground_target)) {
    return [failure('monitor_schema', 'Live monitor evidence is not bound to the exact run and source')];
  }
  if (!exactKeys(monitorEvidence.foreground_plan, [
    'request_marker', 'expected_value_sha256', 'baseline_value_sha256', 'observer',
    'observer_build', 'semantic_element', 'observation_path', 'restoration_path', 'witness_path',
    'observer_attestation_socket_path',
  ])
      || monitorEvidence.foreground_plan.request_marker
        !== `peekaboo-foreground-postcondition:${contract.execution_nonce}`
      || monitorEvidence.foreground_plan.expected_value_sha256
        !== expectedForegroundValueSHA256(contract.execution_nonce)
      || !HEX64.test(monitorEvidence.foreground_plan.baseline_value_sha256 ?? '')
      || monitorEvidence.foreground_plan.baseline_value_sha256
        === monitorEvidence.foreground_plan.expected_value_sha256
      || !validProcess(monitorEvidence.foreground_plan.observer)
      || contract.controlled_targets.some((entry) => sameProcessGeneration(
        entry.controller,
        monitorEvidence.foreground_plan.observer,
      ))
      || sameProcessGeneration(
        contract.monitor_binding.foreground_controller,
        monitorEvidence.foreground_plan.observer,
      )
      || !sameJSON(monitorEvidence.foreground_plan.observer_build, contract.controller_build)
      || !validSemanticElement(monitorEvidence.foreground_plan.semantic_element)
      || typeof monitorEvidence.foreground_plan.observation_path !== 'string'
      || !path.isAbsolute(monitorEvidence.foreground_plan.observation_path)
      || typeof monitorEvidence.foreground_plan.restoration_path !== 'string'
      || !path.isAbsolute(monitorEvidence.foreground_plan.restoration_path)
      || typeof monitorEvidence.foreground_plan.witness_path !== 'string'
      || !path.isAbsolute(monitorEvidence.foreground_plan.witness_path)
      || !validUnixSocketPath(monitorEvidence.foreground_plan.observer_attestation_socket_path)
      || monitorEvidence.foreground_plan.observer_attestation_socket_path
        === monitorEvidence.monitor_attestation_socket_path) {
    failures.push(failure(
      'monitor_foreground_plan',
      'Monitor history does not commit the pre-execution foreground semantic plan',
    ));
  }
  const revisions = contract.monitor_binding.revisions;
  if (!exactKeys(monitorEvidence.producer_sets, ['baseline', 'grant', 'revoke'])
      || !validProducerDocument(monitorEvidence.producer_sets.baseline, contract, revisions.baseline, false)
      || !validProducerDocument(monitorEvidence.producer_sets.grant, contract, revisions.grant, true)
      || !validProducerDocument(monitorEvidence.producer_sets.revoke, contract, revisions.revoke, false)
      || !sameJSON(
        monitorEvidence.producer_sets.baseline.producers,
        monitorEvidence.producer_sets.revoke.producers,
      )) {
    failures.push(failure('monitor_producers', 'Producer revisions do not encode one exact grant and revoke'));
  }
  const requiredFenceNames = catalog.monitor_contract.required_fences;
  if (!Array.isArray(monitorEvidence.fences)
      || monitorEvidence.fences.length !== requiredFenceNames.length
      || monitorEvidence.fences.some((fence, index) => (
        !exactKeys(fence, ['name', 'heartbeat'])
        || fence.name !== requiredFenceNames[index]
        || !validMonitorHeartbeat(fence.heartbeat, contract)
      ))) {
    failures.push(failure('monitor_fences', 'Monitor fences are missing, reordered, or not stable and clean'));
  } else {
    const heartbeats = Object.fromEntries(monitorEvidence.fences.map((fence) => [fence.name, fence.heartbeat]));
    const ordered = monitorEvidence.fences.map((fence) => fence.heartbeat);
    if (ordered.some((heartbeat, index) => index > 0 && (
      heartbeat.sequence <= ordered[index - 1].sequence
      || !validMonitorClockTransition(ordered[index - 1], heartbeat)
      || heartbeat.authorizationEpoch <= ordered[index - 1].authorizationEpoch
    ))) {
      failures.push(failure('monitor_order', 'Monitor sequence, time, and authorization epochs must increase'));
    }
    const expectedFenceStates = [
      ['baseline-stable', revisions.baseline, false],
      ['grant-stable', revisions.grant, true],
      ['operations-start', revisions.grant, true],
      ['operations-complete', revisions.grant, true],
      ['revoke-stable', revisions.revoke, false],
      ['final-stable', revisions.revoke, false],
    ];
    for (const [name, revision, foregroundActive] of expectedFenceStates) {
      const heartbeat = heartbeats[name];
      const expectedTarget = foregroundActive ? contract.monitor_binding.foreground_target : null;
      if (heartbeat.allowedProducerRevision !== revision
          || heartbeat.foregroundActive !== foregroundActive
          || heartbeat.foregroundTargetPID !== (expectedTarget?.pid ?? null)
          || heartbeat.foregroundTargetWindowID !== (expectedTarget?.window_id ?? null)) {
        failures.push(failure('monitor_fence_state', `Fence ${name} has the wrong revision or target`));
      }
    }
    for (const name of ['baseline-stable', 'grant-stable', 'operations-start', 'revoke-stable', 'final-stable']) {
      const heartbeat = heartbeats[name];
      if (heartbeat.attributedForegroundEventCount !== 0
          || heartbeat.attributedForegroundSourcePIDs.length !== 0
          || heartbeat.foregroundActivityObserved !== false) {
        failures.push(failure('monitor_activity', `Fence ${name} carries activity from another revision or phase`));
      }
    }
    const activity = heartbeats['operations-complete'];
    if (!(activity.attributedForegroundEventCount > 0)
        || !sameJSON(
          activity.attributedForegroundSourcePIDs,
          [contract.monitor_binding.foreground_controller.pid],
        )
        || activity.foregroundActivityObserved !== true) {
      failures.push(failure('monitor_activity', 'Foreground activity is absent or belongs to another controller'));
    }
    const startMilliseconds = heartbeats['operations-start'].wallClockMilliseconds;
    const completeMilliseconds = heartbeats['operations-complete'].wallClockMilliseconds;
    const overlapSlots = catalog.monitor_contract.overlap_slot_ids.map((slotID) => (
      contract.operation_slots.find((slot) => slot.slot_id === slotID)
    ));
    if (!(startMilliseconds < completeMilliseconds)
        || overlapSlots.some((slot) => !slot
          || slot.interval.started_at_milliseconds >= startMilliseconds
          || slot.interval.completed_at_milliseconds <= completeMilliseconds)) {
      failures.push(failure(
        'monitor_overlap',
        'Signed background operations do not bracket exact-controller foreground activity',
      ));
    }
    if (ordered.some((heartbeat) => (
      heartbeat.wallClockMilliseconds < contract.interval.started_at_milliseconds
      || heartbeat.wallClockMilliseconds > contract.interval.completed_at_milliseconds
    ))) {
      failures.push(failure('monitor_interval', 'Monitor fences fall outside the contracted live interval'));
    }
    if (contract.interval.started_at_milliseconds !== ordered[0].wallClockMilliseconds
        || contract.interval.completed_at_milliseconds !== ordered.at(-1).wallClockMilliseconds) {
      failures.push(failure('monitor_interval', 'Run interval must equal the first and final stable monitor fences'));
    }
    const expectedHistoryCommitment = monitorHistoryCommitmentSHA256(monitorEvidence);
    const expectedBaselineCommitment = monitorBaselineCommitmentSHA256(monitorEvidence);
    if (monitorEvidence.baseline_commitment_sha256 !== expectedBaselineCommitment
        || ordered[0].historyCommitmentSHA256 !== expectedBaselineCommitment) {
      failures.push(failure(
        'monitor_baseline_commitment',
        'Baseline heartbeat does not precommit the producer, semantic plan, and ambient state',
      ));
    }
    if (monitorEvidence.history_commitment_sha256 !== expectedHistoryCommitment
        || ordered.at(-1).historyCommitmentSHA256 !== expectedHistoryCommitment) {
      failures.push(failure(
        'monitor_history_commitment',
        'Live final heartbeat does not commit the complete producer/fence history',
      ));
    }
  }
  if (!validMonitorSample(monitorEvidence.baseline_sample, contract.monitor_binding.sentinel)
      || !validMonitorSample(monitorEvidence.final_sample, contract.monitor_binding.sentinel)
      || monitorEvidence.baseline_sample.clipboard_change_count
        !== monitorEvidence.final_sample.clipboard_change_count
      || monitorEvidence.baseline_sample.clipboard_digest
        !== monitorEvidence.final_sample.clipboard_digest) {
    failures.push(failure('monitor_sentinel', 'Sentinel or clipboard state was not exactly preserved'));
  }
  if (!Array.isArray(monitorEvidence.violation_records)
      || monitorEvidence.violation_records.length !== 0
      || !Array.isArray(monitorEvidence.contamination_records)
      || monitorEvidence.contamination_records.length !== 0
      || !validCrashEvidence(catalog, monitorEvidence.crash_evidence)) {
    failures.push(failure('monitor_cleanliness', 'Violation, contamination, or crash evidence is nonempty'));
  }
  const finalBoundsSlotIDs = catalog.slots
    .filter((slot) => slot.checkpoint === 'final-bounds')
    .map((slot) => slot.slot_id);
  if (!exactKeys(monitorEvidence.restoration, [
    'background_final_bounds_slot_ids', 'foreground_postcondition_sha256',
    'sentinel_sample_sha256',
  ]) || !sameJSON(
    monitorEvidence.restoration.background_final_bounds_slot_ids,
    finalBoundsSlotIDs,
  )
      || !HEX64.test(monitorEvidence.restoration.foreground_postcondition_sha256 ?? '')
      || monitorEvidence.restoration.sentinel_sample_sha256
        !== aggregateSHA256('monitor-sample', monitorEvidence.final_sample)) {
    failures.push(failure(
      'monitor_restoration',
      'Restoration must bind signed final-bounds slots, foreground witness, and final sentinel sample',
    ));
  }
  return failures;
}

function validateForegroundPostcondition(contract, monitorEvidence, witness) {
  const plan = monitorEvidence?.foreground_plan;
  if (!isPlainObject(monitorEvidence) || !Array.isArray(monitorEvidence.fences)
      || !exactKeys(witness, [
    'version', 'execution_nonce', 'target', 'observer', 'focused_element', 'interval', 'request_marker',
    'before_value_sha256', 'expected_value_sha256', 'observed_value_sha256',
    'restored_value_sha256', 'observation_path', 'observation_file_sha256',
    'restoration_path', 'restoration_file_sha256', 'passed', 'restored',
  ]) || witness.version !== 1
      || witness.execution_nonce !== contract.execution_nonce
      || !isPlainObject(plan)
      || !sameJSON(witness.target, contract.monitor_binding.foreground_target)
      || !sameJSON(witness.observer, plan.observer)
      || !exactKeys(witness.focused_element, ['role', 'title', 'identifier', 'frame'])
      || witness.focused_element.role !== plan.semantic_element.role
      || witness.focused_element.identifier !== plan.semantic_element.identifier
      || witness.focused_element.title !== plan.semantic_element.title
      || !validBounds(witness.focused_element.frame)
      || !boundsContain(witness.target.bounds, witness.focused_element.frame)
      || sameProcessGeneration(witness.observer, contract.monitor_binding.foreground_controller)
      || !validInterval(witness.interval, contract.interval)
      || witness.request_marker !== plan.request_marker
      || !HEX64.test(witness.before_value_sha256 ?? '')
      || !HEX64.test(witness.expected_value_sha256 ?? '')
      || !HEX64.test(witness.observed_value_sha256 ?? '')
      || !HEX64.test(witness.restored_value_sha256 ?? '')
      || typeof witness.observation_path !== 'string' || !path.isAbsolute(witness.observation_path)
      || !HEX64.test(witness.observation_file_sha256 ?? '')
      || typeof witness.restoration_path !== 'string' || !path.isAbsolute(witness.restoration_path)
      || !HEX64.test(witness.restoration_file_sha256 ?? '')
      || witness.expected_value_sha256 !== plan.expected_value_sha256
      || witness.before_value_sha256 !== plan.baseline_value_sha256
      || witness.observation_path !== plan.observation_path
      || witness.restoration_path !== plan.restoration_path
      || witness.expected_value_sha256 !== witness.observed_value_sha256
      || witness.before_value_sha256 !== witness.restored_value_sha256
      || witness.before_value_sha256 === witness.observed_value_sha256
      || witness.passed !== true || witness.restored !== true) {
    return [failure(
      'foreground_postcondition',
      'Foreground semantic postcondition is not independently observed and restored',
    )];
  }
  const fences = Object.fromEntries(monitorEvidence.fences.map((fence) => [fence?.name, fence?.heartbeat]));
  if (!isPlainObject(fences['operations-start']) || !isPlainObject(fences['operations-complete'])) {
    return [failure(
      'foreground_postcondition_interval',
      'Foreground postcondition is missing its monitor activity bracket',
    )];
  }
  const bracketStart = fences['operations-start'].wallClockMilliseconds;
  const bracketEnd = fences['operations-complete'].wallClockMilliseconds;
  if (witness.interval.started_at_milliseconds < bracketStart
      || witness.interval.completed_at_milliseconds > bracketEnd) {
    return [failure(
      'foreground_postcondition_interval',
      'Foreground postcondition observation is outside the attributed overlap bracket',
    )];
  }
  return [];
}

function validateEvidence(
  catalog,
  catalogSHA256,
  contract,
  contractSHA256,
  manifest,
  manifestSHA256,
  evidence,
  offlineResult,
  freshFirstPartyRows,
) {
  const failures = [];
  const evidenceKeys = [
    'version', 'certification_kind', 'execution_nonce',
    'catalog_sha256', 'contract_sha256', 'operation_manifest_sha256',
    'first_party_validator_executable_sha256', 'socket_evidence', 'source_evidence',
    'monitor_evidence', 'foreground_postcondition',
  ];
  if (!onlyKeys(evidence, [...evidenceKeys, 'offline_protocol_validation'])
      || evidenceKeys.some((key) => !(key in evidence))
      || evidence.version !== 2
      || evidence.certification_kind !== LIVE_CERTIFICATION_KIND
      || evidence.execution_nonce !== contract.execution_nonce
      || evidence.catalog_sha256 !== catalogSHA256
      || evidence.contract_sha256 !== contractSHA256
      || evidence.operation_manifest_sha256 !== manifestSHA256
      || evidence.first_party_validator_executable_sha256
        !== contract.first_party_validator?.executable_sha256) {
    return [failure('evidence_schema', 'Raw evidence must be one closed exact live-physical version-2 object')];
  }
  if (!exactKeys(evidence.socket_evidence, ['path', 'device', 'inode', 'is_socket', 'is_symbolic_link'])
      || evidence.socket_evidence.path !== contract.socket_endpoint.path
      || evidence.socket_evidence.device !== contract.socket_endpoint.device
      || evidence.socket_evidence.inode !== contract.socket_endpoint.inode
      || evidence.socket_evidence.is_socket !== true
      || evidence.socket_evidence.is_symbolic_link !== false) {
    failures.push(failure('evidence_socket', 'Recorded authenticated socket evidence differs from the contract'));
  }
  if (!sameJSON(evidence.source_evidence, contract.source)) {
    failures.push(failure('evidence_source', 'Recorded source evidence differs from the source-controlled contract'));
  }
  failures.push(...validateLiveMonitorEvidence(catalog, contract, evidence.monitor_evidence));
  failures.push(...validateForegroundPostcondition(
    contract,
    evidence.monitor_evidence,
    evidence.foreground_postcondition,
  ));
  if (evidence.monitor_evidence?.restoration?.foreground_postcondition_sha256
      !== aggregateSHA256('foreground-postcondition', evidence.foreground_postcondition)) {
    failures.push(failure(
      'monitor_restoration',
      'Monitor restoration does not commit the foreground postcondition witness',
    ));
  }
  const freshBySlot = new Map(freshFirstPartyRows.map((row) => [row.slot_id, row]));
  if (freshBySlot.size !== manifest.slots.length || freshFirstPartyRows.length !== manifest.slots.length) {
    failures.push(failure('first_party_execution', 'Fresh first-party validation did not cover every manifest slot'));
  }
  for (const [index, manifestRow] of manifest.slots.entries()) {
    const slot = contract.operation_slots[index];
    const fresh = freshBySlot.get(slot.slot_id);
    if (!exactKeys(fresh, ['slot_id', 'bundle_file', 'file_sha256', 'verdict'])
        || fresh.slot_id !== slot.slot_id
        || fresh.bundle_file !== manifestRow.bundle_file
        || fresh.file_sha256 !== manifestRow.bundle_sha256
        || !validFirstPartyVerdict(fresh.verdict, slot, manifestRow, contract)) {
      failures.push(failure(
        'first_party_execution',
        'Fresh exact-listener verdict does not bind one manifest slot and raw bundle',
        slot.slot_id,
      ));
    }
  }
  const offlineRows = new Map(offlineResult.receipts.map((row) => [row.slot_id, row]));
  if (offlineRows.size !== manifest.slots.length) {
    failures.push(failure('offline_receipt_bijection', 'Fresh offline rows do not match every manifest slot'));
  }
  return failures;
}

async function buildMultiTargetCertificationSummary({
  catalog,
  catalogFileSHA256,
  contract,
  manifest,
  evidence: callerEvidence,
  bundles,
  firstPartyValidator,
  certificationAuthority = null,
}) {
  // A cached result is deliberately not part of the trusted input. Preserve the caller's object,
  // remove the field from the validation copy, and derive every summary fact from a fresh pass.
  const evidence = structuredClone(callerEvidence);
  delete evidence.offline_protocol_validation;
  const contractSHA256 = canonicalSHA256(contract);
  const manifestSHA256 = aggregateSHA256('operation-manifest', manifest);
  const bundleByFile = new Map(bundles.map((entry) => [entry.file, entry]));
  const freshFirstPartyRows = [];
  const firstPartyExecutionFailures = [];
  if (typeof firstPartyValidator !== 'function') {
    firstPartyExecutionFailures.push(failure(
      'first_party_execution',
      'Finalization requires an active authenticated first-party validator',
    ));
  } else {
    for (const [index, manifestRow] of (manifest?.slots ?? []).entries()) {
      const slot = contract?.operation_slots?.[index];
      const bundle = bundleByFile.get(manifestRow?.bundle_file);
      if (!slot || !bundle) continue;
      try {
        const verdict = await firstPartyValidator({ contract, slot, manifestRow, bundle });
        freshFirstPartyRows.push({
          slot_id: slot.slot_id,
          bundle_file: manifestRow.bundle_file,
          file_sha256: bundle.sha256,
          verdict,
        });
      } catch (error) {
        firstPartyExecutionFailures.push(failure(
          'first_party_execution',
          `First-party validation failed: ${error.message}`,
          slot.slot_id,
        ));
      }
    }
  }
  const offlineResult = runOfflineValidatorV3({
    catalog,
    catalogSHA256: catalogFileSHA256,
    contract,
    manifest,
    bundles,
  });
  const structuralFailures = [
    ...validateEvidence(
      catalog,
      catalogFileSHA256,
      contract,
      contractSHA256,
      manifest,
      manifestSHA256,
      evidence,
      offlineResult,
      freshFirstPartyRows,
    ),
    ...firstPartyExecutionFailures,
    ...offlineResult.failures,
  ];
  const structurallyValid = structuralFailures.length === 0;
  const authorityGranted = certificationAuthority === LIVE_CERTIFICATION_AUTHORITY;
  const failures = [
    ...structuralFailures,
    ...(authorityGranted ? [] : [failure(
      'live_execution_required',
      'Only the production live path may mint a certification success claim',
    )]),
  ];
  const verdictRows = freshFirstPartyRows;
  const verdictBySlot = new Map(verdictRows.map((row) => [row?.slot_id, row]));
  const offlineBySlot = new Map(offlineResult.receipts.map((row) => [row.slot_id, row]));
  const slotVerdicts = (manifest?.slots ?? []).map((row, index) => {
    const slot = contract?.operation_slots?.[index];
    const live = verdictBySlot.get(row.slot_id);
    const offline = offlineBySlot.get(row.slot_id);
    const livePassed = Boolean(slot)
      && exactKeys(live, ['slot_id', 'bundle_file', 'file_sha256', 'verdict'])
      && live.slot_id === row.slot_id
      && live.bundle_file === row.bundle_file
      && live.file_sha256 === row.bundle_sha256
      && validFirstPartyVerdict(live.verdict, slot, row, contract);
    return {
      slot_id: row.slot_id,
      operation_id: row.operation_id,
      manifest_slot_sha256: aggregateSHA256('manifest-slot', row),
      request_id: row.request_id,
      session_id: row.session_id,
      session_sequence: row.session_sequence,
      bundle_sha256: row.bundle_sha256,
      first_party_verdict_sha256: live ? aggregateSHA256('first-party-verdict', live) : null,
      offline_receipt_sha256: offline ? aggregateSHA256('offline-receipt', offline) : null,
      passed: Boolean(livePassed && offline),
    };
  });
  const controlledTargets = (contract?.controlled_targets ?? []).map((entry) => ({
    id: entry.id,
    controller_id: entry.controller_id,
    controller_sha256: aggregateSHA256('controller', entry.controller),
    target_sha256: aggregateSHA256('controlled-target', entry.target),
  }));
  const runBindingSHA256 = certificationRunBindingSHA256({
    catalogSHA256: catalogFileSHA256,
    listenerInstanceID: contract?.listener?.instance_id ?? '',
    executionNonce: contract?.execution_nonce ?? '',
    currentBuildSource: contract?.current_build_source ?? null,
    monitorBinding: contract?.monitor_binding ?? null,
    controllerBuild: contract?.controller_build ?? null,
    operationSlots: contract?.operation_slots ?? [],
  });
  const summaryCore = {
    version: 2,
    certification_kind: LIVE_CERTIFICATION_KIND,
    claim_scope: LIVE_CLAIM_SCOPE,
    authority: 'display-only-rerun-finalize-for-authoritative-result',
    structural_validation_passed: structurallyValid,
    certification_run_id: contract?.certification_run_id ?? null,
    run_binding_sha256: runBindingSHA256,
    digest_spec_sha256: BUILTIN_DIGEST_SPEC_SHA256,
    catalog_file_sha256: catalogFileSHA256,
    contract_sha256: contractSHA256,
    operation_manifest_sha256: manifestSHA256,
    sanitized_raw_evidence_sha256: aggregateSHA256('raw-evidence', evidence),
    monitor_evidence_sha256: aggregateSHA256('monitor-evidence', evidence.monitor_evidence),
    monitor_history_commitment_sha256: evidence.monitor_evidence.history_commitment_sha256,
    monitor_baseline_commitment_sha256: evidence.monitor_evidence.baseline_commitment_sha256,
    foreground_postcondition_sha256: aggregateSHA256(
      'foreground-postcondition',
      evidence.foreground_postcondition,
    ),
    foreground_task_postcondition_passed: !structuralFailures.some((entry) => (
      entry.rule.startsWith('foreground_postcondition')
    )),
    raw_bundle_inventory_sha256: aggregateSHA256('raw-bundle-inventory', bundles.map((entry) => ({
      file: entry.file,
      sha256: entry.sha256,
    })).sort((left, right) => left.file.localeCompare(right.file))),
    first_party_verdict_set_sha256: aggregateSHA256('first-party-verdict-set', verdictRows),
    first_party_verdicts: verdictRows,
    offline_protocol_validation_sha256: aggregateSHA256(
      'offline-protocol-validation',
      offlineResult,
    ),
    target_count: controlledTargets.length,
    slot_count: slotVerdicts.length,
    controlled_targets: controlledTargets,
    slot_verdicts: slotVerdicts,
    offline_protocol_validation: offlineResult,
    failures,
  };
  const summary = {
    ...summaryCore,
    summary_core_sha256: aggregateSHA256('summary-core', summaryCore),
  };
  Object.defineProperty(summary, LIVE_CERTIFICATION_RESULT, {
    value: authorityGranted && structurallyValid,
    enumerable: false,
  });
  return summary;
}

export async function validateMultiTargetCertificationStructure(input) {
  return buildMultiTargetCertificationSummary(input);
}

async function finalizeLiveMultiTargetCertification(input) {
  return buildMultiTargetCertificationSummary({
    ...input,
    certificationAuthority: LIVE_CERTIFICATION_AUTHORITY,
  });
}

const SUMMARY_KEYS = [
  'version', 'certification_kind', 'claim_scope', 'authority',
  'structural_validation_passed', 'certification_run_id', 'digest_spec_sha256',
  'run_binding_sha256',
  'catalog_file_sha256', 'contract_sha256', 'operation_manifest_sha256',
  'sanitized_raw_evidence_sha256', 'monitor_evidence_sha256',
  'monitor_history_commitment_sha256',
  'monitor_baseline_commitment_sha256',
  'foreground_postcondition_sha256', 'foreground_task_postcondition_passed',
  'raw_bundle_inventory_sha256',
  'first_party_verdict_set_sha256', 'first_party_verdicts',
  'offline_protocol_validation_sha256',
  'target_count', 'slot_count', 'controlled_targets', 'slot_verdicts',
  'offline_protocol_validation', 'failures', 'summary_core_sha256',
];

const SUMMARY_DIGEST_KEYS = [
  'digest_spec_sha256', 'run_binding_sha256', 'catalog_file_sha256',
  'contract_sha256', 'operation_manifest_sha256', 'sanitized_raw_evidence_sha256',
  'monitor_evidence_sha256', 'monitor_history_commitment_sha256',
  'monitor_baseline_commitment_sha256', 'foreground_postcondition_sha256',
  'raw_bundle_inventory_sha256', 'first_party_verdict_set_sha256',
  'offline_protocol_validation_sha256', 'summary_core_sha256',
];

const SUMMARY_FIRST_PARTY_VERDICT_KEYS = [
  'valid', 'validator_id', 'trust_source', 'minimum_protocol_version',
  'host_protocol_version', 'request_id', 'session_id', 'session_sequence',
  'predecessor_session_id', 'operation', 'listener_instance_id',
  'listener_public_key_sha256', 'host', 'client_instance_id', 'host_source_commit',
  'client', 'request_sha256', 'response_sha256', 'bundle_sha256',
  'terminal_receipt_attested', 'target_attested', 'outcome_attested', 'retention_basis',
];

const SUMMARY_OFFLINE_RECEIPT_KEYS = [
  'slot_id', 'operation_id', 'request_id', 'session_id', 'session_sequence',
  'operation', 'controller_id', 'target_id', 'target', 'interval', 'source',
  'expected_outcome', 'request_sha256', 'response_sha256', 'file', 'file_sha256',
];

export function validateSuccessfulCertificationSummary(summary, label = 'certification summary') {
  if (!exactKeys(summary, SUMMARY_KEYS)) {
    throw new TypeError(`${label} is not one closed version-2 object`);
  }
  if (summary.version !== 2
      || summary.certification_kind !== LIVE_CERTIFICATION_KIND
      || summary.claim_scope !== LIVE_CLAIM_SCOPE
      || summary.authority !== 'display-only-rerun-finalize-for-authoritative-result'
      || summary.structural_validation_passed !== true
      || summary.foreground_task_postcondition_passed !== true
      || summary.catalog_file_sha256 !== BUILTIN_CATALOG_SHA256
      || summary.digest_spec_sha256 !== BUILTIN_DIGEST_SPEC_SHA256
      || !/^multi-target-[0-9a-f-]{36}$/.test(summary.certification_run_id ?? '')
      || SUMMARY_DIGEST_KEYS.some((key) => !HEX64.test(summary[key] ?? ''))
      || !Array.isArray(summary.failures) || summary.failures.length !== 0) {
    throw new TypeError(`${label} is not one successful live certification core`);
  }
  if (!Number.isSafeInteger(summary.target_count) || summary.target_count < 2
      || !Number.isSafeInteger(summary.slot_count) || summary.slot_count < 1
      || !Array.isArray(summary.controlled_targets)
      || summary.controlled_targets.length !== summary.target_count
      || !Array.isArray(summary.slot_verdicts)
      || summary.slot_verdicts.length !== summary.slot_count
      || !Array.isArray(summary.first_party_verdicts)
      || summary.first_party_verdicts.length !== summary.slot_count) {
    throw new TypeError(`${label} target or slot cardinality is not a closed successful run`);
  }
  const controlledTargetIDs = [];
  for (const row of summary.controlled_targets) {
    if (!exactKeys(row, ['id', 'controller_id', 'controller_sha256', 'target_sha256'])
        || typeof row.id !== 'string' || row.id.length === 0
        || typeof row.controller_id !== 'string' || row.controller_id.length === 0
        || !HEX64.test(row.controller_sha256 ?? '') || !HEX64.test(row.target_sha256 ?? '')) {
      throw new TypeError(`${label} controlled target rows are not closed`);
    }
    controlledTargetIDs.push(row.id);
  }
  if (new Set(controlledTargetIDs).size !== controlledTargetIDs.length) {
    throw new TypeError(`${label} controlled target IDs are not unique`);
  }
  const slotIDs = [];
  for (const row of summary.slot_verdicts) {
    if (!exactKeys(row, [
      'slot_id', 'operation_id', 'manifest_slot_sha256', 'request_id', 'session_id',
      'session_sequence', 'bundle_sha256', 'first_party_verdict_sha256',
      'offline_receipt_sha256', 'passed',
    ]) || typeof row.slot_id !== 'string' || row.slot_id.length === 0
        || typeof row.operation_id !== 'string' || row.operation_id.length === 0
        || typeof row.request_id !== 'string' || row.request_id.length === 0
        || typeof row.session_id !== 'string' || row.session_id.length === 0
        || typeof row.session_sequence !== 'string' || row.session_sequence.length === 0
        || !HEX64.test(row.manifest_slot_sha256 ?? '')
        || !HEX64.test(row.bundle_sha256 ?? '')
        || !HEX64.test(row.first_party_verdict_sha256 ?? '')
        || !HEX64.test(row.offline_receipt_sha256 ?? '')
        || row.passed !== true) {
      throw new TypeError(`${label} slot verdict rows are not closed and successful`);
    }
    slotIDs.push(row.slot_id);
  }
  if (new Set(slotIDs).size !== slotIDs.length) {
    throw new TypeError(`${label} slot verdict IDs are not unique`);
  }
  const firstPartyIDs = [];
  for (const row of summary.first_party_verdicts) {
    if (!exactKeys(row, ['slot_id', 'bundle_file', 'file_sha256', 'verdict'])
        || typeof row.slot_id !== 'string' || row.slot_id.length === 0
        || typeof row.bundle_file !== 'string' || row.bundle_file.length === 0
        || !HEX64.test(row.file_sha256 ?? '')
        || !exactKeys(row.verdict, SUMMARY_FIRST_PARTY_VERDICT_KEYS)
        || row.verdict.valid !== true
        || row.verdict.validator_id !== 'peekaboo-bridge-receipt-validate-v1'
        || row.verdict.trust_source !== 'authenticated_live_listener'
        || row.verdict.minimum_protocol_version !== '1.29'
        || row.verdict.host_protocol_version !== '1.31'
        || row.verdict.terminal_receipt_attested !== true
        || row.verdict.target_attested !== true
        || typeof row.verdict.outcome_attested !== 'boolean'
        || row.verdict.retention_basis !== 'exported_bundle'
        || normalizedUUID(row.verdict.request_id, UUID_V8) === null
        || normalizedUUID(row.verdict.session_id, UUID_V4) === null
        || normalizedDecimal(row.verdict.session_sequence, false) === null
        || !(row.verdict.predecessor_session_id === null
          || normalizedUUID(row.verdict.predecessor_session_id, UUID_V4) !== null)
        || typeof row.verdict.operation !== 'string' || row.verdict.operation.length === 0
        || normalizedUUID(row.verdict.listener_instance_id, UUID_V4) === null
        || normalizedUUID(row.verdict.client_instance_id, UUID_V4) === null
        || !validProcess(row.verdict.host) || !validProcess(row.verdict.client)
        || !HEX40.test(row.verdict.host_source_commit ?? '')
        || !HEX64.test(row.verdict.listener_public_key_sha256 ?? '')
        || !HEX64.test(row.verdict.request_sha256 ?? '')
        || !HEX64.test(row.verdict.response_sha256 ?? '')
        || row.verdict.bundle_sha256 !== row.file_sha256) {
      throw new TypeError(`${label} first-party verdict rows are not closed`);
    }
    firstPartyIDs.push(row.slot_id);
  }
  const offline = summary.offline_protocol_validation;
  if (!exactKeys(offline, [
    'version', 'success', 'contract_sha256', 'operation_manifest_sha256',
    'receipts', 'failures',
  ]) || offline.version !== 3 || offline.success !== true
      || offline.contract_sha256 !== summary.contract_sha256
      || offline.operation_manifest_sha256 !== summary.operation_manifest_sha256
      || !Array.isArray(offline.receipts) || offline.receipts.length !== summary.slot_count
      || !Array.isArray(offline.failures) || offline.failures.length !== 0) {
    throw new TypeError(`${label} offline protocol result is not closed and successful`);
  }
  const offlineIDs = offline.receipts.map((row) => row?.slot_id);
  if (offline.receipts.some((row) => !exactKeys(row, SUMMARY_OFFLINE_RECEIPT_KEYS)
      || typeof row.slot_id !== 'string' || row.slot_id.length === 0
      || typeof row.operation_id !== 'string' || row.operation_id.length === 0
      || typeof row.request_id !== 'string' || row.request_id.length === 0
      || typeof row.session_id !== 'string' || row.session_id.length === 0
      || typeof row.session_sequence !== 'string' || row.session_sequence.length === 0
      || typeof row.operation !== 'string' || row.operation.length === 0
      || typeof row.controller_id !== 'string' || row.controller_id.length === 0
      || typeof row.target_id !== 'string' || row.target_id.length === 0
      || !validTarget(row.target) || !validInterval(row.interval)
      || !exactKeys(row.source, [
        'protocol_source_commit', 'host_source_commit', 'listener_instance_id', 'host',
      ])
      || !HEX40.test(row.source.protocol_source_commit ?? '')
      || !HEX40.test(row.source.host_source_commit ?? '')
      || normalizedUUID(row.source.listener_instance_id, UUID_V4) === null
      || !validProcess(row.source.host)
      || !(row.expected_outcome === null || validExpectedOutcome(row.expected_outcome))
      || !HEX64.test(row.request_sha256 ?? '') || !HEX64.test(row.response_sha256 ?? '')
      || typeof row.file !== 'string' || row.file.length === 0
      || !HEX64.test(row.file_sha256 ?? ''))) {
    throw new TypeError(`${label} offline receipt rows are not closed`);
  }
  const expectedIDs = [...slotIDs].sort();
  if (!sameJSON([...firstPartyIDs].sort(), expectedIDs)
      || !sameJSON([...offlineIDs].sort(), expectedIDs)) {
    throw new TypeError(`${label} successful slot evidence is not bijective`);
  }
  const firstPartyBySlot = new Map(summary.first_party_verdicts.map((row) => [row.slot_id, row]));
  const offlineBySlot = new Map(offline.receipts.map((row) => [row.slot_id, row]));
  const controlledByID = new Map(summary.controlled_targets.map((row) => [row.id, row]));
  const coveredTargetIDs = new Set();
  const physicalTargetKeys = new Set();
  for (const row of summary.slot_verdicts) {
    const firstParty = firstPartyBySlot.get(row.slot_id);
    const offlineReceipt = offlineBySlot.get(row.slot_id);
    const controlled = controlledByID.get(offlineReceipt.target_id);
    if (!controlled || controlled.controller_id !== offlineReceipt.controller_id
        || controlled.controller_sha256
          !== aggregateSHA256('controller', firstParty.verdict.client)
        || controlled.target_sha256
          !== aggregateSHA256('controlled-target', offlineReceipt.target)
        || offlineReceipt.source.listener_instance_id !== firstParty.verdict.listener_instance_id
        || offlineReceipt.source.host_source_commit !== firstParty.verdict.host_source_commit
        || !sameJSON(offlineReceipt.source.host, firstParty.verdict.host)
        || row.operation_id !== offlineReceipt.operation_id
        || row.request_id !== firstParty.verdict.request_id
        || row.request_id !== offlineReceipt.request_id
        || row.session_id !== firstParty.verdict.session_id
        || row.session_id !== offlineReceipt.session_id
        || row.session_sequence !== firstParty.verdict.session_sequence
        || row.session_sequence !== offlineReceipt.session_sequence
        || firstParty.verdict.operation !== offlineReceipt.operation
        || row.bundle_sha256 !== firstParty.file_sha256
        || row.bundle_sha256 !== firstParty.verdict.bundle_sha256
        || row.bundle_sha256 !== offlineReceipt.file_sha256
        || firstParty.bundle_file !== offlineReceipt.file
        || firstParty.verdict.request_sha256 !== offlineReceipt.request_sha256
        || firstParty.verdict.response_sha256 !== offlineReceipt.response_sha256
        || row.first_party_verdict_sha256
          !== aggregateSHA256('first-party-verdict', firstParty)
        || row.offline_receipt_sha256
          !== aggregateSHA256('offline-receipt', offlineReceipt)) {
      throw new TypeError(`${label} slot evidence commitments are invalid`);
    }
    coveredTargetIDs.add(offlineReceipt.target_id);
    physicalTargetKeys.add([
      offlineReceipt.target.pid,
      offlineReceipt.target.start_identity,
      offlineReceipt.target.window_id,
    ].join('\0'));
  }
  if (!sameJSON([...coveredTargetIDs].sort(), [...controlledByID.keys()].sort())) {
    throw new TypeError(`${label} slots do not cover every controlled target`);
  }
  if (physicalTargetKeys.size !== controlledByID.size) {
    throw new TypeError(`${label} controlled targets are not physically distinct`);
  }
  if (summary.first_party_verdict_set_sha256
        !== aggregateSHA256('first-party-verdict-set', summary.first_party_verdicts)
      || summary.offline_protocol_validation_sha256
        !== aggregateSHA256('offline-protocol-validation', offline)) {
    throw new TypeError(`${label} nested evidence commitments are invalid`);
  }
  const summaryCore = structuredClone(summary);
  delete summaryCore.summary_core_sha256;
  if (summary.summary_core_sha256 !== aggregateSHA256('summary-core', summaryCore)) {
    throw new TypeError(`${label} core digest is invalid`);
  }
  return summary;
}

function digestJSONValue(kindID, value) {
  return computeDigestClaim({
    kindID,
    inputBytes: Buffer.from(JSON.stringify(value), 'utf8'),
  }).digest;
}

function exactStringSet(actual, expected) {
  return Array.isArray(actual)
    && actual.every((value) => typeof value === 'string')
    && new Set(actual).size === actual.length
    && sameJSON([...actual].sort(), [...expected].sort());
}

export function verifyDigestClaims({ catalogBytes, artifacts, summary }) {
  const checks = [];
  const failures = [];
  const addCheck = (kind, subject, claimed, recomputed) => {
    const match = typeof claimed === 'string' && HEX64.test(claimed) && claimed === recomputed;
    checks.push({ kind, subject, claimed: claimed ?? null, recomputed, match });
    if (!match) failures.push({ kind, subject, message: 'Digest claim does not match its documented projection' });
  };
  if (!exactKeys(summary, SUMMARY_KEYS) || summary.version !== 2
      || summary.certification_kind !== LIVE_CERTIFICATION_KIND
      || summary.claim_scope !== LIVE_CLAIM_SCOPE
      || summary.authority !== 'display-only-rerun-finalize-for-authoritative-result'
      || typeof summary.structural_validation_passed !== 'boolean'
      || typeof summary.foreground_task_postcondition_passed !== 'boolean'
      || !Array.isArray(summary.controlled_targets)
      || !Array.isArray(summary.slot_verdicts)
      || !Array.isArray(summary.first_party_verdicts)
      || !isPlainObject(summary.offline_protocol_validation)) {
    return {
      version: 1,
      success: false,
      digest_spec_sha256: BUILTIN_DIGEST_SPEC_SHA256,
      checks,
      failures: [{ kind: 'summary', subject: 'root', message: 'Summary is not one closed version-2 object' }],
    };
  }
  addCheck(
    'digest-spec-file',
    'built-in',
    summary.digest_spec_sha256,
    computeDigestClaim({ kindID: 'digest-spec-file', inputBytes: loadDigestSpec().bytes }).digest,
  );
  const catalogDigest = computeDigestClaim({ kindID: 'catalog-file', inputBytes: catalogBytes }).digest;
  addCheck(
    'catalog-file',
    'built-in',
    summary.catalog_file_sha256,
    catalogDigest,
  );
  addCheck('contract', 'contract.json', summary.contract_sha256, digestJSONValue('contract', artifacts.contract));
  const runBindingInput = {
    catalogSHA256: catalogDigest,
    listenerInstanceID: artifacts.contract?.listener?.instance_id ?? '',
    executionNonce: artifacts.contract?.execution_nonce ?? '',
    currentBuildSource: artifacts.contract?.current_build_source ?? null,
    monitorBinding: artifacts.contract?.monitor_binding ?? null,
    controllerBuild: artifacts.contract?.controller_build ?? null,
    operationSlots: artifacts.contract?.operation_slots ?? [],
  };
  addCheck(
    'run-binding',
    'contract.operation_slots',
    summary.run_binding_sha256,
    digestJSONValue('run-binding', artifacts.contract),
  );
  if (summary.certification_run_id !== deriveCertificationRunID(runBindingInput)) {
    failures.push({ kind: 'run-binding', subject: 'certification_run_id', message: 'Run ID differs from run binding' });
  }
  addCheck(
    'operation-manifest',
    'operation-manifest.json',
    summary.operation_manifest_sha256,
    digestJSONValue('operation-manifest', artifacts.manifest),
  );
  addCheck(
    'raw-evidence',
    'raw-evidence.json',
    summary.sanitized_raw_evidence_sha256,
    digestJSONValue('raw-evidence', artifacts.evidence),
  );
  addCheck(
    'monitor-evidence',
    'raw-evidence.json.monitor_evidence',
    summary.monitor_evidence_sha256,
    digestJSONValue('monitor-evidence', artifacts.evidence.monitor_evidence),
  );
  addCheck(
    'monitor-baseline',
    'raw-evidence.json.monitor_evidence',
    summary.monitor_baseline_commitment_sha256,
    digestJSONValue('monitor-baseline', artifacts.evidence.monitor_evidence),
  );
  addCheck(
    'monitor-history',
    'raw-evidence.json.monitor_evidence',
    summary.monitor_history_commitment_sha256,
    digestJSONValue('monitor-history', artifacts.evidence.monitor_evidence),
  );
  addCheck(
    'foreground-postcondition',
    'raw-evidence.json.foreground_postcondition',
    summary.foreground_postcondition_sha256,
    digestJSONValue('foreground-postcondition', artifacts.evidence.foreground_postcondition),
  );
  const inventory = artifacts.bundles.map((entry) => ({
    file: entry.file,
    sha256: entry.sha256,
  })).sort((left, right) => left.file.localeCompare(right.file));
  addCheck(
    'raw-bundle-inventory',
    'bundles',
    summary.raw_bundle_inventory_sha256,
    digestJSONValue('raw-bundle-inventory', inventory),
  );
  addCheck(
    'first-party-verdict-set',
    'summary.first_party_verdicts',
    summary.first_party_verdict_set_sha256,
    digestJSONValue('first-party-verdict-set', summary.first_party_verdicts),
  );
  addCheck(
    'offline-protocol-validation',
    'summary.offline_protocol_validation',
    summary.offline_protocol_validation_sha256,
    digestJSONValue('offline-protocol-validation', summary.offline_protocol_validation),
  );

  const contractTargets = new Map((artifacts.contract?.controlled_targets ?? []).map((entry) => [entry.id, entry]));
  const contractTargetIDs = (artifacts.contract?.controlled_targets ?? []).map((entry) => entry?.id);
  const summaryTargetIDs = summary.controlled_targets.map((entry) => entry?.id);
  if (!exactStringSet(contractTargetIDs, contractTargetIDs)
      || !exactStringSet(summaryTargetIDs, contractTargetIDs)
      || summary.target_count !== summary.controlled_targets.length
      || summary.controlled_targets.length !== contractTargets.size) {
    failures.push({ kind: 'controlled-target', subject: 'set', message: 'Controlled target cardinality differs' });
  }
  for (const row of summary.controlled_targets) {
    const contractTarget = contractTargets.get(row?.id);
    if (!exactKeys(row, [
      'id', 'controller_id', 'controller_sha256', 'target_sha256',
    ]) || !contractTarget || row.controller_id !== contractTarget.controller_id) {
      failures.push({ kind: 'controlled-target', subject: row?.id ?? null, message: 'Controlled target row is invalid' });
      continue;
    }
    addCheck(
      'controller',
      row.id,
      row.controller_sha256,
      digestJSONValue('controller', contractTarget.controller),
    );
    addCheck(
      'controlled-target',
      row.id,
      row.target_sha256,
      digestJSONValue('controlled-target', contractTarget.target),
    );
  }

  const manifestSlots = new Map((artifacts.manifest?.slots ?? []).map((entry) => [entry.slot_id, entry]));
  const firstPartyRows = new Map(summary.first_party_verdicts.map((entry) => [entry?.slot_id, entry]));
  const offlineRows = new Map((summary.offline_protocol_validation?.receipts ?? [])
    .map((entry) => [entry?.slot_id, entry]));
  const manifestSlotIDs = (artifacts.manifest?.slots ?? []).map((entry) => entry?.slot_id);
  const summarySlotIDs = summary.slot_verdicts.map((entry) => entry?.slot_id);
  const firstPartySlotIDs = summary.first_party_verdicts.map((entry) => entry?.slot_id);
  const offlineSlotIDs = (summary.offline_protocol_validation?.receipts ?? [])
    .map((entry) => entry?.slot_id);
  if (!exactStringSet(manifestSlotIDs, manifestSlotIDs)
      || !exactStringSet(summarySlotIDs, manifestSlotIDs)
      || !exactStringSet(firstPartySlotIDs, manifestSlotIDs)
      || !exactStringSet(offlineSlotIDs, manifestSlotIDs)
      || summary.slot_count !== summary.slot_verdicts.length
      || summary.slot_verdicts.length !== manifestSlots.size) {
    failures.push({ kind: 'manifest-slot', subject: 'set', message: 'Slot cardinality differs' });
  }
  for (const row of summary.slot_verdicts) {
    const manifestSlot = manifestSlots.get(row?.slot_id);
    const firstParty = firstPartyRows.get(row?.slot_id);
    const offline = offlineRows.get(row?.slot_id);
    const rawBundle = artifacts.bundles.find((entry) => entry.file === manifestSlot?.bundle_file);
    if (!exactKeys(row, [
      'slot_id', 'operation_id', 'manifest_slot_sha256', 'request_id', 'session_id',
      'session_sequence', 'bundle_sha256', 'first_party_verdict_sha256',
      'offline_receipt_sha256', 'passed',
    ]) || !manifestSlot || !firstParty || !offline || !rawBundle) {
      failures.push({ kind: 'manifest-slot', subject: row?.slot_id ?? null, message: 'Slot digest row is invalid' });
      continue;
    }
    addCheck(
      'bundle-file',
      row.slot_id,
      row.bundle_sha256,
      rawBundle.sha256,
    );
    if (manifestSlot.bundle_sha256 !== row.bundle_sha256) {
      failures.push({ kind: 'bundle-file', subject: row.slot_id, message: 'Manifest and summary bundle claims differ' });
    }
    if (row.operation_id !== manifestSlot.operation_id
        || row.request_id !== manifestSlot.request_id
        || row.session_id !== manifestSlot.session_id
        || row.session_sequence !== manifestSlot.session_sequence) {
      failures.push({
        kind: 'manifest-slot',
        subject: row.slot_id,
        message: 'Manifest and summary slot metadata differ',
      });
    }
    addCheck(
      'manifest-slot',
      row.slot_id,
      row.manifest_slot_sha256,
      digestJSONValue('manifest-slot', manifestSlot),
    );
    addCheck(
      'first-party-verdict',
      row.slot_id,
      row.first_party_verdict_sha256,
      digestJSONValue('first-party-verdict', firstParty),
    );
    addCheck(
      'offline-receipt',
      row.slot_id,
      row.offline_receipt_sha256,
      digestJSONValue('offline-receipt', offline),
    );
  }
  addCheck(
    'summary-core',
    'summary',
    summary.summary_core_sha256,
    digestJSONValue('summary-core', summary),
  );
  return {
    version: 1,
    success: failures.length === 0,
    digest_spec_sha256: BUILTIN_DIGEST_SPEC_SHA256,
    checks,
    failures,
  };
}

function openPrivateDirectory(directory, label) {
  const flags = fs.constants.O_RDONLY
    | (fs.constants.O_CLOEXEC ?? 0)
    | (fs.constants.O_NOFOLLOW ?? 0)
    | (fs.constants.O_DIRECTORY ?? 0);
  const descriptor = fs.openSync(directory, flags);
  try {
    const info = fs.fstatSync(descriptor);
    const pathInfo = fs.lstatSync(directory);
    if (!info.isDirectory() || pathInfo.isSymbolicLink()
        || info.dev !== pathInfo.dev || info.ino !== pathInfo.ino
        || (info.mode & 0o077) !== 0
        || (typeof process.geteuid === 'function' && info.uid !== process.geteuid())) {
      throw new TypeError(`${label} must be an owner-private real directory`);
    }
    return {
      descriptor,
      directory,
      label,
      info,
      names: fs.readdirSync(directory).sort(),
    };
  } catch (error) {
    fs.closeSync(descriptor);
    throw error;
  }
}

function closeAndValidateDirectory(snapshot, allowContentChange = false) {
  try {
    const descriptorInfo = fs.fstatSync(snapshot.descriptor);
    const pathInfo = fs.lstatSync(snapshot.directory);
    const names = fs.readdirSync(snapshot.directory).sort();
    if (descriptorInfo.dev !== snapshot.info.dev || descriptorInfo.ino !== snapshot.info.ino
        || pathInfo.dev !== snapshot.info.dev || pathInfo.ino !== snapshot.info.ino
        || (!allowContentChange && (
          descriptorInfo.mtimeMs !== snapshot.info.mtimeMs
          || descriptorInfo.ctimeMs !== snapshot.info.ctimeMs
          || !sameJSON(names, snapshot.names)
        ))) {
      throw new TypeError(`${snapshot.label} changed while certification artifacts were read`);
    }
  } finally {
    fs.closeSync(snapshot.descriptor);
  }
}

function readStablePrivateFile(filePath, label) {
  const flags = fs.constants.O_RDONLY
    | (fs.constants.O_CLOEXEC ?? 0)
    | (fs.constants.O_NOFOLLOW ?? 0);
  const descriptor = fs.openSync(filePath, flags);
  try {
    const before = fs.fstatSync(descriptor);
    if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1
        || (before.mode & 0o177) !== 0
        || (typeof process.geteuid === 'function' && before.uid !== process.geteuid())
        || before.size <= 0 || before.size > 256 * 1024 * 1024) {
      throw new TypeError(`${label} must be an owner-private, non-hardlinked regular file`);
    }
    const bytes = fs.readFileSync(descriptor);
    const after = fs.fstatSync(descriptor);
    const pathAfter = fs.lstatSync(filePath);
    if (before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size
        || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs
        || after.dev !== pathAfter.dev || after.ino !== pathAfter.ino
        || after.nlink !== 1 || bytes.length !== before.size) {
      throw new TypeError(`${label} changed while it was read`);
    }
    return bytes;
  } finally {
    fs.closeSync(descriptor);
  }
}

function parseJSON(bytes, label) {
  try {
    return JSON.parse(bytes.toString('utf8'));
  } catch (error) {
    throw new TypeError(`${label} is not valid JSON: ${error.message}`);
  }
}

export function readCertificationArtifacts(directory) {
  const artifactRoot = path.resolve(directory);
  const rootSnapshot = openPrivateDirectory(artifactRoot, 'artifact root');
  let bundleSnapshot = null;
  try {
    const expectedRootNames = new Set([
      'bundles', 'contract.json', 'operation-manifest.json', 'raw-evidence.json',
    ]);
    const rootNames = rootSnapshot.names;
    if (rootNames.some((name) => !expectedRootNames.has(name))
        || rootNames.length !== expectedRootNames.size) {
      throw new TypeError('artifact root must contain only contract, manifest, raw evidence, and bundles');
    }
    const readDocument = (name) => parseJSON(
      readStablePrivateFile(path.join(artifactRoot, name), name),
      name,
    );
    const bundleDirectory = path.join(artifactRoot, 'bundles');
    bundleSnapshot = openPrivateDirectory(bundleDirectory, 'bundle directory');
    const bundles = bundleSnapshot.names.map((name) => {
      if (!/^[a-z0-9][a-z0-9._-]*\.json$/.test(name) || name.includes('..')) {
        throw new TypeError(`bundle filename is not canonical: ${name}`);
      }
      const absolute = path.join(bundleDirectory, name);
      const bytes = readStablePrivateFile(absolute, `bundle ${name}`);
      return {
        file: name,
        path: absolute,
        bytes,
        sha256: sha256(bytes),
        document: parseJSON(bytes, `bundle ${name}`),
      };
    });
    const result = {
      contract: readDocument('contract.json'),
      manifest: readDocument('operation-manifest.json'),
      evidence: readDocument('raw-evidence.json'),
      bundles,
    };
    closeAndValidateDirectory(bundleSnapshot);
    closeAndValidateDirectory(rootSnapshot);
    return result;
  } catch (error) {
    try {
      if (bundleSnapshot) fs.closeSync(bundleSnapshot.descriptor);
    } catch {}
    try {
      fs.closeSync(rootSnapshot.descriptor);
    } catch {}
    throw error;
  }
}

function readRawBundleDirectory(directory) {
  const bundleRoot = path.resolve(directory);
  const snapshot = openPrivateDirectory(bundleRoot, 'raw bundle directory');
  try {
    const bundles = snapshot.names.map((name) => {
      if (!/^[a-z0-9][a-z0-9._-]*\.json$/.test(name) || name.includes('..')) {
        throw new TypeError(`bundle filename is not canonical: ${name}`);
      }
      const absolute = path.join(bundleRoot, name);
      const bytes = readStablePrivateFile(absolute, `bundle ${name}`);
      return {
        file: name,
        path: absolute,
        bytes,
        sha256: sha256(bytes),
        document: parseJSON(bytes, `bundle ${name}`),
      };
    });
    closeAndValidateDirectory(snapshot);
    return bundles;
  } catch (error) {
    try {
      fs.closeSync(snapshot.descriptor);
    } catch {}
    throw error;
  }
}

function readControllerReceiptDirectory(directory) {
  const receiptRoot = path.resolve(directory);
  const snapshot = openPrivateDirectory(receiptRoot, 'controller receipt directory');
  try {
    if (snapshot.names.length !== 2 || snapshot.names.some((name) => (
      !/^controller-[a-z0-9-]+-receipt\.json$/.test(name)
    ))) {
      throw new TypeError('controller receipt directory must contain exactly two canonical receipts');
    }
    const receipts = snapshot.names.sort().map((name) => {
      const bytes = readStablePrivateFile(path.join(receiptRoot, name), `controller receipt ${name}`);
      return parseJSON(bytes, `controller receipt ${name}`);
    });
    closeAndValidateDirectory(snapshot);
    return receipts;
  } catch (error) {
    try {
      fs.closeSync(snapshot.descriptor);
    } catch {}
    throw error;
  }
}

function normalizeControllerReceiptProcess(value, context) {
  if (!validProcess(value)) throw new TypeError(`${context} process identity is malformed`);
  return structuredClone(value);
}

function normalizeControllerReceiptTarget(value, context) {
  if (!validTarget(value)) throw new TypeError(`${context} exact-window target is malformed`);
  return structuredClone(value);
}

function controllerBundleName(value) {
  if (typeof value !== 'string' || !/^bundles\/[0-9a-f-]{36}\.json$/.test(value)) return null;
  return value.slice('bundles/'.length);
}

function validControllerHandshake(value) {
  const keys = [
    'socket_path', 'negotiated_version', 'host_kind', 'build',
    'listener_instance_id', 'host', 'session',
  ];
  const required = keys.filter((key) => key !== 'build');
  return onlyKeys(value, keys) && required.every((key) => key in value)
    && typeof value.socket_path === 'string' && path.isAbsolute(value.socket_path)
    && validProtocolVersion(value.negotiated_version, 1, 30)
    && typeof value.host_kind === 'string' && value.host_kind.length > 0
    && (value.build === null || typeof value.build === 'string')
    && normalizedUUID(value.listener_instance_id, UUID_V4) !== null
    && onlyKeys(value.host, [
      'process', 'bundle_identifier', 'bundle_short_version', 'bundle_version', 'source_commit',
    ])
    && ['process', 'source_commit'].every((key) => key in value.host)
    && validProcess(value.host.process)
    && (value.host.bundle_identifier === null || typeof value.host.bundle_identifier === 'string')
    && (value.host.bundle_short_version === null || typeof value.host.bundle_short_version === 'string')
    && (value.host.bundle_version === null || typeof value.host.bundle_version === 'string')
    && HEX40.test(value.host.source_commit ?? '')
    && exactKeys(value.session, [
      'id', 'client_instance_id', 'maximum_request_count', 'initial_remaining_claim_count',
    ])
    && normalizedUUID(value.session.id, UUID_V4) !== null
    && normalizedUUID(value.session.client_instance_id, UUID_V4) !== null
    && positiveInteger(value.session.maximum_request_count)
    && positiveInteger(value.session.initial_remaining_claim_count)
    && value.session.initial_remaining_claim_count >= 5;
}

function deriveListenerContract(bundle, sourceCommit) {
  const listener = bundle?.operationAttestation;
  if (!exactKeys(listener, [
    'schemaVersion', 'listenerInstanceID', 'publicKey', 'host', 'createdAtUnixMilliseconds',
    'receiptArchiveDirectory', 'signature',
  ]) || listener.schemaVersion !== 1 || !HEX40.test(sourceCommit ?? '')) {
    throw new TypeError('controller bundle listener attestation is malformed');
  }
  const publicKeyBytes = decodeBase64(listener.publicKey, 'listener public key');
  if (publicKeyBytes.length !== 32) throw new TypeError('listener public key must be 32 bytes');
  const contract = {
    instance_id: normalizedUUID(listener.listenerInstanceID, UUID_V4),
    public_key_base64: listener.publicKey,
    public_key_sha256: sha256(publicKeyBytes),
    host: normalizeWireProcess(listener.host, 'listener host'),
    source_commit: sourceCommit,
    created_at_milliseconds: listener.createdAtUnixMilliseconds,
    receipt_archive_directory: listener.receiptArchiveDirectory,
  };
  if (contract.instance_id === null || !milliseconds(contract.created_at_milliseconds)
      || typeof contract.receipt_archive_directory !== 'string'
      || !path.isAbsolute(contract.receipt_archive_directory)) {
    throw new TypeError('controller listener contract is incomplete');
  }
  return contract;
}

function controllerReceiptSlot(receipt, template) {
  const slot = receipt.slots.find((entry) => entry?.slot_id === template.slot_id);
  const slotKeys = [
    'slot_id', 'kind', 'operation', 'checkpoint', 'marker', 'request_id',
    'session_id', 'session_sequence', 'listener_instance_id', 'target', 'interval',
    'controller_interval', 'outcome', 'result', 'bundle',
  ];
  const requiredSlotKeys = slotKeys.filter((key) => !['checkpoint', 'outcome'].includes(key));
  if (!onlyKeys(slot, slotKeys) || requiredSlotKeys.some((key) => !(key in slot))
      || slot.kind !== template.kind || slot.operation !== template.operation
      || (slot.checkpoint ?? null) !== template.checkpoint
      || slot.marker !== `peekaboo-certification-run:${receipt.execution_nonce}:slot:${template.slot_id}`
      || slot.listener_instance_id !== receipt.handshake.listener_instance_id
      || slot.session_id !== receipt.handshake.session.id
      || normalizedUUID(slot.request_id, UUID_V8) === null
      || normalizedUUID(slot.session_id, UUID_V4) === null
      || normalizedDecimal(slot.session_sequence) === null
      || normalizedUUID(slot.listener_instance_id, UUID_V4) === null
      || !validTarget(slot.target)
      || !validInterval(slot.interval)
      || !validInterval(slot.controller_interval)
      || !((slot.outcome ?? null) === null || validExpectedOutcome(slot.outcome))
      || !onlyKeys(slot.result, [
        'status', 'total_characters', 'key_presses', 'observation_file',
        'observation_sha256', 'observed_bounds',
      ])
      || slot.result.status !== 'passed'
      || !exactKeys(slot.bundle, ['file', 'sha256', 'request_sha256', 'response_sha256'])
      || controllerBundleName(slot.bundle.file) === null
      || !HEX64.test(slot.bundle.sha256 ?? '')
      || !HEX64.test(slot.bundle.request_sha256 ?? '')
      || !HEX64.test(slot.bundle.response_sha256 ?? '')) {
    throw new TypeError(`controller receipt slot ${template.slot_id} is incomplete`);
  }
  return slot;
}

export function makeLiveCertificationContract({
  catalog,
  catalogSHA256,
  controllerReceipts,
  bundles,
  monitorEvidence,
  firstPartyValidator,
  socketEndpoint,
}) {
  const catalogFailures = validateCatalog(catalog);
  if (catalogFailures.length > 0) {
    throw new TypeError(`catalog is invalid: ${catalogFailures.map((entry) => entry.rule).join(', ')}`);
  }
  if (!Array.isArray(controllerReceipts) || controllerReceipts.length !== 2
      || !Array.isArray(bundles) || bundles.length !== catalog.slots.length
      || !isPlainObject(monitorEvidence)
      || !isPlainObject(firstPartyValidator)
      || !isPlainObject(socketEndpoint)) {
    throw new TypeError('live contract assembly requires two controllers and one closed signed corpus');
  }
  const receiptByController = new Map();
  const bundleByFile = new Map(bundles.map((entry) => [entry.file, entry]));
  if (bundleByFile.size !== bundles.length) throw new TypeError('raw bundle filenames must be unique');
  const executionNonce = monitorEvidence.execution_nonce;
  const monitorInstanceID = monitorEvidence.monitor_instance_id;
  for (const receipt of controllerReceipts) {
    if (!exactKeys(receipt, [
      'version', 'result', 'execution_nonce', 'monitor_instance_id', 'controller_id',
      'target_id', 'controller', 'build', 'handshake', 'target', 'interval', 'slots',
    ]) || receipt.version !== 1 || receipt.result !== 'passed'
        || receipt.execution_nonce !== executionNonce
        || receipt.monitor_instance_id !== monitorInstanceID
        || typeof receipt.controller_id !== 'string' || typeof receipt.target_id !== 'string'
        || receiptByController.has(receipt.controller_id)
        || !validControllerHandshake(receipt.handshake)
        || !validControllerBuild(receipt.build, catalog, null)
        || !validProcess(receipt.controller)
        || !validTarget(receipt.target)
        || !validInterval(receipt.interval)
        || !Array.isArray(receipt.slots) || receipt.slots.length !== 4) {
      throw new TypeError('controller receipt is not one closed four-slot passed run');
    }
    receiptByController.set(receipt.controller_id, receipt);
  }
  const firstTemplate = catalog.slots[0];
  const firstReceipt = receiptByController.get(firstTemplate.controller_id);
  const controllerBuild = structuredClone(firstReceipt.build);
  const currentBuildCommit = controllerBuild.source_commit;
  if ([...receiptByController.values()].some((receipt) => (
    !sameJSON(receipt.build, controllerBuild)
  ))) {
    throw new TypeError('controller receipts do not share one exact source-authenticated build');
  }
  const firstControllerSlot = controllerReceiptSlot(firstReceipt, firstTemplate);
  const firstBundleName = controllerBundleName(firstControllerSlot.bundle?.file);
  const firstBundle = bundleByFile.get(firstBundleName);
  if (!firstBundle) throw new TypeError('first controller bundle is missing');
  const listener = deriveListenerContract(
    firstBundle.document,
    firstReceipt.handshake?.host?.source_commit,
  );
  if (firstPartyValidator.source_commit !== currentBuildCommit
      || listener.source_commit !== currentBuildCommit) {
    throw new TypeError(
      'controller, validator, and listener host do not share one current-build commit',
    );
  }
  const controlledTargets = [];
  for (const targetID of catalog.controlled_target_ids) {
    const template = catalog.slots.find((slot) => slot.target_id === targetID);
    const receipt = receiptByController.get(template?.controller_id);
    if (!receipt || receipt.target_id !== targetID
        || receipt.handshake?.negotiated_version?.major !== catalog.protocol.host_handshake.major
        || receipt.handshake?.negotiated_version?.minor !== catalog.protocol.host_handshake.minor
        || receipt.handshake?.listener_instance_id !== listener.instance_id
        || receipt.handshake?.host?.source_commit !== listener.source_commit
        || receipt.handshake?.socket_path !== socketEndpoint.path) {
      throw new TypeError(`controller ${template?.controller_id ?? targetID} handshake differs from the run`);
    }
    const controller = normalizeControllerReceiptProcess(
      receipt.controller,
      `controller ${receipt.controller_id}`,
    );
    const target = normalizeControllerReceiptTarget(receipt.target, `target ${targetID}`);
    controlledTargets.push({
      id: targetID,
      controller_id: receipt.controller_id,
      controller,
      target,
    });
  }
  const operationSlots = catalog.slots.map((template) => {
    const receipt = receiptByController.get(template.controller_id);
    const controllerSlot = controllerReceiptSlot(receipt, template);
    const file = controllerBundleName(controllerSlot.bundle?.file);
    const bundle = bundleByFile.get(file);
    if (!file || !bundle || bundle.sha256 !== controllerSlot.bundle.sha256) {
      throw new TypeError(`controller slot ${template.slot_id} has no exact raw bundle`);
    }
    const payload = bundle.document?.receipt?.payload;
    const session = bundle.document?.operationSessionAttestation;
    if (!isPlainObject(payload) || !isPlainObject(session)) {
      throw new TypeError(`controller slot ${template.slot_id} bundle is malformed`);
    }
    const requestBytes = decodeBase64(bundle.document.canonicalRequest, 'controller canonical request');
    const responseBytes = decodeBase64(bundle.document.canonicalResponse, 'controller canonical response');
    const facts = wireFacts(requestBytes, responseBytes);
    const targetOwner = controlledTargets.find((entry) => entry.id === template.target_id);
    const sessionID = normalizedUUID(payload.sessionID, UUID_V4);
    const sessionSequence = normalizedDecimal(payload.sessionSequence);
    const requestID = normalizedUUID(payload.requestID, UUID_V8);
    const slot = {
      slot_id: template.slot_id,
      operation_id: `pending:${template.slot_id}`,
      kind: template.kind,
      checkpoint: template.checkpoint,
      controller_id: template.controller_id,
      target_id: template.target_id,
      controller: structuredClone(targetOwner.controller),
      client: normalizeWireProcess(payload.client, 'controller bundle client'),
      request_id: requestID,
      session: {
        id: sessionID,
        sequence: sessionSequence,
        predecessor_id: session.predecessorSessionID === undefined
          ? null
          : normalizedUUID(session.predecessorSessionID, UUID_V4),
        client_instance_id: normalizedUUID(payload.clientInstanceID, UUID_V4),
        attestation_sha256: sha256(canonicalBytes(session)),
        listener_instance_id: normalizedUUID(payload.listenerInstanceID, UUID_V4),
        listener_public_key_sha256: payload.listenerPublicKeySHA256,
      },
      operation: payload.operation,
      request_binding: {
        path: structuredClone(template.request_binding_path),
        value: valueAtPath(facts.request_document, template.request_binding_path),
      },
      request_envelope_case: facts.request_envelope_case,
      request_case: facts.request_case,
      response_envelope_case: facts.response_envelope_case,
      response_case: facts.response_case,
      request_sha256: payload.requestSHA256,
      response_sha256: payload.responseSHA256,
      target: normalizeWireTarget(payload.target),
      focused_element: payload.focusedElement ?? null,
      selected_leaf_evidence: payload.selectedLeafEvidence ?? null,
      interval: {
        started_at_milliseconds: payload.startedAtUnixMilliseconds,
        completed_at_milliseconds: payload.completedAtUnixMilliseconds,
      },
      source: {
        protocol_source_commit: catalog.protocol_source.commit,
        host_source_commit: listener.source_commit,
        listener_instance_id: listener.instance_id,
        host: structuredClone(listener.host),
      },
      expected_outcome: payload.outcome === undefined ? null : normalizeWireOutcome(payload.outcome),
    };
    validateOperationSemantics(facts, slot, controllerSlot.result);
    if (requestID !== controllerSlot.request_id || sessionID !== controllerSlot.session_id
        || sessionSequence !== controllerSlot.session_sequence
        || slot.operation !== template.operation
        || !sameJSON(slot.target, targetOwner.target)
        || !sameJSON(slot.expected_outcome, controllerSlot.outcome ?? null)
        || slot.request_sha256 !== controllerSlot.bundle.request_sha256
        || slot.response_sha256 !== controllerSlot.bundle.response_sha256
        || !sameJSON(slot.interval, controllerSlot.interval)) {
      throw new TypeError(`controller slot ${template.slot_id} differs from its signed bundle`);
    }
    return slot;
  });
  const monitorBinding = {
    version: 1,
    monitor_instance_id: monitorInstanceID,
    execution_nonce: executionNonce,
    monitor_source_commit: catalog.monitor_source.commit,
    monitor_source_sha256: catalog.monitor_source.probe_sha256,
    coordinator_runtime_commit: currentBuildCommit,
    coordinator_source_sha256: catalog.current_build_source.coordinator.sha256,
    monitor_process: structuredClone(monitorEvidence.monitor_process),
    monitor_attestation_socket_path: monitorEvidence.monitor_attestation_socket_path,
    sentinel: structuredClone(monitorEvidence.sentinel),
    foreground_controller: structuredClone(monitorEvidence.foreground_controller),
    foreground_target: structuredClone(monitorEvidence.foreground_target),
    revisions: {
      baseline: monitorEvidence.producer_sets?.baseline?.revision,
      grant: monitorEvidence.producer_sets?.grant?.revision,
      revoke: monitorEvidence.producer_sets?.revoke?.revision,
    },
  };
  const fences = Object.fromEntries((monitorEvidence.fences ?? []).map((entry) => (
    [entry?.name, entry?.heartbeat]
  )));
  const contract = {
    version: 4,
    certification_kind: LIVE_CERTIFICATION_KIND,
    claim_scope: LIVE_CLAIM_SCOPE,
    execution_nonce: executionNonce,
    catalog_sha256: catalogSHA256,
    certification_run_id: 'pending',
    protocol: {
      host_handshake: structuredClone(catalog.protocol.host_handshake),
      receipt_protocol_floor: structuredClone(catalog.protocol.receipt_protocol_floor),
    },
    source: structuredClone(catalog.protocol_source),
    current_build_source: { commit: currentBuildCommit },
    first_party_validator: structuredClone(firstPartyValidator),
    listener,
    socket_endpoint: structuredClone(socketEndpoint),
    interval: {
      started_at_milliseconds: fences['baseline-stable']?.wallClockMilliseconds,
      completed_at_milliseconds: fences['final-stable']?.wallClockMilliseconds,
    },
    monitor_binding: monitorBinding,
    controller_build: controllerBuild,
    controlled_targets: controlledTargets,
    operation_slots: operationSlots,
  };
  const runID = deriveCertificationRunID({
    catalogSHA256,
    listenerInstanceID: listener.instance_id,
    executionNonce,
    currentBuildSource: contract.current_build_source,
    monitorBinding,
    controllerBuild,
    operationSlots,
  });
  contract.certification_run_id = runID;
  contract.operation_slots.forEach((slot) => {
    slot.operation_id = `${runID}:${slot.slot_id}`;
  });
  const failures = validateContract(catalog, catalogSHA256, contract);
  if (failures.length > 0) {
    throw new TypeError(`assembled live contract is invalid: ${failures.map((entry) => entry.rule).join(', ')}`);
  }
  return contract;
}

export function makeOperationManifest(catalog, catalogSHA256, contract, bundles) {
  const contractSHA256 = canonicalSHA256(contract);
  if (bundles.length !== contract.operation_slots?.length) {
    throw new TypeError('raw bundle directory must contain exactly one bundle per contract slot');
  }
  const bundlesByRequestID = new Map();
  for (const bundle of bundles) {
    const requestID = normalizedUUID(bundle.document?.receipt?.payload?.requestID, UUID_V8);
    if (!requestID || bundle.file !== `${requestID}.json` || bundlesByRequestID.has(requestID)) {
      throw new TypeError('raw bundle filenames and signed request IDs must be canonical and unique');
    }
    bundlesByRequestID.set(requestID, bundle);
  }
  const slots = contract.operation_slots.map((slot) => {
    const bundle = bundlesByRequestID.get(slot.request_id);
    if (!bundle) throw new TypeError(`contract slot ${slot.slot_id} has no raw bundle`);
    const requestBytes = decodeBase64(bundle.document.canonicalRequest, 'canonical request');
    const responseBytes = decodeBase64(bundle.document.canonicalResponse, 'canonical response');
    const facts = wireFacts(requestBytes, responseBytes);
    if (valueAtPath(facts.request_document, slot.request_binding.path) !== slot.request_binding.value) {
      throw new TypeError(`contract slot ${slot.slot_id} is not marked in its signed request`);
    }
    return {
      slot_id: slot.slot_id,
      operation_id: slot.operation_id,
      bundle_file: bundle.file,
      bundle_sha256: bundle.sha256,
      controller_id: slot.controller_id,
      target_id: slot.target_id,
      client: structuredClone(slot.client),
      request_id: slot.request_id,
      session_id: slot.session.id,
      session_sequence: slot.session.sequence,
      session_attestation_sha256: slot.session.attestation_sha256,
      predecessor_session_id: slot.session.predecessor_id,
      client_instance_id: slot.session.client_instance_id,
      operation: slot.operation,
      request_binding: structuredClone(slot.request_binding),
      request_sha256: slot.request_sha256,
      response_sha256: slot.response_sha256,
    };
  });
  const manifest = {
    version: 1,
    catalog_sha256: catalogSHA256,
    contract_sha256: contractSHA256,
    slots,
  };
  const failures = [
    ...validateCatalog(catalog),
    ...validateContract(catalog, catalogSHA256, contract),
    ...validateManifest(catalog, catalogSHA256, contract, contractSHA256, manifest),
  ];
  if (failures.length > 0) {
    throw new TypeError(`contract/manifest preparation failed: ${failures.map((entry) => entry.rule).join(', ')}`);
  }
  return manifest;
}

function currentSocketEvidence(socketPath) {
  const info = fs.lstatSync(socketPath, { bigint: true });
  if (!info.isSocket() || info.isSymbolicLink()) {
    throw new TypeError('Bridge endpoint must be one live non-symlink socket');
  }
  return {
    path: socketPath,
    device: String(info.dev),
    inode: String(info.ino),
    is_socket: true,
    is_symbolic_link: false,
  };
}

function createPreparedArtifacts(directory, contract, manifest, evidence, bundles) {
  const artifactRoot = path.resolve(directory);
  fs.mkdirSync(artifactRoot, { mode: 0o700 });
  fs.chmodSync(artifactRoot, 0o700);
  const bundleDirectory = path.join(artifactRoot, 'bundles');
  fs.mkdirSync(bundleDirectory, { mode: 0o700 });
  const writeJSON = (name, value) => {
    fs.writeFileSync(path.join(artifactRoot, name), `${JSON.stringify(value, null, 2)}\n`, {
      encoding: 'utf8',
      mode: 0o600,
      flag: 'wx',
    });
  };
  writeJSON('contract.json', contract);
  writeJSON('operation-manifest.json', manifest);
  writeJSON('raw-evidence.json', evidence);
  for (const bundle of bundles) {
    fs.writeFileSync(path.join(bundleDirectory, bundle.file), bundle.bytes, {
      mode: 0o600,
      flag: 'wx',
    });
  }
  return artifactRoot;
}

function parseArguments(argv) {
  if (argv.includes('--help') || argv.includes('-h')) return { action: 'help' };
  if (argv.includes('--version')) return { action: 'version' };
  const commands = ['prepare', 'finalize', 'digest', 'verify-digests'];
  const command = commands.includes(argv[0]) ? argv[0] : 'finalize';
  const startIndex = command === argv[0] ? 1 : 0;
  const result = { command };
  for (let index = startIndex; index < argv.length; index += 1) {
    const value = argv[index];
    if (command === 'digest' && value === '--spec') {
      result.spec = true;
      continue;
    }
    const normalized = value === '-o' ? '--output' : value;
    let options;
    if (command === 'prepare') {
      options = [
        '--controller-receipts', '--bundles', '--monitor-evidence', '--foreground-postcondition',
        '--artifacts', '--peekaboo', '--output',
      ];
    } else if (command === 'finalize') {
      options = ['--artifacts', '--peekaboo', '--output'];
    } else if (command === 'digest') {
      options = ['--kind', '--input', '--projection'];
    } else {
      options = ['--artifacts', '--summary'];
    }
    if (options.includes(normalized) && argv[index + 1]) {
      result[normalized.slice(2)] = argv[index + 1];
      index += 1;
    } else {
      throw new TypeError(`Unknown or incomplete argument: ${value}`);
    }
  }
  if (['prepare', 'finalize'].includes(command) && (!result.artifacts || !result.peekaboo)) {
    throw new TypeError('--artifacts and --peekaboo are required');
  }
  if (command === 'prepare' && (
    !result['controller-receipts'] || !result.bundles || !result['monitor-evidence']
      || !result['foreground-postcondition']
  )) {
    throw new TypeError(
      'prepare also requires --controller-receipts, --bundles, --monitor-evidence, and --foreground-postcondition',
    );
  }
  if (command === 'digest' && result.spec !== true && (!result.kind || !result.input)) {
    throw new TypeError('digest requires --kind and --input, or --spec');
  }
  if (command === 'verify-digests' && (!result.artifacts || !result.summary)) {
    throw new TypeError('verify-digests requires --artifacts and --summary');
  }
  return result;
}

function writeOwnerPrivateOutput(outputPath, output) {
  const absolute = path.resolve(outputPath);
  const parent = path.dirname(absolute);
  const parentSnapshot = openPrivateDirectory(parent, 'output parent');
  try {
    fs.writeFileSync(absolute, output, { encoding: 'utf8', mode: 0o600, flag: 'wx' });
  } finally {
    closeAndValidateDirectory(parentSnapshot, true);
  }
}

function readStableRegularFile(filePath, label) {
  const flags = fs.constants.O_RDONLY
    | (fs.constants.O_CLOEXEC ?? 0)
    | (fs.constants.O_NOFOLLOW ?? 0);
  const descriptor = fs.openSync(filePath, flags);
  try {
    const before = fs.fstatSync(descriptor);
    if (!before.isFile() || before.size <= 0 || before.size > 512 * 1024 * 1024) {
      throw new TypeError(`${label} must be one bounded regular file`);
    }
    const bytes = fs.readFileSync(descriptor);
    const after = fs.fstatSync(descriptor);
    const pathAfter = fs.lstatSync(filePath);
    if (before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size
        || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs
        || after.dev !== pathAfter.dev || after.ino !== pathAfter.ino
        || bytes.length !== before.size) {
      throw new TypeError(`${label} changed while it was read`);
    }
    return { bytes, info: after };
  } finally {
    fs.closeSync(descriptor);
  }
}

function appleAnchoredTeamRequirement(teamID) {
  if (typeof teamID !== 'string' || !/^[A-Z0-9]{5,20}$/.test(teamID)) {
    throw new TypeError('Apple-anchored signing requirement has an invalid Team ID');
  }
  return `anchor apple generic and certificate leaf[subject.OU] = "${teamID}"`;
}

function codeSignatureMetadata(signatureInfo, label) {
  if (signatureInfo.error || signatureInfo.status !== 0) {
    throw new TypeError(`${label} code-signature identity is unavailable`);
  }
  const signatureText = `${signatureInfo.stdout ?? ''}\n${signatureInfo.stderr ?? ''}`;
  const executable = signatureText.match(/^Executable=(.+)$/m)?.[1] ?? null;
  const teamID = signatureText.match(/^TeamIdentifier=([A-Z0-9]+)$/m)?.[1] ?? null;
  const codeSignatureHash = signatureText.match(/^CDHash=([0-9a-f]+)$/m)?.[1] ?? null;
  if (!teamID || !HEX40.test(codeSignatureHash ?? '')) {
    throw new TypeError(`${label} code-signature identity is incomplete`);
  }
  return { executable, team_id: teamID, code_signature_hash: codeSignatureHash };
}

export function verifyAppleSigningRequirement(subject, teamID, label, runner = spawnSync) {
  const verification = appleAnchorVerificationResult(subject, teamID, runner);
  if (verification.error || verification.status !== 0) {
    throw new TypeError(`${label} does not satisfy the Apple-anchored signing requirement`);
  }
}

function displayCodeSignatureMetadata(subject, label, runner = spawnSync) {
  return codeSignatureMetadata(runner('/usr/bin/codesign', [
    '--display', '--verbose=4', subject,
  ], {
    encoding: 'utf8',
    timeout: 10_000,
    maxBuffer: 1024 * 1024,
  }), label);
}

function nativeMachOArchitecture(nodeArchitecture = process.arch) {
  if (nodeArchitecture === 'arm64') return 'arm64';
  if (nodeArchitecture === 'x64') return 'x86_64';
  throw new TypeError(`unsupported native Mach-O architecture: ${nodeArchitecture}`);
}

export function embeddedSourceCommit(executable, label = 'signed executable', {
  runner = spawnSync,
  nodeArchitecture = process.arch,
} = {}) {
  const architecture = nativeMachOArchitecture(nodeArchitecture);
  // `-P` is otool's dedicated decoded `__info_plist` output; `-arch` prevents concatenated universal slices.
  const section = runner('/usr/bin/otool', ['-arch', architecture, '-X', '-P', executable], {
    encoding: 'utf8',
    timeout: 10_000,
    maxBuffer: 4 * 1024 * 1024,
  });
  if (section.error || section.status !== 0) {
    throw new TypeError(`${label} has no embedded info plist for ${architecture}`);
  }
  const plist = runner('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '-'], {
    input: section.stdout,
    encoding: 'utf8',
    timeout: 10_000,
    maxBuffer: 4 * 1024 * 1024,
  });
  if (plist.error || plist.status !== 0) {
    throw new TypeError(`${label} info plist is unreadable`);
  }
  let value;
  try {
    value = JSON.parse(plist.stdout);
  } catch {
    throw new TypeError(`${label} info plist is unreadable`);
  }
  if (!HEX40.test(value?.PeekabooSourceCommit ?? '')) {
    throw new TypeError(`${label} has no exact source stamp`);
  }
  return value.PeekabooSourceCommit;
}

function appleAnchorVerificationResult(subject, teamID, runner = spawnSync) {
  const requirement = appleAnchoredTeamRequirement(teamID);
  const args = ['--verify', '--strict'];
  if (!String(subject).startsWith('+')) args.push('--all-architectures');
  args.push(`-R=${requirement}`, subject);
  return runner('/usr/bin/codesign', args, {
    encoding: 'utf8',
    timeout: 10_000,
    maxBuffer: 1024 * 1024,
  });
}

function stagedCodeFile(pathname, label) {
  const file = readStableRegularFile(pathname, label);
  return {
    path: pathname,
    device: file.info.dev,
    inode: file.info.ino,
    linkCount: file.info.nlink,
    mode: file.info.mode,
    owner: file.info.uid,
    size: file.info.size,
    modifiedAtMilliseconds: file.info.mtimeMs,
    changedAtMilliseconds: file.info.ctimeMs,
    sha256: sha256(file.bytes),
  };
}

export function assertCodeIdentityInspectorStage(stage) {
  const directory = fs.lstatSync(stage.directory);
  if (!directory.isDirectory() || directory.isSymbolicLink()
      || directory.dev !== stage.directoryDevice || directory.ino !== stage.directoryInode
      || directory.mtimeMs !== stage.directoryModifiedAtMilliseconds
      || directory.ctimeMs !== stage.directoryChangedAtMilliseconds
      || (directory.mode & 0o077) !== 0
      || (typeof process.geteuid === 'function' && directory.uid !== process.geteuid())
      || !sameJSON(fs.readdirSync(stage.directory).sort(), stage.files.map((entry) => entry.name).sort())) {
    throw new TypeError('staged code-identity inspector directory changed');
  }
  for (const expected of stage.files) {
    const observed = stagedCodeFile(expected.path, `staged code-identity inspector ${expected.name}`);
    if (observed.device !== expected.device || observed.inode !== expected.inode
        || observed.linkCount !== 1 || observed.linkCount !== expected.linkCount
        || observed.mode !== expected.mode || observed.owner !== expected.owner
        || observed.size !== expected.size
        || observed.modifiedAtMilliseconds !== expected.modifiedAtMilliseconds
        || observed.changedAtMilliseconds !== expected.changedAtMilliseconds
        || observed.sha256 !== expected.sha256) {
      throw new TypeError(`staged code-identity inspector ${expected.name} changed`);
    }
  }
}

export function removeCodeIdentityInspectorStage(stage) {
  fs.chmodSync(stage.directory, 0o700);
  fs.rmSync(stage.directory, { recursive: true, force: true });
}

function validCodeIdentityProcess(value) {
  return exactKeys(value, ['pid', 'start_identity', 'code_signature_hash'])
    && positiveInteger(value.pid)
    && normalizedDecimal(value.start_identity, true) !== null
    && HEX40.test(value.code_signature_hash ?? '');
}

function validCodeIdentityBuild(value) {
  return exactKeys(value, ['source_commit', 'executable_path', 'executable_sha256', 'team_id'])
    && HEX40.test(value.source_commit ?? '')
    && typeof value.executable_path === 'string' && path.isAbsolute(value.executable_path)
    && HEX64.test(value.executable_sha256 ?? '')
    && /^[A-Z0-9]{10}$/.test(value.team_id ?? '');
}

function codeIdentityInspectorBuild(stage) {
  return {
    source_commit: stage.sourceCommit,
    executable_path: stage.executable,
    executable_sha256: stage.executableSHA256,
    team_id: stage.teamID,
  };
}

function validateCodeIdentitySubject(subject, expected, label) {
  if (!exactKeys(subject, [
    'kind', 'process', 'executable_path', 'executable_sha256',
    'code_signature_hash', 'team_id', 'source_commit',
  ]) || subject.kind !== expected.kind
      || typeof subject.executable_path !== 'string'
      || subject.executable_path !== expected.executablePath
      || !HEX40.test(subject.code_signature_hash ?? '')
      || subject.team_id !== expected.teamID
      || subject.source_commit !== expected.sourceCommit) {
    throw new TypeError(`${label} code-identity subject differs from the exact expectation`);
  }
  if (expected.codeSignatureHash !== null
      && subject.code_signature_hash !== expected.codeSignatureHash) {
    throw new TypeError(`${label} code-signature hash differs from the exact expectation`);
  }
  if (expected.kind === 'executable') {
    if (subject.process !== null || subject.executable_sha256 !== expected.executableSHA256) {
      throw new TypeError(`${label} executable identity differs from the exact file`);
    }
  } else if (expected.kind === 'process') {
    if (subject.executable_sha256 !== null || !validCodeIdentityProcess(subject.process)
        || !sameJSON(subject.process, expected.process)
        || subject.process.code_signature_hash !== subject.code_signature_hash) {
      throw new TypeError(`${label} process identity differs from the exact generation and executable`);
    }
  } else {
    throw new TypeError(`${label} code-identity kind is invalid`);
  }
  return subject;
}

async function waitForInspectorReceipt(outputPath, childState, timeoutMilliseconds) {
  const deadline = Date.now() + timeoutMilliseconds;
  while (Date.now() < deadline) {
    if (fs.existsSync(outputPath)) return;
    if (childState.exited) throw new TypeError('native code-identity inspector exited before readiness');
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new TypeError('native code-identity inspector timed out before readiness');
}

async function waitForStoppedProcess(pid, runner, timeoutMilliseconds = 2000) {
  const deadline = Date.now() + timeoutMilliseconds;
  while (Date.now() < deadline) {
    const status = runner('/bin/ps', ['-o', 'state=', '-p', String(pid)], {
      encoding: 'utf8', timeout: 1000, maxBuffer: 1024,
    });
    if (!status.error && status.status === 0 && /^T/m.test(status.stdout ?? '')) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new TypeError('native code-identity inspector did not enter the stopped state');
}

async function waitForReleasedInspectorExit(exitPromise, label) {
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new TypeError(`${label} native code-identity inspector did not exit after release`));
    }, 5000);
    exitPromise.then(() => {
      clearTimeout(timeout);
      resolve();
    }, (error) => {
      clearTimeout(timeout);
      reject(error);
    });
  });
}

export async function inspectCodeIdentity({
  inspectorStage,
  subject,
  expected,
  label,
  runner = spawnSync,
  spawnChild = spawn,
  signalProcess = process.kill.bind(process),
  waitForStopped = waitForStoppedProcess,
}) {
  assertCodeIdentityInspectorStage(inspectorStage);
  const temporaryDirectory = fs.realpathSync(
    fs.mkdtempSync(path.join(os.tmpdir(), 'peekaboo-code-identity-')),
  );
  fs.chmodSync(temporaryDirectory, 0o700);
  const planPath = path.join(temporaryDirectory, 'plan.json');
  const outputPath = path.join(temporaryDirectory, 'receipt.json');
  const inspectorBuild = codeIdentityInspectorBuild(inspectorStage);
  const plan = {
    version: 1,
    execution_nonce: randomBytes(32).toString('hex'),
    expected_inspector_build: inspectorBuild,
    subject,
    output_path: outputPath,
    release_path: path.join(temporaryDirectory, 'release.json'),
  };
  let child;
  let childState;
  let completionPromise;
  let stopped = false;
  try {
    writeOwnerPrivateOutput(planPath, `${JSON.stringify(plan, null, 2)}\n`);
    child = spawnChild(inspectorStage.executable, ['--inspect-code', planPath], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    if (!positiveInteger(child?.pid) || !child.stdout || !child.stderr) {
      throw new TypeError(`${label} native code-identity inspector did not start`);
    }
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    childState = { exited: false, code: null, signal: null, error: null };
    completionPromise = new Promise((resolve) => {
      child.once('error', (error) => {
        childState.error = error;
        childState.exited = true;
        resolve();
      });
      child.once('exit', (code, signal) => {
        childState.code = code;
        childState.signal = signal;
        childState.exited = true;
      });
      child.once('close', (code, signal) => {
        childState.code ??= code;
        childState.signal ??= signal;
        childState.exited = true;
        resolve();
      });
    });
    await waitForInspectorReceipt(outputPath, childState, 30_000);
    const receipt = parseJSON(
      readStablePrivateFile(outputPath, `${label} code-identity receipt`),
      `${label} code-identity receipt`,
    );
    signalProcess(child.pid, 'SIGSTOP');
    stopped = true;
    await waitForStopped(child.pid, runner);
    assertCodeIdentityInspectorStage(inspectorStage);
    verifyAppleSigningRequirement(`+${child.pid}`, inspectorStage.teamID, `${label} live inspector`, runner);
    assertCodeIdentityInspectorStage(inspectorStage);
    const liveIdentity = displayCodeSignatureMetadata(
      `+${child.pid}`, `${label} live inspector`, runner,
    );
    assertCodeIdentityInspectorStage(inspectorStage);
    let liveExecutable;
    try {
      liveExecutable = fs.realpathSync(liveIdentity.executable);
    } catch {
      throw new TypeError(`${label} live inspector executable path is unavailable`);
    }
    if (!exactKeys(receipt, ['version', 'inspector_process', 'inspector_build', 'subject'])
        || receipt.version !== 1 || !validCodeIdentityProcess(receipt.inspector_process)
        || receipt.inspector_process.pid !== child.pid
        || !validCodeIdentityBuild(receipt.inspector_build)
        || !sameJSON(receipt.inspector_build, inspectorBuild)
        || liveExecutable !== inspectorStage.executable
        || liveIdentity.team_id !== inspectorStage.teamID
        || liveIdentity.code_signature_hash !== receipt.inspector_process.code_signature_hash
        || (inspectorStage.codeSignatureHash !== null
          && (receipt.inspector_process.code_signature_hash !== inspectorStage.codeSignatureHash
            || liveIdentity.code_signature_hash !== inspectorStage.codeSignatureHash))) {
      throw new TypeError(`${label} code-identity receipt does not bind the exact inspector build and process`);
    }
    const inspected = validateCodeIdentitySubject(receipt.subject, expected, label);
    if (expected.executablePath === inspectorStage.executable
        && receipt.inspector_process.code_signature_hash !== inspected.code_signature_hash) {
      throw new TypeError(`${label} staged inspector self-identity is inconsistent`);
    }
    if (!sameJSON(fs.readdirSync(temporaryDirectory).sort(), ['plan.json', 'receipt.json'])) {
      throw new TypeError(`${label} code-identity exchange created unexpected artifacts`);
    }
    writeOwnerPrivateOutput(plan.release_path, `${JSON.stringify({
      version: 1,
      execution_nonce: plan.execution_nonce,
      phase: 'release',
    }, null, 2)}\n`);
    signalProcess(child.pid, 'SIGCONT');
    stopped = false;
    await waitForReleasedInspectorExit(completionPromise, label);
    assertCodeIdentityInspectorStage(inspectorStage);
    if (childState.error || childState.code !== 0 || childState.signal !== null) {
      throw new TypeError(`${label} native code-identity inspector exited nonzero: ${stderr.trim()}`);
    }
    let envelope;
    try {
      envelope = JSON.parse(stdout);
    } catch {
      throw new TypeError(`${label} native code-identity inspector result is not JSON`);
    }
    if (!exactKeys(envelope, ['receipt', 'result']) || envelope.result !== 'passed'
        || envelope.receipt !== outputPath) {
      throw new TypeError(`${label} native code-identity inspector result is not closed`);
    }
    return inspected;
  } finally {
    if (child && childState?.exited !== true) {
      try { if (stopped) signalProcess(child.pid, 'SIGCONT'); } catch {}
      try { signalProcess(child.pid, 'SIGTERM'); } catch {}
      try { await waitForReleasedInspectorExit(completionPromise, label); } catch {}
    }
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

export async function stageCodeIdentityInspector(sourceExecutable, allowedTeamIDs, sourceCommit, {
  runner = spawnSync,
  parentDirectory = os.tmpdir(),
  spawnChild = spawn,
  signalProcess = process.kill.bind(process),
  waitForStopped = waitForStoppedProcess,
} = {}) {
  const sourcePath = fs.realpathSync(path.resolve(sourceExecutable));
  const source = readStableRegularFile(sourcePath, 'source code-identity inspector');
  const directory = fs.realpathSync(
    fs.mkdtempSync(path.join(parentDirectory, 'peekaboo-code-inspector-')),
  );
  fs.chmodSync(directory, 0o700);
  const executable = path.join(directory, 'peekaboo-certification-controller');
  try {
    fs.writeFileSync(executable, source.bytes, { mode: 0o500, flag: 'wx' });
    const sourceDirectory = path.dirname(sourcePath);
    const runtimeNames = fs.readdirSync(sourceDirectory).sort().filter((name) => (
      /^libswiftCompatibility[A-Za-z0-9._-]*\.dylib$/.test(name)
    ));
    for (const name of runtimeNames) {
      const library = readStableRegularFile(path.join(sourceDirectory, name), `code inspector runtime ${name}`);
      fs.writeFileSync(path.join(directory, name), library.bytes, { mode: 0o500, flag: 'wx' });
    }
    const filePaths = [
      ['peekaboo-certification-controller', executable],
      ...runtimeNames.map((name) => [name, path.join(directory, name)]),
    ];
    const files = filePaths.map(([name, pathname]) => ({ name, ...stagedCodeFile(pathname, name) }));
    fs.chmodSync(directory, 0o500);
    const directoryInfo = fs.lstatSync(directory);
    const stage = {
      directory,
      directoryDevice: directoryInfo.dev,
      directoryInode: directoryInfo.ino,
      directoryModifiedAtMilliseconds: directoryInfo.mtimeMs,
      directoryChangedAtMilliseconds: directoryInfo.ctimeMs,
      executable,
      executableSHA256: files[0].sha256,
      teamID: null,
      sourceCommit,
      codeSignatureHash: null,
      files,
    };
    assertCodeIdentityInspectorStage(stage);
    const matchingTeamIDs = allowedTeamIDs.filter((teamID) => {
      assertCodeIdentityInspectorStage(stage);
      const verification = appleAnchorVerificationResult(executable, teamID, runner);
      assertCodeIdentityInspectorStage(stage);
      return !verification.error && verification.status === 0;
    });
    if (matchingTeamIDs.length !== 1) {
      throw new TypeError('staged code-identity inspector must match exactly one catalog-approved Apple anchor');
    }
    const teamID = matchingTeamIDs[0];
    stage.teamID = teamID;
    for (const name of runtimeNames) {
      assertCodeIdentityInspectorStage(stage);
      const verification = appleAnchorVerificationResult(path.join(directory, name), teamID, runner);
      assertCodeIdentityInspectorStage(stage);
      if (verification.error || verification.status !== 0) {
        throw new TypeError(`staged code inspector runtime ${name} has the wrong Apple anchor`);
      }
    }
    assertCodeIdentityInspectorStage(stage);
    const stagedIdentity = displayCodeSignatureMetadata(executable, 'staged code-identity inspector', runner);
    assertCodeIdentityInspectorStage(stage);
    if (stagedIdentity.team_id !== teamID) {
      throw new TypeError('staged code-identity inspector display metadata differs from its Apple anchor');
    }
    assertCodeIdentityInspectorStage(stage);
    const stagedSourceCommit = embeddedSourceCommit(executable, 'staged code-identity inspector', { runner });
    assertCodeIdentityInspectorStage(stage);
    if (stagedSourceCommit !== sourceCommit) {
      throw new TypeError('staged code-identity inspector source differs from the clean Git HEAD');
    }
    stage.codeSignatureHash = stagedIdentity.code_signature_hash;
    const selfIdentity = await inspectCodeIdentity({
      inspectorStage: stage,
      subject: { kind: 'executable', executable_path: executable, expected_team_id: teamID },
      expected: {
        kind: 'executable',
        executablePath: executable,
        executableSHA256: stage.executableSHA256,
        codeSignatureHash: stage.codeSignatureHash,
        teamID,
        sourceCommit,
      },
      label: 'staged code-identity inspector',
      runner,
      spawnChild,
      signalProcess,
      waitForStopped,
    });
    if (selfIdentity.code_signature_hash !== stage.codeSignatureHash) {
      throw new TypeError('staged code-identity inspector live CDHash differs from its immutable stage');
    }
    assertCodeIdentityInspectorStage(stage);
    return stage;
  } catch (error) {
    try {
      fs.chmodSync(directory, 0o700);
      fs.rmSync(directory, { recursive: true, force: true });
    } catch {}
    throw error;
  }
}

function assertStagedExecutable(stage, expectedSHA256) {
  assertCodeIdentityInspectorStage(stage);
  if (stage.executableFile.sha256 !== expectedSHA256) {
    throw new TypeError('staged first-party validator changed during certification');
  }
}

function withStableFirstPartyStage(stage, expectedSHA256, operation) {
  assertStagedExecutable(stage, expectedSHA256);
  try {
    return operation();
  } finally {
    assertStagedExecutable(stage, expectedSHA256);
  }
}

function stagedFirstPartyIdentity(stage, file, expectedTeamID, label, runner = spawnSync) {
  withStableFirstPartyStage(stage, stage.executableFile.sha256, () => {
    verifyAppleSigningRequirement(file.path, expectedTeamID, label, runner);
  });
  const identity = withStableFirstPartyStage(stage, stage.executableFile.sha256, () => (
    displayCodeSignatureMetadata(file.path, label, runner)
  ));
  if (identity.team_id !== expectedTeamID) {
    throw new TypeError(`${label} signing team differs from the Apple-anchored requirement`);
  }
  return identity;
}

function stagedFirstPartyIdentityForAllowedTeams(stage, file, allowedTeamIDs, label, runner = spawnSync) {
  const matchingTeamIDs = allowedTeamIDs.filter((teamID) => {
    const verification = withStableFirstPartyStage(stage, stage.executableFile.sha256, () => (
      appleAnchorVerificationResult(file.path, teamID, runner)
    ));
    return !verification.error && verification.status === 0;
  });
  if (matchingTeamIDs.length !== 1) {
    throw new TypeError(`${label} must match exactly one catalog-approved Apple anchor`);
  }
  const identity = withStableFirstPartyStage(stage, stage.executableFile.sha256, () => (
    displayCodeSignatureMetadata(file.path, label, runner)
  ));
  if (identity.team_id !== matchingTeamIDs[0]) {
    throw new TypeError(`${label} signing team differs from the Apple-anchored requirement`);
  }
  return identity;
}

function createFirstPartyExecutableStage(executablePath, contract = null) {
  const sourceExecutable = fs.realpathSync(path.resolve(executablePath));
  const source = readStableRegularFile(sourceExecutable, 'first-party validator');
  const sourceSHA256 = sha256(source.bytes);
  if (contract && sourceSHA256 !== contract.first_party_validator.executable_sha256) {
    throw new TypeError('first-party validator bytes differ from the contracted executable');
  }
  const stageDirectory = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'peekaboo-validator.')));
  fs.chmodSync(stageDirectory, 0o700);
  const executable = path.join(stageDirectory, 'peekaboo');
  try {
    fs.writeFileSync(executable, source.bytes, { mode: 0o500, flag: 'wx' });
    const sourceDirectory = path.dirname(sourceExecutable);
    const runtimeNames = fs.readdirSync(sourceDirectory).sort().filter((name) => (
      /^libswiftCompatibility[A-Za-z0-9._-]*\.dylib$/.test(name)
    ));
    const expectedRuntimeNames = contract?.first_party_validator.runtime_libraries.map((entry) => entry.name);
    if (expectedRuntimeNames && !sameJSON(runtimeNames, expectedRuntimeNames)) {
      throw new TypeError('validator runtime library set differs from the closed contract');
    }
    for (const name of runtimeNames) {
      const librarySource = path.join(sourceDirectory, name);
      const library = readStableRegularFile(librarySource, `validator runtime ${name}`);
      const expected = contract?.first_party_validator.runtime_libraries.find((entry) => entry.name === name);
      if (expected && sha256(library.bytes) !== expected.sha256) {
        throw new TypeError(`validator runtime ${name} differs from the contracted bytes`);
      }
      const stagedLibrary = path.join(stageDirectory, name);
      fs.writeFileSync(stagedLibrary, library.bytes, { mode: 0o500, flag: 'wx' });
    }
    const filePaths = [
      ['peekaboo', executable],
      ...runtimeNames.map((name) => [name, path.join(stageDirectory, name)]),
    ];
    const files = filePaths.map(([name, pathname]) => ({ name, ...stagedCodeFile(pathname, name) }));
    fs.chmodSync(stageDirectory, 0o500);
    const directoryInfo = fs.lstatSync(stageDirectory);
    const stage = {
      directory: stageDirectory,
      directoryDevice: directoryInfo.dev,
      directoryInode: directoryInfo.ino,
      directoryModifiedAtMilliseconds: directoryInfo.mtimeMs,
      directoryChangedAtMilliseconds: directoryInfo.ctimeMs,
      executable,
      executableFile: files[0],
      libraries: files.slice(1),
      files,
    };
    assertStagedExecutable(stage, contract?.first_party_validator.executable_sha256 ?? sourceSHA256);
    return stage;
  } catch (error) {
    try {
      fs.chmodSync(stageDirectory, 0o700);
      fs.rmSync(stageDirectory, { recursive: true, force: true });
    } catch {}
    throw error;
  }
}

export function inspectFirstPartyExecutable(sourceExecutable, catalog, { runner = spawnSync } = {}) {
  const stage = createFirstPartyExecutableStage(sourceExecutable);
  try {
    const identity = stagedFirstPartyIdentityForAllowedTeams(
      stage,
      stage.executableFile,
      catalog.trusted_first_party_validator_team_ids,
      'staged first-party validator',
      runner,
    );
    const versionRun = withStableFirstPartyStage(stage, stage.executableFile.sha256, () => (
      runner(stage.executable, ['--version', '--json'], {
        encoding: 'utf8', timeout: 10_000, maxBuffer: 1024 * 1024,
      })
    ));
    let version;
    try {
      version = JSON.parse(versionRun.stdout);
    } catch {
      throw new TypeError('first-party validator version receipt is not JSON');
    }
    const sourceCommit = version?.data?.sourceCommit;
    if (versionRun.status !== 0 || version?.success !== true || !HEX40.test(sourceCommit ?? '')) {
      throw new TypeError('first-party validator has no exact stamped source commit');
    }
    const runtimeLibraries = stage.libraries.map((library) => {
      const libraryIdentity = stagedFirstPartyIdentity(
        stage, library, identity.team_id, `staged validator runtime ${library.name}`, runner,
      );
      return {
        name: library.name,
        sha256: library.sha256,
        code_signature_hash: libraryIdentity.code_signature_hash,
      };
    });
    return {
      id: 'peekaboo-bridge-receipt-validate-v1',
      source_commit: sourceCommit,
      executable_sha256: stage.executableFile.sha256,
      code_signature_hash: identity.code_signature_hash,
      team_id: identity.team_id,
      runtime_libraries: runtimeLibraries,
      trusted_host_team_ids: structuredClone(catalog.trusted_bridge_host_team_ids),
    };
  } finally {
    removeStagedExecutable(stage);
  }
}

function stageFirstPartyExecutable(executablePath, catalog, contract) {
  const stage = createFirstPartyExecutableStage(executablePath, contract);
  try {
    const identity = stagedFirstPartyIdentity(
      stage,
      stage.executableFile,
      contract.first_party_validator.team_id,
      'staged first-party validator',
    );

    if (!catalog.trusted_first_party_validator_team_ids.includes(identity.team_id)
        || identity.team_id !== contract.first_party_validator.team_id
        || identity.code_signature_hash !== contract.first_party_validator.code_signature_hash) {
      throw new TypeError('first-party validator signing identity differs from the source-controlled contract');
    }
    for (const expected of contract.first_party_validator.runtime_libraries) {
      const library = stage.libraries.find((entry) => entry.name === expected.name);
      const libraryIdentity = stagedFirstPartyIdentity(
        stage, library, identity.team_id, `staged validator runtime ${expected.name}`,
      );
      if (libraryIdentity.code_signature_hash !== expected.code_signature_hash) {
        throw new TypeError(`validator runtime ${expected.name} differs from the contracted signing identity`);
      }
    }
    const versionRun = withStableFirstPartyStage(stage, stage.executableFile.sha256, () => (
      spawnSync(stage.executable, ['--version', '--json'], {
        encoding: 'utf8', timeout: 10_000, maxBuffer: 1024 * 1024,
      })
    ));
    let version;
    try {
      version = JSON.parse(versionRun.stdout);
    } catch {
      throw new TypeError('first-party validator version receipt is not JSON');
    }
    if (versionRun.status !== 0 || version?.success !== true
        || version?.data?.sourceCommit !== contract.first_party_validator.source_commit) {
      throw new TypeError('first-party validator source commit differs from the contract');
    }
    assertStagedExecutable(stage, contract.first_party_validator.executable_sha256);
    return stage;
  } catch (error) {
    try {
      removeStagedExecutable(stage);
    } catch {}
    throw error;
  }
}

function removeStagedExecutable(stage) {
  fs.chmodSync(stage.directory, 0o700);
  fs.rmSync(stage.directory, { recursive: true, force: true });
}

function verifyLiveSocket(contract, evidence) {
  const info = fs.lstatSync(contract.socket_endpoint.path, { bigint: true });
  if (!info.isSocket() || info.isSymbolicLink()
      || String(info.dev) !== contract.socket_endpoint.device
      || String(info.ino) !== contract.socket_endpoint.inode
      || !sameJSON(evidence.socket_evidence, {
        path: contract.socket_endpoint.path,
        device: String(info.dev),
        inode: String(info.ino),
        is_socket: true,
        is_symbolic_link: false,
      })) {
    throw new TypeError('live Bridge socket differs from the contracted device and inode');
  }
}

async function verifyLiveMonitorRuntime(contract, evidence, inspectorStage) {
  const binding = contract.monitor_binding;
  const monitorEvidence = evidence.monitor_evidence;
  const executable = readStableRegularFile(
    binding.monitor_process.executable_path,
    'live certification monitor',
  );
  if (sha256(executable.bytes) !== binding.monitor_process.executable_sha256) {
    throw new TypeError('live certification monitor bytes differ from the contract');
  }
  const monitorPath = fs.realpathSync(binding.monitor_process.executable_path);
  const identity = await inspectCodeIdentity({
    inspectorStage,
    subject: {
      kind: 'executable', executable_path: monitorPath,
      expected_team_id: binding.monitor_process.team_id,
    },
    expected: {
      kind: 'executable',
      executablePath: monitorPath,
      executableSHA256: binding.monitor_process.executable_sha256,
      codeSignatureHash: binding.monitor_process.code_signature_hash,
      teamID: binding.monitor_process.team_id,
      sourceCommit: binding.monitor_process.source_commit,
    },
    label: 'live certification monitor file',
  });
  const liveIdentity = await inspectCodeIdentity({
    inspectorStage,
    subject: {
      kind: 'process',
      process_identifier: binding.monitor_process.pid,
      process_start_identity: binding.monitor_process.start_identity,
      expected_team_id: binding.monitor_process.team_id,
    },
    expected: {
      kind: 'process',
      process: {
        pid: binding.monitor_process.pid,
        start_identity: binding.monitor_process.start_identity,
        code_signature_hash: binding.monitor_process.code_signature_hash,
      },
      executablePath: monitorPath,
      executableSHA256: null,
      codeSignatureHash: binding.monitor_process.code_signature_hash,
      teamID: binding.monitor_process.team_id,
      sourceCommit: binding.monitor_process.source_commit,
    },
    label: 'live certification monitor process',
  });
  if (identity.code_signature_hash !== binding.monitor_process.code_signature_hash
      || identity.team_id !== binding.monitor_process.team_id
      || liveIdentity.code_signature_hash !== binding.monitor_process.code_signature_hash
      || liveIdentity.team_id !== binding.monitor_process.team_id
      || liveIdentity.executable_path !== monitorPath) {
    throw new TypeError('live certification monitor code identity differs from the contract');
  }
  const heartbeatInfo = fs.lstatSync(binding.monitor_process.heartbeat_path);
  if (!heartbeatInfo.isFile() || heartbeatInfo.isSymbolicLink() || heartbeatInfo.nlink !== 1
      || (typeof process.getuid === 'function' && heartbeatInfo.uid !== process.getuid())
      || (heartbeatInfo.mode & 0o077) !== 0) {
    throw new TypeError('live monitor heartbeat must be one owner-private regular file');
  }
  const heartbeat = parseJSON(
    readStableRegularFile(binding.monitor_process.heartbeat_path, 'live monitor heartbeat').bytes,
    'live monitor heartbeat',
  );
  const finalHeartbeat = monitorEvidence.fences.at(-1)?.heartbeat;
  if (!sameJSON(heartbeat, finalHeartbeat)) {
    throw new TypeError('live monitor final heartbeat differs from the certification corpus');
  }
  const crashEvidence = monitorEvidence.crash_evidence;
  const crashDirectory = requireCanonicalDiagnosticReportsDirectory(crashEvidence.directory);
  const currentCrashInventory = fs.readdirSync(crashDirectory, { withFileTypes: true })
    .filter((entry) => entry.isFile() && crashEvidence.prefixes.some((prefix) => (
      entry.name.startsWith(prefix)
    )))
    .map((entry) => {
      const filePath = path.join(crashDirectory, entry.name);
      const file = readStableRegularFile(filePath, `crash report ${entry.name}`);
      return {
        name: entry.name,
        size: file.info.size,
        modified_at_milliseconds: Math.floor(file.info.mtimeMs),
        sha256: sha256(file.bytes),
      };
    })
    .sort((left, right) => left.name.localeCompare(right.name));
  if (!sameJSON(currentCrashInventory, crashEvidence.final)) {
    throw new TypeError('live crash-report inventory differs from the clean final scan');
  }
}

async function verifyLiveControllerRuntime(contract, inspectorStage) {
  const build = contract.controller_build;
  const executable = readStableRegularFile(build.executable_path, 'certification controller');
  if (sha256(executable.bytes) !== build.executable_sha256) {
    throw new TypeError('certification controller bytes differ from the contract');
  }
  const controllerPath = fs.realpathSync(build.executable_path);
  const diskIdentity = await inspectCodeIdentity({
    inspectorStage,
    subject: {
      kind: 'executable', executable_path: controllerPath, expected_team_id: build.team_id,
    },
    expected: {
      kind: 'executable',
      executablePath: controllerPath,
      executableSHA256: build.executable_sha256,
      codeSignatureHash: inspectorStage.codeSignatureHash,
      teamID: build.team_id,
      sourceCommit: build.source_commit,
    },
    label: 'certification controller file',
  });
  if (diskIdentity.team_id !== build.team_id) {
    throw new TypeError('certification controller file has the wrong signing team');
  }
  for (const entry of contract.controlled_targets) {
    const liveIdentity = await inspectCodeIdentity({
      inspectorStage,
      subject: {
        kind: 'process',
        process_identifier: entry.controller.pid,
        process_start_identity: entry.controller.start_identity,
        expected_team_id: build.team_id,
      },
      expected: {
        kind: 'process',
        process: entry.controller,
        executablePath: controllerPath,
        executableSHA256: null,
        codeSignatureHash: entry.controller.code_signature_hash,
        teamID: build.team_id,
        sourceCommit: build.source_commit,
      },
      label: `controller ${entry.controller_id} process`,
    });
    if (liveIdentity.executable_path !== controllerPath
        || liveIdentity.code_signature_hash !== entry.controller.code_signature_hash
        || diskIdentity.code_signature_hash !== liveIdentity.code_signature_hash
        || liveIdentity.team_id !== build.team_id) {
      throw new TypeError(`controller ${entry.controller_id} build or process generation drifted`);
    }
  }
}

async function verifyLiveForegroundObserverRuntime(contract, evidence, inspectorStage) {
  const plan = evidence.monitor_evidence.foreground_plan;
  const build = plan.observer_build;
  if (!sameJSON(build, contract.controller_build)) {
    throw new TypeError('foreground observer build differs from the source-owned controller build');
  }
  const controllerPath = fs.realpathSync(build.executable_path);
  const liveIdentity = await inspectCodeIdentity({
    inspectorStage,
    subject: {
      kind: 'process',
      process_identifier: plan.observer.pid,
      process_start_identity: plan.observer.start_identity,
      expected_team_id: build.team_id,
    },
    expected: {
      kind: 'process',
      process: plan.observer,
      executablePath: controllerPath,
      executableSHA256: null,
      codeSignatureHash: plan.observer.code_signature_hash,
      teamID: build.team_id,
      sourceCommit: build.source_commit,
    },
    label: 'foreground semantic observer process',
  });
  const diskIdentity = await inspectCodeIdentity({
    inspectorStage,
    subject: {
      kind: 'executable', executable_path: controllerPath, expected_team_id: build.team_id,
    },
    expected: {
      kind: 'executable',
      executablePath: controllerPath,
      executableSHA256: build.executable_sha256,
      codeSignatureHash: inspectorStage.codeSignatureHash,
      teamID: build.team_id,
      sourceCommit: build.source_commit,
    },
    label: 'foreground semantic observer file',
  });
  if (liveIdentity.executable_path !== controllerPath
      || liveIdentity.code_signature_hash !== plan.observer.code_signature_hash
      || diskIdentity.code_signature_hash !== liveIdentity.code_signature_hash
      || diskIdentity.team_id !== liveIdentity.team_id
      || liveIdentity.team_id !== build.team_id) {
    throw new TypeError('foreground semantic observer build or process generation drifted');
  }
}

function ownerPrivateSocketSnapshot(socketPath, label) {
  const info = fs.lstatSync(socketPath);
  if (!info.isSocket() || info.isSymbolicLink()
      || (typeof process.geteuid === 'function' && info.uid !== process.geteuid())
      || (info.mode & 0o077) !== 0) {
    throw new TypeError(`${label} must be one owner-private Unix socket`);
  }
  return { device: info.dev, inode: info.ino };
}

function liveAttestationProcess(processReceipt) {
  return {
    pid: processReceipt.pid,
    start_identity: processReceipt.start_identity,
    code_signature_hash: processReceipt.code_signature_hash,
  };
}

function requirePIDAttestationInspectorBinding(contract, evidence, inspectorStage) {
  const controllerCDHashes = new Set(contract.controlled_targets.map((entry) => (
    entry.controller.code_signature_hash
  )));
  const observerCDHash = evidence.monitor_evidence.foreground_plan.observer.code_signature_hash;
  if (inspectorStage.executableSHA256 !== contract.controller_build.executable_sha256
      || inspectorStage.teamID !== contract.controller_build.team_id
      || inspectorStage.sourceCommit !== contract.controller_build.source_commit
      || controllerCDHashes.size !== 1
      || !controllerCDHashes.has(inspectorStage.codeSignatureHash)
      || observerCDHash !== inspectorStage.codeSignatureHash) {
    throw new TypeError('PID-attestation inspector differs from the exact controller build and live processes');
  }
}

export async function runStagedPIDAttestationCommand({
  inspectorStage,
  planPath,
  expectedOutputPath,
  releasePath,
  executionNonce,
  label,
  runner = spawnSync,
  spawnChild = spawn,
  signalProcess = process.kill.bind(process),
  waitForStopped = waitForStoppedProcess,
}) {
  assertCodeIdentityInspectorStage(inspectorStage);
  const child = spawnChild(inspectorStage.executable, ['--attest-monitor', planPath], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const childState = { exited: false, code: null, signal: null, error: null };
  let resolveCompletion;
  const completionPromise = new Promise((resolve) => {
    resolveCompletion = resolve;
  });
  if (child && typeof child.once === 'function') {
    child.once('error', (error) => {
      childState.error = error;
      childState.exited = true;
      resolveCompletion();
    });
    child.once('exit', (code, signal) => {
      childState.code = code;
      childState.signal = signal;
      childState.exited = true;
    });
    child.once('close', (code, signal) => {
      childState.code ??= code;
      childState.signal ??= signal;
      childState.exited = true;
      resolveCompletion();
    });
  } else {
    childState.error = new TypeError(`${label} challenge process is unavailable`);
    childState.exited = true;
    resolveCompletion();
  }
  let stdout = '';
  let stderr = '';
  let stopped = false;
  try {
    if (!positiveInteger(child?.pid) || !child.stdout || !child.stderr) {
      throw new TypeError(`${label} challenge failed`);
    }
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    await waitForInspectorReceipt(expectedOutputPath, childState, 15_000);
    signalProcess(child.pid, 'SIGSTOP');
    stopped = true;
    await waitForStopped(child.pid, runner);
    assertCodeIdentityInspectorStage(inspectorStage);
    verifyAppleSigningRequirement(`+${child.pid}`, inspectorStage.teamID, `${label} live child`, runner);
    assertCodeIdentityInspectorStage(inspectorStage);
    const liveIdentity = displayCodeSignatureMetadata(`+${child.pid}`, `${label} live child`, runner);
    assertCodeIdentityInspectorStage(inspectorStage);
    let liveExecutable;
    try {
      liveExecutable = fs.realpathSync(liveIdentity.executable);
    } catch {
      throw new TypeError(`${label} live child executable path is unavailable`);
    }
    assertCodeIdentityInspectorStage(inspectorStage);
    const liveSourceCommit = embeddedSourceCommit(liveExecutable, `${label} live child`, { runner });
    assertCodeIdentityInspectorStage(inspectorStage);
    if (liveExecutable !== inspectorStage.executable
        || liveIdentity.team_id !== inspectorStage.teamID
        || liveIdentity.code_signature_hash !== inspectorStage.codeSignatureHash
        || liveSourceCommit !== inspectorStage.sourceCommit) {
      throw new TypeError(`${label} live child differs from the retained inspector stage`);
    }
    writeOwnerPrivateOutput(releasePath, `${JSON.stringify({
      version: 1,
      execution_nonce: executionNonce,
      phase: 'release',
    }, null, 2)}\n`);
    signalProcess(child.pid, 'SIGCONT');
    stopped = false;
    await waitForReleasedInspectorExit(completionPromise, label);
    assertCodeIdentityInspectorStage(inspectorStage);
    if (childState.error || childState.code !== 0 || childState.signal !== null) {
      throw new TypeError(`${label} challenge failed: ${stderr.trim()}`);
    }
    let envelope;
    try {
      envelope = JSON.parse(stdout);
    } catch {
      throw new TypeError(`${label} challenge result is not JSON`);
    }
    if (!exactKeys(envelope, ['receipt', 'result']) || envelope.result !== 'passed'
        || envelope.receipt !== expectedOutputPath) {
      throw new TypeError(`${label} challenge result is not bound to its staged child receipt`);
    }
    return { pid: child.pid, envelope };
  } finally {
    if (positiveInteger(child?.pid) && childState.exited !== true) {
      try { if (stopped) signalProcess(child.pid, 'SIGCONT'); } catch {}
      try { signalProcess(child.pid, 'SIGTERM'); } catch {}
      try { await waitForReleasedInspectorExit(completionPromise, label); } catch {}
    }
  }
}

export function makeLivePIDAttestationPlan({
  contract,
  responseKind,
  socketPath,
  expectedProcess,
  temporaryDirectory,
  outputPath,
  releasePath,
}) {
  return {
    version: 1,
    execution_nonce: contract.execution_nonce,
    monitor_instance_id: contract.monitor_binding.monitor_instance_id,
    socket_path: socketPath,
    expected_peer: structuredClone(expectedProcess),
    response_kind: responseKind,
    artifacts_directory: temporaryDirectory,
    output_path: outputPath,
    release_path: releasePath,
    timeout_milliseconds: 10_000,
    maximum_response_bytes: 1024 * 1024,
  };
}

async function runLivePIDAttestation(contract, evidence, responseKind, inspectorStage) {
  requirePIDAttestationInspectorBinding(contract, evidence, inspectorStage);
  const monitor = responseKind === 'monitor';
  const foregroundPlan = evidence.monitor_evidence.foreground_plan;
  const socketPath = monitor
    ? contract.monitor_binding.monitor_attestation_socket_path
    : foregroundPlan.observer_attestation_socket_path;
  const expectedProcess = monitor
    ? liveAttestationProcess(contract.monitor_binding.monitor_process)
    : foregroundPlan.observer;
  const label = monitor ? 'live monitor attestation' : 'foreground observer attestation';
  const socketBefore = ownerPrivateSocketSnapshot(socketPath, `${label} endpoint`);
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'peekaboo-pid-attestation-'));
  fs.chmodSync(temporaryDirectory, 0o700);
  const planPath = path.join(temporaryDirectory, 'plan.json');
  const outputPath = path.join(temporaryDirectory, 'response.json');
  const releasePath = path.join(temporaryDirectory, 'release.json');
  const plan = makeLivePIDAttestationPlan({
    contract,
    responseKind,
    socketPath,
    expectedProcess,
    temporaryDirectory,
    outputPath,
    releasePath,
  });
  try {
    writeOwnerPrivateOutput(planPath, `${JSON.stringify(plan, null, 2)}\n`);
    await runStagedPIDAttestationCommand({
      inspectorStage,
      planPath,
      expectedOutputPath: outputPath,
      releasePath,
      executionNonce: contract.execution_nonce,
      label,
    });
    const response = parseJSON(readStablePrivateFile(outputPath, `${label} response`), label);
    const commonKeys = [
      'version', 'execution_nonce', 'monitor_instance_id', 'challenge',
    ];
    const responseKeys = monitor
      ? [...commonKeys, 'monitor', 'monitor_evidence_sha256']
      : [
        ...commonKeys, 'observer', 'witness_sha256', 'observation_file_sha256',
        'restoration_file_sha256', 'before_value_sha256', 'expected_value_sha256',
        'observed_value_sha256', 'restored_value_sha256',
      ];
    if (!exactKeys(response, responseKeys)
        || response.version !== 1
        || response.execution_nonce !== contract.execution_nonce
        || response.monitor_instance_id !== contract.monitor_binding.monitor_instance_id
        || !HEX64.test(response.challenge ?? '')) {
      throw new TypeError(`${label} response is not one closed run-bound challenge response`);
    }
    if (monitor) {
      if (!sameJSON(response.monitor, expectedProcess)
          || response.monitor_evidence_sha256
            !== aggregateSHA256('monitor-evidence', evidence.monitor_evidence)) {
        throw new TypeError('live monitor attestation differs from the contracted process and corpus');
      }
    } else {
      const witnessBytes = readStablePrivateFile(foregroundPlan.witness_path, 'foreground witness');
      const witnessDocument = parseJSON(witnessBytes, 'foreground witness');
      const witness = evidence.foreground_postcondition;
      if (!sameJSON(witnessDocument, witness)
          || !sameJSON(response.observer, expectedProcess)
          || response.witness_sha256 !== sha256(witnessBytes)
          || response.observation_file_sha256 !== witness.observation_file_sha256
          || response.restoration_file_sha256 !== witness.restoration_file_sha256
          || response.before_value_sha256 !== witness.before_value_sha256
          || response.expected_value_sha256 !== witness.expected_value_sha256
          || response.observed_value_sha256 !== witness.observed_value_sha256
          || response.restored_value_sha256 !== witness.restored_value_sha256) {
        throw new TypeError('foreground observer attestation differs from the contracted witness');
      }
    }
    const socketAfter = ownerPrivateSocketSnapshot(socketPath, `${label} endpoint`);
    if (!sameJSON(socketAfter, socketBefore)) {
      throw new TypeError(`${label} endpoint changed during its PID-bound challenge`);
    }
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

async function verifyLivePIDAttestations(contract, evidence, inspectorStage) {
  await runLivePIDAttestation(contract, evidence, 'monitor', inspectorStage);
  await runLivePIDAttestation(contract, evidence, 'observer', inspectorStage);
}

function readForegroundWitnessFile(filePath, expectedSHA256, label) {
  const info = fs.lstatSync(filePath);
  if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1
      || (typeof process.getuid === 'function' && info.uid !== process.getuid())
      || (info.mode & 0o077) !== 0) {
    throw new TypeError(`${label} must be one owner-private regular file`);
  }
  const bytes = readStableRegularFile(filePath, label).bytes;
  if (sha256(bytes) !== expectedSHA256) throw new TypeError(`${label} bytes differ from the contract`);
  return parseJSON(bytes, label);
}

function verifyLiveForegroundPostconditionRuntime(contract, evidence) {
  const witness = evidence.foreground_postcondition;
  const validateDocument = (value, expectedValueSHA256, label) => {
    if (!exactKeys(value, [
      'version', 'execution_nonce', 'request_marker', 'target', 'observer',
      'observed_value_sha256', 'observed_at_milliseconds',
    ]) || value.version !== 1
        || value.execution_nonce !== contract.execution_nonce
        || value.request_marker !== witness.request_marker
        || !sameJSON(value.target, witness.target)
        || !sameJSON(value.observer, witness.observer)
        || value.observed_value_sha256 !== expectedValueSHA256
        || !milliseconds(value.observed_at_milliseconds)) {
      throw new TypeError(`${label} is not the contracted independent readback`);
    }
    return value;
  };
  const observation = validateDocument(readForegroundWitnessFile(
    witness.observation_path,
    witness.observation_file_sha256,
    'foreground observation witness',
  ), witness.observed_value_sha256, 'foreground observation witness');
  const restoration = validateDocument(readForegroundWitnessFile(
    witness.restoration_path,
    witness.restoration_file_sha256,
    'foreground restoration witness',
  ), witness.restored_value_sha256, 'foreground restoration witness');
  if (observation.observed_at_milliseconds < witness.interval.started_at_milliseconds
      || observation.observed_at_milliseconds > witness.interval.completed_at_milliseconds
      || restoration.observed_at_milliseconds < observation.observed_at_milliseconds
      || restoration.observed_at_milliseconds > contract.interval.completed_at_milliseconds) {
    throw new TypeError('foreground observation/restoration timestamps are outside the live run');
  }
}

function liveFirstPartyValidator(stage, contract) {
  return async ({ bundle }) => {
    if (typeof bundle.path !== 'string' || !path.isAbsolute(bundle.path)) {
      throw new TypeError('live validation requires the securely read absolute bundle path');
    }
    const args = [
      'bridge', 'receipt', 'validate',
      '--bundle', bundle.path,
      '--bridge-socket', contract.socket_endpoint.path,
      ...contract.first_party_validator.trusted_host_team_ids.flatMap((teamID) => (
        ['--trusted-host-team-id', teamID]
      )),
      '--json',
    ];
    assertStagedExecutable(stage, contract.first_party_validator.executable_sha256);
    const run = spawnSync(stage.executable, args, {
      encoding: 'utf8',
      timeout: 30_000,
      maxBuffer: 16 * 1024 * 1024,
    });
    assertStagedExecutable(stage, contract.first_party_validator.executable_sha256);
    if (run.status !== 0) throw new TypeError('authenticated live-listener validation exited nonzero');
    let envelope;
    try {
      envelope = JSON.parse(run.stdout);
    } catch {
      throw new TypeError('authenticated live-listener validation did not return JSON');
    }
    if (!exactKeys(envelope, ['success', 'data', 'debug_logs']) || envelope.success !== true
        || !isPlainObject(envelope.data) || !Array.isArray(envelope.debug_logs)
        || envelope.debug_logs.some((entry) => typeof entry !== 'string')) {
      throw new TypeError('authenticated live-listener validation returned an invalid envelope');
    }
    return envelope.data;
  };
}

async function executeFinalization(args, catalog, catalogBytes, artifacts) {
  const inspectorStage = await stageCodeIdentityInspector(
    artifacts.contract.controller_build.executable_path,
    catalog.trusted_controller_team_ids,
    artifacts.contract.controller_build.source_commit,
  );
  try {
    if (inspectorStage.executableSHA256 !== artifacts.contract.controller_build.executable_sha256
        || inspectorStage.teamID !== artifacts.contract.controller_build.team_id) {
      throw new TypeError('staged code-identity inspector differs from the contracted controller build');
    }
    verifyLiveSocket(artifacts.contract, artifacts.evidence);
    await verifyLiveMonitorRuntime(artifacts.contract, artifacts.evidence, inspectorStage);
    await verifyLiveControllerRuntime(artifacts.contract, inspectorStage);
    await verifyLiveForegroundObserverRuntime(artifacts.contract, artifacts.evidence, inspectorStage);
    verifyLiveForegroundPostconditionRuntime(artifacts.contract, artifacts.evidence);
    await verifyLivePIDAttestations(artifacts.contract, artifacts.evidence, inspectorStage);
    const stage = stageFirstPartyExecutable(args.peekaboo, catalog, artifacts.contract);
    try {
      const summary = await finalizeLiveMultiTargetCertification({
        catalog,
        catalogFileSHA256: sha256(catalogBytes),
        ...artifacts,
        firstPartyValidator: liveFirstPartyValidator(stage, artifacts.contract),
      });
      verifyLiveSocket(artifacts.contract, artifacts.evidence);
      await verifyLiveMonitorRuntime(artifacts.contract, artifacts.evidence, inspectorStage);
      await verifyLiveControllerRuntime(artifacts.contract, inspectorStage);
      await verifyLiveForegroundObserverRuntime(artifacts.contract, artifacts.evidence, inspectorStage);
      verifyLiveForegroundPostconditionRuntime(artifacts.contract, artifacts.evidence);
      await verifyLivePIDAttestations(artifacts.contract, artifacts.evidence, inspectorStage);
      const after = readCertificationArtifacts(args.artifacts);
      if (!sameJSON(after.contract, artifacts.contract)
          || !sameJSON(after.manifest, artifacts.manifest)
          || !sameJSON(after.evidence, artifacts.evidence)
          || !sameJSON(
            after.bundles.map((entry) => ({ file: entry.file, sha256: entry.sha256 })),
            artifacts.bundles.map((entry) => ({ file: entry.file, sha256: entry.sha256 })),
          )) {
        throw new TypeError('certification artifact corpus changed during finalization');
      }
      const output = `${JSON.stringify(summary, null, 2)}\n`;
      if (args.output) writeOwnerPrivateOutput(args.output, output);
      else process.stdout.write(output);
      if (!summary[LIVE_CERTIFICATION_RESULT]) process.exitCode = 1;
    } finally {
      removeStagedExecutable(stage);
    }
  } finally {
    removeCodeIdentityInspectorStage(inspectorStage);
  }
}

async function runCLI() {
  const args = parseArguments(process.argv.slice(2));
  if (args.action === 'help') {
    process.stdout.write(CLI_HELP);
    return;
  }
  if (args.action === 'version') {
    process.stdout.write(`peekaboo-certify ${CLI_VERSION}\n`);
    return;
  }
  if (args.command === 'digest') {
    const loaded = loadDigestSpec();
    if (args.spec === true) {
      process.stdout.write(loaded.bytes);
      if (!loaded.bytes.toString('utf8').endsWith('\n')) process.stdout.write('\n');
      return;
    }
    const input = readStableRegularFile(path.resolve(args.input), 'digest input').bytes;
    const result = computeDigestClaim({
      kindID: args.kind,
      inputBytes: input,
      projection: args.projection ?? null,
    });
    process.stdout.write(`${JSON.stringify({
      version: 1,
      digest_spec_sha256: BUILTIN_DIGEST_SPEC_SHA256,
      kind: result.kind.id,
      projection: result.kind.projection,
      algorithm: 'sha256',
      domain: result.kind.domain,
      digest: result.digest,
    }, null, 2)}\n`);
    return;
  }
  const catalogPath = path.join(path.dirname(fileURLToPath(import.meta.url)), 'multi-target-certification-catalog.json');
  const catalogBytes = fs.readFileSync(catalogPath);
  if (sha256(catalogBytes) !== BUILTIN_CATALOG_SHA256) {
    throw new TypeError('built-in source-controlled certification catalog digest is invalid');
  }
  const catalog = parseJSON(catalogBytes, 'catalog');
  if (args.command === 'verify-digests') {
    const artifacts = readCertificationArtifacts(args.artifacts);
    const summaryBytes = readStablePrivateFile(path.resolve(args.summary), 'certification summary');
    const summary = parseJSON(summaryBytes, 'certification summary');
    const result = verifyDigestClaims({ catalogBytes, artifacts, summary });
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    if (!result.success) process.exitCode = 1;
    return;
  }
  const sourceBinding = verifyCurrentBuildSourceBinding(
    catalog,
    path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..'),
  );
  if (args.command === 'prepare') {
    const controllerReceipts = readControllerReceiptDirectory(args['controller-receipts']);
    const bundles = readRawBundleDirectory(args.bundles);
    const monitorEvidenceBytes = readStablePrivateFile(
      path.resolve(args['monitor-evidence']),
      'live monitor evidence',
    );
    const monitorEvidence = parseJSON(monitorEvidenceBytes, 'live monitor evidence');
    const foregroundPostconditionBytes = readStablePrivateFile(
      path.resolve(args['foreground-postcondition']),
      'foreground postcondition witness',
    );
    const foregroundPostcondition = parseJSON(
      foregroundPostconditionBytes,
      'foreground postcondition witness',
    );
    const catalogSHA256 = sha256(catalogBytes);
    const socketPath = controllerReceipts[0]?.handshake?.socket_path;
    if (typeof socketPath !== 'string' || !controllerReceipts.every((receipt) => (
      receipt?.handshake?.socket_path === socketPath
    ))) {
      throw new TypeError('controller receipts do not bind one exact Bridge socket');
    }
    const socketEvidence = currentSocketEvidence(socketPath);
    const firstPartyValidator = inspectFirstPartyExecutable(args.peekaboo, catalog);
    const contract = makeLiveCertificationContract({
      catalog,
      catalogSHA256,
      controllerReceipts,
      bundles,
      monitorEvidence,
      firstPartyValidator,
      socketEndpoint: {
        path: socketEvidence.path,
        device: socketEvidence.device,
        inode: socketEvidence.inode,
      },
    });
    if (contract.current_build_source.commit !== sourceBinding.commit) {
      throw new TypeError('assembled contract does not match the finalizer clean Git HEAD');
    }
    const manifest = makeOperationManifest(catalog, catalogSHA256, contract, bundles);
    const evidence = {
      version: 2,
      certification_kind: LIVE_CERTIFICATION_KIND,
      execution_nonce: contract.execution_nonce,
      catalog_sha256: catalogSHA256,
      contract_sha256: canonicalSHA256(contract),
      operation_manifest_sha256: aggregateSHA256('operation-manifest', manifest),
      first_party_validator_executable_sha256: contract.first_party_validator.executable_sha256,
      socket_evidence: socketEvidence,
      source_evidence: structuredClone(contract.source),
      monitor_evidence: monitorEvidence,
      foreground_postcondition: foregroundPostcondition,
    };
    verifyLiveSocket(contract, evidence);
    createPreparedArtifacts(args.artifacts, contract, manifest, evidence, bundles);
  }
  const artifacts = readCertificationArtifacts(args.artifacts);
  if (artifacts.contract?.current_build_source?.commit !== sourceBinding.commit) {
    throw new TypeError('contract current-build commit differs from the finalizer clean Git HEAD');
  }
  await executeFinalization(args, catalog, catalogBytes, artifacts);
}

const invokedAsScript = (() => {
  if (!process.argv[1]) return false;
  try {
    return fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
  } catch {
    return false;
  }
})();
if (invokedAsScript) {
  runCLI().catch((error) => {
    process.stderr.write(`multi-target certification finalizer: ${error.message}\n`);
    process.exitCode = 2;
  });
}
