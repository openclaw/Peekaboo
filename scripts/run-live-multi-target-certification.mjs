#!/usr/bin/env node

import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  inspectCodeIdentity as inspectCodeIdentityWithNativeController,
  projectFinalizerSourceBytes,
  stageCodeIdentityInspector as stageNativeCodeIdentityInspector,
  verifyCurrentBuildSourceBinding,
} from './finalize-multi-target-certification.mjs';

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const SCRIPT_DIRECTORY = path.dirname(SCRIPT_PATH);
const DEFAULT_CATALOG_PATH = path.join(SCRIPT_DIRECTORY, 'multi-target-certification-catalog.json');
const DEFAULT_FINALIZER_PATH = path.join(SCRIPT_DIRECTORY, 'finalize-multi-target-certification.mjs');
const HEX40 = /^[0-9a-f]{40}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const POSITIVE_DECIMAL = /^[1-9][0-9]*$/;
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const UUID_V8 = /^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const UINT64_MAX = 0xffff_ffff_ffff_ffffn;
const MAXIMUM_FILE_BYTES = 16 * 1024 * 1024;
const POLL_MILLISECONDS = 25;
const REPOSITORY_ROOT = path.resolve(SCRIPT_DIRECTORY, '..');
const CONTROLLER_TYPING_DELAY_MILLISECONDS = 50;
const CONTROLLER_MUTATION_OVERLAP_MARGIN_SECONDS = 20;
const EXTERNAL_FOREGROUND_WINDOW_COUNT = 2;
const OPERATION_LIFECYCLE_MARGIN_SECONDS = 30;
const MAXIMUM_CONTROLLER_TEXT_BYTES = 4096;
const FINALIZER_INNER_BUNDLE_TIMEOUT_MILLISECONDS = 30_000;
const FINALIZER_IDENTITY_INSPECTION_COUNT = 15;
const FINALIZER_IDENTITY_RECEIPT_TIMEOUT_MILLISECONDS = 30_000;
const FINALIZER_PID_ATTESTATION_COUNT = 4;
const FINALIZER_PID_ATTESTATION_RECEIPT_TIMEOUT_MILLISECONDS = 15_000;
const FINALIZER_PROCESS_STOP_TIMEOUT_MILLISECONDS = 2_000;
const FINALIZER_CODESIGN_VERIFY_TIMEOUT_MILLISECONDS = 10_000;
const FINALIZER_CODESIGN_DISPLAY_TIMEOUT_MILLISECONDS = 10_000;
const FINALIZER_SOURCE_STAMP_TIMEOUT_MILLISECONDS = 20_000;
const FINALIZER_RELEASE_TIMEOUT_MILLISECONDS = 5_000;
const FINALIZER_STAGING_AND_SHUTDOWN_MARGIN_MILLISECONDS = 300_000;
const FINALIZER_IDENTITY_INSPECTION_TIMEOUT_MILLISECONDS =
  FINALIZER_IDENTITY_RECEIPT_TIMEOUT_MILLISECONDS
  + FINALIZER_PROCESS_STOP_TIMEOUT_MILLISECONDS
  + FINALIZER_CODESIGN_VERIFY_TIMEOUT_MILLISECONDS
  + FINALIZER_CODESIGN_DISPLAY_TIMEOUT_MILLISECONDS
  + FINALIZER_SOURCE_STAMP_TIMEOUT_MILLISECONDS
  + FINALIZER_RELEASE_TIMEOUT_MILLISECONDS;
const FINALIZER_PID_ATTESTATION_TIMEOUT_MILLISECONDS =
  FINALIZER_PID_ATTESTATION_RECEIPT_TIMEOUT_MILLISECONDS
  + FINALIZER_PROCESS_STOP_TIMEOUT_MILLISECONDS
  + FINALIZER_CODESIGN_VERIFY_TIMEOUT_MILLISECONDS
  + FINALIZER_CODESIGN_DISPLAY_TIMEOUT_MILLISECONDS
  + FINALIZER_SOURCE_STAMP_TIMEOUT_MILLISECONDS
  + FINALIZER_RELEASE_TIMEOUT_MILLISECONDS;
const FINALIZER_IDENTITY_RUNTIME_OVERHEAD_MILLISECONDS =
  (FINALIZER_IDENTITY_INSPECTION_COUNT * FINALIZER_IDENTITY_INSPECTION_TIMEOUT_MILLISECONDS)
  + (FINALIZER_PID_ATTESTATION_COUNT * FINALIZER_PID_ATTESTATION_TIMEOUT_MILLISECONDS)
  + FINALIZER_STAGING_AND_SHUTDOWN_MARGIN_MILLISECONDS;
const FINALIZER_INVOCATION_COUNT = 2;

const HELP = `\
Run one source-owned live multi-target Peekaboo certification.

Usage:
  run-live-multi-target-certification --plan OWNER_PRIVATE_PLAN.json

Options:
  --plan FILE   Closed owner-private live-run plan
  -h, --help    Show this help
  --version     Print the coordinator contract version

The coordinator creates a fresh nonce and run root, owns exactly two persistent
background controllers plus one observe-only semantic witness, brackets an explicit
bounded external Computer Use window with monitor fences, seals the live corpus, and
runs both prepare and final finalization. JSON lifecycle events are written to stdout;
diagnostics are written to stderr. Exit status is nonzero unless every live gate passes.
`;

class CoordinatorError extends Error {}

function isPlainObject(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function exactKeys(value, keys) {
  if (!isPlainObject(value)) return false;
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  return actual.length === expected.length && actual.every((key, index) => key === expected[index]);
}

function canonicalValue(value) {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
  if (typeof value === 'number') {
    if (!Number.isFinite(value) || Object.is(value, -0)
        || (Number.isInteger(value) && !Number.isSafeInteger(value))) {
      throw new CoordinatorError('canonical JSON excludes lossy or non-finite numbers');
    }
    return value;
  }
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (!isPlainObject(value)) throw new CoordinatorError('canonical JSON accepts only plain JSON values');
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalValue(value[key])]));
}

function canonicalBytes(value) {
  return Buffer.from(JSON.stringify(canonicalValue(value)), 'utf8');
}

function sameJSON(left, right) {
  try {
    return canonicalBytes(left).equals(canonicalBytes(right));
  } catch {
    return false;
  }
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

export async function inspectCodeIdentity(options) {
  try {
    return await inspectCodeIdentityWithNativeController(options);
  } catch (error) {
    throw new CoordinatorError(error.message);
  }
}

async function stageCodeIdentityInspector(...args) {
  try {
    return await stageNativeCodeIdentityInspector(...args);
  } catch (error) {
    throw new CoordinatorError(error.message);
  }
}

function deriveCurrentBuildSource(catalog, testRuntime) {
  if (!testRuntime) {
    try {
      return verifyCurrentBuildSourceBinding(catalog, REPOSITORY_ROOT);
    } catch (error) {
      throw new CoordinatorError(error.message);
    }
  }
  const head = runSync(
    '/usr/bin/git',
    ['-C', REPOSITORY_ROOT, 'rev-parse', '--verify', 'HEAD'],
    'test-runtime Git HEAD derivation',
  ).stdout.trim();
  if (!HEX40.test(head)) throw new CoordinatorError('test-runtime Git HEAD is not one exact commit');
  return { commit: head, repository_root: REPOSITORY_ROOT };
}

function requirePeekabooSourceCommit(executable, expectedCommit) {
  const run = runSync(executable, ['--version', '--json'], 'Peekaboo source-stamp preflight');
  let version;
  try {
    version = JSON.parse(run.stdout);
  } catch {
    throw new CoordinatorError('Peekaboo source-stamp preflight did not return JSON');
  }
  if (version?.success !== true || version?.data?.sourceCommit !== expectedCommit) {
    throw new CoordinatorError('Peekaboo validator source stamp differs from the clean Git HEAD');
  }
}

function nativeMachOArchitecture(nodeArchitecture = process.arch) {
  if (nodeArchitecture === 'arm64') return 'arm64';
  if (nodeArchitecture === 'x64') return 'x86_64';
  throw new CoordinatorError(`unsupported native Mach-O architecture: ${nodeArchitecture}`);
}

export function embeddedSourceCommit(executable, label, {
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
    throw new CoordinatorError(`${label} has no embedded info plist for ${architecture}`);
  }
  const plist = runner('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '-'], {
    input: section.stdout,
    encoding: 'utf8',
    timeout: 10_000,
    maxBuffer: 4 * 1024 * 1024,
  });
  if (plist.error || plist.status !== 0) {
    throw new CoordinatorError(`${label} source-stamp preflight is unreadable`);
  }
  let value;
  try {
    value = JSON.parse(plist.stdout);
  } catch {
    throw new CoordinatorError(`${label} source-stamp preflight is unreadable`);
  }
  if (!HEX40.test(value?.PeekabooSourceCommit ?? '')) {
    throw new CoordinatorError(`${label} has no exact embedded source stamp`);
  }
  return value.PeekabooSourceCommit;
}

function aggregateSHA256(domain, value) {
  return sha256(Buffer.concat([
    Buffer.from(`peekaboo.multi-target-certification.${domain}.v2\0`, 'utf8'),
    canonicalBytes(value),
  ]));
}

function monitorBaselineProjection(evidence) {
  return {
    execution_nonce: evidence.execution_nonce,
    monitor_instance_id: evidence.monitor_instance_id,
    monitor_attestation_socket_path: evidence.monitor_attestation_socket_path,
    producer_set: evidence.producer_sets.baseline,
    baseline_sample: evidence.baseline_sample,
    foreground_plan: evidence.foreground_plan,
    crash_baseline: {
      directory: evidence.crash_evidence.directory,
      prefixes: evidence.crash_evidence.prefixes,
      baseline: evidence.crash_evidence.baseline,
    },
  };
}

function monitorHistoryProjection(evidence) {
  return {
    execution_nonce: evidence.execution_nonce,
    monitor_instance_id: evidence.monitor_instance_id,
    monitor_attestation_socket_path: evidence.monitor_attestation_socket_path,
    baseline_commitment_sha256: evidence.baseline_commitment_sha256,
    producer_sets: evidence.producer_sets,
    fences: evidence.fences.map((entry) => {
      const heartbeat = structuredClone(entry.heartbeat);
      delete heartbeat.historyCommitmentSHA256;
      return { name: entry.name, heartbeat };
    }),
    baseline_sample: evidence.baseline_sample,
    final_sample: evidence.final_sample,
    foreground_plan: evidence.foreground_plan,
    violation_records: evidence.violation_records,
    contamination_records: evidence.contamination_records,
    crash_evidence: evidence.crash_evidence,
    restoration: evidence.restoration,
  };
}

function parseArguments(argv) {
  if (argv.length === 1 && ['-h', '--help'].includes(argv[0])) return { action: 'help' };
  if (argv.length === 1 && argv[0] === '--version') return { action: 'version' };
  if (argv.length === 2 && argv[0] === '--plan') return { action: 'run', plan: argv[1] };
  throw new CoordinatorError(HELP);
}

function requireAbsolute(value, label) {
  if (typeof value !== 'string' || !path.isAbsolute(value) || value.includes('\0')) {
    throw new CoordinatorError(`${label} must be one absolute path`);
  }
  return path.resolve(value);
}

function requireSafeID(value, label) {
  if (typeof value !== 'string' || !/^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/.test(value)) {
    throw new CoordinatorError(`${label} must be one safe lowercase identifier`);
  }
}

function canonicalPositiveDecimal(value) {
  if (typeof value !== 'string' || !POSITIVE_DECIMAL.test(value)) return false;
  try {
    const parsed = BigInt(value);
    return parsed > 0n && parsed <= UINT64_MAX && String(parsed) === value;
  } catch {
    return false;
  }
}

function safeInteger(value) {
  return Number.isSafeInteger(value) && !Object.is(value, -0);
}

function finiteLosslessNumber(value) {
  return typeof value === 'number'
    && Number.isFinite(value)
    && !Object.is(value, -0)
    && (!Number.isInteger(value) || Number.isSafeInteger(value));
}

function positiveSafeInteger(value) {
  return safeInteger(value) && value > 0;
}

function nonnegativeSafeInteger(value) {
  return safeInteger(value) && value >= 0;
}

