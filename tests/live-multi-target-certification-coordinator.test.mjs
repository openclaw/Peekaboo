import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  finalizerCommandTimeoutMilliseconds,
  finalizerGlobalBudgetMilliseconds,
  requireForegroundControllerCodeIdentity,
} from '../scripts/run-live-multi-target-certification.mjs';

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const coordinator = path.join(repository, 'scripts/run-live-multi-target-certification.mjs');
const legacyCoordinator = path.join(repository, 'scripts/test-dual-controller-overlap.sh');
const backgroundCertification = path.join(repository, 'scripts/test-background-certification.sh');
const contract = path.join(repository, 'tests/contracts/live-multi-target-certification-coordinator.md');
const operatorDocumentation = path.join(repository, 'docs/testing/background-computer-use.md');
const TEAM_ID = 'FWJYW4S8P8';
const MONITOR_SOURCE = '2'.repeat(40);
const MONITOR_SHA = '3'.repeat(64);
const COORDINATOR_SHA = '5'.repeat(64);
const CURRENT_BUILD_COMMIT = spawnSync(
  '/usr/bin/git', ['-C', repository, 'rev-parse', '--verify', 'HEAD'], { encoding: 'utf8' },
).stdout.trim();
const HOST_PID = 9101;
const SENTINEL_PID = 9201;
const SENTINEL_WINDOW = 9202;
const FOREGROUND_PID = 9301;
const FOREGROUND_WINDOW = 9302;

function privateDirectory(prefix) {
  const base = fs.existsSync('/private/tmp') ? '/private/tmp' : os.tmpdir();
  const directory = fs.mkdtempSync(path.join(base, prefix));
  fs.chmodSync(directory, 0o700);
  return directory;
}

function writePrivate(filePath, value) {
  fs.writeFileSync(filePath, typeof value === 'string' ? value : `${JSON.stringify(value, null, 2)}\n`, {
    mode: 0o600,
  });
  fs.chmodSync(filePath, 0o600);
}

function writeExecutable(filePath, source) {
  fs.writeFileSync(filePath, source, { mode: 0o700 });
  fs.chmodSync(filePath, 0o700);
}

function target(pid, startIdentity, windowID) {
  return {
    scope: 'window',
    pid,
    start_identity: startIdentity,
    window_id: windowID,
    bounds: { x: 20, y: 30, width: 500, height: 300 },
    is_minimized: false,
  };
}

function controllerTarget(pid, startIdentity, windowID) {
  return {
    process_identifier: pid,
    process_start_identity_decimal: startIdentity,
    window_id: windowID,
    bounds: { x: 20, y: 30, width: 500, height: 300 },
    is_minimized: false,
    click_point: { x: 100, y: 100 },
  };
}

function fakeCatalog() {
  const slots = [];
  for (const [controllerID, targetID] of [
    ['controller-a', 'target-a'], ['controller-b', 'target-b'],
  ]) {
    slots.push(
      { slot_id: `${controllerID}-mutation-001`, controller_id: controllerID, target_id: targetID, checkpoint: null },
      { slot_id: `${controllerID}-protocol-130-001`, controller_id: controllerID, target_id: targetID, checkpoint: null },
      { slot_id: `${controllerID}-checkpoint-001`, controller_id: controllerID, target_id: targetID, checkpoint: 'post-mutation' },
      { slot_id: `${controllerID}-final-bounds`, controller_id: controllerID, target_id: targetID, checkpoint: 'final-bounds' },
    );
  }
  return {
    controlled_target_ids: ['target-a', 'target-b'],
    slots,
    protocol_source: { commit: 'e'.repeat(40) },
    trusted_bridge_host_team_ids: [TEAM_ID],
    trusted_controller_team_ids: [TEAM_ID],
    monitor_source: { commit: MONITOR_SOURCE, probe_sha256: MONITOR_SHA },
    current_build_source: { coordinator: { sha256: COORDINATOR_SHA } },
    trusted_monitor_team_ids: [TEAM_ID],
    monitor_contract: {
      crash_report_prefixes: ['Peekaboo', 'peekaboo-certification-controller'],
    },
  };
}

const fakeMonitorSource = String.raw`#!/usr/bin/env node
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import process from 'node:process';

process.umask(0o077);
const args = process.argv.slice(2);
const mode = args[0];
const arg = (name) => args[args.indexOf(name) + 1];
const write = (file, value) => {
  const temporary = file + '.tmp';
  fs.writeFileSync(temporary, JSON.stringify(value) + '\n', { mode: 0o600 });
  fs.renameSync(temporary, file);
  fs.chmodSync(file, 0o600);
};
const canonical = (value) => {
  if (value === null || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map(canonical);
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
};
const aggregate = (domain, value) => createHash('sha256').update(Buffer.concat([
  Buffer.from('peekaboo.multi-target-certification.' + domain + '.v2\0'),
  Buffer.from(JSON.stringify(canonical(value))),
])).digest('hex');
const fileSHA = (file) => createHash('sha256').update(fs.readFileSync(file)).digest('hex');
if (mode === 'sample') {
  write(arg('--output'), {
    timestamp: Date.now() / 1000,
    frontmostPID: Number(process.env.FAKE_SENTINEL_PID),
    frontmostBundleIdentifier: 'test.sentinel',
    frontmostWindowID: Number(process.env.FAKE_SENTINEL_WINDOW),
    cursor: { x: 1, y: 2 },
    clipboardChangeCount: 7,
    clipboardDigest: '7'.repeat(64),
    peekabooWindowIDs: [],
    visibleScreenFramesTopLeft: [{ x: 0, y: 0, width: 1000, height: 700 }],
  });
  process.exit(0);
}
if (mode === 'process-identity') {
  const pid = Number(arg('--pid'));
  const outputPath = arg('--output');
  const useFinalSentinelDrift = pid === Number(process.env.FAKE_SENTINEL_PID)
    && outputPath.includes('final-sentinel')
    && typeof process.env.FAKE_FINAL_SENTINEL_START_IDENTITY === 'string';
  write(outputPath, {
    pid,
    startIdentity: useFinalSentinelDrift
      ? process.env.FAKE_FINAL_SENTINEL_START_IDENTITY
      : String(pid) + '00',
  });
  process.exit(0);
}
if (mode === 'process-executable') {
  const pid = Number(arg('--pid'));
  write(arg('--output'), {
    pid,
    startIdentity: String(pid) + '00',
    path: process.argv[1],
    sha256: fileSHA(process.argv[1]),
  });
  process.exit(0);
}
if (mode !== 'watch') process.exit(2);
const output = arg('--output');
const contamination = arg('--contamination-output');
const ready = arg('--ready');
const heartbeatPath = arg('--heartbeat');
const producersPath = arg('--allowed-producers');
const historyPath = arg('--history-commitment');
const socketPath = arg('--attestation-socket');
const evidencePath = arg('--attestation-evidence');
const sealRequest = arg('--seal-request');
const sealReceipt = arg('--seal-receipt');
const nonce = arg('--execution-nonce');
const monitorID = arg('--monitor-instance-id');
fs.writeFileSync(output, '', { mode: 0o600 });
fs.writeFileSync(contamination, '', { mode: 0o600 });
let sequence = 0;
let epoch = 0;
let sealed = false;
const startedAt = Date.now();
const processReceipt = { pid: process.pid, start_identity: String(process.pid) + '00', code_signature_hash: 'a'.repeat(40) };
const server = net.createServer((socket) => {
  let input = '';
  socket.setEncoding('utf8');
  socket.on('data', (chunk) => {
    input += chunk;
    if (!input.includes('\n')) return;
    const request = JSON.parse(input.slice(0, input.indexOf('\n')));
    const evidence = JSON.parse(fs.readFileSync(evidencePath));
    socket.end(JSON.stringify({
      version: 1,
      execution_nonce: nonce,
      monitor_instance_id: monitorID,
      challenge: request.challenge,
      monitor: processReceipt,
      monitor_evidence_sha256: aggregate('monitor-evidence', evidence),
    }) + '\n');
  });
});
server.listen(socketPath, () => {
  fs.chmodSync(socketPath, 0o600);
  fs.writeFileSync(ready, 'ready\n', { mode: 0o600 });
});
const tick = () => {
  if (sealed) return;
  const producer = JSON.parse(fs.readFileSync(producersPath));
  sequence += 1;
  epoch += 1;
  const active = producer.foreground.active;
  const activity = producer.revision === 2
    && (process.env.FAKE_EARLY_ACTIVITY === '1' || Date.now() - startedAt > 450) ? 3 : 0;
  write(heartbeatPath, {
    sequence,
    monotonicMicroseconds: Number(process.hrtime.bigint() / 1000n),
    wallClockMilliseconds: Date.now() + (process.env.FAKE_CLOCK_DRIFT === '1' ? sequence * 3000 : 0),
    lastCleanSequence: sequence,
    contaminationRetries: 0,
    contaminationBlocked: false,
    inputAttributionAvailable: true,
    allowedProducerRevision: producer.revision,
    phase: 'running',
    cursorMovementObserved: false,
    pendingActivationCount: 0,
    pendingFocusedWindowChange: false,
    authorizationEpoch: epoch,
    transitionAcknowledged: false,
    foregroundActive: active,
    foregroundTargetPID: active ? producer.foreground.target.pid : null,
    foregroundTargetWindowID: active ? producer.foreground.target.windowID : null,
    attributedForegroundEventCount: activity,
    attributedForegroundSourcePIDs: activity ? [Number(process.env.FAKE_FOREGROUND_PID)] : [],
    foregroundActivityObserved: activity > 0,
    executionNonce: nonce,
    monitorInstanceID: monitorID,
    historyCommitmentSHA256: fs.readFileSync(historyPath, 'utf8').trim(),
  });
  if (fs.existsSync(sealRequest)) {
    const request = JSON.parse(fs.readFileSync(sealRequest));
    const evidence = JSON.parse(fs.readFileSync(request.draft_path));
    if (process.env.FAKE_TAMPER_SEAL === '1') evidence.execution_nonce = 'f'.repeat(64);
    write(request.sealed_path, evidence);
    write(heartbeatPath, evidence.fences.at(-1).heartbeat);
    write(sealReceipt, {
      version: 1,
      execution_nonce: nonce,
      monitor_instance_id: monitorID,
      phase: 'sealed',
      monitor_evidence_sha256: aggregate('monitor-evidence', evidence),
    });
    sealed = true;
  }
};
setInterval(tick, 20);
process.on('SIGTERM', () => server.close(() => process.exit(0)));
`;

