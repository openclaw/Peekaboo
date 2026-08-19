#!/usr/bin/env node

import { spawn, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
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
} from './lib.mjs';

const TOOL_ROOT = path.dirname(fileURLToPath(import.meta.url));
const COMMON_ENVIRONMENT_KEYS = [
  'HOME', 'LANG', 'LC_ALL', 'LC_CTYPE', 'LOGNAME', 'SSL_CERT_DIR', 'SSL_CERT_FILE',
  'TMPDIR', 'TZ', 'USER',
];

function closedEnvironment() {
  const environment = { PATH: '/usr/bin:/bin:/usr/sbin:/sbin' };
  for (const key of COMMON_ENVIRONMENT_KEYS) {
    const value = process.env[key];
    if (value === undefined) continue;
    requireCondition(!value.includes('\0'), `environment ${key} contains NUL`);
    environment[key] = value;
  }
  const keys = Object.keys(environment).sort();
  return {
    values: Object.fromEntries(keys.map((key) => [key, environment[key]])),
    keys,
    sha256: sha256(canonicalBytes(environment)),
  };
}

function requireAbsentPrivateOutput(filePath, label) {
  requireCondition(path.isAbsolute(filePath), `${label} must be absolute`);
  requirePrivateDirectory(path.dirname(filePath), `${label} parent`);
  requireCondition(!fs.existsSync(filePath), `${label} must be absent`);
}

function validateCoordinator(spec) {
  exactKeys(spec.context, ['coordinator_source_path'], 'launch context');
  const source = readStableFile(spec.context.coordinator_source_path, 'coordinator source', {
    privateFile: false,
  });
  requireCondition(fs.realpathSync(spec.executable) === fs.realpathSync(process.execPath),
    'coordinator executable is not this exact Node runtime');
  requireCondition(spec.arguments.length === 3
    && spec.arguments[0] === spec.context.coordinator_source_path
    && spec.arguments[1] === '--plan'
    && spec.arguments[2] === spec.plan_path,
  'coordinator argv is not the exact source plus one plan');
  return { source };
}

function validateSpec(specPath) {
  const retainedSpec = readStableJSON(specPath, 'managed launch input');
  const spec = retainedSpec.value;
  exactKeys(spec, [
    'version', 'kind', 'plan_path', 'executable', 'arguments', 'identity_handshake_path',
    'pid_path', 'start_ack_path', 'invocation_receipt_path', 'exit_receipt_path',
    'stdout_path', 'stderr_path', 'start_timeout_seconds', 'run_timeout_seconds', 'context',
  ], 'managed launch input');
  requireCondition(spec.version === 1 && spec.kind === 'coordinator',
    'managed launch kind/version is invalid');
  requireCondition(Array.isArray(spec.arguments) && spec.arguments.length > 0
    && spec.arguments.every((entry) => typeof entry === 'string' && !entry.includes('\0')),
  'managed launch arguments are invalid');
  requireCondition(Number.isSafeInteger(spec.start_timeout_seconds)
    && spec.start_timeout_seconds >= 5 && spec.start_timeout_seconds <= 120,
  'managed launch start timeout is invalid');
  requireCondition(Number.isSafeInteger(spec.run_timeout_seconds)
    && spec.run_timeout_seconds >= 5 && spec.run_timeout_seconds <= 7200,
  'managed launch run timeout is invalid');
  const planReceipt = readStableJSON(spec.plan_path, 'live-v4 plan');
  const plan = planReceipt.value;
  requireCondition(plan.version === 1 && path.isAbsolute(plan.monitor_executable)
    && HEX40.test(plan.monitor?.code_signature_hash ?? ''),
  'live-v4 plan lacks the exact monitor identity');
  const executable = requireStableExecutable(spec.executable, `${spec.kind} executable`, {
    allowRootOwner: true,
  });
  const monitor = requireStableExecutable(plan.monitor_executable, 'signed monitor executable', {
    allowRootOwner: true,
  });
  const details = validateCoordinator(spec);
  const outputs = [
    ['identity_handshake_path', spec.identity_handshake_path],
    ['pid_path', spec.pid_path],
    ['start_ack_path', spec.start_ack_path],
    ['invocation_receipt_path', spec.invocation_receipt_path],
    ['exit_receipt_path', spec.exit_receipt_path],
    ['stdout_path', spec.stdout_path],
    ['stderr_path', spec.stderr_path],
  ];
  requireCondition(new Set(outputs.map(([, value]) => value)).size === outputs.length,
    'managed launch output paths must be distinct');
  for (const [label, value] of outputs) requireAbsentPrivateOutput(value, label);
  return { spec, retainedSpec, plan, planReceipt, executable, monitor, details };
}

