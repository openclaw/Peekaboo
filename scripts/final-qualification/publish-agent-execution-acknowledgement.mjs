#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  HEX40,
  HEX64,
  canonicalBytes,
  exactKeys,
  parseOptions,
  positiveDecimal,
  positiveInteger,
  publishPrivateAtomicNoReplace,
  readStableFile,
  readStableJSON,
  requireCondition,
  requirePrivateDirectory,
  requireStableExecutable,
  sameJSON,
  sha256,
  writePrivateExclusive,
} from './lib.mjs';

const TOOL_ROOT = path.dirname(fileURLToPath(import.meta.url));
const COORDINATION_BASENAME = 'agent-execution-coordination.json';
const ACKNOWLEDGEMENT_BASENAME = 'agent-execution-ack.json';
const OPERATION_RECEIPT_DIRECTORY_BASENAME = 'agent-operation-receipts';
const HOST_UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;
const ROOT_CLASSES = new Set([
  'agent', 'agent_requester', 'bridge', 'coordinator', 'elevation', 'fixture', 'integrated_cu',
]);
const ALLOWED_ENVIRONMENT_KEYS = new Set([
  'PATH', 'HOME', 'LANG', 'LC_ALL', 'LC_CTYPE', 'LOGNAME', 'SSL_CERT_DIR', 'SSL_CERT_FILE',
  'TMPDIR', 'TZ', 'USER', 'ANTHROPIC_API_KEY', 'GEMINI_API_KEY', 'GOOGLE_API_KEY',
  'GROK_API_KEY', 'MINIMAX_API_KEY', 'MOONSHOT_API_KEY', 'OPENAI_API_KEY',
  'OPENROUTER_API_KEY', 'X_AI_API_KEY', 'XAI_API_KEY', 'PEEKABOO_OPERATION_RECEIPT_DIRECTORY',
  'PEEKABOO_AGENT_EXECUTION_GATE_FD', 'PEEKABOO_AGENT_EXECUTION_GATE_CHALLENGE',
  'PEEKABOO_AGENT_EXECUTION_LOCKDOWN_FD', 'PEEKABOO_AGENT_EXECUTION_PROCESS_LIMIT',
]);
const REQUIRED_ENVIRONMENT_KEYS = [
  'PATH', 'PEEKABOO_OPERATION_RECEIPT_DIRECTORY', 'PEEKABOO_AGENT_EXECUTION_GATE_FD',
  'PEEKABOO_AGENT_EXECUTION_GATE_CHALLENGE', 'PEEKABOO_AGENT_EXECUTION_LOCKDOWN_FD',
  'PEEKABOO_AGENT_EXECUTION_PROCESS_LIMIT',
];

function validatedIdentity(value, label) {
  exactKeys(value, [
    'processIdentifier', 'processStartIdentity', 'codeSignatureHash',
  ], label);
  requireCondition(positiveInteger(value.processIdentifier)
    && positiveDecimal(value.processStartIdentity)
    && HEX40.test(value.codeSignatureHash), `${label} is malformed`);
  return value;
}

function verifiedCodeSignatureHash(executablePath, label) {
  const verify = spawnSync('/usr/bin/codesign', ['--verify', '--strict', executablePath], {
    encoding: 'utf8',
    timeout: 10_000,
    maxBuffer: 1024 * 1024,
    env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LANG: 'C', LC_ALL: 'C' },
  });
  requireCondition(!verify.error && verify.status === 0,
    `${label} code signature verification failed`);
  const display = spawnSync('/usr/bin/codesign', ['-dvvv', executablePath], {
    encoding: 'utf8',
    timeout: 10_000,
    maxBuffer: 1024 * 1024,
    env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LANG: 'C', LC_ALL: 'C' },
  });
  const matches = [...`${display.stdout ?? ''}\n${display.stderr ?? ''}`
    .matchAll(/^CDHash=([0-9a-f]{40})$/gm)].map((match) => match[1]);
  requireCondition(!display.error && display.status === 0 && matches.length === 1,
    `${label} has no exact CDHash`);
  return matches[0];
}