const fakeControllerSource = String.raw`#!/usr/bin/env node
import { createHash, randomUUID } from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import process from 'node:process';

process.umask(0o077);
const args = process.argv.slice(2);
const read = (file) => JSON.parse(fs.readFileSync(file));
const canonical = (value) => {
  if (value === null || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map(canonical);
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
};
const write = (file, value) => {
  const temporary = file + '.' + process.pid + '.' + randomUUID() + '.tmp';
  const descriptor = fs.openSync(temporary, 'wx', 0o600);
  try {
    fs.writeFileSync(descriptor, JSON.stringify(canonical(value), null, 2) + '\n');
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  if (fs.existsSync(file)) {
    fs.unlinkSync(temporary);
    throw new Error('fake controller output already exists');
  }
  fs.renameSync(temporary, file);
  fs.chmodSync(file, 0o600);
};
const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');
const processReceipt = () => ({ pid: process.pid, start_identity: String(process.pid) + '00', code_signature_hash: 'b'.repeat(40) });
const wait = (file) => new Promise((resolve) => {
  const timer = setInterval(() => {
    if (fs.existsSync(file)) { clearInterval(timer); resolve(); }
  }, 10);
});
if (args[0] === '--attest-monitor') {
  const plan = read(args[1]);
  if (!plan.release_path || !plan.expected_peer || 'expected_peer_pid' in plan) process.exit(12);
  const socket = net.createConnection(plan.socket_path);
  const challenge = 'c'.repeat(64);
  let input = '';
  socket.setEncoding('utf8');
  socket.on('connect', () => socket.write(JSON.stringify({
    version: 1,
    execution_nonce: plan.execution_nonce,
    monitor_instance_id: plan.monitor_instance_id,
    challenge,
  }) + '\n'));
  socket.on('data', (chunk) => {
    input += chunk;
    if (!input.includes('\n')) return;
    const response = JSON.parse(input.slice(0, input.indexOf('\n')));
    if (process.env.FAKE_BAD_ATTESTATION === plan.response_kind) {
      const key = plan.response_kind === 'monitor' ? 'monitor_evidence_sha256' : 'witness_sha256';
      response[key] = 'f'.repeat(64);
    }
    const processKey = plan.response_kind === 'monitor' ? 'monitor' : 'observer';
    if (JSON.stringify(canonical(response[processKey])) !== JSON.stringify(canonical(plan.expected_peer))) {
      process.exit(13);
    }
    write(plan.output_path, response);
    socket.end();
  });
  socket.on('close', async () => {
    await wait(plan.release_path);
    process.exit(0);
  });
} else if (args[0] === '--plan') {
  const plan = read(args[1]);
  const root = plan.artifacts_directory;
  fs.mkdirSync(root + '/bundles', { mode: 0o700 });
  fs.mkdirSync(root + '/observations', { mode: 0o700 });
  write(plan.ready_path, {
    version: 1,
    execution_nonce: plan.execution_nonce,
    controller_id: plan.controller_id,
    target_id: plan.target_id,
    controller: processReceipt(),
    build: plan.expected_controller_build,
    ready_at_milliseconds: Date.now(),
  });
  await wait(plan.start_path);
  write(root + '/mutation-started.json', {
    version: 1, phase: 'mutation-started', execution_nonce: plan.execution_nonce,
    controller_id: plan.controller_id,
    target_id: plan.target_id,
    target: {
      scope: 'window',
      pid: plan.target.process_identifier,
      start_identity: plan.target.process_start_identity_decimal,
      window_id: plan.target.window_id,
      bounds: plan.target.bounds,
      is_minimized: plan.target.is_minimized,
    },
    timestamp_milliseconds: Date.now(),
  });
  const mutationDelayMilliseconds = process.env.FAKE_CONTROLLER_EXIT_EARLY === plan.controller_id
    ? 10
    : Number(process.env.FAKE_CONTROLLER_MUTATION_DELAY_MILLISECONDS ?? 900);
  await new Promise((resolve) => setTimeout(resolve, mutationDelayMilliseconds));
  if (process.env.FAKE_CONTROLLER_EXIT_EARLY === plan.controller_id) process.exit(9);
  write(root + '/mutation-completed.json', {
    version: 1, phase: 'mutation-completed', execution_nonce: plan.execution_nonce,
    controller_id: plan.controller_id,
    target_id: plan.target_id,
    target: {
      scope: 'window',
      pid: plan.target.process_identifier,
      start_identity: plan.target.process_start_identity_decimal,
      window_id: plan.target.window_id,
      bounds: plan.target.bounds,
      is_minimized: plan.target.is_minimized,
    },
    timestamp_milliseconds: Date.now(),
  });
  const slots = ['mutation-001', 'protocol-130-001', 'checkpoint-001', 'final-bounds'];
  for (const slot of slots.slice(0, -1)) {
    const requestID = randomUUID().toLowerCase();
    const versionEightID = requestID.slice(0, 14) + '8' + requestID.slice(15);
    write(root + '/bundles/' + versionEightID + '.json', { slot });
  }
  if (process.env.FAKE_DELAY_FINAL_BOUNDS_READY === plan.controller_id) {
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  const finalBoundsController = processReceipt();
  if (process.env.FAKE_BAD_FINAL_BOUNDS_READY === plan.controller_id) {
    finalBoundsController.start_identity = '1';
  }
  write(plan.final_bounds_ready_path, {
    version: 1,
    execution_nonce: plan.execution_nonce,
    monitor_instance_id: plan.monitor_instance_id,
    controller_id: plan.controller_id,
    target_id: plan.target_id,
    controller: finalBoundsController,
    completed_slot_ids: slots.slice(0, -1).map((slot) => plan.controller_id + '-' + slot),
    ready_at_milliseconds: Date.now(),
  });
  await wait(plan.final_bounds_start_path);
  write(root + '/final-bounds-started.json', {
    version: 1,
    execution_nonce: plan.execution_nonce,
    controller_id: plan.controller_id,
    timestamp_milliseconds: Date.now(),
  });
  {
    const slot = slots.at(-1);
    const requestID = randomUUID().toLowerCase();
    const versionEightID = requestID.slice(0, 14) + '8' + requestID.slice(15);
    write(root + '/bundles/' + versionEightID + '.json', { slot });
  }
  write(root + '/' + plan.controller_id + '-receipt.json', {
    version: 1,
    result: 'passed',
    execution_nonce: plan.execution_nonce,
    monitor_instance_id: plan.monitor_instance_id,
    controller_id: plan.controller_id,
    target_id: plan.target_id,
    controller: processReceipt(),
    build: plan.expected_controller_build,
    handshake: {},
    target: {},
    interval: { started_at_milliseconds: Date.now() - 500, completed_at_milliseconds: Date.now() },
    slots: slots.map((slot) => ({ slot_id: plan.controller_id + '-' + slot })),
  });
  await wait(plan.release_path);
  process.stdout.write(JSON.stringify({ result: 'passed', receipt: root + '/' + plan.controller_id + '-receipt.json' }) + '\n');
  process.exit(0);
} else if (args[0] === '--observe-only-plan') {
  const plan = read(args[1]);
  const observer = processReceipt();
  const focusFrame = process.env.FAKE_FRACTIONAL_FOCUS_FRAME === '1'
    ? { x: 30.5, y: 40.25, width: 200.5, height: 40.25 }
    : { x: 30, y: 40, width: 200, height: 40 };
  write(plan.ready_path, {
    version: 1,
    mode: 'observe-only',
    execution_nonce: plan.execution_nonce,
    observer_id: plan.observer_id,
    observer,
    observer_build: plan.expected_controller_build,
    target: plan.target,
    focused_element: {
      role: plan.semantic_element.role,
      identifier: plan.semantic_element.identifier,
      title: plan.semantic_element.title,
      frame: focusFrame,
    },
    request_marker: plan.request_marker,
    baseline_value_sha256: plan.baseline_value_sha256,
    expected_value_sha256: plan.expected_value_sha256,
    observation_path: plan.observation_path,
    restoration_path: plan.restoration_path,
    ready_at_milliseconds: Date.now(),
  });
  await wait(plan.observation_request_path);
  const observation = {
    version: 1,
    execution_nonce: plan.execution_nonce,
    request_marker: plan.request_marker,
    target: plan.target,
    observer,
    observed_value_sha256: plan.expected_value_sha256,
    observed_at_milliseconds: Date.now(),
  };
  write(plan.observation_path, observation);
  await wait(plan.restoration_request_path);
  const restoration = {
    ...observation,
    observed_value_sha256: plan.baseline_value_sha256,
    observed_at_milliseconds: Date.now(),
  };
  write(plan.restoration_path, restoration);
  const witness = {
    version: 1,
    execution_nonce: plan.execution_nonce,
    target: plan.target,
    observer,
    focused_element: {
      role: plan.semantic_element.role,
      identifier: plan.semantic_element.identifier,
      title: plan.semantic_element.title,
      frame: focusFrame,
    },
    interval: { started_at_milliseconds: Date.now() - 5, completed_at_milliseconds: Date.now() },
    request_marker: plan.request_marker,
    before_value_sha256: plan.baseline_value_sha256,
    expected_value_sha256: plan.expected_value_sha256,
    observed_value_sha256: plan.expected_value_sha256,
    restored_value_sha256: plan.baseline_value_sha256,
    observation_path: plan.observation_path,
    observation_file_sha256: sha(fs.readFileSync(plan.observation_path)),
    restoration_path: plan.restoration_path,
    restoration_file_sha256: sha(fs.readFileSync(plan.restoration_path)),
    passed: true,
    restored: true,
  };
  write(plan.witness_path, witness);
  const server = net.createServer((socket) => {
    let input = '';
    socket.setEncoding('utf8');
    socket.on('data', (chunk) => {
      input += chunk;
      if (!input.includes('\n')) return;
      const request = JSON.parse(input.slice(0, input.indexOf('\n')));
      socket.end(JSON.stringify({
        version: 1,
        execution_nonce: plan.execution_nonce,
        monitor_instance_id: plan.monitor_instance_id,
        challenge: request.challenge,
        observer,
        witness_sha256: sha(fs.readFileSync(plan.witness_path)),
        observation_file_sha256: witness.observation_file_sha256,
        restoration_file_sha256: witness.restoration_file_sha256,
        before_value_sha256: witness.before_value_sha256,
        expected_value_sha256: witness.expected_value_sha256,
        observed_value_sha256: witness.observed_value_sha256,
        restored_value_sha256: witness.restored_value_sha256,
      }) + '\n');
    });
  });
  server.listen(plan.attestation_socket_path, () => fs.chmodSync(plan.attestation_socket_path, 0o600));
  await wait(plan.release_path);
  server.close(() => process.exit(0));
} else {
  process.exit(2);
}
`;

