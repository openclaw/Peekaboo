#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export class QualificationError extends Error {}

export function requireCondition(condition, message) {
  if (!condition) throw new QualificationError(message);
}

export function isPlainObject(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

export function exactKeys(value, keys, label) {
  requireCondition(isPlainObject(value), `${label} must be one object`);
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  requireCondition(
    actual.length === expected.length && actual.every((key, index) => key === expected[index]),
    `${label} keys are not closed`,
  );
}

export function canonicalValue(value) {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
  if (typeof value === 'number') {
    requireCondition(Number.isFinite(value) && !Object.is(value, -0), 'canonical JSON excludes lossy numbers');
    requireCondition(!Number.isInteger(value) || Number.isSafeInteger(value), 'canonical JSON excludes unsafe integers');
    return value;
  }
  if (Array.isArray(value)) return value.map(canonicalValue);
  requireCondition(isPlainObject(value), 'canonical JSON accepts only plain JSON values');
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalValue(value[key])]));
}

export function canonicalBytes(value) {
  return Buffer.from(JSON.stringify(canonicalValue(value)), 'utf8');
}

export function sameJSON(left, right) {
  try {
    return canonicalBytes(left).equals(canonicalBytes(right));
  } catch {
    return false;
  }
}

const AGENT_MUTATING_TOOL_NAMES = new Set([
  'action', 'app', 'click', 'dialog', 'dock', 'drag', 'menu', 'move', 'paste', 'press',
  'scroll', 'set_value', 'space', 'type', 'window',
]);

export function normalizedAgentToolName(value) {
  return typeof value === 'string'
    ? value.trim().replaceAll('-', '_').toLowerCase()
    : '';
}

export function isAgentMutatingToolName(value) {
  return AGENT_MUTATING_TOOL_NAMES.has(normalizedAgentToolName(value));
}

function rejectAgentForegroundArguments(value, label) {
  if (Array.isArray(value)) {
    value.forEach((entry) => rejectAgentForegroundArguments(entry, label));
    return;
  }
  if (!value || typeof value !== 'object') return;
  for (const [key, entry] of Object.entries(value)) {
    const normalized = key.trim().replaceAll('-', '_').toLowerCase();
    requireCondition(!(normalized === 'foreground' && entry === true),
      `${label} requested foreground=true`);
    requireCondition(!(['mode', 'delivery_mode', 'capture_focus'].includes(normalized)
      && typeof entry === 'string' && entry.toLowerCase() === 'foreground'),
    `${label} requested foreground mode`);
    rejectAgentForegroundArguments(entry, label);
  }
}

export function validateAgentExecutionTrace(root, label = 'Agent JSON result') {
  requireCondition(root?.success === true && isPlainObject(root.result),
    `${label} did not succeed`);
  const trace = root.result.executionTrace;
  exactKeys(trace, ['entries', 'totalCallCount', 'truncated'], `${label} executionTrace`);
  requireCondition(Array.isArray(trace.entries) && trace.entries.length > 0,
    `${label} execution trace is empty`);
  requireCondition(trace.truncated === false && trace.totalCallCount === trace.entries.length,
    `${label} execution trace is incomplete`);
  const ids = new Set();
  const entriesByID = new Map();
  const entryIndexByID = new Map();
  const dispatchedCallIDs = new Set();
  for (const [index, entry] of trace.entries.entries()) {
    const keys = Object.keys(entry).sort();
    const required = ['arguments', 'disposition', 'id', 'isError', 'name', 'result'];
    requireCondition(required.every((key) => keys.includes(key))
      && keys.every((key) => [...required, 'mutationDispatch', 'actionOutcome'].includes(key)),
    `${label} trace entry ${index} keys are not closed`);
    requireCondition(typeof entry.id === 'string' && entry.id.length > 0 && !ids.has(entry.id),
      `${label} trace entry ${index} ID is invalid`);
    ids.add(entry.id);
    entriesByID.set(entry.id, entry);
    entryIndexByID.set(entry.id, index);
    const name = normalizedAgentToolName(entry.name);
    requireCondition(name && name !== 'shell', `${label} trace contains Shell`);
    rejectAgentForegroundArguments(entry.arguments, `${label} trace entry ${entry.id}`);
    requireCondition(entry.mutationDispatch !== 'possibly_dispatched',
      `${label} trace entry ${entry.id} is possibly dispatched`);
    if (entry.mutationDispatch === 'dispatched') dispatchedCallIDs.add(entry.id);
    requireCondition(entry.actionOutcome?.delivery_mode !== 'foreground',
      `${label} trace entry ${entry.id} used foreground delivery`);
    if (isAgentMutatingToolName(name)) {
      requireCondition(entry.disposition === 'executed/succeeded' && entry.isError === false,
        `${label} mutation ${entry.id} did not succeed`);
      requireCondition(entry.mutationDispatch === 'dispatched',
        `${label} mutation ${entry.id} was not definitely dispatched`);
      requireCondition(entry.actionOutcome?.delivery_mode === 'background',
        `${label} mutation ${entry.id} lacks background outcome authority`);
    } else {
      requireCondition(entry.disposition === 'executed/succeeded' && entry.isError === false,
        `${label} observation ${entry.id} did not succeed`);
    }
  }
  return { root, trace, entriesByID, entryIndexByID, dispatchedCallIDs };
}

export function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

const CANONICAL_BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

export function strictBase64Bytes(value, label, { maximumBytes = 256 * 1024 * 1024 } = {}) {
  requireCondition(typeof value === 'string'
    && Number.isSafeInteger(maximumBytes) && maximumBytes >= 0
    && value.length <= Math.ceil(maximumBytes / 3) * 4
    && CANONICAL_BASE64.test(value),
  `${label} is not bounded canonical base64`);
  const bytes = Buffer.from(value, 'base64');
  requireCondition(bytes.length <= maximumBytes && bytes.toString('base64') === value,
    `${label} is not bounded canonical base64`);
  return bytes;
}