function corroboratePublication(retained, publishedAt, label) {
  const modifiedAt = Number(retained.info.mtimeNs / 1_000_000n);
  requireCondition(Number.isSafeInteger(publishedAt) && publishedAt > 0
    && Number.isSafeInteger(modifiedAt) && modifiedAt >= publishedAt
    && modifiedAt - publishedAt <= 2000,
  `${label} timestamp is not corroborated by its file`);
}

function pathIsAbsent(filePath) {
  try {
    fs.lstatSync(filePath);
    return false;
  } catch (error) {
    requireCondition(error?.code === 'ENOENT', `cannot inspect release-gating path ${filePath}`);
    return true;
  }
}

function validateLiveLifecycleGuard(readiness, monitorPath) {
  const temporary = fs.mkdtempSync('/private/tmp/pbq-agent-ack-guard.');
  fs.chmodSync(temporary, 0o700);
  try {
    const inspect = (command) => {
      const output = path.join(temporary, `${command}.json`);
      const run = spawnSync(monitorPath, [
        command, '--pid', String(readiness.lifecycle_guard_pid), '--output', output,
      ], {
        encoding: 'utf8',
        timeout: 15_000,
        maxBuffer: 1024 * 1024,
        env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LANG: 'C', LC_ALL: 'C' },
      });
      requireCondition(!run.error && run.status === 0,
        `signed monitor ${command} failed for the lifecycle guard`);
      return readStableJSON(output, `live lifecycle guard ${command}`).value;
    };
    const identity = inspect('process-identity');
    const executable = inspect('process-executable');
    exactKeys(identity, ['pid', 'startIdentity'], 'live lifecycle guard identity');
    exactKeys(executable, ['pid', 'startIdentity', 'path', 'sha256'],
      'live lifecycle guard executable');
    requireCondition(identity.pid === readiness.lifecycle_guard_pid
      && identity.startIdentity === readiness.lifecycle_guard_start_identity
      && executable.pid === identity.pid && executable.startIdentity === identity.startIdentity
      && executable.path === readiness.lifecycle_guard_executable_path
      && executable.sha256 === readiness.lifecycle_guard_binary_sha256,
    'live lifecycle guard differs from collector readiness');
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}

function validateAcknowledgementControl(value, acknowledgementPath) {
  exactKeys(value, [
    'acknowledgement_path', 'authorization_source_path', 'authorization_request_path',
    'authorization_result_path',
  ], 'collector acknowledgement control');
  const parent = path.dirname(acknowledgementPath);
  const basename = path.basename(acknowledgementPath);
  const expected = {
    acknowledgement_path: acknowledgementPath,
    authorization_source_path: path.join(parent, `.${basename}.lifecycle-source`),
    authorization_request_path: path.join(parent, `.${basename}.lifecycle-request`),
    authorization_result_path: path.join(parent, `.${basename}.lifecycle-result`),
  };
  requireCondition(sameJSON(value, expected),
    'collector acknowledgement control paths are not canonical');
  return value;
}