function heartbeatClockDriftMicroseconds(current, previous) {
  const wallDeltaMicroseconds = (
    BigInt(current.wallClockMilliseconds) - BigInt(previous.wallClockMilliseconds)
  ) * 1000n;
  const monotonicDelta = BigInt(current.monotonicMicroseconds) - BigInt(previous.monotonicMicroseconds);
  const difference = wallDeltaMicroseconds - monotonicDelta;
  return difference < 0n ? -difference : difference;
}

function requirePrivateDirectory(directory, label, { empty = false } = {}) {
  const info = fs.lstatSync(directory);
  if (!info.isDirectory() || info.isSymbolicLink() || (info.mode & 0o077) !== 0
      || (typeof process.geteuid === 'function' && info.uid !== process.geteuid())) {
    throw new CoordinatorError(`${label} must be one owner-private directory`);
  }
  if (empty && fs.readdirSync(directory).length !== 0) {
    throw new CoordinatorError(`${label} must be empty`);
  }
}

function requirePrivateFile(filePath, label, maximumBytes = MAXIMUM_FILE_BYTES) {
  const info = fs.lstatSync(filePath);
  if (!info.isFile() || info.isSymbolicLink() || info.nlink !== 1 || info.size > maximumBytes
      || (info.mode & 0o077) !== 0
      || (typeof process.geteuid === 'function' && info.uid !== process.geteuid())) {
    throw new CoordinatorError(`${label} must be one bounded owner-private regular file`);
  }
  return fs.readFileSync(filePath);
}

function requireExecutable(filePath, label) {
  const absolute = requireAbsolute(filePath, label);
  const info = fs.statSync(absolute);
  if (!info.isFile() || (info.mode & 0o111) === 0) {
    throw new CoordinatorError(`${label} must be executable`);
  }
  return fs.realpathSync(absolute);
}

function retainRegularFile(filePath, label) {
  const absolute = fs.realpathSync(requireAbsolute(filePath, label));
  const descriptor = fs.openSync(absolute, 'r');
  try {
    const before = fs.fstatSync(descriptor);
    if (!before.isFile() || before.nlink !== 1 || before.size > MAXIMUM_FILE_BYTES
        || (typeof process.geteuid === 'function' && before.uid !== process.geteuid())) {
      throw new CoordinatorError(`${label} must be one bounded owner-owned regular file`);
    }
    const bytes = fs.readFileSync(descriptor);
    const after = fs.fstatSync(descriptor);
    if (before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size
        || before.mtimeMs !== after.mtimeMs || bytes.length !== before.size) {
      throw new CoordinatorError(`${label} changed while its exact bytes were retained`);
    }
    return { path: absolute, bytes, sha256: sha256(bytes) };
  } finally {
    fs.closeSync(descriptor);
  }
}

function retainFinalizerSource(finalizerPath, catalog, testRuntime) {
  const retained = retainRegularFile(finalizerPath, 'certification finalizer source');
  if (!testRuntime && sha256(projectFinalizerSourceBytes(retained.bytes))
      !== catalog.current_build_source.finalizer.projected_sha256) {
    throw new CoordinatorError('retained finalizer source differs from the source-controlled binding');
  }
  return retained;
}

function canonicalDiagnosticReportsDirectory(configuredPath) {
  const absolute = requireAbsolute(configuredPath, 'diagnostic reports directory');
  const canonical = fs.realpathSync(absolute);
  if (absolute !== configuredPath || canonical !== absolute) {
    throw new CoordinatorError('diagnostic reports directory must be one canonical non-symlink path');
  }
  requirePrivateDirectory(canonical, 'diagnostic reports directory');
  return canonical;
}

function parseJSON(bytes, label) {
  try {
    const value = JSON.parse(bytes);
    if (!isPlainObject(value)) throw new Error('not an object');
    return value;
  } catch (error) {
    throw new CoordinatorError(`${label} is not one JSON object: ${error.message}`);
  }
}

function writePrivateJSON(filePath, value) {
  const parent = path.dirname(filePath);
  requirePrivateDirectory(parent, `parent for ${path.basename(filePath)}`);
  const temporary = path.join(parent, `.${path.basename(filePath)}.${randomUUID()}.tmp`);
  const bytes = Buffer.from(`${JSON.stringify(value, null, 2)}\n`, 'utf8');
  const descriptor = fs.openSync(temporary, 'wx', 0o600);
  try {
    fs.writeFileSync(descriptor, bytes);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  fs.renameSync(temporary, filePath);
  fs.chmodSync(filePath, 0o600);
}

function readPrivateJSON(filePath, label) {
  return parseJSON(requirePrivateFile(filePath, label), label);
}

function emit(event) {
  process.stdout.write(`${JSON.stringify(event)}\n`);
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function childFailure(child, label) {
  if (child.spawnError) {
    throw new CoordinatorError(`${label} failed to spawn: ${child.spawnError.message}`);
  }
  if (child.exitCode !== null) {
    const diagnostic = child.capturedStderr?.trim();
    throw new CoordinatorError(
      `${label} exited before its owner release (status ${child.exitCode})${diagnostic ? `: ${diagnostic}` : ''}`,
    );
  }
  if (child.signalCode !== null) {
    throw new CoordinatorError(`${label} was terminated before its owner release (${child.signalCode})`);
  }
}

async function waitFor(label, deadline, predicate, children = []) {
  while (Date.now() < deadline) {
    for (const entry of children) childFailure(entry.child, entry.label);
    const value = await predicate();
    if (value !== undefined && value !== false && value !== null) return value;
    await sleep(POLL_MILLISECONDS);
  }
  throw new CoordinatorError(`timed out waiting for ${label}`);
}

function spawnOwned(executable, args, label) {
  const child = spawn(executable, args, {
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env },
  });
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.capturedStdout = '';
  child.capturedStderr = '';
  child.stdout.on('data', (chunk) => { child.capturedStdout += chunk; });
  child.stderr.on('data', (chunk) => { child.capturedStderr += chunk; });
  child.once('error', (error) => { child.spawnError = error; });
  child.ownerClosed = false;
  child.once('close', () => { child.ownerClosed = true; });
  child.ownerLabel = label;
  return child;
}

async function waitForExit(child, label, timeoutMilliseconds) {
  if (child.spawnError) throw new CoordinatorError(`${label} failed to spawn: ${child.spawnError.message}`);
  if (child.ownerClosed) {
    if (child.exitCode !== 0) throw new CoordinatorError(`${label} exited with status ${child.exitCode}`);
    return;
  }
  const result = await Promise.race([
    new Promise((resolve) => child.once('close', (code, signal) => resolve({ code, signal }))),
    new Promise((resolve) => child.once('error', (error) => resolve({ error }))),
    sleep(timeoutMilliseconds).then(() => ({ timeout: true })),
  ]);
  if (result.timeout) throw new CoordinatorError(`${label} did not exit after release`);
  if (result.error) throw new CoordinatorError(`${label} failed: ${result.error.message}`);
  if (result.code !== 0) {
    throw new CoordinatorError(
      `${label} exited with status ${result.code ?? result.signal}: ${child.capturedStderr.trim()}`,
    );
  }
}

async function terminateChild(child, label) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  child.kill('SIGTERM');
  const result = await Promise.race([
    new Promise((resolve) => child.once('exit', resolve)),
    sleep(1000).then(() => 'timeout'),
  ]);
  if (result === 'timeout' && child.exitCode === null && child.signalCode === null) {
    child.kill('SIGKILL');
    await Promise.race([new Promise((resolve) => child.once('exit', resolve)), sleep(1000)]);
  }
  if (child.exitCode === null && child.signalCode === null) {
    throw new CoordinatorError(`${label} survived bounded TERM/KILL cleanup`);
  }
}