export function decodeCanonicalBase64JSON(
  value,
  label,
  { maximumBytes = 64 * 1024 * 1024 } = {},
) {
  const bytes = strictBase64Bytes(value, label, { maximumBytes });
  let decoded;
  try {
    decoded = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  } catch (error) {
    throw new QualificationError(`${label} is not canonical JSON: ${error.message}`);
  }
  requireCondition(isPlainObject(decoded) && canonicalBytes(decoded).equals(bytes),
    `${label} is not one canonical JSON object`);
  return { bytes, value: decoded, sha256: sha256(bytes) };
}

export const HEX40 = /^[0-9a-f]{40}$/;
export const HEX64 = /^[0-9a-f]{64}$/;
export const TEAM_ID = /^[A-Z0-9]{10}$/;
export const POSITIVE_DECIMAL = /^[1-9][0-9]*$/;
export const NONNEGATIVE_DECIMAL = /^(0|[1-9][0-9]*)$/;
export const LOWERCASE_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const UINT64_MAX = 0xffff_ffff_ffff_ffffn;

export function positiveInteger(value) {
  return Number.isSafeInteger(value) && value > 0;
}

export function positiveDecimal(value) {
  if (typeof value !== 'string' || !POSITIVE_DECIMAL.test(value)) return false;
  try {
    return BigInt(value) <= UINT64_MAX;
  } catch {
    return false;
  }
}

export function nonnegativeDecimal(value) {
  if (typeof value !== 'string' || !NONNEGATIVE_DECIMAL.test(value)) return false;
  try {
    return BigInt(value) <= UINT64_MAX;
  } catch {
    return false;
  }
}

export function authenticatedBridgeReceiptIdentity(payload, report, label) {
  const payloadIdentity = {
    request_id: String(payload?.requestID ?? '').toLowerCase(),
    session_id: String(payload?.sessionID ?? '').toLowerCase(),
    session_sequence: payload?.sessionSequence,
    listener_instance_id: String(payload?.listenerInstanceID ?? '').toLowerCase(),
    client_instance_id: String(payload?.clientInstanceID ?? '').toLowerCase(),
  };
  requireCondition(
    LOWERCASE_UUID.test(payloadIdentity.request_id)
      && LOWERCASE_UUID.test(payloadIdentity.session_id)
      && nonnegativeDecimal(payloadIdentity.session_sequence)
      && LOWERCASE_UUID.test(payloadIdentity.listener_instance_id)
      && LOWERCASE_UUID.test(payloadIdentity.client_instance_id),
    `${label} signed request/session/listener identity is malformed`,
  );
  requireCondition(
    report?.request_id === payloadIdentity.request_id
      && report?.session_id === payloadIdentity.session_id
      && report?.session_sequence === payloadIdentity.session_sequence
      && report?.listener_instance_id === payloadIdentity.listener_instance_id
      && report?.client_instance_id === payloadIdentity.client_instance_id,
    `${label} authenticated request/session/listener identity differs from its signed payload`,
  );
  return {
    ...payloadIdentity,
    request_key: `${payloadIdentity.listener_instance_id}:${payloadIdentity.request_id}`,
    session_claim_key: [
      payloadIdentity.listener_instance_id,
      payloadIdentity.session_id,
      payloadIdentity.session_sequence,
    ].join(':'),
  };
}

export function requireUniqueAuthenticatedBridgeReceipts(entries, label) {
  const dimensions = [
    ['a bundle SHA-256', (entry) => entry.bundle.sha256],
    ['an authenticated request identity', (entry) => entry.identity.request_key],
    ['an authenticated session claim', (entry) => entry.identity.session_claim_key],
  ];
  for (const [dimension, project] of dimensions) {
    const values = entries.map(project);
    requireCondition(new Set(values).size === values.length,
      `${label} reuses ${dimension}`);
  }
}

export function absolutePath(value, label) {
  requireCondition(typeof value === 'string' && path.isAbsolute(value) && !value.includes('\0'), `${label} must be absolute`);
  return value;
}

function sameStat(left, right) {
  return left.dev === right.dev && left.ino === right.ino && left.size === right.size
    && left.mtimeNs === right.mtimeNs && left.ctimeNs === right.ctimeNs;
}

export function requirePrivateDirectory(directory, label, { empty = false } = {}) {
  absolutePath(directory, label);
  const info = fs.lstatSync(directory, { bigint: true });
  requireCondition(
    info.isDirectory() && !info.isSymbolicLink() && (info.mode & 0o077n) === 0n
      && (typeof process.geteuid !== 'function' || info.uid === BigInt(process.geteuid())),
    `${label} must be one owner-private real directory`,
  );
  requireCondition(fs.realpathSync(directory) === directory, `${label} must be canonical`);
  if (empty) requireCondition(fs.readdirSync(directory).length === 0, `${label} must be empty`);
  return directory;
}

