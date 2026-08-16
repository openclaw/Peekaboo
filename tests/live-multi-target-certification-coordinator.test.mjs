import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const coordinator = path.join(repository, 'scripts/run-live-multi-target-certification.mjs');
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
  write(arg('--output'), { pid, startIdentity: String(pid) + '00' });
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
const write = (file, value) => {
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
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
    write(plan.output_path, response);
    socket.end();
  });
  socket.on('close', () => process.exit(0));
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
  await new Promise((resolve) => setTimeout(resolve, process.env.FAKE_CONTROLLER_EXIT_EARLY === plan.controller_id ? 10 : 900));
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
  for (const slot of slots) {
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
      frame: { x: 30, y: 40, width: 200, height: 40 },
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
      frame: { x: 30, y: 40, width: 200, height: 40 },
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
  fs.writeFileSync(artifacts + '/contract.json', '{}\n', { mode: 0o600 });
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
      foreground_target: target(FOREGROUND_PID + 10, `${FOREGROUND_PID + 10}00`, FOREGROUND_WINDOW),
      invariant_names: ['focus', 'window', 'cursor', 'input', 'clipboard', 'overlay'],
      crash_directory: crashes,
      interval_milliseconds: 10,
      code_signature_hash: 'a'.repeat(40),
    },
    external_foreground_timeout_seconds: 5,
    operation_timeout_seconds: 45,
    test_runtime: { catalog_path: catalogPath, finalizer_path: finalizer },
  };
  const planPath = path.join(root, 'plan.json');
  writePrivate(planPath, plan);
  return { root, runs, plan, planPath, finalizerLog };
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

async function runInteractive(fix, { markerMode = 'valid', env = {} } = {}) {
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
      if (event.event === 'external-foreground-window') {
        const window = JSON.parse(fs.readFileSync(event.window_path));
        const phase = window.phase === 'perform' ? 'task-complete' : 'restore-complete';
        const filePath = window.phase === 'perform' ? window.task_complete_path : window.restore_complete_path;
        writePrivate(filePath, {
          version: 1,
          execution_nonce: markerMode === 'stale' ? '0'.repeat(64) : event.execution_nonce,
          monitor_instance_id: event.monitor_instance_id,
          phase,
        });
      }
    }
  });
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  const result = await new Promise((resolve) => child.once('exit', (code, signal) => resolve({ code, signal })));
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

test('operation timeout covers both external windows and lifecycle overhead', () => {
  const fix = fixture();
  try {
    fix.plan.operation_timeout_seconds = 39;
    writePrivate(fix.planPath, fix.plan);
    const run = spawnSync(process.execPath, [coordinator, '--plan', fix.planPath], {
      encoding: 'utf8', env: coordinatorEnvironment(fix),
    });
    assert.notEqual(run.status, 0);
    assert.match(run.stderr, /external and operation timeouts are invalid/);
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

test('source-blind fake lifecycle reaches ineligible test completion after prepare and finalize', async () => {
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

test('fractional and negative-zero committed target coordinates fail before launch', () => {
  const fractional = fixture();
  try {
    fractional.plan.controllers[0].target.bounds.x = 20.5;
    writePrivate(fractional.planPath, fractional.plan);
    const run = spawnSync(process.execPath, [coordinator, '--plan', fractional.planPath], {
      encoding: 'utf8', env: coordinatorEnvironment(fractional),
    });
    assert.notEqual(run.status, 0);
    assert.match(run.stderr, /exact-window schema/);
    assert.deepEqual(fs.readdirSync(fractional.runs), []);
  } finally {
    fs.rmSync(fractional.root, { recursive: true, force: true });
  }

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
