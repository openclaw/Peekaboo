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

export function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
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
    && positiveInteger(value.captured_event.timestamp_nanoseconds),
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