function runSync(executable, args, label, timeout = 15_000) {
  const result = spawnSync(executable, args, {
    encoding: 'utf8',
    timeout,
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    throw new CoordinatorError(
      `${label} failed: ${result.error?.message ?? result.stderr?.trim() ?? `status ${result.status}`}`,
    );
  }
  return result;
}

function targetIsValid(value, controllerShape = false) {
  const keys = controllerShape
    ? ['process_identifier', 'process_start_identity_decimal', 'window_id', 'bounds', 'is_minimized', 'click_point']
    : ['scope', 'pid', 'start_identity', 'window_id', 'bounds', 'is_minimized'];
  const pid = controllerShape ? value?.process_identifier : value?.pid;
  const start = controllerShape ? value?.process_start_identity_decimal : value?.start_identity;
  const boundsValues = value?.bounds ? Object.values(value.bounds) : [];
  return exactKeys(value, keys)
    && (!controllerShape ? value.scope === 'window' : true)
    && positiveSafeInteger(pid)
    && canonicalPositiveDecimal(start)
    && positiveSafeInteger(value.window_id) && value.window_id <= 0xffff_ffff
    && exactKeys(value.bounds, ['x', 'y', 'width', 'height'])
    && boundsValues.every(finiteLosslessNumber)
    && value.bounds.width > 0 && value.bounds.height > 0
    && (value.is_minimized === null || typeof value.is_minimized === 'boolean')
    && (!controllerShape || (exactKeys(value.click_point, ['x', 'y'])
      && finiteLosslessNumber(value.click_point.x) && finiteLosslessNumber(value.click_point.y)
      && value.click_point.x >= value.bounds.x
      && value.click_point.y >= value.bounds.y
      && value.click_point.x <= value.bounds.x + value.bounds.width
      && value.click_point.y <= value.bounds.y + value.bounds.height));
}

function processIsValid(value) {
  return exactKeys(value, ['pid', 'start_identity', 'code_signature_hash'])
    && positiveSafeInteger(value.pid)
    && canonicalPositiveDecimal(value.start_identity)
    && HEX40.test(value.code_signature_hash ?? '');
}

export function requireForegroundControllerCodeIdentity({
  expectedProcess, expectedTeamID, before, after, observedTeamID, observedCodeSignatureHash,
}) {
  if (!processIsValid(expectedProcess)
      || !/^[A-Z0-9]{10}$/.test(expectedTeamID ?? '')
      || !sameJSON(before, {
        pid: expectedProcess.pid,
        start_identity: expectedProcess.start_identity,
      })
      || !sameJSON(after, before)
      || observedTeamID !== expectedTeamID
      || observedCodeSignatureHash !== expectedProcess.code_signature_hash) {
    throw new CoordinatorError(
      'foreground controller live process generation or code-signature identity differs from the plan',
    );
  }
}

function verifyForegroundControllerCodeIdentity({
  monitorExecutable, expectedProcess, expectedTeamID, directory,
}) {
  const before = invokeProcessIdentity(
    monitorExecutable,
    expectedProcess.pid,
    directory,
    'foreground-controller-before',
  );
  const requirement = `anchor apple generic and certificate leaf[subject.OU] = "${expectedTeamID}"`;
  runSync('/usr/bin/codesign', [
    '--verify', '--strict', `-R=${requirement}`, `+${expectedProcess.pid}`,
  ], 'foreground controller Apple-anchored signature', 10_000);
  const display = runSync('/usr/bin/codesign', [
    '--display', '--verbose=4', `+${expectedProcess.pid}`,
  ], 'foreground controller code-signature identity', 10_000);
  const text = `${display.stdout ?? ''}\n${display.stderr ?? ''}`;
  const observedTeamID = text.match(/^TeamIdentifier=([A-Z0-9]{10})$/m)?.[1] ?? null;
  const observedCodeSignatureHash = text.match(/^CDHash=([0-9a-f]{40})$/m)?.[1] ?? null;
  const after = invokeProcessIdentity(
    monitorExecutable,
    expectedProcess.pid,
    directory,
    'foreground-controller-after',
  );
  requireForegroundControllerCodeIdentity({
    expectedProcess,
    expectedTeamID,
    before,
    after,
    observedTeamID,
    observedCodeSignatureHash,
  });
}

function semanticElementIsValid(value) {
  const validNullable = (entry) => entry === null || (
    typeof entry === 'string' && entry.length > 0 && !entry.includes('\0')
      && Buffer.byteLength(entry, 'utf8') <= 1024
  );
  return exactKeys(value, ['role', 'identifier', 'title'])
    && typeof value.role === 'string' && value.role.length > 0
    && !value.role.includes('\0') && Buffer.byteLength(value.role, 'utf8') <= 256
    && validNullable(value.identifier) && validNullable(value.title)
    && (value.identifier !== null || value.title !== null);
}

function boundsContain(outer, inner) {
  return inner.x >= outer.x && inner.y >= outer.y
    && inner.x + inner.width <= outer.x + outer.width
    && inner.y + inner.height <= outer.y + outer.height;
}

function focusedElementMatches(value, semanticElement, target) {
  return exactKeys(value, ['role', 'title', 'identifier', 'frame'])
    && value.role === semanticElement.role
    && value.identifier === semanticElement.identifier
    && value.title === semanticElement.title
    && exactKeys(value.frame, ['x', 'y', 'width', 'height'])
    && Object.values(value.frame).every(finiteLosslessNumber)
    && value.frame.width > 0 && value.frame.height > 0
    && boundsContain(target.bounds, value.frame);
}

function millisecondIntervalIsValid(value) {
  return exactKeys(value, ['started_at_milliseconds', 'completed_at_milliseconds'])
    && positiveSafeInteger(value.started_at_milliseconds)
    && positiveSafeInteger(value.completed_at_milliseconds)
    && value.completed_at_milliseconds >= value.started_at_milliseconds;
}

function receiptTarget(controllerTarget) {
  return {
    scope: 'window',
    pid: controllerTarget.process_identifier,
    start_identity: controllerTarget.process_start_identity_decimal,
    window_id: controllerTarget.window_id,
    bounds: structuredClone(controllerTarget.bounds),
    is_minimized: controllerTarget.is_minimized,
  };
}

function validatePlan(
  plan, catalog, testRuntimeAllowed, currentBuildCommit, diagnosticReportsDirectory,
) {
  const rootKeys = [
    'version', 'runs_directory', 'peekaboo_executable', 'controller_executable',
    'monitor_executable', 'bridge', 'controllers', 'observer', 'monitor',
    'external_foreground_timeout_seconds', 'operation_timeout_seconds',
  ];
  if (testRuntimeAllowed) rootKeys.push('test_runtime');
  if (!exactKeys(plan, rootKeys) || plan.version !== 1) {
    throw new CoordinatorError('live coordinator plan keys are not closed or version is not 1');
  }
  requirePrivateDirectory(requireAbsolute(plan.runs_directory, 'runs_directory'), 'runs_directory');
  requireExecutable(plan.peekaboo_executable, 'peekaboo_executable');
  requireExecutable(plan.controller_executable, 'controller_executable');
  requireExecutable(plan.monitor_executable, 'monitor_executable');
  if (!exactKeys(plan.bridge, ['socket_path', 'trusted_host_team_ids', 'expected_host'])
      || !path.isAbsolute(plan.bridge.socket_path)
      || !Array.isArray(plan.bridge.trusted_host_team_ids)
      || plan.bridge.trusted_host_team_ids.length === 0
      || plan.bridge.trusted_host_team_ids.some((team) => !/^[A-Z0-9]{10}$/.test(team))
      || !exactKeys(plan.bridge.expected_host, [
        'host_kind', 'process_identifier', 'process_start_identity_decimal',
        'code_signature_hash', 'source_commit',
      ])
      || !['gui', 'daemon'].includes(plan.bridge.expected_host.host_kind)
      || !positiveSafeInteger(plan.bridge.expected_host.process_identifier)
      || !canonicalPositiveDecimal(plan.bridge.expected_host.process_start_identity_decimal)
      || !HEX40.test(plan.bridge.expected_host.code_signature_hash ?? '')
      || !HEX40.test(plan.bridge.expected_host.source_commit ?? '')
      || !sameJSON(
        [...plan.bridge.trusted_host_team_ids].sort(),
        [...catalog.trusted_bridge_host_team_ids].sort(),
      )
      || plan.bridge.expected_host.source_commit !== currentBuildCommit) {
    throw new CoordinatorError('bridge plan is malformed');
  }
  if (!Array.isArray(plan.controllers) || plan.controllers.length !== 2) {
    throw new CoordinatorError('plan must contain exactly two controllers');
  }
  const expectedControllers = new Map(catalog.controlled_target_ids.map((targetID) => {
    const template = catalog.slots.find((slot) => slot.target_id === targetID);
    return [template.controller_id, targetID];
  }));
  for (const controller of plan.controllers) {
    if (!exactKeys(controller, ['controller_id', 'target_id', 'target'])
        || expectedControllers.get(controller.controller_id) !== controller.target_id
        || !targetIsValid(controller.target, true)) {
      throw new CoordinatorError('controller plans must match the closed catalog and exact-window schema');
    }
    requireSafeID(controller.controller_id, 'controller_id');
    requireSafeID(controller.target_id, 'target_id');
  }
  if (new Set(plan.controllers.map((entry) => entry.controller_id)).size !== 2
      || new Set(plan.controllers.map((entry) => entry.target_id)).size !== 2) {
    throw new CoordinatorError('controller and target IDs must be distinct');
  }
  const physicalTargets = new Set(plan.controllers.map((entry) => [
    entry.target.process_identifier,
    entry.target.process_start_identity_decimal,
    entry.target.window_id,
  ].join(':')));
  if (physicalTargets.size !== plan.controllers.length) {
    throw new CoordinatorError('background controller physical targets must be distinct');
  }
  if (!exactKeys(plan.observer, ['target', 'semantic_element', 'baseline_value'])
      || !targetIsValid(plan.observer.target)
      || !semanticElementIsValid(plan.observer.semantic_element)
      || typeof plan.observer.baseline_value !== 'string'
      || plan.observer.baseline_value.length === 0
      || Buffer.byteLength(plan.observer.baseline_value, 'utf8') > 4096) {
    throw new CoordinatorError('observe-only semantic plan is malformed');
  }
  if (!exactKeys(plan.monitor, [
    'sentinel', 'foreground_controller', 'foreground_controller_team_id',
    'foreground_target', 'invariant_names',
    'crash_directory', 'interval_milliseconds', 'code_signature_hash',
  ]) || !targetIsValid(plan.monitor.sentinel)
      || !processIsValid(plan.monitor.foreground_controller)
      || !/^[A-Z0-9]{10}$/.test(plan.monitor.foreground_controller_team_id ?? '')
      || !targetIsValid(plan.monitor.foreground_target)
      || !sameJSON(plan.monitor.foreground_target, plan.observer.target)
      || !Array.isArray(plan.monitor.invariant_names)
      || plan.monitor.invariant_names.length !== 6
      || new Set(plan.monitor.invariant_names).size !== 6
      || plan.monitor.invariant_names.some((name) => typeof name !== 'string' || name.length === 0)
      || !safeInteger(plan.monitor.interval_milliseconds)
      || plan.monitor.interval_milliseconds < 5 || plan.monitor.interval_milliseconds > 100
      || !HEX40.test(plan.monitor.code_signature_hash ?? '')) {
    throw new CoordinatorError('monitor plan is malformed');
  }
  if (plan.monitor.crash_directory !== diagnosticReportsDirectory) {
    throw new CoordinatorError(
      'crash_directory must equal the canonical user DiagnosticReports directory',
    );
  }
  const controlledTargets = plan.controllers.map((entry) => receiptTarget(entry.target));
  if (controlledTargets.some((target) => target.pid === plan.monitor.foreground_target.pid
      && target.start_identity === plan.monitor.foreground_target.start_identity)) {
    throw new CoordinatorError('foreground semantic target must be distinct from both background targets');
  }
  const backgroundProcesses = new Set([
    plan.bridge.expected_host.process_identifier,
    ...plan.controllers.map((entry) => entry.target.process_identifier),
  ]);
  if (backgroundProcesses.has(plan.monitor.foreground_controller.pid)) {
    throw new CoordinatorError('foreground controller must be distinct from every background owner and Bridge host');
  }
  if (!safeInteger(plan.external_foreground_timeout_seconds)
      || plan.external_foreground_timeout_seconds < 5
      || plan.external_foreground_timeout_seconds > 150
      || !safeInteger(plan.operation_timeout_seconds)
      || plan.operation_timeout_seconds > 3600) {
    throw new CoordinatorError('external and operation timeouts are invalid');
  }
  const maximumTypingDurationMilliseconds = Math.max(...plan.controllers.map((controller) => (
    [...makeControllerText(
      '0'.repeat(64), controller.controller_id, plan.external_foreground_timeout_seconds,
    )].length * CONTROLLER_TYPING_DELAY_MILLISECONDS
  )));
  const minimumOperationDurationMilliseconds = maximumTypingDurationMilliseconds
    + (EXTERNAL_FOREGROUND_WINDOW_COUNT * plan.external_foreground_timeout_seconds * 1000)
    + (OPERATION_LIFECYCLE_MARGIN_SECONDS * 1000);
  if (plan.operation_timeout_seconds * 1000 < minimumOperationDurationMilliseconds) {
    throw new CoordinatorError(
      'operation timeout does not cover controller typing, both external windows, and lifecycle overhead',
    );
  }
  if (testRuntimeAllowed) {
    if (!exactKeys(plan.test_runtime, [
      'catalog_path', 'finalizer_path', 'diagnostic_reports_path',
    ])
        || !path.isAbsolute(plan.test_runtime.catalog_path)
        || !path.isAbsolute(plan.test_runtime.finalizer_path)
        || plan.test_runtime.diagnostic_reports_path !== diagnosticReportsDirectory) {
      throw new CoordinatorError('test runtime paths are malformed');
    }
  }
}

function monitorSample(monitorExecutable, outputPath) {
  runSync(monitorExecutable, ['sample', '--output', outputPath], 'monitor baseline sample');
  const raw = readPrivateJSON(outputPath, 'monitor sample');
  if (!exactKeys(raw, [
    'timestamp', 'frontmostPID', 'frontmostBundleIdentifier', 'frontmostWindowID', 'cursor',
    'clipboardChangeCount', 'clipboardDigest', 'peekabooWindowIDs', 'visibleScreenFramesTopLeft',
  ]) || !positiveSafeInteger(raw.frontmostPID) || !positiveSafeInteger(raw.frontmostWindowID)
      || !nonnegativeSafeInteger(raw.clipboardChangeCount) || !HEX64.test(raw.clipboardDigest ?? '')) {
    throw new CoordinatorError('monitor sample is not one closed complete desktop sample');
  }
  return {
    frontmost_pid: raw.frontmostPID,
    frontmost_window_id: raw.frontmostWindowID,
    clipboard_change_count: raw.clipboardChangeCount,
    clipboard_digest: raw.clipboardDigest,
  };
}

function requireSentinelSample(sample, sentinel, label) {
  if (sample.frontmost_pid !== sentinel.pid || sample.frontmost_window_id !== sentinel.window_id) {
    throw new CoordinatorError(`${label} does not match the exact sentinel process/window`);
  }
}

function verifiedSentinelSample({ monitorExecutable, outputPath, directory, sentinel, label }) {
  const before = invokeProcessIdentity(
    monitorExecutable, sentinel.pid, directory, `${label}-sentinel-before`,
  );
  const sample = monitorSample(monitorExecutable, outputPath);
  const after = invokeProcessIdentity(
    monitorExecutable, sentinel.pid, directory, `${label}-sentinel-after`,
  );
  if (before.start_identity !== sentinel.start_identity
      || after.start_identity !== sentinel.start_identity) {
    throw new CoordinatorError(`${label} sentinel process generation differs from the exact plan`);
  }
  requireSentinelSample(sample, sentinel, `${label} sample`);
  return sample;
}

function crashInventory(directory, prefixes) {
  return fs.readdirSync(directory, { withFileTypes: true })
    .filter((entry) => entry.isFile() && prefixes.some((prefix) => entry.name.startsWith(prefix)))
    .map((entry) => {
      if (!/^[A-Za-z0-9._-]+$/.test(entry.name)) {
        throw new CoordinatorError('crash inventory contains an unsafe filename');
      }
      const filePath = path.join(directory, entry.name);
      const bytes = requirePrivateFile(filePath, `crash report ${entry.name}`);
      const info = fs.lstatSync(filePath);
      return {
        name: entry.name,
        size: info.size,
        modified_at_milliseconds: Math.floor(info.mtimeMs),
        sha256: sha256(bytes),
      };
    })
    .sort((left, right) => left.name.localeCompare(right.name));
}

function invokeProcessIdentity(monitorExecutable, pid, directory, label) {
  const outputPath = path.join(directory, `${label}-process.json`);
  runSync(monitorExecutable, [
    'process-identity', '--pid', String(pid), '--output', outputPath,
  ], `${label} process identity`);
  const value = readPrivateJSON(outputPath, `${label} process identity`);
  if (!exactKeys(value, ['pid', 'startIdentity']) || value.pid !== pid
      || !canonicalPositiveDecimal(value.startIdentity)) {
    throw new CoordinatorError(`${label} process identity is malformed`);
  }
  return { pid, start_identity: value.startIdentity };
}

function invokeProcessExecutable(monitorExecutable, pid, directory) {
  const outputPath = path.join(directory, 'monitor-process-executable.json');
  runSync(monitorExecutable, [
    'process-executable', '--pid', String(pid), '--output', outputPath,
  ], 'monitor process executable');
  const value = readPrivateJSON(outputPath, 'monitor process executable');
  if (!exactKeys(value, ['pid', 'startIdentity', 'path', 'sha256']) || value.pid !== pid
      || !canonicalPositiveDecimal(value.startIdentity) || !path.isAbsolute(value.path)
      || !HEX64.test(value.sha256 ?? '')) {
    throw new CoordinatorError('monitor process executable receipt is malformed');
  }
  return value;
}

function producerDocument({ revision, nonce, monitorID, host, controllers, foregroundController, foregroundTarget }) {
  const producers = [
    { pid: host.pid, startIdentity: host.start_identity, role: 'bridge' },
    ...controllers.map((entry) => ({
      pid: entry.pid, startIdentity: entry.start_identity, role: 'bridge',
    })),
  ];
  const active = foregroundController !== null;
  if (active) {
    producers.push({
      pid: foregroundController.pid,
      startIdentity: foregroundController.start_identity,
      role: 'foreground-controller',
    });
  }
  return {
    revision,
    executionNonce: nonce,
    monitorInstanceID: monitorID,
    producers,
    foreground: {
      active,
      target: active ? {
        pid: foregroundTarget.pid,
        startIdentity: foregroundTarget.start_identity,
        windowID: foregroundTarget.window_id,
      } : null,
    },
  };
}

function heartbeatIsClosed(value) {
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
    && positiveSafeInteger(value.sequence)
    && positiveSafeInteger(value.monotonicMicroseconds)
    && positiveSafeInteger(value.wallClockMilliseconds)
    && positiveSafeInteger(value.lastCleanSequence)
    && nonnegativeSafeInteger(value.contaminationRetries)
    && typeof value.contaminationBlocked === 'boolean'
    && typeof value.inputAttributionAvailable === 'boolean'
    && positiveSafeInteger(value.allowedProducerRevision)
    && typeof value.phase === 'string' && value.phase.length > 0
    && typeof value.cursorMovementObserved === 'boolean'
    && nonnegativeSafeInteger(value.pendingActivationCount)
    && typeof value.pendingFocusedWindowChange === 'boolean'
    && positiveSafeInteger(value.authorizationEpoch)
    && typeof value.transitionAcknowledged === 'boolean'
    && typeof value.foregroundActive === 'boolean'
    && (value.foregroundTargetPID === null
      || positiveSafeInteger(value.foregroundTargetPID))
    && (value.foregroundTargetWindowID === null
      || positiveSafeInteger(value.foregroundTargetWindowID))
    && nonnegativeSafeInteger(value.attributedForegroundEventCount)
    && Array.isArray(value.attributedForegroundSourcePIDs)
    && value.attributedForegroundSourcePIDs.every(positiveSafeInteger)
    && new Set(value.attributedForegroundSourcePIDs).size
      === value.attributedForegroundSourcePIDs.length
    && typeof value.foregroundActivityObserved === 'boolean'
    && HEX64.test(value.executionNonce ?? '')
    && UUID_V4.test(value.monitorInstanceID ?? '')
    && HEX64.test(value.historyCommitmentSHA256 ?? '');
}

async function waitForHeartbeat({
  name, filePath, deadline, nonce, monitorID, afterSequence, afterEpoch,
  afterMonotonicMicroseconds, afterWallClockMilliseconds, notBeforeWallClockMilliseconds,
  revision, foreground, target, historyCommitment, requireActivity = false, children,
}) {
  return waitFor(`stable monitor fence ${name}`, deadline, () => {
    if (!fs.existsSync(filePath)) return undefined;
    let heartbeat;
    try { heartbeat = readPrivateJSON(filePath, `monitor fence ${name}`); } catch { return undefined; }
    if (!heartbeatIsClosed(heartbeat)) return undefined;
    if (heartbeat.executionNonce !== nonce
        || heartbeat.monitorInstanceID !== monitorID
        || heartbeat.sequence <= afterSequence) return undefined;
    if (heartbeat.contaminationRetries !== 0 || heartbeat.contaminationBlocked
        || !heartbeat.inputAttributionAvailable) {
      throw new CoordinatorError(`monitor became contaminated or lost attribution before ${name}`);
    }
    if (heartbeat.allowedProducerRevision > revision) {
      throw new CoordinatorError(`monitor advanced beyond the expected producer revision before ${name}`);
    }
    if (heartbeat.allowedProducerRevision !== revision
        || heartbeat.lastCleanSequence !== heartbeat.sequence
        || heartbeat.pendingActivationCount !== 0
        || heartbeat.pendingFocusedWindowChange !== false
        || heartbeat.transitionAcknowledged !== false
        || heartbeat.foregroundActive !== foreground
        || heartbeat.foregroundTargetPID !== (foreground ? target.pid : null)
        || heartbeat.foregroundTargetWindowID !== (foreground ? target.window_id : null)
        || heartbeat.historyCommitmentSHA256 !== historyCommitment) return undefined;
    if (heartbeat.authorizationEpoch <= afterEpoch) {
      throw new CoordinatorError(`monitor authorization epoch did not increase at ${name}`);
    }
    if (afterMonotonicMicroseconds !== null) {
      const previous = {
        monotonicMicroseconds: afterMonotonicMicroseconds,
        wallClockMilliseconds: afterWallClockMilliseconds,
      };
      if (heartbeat.monotonicMicroseconds <= previous.monotonicMicroseconds) {
        throw new CoordinatorError(`monitor monotonic clock did not increase at ${name}`);
      }
      if (heartbeat.wallClockMilliseconds < previous.wallClockMilliseconds) {
        throw new CoordinatorError(`monitor wall clock moved backwards at ${name}`);
      }
      if (heartbeatClockDriftMicroseconds(heartbeat, previous) > 2_000_000n) {
        throw new CoordinatorError(`monitor wall/monotonic clock drift exceeded two seconds at ${name}`);
      }
    }
    if (requireActivity) {
      if (!(heartbeat.attributedForegroundEventCount > 0)
          || !sameJSON(heartbeat.attributedForegroundSourcePIDs, [children.foregroundControllerPID])
          || heartbeat.foregroundActivityObserved !== true) return undefined;
    } else if (heartbeat.attributedForegroundEventCount !== 0
        || heartbeat.attributedForegroundSourcePIDs.length !== 0
        || heartbeat.foregroundActivityObserved !== false) {
      throw new CoordinatorError(`foreground activity occurred before the ${name} fence`);
    }
    if (heartbeat.wallClockMilliseconds < notBeforeWallClockMilliseconds) return undefined;
    return structuredClone(heartbeat);
  }, children.processes);
}

function requestMarker(phase, nonce, marker) {
  return { version: 1, execution_nonce: nonce, request_marker: marker, phase };
}

function releaseMarker(nonce) {
  return { version: 1, execution_nonce: nonce, phase: 'release' };
}

function externalMarkerIsValid(value, nonce, monitorID, phase) {
  return exactKeys(value, ['version', 'execution_nonce', 'monitor_instance_id', 'phase'])
    && value.version === 1 && value.execution_nonce === nonce
    && value.monitor_instance_id === monitorID && value.phase === phase;
}

async function waitForExternalMarker(filePath, nonce, monitorID, phase, deadline, children) {
  return waitFor(`external foreground ${phase}`, deadline, () => {
    if (!fs.existsSync(filePath)) return undefined;
    const marker = readPrivateJSON(filePath, `external foreground ${phase}`);
    if (!externalMarkerIsValid(marker, nonce, monitorID, phase)) {
      throw new CoordinatorError(`external foreground ${phase} marker is not closed and run-bound`);
    }
    return marker;
  }, children);
}

function readJSONLines(filePath, label) {
  if (!fs.existsSync(filePath)) throw new CoordinatorError(`${label} is missing`);
  const bytes = requirePrivateFile(filePath, label);
  const text = bytes.toString('utf8');
  if (text.length === 0) return [];
  if (!text.endsWith('\n')) throw new CoordinatorError(`${label} is not newline terminated`);
  return text.trimEnd().split('\n').map((line, index) => parseJSON(Buffer.from(line), `${label} row ${index}`));
}

function copyExclusive(source, destination, label) {
  const bytes = requirePrivateFile(source, label);
  fs.writeFileSync(destination, bytes, { flag: 'wx', mode: 0o600 });
  fs.chmodSync(destination, 0o600);
  if (sha256(requirePrivateFile(destination, `${label} copy`)) !== sha256(bytes)) {
    throw new CoordinatorError(`${label} copy changed bytes`);
  }
}

function collectControllerCorpus(controllerStates, receiptDirectory, bundleDirectory) {
  const requestIDs = new Set();
  for (const state of controllerStates) {
    const receipt = readPrivateJSON(state.receiptPath, `${state.id} receipt`);
    if (receipt.execution_nonce !== state.nonce || receipt.monitor_instance_id !== state.monitorID
        || receipt.controller_id !== state.id || receipt.result !== 'passed'
        || !sameJSON(receipt.controller, state.controllerProcess)
        || !Array.isArray(receipt.slots) || receipt.slots.length !== 4) {
      throw new CoordinatorError(`${state.id} receipt is not one closed four-slot passed run`);
    }
    copyExclusive(
      state.receiptPath,
      path.join(receiptDirectory, `${state.id}-receipt.json`),
      `${state.id} receipt`,
    );
    const files = fs.readdirSync(state.bundleDirectory).sort();
    if (files.length !== 4 || files.some((name) => !UUID_V8.test(name.slice(0, -5)))) {
      throw new CoordinatorError(`${state.id} bundle inventory is not exactly four UUID files`);
    }
    for (const file of files) {
      if (requestIDs.has(file)) throw new CoordinatorError('controller bundle request IDs are not unique');
      requestIDs.add(file);
      copyExclusive(path.join(state.bundleDirectory, file), path.join(bundleDirectory, file), `${state.id} bundle`);
    }
  }
  if (requestIDs.size !== 8) throw new CoordinatorError('combined bundle inventory is not exactly eight');
}

function makeAttestationPlan({
  nonce, monitorID, socketPath, expectedPeer, kind, directory, outputPath,
}) {
  return {
    version: 1,
    execution_nonce: nonce,
    monitor_instance_id: monitorID,
    socket_path: socketPath,
    expected_peer: structuredClone(expectedPeer),
    response_kind: kind,
    artifacts_directory: directory,
    output_path: outputPath,
    release_path: path.join(directory, 'release.json'),
    timeout_milliseconds: 10_000,
    maximum_response_bytes: 1024 * 1024,
  };
}

function requireOwnerSocket(socketPath, label) {
  const info = fs.lstatSync(socketPath);
  if (!info.isSocket() || info.isSymbolicLink() || (info.mode & 0o077) !== 0
      || (typeof process.geteuid === 'function' && info.uid !== process.geteuid())) {
    throw new CoordinatorError(`${label} must be one owner-private Unix socket`);
  }
  return { device: info.dev, inode: info.ino };
}

async function runPIDAttestation({
  controllerExecutable, planPath, plan, expectedProcess, expectedDigest, responseKind,
}) {
  if (!sameJSON(plan.expected_peer, expectedProcess)) {
    throw new CoordinatorError(`${responseKind} PID attestation plan differs from its expected process`);
  }
  writePrivateJSON(planPath, plan);
  const label = `${responseKind} PID attestation`;
  const child = spawnOwned(controllerExecutable, ['--attest-monitor', planPath], label);
  try {
    const response = await waitFor(
      `${responseKind} PID attestation response`,
      Date.now() + plan.timeout_milliseconds,
      () => fs.existsSync(plan.output_path)
        ? readPrivateJSON(plan.output_path, `${responseKind} PID attestation response`)
        : undefined,
      [{ child, label }],
    );
    const processKey = responseKind === 'monitor' ? 'monitor' : 'observer';
    const digestKey = responseKind === 'monitor' ? 'monitor_evidence_sha256' : 'witness_sha256';
    const expectedKeys = responseKind === 'monitor'
      ? [
        'version', 'execution_nonce', 'monitor_instance_id', 'challenge', 'monitor',
        'monitor_evidence_sha256',
      ]
      : [
        'version', 'execution_nonce', 'monitor_instance_id', 'challenge', 'observer',
        'witness_sha256', 'observation_file_sha256', 'restoration_file_sha256',
        'before_value_sha256', 'expected_value_sha256', 'observed_value_sha256',
        'restored_value_sha256',
      ];
    if (!exactKeys(response, expectedKeys) || response.version !== 1
        || response.execution_nonce !== plan.execution_nonce
        || response.monitor_instance_id !== plan.monitor_instance_id
        || !HEX64.test(response.challenge ?? '')
        || !sameJSON(response[processKey], expectedProcess)
        || response[digestKey] !== expectedDigest) {
      throw new CoordinatorError(`${responseKind} PID attestation does not bind the live process and corpus`);
    }
    writePrivateJSON(plan.release_path, releaseMarker(plan.execution_nonce));
    await waitForExit(child, label, 5000);
    return response;
  } finally {
    if (!fs.existsSync(plan.release_path)) {
      try { writePrivateJSON(plan.release_path, releaseMarker(plan.execution_nonce)); } catch {}
    }
    await terminateChild(child, label);
  }
}

export function finalizerCommandTimeoutMilliseconds(bundleCount, {
  innerBundleTimeoutMilliseconds = FINALIZER_INNER_BUNDLE_TIMEOUT_MILLISECONDS,
  identityRuntimeOverheadMilliseconds = FINALIZER_IDENTITY_RUNTIME_OVERHEAD_MILLISECONDS,
} = {}) {
  if (!positiveSafeInteger(bundleCount) || !positiveSafeInteger(innerBundleTimeoutMilliseconds)
      || !positiveSafeInteger(identityRuntimeOverheadMilliseconds)) {
    throw new CoordinatorError('finalizer timeout inputs must be positive safe integers');
  }
  return (bundleCount * innerBundleTimeoutMilliseconds) + identityRuntimeOverheadMilliseconds;
}

export function finalizerGlobalBudgetMilliseconds(bundleCount, options = {}) {
  return FINALIZER_INVOCATION_COUNT * finalizerCommandTimeoutMilliseconds(bundleCount, options);
}

function remainingFinalizerTimeoutMilliseconds(globalDeadline, maximumTimeout) {
  const remaining = globalDeadline - Date.now();
  if (remaining <= 0) throw new CoordinatorError('global finalizer deadline expired before invocation');
  return Math.min(remaining, maximumTimeout);
}

function finalizerCommand(retainedFinalizer, stagingDirectory, args, label, timeout) {
  const sourcePath = path.join(stagingDirectory, `.retained-finalizer-${randomUUID()}.source`);
  const writeDescriptor = fs.openSync(sourcePath, 'wx', 0o600);
  let readDescriptor;
  try {
    fs.writeFileSync(writeDescriptor, retainedFinalizer.bytes);
    fs.fsyncSync(writeDescriptor);
    fs.closeSync(writeDescriptor);
    readDescriptor = fs.openSync(sourcePath, 'r');
    fs.unlinkSync(sourcePath);
    const targetURL = pathToFileURL(retainedFinalizer.path).href;
    const loaderSource = [
      "import fs from 'node:fs';",
      `const targetURL = ${JSON.stringify(targetURL)};`,
      'const retainedSource = fs.readFileSync(3);',
      'export async function load(url, context, nextLoad) {',
      '  if (url === targetURL) {',
      "    return { format: 'module', shortCircuit: true, source: retainedSource };",
      '  }',
      '  return nextLoad(url, context);',
      '}',
    ].join('\n');
    const loaderURL = `data:text/javascript;base64,${Buffer.from(loaderSource).toString('base64')}`;
    const result = spawnSync(process.execPath, [
      '--preserve-symlinks-main',
      `--experimental-loader=${loaderURL}`,
      retainedFinalizer.path,
      ...args,
    ], {
      encoding: 'utf8',
      timeout,
      maxBuffer: 16 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'pipe', readDescriptor],
    });
    if (result.error || result.status !== 0) {
      throw new CoordinatorError(
        `${label} failed: ${result.error?.message ?? result.stderr?.trim() ?? `status ${result.status}`}`,
      );
    }
    return result;
  } finally {
    try { fs.closeSync(writeDescriptor); } catch {}
    if (readDescriptor !== undefined) {
      try { fs.closeSync(readDescriptor); } catch {}
    }
    try { fs.unlinkSync(sourcePath); } catch {}
  }
}