const fakeFinalizerSource = String.raw`#!/usr/bin/env node
import fs from 'node:fs';
import process from 'node:process';
process.umask(0o077);
const args = process.argv.slice(2);
const arg = (name) => args[args.indexOf(name) + 1];
fs.appendFileSync(process.env.FAKE_FINALIZER_LOG, args[0] + '\n', { mode: 0o600 });
if (args[0] === 'prepare') {
  const artifacts = arg('--artifacts');
  fs.mkdirSync(artifacts, { mode: 0o700 });
  fs.writeFileSync(artifacts + '/contract.json', '{}\n', { mode: 0o600 });
}
if (['prepare', 'finalize'].includes(args[0])) {
  const delay = Number(process.env.FAKE_FINALIZER_BUNDLE_DELAY_MILLISECONDS ?? 0);
  for (let index = 0; index < 8; index += 1) {
    if (delay > 0) await new Promise((resolve) => setTimeout(resolve, delay));
    if (delay > 0) fs.appendFileSync(
      process.env.FAKE_FINALIZER_LOG,
      args[0] + '-bundle-' + index + '\n',
    );
  }
}
fs.writeFileSync(arg('--output'), JSON.stringify({ version: 1, structural_validation_passed: true }) + '\n', {
  flag: 'wx', mode: 0o600,
});
`;