export function readStableFile(filePath, label, {
  privateFile = true,
  maximumBytes = 16 * 1024 * 1024,
  allowRootOwner = false,
  requireSingleLink = true,
} = {}) {
  absolutePath(filePath, label);
  const lstat = fs.lstatSync(filePath, { bigint: true });
  const modeMask = privateFile ? 0o077n : 0o022n;
  requireCondition(
    lstat.isFile() && !lstat.isSymbolicLink() && (!requireSingleLink || lstat.nlink === 1n)
      && lstat.size <= BigInt(maximumBytes) && (lstat.mode & modeMask) === 0n
      && (typeof process.geteuid !== 'function'
        || lstat.uid === BigInt(process.geteuid())
        || (allowRootOwner && lstat.uid === 0n)),
    `${label} must be one bounded owner-${privateFile ? 'private' : 'stable'} regular file`,
  );
  const descriptor = fs.openSync(filePath, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
  try {
    const before = fs.fstatSync(descriptor, { bigint: true });
    requireCondition(sameStat(lstat, before), `${label} changed before read`);
    const bytes = fs.readFileSync(descriptor);
    const after = fs.fstatSync(descriptor, { bigint: true });
    requireCondition(sameStat(before, after) && BigInt(bytes.length) === after.size, `${label} changed during read`);
    return { path: filePath, bytes, info: after, sha256: sha256(bytes) };
  } finally {
    fs.closeSync(descriptor);
  }
}

export function readStableJSON(filePath, label, options) {
  const retained = readStableFile(filePath, label, options);
  let value;
  try {
    value = JSON.parse(retained.bytes);
  } catch (error) {
    throw new QualificationError(`${label} is not JSON: ${error.message}`);
  }
  requireCondition(isPlainObject(value), `${label} must contain one JSON object`);
  return { ...retained, value };
}

export function readStableJSONLines(filePath, label, options) {
  const retained = readStableFile(filePath, label, options);
  const text = retained.bytes.toString('utf8');
  requireCondition(text.length > 0 && text.endsWith('\n'), `${label} must be nonempty and newline-terminated`);
  const values = text.trimEnd().split('\n').map((line, index) => {
    try {
      const value = JSON.parse(line);
      requireCondition(isPlainObject(value), `${label} row ${index + 1} is not an object`);
      return value;
    } catch (error) {
      if (error instanceof QualificationError) throw error;
      throw new QualificationError(`${label} row ${index + 1} is not JSON: ${error.message}`);
    }
  });
  return { ...retained, values };
}

export function requireStableExecutable(filePath, label, { allowRootOwner = false } = {}) {
  const retained = readStableFile(filePath, label, {
    privateFile: false,
    maximumBytes: 512 * 1024 * 1024,
    allowRootOwner,
  });
  requireCondition((retained.info.mode & 0o111n) !== 0n, `${label} must be executable`);
  requireCondition(fs.realpathSync(filePath) === filePath, `${label} must be canonical`);
  return retained;
}

export const OBSERVATION_TIME_SKEW_MILLISECONDS = 2000;

export function corroboratedObservationTime(retained, label) {
  const observedAt = retained.value?.observed_at_milliseconds;
  const modifiedAt = Number(retained.info.mtimeNs / 1_000_000n);
  requireCondition(positiveInteger(observedAt), `${label} observation time is invalid`);
  requireCondition(Number.isSafeInteger(modifiedAt)
    && Math.abs(modifiedAt - observedAt) <= OBSERVATION_TIME_SKEW_MILLISECONDS,
  `${label} file time does not corroborate its observation time`);
  return {
    observed_at_milliseconds: observedAt,
    retained_mtime_milliseconds: modifiedAt,
  };
}

export function authenticateLiveBridgeBundle({
  executablePath,
  expectedExecutableSHA256,
  socketPath,
  trustedHostTeamIDs,
  expectedHost,
  bundlePath,
  label,
}) {
  requireCondition(HEX64.test(expectedExecutableSHA256 ?? ''),
    `${label} validator executable digest is invalid`);
  absolutePath(socketPath, `${label} Bridge socket`);
  requireCondition(Array.isArray(trustedHostTeamIDs) && trustedHostTeamIDs.length > 0
    && trustedHostTeamIDs.every((teamID) => TEAM_ID.test(teamID))
    && new Set(trustedHostTeamIDs).size === trustedHostTeamIDs.length,
  `${label} trusted Bridge host teams are invalid`);
  exactKeys(expectedHost, [
    'host_kind', 'process_identifier', 'process_start_identity_decimal', 'code_signature_hash',
    'source_commit',
  ], `${label} expected Bridge host`);
  requireCondition(expectedHost.host_kind === 'gui'
    && positiveInteger(expectedHost.process_identifier)
    && positiveDecimal(expectedHost.process_start_identity_decimal)
    && HEX40.test(expectedHost.code_signature_hash ?? '')
    && HEX40.test(expectedHost.source_commit ?? ''),
  `${label} expected Bridge host is malformed`);
  const before = requireStableExecutable(executablePath, `${label} validator executable`, {
    allowRootOwner: true,
  });
  requireCondition(before.sha256 === expectedExecutableSHA256,
    `${label} validator executable differs from the bound Agent executable`);
  const arguments_ = [
    'bridge', 'receipt', 'validate', '--bundle', bundlePath,
    '--bridge-socket', socketPath,
    ...trustedHostTeamIDs.flatMap((teamID) => ['--trusted-host-team-id', teamID]),
    '--json',
  ];
  const run = spawnSync(executablePath, arguments_, {
    encoding: 'utf8',
    timeout: 30_000,
    maxBuffer: 16 * 1024 * 1024,
  });
  const after = requireStableExecutable(executablePath, `${label} validator executable`, {
    allowRootOwner: true,
  });
  requireCondition(before.sha256 === after.sha256 && after.sha256 === expectedExecutableSHA256,
    `${label} validator executable changed during authenticated validation`);
  requireCondition(!run.error && run.status === 0,
    `${label} authenticated live validation failed: ${run.stderr?.trim() || run.error?.message || run.status}`);
  let envelope;
  try {
    envelope = JSON.parse(run.stdout);
  } catch (error) {
    throw new QualificationError(`${label} authenticated live validation returned invalid JSON: ${error.message}`);
  }
  requireCondition(isPlainObject(envelope)
    && Object.keys(envelope).every((key) => ['success', 'data', 'debug_logs'].includes(key))
    && envelope.success === true && isPlainObject(envelope.data)
    && (envelope.debug_logs === undefined
      || (Array.isArray(envelope.debug_logs)
        && envelope.debug_logs.every((entry) => typeof entry === 'string'))),
  `${label} authenticated live validation returned an invalid envelope`);
  requireCondition(envelope.data.host?.pid === expectedHost.process_identifier
    && envelope.data.host?.start_identity === expectedHost.process_start_identity_decimal
    && envelope.data.host?.code_signature_hash === expectedHost.code_signature_hash
    && envelope.data.host_source_commit === expectedHost.source_commit,
  `${label} authenticated validator reached another Bridge host/build`);
  return envelope.data;
}

const AGENT_EXECUTION_ENVIRONMENT_KEYS = new Set([
  'PATH', 'HOME', 'LANG', 'LC_ALL', 'LC_CTYPE', 'LOGNAME', 'SSL_CERT_DIR',
  'SSL_CERT_FILE', 'TMPDIR', 'TZ', 'USER', 'ANTHROPIC_API_KEY', 'GEMINI_API_KEY',
  'GOOGLE_API_KEY', 'GROK_API_KEY', 'MINIMAX_API_KEY', 'MOONSHOT_API_KEY',
  'OPENAI_API_KEY', 'OPENROUTER_API_KEY', 'X_AI_API_KEY', 'XAI_API_KEY',
  'PEEKABOO_OPERATION_RECEIPT_DIRECTORY', 'PEEKABOO_AGENT_EXECUTION_GATE_FD',
  'PEEKABOO_AGENT_EXECUTION_GATE_CHALLENGE', 'PEEKABOO_AGENT_EXECUTION_LOCKDOWN_FD',
  'PEEKABOO_AGENT_EXECUTION_PROCESS_LIMIT',
]);

const AGENT_EXECUTION_MANDATORY_ENVIRONMENT_KEYS = [
  'PATH', 'PEEKABOO_OPERATION_RECEIPT_DIRECTORY', 'PEEKABOO_AGENT_EXECUTION_GATE_FD',
  'PEEKABOO_AGENT_EXECUTION_GATE_CHALLENGE', 'PEEKABOO_AGENT_EXECUTION_LOCKDOWN_FD',
  'PEEKABOO_AGENT_EXECUTION_PROCESS_LIMIT',
];

const AGENT_EXECUTION_REQUEST_KEYS = [
  'task', 'maxSteps', 'runRootPath', 'coordinationReceiptPath', 'acknowledgementPath',
  'startTimeoutMilliseconds', 'runTimeoutMilliseconds',
];

const AGENT_EXECUTION_OUTCOME = {
  state: 'dispatched_unverified',
  effect: 'unverifiable',
  route: 'bridge',
  delivery_mechanism: 'native_framework',
  delivery_mode: 'background',
  evidence: 'delivery_accepted',
  dispatch_state: 'dispatched',
  dispatched_unit_count: 1,
  retry_safety: 'unsafe',
  escalation: 'observe_before_retry',
  mutation_dispatched: true,
  retry_safe: false,
  requires_fresh_observation: true,
};

function canonicalPositiveUInt64(value) {
  return positiveDecimal(value);
}

function bridgeProcessIdentity(value, label) {
  requireCondition(isPlainObject(value)
    && positiveInteger(value.processIdentifier)
    && canonicalPositiveUInt64(value.processStartIdentity)
    && HEX40.test(value.codeSignatureHash ?? ''),
  `${label} is malformed`);
  return value;
}

function agentExecutionByteEvidence(value, label, { maximumBytes = 16 * 1024 * 1024 } = {}) {
  requireCondition(isPlainObject(value)
    && Number.isSafeInteger(value.byteCount) && value.byteCount >= 0
    && HEX64.test(value.sha256 ?? '')
    && typeof value.truncated === 'boolean'
    && (value.readErrorCode === undefined || value.readErrorCode === null
      || Number.isSafeInteger(value.readErrorCode)),
  `${label} is malformed`);
  const bytes = strictBase64Bytes(value.bytes, `${label}.bytes`, { maximumBytes });
  requireCondition(value.byteCount === bytes.length && value.sha256 === sha256(bytes),
    `${label} byte commitment is invalid`);
  return { value, bytes };
}

function projectedAgentExecutionRequest(decoded, label) {
  exactKeys(decoded, ['projectedAction'], label);
  exactKeys(decoded.projectedAction, ['_0'], `${label}.projectedAction`);
  const projection = decoded.projectedAction._0;
  exactKeys(projection, ['request'], `${label}.projectedAction._0`);
  exactKeys(projection.request, ['agentExecutionTrace'], `${label} semantic request`);
  exactKeys(projection.request.agentExecutionTrace, ['_0'], `${label} Agent request case`);
  const request = projection.request.agentExecutionTrace._0;
  exactKeys(request, AGENT_EXECUTION_REQUEST_KEYS, `${label} Agent request`);
  return request;
}

function projectedAgentExecutionResponse(decoded, label) {
  exactKeys(decoded, ['projectedAction'], label);
  exactKeys(decoded.projectedAction, ['_0'], `${label}.projectedAction`);
  const projection = decoded.projectedAction._0;
  exactKeys(projection, ['outcome', 'response'], `${label}.projectedAction._0`);
  exactKeys(projection.response, ['agentExecutionTrace'], `${label} semantic response`);
  exactKeys(projection.response.agentExecutionTrace, ['_0'], `${label} Agent response case`);
  return { outcome: projection.outcome, response: projection.response.agentExecutionTrace._0 };
}

function validateAgentExecutionRequest(request, expectedRequest, socketPath, label) {
  exactKeys(expectedRequest, AGENT_EXECUTION_REQUEST_KEYS, `${label} expected request`);
  requireCondition(typeof request.task === 'string' && request.task.length > 0
    && !request.task.startsWith('-') && !request.task.includes('\0')
    && Buffer.byteLength(request.task, 'utf8') <= 256 * 1024
    && Number.isSafeInteger(request.maxSteps) && request.maxSteps >= 1 && request.maxSteps <= 100
    && Number.isSafeInteger(request.startTimeoutMilliseconds)
    && request.startTimeoutMilliseconds >= 1 && request.startTimeoutMilliseconds <= 120_000
    && Number.isSafeInteger(request.runTimeoutMilliseconds)
    && request.runTimeoutMilliseconds >= 1 && request.runTimeoutMilliseconds <= 7_200_000,
  `${label} Agent request is malformed`);
  for (const [key, basename] of [
    ['coordinationReceiptPath', 'agent-execution-coordination.json'],
    ['acknowledgementPath', 'agent-execution-ack.json'],
  ]) {
    absolutePath(request[key], `${label} ${key}`);
    requireCondition(path.dirname(request[key]) === request.runRootPath
      && path.basename(request[key]) === basename,
    `${label} ${key} is not the canonical run-root path`);
  }
  absolutePath(request.runRootPath, `${label} run root`);
  absolutePath(socketPath, `${label} Bridge socket`);
  requireCondition(sameJSON(request, expectedRequest),
    `${label} signed Agent request differs from the expected invocation`);
}

function validateAgentExecutionResponse(response, request, {
  executablePath,
  expectedExecutableSHA256,
  socketPath,
  payload,
  report,
  label,
}) {
  requireCondition(isPlainObject(response) && response.version === 1,
    `${label} terminal response is malformed`);
  const process = response.process;
  requireCondition(isPlainObject(process), `${label} child process is malformed`);
  const child = bridgeProcessIdentity(process.processIdentity, `${label} child process identity`);
  const requester = bridgeProcessIdentity(response.requestingPeer, `${label} requesting peer`);
  requireCondition(child.processIdentifier !== requester.processIdentifier
    && child.codeSignatureHash === requester.codeSignatureHash
    && process.executablePath === executablePath
    && process.executableSHA256 === expectedExecutableSHA256,
  `${label} child/requester executable identity is inconsistent`);
  requireCondition(report.client?.pid === requester.processIdentifier
    && report.client?.start_identity === requester.processStartIdentity
    && report.client?.code_signature_hash === requester.codeSignatureHash
    && payload.client.processIdentifier === requester.processIdentifier
    && payload.client.processStartIdentity === requester.processStartIdentity
    && payload.client.codeSignatureHash === requester.codeSignatureHash,
  `${label} signed requester differs from the authenticated client`);

  const target = payload.target;
  exactKeys(target, ['kind', 'processIdentifier', 'processStartIdentity'],
    `${label} signed child target`);
  requireCondition(target.kind === 'process'
    && target.processIdentifier === child.processIdentifier
    && target.processStartIdentity === child.processStartIdentity,
  `${label} signed child target differs from the terminal process`);

  const expectedReceiptDirectory = path.join(request.runRootPath, 'agent-operation-receipts');
  const expectedArguments = [
    'agent', 'run', request.task, '--no-cache', '--max-steps', String(request.maxSteps),
    '--bridge-socket', socketPath, '--json',
  ];
  requireCondition(response.bridgeSocketPath === socketPath
    && response.runRootPath === request.runRootPath
    && response.coordinationReceiptPath === request.coordinationReceiptPath
    && response.acknowledgementPath === request.acknowledgementPath
    && response.operationReceiptDirectoryPath === expectedReceiptDirectory
    && response.taskSHA256 === sha256(Buffer.from(request.task, 'utf8'))
    && response.maxSteps === request.maxSteps
    && response.startTimeoutMilliseconds === request.startTimeoutMilliseconds
    && response.runTimeoutMilliseconds === request.runTimeoutMilliseconds
    && sameJSON(response.arguments, expectedArguments)
    && response.argumentsSHA256 === sha256(canonicalBytes(expectedArguments))
    && response.backgroundOnly === true
    && response.allowForeground === false
    && response.shellAvailable === false
    && response.processCreationLimit === 0,
  `${label} terminal response differs from its exact request or background policy`);

  const environmentKeys = response.environmentKeys;
  requireCondition(response.environmentPolicyVersion === 3
    && Array.isArray(environmentKeys) && environmentKeys.length > 0
    && environmentKeys.every((key) => typeof key === 'string'
      && AGENT_EXECUTION_ENVIRONMENT_KEYS.has(key))
    && environmentKeys.every((key, index) => index === 0 || environmentKeys[index - 1] < key)
    && new Set(environmentKeys).size === environmentKeys.length
    && AGENT_EXECUTION_MANDATORY_ENVIRONMENT_KEYS.every((key) => environmentKeys.includes(key))
    && HEX64.test(response.environmentSHA256 ?? ''),
  `${label} closed Agent environment policy is malformed`);

  const stdout = agentExecutionByteEvidence(response.stdout, `${label} stdout`);
  const stderr = agentExecutionByteEvidence(response.stderr, `${label} stderr`);
  const coordinationReceipt = agentExecutionByteEvidence(
    response.coordinationReceipt,
    `${label} coordination receipt`,
  );
  const acknowledgement = agentExecutionByteEvidence(
    response.acknowledgement,
    `${label} acknowledgement`,
  );
  requireCondition(stdout.bytes.length + stderr.bytes.length <= 16 * 1024 * 1024
    && stdout.value.truncated === false && stdout.value.readErrorCode == null
    && stderr.value.truncated === false && stderr.value.readErrorCode == null
    && coordinationReceipt.value.truncated === false
    && coordinationReceipt.value.readErrorCode == null
    && acknowledgement.value.truncated === false && acknowledgement.value.readErrorCode == null,
  `${label} retained output or coordination evidence is incomplete`);

  const times = [
    response.spawnedAt,
    response.lockdownAcknowledgedAt,
    response.coordinationReceiptPublishedAt,
    response.acknowledgedAt,
    response.releasedAt,
    response.terminalObservationEndedAt,
  ];
  requireCondition(times.every(positiveInteger)
    && times.every((value, index) => index === 0 || times[index - 1] <= value)
    && positiveInteger(payload.startedAtUnixMilliseconds)
    && positiveInteger(payload.completedAtUnixMilliseconds)
    && payload.startedAtUnixMilliseconds <= response.spawnedAt
    && payload.completedAtUnixMilliseconds >= response.terminalObservationEndedAt,
  `${label} signed Agent lifecycle is incomplete or contradictory`);

  requireCondition(response.processDisposition === 'exited'
    && response.exitCode === 0 && response.terminationSignal == null
    && response.outputDisposition === 'validated_execution_trace',
  `${label} Agent did not produce one successful zero-exit terminal result`);

  let stdoutRoot;
  try {
    stdoutRoot = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(stdout.bytes));
  } catch (error) {
    throw new QualificationError(`${label} retained Agent stdout is not one JSON value: ${error.message}`);
  }
  requireCondition(isPlainObject(stdoutRoot) && stdoutRoot.success === true
    && isPlainObject(stdoutRoot.result),
  `${label} retained Agent stdout did not report success`);
  const trace = stdoutRoot.result.executionTrace;
  exactKeys(trace, ['entries', 'totalCallCount', 'truncated'], `${label} execution trace`);
  requireCondition(Array.isArray(trace.entries) && trace.entries.length > 0
    && trace.truncated === false && trace.totalCallCount === trace.entries.length
    && sameJSON(response.executionTrace, trace),
  `${label} signed execution trace is incomplete or not derived from stdout`);
  return {
    process,
    child,
    requester,
    stdout,
    stderr,
    coordinationReceipt,
    acknowledgement,
    stdoutRoot,
    trace,
  };
}