function makeControllerText(nonce, controllerID, externalTimeoutSeconds) {
  const prefix = `peekaboo-certification-background:${nonce}:${controllerID}:`;
  const prefixBytes = Buffer.byteLength(prefix, 'utf8');
  const minimumCharacters = Math.ceil((
    (externalTimeoutSeconds + CONTROLLER_MUTATION_OVERLAP_MARGIN_SECONDS) * 1000
  ) / CONTROLLER_TYPING_DELAY_MILLISECONDS);
  const totalCharacters = Math.max(prefixBytes + 1, minimumCharacters);
  if (totalCharacters > MAXIMUM_CONTROLLER_TEXT_BYTES) {
    throw new CoordinatorError('external foreground timeout cannot fit inside one bounded controller mutation');
  }
  return `${prefix}${'x'.repeat(totalCharacters - prefixBytes)}`;
}

function childEntries(controllerStates, observerChild, monitorChild) {
  return [
    ...controllerStates.map((entry) => ({ child: entry.child, label: entry.id })),
    ...(observerChild ? [{ child: observerChild, label: 'foreground observer' }] : []),
    ...(monitorChild ? [{ child: monitorChild, label: 'live monitor' }] : []),
  ];
}

async function runCoordinator(
  plan, catalog, retainedFinalizer, diagnosticReportsDirectory, testRuntime, currentBuildCommit,
) {
  const runsDirectory = path.resolve(plan.runs_directory);
  const runRoot = fs.mkdtempSync(path.join(runsDirectory, 'peekaboo-live-certification-'));
  fs.chmodSync(runRoot, 0o700);
  const nonce = randomBytes(32).toString('hex');
  const monitorID = randomUUID().toLowerCase();
  const finalizerTimeout = finalizerCommandTimeoutMilliseconds(catalog.slots.length);
  const operationDeadline = Date.now() + plan.operation_timeout_seconds * 1000;
  const globalFinalizerDeadline = operationDeadline
    + finalizerGlobalBudgetMilliseconds(catalog.slots.length);
  const externalDeadlineDuration = plan.external_foreground_timeout_seconds * 1000;
  const sourceControllerExecutable = fs.realpathSync(plan.controller_executable);
  let controllerExecutable = sourceControllerExecutable;
  const monitorExecutable = fs.realpathSync(plan.monitor_executable);
  const peekabooExecutable = fs.realpathSync(plan.peekaboo_executable);
  let inspectorStage;
  let controllerCodeIdentity;
  let monitorCodeIdentity;
  if (!testRuntime) {
    inspectorStage = await stageCodeIdentityInspector(
      sourceControllerExecutable,
      catalog.trusted_controller_team_ids,
      currentBuildCommit,
      { parentDirectory: runRoot },
    );
    controllerExecutable = inspectorStage.executable;
    controllerCodeIdentity = {
      team_id: inspectorStage.teamID,
      code_signature_hash: inspectorStage.codeSignatureHash,
    };
    const monitorSHA256 = sha256(fs.readFileSync(monitorExecutable));
    const monitorMatches = [];
    for (const teamID of catalog.trusted_monitor_team_ids) {
      try {
        monitorMatches.push(await inspectCodeIdentity({
          inspectorStage,
          subject: {
            kind: 'executable', executable_path: monitorExecutable, expected_team_id: teamID,
          },
          expected: {
            kind: 'executable',
            executablePath: monitorExecutable,
            executableSHA256: monitorSHA256,
            codeSignatureHash: plan.monitor.code_signature_hash,
            teamID,
            sourceCommit: catalog.monitor_source.commit,
          },
          label: 'certification monitor file',
        }));
      } catch {}
    }
    if (monitorMatches.length !== 1) {
      throw new CoordinatorError(
        'certification monitor must match exactly one catalog-approved Apple anchor',
      );
    }
    [monitorCodeIdentity] = monitorMatches;
    if (monitorCodeIdentity.code_signature_hash !== plan.monitor.code_signature_hash) {
      throw new CoordinatorError('certification monitor code-signature hash differs from the plan');
    }
    requirePeekabooSourceCommit(peekabooExecutable, currentBuildCommit);
  }
  const controllerBuild = {
    source_commit: currentBuildCommit,
    executable_path: controllerExecutable,
    executable_sha256: inspectorStage?.executableSHA256 ?? sha256(fs.readFileSync(controllerExecutable)),
    team_id: controllerCodeIdentity?.team_id ?? catalog.trusted_controller_team_ids[0],
  };
  const directories = {};
  for (const name of [
    'controllers', 'observer', 'monitor', 'attestations', 'controller-receipts',
    'raw-bundles',
  ]) {
    directories[name] = path.join(runRoot, name);
    fs.mkdirSync(directories[name], { mode: 0o700 });
  }
  directories['prepared-artifacts'] = path.join(runRoot, 'prepared-artifacts');
  if (!testRuntime) {
    verifyForegroundControllerCodeIdentity({
      monitorExecutable,
      expectedProcess: plan.monitor.foreground_controller,
      expectedTeamID: plan.monitor.foreground_controller_team_id,
      directory: directories.monitor,
    });
  }
  const shared = {
    heartbeat: path.join(directories.monitor, 'heartbeat.json'),
    violations: path.join(directories.monitor, 'violations.jsonl'),
    contaminations: path.join(directories.monitor, 'contaminations.jsonl'),
    ready: path.join(directories.monitor, 'ready'),
    phase: path.join(directories.monitor, 'phase'),
    producers: path.join(directories.monitor, 'allowed-producers.json'),
    history: path.join(directories.monitor, 'history-commitment.txt'),
    attestationSocket: path.join(directories.monitor, 'monitor-attestation.sock'),
    evidenceDraft: path.join(directories.monitor, 'monitor-evidence-draft.json'),
    evidence: path.join(directories.monitor, 'monitor-evidence.json'),
    sealRequest: path.join(directories.monitor, 'seal-request.json'),
    sealReceipt: path.join(directories.monitor, 'seal-receipt.json'),
    externalWindow: path.join(runRoot, 'external-foreground-window.json'),
    externalTaskComplete: path.join(runRoot, 'external-foreground-task-complete.json'),
    externalRestoreComplete: path.join(runRoot, 'external-foreground-restore-complete.json'),
    summary: path.join(runRoot, 'certification-summary.json'),
    prepareSummary: path.join(runRoot, 'prepare-summary.json'),
  };
  for (const [label, socketPath] of [
    ['monitor attestation socket', shared.attestationSocket],
    ['observer attestation socket', path.join(directories.observer, 'observer-attestation.sock')],
  ]) {
    if (Buffer.byteLength(socketPath, 'utf8') >= 104) {
      throw new CoordinatorError(`${label} path exceeds the Darwin Unix-socket limit; choose a shorter runs_directory`);
    }
  }
  let observerChild;
  let monitorChild;
  const controllerStates = [];
  let released = false;
  emit({ event: 'run-created', version: 1, execution_nonce: nonce, monitor_instance_id: monitorID, run_root: runRoot });
  try {
    for (const controller of [...plan.controllers].sort((a, b) => a.controller_id.localeCompare(b.controller_id))) {
      const artifactDirectory = path.join(directories.controllers, controller.controller_id);
      fs.mkdirSync(artifactDirectory, { mode: 0o700 });
      const planPath = path.join(artifactDirectory, 'plan.json');
      const readyPath = path.join(artifactDirectory, 'controller-ready.json');
      const startPath = path.join(artifactDirectory, 'controller-start.json');
      const finalBoundsReadyPath = path.join(artifactDirectory, 'final-bounds-ready.json');
      const finalBoundsStartPath = path.join(artifactDirectory, 'final-bounds-start.json');
      const releasePath = path.join(artifactDirectory, 'controller-release.json');
      const controllerPlan = {
        version: 1,
        execution_nonce: nonce,
        monitor_instance_id: monitorID,
        controller_id: controller.controller_id,
        target_id: controller.target_id,
        client_instance_id: randomUUID().toLowerCase(),
        socket_path: plan.bridge.socket_path,
        trusted_bridge_host_team_ids: plan.bridge.trusted_host_team_ids,
        expected_controller_build: controllerBuild,
        expected_host: plan.bridge.expected_host,
        target: controller.target,
        type_text: makeControllerText(nonce, controller.controller_id, plan.external_foreground_timeout_seconds),
        typing_delay_milliseconds: CONTROLLER_TYPING_DELAY_MILLISECONDS,
        artifacts_directory: artifactDirectory,
        ready_path: readyPath,
        start_path: startPath,
        final_bounds_ready_path: finalBoundsReadyPath,
        final_bounds_start_path: finalBoundsStartPath,
        release_path: releasePath,
      };
      writePrivateJSON(planPath, controllerPlan);
      const child = spawnOwned(
        controllerExecutable, ['--plan', planPath], controller.controller_id,
      );
      controllerStates.push({
        id: controller.controller_id,
        targetID: controller.target_id,
        child,
        nonce,
        monitorID,
        artifactDirectory,
        bundleDirectory: path.join(artifactDirectory, 'bundles'),
        receiptPath: path.join(artifactDirectory, `${controller.controller_id}-receipt.json`),
        mutationStartedPath: path.join(artifactDirectory, 'mutation-started.json'),
        mutationCompletedPath: path.join(artifactDirectory, 'mutation-completed.json'),
        readyPath,
        startPath,
        finalBoundsReadyPath,
        finalBoundsStartPath,
        releasePath,
      });
    }
    const controllerProcesses = [];
    for (const state of controllerStates) {
      const ready = await waitFor(`${state.id} pre-execution readiness`, operationDeadline, () => (
        fs.existsSync(state.readyPath)
          ? readPrivateJSON(state.readyPath, `${state.id} readiness`) : undefined
      ), childEntries(controllerStates));
      if (!exactKeys(ready, [
        'version', 'execution_nonce', 'controller_id', 'target_id', 'controller', 'build',
        'ready_at_milliseconds',
      ]) || ready.version !== 1 || ready.execution_nonce !== nonce
          || ready.controller_id !== state.id || ready.target_id !== state.targetID
          || !processIsValid(ready.controller) || ready.controller.pid !== state.child.pid
          || !sameJSON(ready.build, controllerBuild)
          || !positiveSafeInteger(ready.ready_at_milliseconds)) {
        throw new CoordinatorError(`${state.id} readiness is not closed and process/run bound`);
      }
      const observed = invokeProcessIdentity(
        monitorExecutable, state.child.pid, state.artifactDirectory, state.id,
      );
      if (observed.start_identity !== ready.controller.start_identity) {
        throw new CoordinatorError(`${state.id} process generation changed after readiness`);
      }
      if (!testRuntime) {
        const liveIdentity = await inspectCodeIdentity({
          inspectorStage,
          subject: {
            kind: 'process',
            process_identifier: state.child.pid,
            process_start_identity: ready.controller.start_identity,
            expected_team_id: controllerCodeIdentity.team_id,
          },
          expected: {
            kind: 'process',
            process: ready.controller,
            executablePath: controllerExecutable,
            executableSHA256: null,
            codeSignatureHash: controllerCodeIdentity.code_signature_hash,
            teamID: controllerCodeIdentity.team_id,
            sourceCommit: currentBuildCommit,
          },
          label: `${state.id} process`,
        });
        if (ready.controller.code_signature_hash !== controllerCodeIdentity.code_signature_hash
            || liveIdentity.code_signature_hash !== controllerCodeIdentity.code_signature_hash
            || liveIdentity.executable_path !== controllerExecutable) {
          throw new CoordinatorError(`${state.id} Apple-anchored process identity differs from its executable`);
        }
      }
      controllerProcesses.push(ready.controller);
      state.controllerProcess = ready.controller;
    }

    const observerDirectory = directories.observer;
    const observerPlanPath = path.join(observerDirectory, 'plan.json');
    const marker = `peekaboo-foreground-postcondition:${nonce}`;
    const observerPaths = {
      ready: path.join(observerDirectory, 'observer-ready.json'),
      observe: path.join(observerDirectory, 'observe-request.json'),
      restore: path.join(observerDirectory, 'restore-request.json'),
      release: path.join(observerDirectory, 'observer-release.json'),
      observation: path.join(observerDirectory, 'foreground-observation.json'),
      restoration: path.join(observerDirectory, 'foreground-restoration.json'),
      witness: path.join(observerDirectory, 'foreground-witness.json'),
      attestationSocket: path.join(observerDirectory, 'observer-attestation.sock'),
    };
    writePrivateJSON(observerPlanPath, {
      version: 1,
      mode: 'observe-only',
      execution_nonce: nonce,
      monitor_instance_id: monitorID,
      observer_id: 'foreground-observer',
      client_instance_id: randomUUID().toLowerCase(),
      socket_path: plan.bridge.socket_path,
      trusted_bridge_host_team_ids: plan.bridge.trusted_host_team_ids,
      expected_controller_build: controllerBuild,
      expected_host: plan.bridge.expected_host,
      target: plan.observer.target,
      semantic_element: plan.observer.semantic_element,
      request_marker: marker,
      expected_value_sha256: sha256(Buffer.from(marker, 'utf8')),
      baseline_value_sha256: sha256(Buffer.from(plan.observer.baseline_value, 'utf8')),
      artifacts_directory: observerDirectory,
      ready_path: observerPaths.ready,
      observation_request_path: observerPaths.observe,
      restoration_request_path: observerPaths.restore,
      release_path: observerPaths.release,
      observation_path: observerPaths.observation,
      restoration_path: observerPaths.restoration,
      witness_path: observerPaths.witness,
      attestation_socket_path: observerPaths.attestationSocket,
      wait_timeout_seconds: plan.operation_timeout_seconds,
      poll_interval_milliseconds: 25,
    });
    observerChild = spawnOwned(
      controllerExecutable, ['--observe-only-plan', observerPlanPath], 'foreground observer',
    );
    const observerReady = await waitFor('foreground observer readiness', operationDeadline, () => (
      fs.existsSync(observerPaths.ready)
        ? readPrivateJSON(observerPaths.ready, 'foreground observer readiness') : undefined
    ), childEntries(controllerStates, observerChild));
    if (!exactKeys(observerReady, [
      'version', 'mode', 'execution_nonce', 'observer_id', 'observer', 'observer_build',
      'target', 'focused_element', 'request_marker', 'baseline_value_sha256',
      'expected_value_sha256', 'observation_path', 'restoration_path', 'ready_at_milliseconds',
    ]) || observerReady.version !== 1 || observerReady.mode !== 'observe-only'
        || observerReady.execution_nonce !== nonce || observerReady.observer_id !== 'foreground-observer'
        || !processIsValid(observerReady.observer)
        || !focusedElementMatches(
          observerReady.focused_element, plan.observer.semantic_element, plan.observer.target,
        )
        || observerReady.baseline_value_sha256 !== sha256(Buffer.from(plan.observer.baseline_value, 'utf8'))
        || observerReady.expected_value_sha256 !== sha256(Buffer.from(marker, 'utf8'))
        || observerReady.request_marker !== marker
        || !sameJSON(observerReady.target, plan.observer.target)
        || observerReady.observation_path !== observerPaths.observation
        || observerReady.restoration_path !== observerPaths.restoration
        || !sameJSON(observerReady.observer_build, controllerBuild)
        || !positiveSafeInteger(observerReady.ready_at_milliseconds)) {
      throw new CoordinatorError('foreground observer readiness is not bound to the committed semantic plan');
    }
    if (!testRuntime) {
      const observerIdentity = await inspectCodeIdentity({
        inspectorStage,
        subject: {
          kind: 'process',
          process_identifier: observerChild.pid,
          process_start_identity: observerReady.observer.start_identity,
          expected_team_id: controllerCodeIdentity.team_id,
        },
        expected: {
          kind: 'process',
          process: observerReady.observer,
          executablePath: controllerExecutable,
          executableSHA256: null,
          codeSignatureHash: controllerCodeIdentity.code_signature_hash,
          teamID: controllerCodeIdentity.team_id,
          sourceCommit: currentBuildCommit,
        },
        label: 'foreground observer process',
      });
      if (observerReady.observer.code_signature_hash !== controllerCodeIdentity.code_signature_hash
          || observerIdentity.code_signature_hash !== controllerCodeIdentity.code_signature_hash
          || observerIdentity.executable_path !== controllerExecutable) {
        throw new CoordinatorError(
          'foreground observer Apple-anchored process identity differs from its executable',
        );
      }
    }

    const samplePath = path.join(directories.monitor, 'baseline-sample.json');
    const baselineSample = verifiedSentinelSample({
      monitorExecutable,
      outputPath: samplePath,
      directory: directories.monitor,
      sentinel: plan.monitor.sentinel,
      label: 'baseline',
    });
    const crashPrefixes = structuredClone(catalog.monitor_contract.crash_report_prefixes);
    const crashBaseline = crashInventory(diagnosticReportsDirectory, crashPrefixes);
    const hostProcess = {
      pid: plan.bridge.expected_host.process_identifier,
      start_identity: plan.bridge.expected_host.process_start_identity_decimal,
      code_signature_hash: plan.bridge.expected_host.code_signature_hash,
    };
    const baselineProducers = producerDocument({
      revision: 1,
      nonce,
      monitorID,
      host: hostProcess,
      controllers: controllerProcesses,
      foregroundController: null,
      foregroundTarget: plan.monitor.foreground_target,
    });
    const grantProducers = producerDocument({
      revision: 2,
      nonce,
      monitorID,
      host: hostProcess,
      controllers: controllerProcesses,
      foregroundController: plan.monitor.foreground_controller,
      foregroundTarget: plan.monitor.foreground_target,
    });
    const revokeProducers = producerDocument({
      revision: 3,
      nonce,
      monitorID,
      host: hostProcess,
      controllers: controllerProcesses,
      foregroundController: null,
      foregroundTarget: plan.monitor.foreground_target,
    });
    const foregroundPlan = {
      request_marker: marker,
      expected_value_sha256: sha256(Buffer.from(marker, 'utf8')),
      baseline_value_sha256: sha256(Buffer.from(plan.observer.baseline_value, 'utf8')),
      observer: observerReady.observer,
      observer_build: controllerBuild,
      semantic_element: structuredClone(plan.observer.semantic_element),
      observation_path: observerPaths.observation,
      restoration_path: observerPaths.restoration,
      witness_path: observerPaths.witness,
      observer_attestation_socket_path: observerPaths.attestationSocket,
    };
    const evidenceSeed = {
      execution_nonce: nonce,
      monitor_instance_id: monitorID,
      monitor_attestation_socket_path: shared.attestationSocket,
      producer_sets: { baseline: baselineProducers, grant: grantProducers, revoke: revokeProducers },
      baseline_sample: baselineSample,
      foreground_plan: foregroundPlan,
      crash_evidence: {
        directory: diagnosticReportsDirectory,
        prefixes: crashPrefixes,
        baseline: crashBaseline,
      },
    };
    const baselineCommitment = aggregateSHA256('monitor-baseline', monitorBaselineProjection(evidenceSeed));
    fs.writeFileSync(shared.phase, 'setup\n', { flag: 'wx', mode: 0o600 });
    writePrivateJSON(shared.producers, baselineProducers);
    fs.writeFileSync(shared.history, `${baselineCommitment}\n`, { flag: 'wx', mode: 0o600 });
    monitorChild = spawnOwned(monitorExecutable, [
      'watch',
      '--baseline', samplePath,
      '--output', shared.violations,
      '--contamination-output', shared.contaminations,
      '--ready', shared.ready,
      '--heartbeat', shared.heartbeat,
      '--phase', shared.phase,
      '--allowed-producers', shared.producers,
      '--invariant-names', JSON.stringify(plan.monitor.invariant_names),
      '--interval-ms', String(plan.monitor.interval_milliseconds),
      '--physical-input-observational',
      '--cursor-observational',
      '--execution-nonce', nonce,
      '--monitor-instance-id', monitorID,
      '--history-commitment', shared.history,
      '--attestation-socket', shared.attestationSocket,
      '--attestation-evidence', shared.evidence,
      '--seal-request', shared.sealRequest,
      '--sealed-evidence', shared.evidence,
      '--seal-receipt', shared.sealReceipt,
    ], 'live monitor');
    await waitFor('monitor readiness', operationDeadline, () => fs.existsSync(shared.ready), childEntries(
      controllerStates, observerChild, monitorChild,
    ));
    const monitorExecutableReceipt = invokeProcessExecutable(
      monitorExecutable, monitorChild.pid, directories.monitor,
    );
    if (fs.realpathSync(monitorExecutableReceipt.path) !== monitorExecutable
        || monitorExecutableReceipt.sha256 !== sha256(fs.readFileSync(monitorExecutable))
        || monitorExecutableReceipt.startIdentity !== invokeProcessIdentity(
          monitorExecutable, monitorChild.pid, directories.monitor, 'monitor-recheck',
        ).start_identity) {
      throw new CoordinatorError('monitor executable/process generation changed during launch');
    }
    if (!testRuntime) {
      const monitorProcessReceipt = {
        pid: monitorChild.pid,
        start_identity: monitorExecutableReceipt.startIdentity,
        code_signature_hash: monitorCodeIdentity.code_signature_hash,
      };
      const liveMonitorIdentity = await inspectCodeIdentity({
        inspectorStage,
        subject: {
          kind: 'process',
          process_identifier: monitorChild.pid,
          process_start_identity: monitorExecutableReceipt.startIdentity,
          expected_team_id: monitorCodeIdentity.team_id,
        },
        expected: {
          kind: 'process',
          process: monitorProcessReceipt,
          executablePath: monitorExecutable,
          executableSHA256: null,
          codeSignatureHash: monitorCodeIdentity.code_signature_hash,
          teamID: monitorCodeIdentity.team_id,
          sourceCommit: catalog.monitor_source.commit,
        },
        label: 'certification monitor process',
      });
      if (liveMonitorIdentity.code_signature_hash !== monitorCodeIdentity.code_signature_hash
          || liveMonitorIdentity.executable_path !== monitorExecutable) {
        throw new CoordinatorError(
          'certification monitor Apple-anchored process identity differs from its executable',
        );
      }
    }
    const monitorProcess = {
      pid: monitorChild.pid,
      start_identity: monitorExecutableReceipt.startIdentity,
      executable_path: monitorExecutable,
      executable_sha256: monitorExecutableReceipt.sha256,
      code_signature_hash: monitorCodeIdentity?.code_signature_hash ?? plan.monitor.code_signature_hash,
      team_id: monitorCodeIdentity?.team_id ?? catalog.trusted_monitor_team_ids[0],
      source_commit: catalog.monitor_source.commit,
      heartbeat_path: shared.heartbeat,
    };
    const fenceChildren = {
      processes: childEntries(controllerStates, observerChild, monitorChild),
      foregroundControllerPID: plan.monitor.foreground_controller.pid,
    };
    const fences = [];
    let lastSequence = 0;
    let lastEpoch = 0;
    let lastMonotonicMicroseconds = null;
    let lastWallClockMilliseconds = null;
    const capture = async (name, revision, foreground, requireActivity = false) => {
      // A newer sequence can still predate the readiness/observation we just awaited.
      const notBeforeWallClockMilliseconds = Date.now();
      const heartbeat = await waitForHeartbeat({
        name,
        filePath: shared.heartbeat,
        deadline: operationDeadline,
        nonce,
        monitorID,
        afterSequence: lastSequence,
        afterEpoch: lastEpoch,
        afterMonotonicMicroseconds: lastMonotonicMicroseconds,
        afterWallClockMilliseconds: lastWallClockMilliseconds,
        notBeforeWallClockMilliseconds,
        revision,
        foreground,
        target: plan.monitor.foreground_target,
        historyCommitment: baselineCommitment,
        requireActivity,
        children: fenceChildren,
      });
      lastSequence = heartbeat.sequence;
      lastEpoch = heartbeat.authorizationEpoch;
      lastMonotonicMicroseconds = heartbeat.monotonicMicroseconds;
      lastWallClockMilliseconds = heartbeat.wallClockMilliseconds;
      fences.push({ name, heartbeat });
      return heartbeat;
    };
    await capture('baseline-stable', 1, false);
    writePrivateJSON(shared.producers, grantProducers);
    await capture('grant-stable', 2, true);
    fs.writeFileSync(shared.phase, 'running\n', { mode: 0o600 });
    for (const state of controllerStates) {
      writePrivateJSON(state.startPath, {
        version: 1,
        execution_nonce: nonce,
        controller_id: state.id,
        phase: 'start',
      });
    }
    await waitFor('both controller mutations to start', operationDeadline, () => {
      if (!controllerStates.every((state) => fs.existsSync(state.mutationStartedPath))) return undefined;
      for (const state of controllerStates) {
        const started = readPrivateJSON(state.mutationStartedPath, `${state.id} mutation-started marker`);
        const controller = plan.controllers.find((entry) => entry.controller_id === state.id);
        if (!exactKeys(started, [
          'version', 'phase', 'execution_nonce', 'controller_id', 'target_id', 'target',
          'timestamp_milliseconds',
        ]) || started.version !== 1 || started.phase !== 'mutation-started'
            || started.execution_nonce !== nonce || started.controller_id !== state.id
            || started.target_id !== state.targetID
            || !sameJSON(started.target, receiptTarget(controller.target))
            || !positiveSafeInteger(started.timestamp_milliseconds)) {
          throw new CoordinatorError(`${state.id} mutation-started marker is not closed and run-bound`);
        }
      }
      return true;
    }, childEntries(controllerStates, observerChild, monitorChild));
    if (controllerStates.some((state) => fs.existsSync(state.mutationCompletedPath))) {
      throw new CoordinatorError('a controller mutation completed before the operations-start fence');
    }
    const operationsStart = await capture('operations-start', 2, true);
    const taskDeadline = Math.min(
      operationsStart.wallClockMilliseconds + externalDeadlineDuration,
      operationDeadline,
    );
    const taskWindow = {
      version: 1,
      execution_nonce: nonce,
      monitor_instance_id: monitorID,
      phase: 'perform',
      request_marker: marker,
      target: plan.monitor.foreground_target,
      task_complete_path: shared.externalTaskComplete,
      deadline_milliseconds: taskDeadline,
    };
    writePrivateJSON(shared.externalWindow, taskWindow);
    emit({
      event: 'external-foreground-window',
      version: 1,
      execution_nonce: nonce,
      monitor_instance_id: monitorID,
      phase: 'perform',
      window_path: shared.externalWindow,
      deadline_milliseconds: taskWindow.deadline_milliseconds,
    });
    await waitForExternalMarker(
      shared.externalTaskComplete, nonce, monitorID, 'task-complete',
      taskDeadline,
      childEntries(controllerStates, observerChild, monitorChild),
    );
    writePrivateJSON(observerPaths.observe, requestMarker('observe', nonce, marker));
    await waitFor('independent foreground observation', operationDeadline, () => (
      fs.existsSync(observerPaths.observation) ? true : undefined
    ), childEntries(controllerStates, observerChild, monitorChild));
    if (controllerStates.some((state) => fs.existsSync(state.mutationCompletedPath))) {
      throw new CoordinatorError('a controller mutation completed before the operations-complete fence');
    }
    const operationsComplete = await capture('operations-complete', 2, true, true);
    const restoreDeadline = Math.min(
      operationsComplete.wallClockMilliseconds + externalDeadlineDuration,
      operationDeadline,
    );
    const restoreWindow = {
      version: 1,
      execution_nonce: nonce,
      monitor_instance_id: monitorID,
      phase: 'restore',
      baseline_value: plan.observer.baseline_value,
      target: plan.monitor.foreground_target,
      sentinel: plan.monitor.sentinel,
      restore_complete_path: shared.externalRestoreComplete,
      deadline_milliseconds: restoreDeadline,
    };
    writePrivateJSON(shared.externalWindow, restoreWindow);
    emit({
      event: 'external-foreground-window',
      version: 1,
      execution_nonce: nonce,
      monitor_instance_id: monitorID,
      phase: 'restore',
      window_path: shared.externalWindow,
      deadline_milliseconds: restoreWindow.deadline_milliseconds,
    });
    await waitForExternalMarker(
      shared.externalRestoreComplete, nonce, monitorID, 'restore-complete',
      restoreDeadline,
      childEntries(controllerStates, observerChild, monitorChild),
    );
    writePrivateJSON(observerPaths.restore, requestMarker('restore', nonce, marker));
    await waitFor('foreground restoration witness and attestation endpoint', operationDeadline, () => (
      fs.existsSync(observerPaths.witness) && fs.existsSync(observerPaths.attestationSocket) ? true : undefined
    ), childEntries(controllerStates, observerChild, monitorChild));
    await waitFor('both controllers at the final-bounds barrier', operationDeadline, () => {
      if (!controllerStates.every((state) => fs.existsSync(state.finalBoundsReadyPath))) return undefined;
      for (const state of controllerStates) {
        const ready = readPrivateJSON(
          state.finalBoundsReadyPath,
          `${state.id} final-bounds readiness`,
        );
        const expectedSlotIDs = catalog.slots
          .filter((slot) => slot.controller_id === state.id && slot.checkpoint !== 'final-bounds')
          .map((slot) => slot.slot_id);
        if (!exactKeys(ready, [
          'version', 'execution_nonce', 'monitor_instance_id', 'controller_id', 'target_id',
          'controller', 'completed_slot_ids', 'ready_at_milliseconds',
        ]) || ready.version !== 1 || ready.execution_nonce !== nonce
            || ready.monitor_instance_id !== monitorID || ready.controller_id !== state.id
            || ready.target_id !== state.targetID
            || !sameJSON(ready.controller, state.controllerProcess)
            || !sameJSON(ready.completed_slot_ids, expectedSlotIDs)
            || !positiveSafeInteger(ready.ready_at_milliseconds)) {
          throw new CoordinatorError(
            `${state.id} final-bounds readiness is not closed and process/run bound`,
          );
        }
      }
      return true;
    }, childEntries(controllerStates, observerChild, monitorChild));
    if (controllerStates.some((state) => fs.existsSync(state.receiptPath))) {
      throw new CoordinatorError('a controller crossed the final-bounds barrier before owner release');
    }
    for (const state of controllerStates) {
      writePrivateJSON(state.finalBoundsStartPath, {
        version: 1,
        execution_nonce: nonce,
        monitor_instance_id: monitorID,
        controller_id: state.id,
        phase: 'final-bounds',
      });
    }
    await waitFor('both persistent controller receipts', operationDeadline, () => (
      controllerStates.every((state) => fs.existsSync(state.receiptPath)) ? true : undefined
    ), childEntries(controllerStates, observerChild, monitorChild));
    collectControllerCorpus(controllerStates, directories['controller-receipts'], directories['raw-bundles']);
    writePrivateJSON(shared.producers, revokeProducers);
    await capture('revoke-stable', 3, false);
    fs.writeFileSync(shared.phase, 'complete\n', { mode: 0o600 });
    const finalSamplePath = path.join(directories.monitor, 'final-sample.json');
    const finalSample = verifiedSentinelSample({
      monitorExecutable,
      outputPath: finalSamplePath,
      directory: directories.monitor,
      sentinel: plan.monitor.sentinel,
      label: 'final',
    });
    if (finalSample.clipboard_change_count !== baselineSample.clipboard_change_count
        || finalSample.clipboard_digest !== baselineSample.clipboard_digest) {
      throw new CoordinatorError('clipboard state was not restored to the monitor baseline');
    }
    const crashFinal = crashInventory(diagnosticReportsDirectory, crashPrefixes);
    if (!sameJSON(crashFinal, crashBaseline)) {
      throw new CoordinatorError('new certification-related crash reports appeared during the run');
    }
    await capture('final-stable', 3, false);
    const witness = readPrivateJSON(observerPaths.witness, 'foreground postcondition witness');
    const expectedWitnessKeys = [
      'version', 'execution_nonce', 'target', 'observer', 'focused_element', 'interval', 'request_marker',
      'before_value_sha256', 'expected_value_sha256', 'observed_value_sha256', 'restored_value_sha256',
      'observation_path', 'observation_file_sha256', 'restoration_path', 'restoration_file_sha256',
      'passed', 'restored',
    ];
    if (!exactKeys(witness, expectedWitnessKeys)
        || witness.execution_nonce !== nonce || witness.request_marker !== marker
        || !focusedElementMatches(
          witness.focused_element, plan.observer.semantic_element, plan.observer.target,
        )
        || !millisecondIntervalIsValid(witness.interval)
        || witness.passed !== true || witness.restored !== true) {
      throw new CoordinatorError('foreground postcondition witness is not closed and run-bound');
    }
    const monitorEvidence = {
      version: 1,
      execution_nonce: nonce,
      monitor_instance_id: monitorID,
      monitor_source_sha256: catalog.monitor_source.probe_sha256,
      coordinator_source_sha256: catalog.current_build_source.coordinator.sha256,
      monitor_process: monitorProcess,
      monitor_attestation_socket_path: shared.attestationSocket,
      sentinel: plan.monitor.sentinel,
      foreground_controller: plan.monitor.foreground_controller,
      foreground_target: plan.monitor.foreground_target,
      producer_sets: { baseline: baselineProducers, grant: grantProducers, revoke: revokeProducers },
      fences,
      baseline_sample: baselineSample,
      final_sample: finalSample,
      foreground_plan: foregroundPlan,
      violation_records: readJSONLines(shared.violations, 'monitor violation history'),
      contamination_records: readJSONLines(shared.contaminations, 'monitor contamination history'),
      baseline_commitment_sha256: baselineCommitment,
      history_commitment_sha256: '0'.repeat(64),
      crash_evidence: {
        version: 1,
        directory: diagnosticReportsDirectory,
        prefixes: crashPrefixes,
        baseline: crashBaseline,
        final: crashFinal,
        new_reports: [],
      },
      restoration: {
        background_final_bounds_slot_ids: catalog.slots
          .filter((slot) => slot.checkpoint === 'final-bounds').map((slot) => slot.slot_id),
        foreground_postcondition_sha256: aggregateSHA256('foreground-postcondition', witness),
        sentinel_sample_sha256: aggregateSHA256('monitor-sample', finalSample),
      },
    };
    if (monitorEvidence.violation_records.length !== 0 || monitorEvidence.contamination_records.length !== 0) {
      throw new CoordinatorError('monitor violation or contamination history is not empty');
    }
    monitorEvidence.fences[0].heartbeat.historyCommitmentSHA256 = baselineCommitment;
    const historyCommitment = aggregateSHA256('monitor-history', monitorHistoryProjection(monitorEvidence));
    monitorEvidence.history_commitment_sha256 = historyCommitment;
    monitorEvidence.fences.at(-1).heartbeat.historyCommitmentSHA256 = historyCommitment;
    writePrivateJSON(shared.evidenceDraft, monitorEvidence);
    writePrivateJSON(shared.sealRequest, {
      version: 1,
      execution_nonce: nonce,
      monitor_instance_id: monitorID,
      phase: 'seal',
      draft_path: shared.evidenceDraft,
      sealed_path: shared.evidence,
      history_commitment_sha256: historyCommitment,
    });
    const sealedReceipt = await waitFor('monitor-owned corpus seal', operationDeadline, () => (
      fs.existsSync(shared.sealReceipt)
        ? readPrivateJSON(shared.sealReceipt, 'monitor corpus seal') : undefined
    ), childEntries(controllerStates, observerChild, monitorChild));
    const sealedEvidence = readPrivateJSON(shared.evidence, 'sealed monitor evidence');
    if (!exactKeys(sealedReceipt, [
      'version', 'execution_nonce', 'monitor_instance_id', 'phase', 'monitor_evidence_sha256',
    ]) || sealedReceipt.version !== 1 || sealedReceipt.execution_nonce !== nonce
        || sealedReceipt.monitor_instance_id !== monitorID || sealedReceipt.phase !== 'sealed'
        || sealedReceipt.monitor_evidence_sha256 !== aggregateSHA256('monitor-evidence', sealedEvidence)
        || !sameJSON(sealedEvidence, monitorEvidence)) {
      throw new CoordinatorError('monitor-owned corpus seal differs from the coordinator draft');
    }
    const finalHeartbeat = readPrivateJSON(shared.heartbeat, 'sealed final monitor heartbeat');
    if (!sameJSON(finalHeartbeat, sealedEvidence.fences.at(-1).heartbeat)) {
      throw new CoordinatorError('live monitor heartbeat differs from the sealed final fence');
    }
    const monitorSocketBefore = requireOwnerSocket(shared.attestationSocket, 'monitor attestation endpoint');
    const observerSocketBefore = requireOwnerSocket(observerPaths.attestationSocket, 'observer attestation endpoint');
    const monitorAttestationDirectory = path.join(directories.attestations, 'monitor');
    const observerAttestationDirectory = path.join(directories.attestations, 'observer');
    fs.mkdirSync(monitorAttestationDirectory, { mode: 0o700 });
    fs.mkdirSync(observerAttestationDirectory, { mode: 0o700 });
    const expectedMonitorPeer = {
      pid: monitorProcess.pid,
      start_identity: monitorProcess.start_identity,
      code_signature_hash: monitorProcess.code_signature_hash,
    };
    await runPIDAttestation({
      controllerExecutable,
      planPath: path.join(monitorAttestationDirectory, 'plan.json'),
      plan: makeAttestationPlan({
        nonce,
        monitorID,
        socketPath: shared.attestationSocket,
        expectedPeer: expectedMonitorPeer,
        kind: 'monitor',
        directory: monitorAttestationDirectory,
        outputPath: path.join(monitorAttestationDirectory, 'response.json'),
      }),
      expectedProcess: expectedMonitorPeer,
      expectedDigest: aggregateSHA256('monitor-evidence', sealedEvidence),
      responseKind: 'monitor',
    });
    await runPIDAttestation({
      controllerExecutable,
      planPath: path.join(observerAttestationDirectory, 'plan.json'),
      plan: makeAttestationPlan({
        nonce,
        monitorID,
        socketPath: observerPaths.attestationSocket,
        expectedPeer: observerReady.observer,
        kind: 'observer',
        directory: observerAttestationDirectory,
        outputPath: path.join(observerAttestationDirectory, 'response.json'),
      }),
      expectedProcess: observerReady.observer,
      expectedDigest: sha256(requirePrivateFile(observerPaths.witness, 'foreground witness bytes')),
      responseKind: 'observer',
    });
    if (!sameJSON(
      requireOwnerSocket(shared.attestationSocket, 'monitor attestation endpoint'),
      monitorSocketBefore,
    ) || !sameJSON(
      requireOwnerSocket(observerPaths.attestationSocket, 'observer attestation endpoint'),
      observerSocketBefore,
    )) {
      throw new CoordinatorError('an attestation endpoint changed during its PID-bound challenge');
    }
    const prepareArgs = [
      'prepare',
      '--controller-receipts', directories['controller-receipts'],
      '--bundles', directories['raw-bundles'],
      '--monitor-evidence', shared.evidence,
      '--foreground-postcondition', observerPaths.witness,
      '--artifacts', directories['prepared-artifacts'],
      '--peekaboo', peekabooExecutable,
      '--output', shared.prepareSummary,
    ];
    finalizerCommand(
      retainedFinalizer,
      runRoot,
      prepareArgs,
      'certification prepare',
      remainingFinalizerTimeoutMilliseconds(globalFinalizerDeadline, finalizerTimeout),
    );
    finalizerCommand(retainedFinalizer, runRoot, [
      'finalize', '--artifacts', directories['prepared-artifacts'],
      '--peekaboo', peekabooExecutable, '--output', shared.summary,
    ], 'final certification', remainingFinalizerTimeoutMilliseconds(
      globalFinalizerDeadline, finalizerTimeout,
    ));
    requirePrivateFile(shared.prepareSummary, 'prepare summary');
    requirePrivateFile(shared.summary, 'final certification summary');
    for (const state of controllerStates) writePrivateJSON(state.releasePath, releaseMarker(nonce));
    writePrivateJSON(observerPaths.release, requestMarker('release', nonce, marker));
    released = true;
    await Promise.all([
      ...controllerStates.map((state) => waitForExit(state.child, state.id, 5000)),
      waitForExit(observerChild, 'foreground observer', 5000),
    ]);
    await terminateChild(monitorChild, 'live monitor');
    const summaryBytes = requirePrivateFile(shared.summary, 'completed certification summary');
    const completion = {
      event: testRuntime ? 'test-runtime-complete' : 'completed',
      version: 1,
      execution_nonce: nonce,
      monitor_instance_id: monitorID,
      run_root: runRoot,
      summary_path: shared.summary,
      summary_size: summaryBytes.length,
      summary_sha256: sha256(summaryBytes),
      certification_eligible: !testRuntime,
    };
    emit(completion);
    return completion;
  } catch (error) {
    emit({
      event: 'failed',
      version: 1,
      execution_nonce: nonce,
      monitor_instance_id: monitorID,
      run_root: runRoot,
      reason: error.message,
    });
    throw error;
  } finally {
    if (!released) {
      for (const state of controllerStates) {
        try { if (!fs.existsSync(state.releasePath)) writePrivateJSON(state.releasePath, releaseMarker(nonce)); } catch {}
      }
      if (observerChild) {
        try {
          const release = path.join(directories.observer, 'observer-release.json');
          if (!fs.existsSync(release)) writePrivateJSON(release, requestMarker(
            'release', nonce, `peekaboo-foreground-postcondition:${nonce}`,
          ));
        } catch {}
      }
    }
    for (const state of controllerStates) {
      try { await terminateChild(state.child, state.id); } catch {}
    }
    try { await terminateChild(observerChild, 'foreground observer'); } catch {}
    try { await terminateChild(monitorChild, 'live monitor'); } catch {}
  }
}