function fixture() {
  const root = privateDirectory('plc-');
  const runs = path.join(root, 'runs');
  const crashes = path.join(root, 'crashes');
  fs.mkdirSync(runs, { mode: 0o700 });
  fs.mkdirSync(crashes, { mode: 0o700 });
  const monitor = path.join(root, 'fake-monitor.mjs');
  const controllerExecutable = path.join(root, 'fake-controller.mjs');
  const finalizer = path.join(root, 'fake-finalizer.mjs');
  const peekaboo = path.join(root, 'fake-peekaboo');
  const catalogPath = path.join(root, 'catalog.json');
  const finalizerLog = path.join(root, 'finalizer.log');
  writeExecutable(monitor, fakeMonitorSource);
  writeExecutable(controllerExecutable, fakeControllerSource);
  writeExecutable(finalizer, fakeFinalizerSource);
  writeExecutable(peekaboo, '#!/bin/sh\nexit 0\n');
  writePrivate(catalogPath, fakeCatalog());
  writePrivate(finalizerLog, '');
  const plan = {
    version: 1,
    runs_directory: runs,
    peekaboo_executable: peekaboo,
    controller_executable: controllerExecutable,
    monitor_executable: monitor,
    bridge: {
      socket_path: path.join(root, 'bridge.sock'),
      trusted_host_team_ids: [TEAM_ID],
      expected_host: {
        host_kind: 'gui',
        process_identifier: HOST_PID,
        process_start_identity_decimal: `${HOST_PID}00`,
        code_signature_hash: 'd'.repeat(40),
        source_commit: CURRENT_BUILD_COMMIT,
      },
    },
    controllers: [
      { controller_id: 'controller-a', target_id: 'target-a', target: controllerTarget(9401, '940100', 9402) },
      { controller_id: 'controller-b', target_id: 'target-b', target: controllerTarget(9501, '950100', 9502) },
    ],
    observer: {
      target: target(FOREGROUND_PID + 10, `${FOREGROUND_PID + 10}00`, FOREGROUND_WINDOW),
      semantic_element: { role: 'AXTextField', identifier: 'foreground-field', title: null },
      baseline_value: 'restored baseline',
    },
    monitor: {
      sentinel: target(SENTINEL_PID, `${SENTINEL_PID}00`, SENTINEL_WINDOW),
      foreground_controller: {
        pid: FOREGROUND_PID,
        start_identity: `${FOREGROUND_PID}00`,
        code_signature_hash: 'f'.repeat(40),
      },
      foreground_controller_team_id: TEAM_ID,
      foreground_target: target(FOREGROUND_PID + 10, `${FOREGROUND_PID + 10}00`, FOREGROUND_WINDOW),
      invariant_names: ['focus', 'window', 'cursor', 'input', 'clipboard', 'overlay'],
      crash_directory: crashes,
      interval_milliseconds: 10,
      code_signature_hash: 'a'.repeat(40),
    },
    external_foreground_timeout_seconds: 5,
    operation_timeout_seconds: 65,
    test_runtime: {
      catalog_path: catalogPath,
      finalizer_path: finalizer,
      diagnostic_reports_path: crashes,
    },
  };
  const planPath = path.join(root, 'plan.json');
  writePrivate(planPath, plan);
  return { root, runs, plan, planPath, finalizer, finalizerLog };
}

function coordinatorEnvironment(fix, extra = {}) {
  return {
    ...process.env,
    PEEKABOO_COORDINATOR_TEST_RUNTIME: '1',
    FAKE_FINALIZER_LOG: fix.finalizerLog,
    FAKE_SENTINEL_PID: String(SENTINEL_PID),
    FAKE_SENTINEL_WINDOW: String(SENTINEL_WINDOW),
    FAKE_FOREGROUND_PID: String(FOREGROUND_PID),
    ...extra,
  };
}

async function runInteractive(fix, {
  markerMode = 'valid', env = {}, markerDelayMilliseconds = {}, onEvent = null,
} = {}) {
  const child = spawn(process.execPath, [coordinator, '--plan', fix.planPath], {
    env: coordinatorEnvironment(fix, env),
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  let stdout = '';
  let stderr = '';
  const events = [];
  let buffered = '';
  child.stdout.on('data', (chunk) => {
    stdout += chunk;
    buffered += chunk;
    while (buffered.includes('\n')) {
      const index = buffered.indexOf('\n');
      const line = buffered.slice(0, index);
      buffered = buffered.slice(index + 1);
      if (!line) continue;
      const event = JSON.parse(line);
      events.push(event);
      onEvent?.(event);
      if (event.event === 'external-foreground-window') {
        const window = JSON.parse(fs.readFileSync(event.window_path));
        const phase = window.phase === 'perform' ? 'task-complete' : 'restore-complete';
        const filePath = window.phase === 'perform' ? window.task_complete_path : window.restore_complete_path;
        const publish = () => writePrivate(filePath, {
          version: 1,
          execution_nonce: markerMode === 'stale' ? '0'.repeat(64) : event.execution_nonce,
          monitor_instance_id: event.monitor_instance_id,
          phase,
        });
        const delay = markerDelayMilliseconds[window.phase] ?? 0;
        if (delay > 0) setTimeout(publish, delay);
        else publish();
      }
    }
  });
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  const result = await new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', (code, signal) => resolve({ code, signal }));
  });
  return { ...result, stdout, stderr, events };
}

test('behavior contract exists and excludes synthetic certification', () => {
  const text = fs.readFileSync(contract, 'utf8');
  assert.match(text, /certification_eligible: false/);
  assert.match(text, /Caller-written success/);
});

test('help and version are stable operator surfaces', () => {
  const help = spawnSync(process.execPath, [coordinator, '--help'], { encoding: 'utf8' });
  const version = spawnSync(process.execPath, [coordinator, '--version'], { encoding: 'utf8' });
  assert.equal(help.status, 0);
  assert.match(help.stdout, /--plan OWNER_PRIVATE_PLAN\.json/);
  assert.equal(version.stdout, 'peekaboo-live-multi-target-coordinator 1\n');
});

test('operator documentation exposes both bounded external marker handshakes', () => {
  const documentation = fs.readFileSync(operatorDocumentation, 'utf8');
  assert.match(documentation, /run-live-multi-target-certification\.mjs/);
  assert.match(documentation, /external-foreground-window/);
  assert.match(documentation, /task-complete/);
  assert.match(documentation, /restore-complete/);
  assert.match(documentation, /certification_eligible:false/);
});