export function authenticateAgentExecutionTerminalBundle({
  bundlePath,
  validatorReportPath,
  executablePath,
  expectedExecutableSHA256,
  socketPath,
  trustedHostTeamIDs,
  expectedHost,
  expectedRequest,
  label = 'Agent execution terminal bundle',
  authenticateBundle = authenticateLiveBridgeBundle,
}) {
  const bundle = readStableJSON(bundlePath, label, {
    maximumBytes: 256 * 1024 * 1024,
    requireSingleLink: false,
  });
  const validator = readStableJSON(validatorReportPath, `${label} live validator`);
  exactKeys(validator.value, ['success', 'data'], `${label} live validator`);
  requireCondition(validator.value.success === true && isPlainObject(validator.value.data),
    `${label} retained live validator did not succeed`);
  const report = authenticateBundle({
    executablePath,
    expectedExecutableSHA256,
    socketPath,
    trustedHostTeamIDs,
    expectedHost,
    bundlePath: bundle.path,
    label,
  });
  requireCondition(sameJSON(validator.value.data, report),
    `${label} retained validator differs from authenticated live validation`);

  const payload = bundle.value?.receipt?.payload;
  requireCondition(isPlainObject(payload) && payload.schemaVersion === 1
    && payload.operation === 'agentExecutionTrace'
    && isPlainObject(payload.client)
    && HEX64.test(payload.listenerPublicKeySHA256 ?? ''),
  `${label} signed operation payload is malformed`);
  const identity = authenticatedBridgeReceiptIdentity(payload, report, label);
  const request = decodeCanonicalBase64JSON(
    bundle.value.canonicalRequest,
    `${label} canonical request`,
  );
  const response = decodeCanonicalBase64JSON(
    bundle.value.canonicalResponse,
    `${label} canonical response`,
  );
  requireCondition(report?.valid === true
    && report.validator_id === 'peekaboo-bridge-receipt-validate-v1'
    && report.trust_source === 'authenticated_live_listener'
    && report.minimum_protocol_version === '1.29'
    && report.host_protocol_version === '1.31'
    && report.terminal_receipt_attested === true
    && report.target_attested === true
    && report.outcome_attested === true
    && report.retention_basis === 'exported_bundle'
    && report.bundle_sha256 === bundle.sha256
    && report.operation === payload.operation
    && report.listener_public_key_sha256 === payload.listenerPublicKeySHA256
    && report.request_sha256 === payload.requestSHA256
    && report.request_sha256 === request.sha256
    && report.response_sha256 === payload.responseSHA256
    && report.response_sha256 === response.sha256,
  `${label} validator is not bound to one protocol-1.31 terminal bundle`);

  const semanticRequest = projectedAgentExecutionRequest(request.value, `${label} request`);
  validateAgentExecutionRequest(semanticRequest, expectedRequest, socketPath, label);
  const semanticResponse = projectedAgentExecutionResponse(response.value, `${label} response`);
  requireCondition(sameJSON(semanticResponse.outcome, AGENT_EXECUTION_OUTCOME)
    && sameJSON(payload.outcome, AGENT_EXECUTION_OUTCOME),
  `${label} lacks the canonical background external-process outcome`);
  const terminal = validateAgentExecutionResponse(semanticResponse.response, semanticRequest, {
    executablePath,
    expectedExecutableSHA256,
    socketPath,
    payload,
    report,
    label,
  });
  return {
    bundle,
    validator,
    report,
    payload,
    identity,
    canonicalRequest: request,
    canonicalResponse: response,
    request: semanticRequest,
    response: semanticResponse.response,
    outcome: semanticResponse.outcome,
    ...terminal,
  };
}