function validateMonitor(monitor, expectedCDHash) {
  const verify = spawnSync('/usr/bin/codesign', ['--verify', '--strict', monitor.path], {
    encoding: 'utf8', timeout: 10_000, maxBuffer: 1024 * 1024,
  });
  requireCondition(!verify.error && verify.status === 0,
    `monitor signature verification failed: ${verify.stderr?.trim() || verify.error?.message}`);
  const display = spawnSync('/usr/bin/codesign', ['-dvvv', monitor.path], {
    encoding: 'utf8', timeout: 10_000, maxBuffer: 1024 * 1024,
  });
  const text = `${display.stdout ?? ''}\n${display.stderr ?? ''}`;
  const matches = [...text.matchAll(/^CDHash=([0-9a-f]{40})$/gm)].map((match) => match[1]);
  requireCondition(!display.error && display.status === 0 && matches.length === 1
    && matches[0] === expectedCDHash, 'monitor live CDHash differs from the plan');
}

function compileGuardian() {
  const source = path.join(TOOL_ROOT, 'managed-launch-suspended.c');
  const retainedSource = readStableFile(source, 'suspended launch guardian source', {
    privateFile: false,
  });
  const directory = fs.mkdtempSync('/private/tmp/pbq-managed-launch-');
  fs.chmodSync(directory, 0o700);
  const binary = path.join(directory, 'managed-launch-suspended');
  const build = spawnSync('/usr/bin/xcrun', [
    'clang', '-x', 'c', '-std=c11', '-Wall', '-Wextra', '-Werror', '-', '-o', binary,
    '-lproc',
  ], {
    input: retainedSource.bytes,
    encoding: 'utf8',
    timeout: 30_000,
    maxBuffer: 4 * 1024 * 1024,
    env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LANG: 'C', LC_ALL: 'C' },
  });
  requireCondition(!build.error && build.status === 0,
    `cannot build suspended launch guardian: ${build.stderr?.trim() || build.error?.message}`);
  fs.chmodSync(binary, 0o500);
  const executable = requireStableExecutable(binary, 'compiled suspended launch guardian');
  return { directory, binary: executable.path, sha256: executable.sha256, stagedPaths: [] };
}

function cleanupGuardian(value) {
  for (const stagedPath of value.stagedPaths.reverse()) {
    try { fs.unlinkSync(stagedPath); } catch {}
  }
  try { fs.unlinkSync(value.binary); } catch {}
  try { fs.rmdirSync(value.directory); } catch {}
}