export function validateCoordinationReceipt(retained, acknowledgementPath) {
  const value = retained.value;
  exactKeys(value, [
    'version', 'challenge', 'requestingPeer', 'process', 'bridgeSocketPath', 'runRootPath',
    'coordinationReceiptPath', 'acknowledgementPath', 'operationReceiptDirectoryPath',
    'taskSHA256', 'maxSteps', 'startTimeoutMilliseconds', 'runTimeoutMilliseconds',
    'arguments', 'argumentsSHA256', 'backgroundOnly', 'allowForeground', 'shellAvailable',
    'processCreationLimit', 'environmentPolicyVersion', 'environmentKeys', 'environmentSHA256',
    'spawnedAt', 'lockdownAcknowledgedAt', 'publishedAt',
  ], 'Agent execution coordination receipt');
  const requestingPeer = validatedIdentity(value.requestingPeer, 'coordination requesting peer');
  exactKeys(value.process, [
    'processIdentity', 'executablePath', 'executableSHA256',
  ], 'coordination Agent process');
  const child = validatedIdentity(
    value.process.processIdentity,
    'coordination Agent process identity',
  );
  requireCondition(value.version === 1 && HEX64.test(value.challenge)
    && requestingPeer.processIdentifier !== child.processIdentifier
    && requestingPeer.codeSignatureHash === child.codeSignatureHash
    && typeof value.bridgeSocketPath === 'string' && path.isAbsolute(value.bridgeSocketPath)
    && !value.bridgeSocketPath.includes('\0')
    && typeof value.runRootPath === 'string' && path.isAbsolute(value.runRootPath)
    && value.coordinationReceiptPath === retained.path
    && value.coordinationReceiptPath === path.join(value.runRootPath, COORDINATION_BASENAME)
    && value.acknowledgementPath === acknowledgementPath
    && value.acknowledgementPath === path.join(value.runRootPath, ACKNOWLEDGEMENT_BASENAME)
    && value.operationReceiptDirectoryPath
      === path.join(value.runRootPath, OPERATION_RECEIPT_DIRECTORY_BASENAME)
    && HEX64.test(value.taskSHA256) && HEX64.test(value.argumentsSHA256)
    && HEX64.test(value.environmentSHA256)
    && Number.isSafeInteger(value.maxSteps) && value.maxSteps >= 1 && value.maxSteps <= 100
    && Number.isSafeInteger(value.startTimeoutMilliseconds)
    && value.startTimeoutMilliseconds >= 1 && value.startTimeoutMilliseconds <= 120_000
    && Number.isSafeInteger(value.runTimeoutMilliseconds)
    && value.runTimeoutMilliseconds >= 1 && value.runTimeoutMilliseconds <= 7_200_000
    && value.backgroundOnly === true && value.allowForeground === false
    && value.shellAvailable === false && value.processCreationLimit === 0
    && value.environmentPolicyVersion === 3
    && Array.isArray(value.environmentKeys) && value.environmentKeys.length > 0
    && value.environmentKeys.every((key) => typeof key === 'string'
      && ALLOWED_ENVIRONMENT_KEYS.has(key))
    && value.environmentKeys.every((key, index) => index === 0
      || value.environmentKeys[index - 1] < key)
    && new Set(value.environmentKeys).size === value.environmentKeys.length
    && REQUIRED_ENVIRONMENT_KEYS.every((key) => value.environmentKeys.includes(key))
    && Number.isSafeInteger(value.spawnedAt) && value.spawnedAt > 0
    && Number.isSafeInteger(value.lockdownAcknowledgedAt)
    && value.lockdownAcknowledgedAt >= value.spawnedAt
    && Number.isSafeInteger(value.publishedAt)
    && value.publishedAt >= value.lockdownAcknowledgedAt,
  'Agent execution coordination receipt is malformed');
  requirePrivateDirectory(value.runRootPath, 'Agent execution run root');
  requireCondition(pathIsAbsent(value.operationReceiptDirectoryPath),
    'Agent operation receipt directory exists before acknowledgement');
  requireCondition(Array.isArray(value.arguments) && value.arguments.length === 9
    && value.arguments.every((entry) => typeof entry === 'string' && !entry.includes('\0')),
  'coordination Agent argv is malformed');
  const expectedArguments = [
    'agent', 'run', value.arguments[2], '--no-cache', '--max-steps', String(value.maxSteps),
    '--bridge-socket', value.bridgeSocketPath, '--json',
  ];
  requireCondition(sameJSON(value.arguments, expectedArguments)
    && value.arguments[2].trim().length > 0 && value.arguments[2][0] !== '-'
    && Buffer.byteLength(value.arguments[2], 'utf8') > 0
    && Buffer.byteLength(value.arguments[2], 'utf8') <= 256 * 1024
    && sha256(Buffer.from(value.arguments[2], 'utf8')) === value.taskSHA256
    && sha256(canonicalBytes(value.arguments)) === value.argumentsSHA256,
  'coordination Agent argv differs from its commitments');
  const executable = requireStableExecutable(
    value.process.executablePath,
    'coordination Agent executable',
    { allowRootOwner: true },
  );
  requireCondition(executable.sha256 === value.process.executableSHA256
    && verifiedCodeSignatureHash(executable.path, 'coordination Agent executable')
      === child.codeSignatureHash,
  'coordination Agent executable differs from its process identity');
  corroboratePublication(retained, value.publishedAt, 'coordination receipt publication');
  return { value, requestingPeer, child, executable };
}