export function writePrivateExclusive(filePath, value) {
  absolutePath(filePath, 'output');
  requirePrivateDirectory(path.dirname(filePath), 'output parent');
  const bytes = Buffer.from(`${JSON.stringify(canonicalValue(value), null, 2)}\n`, 'utf8');
  const descriptor = fs.openSync(filePath, 'wx', 0o600);
  try {
    fs.writeFileSync(descriptor, bytes);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  fs.chmodSync(filePath, 0o600);
  return { path: filePath, bytes, sha256: sha256(bytes) };
}

// Darwin renameatx_np(RENAME_EXCL) publishes complete bytes and cannot replace an existing marker.
export function publishPrivateAtomicNoReplace(filePath, value) {
  absolutePath(filePath, 'marker output');
  const parent = path.dirname(filePath);
  requirePrivateDirectory(parent, 'marker output parent');
  requireCondition(!fs.existsSync(filePath), 'marker output already exists');
  const temporary = path.join(parent, `.${path.basename(filePath)}.${process.pid}.${Date.now()}.tmp`);
  const bytes = Buffer.from(`${JSON.stringify(canonicalValue(value), null, 2)}\n`, 'utf8');
  const descriptor = fs.openSync(temporary, 'wx', 0o600);
  let stagedInfo;
  try {
    fs.writeFileSync(descriptor, bytes);
    fs.fsyncSync(descriptor);
    stagedInfo = fs.fstatSync(descriptor, { bigint: true });
  } finally {
    fs.closeSync(descriptor);
  }
  let publisher = null;
  try {
    const helperSource = path.join(path.dirname(fileURLToPath(import.meta.url)), 'atomic-publish-no-replace.swift');
    const retainedSource = readStableFile(helperSource, 'atomic publication helper', {
      privateFile: false,
    });
    const publisherDirectory = fs.mkdtempSync('/private/tmp/pbq-atomic-publisher-');
    fs.chmodSync(publisherDirectory, 0o700);
    const publisherPath = path.join(publisherDirectory, 'atomic-publish-no-replace');
    publisher = { directory: publisherDirectory, path: publisherPath, sha256: null };
    const closedEnvironment = {
      PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
      LANG: 'C',
      LC_ALL: 'C',
    };
    const build = spawnSync('/usr/bin/xcrun', ['swiftc', '-', '-o', publisherPath], {
      input: retainedSource.bytes,
      encoding: 'utf8',
      timeout: 30_000,
      maxBuffer: 4 * 1024 * 1024,
      env: closedEnvironment,
    });
    requireCondition(!build.error && build.status === 0,
      `atomic publication helper build failed: ${build.stderr?.trim() || build.error?.message || build.status}`);
    fs.chmodSync(publisherPath, 0o500);
    publisher.sha256 = requireStableExecutable(
      publisherPath,
      'compiled atomic publication helper',
    ).sha256;
    const publish = spawnSync(publisher.path, [temporary, filePath], {
      encoding: 'utf8',
      timeout: 15_000,
      maxBuffer: 1024 * 1024,
      env: closedEnvironment,
    });
    requireCondition(!publish.error && publish.status === 0,
      `atomic marker publication failed: ${publish.stderr?.trim() || publish.error?.message || publish.status}`);
    requireCondition(!fs.existsSync(temporary) && fs.existsSync(filePath), 'atomic publication did not consume the temporary file');
    requireCondition(requireStableExecutable(
      publisher.path,
      'post-publication atomic helper',
    ).sha256 === publisher.sha256, 'compiled atomic publication helper changed during use');
    const published = readStableFile(filePath, 'published marker');
    requireCondition(published.info.dev === stagedInfo.dev && published.info.ino === stagedInfo.ino,
      'atomic publication changed the staged file identity');
    requireCondition(published.bytes.equals(bytes), 'atomic publication changed the marker bytes');
    return { path: filePath, bytes: published.bytes, sha256: published.sha256 };
  } catch (error) {
    try { fs.unlinkSync(temporary); } catch {}
    throw new QualificationError(`marker publication failed without overwrite: ${error.message}`);
  } finally {
    if (publisher !== null) {
      try { fs.unlinkSync(publisher.path); } catch {}
      try { fs.rmdirSync(publisher.directory); } catch {}
    }
  }
}

export function parseOptions(argv, names) {
  requireCondition(argv.length === names.length * 2, `usage requires ${names.map((name) => `--${name} VALUE`).join(' ')}`);
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const option = argv[index];
    const name = option.startsWith('--') ? option.slice(2) : '';
    requireCondition(names.includes(name) && result[name] === undefined, `unexpected option ${option}`);
    result[name] = path.resolve(argv[index + 1]);
  }
  requireCondition(names.every((name) => result[name]), 'required option is missing');
  return result;
}