test('documented legacy overlap entry point provides an explicit v4 migration', () => {
  const help = spawnSync(legacyCoordinator, ['--help'], { encoding: 'utf8' });
  assert.equal(help.status, 0, help.stderr);
  assert.match(help.stdout, /compatibility entry point/);
  assert.match(help.stdout, /run-live-multi-target-certification\.mjs/);
  assert.match(help.stdout, /--plan \/private\/path\/to\/live-coordinator-plan\.json/);
  assert.match(help.stdout, /--artifacts PATH/);

  const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'peekaboo-overlap-wrapper-'));
  try {
    const scripts = path.join(sandbox, 'scripts');
    fs.mkdirSync(scripts);
    const wrapper = path.join(scripts, 'test-dual-controller-overlap.sh');
    fs.copyFileSync(legacyCoordinator, wrapper);
    fs.chmodSync(wrapper, 0o700);
    const replacement = path.join(scripts, 'test-background-certification.sh');
    fs.writeFileSync(replacement, '#!/usr/bin/env bash\nprintf "<%s>\\n" "$@"\n', { mode: 0o700 });
    const artifacts = path.join(sandbox, 'selected-artifacts');
    for (const args of [
      ['--self-test', '--artifacts', artifacts],
      ['--artifacts', artifacts, '--self-test'],
    ]) {
      const forwarded = spawnSync(wrapper, args, { encoding: 'utf8' });
      assert.equal(forwarded.status, 0, forwarded.stderr);
      assert.equal(forwarded.stdout, `<--artifacts>\n<${artifacts}>\n`);
    }
  } finally {
    fs.rmSync(sandbox, { recursive: true, force: true });
  }

  const live = spawnSync(legacyCoordinator, ['--bridge-socket', '/private/tmp/legacy.sock'], {
    encoding: 'utf8',
  });
  assert.equal(live.status, 2);
  assert.match(live.stderr, /old live flags cannot be translated safely/i);
  const mixed = spawnSync(legacyCoordinator, [
    '--bridge-socket', '/private/tmp/legacy.sock', '--self-test',
  ], { encoding: 'utf8' });
  assert.equal(mixed.status, 2);
  assert.match(mixed.stderr, /old live flags cannot be translated safely/i);

  for (const args of [
    ['--artifacts', '/private/tmp/no-self-test'],
    ['--self-test', '--self-test'],
    ['--self-test', '--artifacts'],
    ['--self-test', '--artifacts', '/private/tmp/one', '--artifacts', '/private/tmp/two'],
  ]) {
    const invalid = spawnSync(legacyCoordinator, args, { encoding: 'utf8' });
    assert.equal(invalid.status, 2);
  }

  const invalidRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'peekaboo-background-root-'));
  try {
    fs.writeFileSync(path.join(invalidRoot, 'occupied'), 'occupied\n');
    const occupied = spawnSync(backgroundCertification, ['--artifacts', invalidRoot], { encoding: 'utf8' });
    assert.equal(occupied.status, 2);
    assert.match(occupied.stderr, /must be new or empty/);
    const file = path.join(invalidRoot, 'occupied');
    const notDirectory = spawnSync(backgroundCertification, ['--artifacts', file], { encoding: 'utf8' });
    assert.equal(notDirectory.status, 2);
    assert.match(notDirectory.stderr, /not a directory/);
    const unreadable = path.join(invalidRoot, 'unreadable');
    fs.mkdirSync(unreadable, { mode: 0o300 });
    try {
      const cannotInspect = spawnSync(backgroundCertification, ['--artifacts', unreadable], { encoding: 'utf8' });
      assert.equal(cannotInspect.status, 2);
      assert.match(cannotInspect.stderr, /Cannot inspect artifact directory/);
    } finally {
      fs.chmodSync(unreadable, 0o700);
    }
  } finally {
    fs.rmSync(invalidRoot, { recursive: true, force: true });
  }

  const documentation = fs.readFileSync(operatorDocumentation, 'utf8');
  assert.match(documentation, /--self-test --artifacts \/private\/path\/to\/empty-artifacts/);
});