function validatedRoot(value, label) {
  exactKeys(value, [
    'root_id', 'root_class', 'pid', 'start_identity', 'code_signature_hash',
  ], label);
  requireCondition(typeof value.root_id === 'string' && /^[a-z][a-z0-9_-]{0,63}$/.test(value.root_id)
    && typeof value.root_class === 'string' && ROOT_CLASSES.has(value.root_class)
    && positiveInteger(value.pid) && positiveDecimal(value.start_identity)
    && HEX40.test(value.code_signature_hash), `${label} is malformed`);
  return value;
}

function validatedProcess(value, label) {
  exactKeys(value, [
    'pid', 'start_identity', 'parent_pid', 'parent_start_identity', 'executable_path',
    'executable_name', 'executable_sha256', 'code_signature_hash', 'signing_identifier', 'team_id',
  ], label);
  const parentIsNull = value.parent_pid === null && value.parent_start_identity === null;
  const parentIsValid = positiveInteger(value.parent_pid) && positiveDecimal(value.parent_start_identity);
  requireCondition(positiveInteger(value.pid) && positiveDecimal(value.start_identity)
    && (parentIsNull || parentIsValid)
    && typeof value.executable_path === 'string' && path.isAbsolute(value.executable_path)
    && !value.executable_path.includes('\0')
    && path.basename(value.executable_path) === value.executable_name
    && HEX64.test(value.executable_sha256) && HEX40.test(value.code_signature_hash)
    && (value.signing_identifier === null || (
      typeof value.signing_identifier === 'string' && value.signing_identifier.length > 0
    ))
    && (value.team_id === null || /^[A-Z0-9]{10}$/.test(value.team_id)),
  `${label} is malformed`);
  return value;
}