export function parseCodesignReceipt(filePath, label) {
  const retained = readStableFile(filePath, label);
  const text = retained.bytes.toString('utf8');
  const single = (expression, field) => {
    const matches = [...text.matchAll(expression)].map((match) => match[1]);
    requireCondition(matches.length === 1, `${label} must contain exactly one ${field}`);
    return matches[0];
  };
  const executable = single(/^Executable=(.+)$/gm, 'Executable');
  const teamID = single(/^TeamIdentifier=([A-Z0-9]+)$/gm, 'TeamIdentifier');
  const codeSignatureHash = single(/^CDHash=([0-9a-f]+)$/gm, 'CDHash');
  const authorities = [...text.matchAll(/^Authority=(.+)$/gm)].map((match) => match[1]);
  requireCondition(path.isAbsolute(executable), `${label} Executable must be absolute`);
  requireCondition(TEAM_ID.test(teamID), `${label} TeamIdentifier is invalid`);
  requireCondition(HEX40.test(codeSignatureHash), `${label} CDHash is invalid`);
  requireCondition(authorities.includes('Apple Root CA'), `${label} lacks an Apple Root CA authority chain`);
  return {
    ...retained,
    executable,
    team_id: teamID,
    code_signature_hash: codeSignatureHash,
    authorities,
  };
}

