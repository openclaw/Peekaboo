import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { projectBindings } from '../project-live-bindings.mjs';
import { runManagedLaunch } from '../managed-launcher.mjs';
import { publishCoordinatorMarker } from '../publish-coordinator-marker.mjs';
import {
  generateManifest,
  generateSourceManifest,
  verifyManifest,
} from '../qualification-manifest.mjs';
import { validateConcurrentRun } from '../validate-concurrent-run.mjs';
import { aggregateSHA256, sha256 } from '../lib.mjs';

const TEAM = 'FWJYW4S8P8';
const SOURCE = 'a'.repeat(40);
const CDHASH = 'b'.repeat(40);
const UUID = '12345678-1234-4abc-8def-123456789abc';
const NONCE = 'c'.repeat(64);
const toolRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

function codeSignatureHash(executablePath) {
  const result = spawnSync('/usr/bin/codesign', ['-dvvv', executablePath], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  const match = `${result.stdout}\n${result.stderr}`.match(/^CDHash=([0-9a-f]{40})$/m);
  assert.ok(match);
  return match[1];
}

function privateDirectory(parent, name) {
  const directory = path.join(parent, name);
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  fs.chmodSync(directory, 0o700);
  return directory;
}

function writeFile(filePath, bytes, mode = 0o600) {
  fs.writeFileSync(filePath, bytes, { mode });
  fs.chmodSync(filePath, mode);
  return filePath;
}

function writeJSON(filePath, value, mode = 0o600) {
  return writeFile(filePath, `${JSON.stringify(value, null, 2)}\n`, mode);
}

function installedInventory(
  root,
  role,
  hostUUID,
  entries,
  qualificationToolsAggregate,
  elevationReceiptSHA256,
  suffix = '',
) {
  const projection = {
    deployment_envelope_sha256: '8'.repeat(64),
    peekaboo_source_commit: SOURCE,
    openclaw_source_commit: '9'.repeat(40),
    qualification_tools_aggregate_sha256: qualificationToolsAggregate,
    entries,
  };
  return writeJSON(path.join(root, `${role}-installed${suffix}.json`), {
    version: 1,
    role,
    host_uuid: hostUUID,
    hostname: role === 'local' ? 'megaclaw' : 'steipete-studio-sf.local',
    ...projection,
    elevation_receipt_sha256: elevationReceiptSHA256,
    captured_at_milliseconds: role === 'local' ? 1787000000100 : 1787000000200,
    aggregate_sha256: aggregateSHA256('installed-inventory', projection),
  });
}

function taskProcessTree(root, role, hostUUID, epoch, {
  collectorSHA256,
  forbiddenName = null,
  forbiddenRoot = false,
  orphan = false,
} = {}) {
  const requiredClasses = role === 'local'
    ? (epoch === 'during'
      ? ['agent', 'bridge', 'coordinator', 'elevation', 'fixture', 'integrated_cu']
      : ['bridge', 'elevation', 'integrated_cu'])
    : (epoch === 'during' ? ['bridge', 'elevation', 'fixture'] : ['bridge', 'elevation']);
  const classPID = {
    agent: 710,
    bridge: role === 'local' ? 720 : 820,
    coordinator: 730,
    elevation: role === 'local' ? 740 : 840,
    fixture: role === 'local' ? 750 : 850,
    integrated_cu: 760,
  };
  const executableNames = {
    agent: 'peekaboo',
    bridge: 'Peekaboo',
    coordinator: 'peekaboo-certification-controller',
    elevation: 'OpenClaw',
    fixture: 'Playground',
    integrated_cu: 'SkyComputerUseService',
  };
  const classCodeHash = {
    agent: '1', bridge: '2', coordinator: '3', elevation: '4', fixture: '5', integrated_cu: '6',
  };
  const roots = requiredClasses.map((rootClass) => {
    const pid = classPID[rootClass];
    return {
      root_id: `${rootClass}-root`,
      root_class: rootClass,
      pid,
      start_identity: `${pid}001`,
      code_signature_hash: classCodeHash[rootClass].repeat(40),
    };
  }).sort((left, right) => (left.root_id < right.root_id ? -1 : 1));
  const processes = roots.map((authority) => {
    const originalName = executableNames[authority.root_class];
    const executableName = forbiddenRoot && authority === roots[0] ? forbiddenName : originalName;
    return {
      pid: authority.pid,
      start_identity: authority.start_identity,
      parent_pid: null,
      parent_start_identity: null,
      executable_path: `/private/tmp/qualification/${executableName}`,
      executable_name: executableName,
      executable_sha256: 'a'.repeat(64),
      code_signature_hash: authority.code_signature_hash,
      signing_identifier: `fixture.${role}.${authority.root_class}`,
      team_id: TEAM,
    };
  });
  const parent = roots[0];
  const childPID = role === 'local' ? 799 : 899;
  const childName = !forbiddenRoot && forbiddenName ? forbiddenName : 'qualification-worker';
  processes.push({
    pid: childPID,
    start_identity: `${childPID}001`,
    parent_pid: orphan ? 999 : parent.pid,
    parent_start_identity: orphan ? '999001' : parent.start_identity,
    executable_path: `/private/tmp/qualification/${childName}`,
    executable_name: childName,
    executable_sha256: 'b'.repeat(64),
    code_signature_hash: 'f'.repeat(40),
    signing_identifier: null,
    team_id: null,
  });
  processes.sort((left, right) => left.pid - right.pid);
  const epochOffset = { before: 1, during: 2, after: 3 }[epoch];
  return writeJSON(path.join(root, `${role}-${epoch}-${forbiddenName ?? (orphan ? 'orphan' : 'tree')}.json`), {
    version: 1,
    role,
    host_uuid: hostUUID,
    deployment_envelope_sha256: '8'.repeat(64),
    epoch,
    scope: 'task_owned_descendants',
    captured_at_milliseconds: 1787000010000 + epochOffset,
    collector_sha256: collectorSHA256,
    complete: true,
    roots,
    processes,
  });
}

function deploymentFixture(root, qualificationToolsAggregate, { studioEntries = null } = {}) {
  const localUUID = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
  const studioUUID = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB';
  const entries = [
    {
      artifact: 'openclaw_app', relative_path: 'OpenClaw.app/Contents/MacOS/OpenClaw',
      type: 'file', mode: 0o755, size: 300, sha256: 'c'.repeat(64),
    },
    {
      artifact: 'peekaboo_app', relative_path: 'Peekaboo.app/Contents/MacOS/Peekaboo',
      type: 'file', mode: 0o755, size: 200, sha256: 'd'.repeat(64),
    },
    {
      artifact: 'peekaboo_cli', relative_path: 'runtime/libswiftCompatibilitySpan.dylib',
      type: 'file', mode: 0o644, size: 100, sha256: 'e'.repeat(64),
    },
    {
      artifact: 'peekaboo_cli', relative_path: 'runtime/peekaboo',
      type: 'file', mode: 0o755, size: 400, sha256: 'f'.repeat(64),
    },
    {
      artifact: 'peekaboo_cli', relative_path: 'symlink/peekaboo',
      type: 'symlink', mode: 0o777, target: '../runtime/peekaboo',
    },
  ];
  const elevationReceipts = [
    writeJSON(path.join(root, 'local-elevation-receipt.json'), { role: 'local', receipt: true }),
    writeJSON(path.join(root, 'studio-elevation-receipt.json'), { role: 'studio', receipt: true }),
  ];
  const installed = [
    installedInventory(
      root, 'local', localUUID, entries, qualificationToolsAggregate,
      sha256(fs.readFileSync(elevationReceipts[0])),
    ),
    installedInventory(
      root, 'studio', studioUUID, studioEntries ?? entries, qualificationToolsAggregate,
      sha256(fs.readFileSync(elevationReceipts[1])),
    ),
  ];
  const collector = path.join(toolRoot, 'process-tree-collector.mjs');
  const collectorSHA256 = sha256(fs.readFileSync(collector));
  const processTrees = [
    ...['before', 'during', 'after'].map((epoch) => (
      taskProcessTree(root, 'local', localUUID, epoch, { collectorSHA256 })
    )),
    ...['before', 'during', 'after'].map((epoch) => (
      taskProcessTree(root, 'studio', studioUUID, epoch, { collectorSHA256 })
    )),
  ];
  const policyScanner = writeFile(path.join(root, 'executable-policy-scanner'), 'scanner', 0o500);
  const scannerSHA256 = sha256(fs.readFileSync(policyScanner));
  const policyReports = [
    ['local', localUUID], ['studio', studioUUID],
  ].map(([role, hostUUID]) => writeJSON(path.join(root, `${role}-executable-policy.json`), {
    version: 1,
    role,
    host_uuid: hostUUID,
    deployment_envelope_sha256: '8'.repeat(64),
    scanner_sha256: scannerSHA256,
    complete: true,
    scanned_executable_count: 3,
    scanned_script_count: 3,
    forbidden_findings: [],
  }));
  return {
    installed,
    elevationReceipts,
    collector,
    processTrees,
    policyScanner,
    policyReports,
    localUUID,
    studioUUID,
    collectorSHA256,
  };
}

function executable(root, name, bytes = name) {
  return writeFile(path.join(root, name), bytes, 0o500);
}

function codesign(root, name, executablePath, cdhash = CDHASH) {
  return writeFile(path.join(root, name), [
    `Executable=${executablePath}`,
    'Identifier=fixture',
    `CDHash=${cdhash}`,
    `TeamIdentifier=${TEAM}`,
    'Authority=Developer ID Application: Fixture',
    'Authority=Developer ID Certification Authority',
    'Authority=Apple Root CA',
    '',
  ].join('\n'));
}

function calibrationReceipt(root, name, executablePath, controlledTarget, cdhash = 'e'.repeat(40)) {
  const identity = {
    pid: 205,
    start_identity: '205001',
    executable_path: executablePath,
    executable_sha256: sha256(fs.readFileSync(executablePath)),
    team_id: TEAM,
    code_signature_hash: cdhash,
    signing_identifier: 'fixture.integrated-cu-emitter',
    apple_anchored: true,
  };
  return writeJSON(path.join(root, name), {
    version: 1,
    event_count: 1,
    settle_milliseconds: 250,
    target: {
      pid: controlledTarget.pid,
      start_identity: controlledTarget.start_identity,
      window_id: controlledTarget.window_id,
      bounds: controlledTarget.bounds,
    },
    captured_event: {
      type: 'left_mouse_down',
      source_pid: 205,
      source_start_identity_at_callback: '205001',
      timestamp_nanoseconds: 123456789,
    },
    before: identity,
    after: identity,
  });
}

function processReceipt(root, name, pid, startIdentity) {
  return writeJSON(path.join(root, `${name}-process.json`), { pid, startIdentity });
}

function windowReceipt(root, name, pid, windowID, bounds) {
  return writeJSON(path.join(root, `${name}-windows.json`), {
    success: true,
    data: {
      windows: [{
        window_title: name,
        window_id: windowID,
        bounds,
        is_on_screen: true,
        is_key: false,
        layer: 0,
      }],
      target_application_info: { app_name: name, bundle_id: `fixture.${name}`, pid },
    },
  });
}

function targetSpec(root, name, pid, start, windowID, bounds) {
  return {
    process_identity: processReceipt(root, name, pid, start),
    window_inventory: windowReceipt(root, name, pid, windowID, bounds),
  };
}

function projectionFixture(root) {
  const fixtureHome = privateDirectory(root, 'home');
  const crashDirectory = privateDirectory(privateDirectory(privateDirectory(fixtureHome, 'Library'), 'Logs'), 'DiagnosticReports');
  const runs = privateDirectory(root, 'runs');
  const peekaboo = executable(root, 'peekaboo');
  const controller = executable(root, 'controller');
  const monitor = executable(root, 'monitor');
  const emitterExecutable = executable(root, 'cu-emitter');
  const bridge = writeJSON(path.join(root, 'bridge.json'), {
    success: true,
    data: {
      selected: {
        source: 'remote',
        socketPath: path.join(root, 'bridge.sock'),
        handshake: {
          negotiatedVersion: { major: 1, minor: 30 },
          hostKind: 'gui',
          hostIdentity: {
            processIdentifier: 200,
            processStartIdentityDecimal: '200001',
            codeSignatureHash: 'd'.repeat(40),
            sourceCommit: SOURCE,
          },
        },
      },
    },
  });
  const bounds = [0, 500, 1000, 1500].map((x) => ({ x, y: 20, width: 400, height: 300 }));
  const controllerA = targetSpec(root, 'controller-a', 201, '201001', 301, bounds[0]);
  const controllerB = targetSpec(root, 'controller-b', 202, '202001', 302, bounds[1]);
  const observer = targetSpec(root, 'observer', 203, '203001', 303, bounds[2]);
  const sentinel = targetSpec(root, 'sentinel', 204, '204001', 304, bounds[3]);
  const semantic = writeJSON(path.join(root, 'semantic.json'), {
    version: 1,
    target: { pid: 203, start_identity: '203001', window_id: 303 },
    focused_element: {
      role: 'AXTextArea',
      identifier: 'fixture-field',
      title: null,
      frame: { x: 1010, y: 30, width: 200, height: 100 },
    },
    baseline_value: 'baseline',
  });
  const catalog = writeJSON(path.join(root, 'catalog.json'), {
    trusted_bridge_host_team_ids: [TEAM],
    trusted_monitor_team_ids: [TEAM],
    controlled_target_ids: ['target-a', 'target-b'],
  });
  const spec = {
    version: 1,
    paths: {
      catalog,
      runs_directory: runs,
      peekaboo_executable: peekaboo,
      controller_executable: controller,
      monitor_executable: monitor,
      crash_directory: crashDirectory,
    },
    receipts: {
      bridge_status: bridge,
      controller_a: controllerA,
      controller_b: controllerB,
      observer,
      sentinel,
      observer_semantic: semantic,
      integrated_cu_emitter: calibrationReceipt(root, 'emitter-calibration.json', emitterExecutable, {
        pid: 203, start_identity: '203001', window_id: 303, bounds: bounds[2],
      }),
      monitor_codesign: codesign(root, 'monitor-codesign.txt', monitor, 'f'.repeat(40)),
    },
    timeouts: {
      external_foreground_timeout_seconds: 20,
      operation_timeout_seconds: 120,
      monitor_interval_milliseconds: 10,
    },
  };
  return { fixtureHome, spec, emitterExecutable };
}

test('closed raw receipts project deterministic live-v4 bindings and reject ambiguity', () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-tools-project-');
  fs.chmodSync(root, 0o700);
  const priorHome = process.env.HOME;
  try {
    const fix = projectionFixture(root);
    process.env.HOME = fix.fixtureHome;
    const input = writeJSON(path.join(root, 'input.json'), fix.spec);
    const output = path.join(root, 'bindings.json');
    const result = projectBindings(input, output);
    const bindings = JSON.parse(fs.readFileSync(output));
    assert.equal(result.bindings.monitor.foreground_controller.pid, 205);
    assert.equal(bindings.monitor.code_signature_hash, 'f'.repeat(40));
    assert.deepEqual(bindings.controllers.map((entry) => entry.controller_id), ['controller-a', 'controller-b']);
    assert.equal(bindings.controllers[0].target.click_point.x, 200);
    assert.equal(fs.statSync(output).mode & 0o777, 0o600);

    const calibrated = JSON.parse(fs.readFileSync(fix.spec.receipts.integrated_cu_emitter));
    calibrated.after.code_signature_hash = '9'.repeat(40);
    writeJSON(fix.spec.receipts.integrated_cu_emitter, calibrated);
    assert.throws(() => projectBindings(input, path.join(root, 'drifted-emitter.json')), /identity changed/);
    calibrated.after.code_signature_hash = calibrated.before.code_signature_hash;
    writeJSON(fix.spec.receipts.integrated_cu_emitter, calibrated);

    const ambiguous = JSON.parse(fs.readFileSync(fix.spec.receipts.controller_a.window_inventory));
    ambiguous.data.windows.push({ ...ambiguous.data.windows[0], window_id: 999 });
    writeJSON(fix.spec.receipts.controller_a.window_inventory, ambiguous);
    assert.throws(() => projectBindings(input, path.join(root, 'ambiguous.json')), /exactly one window/);
  } finally {
    if (priorHome === undefined) delete process.env.HOME;
    else process.env.HOME = priorHome;
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('native emitter calibrator compiles and its source-only self-test uses no event tap', () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-tools-calibrator-');
  fs.chmodSync(root, 0o700);
  try {
    const binary = path.join(root, 'integrated-cu-emitter-calibrator');
    const build = spawnSync('/usr/bin/xcrun', [
      'swiftc', path.join(toolRoot, 'integrated-cu-emitter-calibrator.swift'),
      '-o', binary,
      '-framework', 'AppKit', '-framework', 'CoreGraphics',
      '-framework', 'CryptoKit', '-framework', 'Security',
    ], { encoding: 'utf8' });
    assert.equal(build.status, 0, build.stderr);
    const selfTest = spawnSync(binary, ['--self-test'], { encoding: 'utf8' });
    assert.equal(selfTest.status, 0, selfTest.stderr);
    assert.deepEqual(JSON.parse(selfTest.stdout), { success: true, tests: 8 });
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('process-tree collector is read-only and its self-test does not inspect live processes', () => {
  const collector = path.join(toolRoot, 'process-tree-collector.mjs');
  const source = fs.readFileSync(collector, 'utf8');
  assert.doesNotMatch(source, /\b(?:killall|pkill)\b|\.kill\s*\(|SIG(?:TERM|KILL)/);
  const selfTest = spawnSync(process.execPath, [collector, '--self-test'], { encoding: 'utf8' });
  assert.equal(selfTest.status, 0, selfTest.stderr);
  assert.deepEqual(JSON.parse(selfTest.stdout), { version: 1, passed: true });
});

test('native atomic publisher uses renameatx no-replace semantics', () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-tools-atomic-');
  fs.chmodSync(root, 0o700);
  try {
    const helper = path.join(toolRoot, 'atomic-publish-no-replace.swift');
    const destination = path.join(root, 'marker.json');
    const firstSource = writeFile(path.join(root, '.first.tmp'), 'first\n');
    const first = spawnSync('/usr/bin/xcrun', ['swift', helper, firstSource, destination], { encoding: 'utf8' });
    assert.equal(first.status, 0, first.stderr);
    assert.equal(fs.readFileSync(destination, 'utf8'), 'first\n');
    assert.equal(fs.existsSync(firstSource), false);

    const secondSource = writeFile(path.join(root, '.second.tmp'), 'second\n');
    const second = spawnSync('/usr/bin/xcrun', ['swift', helper, secondSource, destination], { encoding: 'utf8' });
    assert.notEqual(second.status, 0);
    assert.match(second.stderr, /destination already exists/);
    assert.equal(fs.readFileSync(destination, 'utf8'), 'first\n');
    assert.equal(fs.existsSync(secondSource), true);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

function managedLaunchSpec(root, kind, planPath, executablePath, arguments_, context, prefix) {
  return {
    version: 1,
    kind,
    plan_path: planPath,
    executable: executablePath,
    arguments: arguments_,
    identity_handshake_path: path.join(root, `${prefix}-identity.json`),
    pid_path: path.join(root, `${prefix}-pid.json`),
    start_ack_path: path.join(root, `${prefix}-start.json`),
    invocation_receipt_path: path.join(root, `${prefix}-invocation.json`),
    exit_receipt_path: path.join(root, `${prefix}-exit.json`),
    stdout_path: path.join(root, `${prefix}.stdout`),
    stderr_path: path.join(root, `${prefix}.stderr`),
    start_timeout_seconds: 10,
    run_timeout_seconds: 10,
    context,
  };
}

test('managed launcher suspends Agent/coordinator until signed-monitor identity and records actual exits', async () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-tools-launcher-');
  fs.chmodSync(root, 0o700);
  const priorCWD = process.cwd();
  try {
    process.chdir(root);
    const childMarker = path.join(root, 'agent-child-ran');
    writeFile(path.join(root, 'process-identity'), [
      'use strict;',
      `die "child ran before handshake" if -e "${childMarker}";`,
      'select(undef, undef, undef, 0.10);',
      'my ($pid, $output);',
      'for (my $i = 0; $i < @ARGV; $i++) {',
      '  $pid = $ARGV[$i + 1] if $ARGV[$i] eq "--pid";',
      '  $output = $ARGV[$i + 1] if $ARGV[$i] eq "--output";',
      '}',
      'die "missing" unless $pid && $output;',
      'open(my $fh, ">", $output) or die $!;',
      'chmod 0600, $output;',
      'print $fh "{\\n  \\"pid\\": $pid,\\n  \\"startIdentity\\": \\"123456789\\"\\n}\\n";',
      'close($fh);',
      '',
    ].join('\n'), 0o400);
    const monitor = '/usr/bin/perl';
    const agentExecutable = writeFile(path.join(root, 'agent-fixture'), [
      '#!/usr/bin/perl',
      'use strict;',
      `open(my $fh, ">", "${childMarker}") or die $!;`,
      'print $fh "ran\\n";',
      'close($fh);',
      '',
    ].join('\n'), 0o500);
    const bridgeSocket = path.join(root, 'bridge.sock');
    const planPath = writeJSON(path.join(root, 'plan.json'), {
      version: 1,
      peekaboo_executable: agentExecutable,
      monitor_executable: monitor,
      bridge: { socket_path: bridgeSocket },
      monitor: { code_signature_hash: codeSignatureHash(monitor) },
    });
    const taskText = 'Use only exact background targets.';
    const taskPath = writeFile(path.join(root, 'task.txt'), `${taskText}\n`, 0o400);
    const receipts = privateDirectory(root, 'receipts');
    const agentSpec = managedLaunchSpec(
      root,
      'agent',
      planPath,
      agentExecutable,
      ['agent', 'run', taskText, '--no-cache', '--max-steps', '40', '--bridge-socket', bridgeSocket, '--json'],
      { task_path: taskPath, receipt_directory: receipts, bridge_socket: bridgeSocket },
      'agent',
    );
    const agentSpecPath = writeJSON(path.join(root, 'agent-spec.json'), agentSpec);
    const agentRun = await runManagedLaunch(agentSpecPath);
    assert.equal(agentRun.exit_code, 0);
    assert.equal(agentRun.signal, null);
    const agentInvocation = JSON.parse(fs.readFileSync(agentSpec.invocation_receipt_path));
    const agentExit = JSON.parse(fs.readFileSync(agentSpec.exit_receipt_path));
    assert.equal(agentInvocation.kind, 'agent');
    assert.equal(agentInvocation.background_only, true);
    assert.equal(agentInvocation.allow_foreground, false);
    assert.equal(agentInvocation.pid, agentExit.pid);
    assert.equal(agentInvocation.start_identity, agentExit.start_identity);
    assert.equal(fs.readFileSync(childMarker, 'utf8'), 'ran\n');
    assert.equal(fs.statSync(agentSpec.invocation_receipt_path).mode & 0o777, 0o600);
    assert.equal(fs.statSync(agentSpec.exit_receipt_path).mode & 0o777, 0o600);
    fs.unlinkSync(childMarker);

    const audioReceipts = privateDirectory(root, 'audio-receipts');
    const audioSpec = managedLaunchSpec(
      root,
      'agent',
      planPath,
      agentExecutable,
      [
        'agent', 'run', taskText, '--no-cache', '--max-steps', '40',
        '--bridge-socket', bridgeSocket, '--json', '--audio',
      ],
      { task_path: taskPath, receipt_directory: audioReceipts, bridge_socket: bridgeSocket },
      'audio',
    );
    await assert.rejects(
      runManagedLaunch(writeJSON(path.join(root, 'audio-spec.json'), audioSpec)),
      /exactly equal the closed background-only launch order/,
    );
    assert.equal(fs.existsSync(audioSpec.pid_path), false);

    const coordinatorSource = writeFile(path.join(root, 'coordinator.mjs'), 'process.stdout.write("coordinator fixture\\n");\n', 0o400);
    const coordinatorSpec = managedLaunchSpec(
      root,
      'coordinator',
      planPath,
      process.execPath,
      [coordinatorSource, '--plan', planPath],
      { coordinator_source_path: coordinatorSource },
      'coordinator',
    );
    const coordinatorSpecPath = writeJSON(path.join(root, 'coordinator-spec.json'), coordinatorSpec);
    const coordinatorRun = await runManagedLaunch(coordinatorSpecPath);
    assert.equal(coordinatorRun.exit_code, 0);
    assert.match(fs.readFileSync(coordinatorSpec.stdout_path, 'utf8'), /coordinator fixture/);
    assert.equal(JSON.parse(fs.readFileSync(coordinatorSpec.invocation_receipt_path)).kind, 'coordinator');

    const signalSource = writeFile(
      path.join(root, 'signal-coordinator.mjs'),
      'process.kill(process.pid, "SIGTERM");\n',
      0o400,
    );
    const signalSpec = managedLaunchSpec(
      root,
      'coordinator',
      planPath,
      process.execPath,
      [signalSource, '--plan', planPath],
      { coordinator_source_path: signalSource },
      'signal',
    );
    const signalRun = await runManagedLaunch(
      writeJSON(path.join(root, 'signal-spec.json'), signalSpec),
    );
    assert.equal(signalRun.exit_code, null);
    assert.equal(signalRun.signal, 15);
    const signalExit = JSON.parse(fs.readFileSync(signalSpec.exit_receipt_path));
    assert.equal(signalExit.exit_code, null);
    assert.equal(signalExit.signal, 15);

    const noHandshakePlan = writeJSON(path.join(root, 'no-handshake-plan.json'), {
      version: 1,
      peekaboo_executable: agentExecutable,
      monitor_executable: '/usr/bin/true',
      bridge: { socket_path: bridgeSocket },
      monitor: { code_signature_hash: codeSignatureHash('/usr/bin/true') },
    });
    const failedReceipts = privateDirectory(root, 'failed-receipts');
    const failedSpec = managedLaunchSpec(
      root,
      'agent',
      noHandshakePlan,
      agentExecutable,
      ['agent', 'run', taskText, '--no-cache', '--max-steps', '40', '--bridge-socket', bridgeSocket, '--json'],
      { task_path: taskPath, receipt_directory: failedReceipts, bridge_socket: bridgeSocket },
      'failed',
    );
    await assert.rejects(
      runManagedLaunch(writeJSON(path.join(root, 'failed-spec.json'), failedSpec)),
      /identity\.json|ENOENT|handshake/,
    );
    assert.equal(fs.existsSync(failedSpec.invocation_receipt_path), false);
    assert.equal(fs.existsSync(failedSpec.exit_receipt_path), false);
    assert.equal(fs.existsSync(childMarker), false);
  } finally {
    process.chdir(priorCWD);
    fs.rmSync(root, { recursive: true, force: true });
  }
});

function target(pid, start, windowID, x = 0) {
  return {
    scope: 'window', pid, start_identity: start, window_id: windowID,
    bounds: { x, y: 0, width: 400, height: 300 }, is_minimized: false,
  };
}

function emitter() {
  return { pid: 205, start_identity: '205001', team_id: TEAM, code_signature_hash: 'e'.repeat(40) };
}

test('marker publication is run-bound, readback-gated, atomic, and no-overwrite', () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-tools-marker-');
  fs.chmodSync(root, 0o700);
  try {
    const now = Date.now();
    const windowPath = path.join(root, 'external-foreground-window.json');
    const output = path.join(root, 'external-foreground-task-complete.json');
    const marker = 'perform-marker';
    writeJSON(windowPath, {
      version: 1, execution_nonce: NONCE, monitor_instance_id: UUID, phase: 'perform',
      request_marker: marker, target: target(203, '203001', 303),
      task_complete_path: output, deadline_milliseconds: now + 60_000,
    });
    const readback = writeJSON(path.join(root, 'perform-readback.json'), {
      version: 1, execution_nonce: NONCE, monitor_instance_id: UUID, phase: 'perform',
      window_path: windowPath, emitter: emitter(), target: target(203, '203001', 303),
      observed_at_milliseconds: now, passed: true,
      expected_value_sha256: sha256(Buffer.from(marker)),
      observed_value_sha256: sha256(Buffer.from(marker)),
    });
    const published = publishCoordinatorMarker(windowPath, readback);
    assert.equal(published.marker.phase, 'task-complete');
    assert.equal(JSON.parse(fs.readFileSync(output)).execution_nonce, NONCE);
    assert.throws(() => publishCoordinatorMarker(windowPath, readback), /already exists/);

    const restoreOutput = path.join(root, 'external-foreground-restore-complete.json');
    const baseline = 'restore-baseline';
    const sentinel = target(204, '204001', 304, 500);
    writeJSON(windowPath, {
      version: 1, execution_nonce: NONCE, monitor_instance_id: UUID, phase: 'restore',
      baseline_value: baseline, target: target(203, '203001', 303), sentinel,
      restore_complete_path: restoreOutput, deadline_milliseconds: now + 60_000,
    });
    const restoreReadback = writeJSON(path.join(root, 'restore-readback.json'), {
      version: 1, execution_nonce: NONCE, monitor_instance_id: UUID, phase: 'restore',
      window_path: windowPath, emitter: emitter(), target: target(203, '203001', 303),
      observed_at_milliseconds: now, passed: true,
      baseline_value_sha256: sha256(Buffer.from(baseline)),
      observed_value_sha256: sha256(Buffer.from(baseline)),
      sentinel,
      observed_sentinel: { pid: sentinel.pid, start_identity: sentinel.start_identity, window_id: sentinel.window_id },
    });
    const restored = publishCoordinatorMarker(windowPath, restoreReadback);
    assert.equal(restored.marker.phase, 'restore-complete');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

function actionOutcome() {
  return {
    state: 'confirmed_change', effect: 'confirmed', route: 'bridge',
    delivery_mechanism: 'accessibility_value', delivery_mode: 'background',
    evidence: 'verified_change', dispatch_state: 'dispatched', dispatched_unit_count: 1,
    retry_safety: 'not_applicable', escalation: 'none', mutation_dispatched: true,
    retry_safe: false, requires_fresh_observation: false,
  };
}

function heldPointerClientID(executionNonce) {
  const digest = Buffer.from(sha256(Buffer.concat([
    Buffer.from('peekaboo.held-pointer-certification.client.v1\0', 'utf8'),
    Buffer.from(executionNonce, 'utf8'),
  ])), 'hex').subarray(0, 16);
  digest[6] = (digest[6] & 0x0f) | 0x80;
  digest[8] = (digest[8] & 0x3f) | 0x80;
  const hex = digest.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function traceEntry(id, name, pid, windowID) {
  return {
    id, name, arguments: { pid, window_id: windowID, foreground: false },
    result: { success: true, mutation_dispatched: true, mutation_dispatch: 'dispatched' },
    isError: false, disposition: 'executed/succeeded', mutationDispatch: 'dispatched',
    actionOutcome: actionOutcome(),
  };
}

let fixtureRequestCounter = 1;
function signedBundleFixture(root, name, operation, targetValue, startedAt, completedAt, {
  mutating = true,
  sourceCommit = SOURCE,
  directory = root,
  client = { pid: 901, start_identity: '901001', code_signature_hash: 'a'.repeat(40) },
  host = { pid: 200, start_identity: '200001', code_signature_hash: 'd'.repeat(40) },
  listenerInstanceID = UUID,
  clientInstanceID = UUID,
  sessionSequence = '0',
  targetAbsent = false,
  outcome = null,
  outcomeAttested = mutating,
} = {}) {
  const requestID = `00000000-0000-4000-8000-${String(fixtureRequestCounter++).padStart(12, '0')}`;
  const payload = {
    schemaVersion: 1,
    requestID,
    operation,
    listenerInstanceID,
    clientInstanceID,
    sessionSequence,
    client: {
      processIdentifier: client.pid,
      processStartIdentity: client.start_identity,
      codeSignatureHash: client.code_signature_hash,
    },
    startedAtUnixMilliseconds: startedAt,
    completedAtUnixMilliseconds: completedAt,
    target: targetAbsent ? null : {
      kind: 'window',
      processIdentifier: targetValue.pid,
      processStartIdentity: targetValue.start_identity,
      windowID: targetValue.window_id,
      capturedBounds: [[0, 0], [400, 300]],
      isMinimized: false,
    },
    outcome: outcome ?? (mutating ? actionOutcome() : {
      state: 'confirmed_no_change', effect: 'confirmed', route: 'bridge',
      evidence: 'verified_no_change', dispatch_state: 'none', retry_safety: 'not_applicable',
      escalation: 'none', mutation_dispatched: false, retry_safe: false,
      requires_fresh_observation: false,
    }),
  };
  const bundle = writeJSON(path.join(directory, `${name}-bundle.json`), { receipt: { payload } });
  const validator = writeJSON(path.join(root, `${name}-validator.json`), {
    success: true,
    data: {
      valid: true,
      validator_id: 'peekaboo-bridge-receipt-validate-v1',
      trust_source: 'authenticated_live_listener',
      minimum_protocol_version: '1.29',
      request_id: requestID,
      operation,
      listener_instance_id: listenerInstanceID,
      client_instance_id: clientInstanceID,
      session_sequence: sessionSequence,
      host: {
        pid: host.pid,
        start_identity: host.start_identity,
        code_signature_hash: host.code_signature_hash,
      },
      client: {
        pid: client.pid,
        start_identity: client.start_identity,
        code_signature_hash: client.code_signature_hash,
      },
      host_source_commit: sourceCommit,
      host_protocol_version: '1.30',
      bundle_sha256: sha256(fs.readFileSync(bundle)),
      terminal_receipt_attested: true,
      target_attested: !targetAbsent,
      outcome_attested: outcomeAttested,
      retention_basis: 'exported_bundle',
    },
  });
  return { bundle, validator, payload };
}

function semanticReadbackFixture(root, name, targetValue, phase, value, observedAt) {
  const filePath = writeJSON(path.join(root, `${name}-readback.json`), {
    version: 1,
    target: targetValue,
    phase,
    value,
    observed_at_milliseconds: observedAt,
    passed: true,
  });
  fs.utimesSync(filePath, new Date(observedAt), new Date(observedAt));
  return filePath;
}

function concurrentFixture(root, { aliasAgentTarget = false } = {}) {
  const runRoot = privateDirectory(root, 'run');
  const monitorDirectory = privateDirectory(runRoot, 'monitor');
  const agentExecutable = '/usr/bin/true';
  const bridgeSocket = path.join(root, 'bridge.sock');
  const now = Date.now();
  const operationsStart = now - 3000;
  const operationsComplete = now - 2000;
  const foregroundTarget = target(203, '203001', 303);
  const sentinel = target(204, '204001', 304, 500);
  const plan = writeJSON(path.join(root, 'plan.json'), {
    version: 1,
    peekaboo_executable: agentExecutable,
    monitor_executable: '/usr/bin/true',
    bridge: {
      socket_path: bridgeSocket,
      expected_host: {
        process_identifier: 200,
        process_start_identity_decimal: '200001',
        code_signature_hash: 'd'.repeat(40),
        source_commit: SOURCE,
      },
    },
    controllers: [
      {
        controller_id: 'controller-a',
        target_id: 'target-a',
        target: aliasAgentTarget
          ? { process_identifier: 301, process_start_identity_decimal: '301001', window_id: 301 }
          : { process_identifier: 201, process_start_identity_decimal: '201001', window_id: 301 },
      },
      {
        controller_id: 'controller-b',
        target_id: 'target-b',
        target: { process_identifier: 202, process_start_identity_decimal: '202001', window_id: 302 },
      },
    ],
    observer: { target: foregroundTarget },
    monitor: {
      code_signature_hash: 'f'.repeat(40),
      foreground_target: foregroundTarget,
      sentinel,
      foreground_controller: { pid: 205, start_identity: '205001', code_signature_hash: 'e'.repeat(40) },
      foreground_controller_team_id: TEAM,
    },
  });
  const marker = `peekaboo-foreground-postcondition:${NONCE}`;
  const baselineDigest = '1'.repeat(64);
  const monitorEvidence = writeJSON(path.join(monitorDirectory, 'monitor-evidence.json'), {
    version: 1, execution_nonce: NONCE, monitor_instance_id: UUID,
    fences: [
      { name: 'operations-start', heartbeat: { wallClockMilliseconds: operationsStart } },
      { name: 'operations-complete', heartbeat: { wallClockMilliseconds: operationsComplete } },
    ],
    foreground_plan: {
      request_marker: marker,
      expected_value_sha256: sha256(Buffer.from(marker)),
      baseline_value_sha256: baselineDigest,
    },
  });
  const summary = writeJSON(path.join(runRoot, 'certification-summary.json'), { passed: true });
  const windowPath = path.join(runRoot, 'external-foreground-window.json');
  const events = [
    { event: 'run-created', version: 1, execution_nonce: NONCE, monitor_instance_id: UUID, run_root: runRoot },
    { event: 'external-foreground-window', version: 1, execution_nonce: NONCE, monitor_instance_id: UUID, phase: 'perform', window_path: windowPath, deadline_milliseconds: now + 30_000 },
    { event: 'external-foreground-window', version: 1, execution_nonce: NONCE, monitor_instance_id: UUID, phase: 'restore', window_path: windowPath, deadline_milliseconds: now + 60_000 },
    { event: 'completed', version: 1, execution_nonce: NONCE, monitor_instance_id: UUID, run_root: runRoot, summary_path: summary, certification_eligible: true },
  ];
  const eventPath = writeFile(path.join(root, 'events.jsonl'), `${events.map(JSON.stringify).join('\n')}\n`);
  const coordinatorExit = writeJSON(path.join(root, 'coordinator-exit.json'), {
    version: 1, process: 'coordinator', pid: 900, start_identity: '900001',
    started_at_milliseconds: now - 5000, completed_at_milliseconds: now + 5000,
    exit_code: 0, signal: null,
  });
  const coordinatorSource = writeFile(
    path.join(root, 'run-live-multi-target-certification.mjs'),
    '// retained coordinator fixture\n',
    0o400,
  );
  const coordinatorHandshake = writeJSON(path.join(root, 'coordinator-handshake.json'), {
    pid: 900, startIdentity: '900001',
  });
  const coordinatorStderr = writeFile(path.join(root, 'coordinator.stderr'), '');
  const coordinatorInvocation = writeJSON(path.join(root, 'coordinator-invocation.json'), {
    version: 1,
    kind: 'coordinator',
    pid: 900,
    start_identity: '900001',
    executable_path: process.execPath,
    executable_sha256: sha256(fs.readFileSync(process.execPath)),
    arguments: [coordinatorSource, '--plan', plan],
    plan_path: plan,
    plan_sha256: sha256(fs.readFileSync(plan)),
    monitor_executable_path: '/usr/bin/true',
    monitor_executable_sha256: sha256(fs.readFileSync('/usr/bin/true')),
    monitor_code_signature_hash: 'f'.repeat(40),
    identity_handshake_path: coordinatorHandshake,
    identity_handshake_sha256: sha256(fs.readFileSync(coordinatorHandshake)),
    stdout_path: eventPath,
    stderr_path: coordinatorStderr,
    captured_at_milliseconds: now - 4500,
    coordinator_source_path: coordinatorSource,
    coordinator_source_sha256: sha256(fs.readFileSync(coordinatorSource)),
  });
  const agentExit = writeJSON(path.join(root, 'agent-exit.json'), {
    version: 1, process: 'agent', pid: 901, start_identity: '901001',
    started_at_milliseconds: now - 4000, completed_at_milliseconds: now + 1000,
    exit_code: 0, signal: null,
  });
  const taskText = 'Operate only through Peekaboo background tools on two exact controlled windows.';
  const taskPath = writeFile(path.join(root, 'agent-task.txt'), `${taskText}\n`, 0o400);
  const agentReceipts = privateDirectory(root, 'agent-receipts');
  const invocationHandshake = writeJSON(path.join(root, 'agent-invocation-handshake.json'), {
    pid: 901, startIdentity: '901001',
  });
  const invocationStdout = writeFile(path.join(root, 'agent-invocation.stdout'), '');
  const invocationStderr = writeFile(path.join(root, 'agent-invocation.stderr'), '');
  const agentInvocation = writeJSON(path.join(root, 'agent-invocation.json'), {
    version: 1,
    kind: 'agent',
    pid: 901,
    start_identity: '901001',
    executable_path: agentExecutable,
    executable_sha256: sha256(fs.readFileSync(agentExecutable)),
    arguments: [
      'agent', 'run', taskText, '--no-cache', '--max-steps', '40',
      '--bridge-socket', bridgeSocket, '--json',
    ],
    plan_path: plan,
    plan_sha256: sha256(fs.readFileSync(plan)),
    monitor_executable_path: '/usr/bin/true',
    monitor_executable_sha256: sha256(fs.readFileSync('/usr/bin/true')),
    monitor_code_signature_hash: 'f'.repeat(40),
    identity_handshake_path: invocationHandshake,
    identity_handshake_sha256: sha256(fs.readFileSync(invocationHandshake)),
    stdout_path: invocationStdout,
    stderr_path: invocationStderr,
    task_path: taskPath,
    task_sha256: sha256(fs.readFileSync(taskPath)),
    receipt_directory: agentReceipts,
    bridge_socket: bridgeSocket,
    background_only: true,
    allow_foreground: false,
    shell_available: false,
    captured_at_milliseconds: now - 3500,
  });
  const agentIdentity = {
    launch: invocationHandshake,
    perform: processReceipt(root, 'agent-perform', 901, '901001'),
    restore: processReceipt(root, 'agent-restore', 901, '901001'),
  };
  fs.utimesSync(agentIdentity.launch, new Date(now - 3900), new Date(now - 3900));
  fs.utimesSync(agentIdentity.perform, new Date(operationsStart + 10), new Date(operationsStart + 10));
  fs.utimesSync(agentIdentity.restore, new Date(operationsComplete + 100), new Date(operationsComplete + 100));
  const entries = [
    traceEntry('a-mutate', 'set_value', 301, 401),
    traceEntry('a-restore', 'set_value', 301, 401),
    traceEntry('b-mutate', 'paste', 302, 402),
    traceEntry('b-restore', 'type', 302, 402),
  ];
  const agentResult = writeJSON(path.join(root, 'agent-result.json'), {
    success: true,
    result: {
      content: 'complete',
      executionTrace: { entries, totalCallCount: entries.length, truncated: false },
    },
  });
  const targetA = { pid: 301, start_identity: '301001', window_id: 401 };
  const targetB = { pid: 302, start_identity: '302001', window_id: 402 };
  const agentClient = {
    pid: 901,
    start_identity: '901001',
    code_signature_hash: codeSignatureHash(agentExecutable),
  };
  const baselineA = semanticReadbackFixture(root, 'a-baseline', targetA, 'baseline', 'alpha', operationsStart + 50);
  const mutationA = semanticReadbackFixture(root, 'a-mutate', targetA, 'mutated', 'alpha!', operationsStart + 250);
  const restorationA = semanticReadbackFixture(root, 'a-restore', targetA, 'restored', 'alpha', operationsStart + 450);
  const baselineB = semanticReadbackFixture(root, 'b-baseline', targetB, 'baseline', 'beta', operationsStart + 500);
  const mutationB = semanticReadbackFixture(root, 'b-mutate', targetB, 'mutated', 'beta!', operationsStart + 700);
  const restorationB = semanticReadbackFixture(root, 'b-restore', targetB, 'restored', 'beta', operationsStart + 900);
  const bundleA = signedBundleFixture(
    root, 'a-mutate', 'setValue', targetA, operationsStart + 100, operationsStart + 200,
    { directory: agentReceipts, client: agentClient },
  );
  const bundleARestore = signedBundleFixture(
    root, 'a-restore', 'setValue', targetA, operationsStart + 300, operationsStart + 400,
    { directory: agentReceipts, client: agentClient },
  );
  const bundleB = signedBundleFixture(
    root, 'b-mutate', 'exactWindowTargetedTypeActions', targetB,
    operationsStart + 550, operationsStart + 650,
    { directory: agentReceipts, client: agentClient },
  );
  const bundleBRestore = signedBundleFixture(
    root, 'b-restore', 'exactWindowTargetedTypeActions', targetB,
    operationsStart + 750, operationsStart + 850,
    { directory: agentReceipts, client: agentClient },
  );
  const action = (id, family, readbackPath, bundle) => ({
    trace_call_id: id,
    family,
    readback_path: readbackPath,
    bundle_path: bundle.bundle,
    validator_report_path: bundle.validator,
  });
  const agentReadbacks = writeJSON(path.join(root, 'agent-readbacks.json'), {
    version: 1, agent: { pid: 901, start_identity: '901001' },
    targets: [
      {
        label: 'target-a', target: targetA,
        baseline_readback_path: baselineA,
        mutation: action('a-mutate', 'set_value', mutationA, bundleA),
        restoration: action('a-restore', 'set_value', restorationA, bundleARestore),
      },
      {
        label: 'target-b', target: targetB,
        baseline_readback_path: baselineB,
        mutation: action('b-mutate', 'paste', mutationB, bundleB),
        restoration: action('b-restore', 'type', restorationB, bundleBRestore),
      },
    ],
  });
  const agentBundles = [bundleA, bundleARestore, bundleB, bundleBRestore].map((entry) => ({
    bundle_path: entry.bundle,
    validator_report_path: entry.validator,
  }));
  const emitterExecutable = executable(root, 'emitter-bin');
  const emitterSpec = calibrationReceipt(
    root,
    'cu-emitter-calibration.json',
    emitterExecutable,
    foregroundTarget,
  );
  const readbackCommon = {
    version: 1, execution_nonce: NONCE, monitor_instance_id: UUID,
    window_path: windowPath, emitter: emitter(), target: foregroundTarget, passed: true,
  };
  const performReadback = writeJSON(path.join(root, 'cu-perform.json'), {
    ...readbackCommon, phase: 'perform', observed_at_milliseconds: now - 2500,
    expected_value_sha256: sha256(Buffer.from(marker)),
    observed_value_sha256: sha256(Buffer.from(marker)),
  });
  const restoreReadback = writeJSON(path.join(root, 'cu-restore.json'), {
    ...readbackCommon, phase: 'restore', observed_at_milliseconds: now - 1500,
    baseline_value_sha256: baselineDigest, observed_value_sha256: baselineDigest,
    sentinel,
    observed_sentinel: { pid: sentinel.pid, start_identity: sentinel.start_identity, window_id: sentinel.window_id },
  });
  const spec = {
    version: 1, plan, coordinator_invocation: coordinatorInvocation,
    coordinator_events: eventPath, coordinator_exit: coordinatorExit,
    agent_result: agentResult, agent_exit: agentExit, agent_invocation: agentInvocation,
    agent_identity: agentIdentity,
    agent_bundles: agentBundles,
    agent_readbacks: agentReadbacks,
    integrated_cu: { emitter: emitterSpec, perform_readback: performReadback, restore_readback: restoreReadback },
  };
  return {
    spec,
    agentResult,
    monitorEvidence,
    semanticReadbacks: [baselineA, mutationA, restorationA, baselineB, mutationB, restorationB],
    agentBundles,
  };
}

test('post-run validator requires zero exits, exact Agent generation, background trace, restoration, and overlap', () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-tools-validate-');
  fs.chmodSync(root, 0o700);
  try {
    const fix = concurrentFixture(root);
    const specPath = writeJSON(path.join(root, 'validation-input.json'), fix.spec);
    const output = path.join(root, 'validation-report.json');
    const result = validateConcurrentRun(specPath, output);
    assert.equal(result.report.passed, true);
    assert.deepEqual(result.report.agent.mutation_families, ['paste', 'set_value']);
    assert.equal(result.report.overlap.agent_covers_operation_interval, true);

    const originalResult = fs.readFileSync(fix.agentResult);
    const bad = JSON.parse(originalResult);
    bad.result.executionTrace.entries[0].actionOutcome.delivery_mode = 'foreground';
    writeJSON(fix.agentResult, bad);
    assert.throws(() => validateConcurrentRun(specPath, path.join(root, 'bad-report.json')), /foreground delivery/);
    writeFile(fix.agentResult, originalResult);

    const extra = JSON.parse(originalResult);
    extra.result.executionTrace.entries.push(traceEntry('extra-mutation', 'click', 303, 403));
    extra.result.executionTrace.totalCallCount += 1;
    writeJSON(fix.agentResult, extra);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'extra-report.json')),
      /exactly the four mapped dispatched mutation call IDs/,
    );
    writeFile(fix.agentResult, originalResult);

    const lateReadback = JSON.parse(fs.readFileSync(fix.semanticReadbacks[1]));
    lateReadback.observed_at_milliseconds = result.report.overlap.operations_started_at_milliseconds - 1;
    writeJSON(fix.semanticReadbacks[1], lateReadback);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'late-report.json')),
      /outside the authoritative operation interval/,
    );
    lateReadback.observed_at_milliseconds = result.report.overlap.operations_started_at_milliseconds + 250;
    writeJSON(fix.semanticReadbacks[1], lateReadback);
    fs.utimesSync(
      fix.semanticReadbacks[1],
      new Date(lateReadback.observed_at_milliseconds),
      new Date(lateReadback.observed_at_milliseconds),
    );

    const foreignBundlePath = fix.agentBundles[0].bundle_path;
    const foreignValidatorPath = fix.agentBundles[0].validator_report_path;
    const originalBundle = fs.readFileSync(foreignBundlePath);
    const originalValidator = fs.readFileSync(foreignValidatorPath);
    const foreignBundle = JSON.parse(originalBundle);
    foreignBundle.receipt.payload.client.processIdentifier = 999;
    foreignBundle.receipt.payload.client.processStartIdentity = '999001';
    writeJSON(foreignBundlePath, foreignBundle);
    const foreignValidator = JSON.parse(originalValidator);
    foreignValidator.data.client.pid = 999;
    foreignValidator.data.client.start_identity = '999001';
    foreignValidator.data.bundle_sha256 = sha256(fs.readFileSync(foreignBundlePath));
    writeJSON(foreignValidatorPath, foreignValidator);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'foreign-client-report.json')),
      /emitted by another process generation/,
    );
    writeFile(foreignBundlePath, originalBundle);
    writeFile(foreignValidatorPath, originalValidator);

    const invalidValidator = JSON.parse(originalValidator);
    invalidValidator.data.valid = false;
    writeJSON(foreignValidatorPath, invalidValidator);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'invalid-validator-report.json')),
      /live validator report is not bound to the exact bundle/,
    );
    writeFile(foreignValidatorPath, originalValidator);

    const earlyBundle = JSON.parse(originalBundle);
    earlyBundle.receipt.payload.startedAtUnixMilliseconds
      = result.report.overlap.operations_started_at_milliseconds - 1;
    writeJSON(foreignBundlePath, earlyBundle);
    const earlyValidator = JSON.parse(originalValidator);
    earlyValidator.data.bundle_sha256 = sha256(fs.readFileSync(foreignBundlePath));
    writeJSON(foreignValidatorPath, earlyValidator);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'early-mutation-report.json')),
      /signed interval falls outside live-v4 operations/,
    );
    writeFile(foreignBundlePath, originalBundle);
    writeFile(foreignValidatorPath, originalValidator);

    const receiptDirectory = JSON.parse(fs.readFileSync(fix.spec.agent_invocation)).receipt_directory;
    writeJSON(path.join(receiptDirectory, 'unlisted.json'), { unexpected: true });
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'unlisted-report.json')),
      /does not equal the complete receipt-directory inventory/,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('post-run validator rejects Agent target reuse with live-v4 controlled processes', () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-tools-alias-');
  fs.chmodSync(root, 0o700);
  try {
    const fix = concurrentFixture(root, { aliasAgentTarget: true });
    const specPath = writeJSON(path.join(root, 'validation-input.json'), fix.spec);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'alias-report.json')),
      /aliases a controller\/observer\/foreground\/sentinel process/,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('qualification manifest closes every required evidence class and detects byte drift', () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-tools-manifest-');
  fs.chmodSync(root, 0o700);
  try {
    let index = 0;
    const evidence = () => writeJSON(path.join(root, `evidence-${index++}.json`), { index });
    const concurrent = concurrentFixture(root);
    const concurrentInput = writeJSON(path.join(root, 'concurrent-input.json'), concurrent.spec);
    const concurrentReport = path.join(root, 'concurrent-report.json');
    validateConcurrentRun(concurrentInput, concurrentReport);
    const matrix = Array.from({ length: 5 }, (_, cycle) => ({
      certificate: writeJSON(path.join(root, `matrix-${cycle + 1}.json`), {
        success: true,
        catalog_version: 2,
        expected_cases: 42,
        observed_cases: 42,
        failures: [],
      }),
      crash_inventory: writeJSON(path.join(root, `crash-${cycle + 1}.json`), {
        version: 1, passed: true, added: [], changed: [], removed: [],
      }),
    }));
    const adjunctTarget = { pid: 501, start_identity: '501001', window_id: 601 };
    const adjunctTime = Date.now();
    const middleBundle = signedBundleFixture(
      root, 'middle', 'exactWindowTargetedClick', adjunctTarget, adjunctTime, adjunctTime + 10,
    );
    const middleReadback = writeJSON(path.join(root, 'middle-readback.json'), {
      version: 1, kind: 'middle_click', target: adjunctTarget,
      before_sequence: 10, after_sequence: 12,
      events: [
        { sequence: 11, button: 'middle', phase: 'down', window_id: adjunctTarget.window_id },
        { sequence: 12, button: 'middle', phase: 'up', window_id: adjunctTarget.window_id },
      ],
      observed_at_milliseconds: adjunctTime + 20, passed: true,
    });
    const middleRestoration = writeJSON(path.join(root, 'middle-restoration.json'), {
      version: 1, kind: 'middle_click', target: adjunctTarget,
      baseline_value: 'stable', restored_value: 'stable',
      observed_at_milliseconds: adjunctTime + 30, passed: true,
    });
    const keyBundle = signedBundleFixture(
      root, 'held-key', 'exactWindowTargetedHotkey', adjunctTarget, adjunctTime + 40, adjunctTime + 50,
    );
    const keyReadback = writeJSON(path.join(root, 'held-key-readback.json'), {
      version: 1, kind: 'held_key', target: adjunctTarget, key: 'a', hold_milliseconds: 500,
      baseline_value: 'key', observed_value: 'keya',
      observed_at_milliseconds: adjunctTime + 60, passed: true,
    });
    const keyRestoration = writeJSON(path.join(root, 'held-key-restoration.json'), {
      version: 1, kind: 'held_key', target: adjunctTarget,
      baseline_value: 'key', restored_value: 'key',
      observed_at_milliseconds: adjunctTime + 70, passed: true,
    });
    const pointerOperations = [
      ['pointer-list-1', 'listWindows', false],
      ['pointer-list-2', 'listWindows', false],
      ['pointer-create', 'createExactWindowHeldPointerOwner', false],
      ['pointer-begin', 'beginExactWindowHeldPointer', true],
      ['pointer-release', 'releaseExactWindowHeldPointer', true],
      ['pointer-disconnect', 'disconnectExactWindowHeldPointerOwner', false],
    ];
    const pointerClient = { pid: 777, start_identity: '777001', code_signature_hash: '6'.repeat(40) };
    const pointerHost = { pid: 700, start_identity: '700001', code_signature_hash: '7'.repeat(40) };
    const pointerClientInstanceID = heldPointerClientID(NONCE);
    const pointerPairs = pointerOperations.map(([name, operation, mutating], entryIndex) => (
      signedBundleFixture(
        root,
        name,
        operation,
        adjunctTarget,
        adjunctTime + 100 + (entryIndex * 20),
        adjunctTime + 110 + (entryIndex * 20),
        {
          mutating,
          sourceCommit: SOURCE,
          client: pointerClient,
          host: pointerHost,
          clientInstanceID: pointerClientInstanceID,
          sessionSequence: String(entryIndex),
          targetAbsent: operation === 'disconnectExactWindowHeldPointerOwner',
          outcomeAttested: mutating || operation === 'disconnectExactWindowHeldPointerOwner',
          outcome: operation === 'beginExactWindowHeldPointer' ? {
            ...actionOutcome(), delivery_mechanism: 'window_targeted_events',
            evidence: 'delivery_accepted', state: 'dispatched_unverified',
            effect: 'unverifiable', retry_safety: 'unsafe', escalation: 'observe_before_retry',
            dispatched_unit_count: 2, requires_fresh_observation: true,
          } : operation === 'releaseExactWindowHeldPointer' ? {
            ...actionOutcome(), delivery_mechanism: 'window_targeted_events',
            evidence: 'delivery_accepted', state: 'dispatched_unverified',
            effect: 'unverifiable', retry_safety: 'unsafe', escalation: 'observe_before_retry',
            dispatched_unit_count: 1, requires_fresh_observation: true,
          } : null,
        },
      )
    ));
    const pointerReadback = writeJSON(path.join(root, 'pointer-readback.json'), {
      version: 1, kind: 'held_pointer', target: adjunctTarget,
      before_sequence: 20, after_sequence: 22,
      events: [
        { sequence: 21, button: 'left', phase: 'down', window_id: adjunctTarget.window_id },
        { sequence: 22, button: 'left', phase: 'up', window_id: adjunctTarget.window_id },
      ],
      observed_at_milliseconds: adjunctTime + 250, passed: true,
    });
    const pointerRestoration = writeJSON(path.join(root, 'pointer-restoration.json'), {
      version: 1, kind: 'held_pointer', target: adjunctTarget,
      baseline_value: 'pointer', restored_value: 'pointer',
      observed_at_milliseconds: adjunctTime + 260, passed: true,
    });
    const pointerControllerResult = writeJSON(path.join(root, 'pointer-controller-result.json'), {
      version: 1, result: 'passed', execution_nonce: NONCE,
      controller: pointerClient,
      build: {
        source_commit: SOURCE, executable_path: '/usr/bin/true',
        executable_sha256: sha256(fs.readFileSync('/usr/bin/true')), team_id: TEAM,
      },
      handshake: {
        socket_path: '/private/tmp/bridge.sock',
        negotiated_version: { major: 1, minor: 30 }, host_kind: 'gui', build: null,
        listener_instance_id: UUID,
        host: {
          process: pointerHost, bundle_identifier: null, bundle_short_version: null,
          bundle_version: null, source_commit: SOURCE,
        },
        session: {
          id: '019c0000-0000-4000-8000-000000000099',
          client_instance_id: pointerClientInstanceID,
          maximum_request_count: 64, initial_remaining_claim_count: 64,
        },
      },
      target: {
        scope: 'window', ...adjunctTarget,
        bounds: { x: 0, y: 0, width: 400, height: 300 }, is_minimized: false,
      },
      point: { x: 10, y: 20 }, button: 'left', hold_milliseconds: 500,
      interval: {
        started_at_milliseconds: adjunctTime + 90,
        completed_at_milliseconds: adjunctTime + 230,
      },
      begin_dispatched_units: 2, release_dispatched_units: 1,
      lifecycle_dispatched_units: 3, terminal_reason: 'released', cleanup_state: 'owner_disconnected',
      operations: pointerPairs.map((entry, index) => ({
        operation: pointerOperations[index][1],
        request_id: entry.payload.requestID,
        session_sequence: String(index), listener_instance_id: UUID,
        interval: {
          started_at_milliseconds: entry.payload.startedAtUnixMilliseconds,
          completed_at_milliseconds: entry.payload.completedAtUnixMilliseconds,
        },
        outcome: entry.payload.outcome,
        bundle: {
          file: `bundles/${entry.payload.requestID}.json`,
          sha256: sha256(fs.readFileSync(entry.bundle)),
          request_sha256: '1'.repeat(64), response_sha256: '2'.repeat(64),
        },
      })),
    });
    const pointerTargetBefore = writeJSON(path.join(root, 'pointer-target-before.json'), {
      pid: adjunctTarget.pid, startIdentity: adjunctTarget.start_identity,
    });
    const pointerTargetAfter = writeJSON(path.join(root, 'pointer-target-after.json'), {
      pid: adjunctTarget.pid, startIdentity: adjunctTarget.start_identity,
    });
    const pointerCrash = writeJSON(path.join(root, 'pointer-crash.json'), {
      version: 1, passed: true, added: [], changed: [], removed: [],
    });
    const artifactManifest = evidence();
    fs.chmodSync(artifactManifest, 0o400);
    const toolsManifest = path.join(root, 'qualification-tools-source.json');
    generateSourceManifest(toolRoot, [
      'README.md',
      'atomic-publish-no-replace.swift',
      'integrated-cu-emitter-calibrator.swift',
      'managed-launch-suspended.c',
      'lib.mjs',
      'managed-launcher.mjs',
      'project-live-bindings.mjs',
      'process-tree-collector.mjs',
      'publish-coordinator-marker.mjs',
      'qualification-manifest.mjs',
      'validate-concurrent-run.mjs',
      'test/qualification-tools.test.mjs',
    ], toolsManifest, SOURCE);
    fs.chmodSync(toolsManifest, 0o400);
    const coordinatorInvocation = JSON.parse(fs.readFileSync(concurrent.spec.coordinator_invocation));
    const liveEvents = fs.readFileSync(concurrent.spec.coordinator_events, 'utf8')
      .trim().split('\n').map(JSON.parse);
    const completion = liveEvents.at(-1);
    const agentInvocation = JSON.parse(fs.readFileSync(concurrent.spec.agent_invocation));
    const qualificationToolsAggregate = JSON.parse(fs.readFileSync(toolsManifest)).aggregate_sha256;
    const deployment = deploymentFixture(root, qualificationToolsAggregate);
    const inputValue = {
      version: 2,
      artifact_manifest: artifactManifest,
      deployment: {
        installed_inventories: deployment.installed,
        elevation_receipts: deployment.elevationReceipts,
        process_tree_collector: deployment.collector,
        process_trees: deployment.processTrees,
        executable_policy_scanner: deployment.policyScanner,
        executable_policy_reports: deployment.policyReports,
      },
      tooling: {
        qualification_tools_manifest: toolsManifest,
        plan_constructor: evidence(),
        crash_scanner: evidence(),
      },
      live_v4: {
        plan: concurrent.spec.plan,
        coordinator_identity_handshake: coordinatorInvocation.identity_handshake_path,
        coordinator_invocation: concurrent.spec.coordinator_invocation,
        coordinator_events: concurrent.spec.coordinator_events,
        coordinator_exit: concurrent.spec.coordinator_exit,
        certification_summary: completion.summary_path,
        monitor_evidence: concurrent.monitorEvidence,
      },
      matrix_cycles: matrix,
      agent_cu: {
        task: agentInvocation.task_path,
        agent_result: concurrent.spec.agent_result,
        agent_exit: concurrent.spec.agent_exit,
        agent_invocation: concurrent.spec.agent_invocation,
        agent_process_receipts: Object.values(concurrent.spec.agent_identity),
        agent_readbacks: concurrent.spec.agent_readbacks,
        signed_bundles: concurrent.agentBundles.map((entry) => entry.bundle_path),
        live_validator_reports: concurrent.agentBundles.map((entry) => entry.validator_report_path),
        semantic_readbacks: concurrent.semanticReadbacks,
        integrated_cu_emitter_receipt: concurrent.spec.integrated_cu.emitter,
        perform_readback: concurrent.spec.integrated_cu.perform_readback,
        restore_readback: concurrent.spec.integrated_cu.restore_readback,
        validation_report: concurrentReport,
      },
      adjuncts: {
        middle_click: {
          raw_bundles: [middleBundle.bundle], live_validator_reports: [middleBundle.validator],
          readbacks: [middleReadback], restorations: [middleRestoration],
        },
        held_key: {
          raw_bundles: [keyBundle.bundle], live_validator_reports: [keyBundle.validator],
          readbacks: [keyReadback], restorations: [keyRestoration],
        },
        held_pointer: {
          raw_bundles: pointerPairs.map((entry) => entry.bundle),
          live_validator_reports: pointerPairs.map((entry) => entry.validator),
          readbacks: [pointerReadback], restorations: [pointerRestoration],
          controller_results: [pointerControllerResult],
          target_process_receipts: [pointerTargetBefore, pointerTargetAfter],
          crash_inventories: [pointerCrash],
        },
      },
      restoration_cleanup: { restoration_evidence: [evidence()], cleanup_evidence: [evidence()] },
    };
    const legacyInput = structuredClone(inputValue);
    legacyInput.version = 1;
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'legacy-v1-input.json'), legacyInput),
        path.join(root, 'legacy-v1-manifest.json'),
      ),
      /input version is not 2/,
    );
    const localInventory = JSON.parse(fs.readFileSync(deployment.installed[0]));
    const installedDrifts = [
      ['size', (entries) => { entries[0].size += 1; }],
      ['path', (entries) => { entries[0].relative_path = 'OpenClaw2.app/Contents/MacOS/OpenClaw'; }],
      ['mode', (entries) => { entries[0].mode = 0o700; }],
      ['hash', (entries) => { entries[0].sha256 = '0'.repeat(64); }],
      ['symlink', (entries) => { entries.at(-1).target = '../other/peekaboo'; }],
    ];
    for (const [driftName, mutate] of installedDrifts) {
      const mismatchedEntries = structuredClone(localInventory.entries);
      mutate(mismatchedEntries);
      const mismatchedStudio = installedInventory(
        root,
        'studio',
        deployment.studioUUID,
        mismatchedEntries,
        qualificationToolsAggregate,
        sha256(fs.readFileSync(deployment.elevationReceipts[1])),
        `-${driftName}-mismatch`,
      );
      const mismatchedInstallInput = structuredClone(inputValue);
      mismatchedInstallInput.deployment.installed_inventories[1] = mismatchedStudio;
      assert.throws(
        () => generateManifest(
          writeJSON(path.join(root, `${driftName}-installed-input.json`), mismatchedInstallInput),
          path.join(root, `${driftName}-installed-manifest.json`),
        ),
        /local and Studio installed inventories differ/,
      );
    }
    for (const [index, forbiddenName] of [
      'cua-driver', 'osascript', 'AppleScript', 'jxa', 'osa', 'lume',
      'vmware-vmx', 'VirtualBoxVM', 'UTM', 'tart', 'vfkit', 'qemu',
      'vncserver', 'Screen Sharing', 'Remote Desktop',
    ].entries()) {
      const forbiddenInput = structuredClone(inputValue);
      forbiddenInput.deployment.process_trees[1] = taskProcessTree(
        root,
        'local',
        deployment.localUUID,
        'during',
        { forbiddenName, collectorSHA256: deployment.collectorSHA256 },
      );
      assert.throws(
        () => generateManifest(
          writeJSON(path.join(root, `forbidden-${index}-input.json`), forbiddenInput),
          path.join(root, `forbidden-${index}-manifest.json`),
        ),
        /contains forbidden task-owned process/,
      );
    }
    const forbiddenRootInput = structuredClone(inputValue);
    forbiddenRootInput.deployment.process_trees[1] = taskProcessTree(
      root,
      'local',
      deployment.localUUID,
      'during',
      {
        forbiddenName: 'cua-driver',
        forbiddenRoot: true,
        collectorSHA256: deployment.collectorSHA256,
      },
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'forbidden-root-input.json'), forbiddenRootInput),
        path.join(root, 'forbidden-root-manifest.json'),
      ),
      /contains forbidden task-owned process/,
    );
    const orphanInput = structuredClone(inputValue);
    orphanInput.deployment.process_trees[1] = taskProcessTree(
      root,
      'local',
      deployment.localUUID,
      'during',
      { orphan: true, collectorSHA256: deployment.collectorSHA256 },
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'orphan-process-input.json'), orphanInput),
        path.join(root, 'orphan-process-manifest.json'),
      ),
      /outside the task-owned descendant tree/,
    );
    const incompleteInput = structuredClone(inputValue);
    const incompleteTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
    incompleteTree.complete = false;
    incompleteInput.deployment.process_trees[1] = writeJSON(
      path.join(root, 'incomplete-process-tree.json'),
      incompleteTree,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'incomplete-process-input.json'), incompleteInput),
        path.join(root, 'incomplete-process-manifest.json'),
      ),
      /process_trees\[1\] is malformed/,
    );
    const missingRootInput = structuredClone(inputValue);
    const missingRootTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
    const fixtureRoot = missingRootTree.roots.find((entry) => entry.root_class === 'fixture');
    missingRootTree.roots = missingRootTree.roots.filter((entry) => entry.root_class !== 'fixture');
    missingRootTree.processes = missingRootTree.processes.filter((entry) => entry.pid !== fixtureRoot.pid);
    missingRootInput.deployment.process_trees[1] = writeJSON(
      path.join(root, 'missing-root-process-tree.json'),
      missingRootTree,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'missing-root-input.json'), missingRootInput),
        path.join(root, 'missing-root-manifest.json'),
      ),
      /root coverage is incomplete/,
    );
    const wrongCollectorInput = structuredClone(inputValue);
    const wrongCollectorTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
    wrongCollectorTree.collector_sha256 = '0'.repeat(64);
    wrongCollectorInput.deployment.process_trees[1] = writeJSON(
      path.join(root, 'wrong-collector-process-tree.json'),
      wrongCollectorTree,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'wrong-collector-input.json'), wrongCollectorInput),
        path.join(root, 'wrong-collector-manifest.json'),
      ),
      /collector differs from the bound source/,
    );
    const timestampInput = structuredClone(inputValue);
    const timestampTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
    timestampTree.captured_at_milliseconds = JSON.parse(
      fs.readFileSync(deployment.processTrees[0]),
    ).captured_at_milliseconds;
    timestampInput.deployment.process_trees[1] = writeJSON(
      path.join(root, 'unordered-process-tree.json'),
      timestampTree,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'unordered-process-input.json'), timestampInput),
        path.join(root, 'unordered-process-manifest.json'),
      ),
      /timestamps are not strictly ordered/,
    );
    const generationDriftInput = structuredClone(inputValue);
    const generationDriftTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
    const driftedRoot = generationDriftTree.roots.find((entry) => entry.root_class === 'bridge');
    const driftedProcess = generationDriftTree.processes.find((entry) => entry.pid === driftedRoot.pid);
    driftedRoot.start_identity = `${BigInt(driftedRoot.start_identity) + 1n}`;
    driftedProcess.start_identity = driftedRoot.start_identity;
    generationDriftInput.deployment.process_trees[1] = writeJSON(
      path.join(root, 'generation-drift-process-tree.json'),
      generationDriftTree,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'generation-drift-input.json'), generationDriftInput),
        path.join(root, 'generation-drift-manifest.json'),
      ),
      /root generation drifted across epochs/,
    );
    const duplicatePIDInput = structuredClone(inputValue);
    const duplicatePIDTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
    const duplicateProcess = structuredClone(duplicatePIDTree.processes.at(-1));
    duplicateProcess.start_identity = `${BigInt(duplicateProcess.start_identity) + 1n}`;
    duplicatePIDTree.processes.push(duplicateProcess);
    duplicatePIDInput.deployment.process_trees[1] = writeJSON(
      path.join(root, 'duplicate-pid-process-tree.json'),
      duplicatePIDTree,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'duplicate-pid-input.json'), duplicatePIDInput),
        path.join(root, 'duplicate-pid-manifest.json'),
      ),
      /PID reuse in one epoch/,
    );
    const wrongElevationInput = structuredClone(inputValue);
    wrongElevationInput.deployment.elevation_receipts[1] = evidence();
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'wrong-elevation-input.json'), wrongElevationInput),
        path.join(root, 'wrong-elevation-manifest.json'),
      ),
      /elevation receipt differs from its installed inventory/,
    );
    const duplicateHostInput = structuredClone(inputValue);
    duplicateHostInput.deployment.installed_inventories[1] = installedInventory(
      root,
      'studio',
      deployment.localUUID,
      localInventory.entries,
      qualificationToolsAggregate,
      sha256(fs.readFileSync(deployment.elevationReceipts[1])),
      '-duplicate-host',
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'duplicate-host-input.json'), duplicateHostInput),
        path.join(root, 'duplicate-host-manifest.json'),
      ),
      /host UUIDs are not distinct/,
    );
    const wrongToolsAggregateInput = structuredClone(inputValue);
    wrongToolsAggregateInput.deployment.installed_inventories = [
      installedInventory(
        root,
        'local',
        deployment.localUUID,
        localInventory.entries,
        '0'.repeat(64),
        sha256(fs.readFileSync(deployment.elevationReceipts[0])),
        '-wrong-tools',
      ),
      installedInventory(
        root,
        'studio',
        deployment.studioUUID,
        localInventory.entries,
        '0'.repeat(64),
        sha256(fs.readFileSync(deployment.elevationReceipts[1])),
        '-wrong-tools',
      ),
    ];
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'wrong-tools-aggregate-input.json'), wrongToolsAggregateInput),
        path.join(root, 'wrong-tools-aggregate-manifest.json'),
      ),
      /qualification tools aggregate differs from installed inventories/,
    );
    const dirtyPolicyInput = structuredClone(inputValue);
    const dirtyPolicy = JSON.parse(fs.readFileSync(deployment.policyReports[0]));
    dirtyPolicy.forbidden_findings = [{ family: 'osa', path: '/private/task/worker' }];
    dirtyPolicyInput.deployment.executable_policy_reports[0] = writeJSON(
      path.join(root, 'dirty-executable-policy.json'),
      dirtyPolicy,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'dirty-executable-policy-input.json'), dirtyPolicyInput),
        path.join(root, 'dirty-executable-policy-manifest.json'),
      ),
      /not one complete clean executable\/script policy report/,
    );
    assert.doesNotMatch(
      fs.readFileSync(path.join(toolRoot, 'qualification-manifest.mjs'), 'utf8'),
      /\b(?:killall|pkill)\b|\.kill\s*\(/,
    );
    const dummyInput = structuredClone(inputValue);
    dummyInput.matrix_cycles[0].certificate = evidence();
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'dummy-manifest-input.json'), dummyInput),
        path.join(root, 'dummy-manifest.json'),
      ),
      /keys are not closed|passing 42\/42 certificate/,
    );
    const badCrashInput = structuredClone(inputValue);
    badCrashInput.matrix_cycles[0].crash_inventory = writeJSON(
      path.join(root, 'bad-crash.json'),
      { version: 1, passed: false, added: [{ name: 'Peekaboo.crash' }], changed: [], removed: [] },
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'bad-crash-input.json'), badCrashInput),
        path.join(root, 'bad-crash-manifest.json'),
      ),
      /zero-delta crash comparison/,
    );
    const crossRunInput = structuredClone(inputValue);
    crossRunInput.live_v4.plan = writeJSON(path.join(root, 'other-run-plan.json'), {
      ...JSON.parse(fs.readFileSync(inputValue.live_v4.plan)), other_run: true,
    });
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'cross-run-input.json'), crossRunInput),
        path.join(root, 'cross-run-manifest.json'),
      ),
      /differs from concurrent validation/,
    );
    const badPointerInput = structuredClone(inputValue);
    badPointerInput.adjuncts.held_pointer.controller_results = [writeJSON(
      path.join(root, 'bad-pointer-controller.json'),
      { ...JSON.parse(fs.readFileSync(pointerControllerResult)), cleanup_state: 'owner_closed' },
    )];
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'bad-pointer-input.json'), badPointerInput),
        path.join(root, 'bad-pointer-manifest.json'),
      ),
      /source-owned 6-receipt result/,
    );
    const badPointerClientInput = structuredClone(inputValue);
    const badPointerClient = JSON.parse(fs.readFileSync(pointerControllerResult));
    badPointerClient.handshake.session.client_instance_id = UUID;
    badPointerClientInput.adjuncts.held_pointer.controller_results = [writeJSON(
      path.join(root, 'bad-pointer-client.json'), badPointerClient,
    )];
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'bad-pointer-client-input.json'), badPointerClientInput),
        path.join(root, 'bad-pointer-client-manifest.json'),
      ),
      /source-owned 6-receipt result/,
    );
    const badPointerCrashInput = structuredClone(inputValue);
    badPointerCrashInput.adjuncts.held_pointer.crash_inventories = [writeJSON(
      path.join(root, 'bad-pointer-crash.json'),
      { version: 1, passed: false, added: [{ name: 'Playground.crash' }], changed: [], removed: [] },
    )];
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'bad-pointer-crash-input.json'), badPointerCrashInput),
        path.join(root, 'bad-pointer-crash-manifest.json'),
      ),
      /zero-delta crash comparison/,
    );
    const badValidatorInput = structuredClone(inputValue);
    badValidatorInput.adjuncts.middle_click.live_validator_reports = [writeJSON(
      path.join(root, 'bad-middle-validator.json'),
      { success: true, data: { ...JSON.parse(fs.readFileSync(middleBundle.validator)).data, valid: false } },
    )];
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'bad-validator-input.json'), badValidatorInput),
        path.join(root, 'bad-validator-manifest.json'),
      ),
      /not bound to one authenticated live bundle/,
    );
    const input = writeJSON(path.join(root, 'manifest-input.json'), inputValue);
    const output = path.join(root, 'qualification-manifest.json');
    generateManifest(input, output);
    const verified = verifyManifest(output);
    assert.equal(verified.version, 2);
    assert.equal(verified.valid, true);
    assert.equal(verified.adjuncts_are_live_v4_slots, false);
    const generatedManifest = JSON.parse(fs.readFileSync(output));
    assert.equal(generatedManifest.version, 2);
    assert.equal(generatedManifest.evidence.deployment.installed_inventories.length, 2);
    assert.equal(generatedManifest.evidence.deployment.process_trees.length, 6);

    const originalInstalledInventory = fs.readFileSync(deployment.installed[0]);
    fs.appendFileSync(deployment.installed[0], 'drift');
    assert.throws(() => verifyManifest(output), /changed after manifest generation/);
    writeFile(deployment.installed[0], originalInstalledInventory);

    const originalControllerResult = fs.readFileSync(pointerControllerResult);
    fs.appendFileSync(pointerControllerResult, 'drift');
    assert.throws(() => verifyManifest(output), /changed/);
    writeFile(pointerControllerResult, originalControllerResult);

    const openManifest = JSON.parse(fs.readFileSync(output));
    openManifest.unexpected = true;
    const openPath = writeJSON(path.join(root, 'open-manifest.json'), openManifest);
    assert.throws(() => verifyManifest(openPath), /keys are not closed/);

    fs.appendFileSync(inputValue.matrix_cycles[0].certificate, 'drift');
    assert.throws(() => verifyManifest(output), /changed after manifest generation/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
