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
} = {}) {
  absolutePath(filePath, label);
  const lstat = fs.lstatSync(filePath, { bigint: true });
  const modeMask = privateFile ? 0o077n : 0o022n;
  requireCondition(
    lstat.isFile() && !lstat.isSymbolicLink() && lstat.nlink === 1n
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
  try {
    fs.writeFileSync(descriptor, bytes);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  try {
    const helperSource = path.join(path.dirname(fileURLToPath(import.meta.url)), 'atomic-publish-no-replace.swift');
    readStableFile(helperSource, 'atomic publication helper', { privateFile: false });
    const publish = spawnSync('/usr/bin/xcrun', ['swift', helperSource, temporary, filePath], {
      encoding: 'utf8',
      timeout: 15_000,
      maxBuffer: 1024 * 1024,
    });
    requireCondition(!publish.error && publish.status === 0,
      `atomic marker publication failed: ${publish.stderr?.trim() || publish.error?.message || publish.status}`);
    requireCondition(!fs.existsSync(temporary) && fs.existsSync(filePath), 'atomic publication did not consume the temporary file');
  } catch (error) {
    try { fs.unlinkSync(temporary); } catch {}
    throw new QualificationError(`marker publication failed without overwrite: ${error.message}`);
  }
  fs.chmodSync(filePath, 0o600);
  return { path: filePath, bytes, sha256: sha256(bytes) };
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
