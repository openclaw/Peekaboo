#!/usr/bin/env node

import { spawn, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { performance } from 'node:perf_hooks';
import { fileURLToPath } from 'node:url';
import {
  exactKeys,
  parseOptions,
  positiveDecimal,
  readStableFile,
  readStableJSON,
  requireCondition,
  requirePrivateDirectory,
  requireStableExecutable,
  sha256,
  writePrivateExclusive,
} from './lib.mjs';

const HOST_ROLES = ['local', 'studio'];
const EPOCHS = ['before', 'during', 'after'];
const ROOT_CLASSES = [
  'agent', 'agent_requester', 'bridge', 'coordinator', 'elevation', 'fixture', 'integrated_cu',
];
const HOST_UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;
const HEX40 = /^[0-9a-f]{40}$/;
const HEX64 = /^[0-9a-f]{64}$/;

function run(executable, arguments_, label) {
  const result = spawnSync(executable, arguments_, {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LANG: 'C', LC_ALL: 'C' },
  });
  requireCondition(result.status === 0,
    `${label} failed: ${String(result.stderr || result.stdout).trim()}`);
  return `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
}

function processTable() {
  const output = run('/bin/ps', ['-axo', 'pid=,ppid='], 'process table');
  const table = new Map();
  for (const [index, line] of output.trim().split('\n').entries()) {
    const match = line.trim().match(/^([1-9][0-9]*)\s+([0-9]+)$/);
    requireCondition(match !== null, `process table row ${index + 1} is malformed`);
    const pid = Number(match[1]);
    const parentPID = Number(match[2]);
    requireCondition(Number.isSafeInteger(pid) && Number.isSafeInteger(parentPID),
      `process table row ${index + 1} is out of range`);
    requireCondition(!table.has(pid), `process table repeats PID ${pid}`);
    table.set(pid, parentPID);
  }
  return table;
}

function descendantPIDs(table, roots) {
  const selected = new Set(roots);
  let changed = true;
  while (changed) {
    changed = false;
    for (const [pid, parentPID] of table) {
      if (!selected.has(pid) && selected.has(parentPID)) {
        selected.add(pid);
        changed = true;
      }
    }
  }
  return [...selected].sort((left, right) => left - right);
}

export function accumulateDescendantPIDs(observedPIDs, table, roots) {
  for (const pid of descendantPIDs(table, roots)) observedPIDs.add(pid);
  return [...observedPIDs].sort((left, right) => left - right);
}

export function accumulatedDescendantPIDs(tables, roots) {
  const observedPIDs = new Set();
  for (const table of tables) accumulateDescendantPIDs(observedPIDs, table, roots);
  return [...observedPIDs].sort((left, right) => left - right);
}

export function validateRepeatedObservation(
  priorIdentity,
  currentIdentity,
  priorParent,
  currentParent,
  pid,
) {
  requireCondition(currentIdentity.pid === pid
    && currentIdentity.startIdentity === priorIdentity.start_identity,
  `task process ${pid} was reused during collection`);
  requireCondition(priorParent === currentParent,
    `task process ${pid} changed parent during collection`);
}

export function validateRepeatedExecutable(prior, current, pid) {
  requireCondition(
    prior.executable_path === current.executable_path
      && prior.executable_sha256 === current.executable_sha256
      && prior.code_signature_hash === current.code_signature_hash
      && prior.signing_identifier === current.signing_identifier
      && prior.team_id === current.team_id,
    `task process ${pid} changed executable identity during collection`,
  );
}

export function validateSampleGap(previousSampleAt, currentSampleAt, maximumGap) {
  requireCondition(Number.isSafeInteger(previousSampleAt) && previousSampleAt > 0
    && Number.isSafeInteger(currentSampleAt) && currentSampleAt >= previousSampleAt
    && Number.isSafeInteger(maximumGap) && maximumGap > 0,
  'process-table sample timestamps are malformed');
  const gap = currentSampleAt - previousSampleAt;
  requireCondition(gap <= maximumGap,
    `process-table sampling gap ${gap}ms exceeds ${maximumGap}ms`);
  return gap;
}

export function isFinalProcessTableSample(sampleCount, sampleStartedAt, deadline) {
  return Number.isSafeInteger(sampleCount) && sampleCount >= 2
    && Number.isFinite(sampleStartedAt) && Number.isFinite(deadline)
    && sampleStartedAt >= deadline;
}

function monitorJSON(monitor, command, pid, directory, sequence) {
  const output = path.join(directory, `${sequence}-${command}-${pid}.json`);
  run(monitor, [command, '--pid', String(pid), '--output', output], `monitor ${command} for PID ${pid}`);
  return readStableJSON(output, `monitor ${command} for PID ${pid}`).value;
}

function signingMetadata(executablePath) {
  const verification = spawnSync('/usr/bin/codesign', ['--verify', '--strict', executablePath], {
    encoding: 'utf8',
    timeout: 10_000,
    maxBuffer: 1024 * 1024,
    env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LANG: 'C', LC_ALL: 'C' },
  });
  requireCondition(!verification.error && verification.status === 0,
    `codesign verification failed for ${executablePath}`);
  const output = run('/usr/bin/codesign', ['-dvvv', executablePath], `codesign ${executablePath}`);
  const value = (key) => output.match(new RegExp(`^${key}=(.+)$`, 'm'))?.[1] ?? null;
  const codeSignatureHash = value('CDHash');
  const signingIdentifier = value('Identifier');
  const teamID = value('TeamIdentifier');
  requireCondition(HEX40.test(codeSignatureHash ?? '') && typeof signingIdentifier === 'string'
    && signingIdentifier.length > 0 && /^[A-Z0-9]{10}$/.test(teamID ?? ''),
  `codesign identity is incomplete for ${executablePath}`);
  return { codeSignatureHash, signingIdentifier, teamID };
}

function monitoredExecutableIdentity(monitorPath, pid, temporary, sequence) {
  const executable = monitorJSON(
    monitorPath,
    'process-executable',
    pid,
    temporary,
    `${sequence}-before`,
  );
  exactKeys(executable, ['pid', 'startIdentity', 'path', 'sha256'],
    `process executable ${pid}`);
  requireCondition(executable.pid === pid && /^[1-9][0-9]*$/.test(executable.startIdentity)
    && path.isAbsolute(executable.path) && HEX64.test(executable.sha256),
  `process executable ${pid} is malformed`);
  const canonicalPath = fs.realpathSync(executable.path);
  requireCondition(canonicalPath === executable.path,
    `process executable ${pid} is not canonical`);
  const retainedExecutable = requireStableExecutable(
    canonicalPath,
    `monitored process executable ${pid}`,
    { allowRootOwner: true },
  );
  requireCondition(retainedExecutable.sha256 === executable.sha256,
    `monitor reported incorrect executable bytes for PID ${pid}`);
  const signing = signingMetadata(canonicalPath);
  const after = monitorJSON(
    monitorPath,
    'process-executable',
    pid,
    temporary,
    `${sequence}-after`,
  );
  exactKeys(after, ['pid', 'startIdentity', 'path', 'sha256'],
    `final process executable ${pid}`);
  requireCondition(after.pid === executable.pid
    && after.startIdentity === executable.startIdentity
    && after.path === executable.path
    && after.sha256 === executable.sha256
    && fs.realpathSync(after.path) === canonicalPath,
  `process executable ${pid} changed during signed identity inspection`);
  return {
    pid,
    start_identity: executable.startIdentity,
    executable_path: canonicalPath,
    executable_name: path.basename(canonicalPath),
    executable_sha256: executable.sha256,
    code_signature_hash: signing.codeSignatureHash,
    signing_identifier: signing.signingIdentifier,
    team_id: signing.teamID,
  };
}

function compileLifecycleGuard(temporary) {
  const sourcePath = path.join(path.dirname(fileURLToPath(import.meta.url)), 'process-lifecycle-guard.c');
  const source = readStableFile(sourcePath, 'process lifecycle guard source', {
    privateFile: false,
  });
  const retainedSource = path.join(temporary, 'process-lifecycle-guard.c');
  fs.writeFileSync(retainedSource, source.bytes, { flag: 'wx', mode: 0o400 });
  const binary = path.join(temporary, 'process-lifecycle-guard');
  const build = spawnSync('/usr/bin/xcrun', [
    'cc', '-x', 'c', '-std=c11', '-Wall', '-Wextra', '-Werror', '-', '-o', binary,
  ], {
    input: source.bytes,
    encoding: 'utf8',
    timeout: 30_000,
    maxBuffer: 4 * 1024 * 1024,
    env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LANG: 'C', LC_ALL: 'C' },
  });
  requireCondition(!build.error && build.status === 0,
    `cannot build process lifecycle guard: ${build.stderr?.trim() || build.error?.message}`);
  fs.chmodSync(binary, 0o500);
  const executable = requireStableExecutable(binary, 'compiled process lifecycle guard');
  requireCondition(readStableFile(retainedSource, 'retained process lifecycle guard source').sha256
    === source.sha256, 'retained lifecycle guard source changed during compilation');
  return {
    binary: executable.path,
    binary_sha256: executable.sha256,
    source_sha256: source.sha256,
  };
}

function waitForFile(filePath, timeoutMilliseconds, label) {
  const deadline = Date.now() + timeoutMilliseconds;
  while (!fs.existsSync(filePath) && Date.now() < deadline) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
  }
  requireCondition(fs.existsSync(filePath), `${label} was not published before its deadline`);
}

function requireNoLifecycleViolation(outputPath) {
  if (!fs.existsSync(outputPath)) return;
  const result = readStableJSON(outputPath, 'process lifecycle result').value;
  requireCondition(result.passed === true,
    `continuous process lifecycle guard observed PID ${result.event_pid} flags ${result.event_flags}`);
}

function pathIsAbsent(filePath) {
  try {
    fs.lstatSync(filePath);
    return false;
  } catch (error) {
    requireCondition(error?.code === 'ENOENT', `cannot inspect output path ${filePath}`);
    return true;
  }
}

function validateSpec(value) {
  exactKeys(value, [
    'version', 'role', 'host_uuid', 'deployment_envelope_sha256', 'epoch',
    'observation_milliseconds', 'sample_interval_milliseconds',
    'maximum_sample_gap_milliseconds', 'ready_path', 'acknowledgement_path', 'roots',
  ], 'collector spec');
  requireCondition(value.version === 1 && HOST_ROLES.includes(value.role)
    && HOST_UUID.test(value.host_uuid) && HEX64.test(value.deployment_envelope_sha256)
    && EPOCHS.includes(value.epoch)
    && Number.isSafeInteger(value.observation_milliseconds)
    && value.observation_milliseconds >= 50 && value.observation_milliseconds <= 7_200_000
    && Number.isSafeInteger(value.sample_interval_milliseconds)
    && value.sample_interval_milliseconds >= 5 && value.sample_interval_milliseconds <= 100
    && value.sample_interval_milliseconds < value.observation_milliseconds
    && Number.isSafeInteger(value.maximum_sample_gap_milliseconds)
    && value.maximum_sample_gap_milliseconds >= value.sample_interval_milliseconds
    && value.maximum_sample_gap_milliseconds <= 10_000
    && typeof value.ready_path === 'string' && path.isAbsolute(value.ready_path)
    && !value.ready_path.includes('\0')
    && (value.acknowledgement_path === null || (
      typeof value.acknowledgement_path === 'string'
        && path.isAbsolute(value.acknowledgement_path)
        && !value.acknowledgement_path.includes('\0')
    ))
    && Array.isArray(value.roots) && value.roots.length > 0,
  'collector spec is malformed');
  requirePrivateDirectory(path.dirname(value.ready_path), 'collector readiness parent');
  requireCondition(pathIsAbsent(value.ready_path), 'collector readiness output must be absent');
  const roots = value.roots.map((root, index) => {
    exactKeys(root, [
      'root_id', 'root_class', 'pid', 'start_identity', 'code_signature_hash',
    ], `collector spec roots[${index}]`);
    requireCondition(typeof root.root_id === 'string' && /^[a-z][a-z0-9_-]{0,63}$/.test(root.root_id)
      && ROOT_CLASSES.includes(root.root_class) && Number.isSafeInteger(root.pid) && root.pid > 0
      && typeof root.start_identity === 'string' && /^[1-9][0-9]*$/.test(root.start_identity)
      && HEX40.test(root.code_signature_hash), `collector spec roots[${index}] is malformed`);
    return root;
  });
  requireCondition(new Set(roots.map((root) => root.root_id)).size === roots.length,
    'collector spec repeats a root ID');
  requireCondition(new Set(roots.map((root) => `${root.pid}:${root.start_identity}`)).size
    === roots.length, 'collector spec repeats a root process generation');
  requireCondition(roots.every((root, index) => index === 0
    || roots[index - 1].root_id < root.root_id), 'collector spec roots are not canonical');
  const requiresAcknowledgement = value.role === 'local' && value.epoch === 'during';
  requireCondition((value.acknowledgement_path !== null) === requiresAcknowledgement,
    'only the local/during collector requires an Agent acknowledgement path');
  let acknowledgementControl = null;
  if (value.acknowledgement_path !== null) {
    const parent = path.dirname(value.acknowledgement_path);
    requirePrivateDirectory(parent, 'Agent acknowledgement parent');
    const basename = path.basename(value.acknowledgement_path);
    acknowledgementControl = {
      acknowledgement_path: value.acknowledgement_path,
      authorization_source_path: path.join(parent, `.${basename}.lifecycle-source`),
      authorization_request_path: path.join(parent, `.${basename}.lifecycle-request`),
      authorization_result_path: path.join(parent, `.${basename}.lifecycle-result`),
    };
    const controlPaths = Object.values(acknowledgementControl);
    requireCondition(new Set([...controlPaths, value.ready_path]).size === controlPaths.length + 1,
      'collector readiness and acknowledgement control paths must be distinct');
    requireCondition(controlPaths.every(pathIsAbsent),
      'Agent acknowledgement control paths must be absent');
  }
  return { ...value, roots, acknowledgement_control: acknowledgementControl };
}

function processRecords(identities, parents, roots) {
  const rootByPID = new Map(roots.map((root) => [root.pid, root]));
  const processes = [...identities.keys()].sort((left, right) => left - right).map((pid) => {
    const process = identities.get(pid);
    const parentPID = parents.get(pid);
    const parent = identities.get(parentPID);
    return {
      pid: process.pid,
      start_identity: process.start_identity,
      parent_pid: rootByPID.has(pid) ? null : parentPID,
      parent_start_identity: rootByPID.has(pid) ? null : parent?.start_identity ?? null,
      executable_path: process.executable_path,
      executable_name: process.executable_name,
      executable_sha256: process.executable_sha256,
      code_signature_hash: process.code_signature_hash,
      signing_identifier: process.signing_identifier,
      team_id: process.team_id,
    };
  });
  requireCondition(processes.every((process) => process.parent_pid === null
    || process.parent_start_identity !== null), 'a task descendant parent escaped the collected tree');
  return processes;
}

function validateObservedRoots(identities, roots) {
  for (const root of roots) {
    const observed = identities.get(root.pid);
    requireCondition(observed
      && observed.start_identity === root.start_identity
      && observed.code_signature_hash === root.code_signature_hash,
    `task root ${root.root_id} generation or code identity changed`);
  }
}

function publishReadinessNoReplace(filePath, value) {
  const parent = path.dirname(filePath);
  requirePrivateDirectory(parent, 'collector readiness parent');
  requireCondition(pathIsAbsent(filePath), 'collector readiness output already exists');
  const stagedPath = path.join(
    parent,
    `.${path.basename(filePath)}.${process.pid}.${randomUUID()}.tmp`,
  );
  writePrivateExclusive(stagedPath, value);
  const staged = readStableFile(stagedPath, 'staged collector readiness');
  try {
    fs.linkSync(stagedPath, filePath);
    fs.unlinkSync(stagedPath);
    const published = readStableFile(filePath, 'collector readiness');
    requireCondition(published.bytes.equals(staged.bytes)
      && published.info.dev === staged.info.dev
      && published.info.ino === staged.info.ino,
    'collector readiness publication changed the staged bytes');
    return published;
  } catch (error) {
    try { fs.unlinkSync(stagedPath); } catch {}
    throw error;
  }
}

export function collectProcessTree(specPath, monitorPath, outputPath) {
  const spec = validateSpec(readStableJSON(specPath, 'collector spec').value);
  requirePrivateDirectory(path.dirname(outputPath), 'collector final output parent');
  requireCondition(pathIsAbsent(outputPath), 'collector final output must be absent');
  const reservedOutputPaths = [
    spec.ready_path,
    ...Object.values(spec.acknowledgement_control ?? {}),
  ];
  requireCondition(!reservedOutputPaths.includes(outputPath),
    'collector final output conflicts with a readiness or acknowledgement control path');
  const monitor = requireStableExecutable(monitorPath, 'signed process monitor', {
    allowRootOwner: true,
  });
  const monitorSigning = signingMetadata(monitor.path);
  const collectorBytes = fs.readFileSync(fileURLToPath(import.meta.url));
  const collectorSHA256 = sha256(collectorBytes);
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'pbq-process-tree.'));
  fs.chmodSync(temporary, 0o700);
  let lifecycleChild = null;
  let lifecycleCompleted = false;
  let lifecycleResultPath = null;
  try {
    const rootPIDs = spec.roots.map((root) => root.pid);
    const bootstrapTable = processTable();
    requireCondition(spec.roots.every((root) => bootstrapTable.has(root.pid)),
      'one or more task roots are absent before lifecycle observation');
    const lifecycleWatchedPIDs = descendantPIDs(bootstrapTable, rootPIDs);
    const lifecycleGuard = compileLifecycleGuard(temporary);
    const lifecycleReadyPath = path.join(temporary, 'lifecycle-ready.json');
    const lifecycleStopPath = path.join(temporary, 'lifecycle-stop.json');
    const lifecycleOutputPath = path.join(temporary, 'lifecycle-result.json');
    lifecycleResultPath = lifecycleOutputPath;
    const lifecycleStderrPath = path.join(temporary, 'lifecycle.stderr');
    const lifecycleStderr = fs.openSync(
      lifecycleStderrPath,
      fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL,
      0o600,
    );
    requireCondition(
      requireStableExecutable(
        lifecycleGuard.binary,
        'pre-spawn process lifecycle guard',
      ).sha256 === lifecycleGuard.binary_sha256,
      'compiled process lifecycle guard changed before spawn',
    );
    const lifecycleArguments = [
      '--ready', lifecycleReadyPath,
      '--stop', lifecycleStopPath,
      '--output', lifecycleOutputPath,
      ...lifecycleWatchedPIDs.flatMap((pid) => ['--pid', String(pid)]),
    ];
    if (spec.acknowledgement_control !== null) {
      lifecycleArguments.push(
        '--authorization-request', spec.acknowledgement_control.authorization_request_path,
        '--authorization-source', spec.acknowledgement_control.authorization_source_path,
        '--authorization-destination', spec.acknowledgement_control.acknowledgement_path,
        '--authorization-result', spec.acknowledgement_control.authorization_result_path,
      );
    }
    lifecycleChild = spawn(lifecycleGuard.binary, lifecycleArguments, {
      stdio: ['ignore', 'ignore', lifecycleStderr],
    });
    fs.closeSync(lifecycleStderr);
    lifecycleChild.on('error', () => {});
    requireCondition(Number.isSafeInteger(lifecycleChild.pid) && lifecycleChild.pid > 0,
      'process lifecycle guard did not start');
    waitForFile(lifecycleReadyPath, 5000, 'process lifecycle readiness');
    requireNoLifecycleViolation(lifecycleOutputPath);
    const lifecycleReady = readStableJSON(
      lifecycleReadyPath,
      'process lifecycle readiness',
    ).value;
    exactKeys(lifecycleReady, ['version', 'pid', 'started_at_milliseconds'],
      'process lifecycle readiness');
    requireCondition(lifecycleReady.version === 1 && lifecycleReady.pid === lifecycleChild.pid
      && Number.isSafeInteger(lifecycleReady.started_at_milliseconds)
      && lifecycleReady.started_at_milliseconds > 0,
    'process lifecycle readiness is malformed');
    const lifecycleIdentity = monitorJSON(
      monitor.path,
      'process-identity',
      lifecycleChild.pid,
      temporary,
      'lifecycle-readiness',
    );
    const lifecycleExecutable = monitorJSON(
      monitor.path,
      'process-executable',
      lifecycleChild.pid,
      temporary,
      'lifecycle-readiness',
    );
    exactKeys(lifecycleIdentity, ['pid', 'startIdentity'], 'process lifecycle identity');
    exactKeys(lifecycleExecutable, ['pid', 'startIdentity', 'path', 'sha256'],
      'process lifecycle executable');
    requireCondition(lifecycleIdentity.pid === lifecycleChild.pid
      && positiveDecimal(lifecycleIdentity.startIdentity)
      && lifecycleExecutable.pid === lifecycleChild.pid
      && lifecycleExecutable.startIdentity === lifecycleIdentity.startIdentity
      && lifecycleExecutable.path === lifecycleGuard.binary
      && lifecycleExecutable.sha256 === lifecycleGuard.binary_sha256,
    'process lifecycle guard identity differs from its compiled executable');
    const readyTable = processTable();
    requireCondition(JSON.stringify(descendantPIDs(readyTable, rootPIDs))
      === JSON.stringify(lifecycleWatchedPIDs),
    'task process membership changed before continuous lifecycle coverage');
    const identities = new Map();
    const parents = new Map();
    let sequence = 0;
    let sampleCount = 0;
    const observedPIDs = new Set();
    let coverageStartedAt = null;
    let coverageDeadlineMonotonic = null;
    let finalSampleStartedAt = null;
    let coverageCompletedAt = null;
    let previousSampleCompletedMonotonic = null;
    let nextSampleTargetMonotonic = null;
    let observedMaximumSampleGap = 0;
    let readinessPublished = null;
    let readinessPublishedAt = null;
    do {
      requireNoLifecycleViolation(lifecycleOutputPath);
      const sampleStartedAt = Date.now();
      const sampleStartedMonotonic = performance.now();
      const table = processTable();
      const sampleCompletedAt = Date.now();
      const sampleCompletedMonotonic = performance.now();
      requireCondition(sampleCompletedAt >= sampleStartedAt,
        'wall clock moved backward during process-table sampling');
      const sampleDuration = Math.ceil(sampleCompletedMonotonic - sampleStartedMonotonic);
      requireCondition(sampleDuration <= spec.maximum_sample_gap_milliseconds,
        `process-table sample duration ${sampleDuration}ms exceeds ${spec.maximum_sample_gap_milliseconds}ms`);
      if (previousSampleCompletedMonotonic !== null) {
        observedMaximumSampleGap = Math.max(
          observedMaximumSampleGap,
          validateSampleGap(
            Math.floor(previousSampleCompletedMonotonic),
            Math.ceil(sampleCompletedMonotonic),
            spec.maximum_sample_gap_milliseconds,
          ),
        );
      } else {
        coverageStartedAt = sampleCompletedAt;
        coverageDeadlineMonotonic = sampleCompletedMonotonic + spec.observation_milliseconds;
        nextSampleTargetMonotonic = sampleCompletedMonotonic;
      }
      previousSampleCompletedMonotonic = sampleCompletedMonotonic;
      finalSampleStartedAt = sampleStartedAt;
      coverageCompletedAt = sampleCompletedAt;
      requireCondition(spec.roots.every((root) => table.has(root.pid)),
        'one or more task roots disappeared during collection');
      const pids = accumulateDescendantPIDs(
        observedPIDs,
        table,
        spec.roots.map((root) => root.pid),
      ).filter((pid) => table.has(pid));
      for (const pid of pids) {
        const current = monitoredExecutableIdentity(
          monitorPath,
          pid,
          temporary,
          sequence++,
        );
        const prior = identities.get(pid);
        if (prior) {
          validateRepeatedObservation(
            prior,
            { pid: current.pid, startIdentity: current.start_identity },
            parents.get(pid),
            table.get(pid),
            pid,
          );
          validateRepeatedExecutable(prior, current, pid);
          continue;
        }
        identities.set(pid, current);
        parents.set(pid, table.get(pid));
      }
      requireNoLifecycleViolation(lifecycleOutputPath);
      if (readinessPublished === null) {
        validateObservedRoots(identities, spec.roots);
        const observedProcesses = processRecords(identities, parents, spec.roots);
        requireCondition(JSON.stringify(observedProcesses.map((process) => process.pid))
          === JSON.stringify(lifecycleWatchedPIDs),
        'initial authenticated process sample differs from lifecycle coverage');
        const readyMonitor = requireStableExecutable(
          monitor.path,
          'readiness signed process monitor',
          { allowRootOwner: true },
        );
        const readyMonitorSigning = signingMetadata(readyMonitor.path);
        requireCondition(readyMonitor.sha256 === monitor.sha256
          && readyMonitorSigning.codeSignatureHash === monitorSigning.codeSignatureHash,
        'signed process monitor changed before collector readiness');
        const publishedAt = Date.now();
        readinessPublishedAt = publishedAt;
        readinessPublished = publishReadinessNoReplace(spec.ready_path, {
          version: 1,
          role: spec.role,
          host_uuid: spec.host_uuid,
          deployment_envelope_sha256: spec.deployment_envelope_sha256,
          epoch: spec.epoch,
          collector_sha256: collectorSHA256,
          monitor_executable_path: monitor.path,
          monitor_executable_sha256: monitor.sha256,
          monitor_code_signature_hash: monitorSigning.codeSignatureHash,
          lifecycle_guard_sha256: lifecycleGuard.source_sha256,
          lifecycle_guard_binary_sha256: lifecycleGuard.binary_sha256,
          lifecycle_guard_executable_path: lifecycleGuard.binary,
          lifecycle_guard_pid: lifecycleChild.pid,
          lifecycle_guard_start_identity: lifecycleIdentity.startIdentity,
          lifecycle_result_path: lifecycleOutputPath,
          lifecycle_started_at_milliseconds: lifecycleReady.started_at_milliseconds,
          coverage_started_at_milliseconds: coverageStartedAt,
          published_at_milliseconds: publishedAt,
          lifecycle_watched_pids: lifecycleWatchedPIDs,
          roots: spec.roots,
          observed_processes: observedProcesses,
          acknowledgement_control: spec.acknowledgement_control,
          complete: true,
        });
      }
      sampleCount += 1;
      const finalSampleEligible = isFinalProcessTableSample(
        sampleCount,
        sampleStartedMonotonic,
        coverageDeadlineMonotonic,
      );
      if (!finalSampleEligible) {
        nextSampleTargetMonotonic += spec.sample_interval_milliseconds;
        const waitMilliseconds = Math.max(
          0,
          Math.ceil(nextSampleTargetMonotonic - performance.now()),
        );
        Atomics.wait(
          new Int32Array(new SharedArrayBuffer(4)),
          0,
          0,
          waitMilliseconds,
        );
      }
      if (finalSampleEligible) break;
    } while (true);
    const minimumSampleCount = Math.ceil(
      spec.observation_milliseconds / spec.maximum_sample_gap_milliseconds,
    ) + 1;
    requireCondition(sampleCount >= minimumSampleCount,
      'process-tree sample count is too small for the observation/gap contract');
    const capturedAt = Date.now();
    requireCondition(finalSampleStartedAt
      >= coverageStartedAt + spec.observation_milliseconds
      && finalSampleStartedAt <= coverageCompletedAt
      && coverageCompletedAt <= capturedAt,
    'process-tree wall-clock coverage ordering is invalid');
    writePrivateExclusive(lifecycleStopPath, {
      version: 1,
      stop_at_milliseconds: capturedAt,
    });
    waitForFile(lifecycleOutputPath, 5000, 'process lifecycle result');
    const lifecycleResult = readStableJSON(
      lifecycleOutputPath,
      'process lifecycle result',
    ).value;
    lifecycleCompleted = true;
    requireCondition(
      requireStableExecutable(
        lifecycleGuard.binary,
        'post-run process lifecycle guard',
      ).sha256 === lifecycleGuard.binary_sha256,
      'compiled process lifecycle guard changed during observation',
    );
    exactKeys(lifecycleResult, [
      'version', 'passed', 'started_at_milliseconds', 'completed_at_milliseconds',
      'watched_pids', 'event_count', 'event_pid', 'event_flags',
    ], 'process lifecycle result');
    requireCondition(lifecycleResult.version === 1 && lifecycleResult.passed === true
      && lifecycleResult.started_at_milliseconds === lifecycleReady.started_at_milliseconds
      && lifecycleResult.started_at_milliseconds <= coverageStartedAt
      && Number.isSafeInteger(lifecycleResult.completed_at_milliseconds)
      && lifecycleResult.completed_at_milliseconds >= capturedAt
      && JSON.stringify(lifecycleResult.watched_pids) === JSON.stringify(lifecycleWatchedPIDs)
      && lifecycleResult.event_count === 0
      && lifecycleResult.event_pid === null && lifecycleResult.event_flags === null,
    'continuous process lifecycle result is invalid');
    validateObservedRoots(identities, spec.roots);
    const processes = processRecords(identities, parents, spec.roots);
    const finalMonitor = requireStableExecutable(monitor.path, 'final signed process monitor', {
      allowRootOwner: true,
    });
    const finalMonitorSigning = signingMetadata(finalMonitor.path);
    requireCondition(finalMonitor.sha256 === monitor.sha256
      && finalMonitorSigning.codeSignatureHash === monitorSigning.codeSignatureHash,
    'signed process monitor changed during collection');
    let acknowledgementAuthorization = null;
    if (spec.acknowledgement_control !== null) {
      const control = spec.acknowledgement_control;
      const acknowledgement = readStableFile(
        control.acknowledgement_path,
        'guard-published Agent acknowledgement',
      );
      const request = readStableFile(
        control.authorization_request_path,
        'Agent acknowledgement authorization request',
      );
      const authorization = readStableJSON(
        control.authorization_result_path,
        'Agent acknowledgement authorization result',
      );
      exactKeys(authorization.value, [
        'version', 'guard_pid', 'authorized_at_milliseconds',
      ], 'Agent acknowledgement authorization result');
      requireCondition(authorization.value.version === 1
        && authorization.value.guard_pid === lifecycleChild.pid
        && Number.isSafeInteger(authorization.value.authorized_at_milliseconds)
        && authorization.value.authorized_at_milliseconds >= readinessPublishedAt
        && authorization.value.authorized_at_milliseconds <= capturedAt
        && pathIsAbsent(control.authorization_source_path),
      'Agent acknowledgement was not published by the covered lifecycle guard');
      acknowledgementAuthorization = {
        acknowledgement_path: acknowledgement.path,
        acknowledgement_sha256: acknowledgement.sha256,
        authorization_request_path: request.path,
        authorization_request_sha256: request.sha256,
        authorization_result_path: authorization.path,
        authorization_result_sha256: authorization.sha256,
        authorized_at_milliseconds: authorization.value.authorized_at_milliseconds,
      };
    }
    return writePrivateExclusive(outputPath, {
      version: 4,
      role: spec.role,
      host_uuid: spec.host_uuid,
      deployment_envelope_sha256: spec.deployment_envelope_sha256,
      epoch: spec.epoch,
      scope: 'task_owned_descendants',
      requested_observation_milliseconds: spec.observation_milliseconds,
      target_sample_interval_milliseconds: spec.sample_interval_milliseconds,
      coverage_started_at_milliseconds: coverageStartedAt,
      final_sample_started_at_milliseconds: finalSampleStartedAt,
      coverage_completed_at_milliseconds: coverageCompletedAt,
      captured_at_milliseconds: capturedAt,
      sample_count: sampleCount,
      maximum_sample_gap_milliseconds: spec.maximum_sample_gap_milliseconds,
      observed_maximum_sample_gap_milliseconds: observedMaximumSampleGap,
      continuous_lifecycle_observation: true,
      lifecycle_guard_sha256: lifecycleGuard.source_sha256,
      lifecycle_guard_binary_sha256: lifecycleGuard.binary_sha256,
      lifecycle_started_at_milliseconds: lifecycleResult.started_at_milliseconds,
      lifecycle_completed_at_milliseconds: lifecycleResult.completed_at_milliseconds,
      lifecycle_watched_pids: lifecycleWatchedPIDs,
      lifecycle_event_count: lifecycleResult.event_count,
      collector_sha256: collectorSHA256,
      readiness_path: readinessPublished.path,
      readiness_sha256: readinessPublished.sha256,
      readiness_published_at_milliseconds: readinessPublishedAt,
      acknowledgement_authorization: acknowledgementAuthorization,
      monitor_executable_path: monitor.path,
      monitor_executable_sha256: monitor.sha256,
      monitor_code_signature_hash: monitorSigning.codeSignatureHash,
      complete: true,
      roots: spec.roots,
      processes,
    });
  } finally {
    if (!lifecycleCompleted && !fs.existsSync(lifecycleResultPath ?? '')
      && lifecycleChild?.exitCode === null && lifecycleChild?.signalCode === null) {
      lifecycleChild.kill('SIGKILL');
    }
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}

function invokedAsScript() {
  return process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
}

if (invokedAsScript()) {
  try {
    if (process.argv[2] === '--self-test') {
      const fixture = new Map([[10, 1], [11, 10], [12, 11], [20, 1]]);
      requireCondition(JSON.stringify(descendantPIDs(fixture, [10])) === JSON.stringify([10, 11, 12]),
        'descendant self-test failed');
      const before = new Map([[10, 1]]);
      const during = new Map([[10, 1], [11, 10]]);
      const after = new Map([[10, 1]]);
      requireCondition(JSON.stringify(accumulatedDescendantPIDs([before, during, after], [10]))
        === JSON.stringify([10, 11]), 'short-lived descendant self-test failed');
      let reuseRejected = false;
      try {
        validateRepeatedObservation(
          { start_identity: '1001' },
          { pid: 10, startIdentity: '1002' },
          1,
          1,
          10,
        );
      } catch {
        reuseRejected = true;
      }
      requireCondition(reuseRejected, 'PID-reuse self-test failed');
      let sampleGapRejected = false;
      try {
        validateSampleGap(1000, 1101, 100);
      } catch {
        sampleGapRejected = true;
      }
      requireCondition(sampleGapRejected, 'sample-gap self-test failed');
      requireCondition(!isFinalProcessTableSample(2, 1099, 1100)
        && isFinalProcessTableSample(2, 1100, 1100),
      'final process-table sample self-test failed');
      process.stdout.write('{"version":1,"passed":true}\n');
    } else {
      const options = parseOptions(process.argv.slice(2), ['spec', 'monitor', 'output']);
      const result = collectProcessTree(options.spec, options.monitor, options.output);
      process.stdout.write(`${JSON.stringify({ output: options.output, sha256: result.sha256 })}\n`);
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