export function validateBounds(value, label) {
  exactKeys(value, ['x', 'y', 'width', 'height'], label);
  for (const key of ['x', 'y', 'width', 'height']) {
    requireCondition(typeof value[key] === 'number' && Number.isFinite(value[key]) && !Object.is(value[key], -0), `${label}.${key} is invalid`);
  }
  requireCondition(value.width > 0 && value.height > 0, `${label} has empty dimensions`);
  return value;
}

export function validateTarget(value, label) {
  exactKeys(value, ['scope', 'pid', 'start_identity', 'window_id', 'bounds', 'is_minimized'], label);
  requireCondition(value.scope === 'window' && positiveInteger(value.pid) && positiveDecimal(value.start_identity), `${label} process identity is invalid`);
  requireCondition(positiveInteger(value.window_id) && value.window_id <= 0xffff_ffff, `${label} window identity is invalid`);
  validateBounds(value.bounds, `${label}.bounds`);
  requireCondition(value.is_minimized === false, `${label} must be one visible unminimized window`);
  return value;
}

export function controlledFixtureBindings(plan, label) {
  requireCondition(Array.isArray(plan?.controllers) && plan.controllers.length === 2,
    `${label} needs exactly two controlled fixture targets`);
  const authorities = plan.controllers.map((controller, index) => {
    const suffix = index === 0 ? 'a' : 'b';
    const targetID = `target-${suffix}`;
    exactKeys(controller, ['controller_id', 'target_id', 'target'],
      `${label}.controllers[${index}]`);
    requireCondition(controller.controller_id === `controller-${suffix}`
      && controller.target_id === targetID,
    `${label}.controllers[${index}] is not the canonical ${targetID} owner`);
    const target = {
      pid: controller.target?.process_identifier,
      start_identity: controller.target?.process_start_identity_decimal,
      window_id: controller.target?.window_id,
    };
    requireCondition(positiveInteger(target.pid) && positiveDecimal(target.start_identity)
      && positiveInteger(target.window_id) && target.window_id <= 0xffff_ffff,
    `${label}.controllers[${index}] controlled fixture identity is invalid`);
    return {
      label: targetID,
      controller_id: controller.controller_id,
      target,
      receipt_target: validateTarget({
        scope: 'window',
        ...target,
        bounds: structuredClone(controller.target?.bounds),
        is_minimized: controller.target?.is_minimized,
      }, `${label}.controllers[${index}].receipt_target`),
    };
  });
  requireCondition(new Set(authorities.map((binding) => (
    `${binding.target.pid}:${binding.target.start_identity}:${binding.target.window_id}`
  ))).size === authorities.length,
  `${label} controlled fixture targets are not distinct`);
  return {
    authorities,
    targets: authorities.map(({ receipt_target: _receiptTarget, ...binding }) => binding),
  };
}