export function validateCollectorReadiness(retained, coordination) {
  const value = retained.value;
  requirePrivateDirectory(path.dirname(retained.path), 'process collector readiness parent');
  exactKeys(value, [
    'version', 'role', 'host_uuid', 'deployment_envelope_sha256', 'epoch',
    'collector_sha256', 'monitor_executable_path', 'monitor_executable_sha256',
    'monitor_code_signature_hash', 'lifecycle_guard_sha256', 'lifecycle_guard_binary_sha256',
    'lifecycle_guard_executable_path', 'lifecycle_guard_pid', 'lifecycle_guard_start_identity',
    'lifecycle_result_path', 'lifecycle_started_at_milliseconds',
    'coverage_started_at_milliseconds', 'published_at_milliseconds', 'lifecycle_watched_pids',
    'roots', 'observed_processes', 'acknowledgement_control', 'complete',
  ], 'process collector readiness');
  requireCondition(value.version === 1 && value.role === 'local' && value.epoch === 'during'
    && HOST_UUID.test(value.host_uuid) && HEX64.test(value.deployment_envelope_sha256)
    && HEX64.test(value.collector_sha256) && HEX64.test(value.monitor_executable_sha256)
    && HEX40.test(value.monitor_code_signature_hash) && HEX64.test(value.lifecycle_guard_sha256)
    && HEX64.test(value.lifecycle_guard_binary_sha256)
    && typeof value.lifecycle_guard_executable_path === 'string'
    && path.isAbsolute(value.lifecycle_guard_executable_path)
    && positiveInteger(value.lifecycle_guard_pid)
    && positiveDecimal(value.lifecycle_guard_start_identity)
    && typeof value.lifecycle_result_path === 'string' && path.isAbsolute(value.lifecycle_result_path)
    && path.dirname(value.lifecycle_result_path) === path.dirname(value.lifecycle_guard_executable_path)
    && Number.isSafeInteger(value.lifecycle_started_at_milliseconds)
    && value.lifecycle_started_at_milliseconds >= coordination.value.publishedAt
    && Number.isSafeInteger(value.coverage_started_at_milliseconds)
    && value.coverage_started_at_milliseconds >= value.lifecycle_started_at_milliseconds
    && Number.isSafeInteger(value.published_at_milliseconds)
    && value.published_at_milliseconds >= value.coverage_started_at_milliseconds
    && value.complete === true
    && Array.isArray(value.lifecycle_watched_pids) && value.lifecycle_watched_pids.length > 0
    && value.lifecycle_watched_pids.every(positiveInteger)
    && value.lifecycle_watched_pids.every((pid, index) => index === 0
      || value.lifecycle_watched_pids[index - 1] < pid)
    && new Set(value.lifecycle_watched_pids).size === value.lifecycle_watched_pids.length
    && Array.isArray(value.roots) && value.roots.length > 0
    && Array.isArray(value.observed_processes) && value.observed_processes.length > 0,
  'process collector readiness is malformed');
  corroboratePublication(retained, value.published_at_milliseconds, 'collector readiness publication');
  const collector = readStableFile(
    path.join(TOOL_ROOT, 'process-tree-collector.mjs'),
    'readiness process collector source',
    { privateFile: false },
  );
  const lifecycleGuard = readStableFile(
    path.join(TOOL_ROOT, 'process-lifecycle-guard.c'),
    'readiness lifecycle guard source',
    { privateFile: false },
  );
  requireCondition(value.collector_sha256 === collector.sha256
    && value.lifecycle_guard_sha256 === lifecycleGuard.sha256,
  'collector readiness differs from the source-owned tools');
  const monitor = requireStableExecutable(
    value.monitor_executable_path,
    'readiness signed process monitor',
    { allowRootOwner: true },
  );
  requireCondition(monitor.sha256 === value.monitor_executable_sha256
    && verifiedCodeSignatureHash(monitor.path, 'readiness signed process monitor')
      === value.monitor_code_signature_hash,
  'collector readiness monitor identity changed');
  const lifecycleExecutable = requireStableExecutable(
    value.lifecycle_guard_executable_path,
    'readiness lifecycle guard executable',
  );
  requireCondition(lifecycleExecutable.sha256 === value.lifecycle_guard_binary_sha256,
    'collector readiness lifecycle guard executable changed');
  validateLiveLifecycleGuard(value, monitor.path);
  const acknowledgementControl = validateAcknowledgementControl(
    value.acknowledgement_control,
    coordination.value.acknowledgementPath,
  );

  const roots = value.roots.map((root, index) => validatedRoot(
    root,
    `process collector readiness roots[${index}]`,
  ));
  requireCondition(roots.every((root, index) => index === 0
    || roots[index - 1].root_id < root.root_id)
    && new Set(roots.map((root) => root.root_id)).size === roots.length
    && new Set(roots.map((root) => `${root.pid}:${root.start_identity}`)).size === roots.length,
  'process collector readiness roots are not canonical');
  const requesterRoots = roots.filter((root) => root.root_class === 'agent_requester');
  const childRoots = roots.filter((root) => root.root_class === 'agent');
  requireCondition(requesterRoots.length === 1 && childRoots.length === 1
    && requesterRoots[0].root_id === 'agent-requester' && childRoots[0].root_id === 'agent',
  'collector readiness lacks the canonical requester and Agent roots');
  const requesterRoot = requesterRoots[0];
  const childRoot = childRoots[0];
  requireCondition(requesterRoot.pid === coordination.requestingPeer.processIdentifier
    && requesterRoot.start_identity === coordination.requestingPeer.processStartIdentity
    && requesterRoot.code_signature_hash === coordination.requestingPeer.codeSignatureHash
    && childRoot.pid === coordination.child.processIdentifier
    && childRoot.start_identity === coordination.child.processStartIdentity
    && childRoot.code_signature_hash === coordination.child.codeSignatureHash,
  'collector readiness requester or Agent root differs from coordination');

  const processes = value.observed_processes.map((process, index) => validatedProcess(
    process,
    `process collector readiness observed_processes[${index}]`,
  ));
  requireCondition(processes.every((process, index) => index === 0
    || processes[index - 1].pid < process.pid)
    && sameJSON(value.lifecycle_watched_pids, processes.map((process) => process.pid)),
  'collector readiness process inventory differs from lifecycle coverage');
  const byIdentity = new Map(processes.map((process) => [
    `${process.pid}:${process.start_identity}`,
    process,
  ]));
  requireCondition(byIdentity.size === processes.length, 'collector readiness repeats a process identity');
  const rootIdentities = new Set(roots.map((root) => `${root.pid}:${root.start_identity}`));
  for (const root of roots) {
    const process = byIdentity.get(`${root.pid}:${root.start_identity}`);
    requireCondition(process && process.parent_pid === null && process.parent_start_identity === null
      && process.code_signature_hash === root.code_signature_hash,
    `collector readiness root ${root.root_id} lacks its authenticated process`);
  }
  for (const process of processes) {
    const identity = `${process.pid}:${process.start_identity}`;
    if (rootIdentities.has(identity)) continue;
    const parent = `${process.parent_pid}:${process.parent_start_identity}`;
    requireCondition(byIdentity.has(parent),
      'collector readiness contains a process outside its declared roots');
  }
  const reachable = new Set(rootIdentities);
  let changed = true;
  while (changed) {
    changed = false;
    for (const process of processes) {
      const identity = `${process.pid}:${process.start_identity}`;
      const parent = `${process.parent_pid}:${process.parent_start_identity}`;
      if (!reachable.has(identity) && reachable.has(parent)) {
        reachable.add(identity);
        changed = true;
      }
    }
  }
  requireCondition(reachable.size === processes.length,
    'collector readiness contains a cycle or unreachable process');
  const restrictedParents = new Set([
    `${requesterRoot.pid}:${requesterRoot.start_identity}`,
    `${childRoot.pid}:${childRoot.start_identity}`,
  ]);
  requireCondition(processes.every((process) => !restrictedParents.has(
    `${process.parent_pid}:${process.parent_start_identity}`,
  )), 'collector readiness observed a requester or Agent descendant');
  const requesterProcess = byIdentity.get(`${requesterRoot.pid}:${requesterRoot.start_identity}`);
  const childProcess = byIdentity.get(`${childRoot.pid}:${childRoot.start_identity}`);
  requireCondition(childProcess.executable_path === coordination.value.process.executablePath
    && childProcess.executable_sha256 === coordination.value.process.executableSHA256
    && requesterProcess.executable_path === childProcess.executable_path
    && requesterProcess.executable_sha256 === childProcess.executable_sha256,
  'collector readiness executable identity differs from the coordinated CLI');
  return {
    value,
    requesterRoot,
    childRoot,
    requesterProcess,
    childProcess,
    acknowledgementControl,
  };
}