function stageRetainedFile(retained, destination, label) {
  const descriptor = fs.openSync(destination, 'wx', 0o400);
  try {
    fs.writeFileSync(descriptor, retained.bytes);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  fs.chmodSync(destination, 0o400);
  const staged = readStableFile(destination, label);
  requireCondition(staged.sha256 === retained.sha256 && staged.bytes.equals(retained.bytes),
    `${label} differs from retained bytes`);
  return staged;
}

function prepareExecution(fix, guardian) {
  const sourceStagePath = path.join(
    path.dirname(fix.details.source.path),
    `.${path.basename(fix.details.source.path)}.${process.pid}.${randomUUID()}.pbq-stage.mjs`,
  );
  const planStagePath = path.join(guardian.directory, 'coordinator-plan.json');
  const source = stageRetainedFile(
    fix.details.source,
    sourceStagePath,
    'staged coordinator source',
  );
  guardian.stagedPaths.push(source.path);
  const plan = stageRetainedFile(
    fix.planReceipt,
    planStagePath,
    'staged coordinator plan',
  );
  guardian.stagedPaths.push(plan.path);
  fix.execution = {
    arguments: [source.path, '--plan', plan.path],
    source_sha256: source.sha256,
    plan_sha256: plan.sha256,
  };
}

function startTail(filePath, stream) {
  let offset = 0;
  const drain = () => {
    if (!fs.existsSync(filePath)) return;
    const size = fs.statSync(filePath).size;
    if (size <= offset) return;
    const descriptor = fs.openSync(filePath, 'r');
    try {
      const bytes = Buffer.alloc(size - offset);
      fs.readSync(descriptor, bytes, 0, bytes.length, offset);
      offset = size;
      stream.write(bytes);
    } finally {
      fs.closeSync(descriptor);
    }
  };
  const timer = setInterval(drain, 25);
  return () => { clearInterval(timer); drain(); };
}

function monitorHandshake(fix, pid, spawnedAt) {
  const run = spawnSync(fix.plan.monitor_executable, [
    'process-identity', '--pid', String(pid), '--output', fix.spec.identity_handshake_path,
  ], { encoding: 'utf8', timeout: 15_000, maxBuffer: 1024 * 1024 });
  requireCondition(!run.error && run.status === 0,
    `signed monitor identity handshake failed: ${run.stderr?.trim() || run.error?.message}`);
  const retained = readStableJSON(fix.spec.identity_handshake_path, 'monitor identity handshake');
  exactKeys(retained.value, ['pid', 'startIdentity'], 'monitor identity handshake');
  requireCondition(retained.value.pid === pid && positiveDecimal(retained.value.startIdentity),
    'monitor identity handshake differs from the suspended child');
  requireCondition(Number(retained.info.mtimeNs / 1_000_000n) + 1000 >= spawnedAt,
    'monitor identity handshake predates the suspended child');
  return {
    retained,
    pid,
    start_identity: retained.value.startIdentity,
  };
}

function cleanupAuthenticatedChild(guardian, identity) {
  requireCondition(requireStableExecutable(
    guardian.binary,
    'generation-safe cleanup helper',
  ).sha256 === guardian.sha256, 'managed cleanup helper changed after launch');
  const run = spawnSync(guardian.binary, [
    '--terminate-exact', String(identity.pid), identity.start_identity,
  ], {
    encoding: 'utf8',
    timeout: 5000,
    maxBuffer: 1024 * 1024,
    env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LANG: 'C', LC_ALL: 'C' },
  });
  requireCondition(!run.error && run.status === 0,
    `generation-safe managed cleanup failed: ${run.stderr?.trim() || run.error?.message}`);
  let result;
  try {
    result = JSON.parse(run.stdout);
  } catch {
    throw new Error('generation-safe managed cleanup returned malformed JSON');
  }
  exactKeys(result, [
    'version', 'pid', 'start_identity', 'terminated', 'absent',
  ], 'generation-safe managed cleanup result');
  requireCondition(result.version === 1 && result.pid === identity.pid
    && result.start_identity === identity.start_identity
    && typeof result.terminated === 'boolean' && typeof result.absent === 'boolean'
    && result.terminated !== result.absent,
  'generation-safe managed cleanup result is invalid');
}

function invocationReceipt(fix, identity, environment) {
  return {
    version: 1,
    kind: 'coordinator',
    pid: identity.pid,
    start_identity: identity.start_identity,
    executable_path: fix.executable.path,
    executable_sha256: fix.executable.sha256,
    arguments: structuredClone(fix.spec.arguments),
    plan_path: fix.planReceipt.path,
    plan_sha256: fix.planReceipt.sha256,
    monitor_executable_path: fix.monitor.path,
    monitor_executable_sha256: fix.monitor.sha256,
    monitor_code_signature_hash: fix.plan.monitor.code_signature_hash,
    identity_handshake_path: identity.retained.path,
    identity_handshake_sha256: identity.retained.sha256,
    stdout_path: fix.spec.stdout_path,
    stderr_path: fix.spec.stderr_path,
    environment_policy_version: 1,
    environment_keys: environment.keys,
    environment_sha256: environment.sha256,
    captured_at_milliseconds: Date.now(),
    coordinator_source_path: fix.details.source.path,
    coordinator_source_sha256: fix.details.source.sha256,
    execution_source_sha256: fix.execution.source_sha256,
    execution_plan_sha256: fix.execution.plan_sha256,
    execution_staged: true,
  };
}

function helperArguments(fix, guardian) {
  return [
    '--stdout', fix.spec.stdout_path,
    '--stderr', fix.spec.stderr_path,
    '--pid-file', fix.spec.pid_path,
    '--ack-file', fix.spec.start_ack_path,
    '--start-timeout', String(fix.spec.start_timeout_seconds),
    '--run-timeout', String(fix.spec.run_timeout_seconds),
    '--', fix.spec.executable, ...fix.execution.arguments,
  ];
}