export function multiTargetAggregateSHA256(name, value) {
  return sha256(Buffer.concat([
    Buffer.from(`peekaboo.multi-target-certification.${name}.v2\0`, 'utf8'),
    canonicalBytes(value),
  ]));
}

export function validateControlledFixtureSummary(retained, binding, label) {
  const summary = retained.value;
  requireCondition(summary.version === 2
    && summary.certification_kind === 'live-physical'
    && summary.claim_scope === 'multi-target-background-with-attributed-foreground-overlap'
    && summary.structural_validation_passed === true
    && summary.target_count === 2
    && Array.isArray(summary.failures) && summary.failures.length === 0
    && Array.isArray(summary.controlled_targets) && summary.controlled_targets.length === 2,
  `${label} does not authenticate both controlled fixture targets`);
  const seenIDs = new Set();
  const rows = new Map(summary.controlled_targets.map((row, index) => {
    exactKeys(row, ['id', 'controller_id', 'controller_sha256', 'target_sha256'],
      `${label}.controlled_targets[${index}]`);
    requireCondition(typeof row.id === 'string' && !seenIDs.has(row.id),
      `${label}.controlled_targets[${index}] is duplicated`);
    seenIDs.add(row.id);
    return [row.id, row];
  }));
  requireCondition(rows.size === binding.authorities.length,
    `${label} controlled target set is not canonical`);
  for (const authority of binding.authorities) {
    const row = rows.get(authority.label);
    requireCondition(row?.controller_id === authority.controller_id
      && HEX64.test(row.controller_sha256 ?? '')
      && row.target_sha256 === multiTargetAggregateSHA256(
        'controlled-target',
        authority.receipt_target,
      ),
    `${label} ${authority.label} target differs from the live-v4 plan`);
  }
}

export function validateEmitter(value, label) {
  exactKeys(value, ['pid', 'start_identity', 'team_id', 'code_signature_hash'], label);
  requireCondition(positiveInteger(value.pid) && positiveDecimal(value.start_identity), `${label} process identity is invalid`);
  requireCondition(TEAM_ID.test(value.team_id) && HEX40.test(value.code_signature_hash), `${label} code identity is invalid`);
  return value;
}

export function readCalibrationEmitter(filePath, expectedTarget = null) {
  const label = 'integrated-CU emitter calibration receipt';
  const retained = readStableJSON(filePath, label);
  const value = retained.value;
  exactKeys(value, [
    'version', 'event_count', 'settle_milliseconds', 'target', 'captured_event', 'before', 'after',
  ], label);
  requireCondition(value.version === 1 && value.event_count === 1, `${label} is not one event`);
  requireCondition(Number.isSafeInteger(value.settle_milliseconds)
    && value.settle_milliseconds >= 100 && value.settle_milliseconds <= 3000,
  `${label} settle interval is invalid`);
  exactKeys(value.target, ['pid', 'start_identity', 'window_id', 'bounds'], `${label}.target`);
  requireCondition(positiveInteger(value.target.pid) && positiveDecimal(value.target.start_identity)
    && positiveInteger(value.target.window_id), `${label} target identity is invalid`);
  validateBounds(value.target.bounds, `${label}.target.bounds`);
  if (expectedTarget !== null) {
    requireCondition(sameJSON(value.target, {
      pid: expectedTarget.pid,
      start_identity: expectedTarget.start_identity,
      window_id: expectedTarget.window_id,
      bounds: expectedTarget.bounds,
    }), `${label} controlled target differs from the planned foreground target`);
  }
  exactKeys(value.captured_event, [
    'type', 'source_pid', 'source_start_identity_at_callback', 'timestamp_nanoseconds',
  ], `${label}.captured_event`);
  requireCondition([
    'left_mouse_down', 'right_mouse_down', 'other_mouse_down', 'key_down',
    'flags_changed', 'scroll_wheel',
  ].includes(value.captured_event.type), `${label} event type is not eligible`);
  requireCondition(positiveInteger(value.captured_event.source_pid)
    && positiveDecimal(value.captured_event.source_start_identity_at_callback)
    && positiveDecimal(value.captured_event.timestamp_nanoseconds),
  `${label} event source is invalid`);
  const identityKeys = [
    'pid', 'start_identity', 'executable_path', 'executable_sha256', 'team_id',
    'code_signature_hash', 'signing_identifier', 'apple_anchored',
  ];
  for (const phase of ['before', 'after']) {
    const identity = value[phase];
    exactKeys(identity, identityKeys, `${label}.${phase}`);
    requireCondition(positiveInteger(identity.pid) && positiveDecimal(identity.start_identity), `${label}.${phase} process identity is invalid`);
    requireCondition(path.isAbsolute(identity.executable_path) && HEX64.test(identity.executable_sha256 ?? ''), `${label}.${phase} executable identity is invalid`);
    requireCondition(TEAM_ID.test(identity.team_id) && HEX40.test(identity.code_signature_hash), `${label}.${phase} code identity is invalid`);
    requireCondition(typeof identity.signing_identifier === 'string' && identity.signing_identifier.length > 0
      && identity.apple_anchored === true, `${label}.${phase} is not Apple-anchored`);
  }
  requireCondition(sameJSON(value.before, value.after), `${label} emitter identity changed across the event`);
  requireCondition(value.before.pid === value.captured_event.source_pid
    && value.before.start_identity === value.captured_event.source_start_identity_at_callback,
  `${label} code identity differs from the event source generation`);
  requireCondition(value.before.pid !== value.target.pid, `${label} emitter is the controlled target process`);
  const executable = requireStableExecutable(value.before.executable_path, 'calibrated integrated-CU executable');
  requireCondition(executable.sha256 === value.before.executable_sha256, `${label} executable bytes changed after calibration`);
  return {
    retained,
    value,
    emitter: {
      pid: value.before.pid,
      start_identity: value.before.start_identity,
      team_id: value.before.team_id,
      code_signature_hash: value.before.code_signature_hash,
    },
  };
}

export function fileReceipt(filePath, label) {
  const retained = readStableFile(filePath, label);
  return { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 };
}

export function aggregateSHA256(domain, value) {
  return sha256(Buffer.concat([
    Buffer.from(`peekaboo.final-qualification.${domain}.v2\0`, 'utf8'),
    canonicalBytes(value),
  ]));
}