function waitForReadiness(filePath, deadline) {
  while (Date.now() < deadline) {
    if (fs.existsSync(filePath)) {
      const info = fs.lstatSync(filePath, { bigint: true });
      if (info.isFile() && !info.isSymbolicLink() && info.nlink === 1n) {
        return readStableJSON(filePath, 'process collector readiness');
      }
      requireCondition(info.isFile() && !info.isSymbolicLink() && info.nlink === 2n,
        'process collector readiness is not one stable regular file');
    }
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
  }
  throw new Error('process collector readiness timed out before acknowledgement');
}

function waitForGuardAuthorization(control, lifecycleResultPath, deadline) {
  while (Date.now() < deadline) {
    if (fs.existsSync(lifecycleResultPath)) {
      const lifecycle = readStableJSON(lifecycleResultPath, 'failed process lifecycle result').value;
      throw new Error(
        `process lifecycle coverage ended before acknowledgement: ${JSON.stringify(lifecycle)}`,
      );
    }
    if (fs.existsSync(control.acknowledgement_path)
      && fs.existsSync(control.authorization_result_path)) {
      return {
        acknowledgement: readStableFile(
          control.acknowledgement_path,
          'guard-published Agent acknowledgement',
        ),
        authorization: readStableJSON(
          control.authorization_result_path,
          'Agent acknowledgement authorization result',
        ),
      };
    }
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
  }
  throw new Error('lifecycle guard did not publish the Agent acknowledgement before its deadline');
}