test('closed plan rejects unknown caller fields before creating a run', () => {
  const fix = fixture();
  try {
    const invalid = { ...fix.plan, success: true };
    writePrivate(fix.planPath, invalid);
    const run = spawnSync(process.execPath, [coordinator, '--plan', fix.planPath], {
      encoding: 'utf8', env: coordinatorEnvironment(fix),
    });
    assert.notEqual(run.status, 0);
    assert.match(run.stderr, /plan keys are not closed/);
    assert.deepEqual(fs.readdirSync(fix.runs), []);
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('crash evidence accepts only the canonical DiagnosticReports directory', () => {
  const alternate = fixture();
  try {
    const emptyDirectory = path.join(alternate.root, 'caller-selected-empty-crashes');
    fs.mkdirSync(emptyDirectory, { mode: 0o700 });
    alternate.plan.monitor.crash_directory = emptyDirectory;
    writePrivate(alternate.planPath, alternate.plan);
    const run = spawnSync(process.execPath, [coordinator, '--plan', alternate.planPath], {
      encoding: 'utf8', env: coordinatorEnvironment(alternate),
    });
    assert.notEqual(run.status, 0);
    assert.match(run.stderr, /must equal the canonical user DiagnosticReports directory/);
    assert.deepEqual(fs.readdirSync(alternate.runs), []);
  } finally {
    fs.rmSync(alternate.root, { recursive: true, force: true });
  }

  const linked = fixture();
  try {
    const link = path.join(linked.root, 'diagnostic-reports-link');
    fs.symlinkSync(linked.plan.test_runtime.diagnostic_reports_path, link);
    linked.plan.test_runtime.diagnostic_reports_path = link;
    linked.plan.monitor.crash_directory = link;
    writePrivate(linked.planPath, linked.plan);
    const run = spawnSync(process.execPath, [coordinator, '--plan', linked.planPath], {
      encoding: 'utf8', env: coordinatorEnvironment(linked),
    });
    assert.notEqual(run.status, 0);
    assert.match(run.stderr, /must be one canonical non-symlink path/);
    assert.deepEqual(fs.readdirSync(linked.runs), []);
  } finally {
    fs.rmSync(linked.root, { recursive: true, force: true });
  }
});

test('outer finalizer timeout covers eight bounded validators and runtime identity overhead', () => {
  const timeout = finalizerCommandTimeoutMilliseconds(8);
  const identityInspection = 30_000 + 2_000 + 10_000 + 10_000 + 20_000 + 5_000;
  const pidAttestation = 15_000 + 2_000 + 10_000 + 10_000 + 20_000 + 5_000;
  const identityBudget = (15 * identityInspection) + (4 * pidAttestation);
  const stagingAndShutdownMargin = 300_000;
  assert.equal(timeout, (8 * 30_000) + identityBudget + stagingAndShutdownMargin);
  assert.ok(timeout > (8 * 30_000) + identityBudget);
  assert.equal(finalizerGlobalBudgetMilliseconds(8), 2 * timeout);
});

test('foreground controller code identity binds generation team and CDHash', () => {
  const expectedProcess = {
    pid: FOREGROUND_PID,
    start_identity: `${FOREGROUND_PID}00`,
    code_signature_hash: 'f'.repeat(40),
  };
  const input = {
    expectedProcess,
    expectedTeamID: TEAM_ID,
    before: { pid: FOREGROUND_PID, start_identity: `${FOREGROUND_PID}00` },
    after: { pid: FOREGROUND_PID, start_identity: `${FOREGROUND_PID}00` },
    observedTeamID: TEAM_ID,
    observedCodeSignatureHash: 'f'.repeat(40),
  };
  requireForegroundControllerCodeIdentity(input);
  for (const [name, change] of [
    ['generation', { after: { pid: FOREGROUND_PID, start_identity: `${FOREGROUND_PID}01` } }],
    ['team', { observedTeamID: 'AAAAAAAAAA' }],
    ['CDHash', { observedCodeSignatureHash: 'e'.repeat(40) }],
  ]) {
    assert.throws(
      () => requireForegroundControllerCodeIdentity({ ...input, ...change }),
      /foreground controller live process generation or code-signature identity/,
      name,
    );
  }
});

test('Bridge host commit must equal the coordinator Git HEAD even in test runtime', () => {
  const fix = fixture();
  try {
    fix.plan.bridge.expected_host.source_commit = 'e'.repeat(40);
    writePrivate(fix.planPath, fix.plan);
    const run = spawnSync(process.execPath, [coordinator, '--plan', fix.planPath], {
      encoding: 'utf8', env: coordinatorEnvironment(fix),
    });
    assert.notEqual(run.status, 0);
    assert.match(run.stderr, /bridge plan is malformed/);
    assert.deepEqual(fs.readdirSync(fix.runs), []);
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('duplicate exact physical targets fail before child launch', () => {
  const fix = fixture();
  try {
    fix.plan.controllers[1].target = structuredClone(fix.plan.controllers[0].target);
    fix.plan.test_runtime.finalizer_path = 'deliberately-relative-after-target-validation';
    writePrivate(fix.planPath, fix.plan);
    const run = spawnSync(process.execPath, [coordinator, '--plan', fix.planPath], {
      encoding: 'utf8', env: coordinatorEnvironment(fix),
    });
    assert.notEqual(run.status, 0);
    assert.match(run.stderr, /duplicate exact physical target|physical targets must be distinct/);
    assert.deepEqual(fs.readdirSync(fix.runs), []);
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('operation timeout covers typing, both external windows, and lifecycle overhead', () => {
  const fix = fixture();
  try {
    fix.plan.operation_timeout_seconds = 64;
    writePrivate(fix.planPath, fix.plan);
    const run = spawnSync(process.execPath, [coordinator, '--plan', fix.planPath], {
      encoding: 'utf8', env: coordinatorEnvironment(fix),
    });
    assert.notEqual(run.status, 0);
    assert.match(run.stderr, /does not cover controller typing, both external windows/);
    assert.deepEqual(fs.readdirSync(fix.runs), []);
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('21-second asymmetric window budget rejects the former two-window-only formula', () => {
  const fix = fixture();
  try {
    fix.plan.external_foreground_timeout_seconds = 21;
    fix.plan.operation_timeout_seconds = (2 * fix.plan.external_foreground_timeout_seconds) + 30;
    writePrivate(fix.planPath, fix.plan);
    const run = spawnSync(process.execPath, [coordinator, '--plan', fix.planPath], {
      encoding: 'utf8', env: coordinatorEnvironment(fix),
    });
    assert.notEqual(run.status, 0);
    assert.match(run.stderr, /does not cover controller typing, both external windows/);
    assert.deepEqual(fs.readdirSync(fix.runs), []);
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('greater-than-20-second asymmetric external window retains the bounded controller mutation', async () => {
  const fix = fixture();
  try {
    fix.plan.external_foreground_timeout_seconds = 30;
    fix.plan.operation_timeout_seconds = 140;
    writePrivate(fix.planPath, fix.plan);
    const performDelayMilliseconds = 21_000;
    assert.ok(
      (fix.plan.external_foreground_timeout_seconds * 1000) - performDelayMilliseconds >= 3000,
    );
    const startedAt = Date.now();
    const run = await runInteractive(fix, {
      env: { FAKE_CONTROLLER_MUTATION_DELAY_MILLISECONDS: '24000' },
      markerDelayMilliseconds: { perform: performDelayMilliseconds, restore: 25 },
    });
    assert.equal(run.code, 0, run.stderr);
    assert.ok(Date.now() - startedAt > 20_000);
    assert.deepEqual(run.events.filter((event) => event.event === 'external-foreground-window')
      .map((event) => event.phase), ['perform', 'restore']);
    const completion = run.events.at(-1);
    for (const controllerID of ['controller-a', 'controller-b']) {
      const controllerPlan = JSON.parse(fs.readFileSync(path.join(
        completion.run_root, 'controllers', controllerID, 'plan.json',
      )));
      const characterCount = [...controllerPlan.type_text].length;
      const typingDurationMilliseconds = characterCount * controllerPlan.typing_delay_milliseconds;
      assert.equal(characterCount, 1000);
      assert.equal(typingDurationMilliseconds, 50_000);
      assert.equal(
        fix.plan.operation_timeout_seconds * 1000,
        typingDurationMilliseconds
          + (2 * fix.plan.external_foreground_timeout_seconds * 1000)
          + 30_000,
      );
    }
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('equivalent plan targets ignore JSON object insertion order', () => {
  const fix = fixture();
  try {
    const target = fix.plan.observer.target;
    fix.plan.monitor.foreground_target = {
      is_minimized: target.is_minimized,
      bounds: {
        height: target.bounds.height,
        width: target.bounds.width,
        y: target.bounds.y,
        x: target.bounds.x,
      },
      window_id: target.window_id,
      start_identity: target.start_identity,
      pid: target.pid,
      scope: target.scope,
    };
    fix.plan.operation_timeout_seconds = 64;
    writePrivate(fix.planPath, fix.plan);
    const run = spawnSync(process.execPath, [coordinator, '--plan', fix.planPath], {
      encoding: 'utf8', env: coordinatorEnvironment(fix),
    });
    assert.notEqual(run.status, 0);
    assert.match(run.stderr, /does not cover controller typing, both external windows/);
    assert.deepEqual(fs.readdirSync(fix.runs), []);
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('semantic discriminator rejects empty, oversized, and NUL values before launch', () => {
  const invalidValues = [
    { role: 'AXTextField', identifier: '', title: null },
    { role: 'AXTextField', identifier: `x${'y'.repeat(1024)}`, title: null },
    { role: 'AX\0TextField', identifier: 'field', title: null },
  ];
  for (const semanticElement of invalidValues) {
    const fix = fixture();
    try {
      fix.plan.observer.semantic_element = semanticElement;
      writePrivate(fix.planPath, fix.plan);
      const run = spawnSync(process.execPath, [coordinator, '--plan', fix.planPath], {
        encoding: 'utf8', env: coordinatorEnvironment(fix),
      });
      assert.notEqual(run.status, 0);
      assert.match(run.stderr, /semantic plan is malformed/);
      assert.deepEqual(fs.readdirSync(fix.runs), []);
    } finally {
      fs.rmSync(fix.root, { recursive: true, force: true });
    }
  }
});

test('sorted-key fake lifecycle reaches ineligible test completion with bounded typing', async () => {
  const fix = fixture();
  try {
    const run = await runInteractive(fix);
    assert.equal(run.code, 0, run.stderr);
    assert.deepEqual(run.events.filter((event) => event.event === 'external-foreground-window')
      .map((event) => event.phase), ['perform', 'restore']);
    const completion = run.events.at(-1);
    assert.equal(completion.event, 'test-runtime-complete');
    assert.equal(completion.certification_eligible, false);
    assert.deepEqual(fs.readFileSync(fix.finalizerLog, 'utf8').trim().split('\n'), ['prepare', 'finalize']);
    assert.ok(fs.existsSync(completion.summary_path));
    const preparedArtifacts = path.join(completion.run_root, 'prepared-artifacts');
    assert.ok(fs.statSync(preparedArtifacts).isDirectory());
    assert.ok(fs.existsSync(path.join(preparedArtifacts, 'contract.json')));
    for (const [kind, processKey] of [['monitor', 'monitor'], ['observer', 'observer']]) {
      const attestationDirectory = path.join(completion.run_root, 'attestations', kind);
      const attestationPlan = JSON.parse(fs.readFileSync(path.join(attestationDirectory, 'plan.json')));
      const attestationResponse = JSON.parse(fs.readFileSync(attestationPlan.output_path));
      assert.equal('expected_peer_pid' in attestationPlan, false);
      assert.deepEqual(attestationPlan.expected_peer, attestationResponse[processKey]);
      assert.equal(path.dirname(attestationPlan.release_path), attestationDirectory);
      assert.ok(fs.existsSync(attestationPlan.release_path));
    }
    for (const controllerID of ['controller-a', 'controller-b']) {
      const controllerPlan = JSON.parse(fs.readFileSync(path.join(
        completion.run_root, 'controllers', controllerID, 'plan.json',
      )));
      const characterCount = [...controllerPlan.type_text].length;
      const typingDurationMilliseconds = characterCount * controllerPlan.typing_delay_milliseconds;
      assert.equal(characterCount, 500);
      assert.equal(Buffer.byteLength(controllerPlan.type_text, 'utf8'), 500);
      assert.equal(controllerPlan.typing_delay_milliseconds, 50);
      assert.ok(controllerPlan.type_text.startsWith(
        `peekaboo-certification-background:${completion.execution_nonce}:${controllerID}:`,
      ));
      assert.equal(typingDurationMilliseconds, 25_000);
      assert.equal(
        fix.plan.operation_timeout_seconds * 1000,
        typingDurationMilliseconds
          + (2 * fix.plan.external_foreground_timeout_seconds * 1000)
          + 30_000,
      );
    }
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('retained finalizer bytes survive mutable source replacement before prepare', async () => {
  const fix = fixture();
  const originalFinalizer = fs.readFileSync(fix.finalizer);
  let replaced = false;
  try {
    const run = await runInteractive(fix, {
      onEvent: (event) => {
        if (event.event !== 'external-foreground-window' || event.phase !== 'restore' || replaced) return;
        replaced = true;
        writeExecutable(fix.finalizer, String.raw`#!/usr/bin/env node
import fs from 'node:fs';
fs.appendFileSync(process.env.FAKE_FINALIZER_LOG, 'mutable-finalizer\n');
process.exit(91);
`);
      },
    });
    assert.equal(run.code, 0, run.stderr);
    assert.equal(replaced, true);
    assert.deepEqual(fs.readFileSync(fix.finalizerLog, 'utf8').trim().split('\n'), ['prepare', 'finalize']);
  } finally {
    writeExecutable(fix.finalizer, originalFinalizer);
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('delayed valid bundle workload completes under the derived outer finalizer deadline', async () => {
  const fix = fixture();
  try {
    const run = await runInteractive(fix, {
      env: { FAKE_FINALIZER_BUNDLE_DELAY_MILLISECONDS: '125' },
    });
    assert.equal(run.code, 0, run.stderr);
    assert.deepEqual(fs.readFileSync(fix.finalizerLog, 'utf8').trim().split('\n'), [
      'prepare',
      'prepare-bundle-0', 'prepare-bundle-1', 'prepare-bundle-2', 'prepare-bundle-3',
      'prepare-bundle-4', 'prepare-bundle-5', 'prepare-bundle-6', 'prepare-bundle-7',
      'finalize',
      'finalize-bundle-0', 'finalize-bundle-1', 'finalize-bundle-2', 'finalize-bundle-3',
      'finalize-bundle-4', 'finalize-bundle-5', 'finalize-bundle-6', 'finalize-bundle-7',
    ]);
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('maximum 150-second external windows fit bounded typing and the global budget', async () => {
  const fix = fixture();
  try {
    fix.plan.external_foreground_timeout_seconds = 150;
    fix.plan.operation_timeout_seconds = 500;
    writePrivate(fix.planPath, fix.plan);
    const run = await runInteractive(fix);
    assert.equal(run.code, 0, run.stderr);
    const completion = run.events.at(-1);
    assert.equal(completion.event, 'test-runtime-complete');
    for (const controllerID of ['controller-a', 'controller-b']) {
      const controllerPlan = JSON.parse(fs.readFileSync(path.join(
        completion.run_root, 'controllers', controllerID, 'plan.json',
      )));
      const characterCount = [...controllerPlan.type_text].length;
      const typingDurationMilliseconds = characterCount * controllerPlan.typing_delay_milliseconds;
      assert.equal(characterCount, 3400);
      assert.equal(Buffer.byteLength(controllerPlan.type_text, 'utf8'), 3400);
      assert.equal(typingDurationMilliseconds, 170_000);
      assert.equal(
        fix.plan.operation_timeout_seconds * 1000,
        typingDurationMilliseconds
          + (2 * fix.plan.external_foreground_timeout_seconds * 1000)
          + 30_000,
      );
    }
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('final-bounds capture starts only after both process-bound controller readiness markers', async () => {
  const fix = fixture();
  try {
    const run = await runInteractive(fix, {
      env: { FAKE_DELAY_FINAL_BOUNDS_READY: 'controller-b' },
    });
    assert.equal(run.code, 0, run.stderr);
    const completion = run.events.at(-1);
    const readinessTimes = [];
    const startTimes = [];
    for (const controllerID of ['controller-a', 'controller-b']) {
      const directory = path.join(completion.run_root, 'controllers', controllerID);
      const ready = JSON.parse(fs.readFileSync(path.join(directory, 'final-bounds-ready.json')));
      const start = JSON.parse(fs.readFileSync(path.join(directory, 'final-bounds-started.json')));
      const release = JSON.parse(fs.readFileSync(path.join(directory, 'final-bounds-start.json')));
      assert.deepEqual(ready.completed_slot_ids, [
        `${controllerID}-mutation-001`,
        `${controllerID}-protocol-130-001`,
        `${controllerID}-checkpoint-001`,
      ]);
      assert.equal(release.execution_nonce, completion.execution_nonce);
      assert.equal(release.monitor_instance_id, completion.monitor_instance_id);
      assert.equal(release.controller_id, controllerID);
      assert.equal(release.phase, 'final-bounds');
      readinessTimes.push(ready.ready_at_milliseconds);
      startTimes.push(start.timestamp_milliseconds);
    }
    assert.ok(Math.min(...startTimes) >= Math.max(...readinessTimes));
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('malformed final-bounds readiness fails before barrier release or finalization', async () => {
  const fix = fixture();
  try {
    const run = await runInteractive(fix, {
      env: { FAKE_BAD_FINAL_BOUNDS_READY: 'controller-a' },
    });
    assert.notEqual(run.code, 0);
    assert.match(run.stderr, /controller-a final-bounds readiness is not closed and process\/run bound/);
    const failed = run.events.find((event) => event.event === 'failed');
    assert.ok(failed);
    for (const controllerID of ['controller-a', 'controller-b']) {
      assert.equal(fs.existsSync(path.join(
        failed.run_root,
        'controllers',
        controllerID,
        'final-bounds-start.json',
      )), false);
    }
    assert.equal(fs.readFileSync(fix.finalizerLog, 'utf8'), '');
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('stale planned sentinel generation fails before the external window', async () => {
  const fix = fixture();
  try {
    fix.plan.monitor.sentinel.start_identity = `${SENTINEL_PID}99`;
    writePrivate(fix.planPath, fix.plan);
    const run = await runInteractive(fix);
    assert.notEqual(run.code, 0);
    assert.match(run.stderr, /baseline sentinel process generation differs from the exact plan/);
    assert.equal(run.events.some((event) => event.event === 'external-foreground-window'), false);
    assert.equal(fs.readFileSync(fix.finalizerLog, 'utf8'), '');
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('final sentinel generation drift fails before sealing or finalization', async () => {
  const fix = fixture();
  try {
    const run = await runInteractive(fix, {
      env: { FAKE_FINAL_SENTINEL_START_IDENTITY: `${SENTINEL_PID}01` },
    });
    assert.notEqual(run.code, 0);
    assert.match(run.stderr, /final sentinel process generation differs from the exact plan/);
    assert.deepEqual(run.events.filter((event) => event.event === 'external-foreground-window')
      .map((event) => event.phase), ['perform', 'restore']);
    assert.equal(fs.readFileSync(fix.finalizerLog, 'utf8'), '');
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('stale external marker fails closed and preserves the run root', async () => {
  const fix = fixture();
  try {
    const run = await runInteractive(fix, { markerMode: 'stale' });
    assert.notEqual(run.code, 0);
    assert.match(run.stderr, /marker is not closed and run-bound/);
    const failed = run.events.find((event) => event.event === 'failed');
    assert.ok(failed);
    assert.ok(fs.existsSync(failed.run_root));
    assert.equal(fs.readFileSync(fix.finalizerLog, 'utf8'), '');
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('controller exit before owner release aborts the live run', async () => {
  const fix = fixture();
  try {
    const run = await runInteractive(fix, { env: { FAKE_CONTROLLER_EXIT_EARLY: 'controller-a' } });
    assert.notEqual(run.code, 0);
    assert.match(run.stderr, /controller-a exited before its owner release/);
    assert.equal(fs.readFileSync(fix.finalizerLog, 'utf8'), '');
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('foreground activity before operations-start fails closed immediately', async () => {
  const fix = fixture();
  try {
    const run = await runInteractive(fix, { env: { FAKE_EARLY_ACTIVITY: '1' } });
    assert.notEqual(run.code, 0);
    assert.match(run.stderr, /foreground activity occurred before the grant-stable fence/);
    assert.equal(run.events.some((event) => event.event === 'external-foreground-window'), false);
    assert.equal(fs.readFileSync(fix.finalizerLog, 'utf8'), '');
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('cross-clock drift beyond two seconds rejects a stable fence', async () => {
  const fix = fixture();
  try {
    const run = await runInteractive(fix, { env: { FAKE_CLOCK_DRIFT: '1' } });
    assert.notEqual(run.code, 0);
    assert.match(run.stderr, /wall\/monotonic clock drift exceeded two seconds/);
    assert.equal(run.events.some((event) => event.event === 'external-foreground-window'), false);
    assert.equal(fs.readFileSync(fix.finalizerLog, 'utf8'), '');
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('finite fractional target geometry completes the coordinator lifecycle', async () => {
  const fractional = fixture();
  try {
    fractional.plan.controllers[0].target.bounds.x = 20.5;
    fractional.plan.controllers[0].target.bounds.width = 500.25;
    fractional.plan.controllers[0].target.click_point = { x: 100.125, y: 100.75 };
    writePrivate(fractional.planPath, fractional.plan);
    const run = await runInteractive(fractional, { env: { FAKE_FRACTIONAL_FOCUS_FRAME: '1' } });
    assert.equal(run.code, 0, run.stderr);
    assert.equal(run.events.at(-1).event, 'test-runtime-complete');
  } finally {
    fs.rmSync(fractional.root, { recursive: true, force: true });
  }
});

test('nonfinite, nonpositive, and negative-zero target geometry fail before launch', () => {
  const negativeZero = fixture();
  try {
    const raw = JSON.stringify(negativeZero.plan, null, 2)
      .replace('"x": 20,', '"x": -0,');
    writePrivate(negativeZero.planPath, `${raw}\n`);
    const run = spawnSync(process.execPath, [coordinator, '--plan', negativeZero.planPath], {
      encoding: 'utf8', env: coordinatorEnvironment(negativeZero),
    });
    assert.notEqual(run.status, 0);
    assert.match(run.stderr, /exact-window schema/);
    assert.deepEqual(fs.readdirSync(negativeZero.runs), []);
  } finally {
    fs.rmSync(negativeZero.root, { recursive: true, force: true });
  }

  for (const invalidWidth of [0, -1, Number.MAX_SAFE_INTEGER + 1]) {
    const invalid = fixture();
    try {
      invalid.plan.controllers[0].target.bounds.width = invalidWidth;
      writePrivate(invalid.planPath, invalid.plan);
      const run = spawnSync(process.execPath, [coordinator, '--plan', invalid.planPath], {
        encoding: 'utf8', env: coordinatorEnvironment(invalid),
      });
      assert.notEqual(run.status, 0);
      assert.match(run.stderr, /exact-window schema/);
      assert.deepEqual(fs.readdirSync(invalid.runs), []);
    } finally {
      fs.rmSync(invalid.root, { recursive: true, force: true });
    }
  }

  const nonfinite = fixture();
  try {
    const raw = JSON.stringify(nonfinite.plan, null, 2)
      .replace('"width": 500,', '"width": 1e309,');
    writePrivate(nonfinite.planPath, `${raw}\n`);
    const run = spawnSync(process.execPath, [coordinator, '--plan', nonfinite.planPath], {
      encoding: 'utf8', env: coordinatorEnvironment(nonfinite),
    });
    assert.notEqual(run.status, 0);
    assert.match(run.stderr, /exact-window schema/);
    assert.deepEqual(fs.readdirSync(nonfinite.runs), []);
  } finally {
    fs.rmSync(nonfinite.root, { recursive: true, force: true });
  }
});

test('monitor seal tampering is rejected before any finalizer invocation', async () => {
  const fix = fixture();
  try {
    const run = await runInteractive(fix, { env: { FAKE_TAMPER_SEAL: '1' } });
    assert.notEqual(run.code, 0);
    assert.match(run.stderr, /monitor-owned corpus seal differs/);
    assert.equal(fs.readFileSync(fix.finalizerLog, 'utf8'), '');
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});

test('PID-bound monitor digest mismatch is rejected before prepare', async () => {
  const fix = fixture();
  try {
    const run = await runInteractive(fix, { env: { FAKE_BAD_ATTESTATION: 'monitor' } });
    assert.notEqual(run.code, 0);
    assert.match(run.stderr, /monitor PID attestation does not bind/);
    assert.equal(fs.readFileSync(fix.finalizerLog, 'utf8'), '');
  } finally {
    fs.rmSync(fix.root, { recursive: true, force: true });
  }
});