export async function runManagedLaunch(specPath, testHooks = {}) {
  const fix = validateSpec(specPath);
  validateMonitor(fix.monitor, fix.plan.monitor.code_signature_hash);
  const guardian = compileGuardian();
  try {
    prepareExecution(fix, guardian);
  } catch (error) {
    cleanupGuardian(guardian);
    throw error;
  }
  const environment = closedEnvironment();
  const helper = spawn(guardian.binary, helperArguments(fix, guardian), {
    stdio: ['pipe', 'pipe', 'pipe'],
    env: environment.values,
  });
  helper.stdout.setEncoding('utf8');
  helper.stderr.setEncoding('utf8');
  let buffered = '';
  let helperStderr = '';
  let childPID = null;
  let startedAt = null;
  let authenticatedIdentity = null;
  let exitEvent = null;
  let releaseEvent = null;
  let expectedRelease = null;
  let protocolError = null;
  let resolveSpawned;
  let rejectSpawned;
  const spawned = new Promise((resolve, reject) => { resolveSpawned = resolve; rejectSpawned = reject; });
  const helperClosed = new Promise((resolve, reject) => {
    helper.once('error', reject);
    helper.once('close', (code, signal) => resolve({ code, signal }));
  });
  const rejectProtocol = (message) => {
    if (protocolError !== null) return;
    protocolError = new Error(message);
    if (childPID === null) rejectSpawned(protocolError);
    try { helper.kill('SIGTERM'); } catch {}
  };
  helper.stdout.on('data', (chunk) => {
    buffered += chunk;
    while (buffered.includes('\n')) {
      const index = buffered.indexOf('\n');
      const line = buffered.slice(0, index);
      buffered = buffered.slice(index + 1);
      const fields = line.split(' ');
      if (fields[0] === 'SPAWNED' && fields.length === 3) {
        if (childPID !== null || !positiveInteger(Number(fields[1]))
          || !positiveInteger(Number(fields[2]))) {
          rejectProtocol(`guardian emitted invalid SPAWNED protocol: ${line}`);
          continue;
        }
        childPID = Number(fields[1]);
        startedAt = Number(fields[2]);
        resolveSpawned({ childPID, startedAt });
      } else if (fields[0] === 'RELEASED' && fields.length === 5) {
        const candidate = {
          version: Number(fields[1]),
          pid: Number(fields[2]),
          startIdentity: fields[3],
          invocationSHA256: fields[4],
        };
        if (releaseEvent !== null || expectedRelease === null
          || !sameJSON(candidate, expectedRelease)) {
          rejectProtocol(`guardian emitted invalid RELEASED authority: ${line}`);
          continue;
        }
        releaseEvent = candidate;
        process.stderr.write(`managed-launcher: released authenticated ${fix.spec.kind} pid ${candidate.pid}\n`);
        testHooks.afterRelease?.({ guardian: helper, childPID: candidate.pid });
      } else if (fields[0] === 'EXIT' && fields.length === 5) {
        if (exitEvent !== null) {
          rejectProtocol('guardian emitted more than one EXIT event');
          continue;
        }
        exitEvent = {
          pid: Number(fields[1]),
          exitCode: Number(fields[2]),
          signal: Number(fields[3]),
          completedAt: Number(fields[4]),
        };
      } else if (line.length > 0) {
        rejectProtocol(`guardian emitted unknown protocol line: ${line}`);
      }
    }
  });
  helper.stderr.on('data', (chunk) => { helperStderr += chunk; });
  helper.once('error', rejectSpawned);
  helper.once('close', (code) => {
    if (buffered.length > 0) rejectProtocol(`guardian emitted unterminated protocol: ${buffered}`);
    if (childPID === null) rejectSpawned(new Error(`guardian exited before spawn (${code}): ${helperStderr.trim()}`));
  });
  let stopStdout = () => {};
  let stopStderr = () => {};
  try {
    const launch = await new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error('timed out waiting for suspended child')),
        fix.spec.start_timeout_seconds * 1000,
      );
      spawned.then(
        (value) => { clearTimeout(timer); resolve(value); },
        (error) => { clearTimeout(timer); reject(error); },
      );
    });
    testHooks.afterSuspendedSpawn?.({
      childPID: launch.childPID,
      sourcePath: fix.details.source?.path ?? null,
      planPath: fix.planReceipt.path,
    });
    const identity = monitorHandshake(fix, launch.childPID, launch.startedAt);
    authenticatedIdentity = identity;
    const pidReceipt = readStableJSON(fix.spec.pid_path, 'suspended child PID receipt');
    exactKeys(pidReceipt.value, ['version', 'pid'], 'suspended child PID receipt');
    requireCondition(pidReceipt.value.version === 1 && pidReceipt.value.pid === launch.childPID,
      'suspended child PID file differs from guardian protocol');
    stopStdout = startTail(fix.spec.stdout_path, process.stdout);
    stopStderr = startTail(fix.spec.stderr_path, process.stderr);
    const invocation = invocationReceipt(fix, identity, environment);
    const invocationPublished = publishPrivateAtomicNoReplace(
      fix.spec.invocation_receipt_path,
      invocation,
    );
    testHooks.beforeAcknowledgement?.({
      childPID: identity.pid,
      startIdentity: identity.start_identity,
      invocationSHA256: invocationPublished.sha256,
    });
    publishPrivateAtomicNoReplace(fix.spec.start_ack_path, {
      version: 1,
      pid: identity.pid,
      start_identity: identity.start_identity,
      phase: 'start',
      invocation_sha256: invocationPublished.sha256,
    });
    expectedRelease = {
      version: 1,
      pid: identity.pid,
      startIdentity: identity.start_identity,
      invocationSHA256: invocationPublished.sha256,
    };
    await new Promise((resolve, reject) => {
      const onError = (error) => reject(error);
      helper.stdin.once('error', onError);
      helper.stdin.end(
        `ACK 1 ${identity.pid} ${identity.start_identity} ${invocationPublished.sha256}\n`,
        () => {
          helper.stdin.off('error', onError);
          resolve();
        },
      );
    });
    const helperResult = await helperClosed;
    stopStdout();
    stopStderr();
    if (protocolError !== null) throw protocolError;
    requireCondition(helperResult.code === 0 && helperResult.signal === null,
      `guardian failed (${helperResult.code ?? helperResult.signal}): ${helperStderr.trim()}`);
    requireCondition(releaseEvent !== null && sameJSON(releaseEvent, expectedRelease),
      'guardian omitted the exact authenticated release authority');
    requireCondition(exitEvent && exitEvent.pid === identity.pid && positiveInteger(exitEvent.completedAt),
      'guardian omitted the exact child exit event');
    const exitReceipt = {
      version: 1,
      process: fix.spec.kind,
      pid: identity.pid,
      start_identity: identity.start_identity,
      started_at_milliseconds: launch.startedAt,
      completed_at_milliseconds: exitEvent.completedAt,
      exit_code: exitEvent.exitCode >= 0 ? exitEvent.exitCode : null,
      signal: exitEvent.signal > 0 ? exitEvent.signal : null,
    };
    const exitPublished = publishPrivateAtomicNoReplace(fix.spec.exit_receipt_path, exitReceipt);
    return {
      kind: fix.spec.kind,
      pid: identity.pid,
      start_identity: identity.start_identity,
      invocation_sha256: invocationPublished.sha256,
      exit_sha256: exitPublished.sha256,
      exit_code: exitReceipt.exit_code,
      signal: exitReceipt.signal,
    };
  } catch (error) {
    try { helper.kill('SIGTERM'); } catch {}
    await Promise.race([
      helperClosed.catch(() => null),
      new Promise((resolve) => setTimeout(resolve, 2000)),
    ]);
    if (authenticatedIdentity !== null) {
      cleanupAuthenticatedChild(guardian, authenticatedIdentity);
    }
    throw error;
  } finally {
    stopStdout();
    stopStderr();
    cleanupGuardian(guardian);
  }
}

function invokedAsScript() {
  return process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
}

if (invokedAsScript()) {
  try {
    const options = parseOptions(process.argv.slice(2), ['spec']);
    const result = await runManagedLaunch(options.spec);
    process.stderr.write(`managed-launcher: ${JSON.stringify(result)}\n`);
    if (result.signal !== null) process.exitCode = 128 + result.signal;
    else process.exitCode = result.exit_code ?? 1;
  } catch (error) {
    process.stderr.write(`managed-launcher: ${error.message}\n`);
    process.exitCode = 1;
  }
}