async function main() {
  process.umask(0o077);
  const args = parseArguments(process.argv.slice(2));
  if (args.action === 'help') {
    process.stdout.write(HELP);
    return;
  }
  if (args.action === 'version') {
    process.stdout.write('peekaboo-live-multi-target-coordinator 1\n');
    return;
  }
  const testRuntimeAllowed = process.env.PEEKABOO_COORDINATOR_TEST_RUNTIME === '1';
  const planPath = requireAbsolute(args.plan, 'plan');
  const plan = parseJSON(requirePrivateFile(planPath, 'live coordinator plan', 1024 * 1024), 'live coordinator plan');
  const catalogPath = testRuntimeAllowed ? plan.test_runtime?.catalog_path : DEFAULT_CATALOG_PATH;
  const finalizerPath = testRuntimeAllowed ? plan.test_runtime?.finalizer_path : DEFAULT_FINALIZER_PATH;
  if (!catalogPath || !finalizerPath) throw new CoordinatorError('test runtime requires explicit catalog/finalizer paths');
  const catalog = parseJSON(fs.readFileSync(catalogPath), 'certification catalog');
  const currentBuildSource = deriveCurrentBuildSource(catalog, testRuntimeAllowed);
  const diagnosticReportsDirectory = canonicalDiagnosticReportsDirectory(
    testRuntimeAllowed
      ? plan.test_runtime?.diagnostic_reports_path
      : path.join(os.userInfo().homedir, 'Library', 'Logs', 'DiagnosticReports'),
  );
  validatePlan(
    plan,
    catalog,
    testRuntimeAllowed,
    currentBuildSource.commit,
    diagnosticReportsDirectory,
  );
  const retainedFinalizer = retainFinalizerSource(finalizerPath, catalog, testRuntimeAllowed);
  await runCoordinator(
    plan,
    catalog,
    retainedFinalizer,
    diagnosticReportsDirectory,
    testRuntimeAllowed,
    currentBuildSource.commit,
  );
}

const invokedAsScript = (() => {
  if (!process.argv[1]) return false;
  try {
    return fs.realpathSync(process.argv[1]) === SCRIPT_PATH;
  } catch {
    return false;
  }
})();
if (invokedAsScript) {
  main().catch((error) => {
    process.stderr.write(`live multi-target coordinator: ${error.message}\n`);
    process.exitCode = error instanceof CoordinatorError ? 1 : 2;
  });
}