export function publishAgentExecutionAcknowledgement(
  coordinationPath,
  readinessPath,
  acknowledgementPath,
) {
  const coordinationRetained = readStableJSON(
    coordinationPath,
    'Agent execution coordination receipt',
  );
  const coordination = validateCoordinationReceipt(coordinationRetained, acknowledgementPath);
  const deadline = coordination.value.spawnedAt + coordination.value.startTimeoutMilliseconds;
  requireCondition(coordination.value.publishedAt < deadline,
    'Agent coordination receipt exhausted the start window');
  const readinessRetained = waitForReadiness(readinessPath, deadline);
  const readiness = validateCollectorReadiness(readinessRetained, coordination);
  requireCondition(readiness.value.published_at_milliseconds < deadline,
    'process collector readiness missed the Agent start deadline');
  while (Date.now() <= readiness.value.published_at_milliseconds && Date.now() < deadline) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1);
  }
  const acknowledgedAt = Date.now();
  requireCondition(acknowledgedAt > readiness.value.published_at_milliseconds
    && acknowledgedAt < deadline,
  'Agent acknowledgement missed the collector-ready start window');
  requireCondition(readStableFile(coordinationRetained.path, 'final coordination receipt').bytes
    .equals(coordinationRetained.bytes)
    && readStableFile(readinessRetained.path, 'final collector readiness').bytes
      .equals(readinessRetained.bytes),
  'Agent coordination or collector readiness changed before acknowledgement');
  const acknowledgement = {
    version: 1,
    challenge: coordination.value.challenge,
    coordinationReceiptSHA256: coordinationRetained.sha256,
    requestingPeer: structuredClone(coordination.value.requestingPeer),
    process: structuredClone(coordination.value.process),
    taskSHA256: coordination.value.taskSHA256,
    argumentsSHA256: coordination.value.argumentsSHA256,
    environmentSHA256: coordination.value.environmentSHA256,
    acknowledgedAt,
  };
  const control = readiness.acknowledgementControl;
  requireCondition(Object.values(control).every(pathIsAbsent),
    'Agent acknowledgement control paths must be absent before authorization');
  const staged = writePrivateExclusive(control.authorization_source_path, acknowledgement);
  const requestedAt = Date.now();
  const request = publishPrivateAtomicNoReplace(control.authorization_request_path, {
    version: 1,
    guard_pid: readiness.value.lifecycle_guard_pid,
    acknowledgement_path: acknowledgementPath,
    acknowledgement_sha256: staged.sha256,
    readiness_sha256: readinessRetained.sha256,
    requested_at_milliseconds: requestedAt,
  });
  const authorized = waitForGuardAuthorization(
    control,
    readiness.value.lifecycle_result_path,
    deadline,
  );
  exactKeys(authorized.authorization.value, [
    'version', 'guard_pid', 'authorized_at_milliseconds',
  ], 'Agent acknowledgement authorization result');
  requireCondition(authorized.authorization.value.version === 1
    && authorized.authorization.value.guard_pid === readiness.value.lifecycle_guard_pid
    && Number.isSafeInteger(authorized.authorization.value.authorized_at_milliseconds)
    && authorized.authorization.value.authorized_at_milliseconds >= requestedAt
    && authorized.acknowledgement.bytes.equals(staged.bytes)
    && authorized.acknowledgement.sha256 === staged.sha256
    && pathIsAbsent(control.authorization_source_path),
  'lifecycle guard published an invalid Agent acknowledgement');
  return {
    version: 1,
    acknowledgement_path: authorized.acknowledgement.path,
    acknowledgement_sha256: authorized.acknowledgement.sha256,
    coordination_sha256: coordinationRetained.sha256,
    readiness_sha256: readinessRetained.sha256,
    authorization_request_path: request.path,
    authorization_request_sha256: request.sha256,
    authorization_result_path: authorized.authorization.path,
    authorization_result_sha256: authorized.authorization.sha256,
    requester_root: readiness.requesterRoot,
    agent_root: readiness.childRoot,
  };
}

function invokedAsScript() {
  return process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
}

if (invokedAsScript()) {
  try {
    const options = parseOptions(
      process.argv.slice(2),
      ['coordination', 'readiness', 'output'],
    );
    const result = publishAgentExecutionAcknowledgement(
      options.coordination,
      options.readiness,
      options.output,
    );
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } catch (error) {
    process.stderr.write(`publish-agent-execution-acknowledgement: ${error.message}\n`);
    process.exitCode = 1;
  }
}
