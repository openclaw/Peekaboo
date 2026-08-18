#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  HEX40,
  HEX64,
  authenticateLiveBridgeBundle,
  corroboratedObservationTime,
  exactKeys,
  parseOptions,
  positiveDecimal,
  positiveInteger,
  readStableFile,
  readStableJSON,
  readStableJSONLines,
  readCalibrationEmitter,
  requireCondition,
  requirePrivateDirectory,
  requireStableExecutable,
  sameJSON,
  sha256,
  validateEmitter,
  validateTarget,
  writePrivateExclusive,
} from './lib.mjs';

const MUTATING_TOOLS = new Set([
  'action', 'app', 'click', 'dialog', 'dock', 'drag', 'menu', 'move', 'paste', 'press',
  'scroll', 'set_value', 'space', 'type', 'window',
]);

function normalizedToolName(value) {
  return typeof value === 'string' ? value.trim().replaceAll('-', '_').toLowerCase() : '';
}

function verifiedCodeSignatureHash(executablePath, label) {
  const verify = spawnSync('/usr/bin/codesign', ['--verify', '--strict', executablePath], {
    encoding: 'utf8', timeout: 10_000, maxBuffer: 1024 * 1024,
  });
  requireCondition(!verify.error && verify.status === 0,
    `${label} code signature is invalid`);
  const display = spawnSync('/usr/bin/codesign', ['-dvvv', executablePath], {
    encoding: 'utf8', timeout: 10_000, maxBuffer: 1024 * 1024,
  });
  const matches = [...`${display.stdout ?? ''}\n${display.stderr ?? ''}`
    .matchAll(/^CDHash=([0-9a-f]{40})$/gm)].map((match) => match[1]);
  requireCondition(!display.error && display.status === 0 && matches.length === 1,
    `${label} has no exact CDHash`);
  return matches[0];
}

function processIdentity(filePath, label) {
  const retained = readStableJSON(filePath, label);
  exactKeys(retained.value, ['pid', 'startIdentity'], label);
  requireCondition(positiveInteger(retained.value.pid) && positiveDecimal(retained.value.startIdentity), `${label} is malformed`);
  return {
    pid: retained.value.pid,
    start_identity: retained.value.startIdentity,
    mtime_milliseconds: Number(retained.info.mtimeNs / 1_000_000n),
    sha256: retained.sha256,
  };
}

function exitReceipt(filePath, expectedProcess) {
  const label = `${expectedProcess} exit receipt`;
  const retained = readStableJSON(filePath, label);
  const value = retained.value;
  exactKeys(value, [
    'version', 'process', 'pid', 'start_identity', 'started_at_milliseconds',
    'completed_at_milliseconds', 'exit_code', 'signal',
  ], label);
  requireCondition(value.version === 1 && value.process === expectedProcess, `${label} identity is invalid`);
  requireCondition(positiveInteger(value.pid) && positiveDecimal(value.start_identity), `${label} process generation is invalid`);
  requireCondition(positiveInteger(value.started_at_milliseconds)
    && positiveInteger(value.completed_at_milliseconds)
    && value.completed_at_milliseconds >= value.started_at_milliseconds,
  `${label} interval is invalid`);
  requireCondition(value.exit_code === 0 && value.signal === null, `${label} does not prove zero exit`);
  return { ...value, sha256: retained.sha256 };
}

function coordinatorEvents(filePath) {
  const retained = readStableJSONLines(filePath, 'coordinator events');
  const events = retained.values;
  requireCondition(events.length === 4, 'coordinator events must contain exactly four lifecycle events');
  requireCondition(events.map((event) => event.event).join(',')
    === 'run-created,external-foreground-window,external-foreground-window,completed',
  'coordinator lifecycle event order is not canonical');
  const [created, perform, restore, completed] = events;
  exactKeys(created, ['event', 'version', 'execution_nonce', 'monitor_instance_id', 'run_root'], 'run-created event');
  for (const [value, phase] of [[perform, 'perform'], [restore, 'restore']]) {
    exactKeys(value, [
      'event', 'version', 'execution_nonce', 'monitor_instance_id', 'phase',
      'window_path', 'deadline_milliseconds',
    ], `${phase} event`);
    requireCondition(value.phase === phase && positiveInteger(value.deadline_milliseconds), `${phase} event is malformed`);
  }
  exactKeys(completed, [
    'event', 'version', 'execution_nonce', 'monitor_instance_id', 'run_root',
    'summary_path', 'certification_eligible',
  ], 'completed event');
  requireCondition(completed.certification_eligible === true, 'coordinator completion is not certification-eligible');
  requireCondition(HEX64.test(created.execution_nonce ?? '')
    && typeof created.monitor_instance_id === 'string', 'coordinator run identity is malformed');
  for (const event of events.slice(1)) {
    requireCondition(event.version === 1 && event.execution_nonce === created.execution_nonce
      && event.monitor_instance_id === created.monitor_instance_id,
    'coordinator events do not share one run identity');
  }
  requireCondition(completed.run_root === created.run_root, 'completed event changed run root');
  requirePrivateDirectory(created.run_root, 'coordinator run root');
  requireCondition(path.dirname(perform.window_path) === created.run_root
    && perform.window_path === restore.window_path
    && path.basename(perform.window_path) === 'external-foreground-window.json',
  'external window path is not the canonical run-root file');
  requireCondition(completed.summary_path === path.join(created.run_root, 'certification-summary.json'), 'completion summary path is not canonical');
  return { retained, events, created, perform, restore, completed };
}

function operationInterval(runRoot, nonce, monitorID) {
  const monitorPath = path.join(runRoot, 'monitor', 'monitor-evidence.json');
  const retained = readStableJSON(monitorPath, 'live monitor evidence');
  const evidence = retained.value;
  requireCondition(evidence.version === 1 && evidence.execution_nonce === nonce
    && evidence.monitor_instance_id === monitorID, 'live monitor evidence is not run-bound');
  requireCondition(Array.isArray(evidence.fences), 'live monitor evidence has no fences');
  const fence = (name) => {
    const matches = evidence.fences.filter((entry) => entry?.name === name);
    requireCondition(matches.length === 1 && positiveInteger(matches[0].heartbeat?.wallClockMilliseconds), `monitor has no exact ${name} fence`);
    return matches[0].heartbeat.wallClockMilliseconds;
  };
  const start = fence('operations-start');
  const complete = fence('operations-complete');
  requireCondition(complete > start, 'monitor operation fences are not strictly ordered');
  requireCondition(evidence.foreground_plan?.expected_value_sha256
    === sha256(Buffer.from(evidence.foreground_plan?.request_marker ?? '', 'utf8')),
  'monitor foreground marker digest is invalid');
  requireCondition(HEX64.test(evidence.foreground_plan?.baseline_value_sha256 ?? ''), 'monitor foreground baseline digest is invalid');
  return { retained, evidence, start, complete };
}

function recursivelyRejectForeground(value, label = 'trace arguments') {
  if (Array.isArray(value)) {
    value.forEach((entry) => recursivelyRejectForeground(entry, label));
    return;
  }
  if (!value || typeof value !== 'object') return;
  for (const [key, entry] of Object.entries(value)) {
    const normalized = key.trim().replaceAll('-', '_').toLowerCase();
    requireCondition(!(normalized === 'foreground' && entry === true), `${label} requested foreground=true`);
    requireCondition(!(['mode', 'delivery_mode', 'capture_focus'].includes(normalized)
      && typeof entry === 'string' && entry.toLowerCase() === 'foreground'), `${label} requested foreground mode`);
    recursivelyRejectForeground(entry, label);
  }
}

function traceReceipt(filePath) {
  const retained = readStableJSON(filePath, 'Agent JSON result');
  const root = retained.value;
  requireCondition(root.success === true && root.result && typeof root.result === 'object', 'Agent JSON result did not succeed');
  const trace = root.result.executionTrace;
  exactKeys(trace, ['entries', 'totalCallCount', 'truncated'], 'Agent executionTrace');
  requireCondition(Array.isArray(trace.entries) && trace.entries.length > 0, 'Agent execution trace is empty');
  requireCondition(trace.truncated === false && trace.totalCallCount === trace.entries.length, 'Agent execution trace is incomplete');
  const ids = new Set();
  const entriesByID = new Map();
  const entryIndexByID = new Map();
  const dispatchedCallIDs = new Set();
  for (const [index, entry] of trace.entries.entries()) {
    const keys = Object.keys(entry).sort();
    const required = ['arguments', 'disposition', 'id', 'isError', 'name', 'result'];
    requireCondition(required.every((key) => keys.includes(key))
      && keys.every((key) => [...required, 'mutationDispatch', 'actionOutcome'].includes(key)),
    `Agent trace entry ${index} keys are not closed`);
    requireCondition(typeof entry.id === 'string' && entry.id.length > 0 && !ids.has(entry.id), `Agent trace entry ${index} ID is invalid`);
    ids.add(entry.id);
    entriesByID.set(entry.id, entry);
    entryIndexByID.set(entry.id, index);
    const name = normalizedToolName(entry.name);
    requireCondition(name && name !== 'shell', 'Agent trace contains Shell');
    recursivelyRejectForeground(entry.arguments, `Agent trace entry ${entry.id}`);
    requireCondition(entry.mutationDispatch !== 'possibly_dispatched', `Agent trace entry ${entry.id} is possibly dispatched`);
    if (entry.mutationDispatch === 'dispatched') dispatchedCallIDs.add(entry.id);
    requireCondition(entry.actionOutcome?.delivery_mode !== 'foreground', `Agent trace entry ${entry.id} used foreground delivery`);
    if (MUTATING_TOOLS.has(name)) {
      requireCondition(entry.disposition === 'executed/succeeded' && entry.isError === false, `Agent mutation ${entry.id} did not succeed`);
      requireCondition(entry.mutationDispatch === 'dispatched', `Agent mutation ${entry.id} was not definitely dispatched`);
      requireCondition(entry.actionOutcome?.delivery_mode === 'background', `Agent mutation ${entry.id} lacks background outcome authority`);
    } else {
      requireCondition(entry.disposition === 'executed/succeeded' && entry.isError === false, `Agent observation ${entry.id} did not succeed`);
    }
  }
  return { retained, root, trace, entriesByID, entryIndexByID, dispatchedCallIDs };
}

function semanticReadback(filePath, expectedTarget, expectedPhase, operation, label) {
  const retained = readStableJSON(filePath, label);
  const value = retained.value;
  exactKeys(value, [
    'version', 'target', 'phase', 'value', 'observed_at_milliseconds', 'passed',
  ], label);
  requireCondition(value.version === 1 && value.phase === expectedPhase && value.passed === true,
    `${label} did not pass its exact phase`);
  requireCondition(sameJSON(value.target, expectedTarget), `${label} target differs from the Agent target`);
  requireCondition(typeof value.value === 'string' && Buffer.byteLength(value.value) <= 4096,
    `${label} value is invalid`);
  requireCondition(value.observed_at_milliseconds >= operation.start
    && value.observed_at_milliseconds <= operation.complete,
  `${label} falls outside the authoritative operation interval`);
  const observation = corroboratedObservationTime(retained, label);
  return {
    retained,
    value,
    observation,
    value_sha256: sha256(Buffer.from(value.value, 'utf8')),
  };
}

function signedBundleTarget(payload, label) {
  const target = payload?.target;
  requireCondition(target && target.kind === 'window', `${label} is not exact-window targeted`);
  requireCondition(positiveInteger(target.processIdentifier)
    && positiveDecimal(target.processStartIdentity)
    && positiveInteger(target.windowID), `${label} target identity is malformed`);
  return {
    pid: target.processIdentifier,
    start_identity: target.processStartIdentity,
    window_id: target.windowID,
  };
}

function signedBundle(filePath, validatorPath, operation, label, authentication) {
  const bundle = readStableJSON(filePath, `${label} signed bundle`, {
    maximumBytes: 256 * 1024 * 1024,
  });
  const payload = bundle.value?.receipt?.payload;
  requireCondition(payload && payload.schemaVersion === 1
    && typeof payload.operation === 'string'
    && positiveInteger(payload.client?.processIdentifier)
    && positiveDecimal(payload.client?.processStartIdentity)
    && HEX40.test(payload.client?.codeSignatureHash ?? '')
    && positiveInteger(payload.startedAtUnixMilliseconds)
    && positiveInteger(payload.completedAtUnixMilliseconds)
    && payload.completedAtUnixMilliseconds >= payload.startedAtUnixMilliseconds,
  `${label} signed payload is malformed`);
  const validator = readStableJSON(validatorPath, `${label} live validator`);
  exactKeys(validator.value, ['success', 'data'], `${label} live validator`);
  requireCondition(validator.value.success === true, `${label} live validator did not succeed`);
  const authenticatedReport = authentication.authenticateBundle({
    executablePath: authentication.executable_path,
    expectedExecutableSHA256: authentication.executable_sha256,
    socketPath: authentication.bridge_socket,
    trustedHostTeamIDs: authentication.trusted_host_team_ids,
    expectedHost: authentication.expected_host,
    bundlePath: bundle.path,
    label,
  });
  requireCondition(sameJSON(validator.value.data, authenticatedReport),
    `${label} retained validator report differs from authenticated live validation`);
  const report = authenticatedReport;
  requireCondition(report?.valid === true
    && report.validator_id === 'peekaboo-bridge-receipt-validate-v1'
    && report.trust_source === 'authenticated_live_listener'
    && report.minimum_protocol_version === '1.29'
    && report.host_protocol_version === '1.30'
    && HEX40.test(report.host_source_commit ?? '')
    && report.terminal_receipt_attested === true
    && report.retention_basis === 'exported_bundle'
    && report.bundle_sha256 === bundle.sha256
    && report.operation === payload.operation
    && report.request_id === String(payload.requestID ?? '').toLowerCase()
    && report.client?.pid === payload.client.processIdentifier
    && report.client?.start_identity === payload.client.processStartIdentity
    && report.client?.code_signature_hash === payload.client.codeSignatureHash,
  `${label} live validator report is not bound to the exact bundle`);
  if (operation !== null) {
    requireCondition(report.target_attested === true && report.outcome_attested === true,
      `${label} mutation lacks target/outcome attestation`);
    requireCondition(payload.operation === operation, `${label} signed operation differs from its Agent family`);
    requireCondition(payload.outcome?.delivery_mode === 'background'
      && payload.outcome?.dispatch_state === 'dispatched'
      && payload.outcome?.mutation_dispatched === true,
    `${label} signed outcome is not one definite background dispatch`);
  }
  return { bundle, validator, payload, report };
}

function expectedBridgeOperation(family) {
  return {
    set_value: 'setValue',
    action: 'performAction',
    click: 'exactWindowTargetedClick',
    type: 'exactWindowTargetedTypeActions',
    paste: 'exactWindowTargetedTypeActions',
    press: 'exactWindowTargetedHotkey',
  }[family] ?? null;
}

function agentBundleCorpus(entries, receiptDirectory, expectedAgent, expectedHost, authentication) {
  requireCondition(Array.isArray(entries) && entries.length >= 4,
    'Agent bundle corpus must contain every signed bundle');
  const files = fs.readdirSync(receiptDirectory, { withFileTypes: true });
  requireCondition(files.every((entry) => entry.isFile() && entry.name.endsWith('.json')),
    'Agent receipt directory contains a non-bundle entry');
  const actualPaths = files.map((entry) => path.join(receiptDirectory, entry.name)).sort();
  const bundlePaths = entries.map((entry, index) => {
    exactKeys(entry, ['bundle_path', 'validator_report_path'], `agent_bundles[${index}]`);
    requireCondition(path.dirname(entry.bundle_path) === receiptDirectory,
      `agent_bundles[${index}] is outside the Agent receipt directory`);
    return entry.bundle_path;
  }).sort();
  requireCondition(sameJSON(actualPaths, bundlePaths),
    'Agent bundle corpus does not equal the complete receipt-directory inventory');
  requireCondition(new Set(bundlePaths).size === bundlePaths.length,
    'Agent bundle corpus reuses a signed bundle');
  const validatorPaths = entries.map((entry) => entry.validator_report_path);
  requireCondition(new Set(validatorPaths).size === validatorPaths.length,
    'Agent bundle corpus reuses a live validator report');
  const listenerIDs = new Set();
  const corpus = new Map(entries.map((entry, index) => {
    const signed = signedBundle(
      entry.bundle_path,
      entry.validator_report_path,
      null,
      `Agent bundle ${index}`,
      authentication,
    );
    requireCondition(signed.payload.client.processIdentifier === expectedAgent.pid
      && signed.payload.client.processStartIdentity === expectedAgent.start_identity
      && signed.payload.client.codeSignatureHash === expectedAgent.code_signature_hash,
    `Agent bundle ${index} was emitted by another process generation`);
    requireCondition(signed.report.host?.pid === expectedHost.process_identifier
      && signed.report.host?.start_identity === expectedHost.process_start_identity_decimal
      && signed.report.host?.code_signature_hash === expectedHost.code_signature_hash
      && signed.report.host_source_commit === expectedHost.source_commit,
    `Agent bundle ${index} was validated against another Bridge host/build`);
    requireCondition(typeof signed.report.listener_instance_id === 'string'
      && signed.report.listener_instance_id.length > 0,
    `Agent bundle ${index} has no live listener identity`);
    listenerIDs.add(signed.report.listener_instance_id);
    return [entry.bundle_path, signed];
  }));
  requireCondition(listenerIDs.size === 1,
    'Agent bundle corpus spans more than one live listener instance');
  return corpus;
}

function agentReadbacks(filePath, agent, trace, operation, plan, corpus) {
  const retained = readStableJSON(filePath, 'Agent readback evidence');
  const value = retained.value;
  exactKeys(value, ['version', 'agent', 'targets'], 'Agent readback evidence');
  requireCondition(value.version === 1, 'Agent readback evidence version is not 1');
  exactKeys(value.agent, ['pid', 'start_identity'], 'Agent readback agent');
  requireCondition(sameJSON(value.agent, { pid: agent.pid, start_identity: agent.start_identity }),
    'Agent readback evidence belongs to another process generation');
  requireCondition(Array.isArray(value.targets) && value.targets.length === 2,
    'Agent readback evidence needs exactly two targets');
  const forbiddenProcesses = new Set([
    ...plan.controllers.map((entry) => (
      `${entry.target.process_identifier}:${entry.target.process_start_identity_decimal}`
    )),
    `${plan.bridge.expected_host.process_identifier}:${plan.bridge.expected_host.process_start_identity_decimal}`,
    `${plan.observer.target.pid}:${plan.observer.target.start_identity}`,
    `${plan.monitor.foreground_target.pid}:${plan.monitor.foreground_target.start_identity}`,
    `${plan.monitor.foreground_controller.pid}:${plan.monitor.foreground_controller.start_identity}`,
    `${plan.monitor.sentinel.pid}:${plan.monitor.sentinel.start_identity}`,
  ]);
  const mutationFamilies = new Set();
  const usedCallIDs = new Set();
  const usedBundlePaths = new Set();
  const targetProcesses = new Set();
  const targetWindows = new Set();
  const readbackReceipts = [];
  const actionIntervals = [];
  for (const [index, target] of value.targets.entries()) {
    exactKeys(target, [
      'label', 'target', 'baseline_readback_path', 'mutation', 'restoration',
    ], `Agent readback target ${index}`);
    requireCondition(target.label === `target-${index === 0 ? 'a' : 'b'}`,
      'Agent readback target order is not canonical');
    exactKeys(target.target, ['pid', 'start_identity', 'window_id'], `Agent readback ${target.label}.target`);
    requireCondition(positiveInteger(target.target.pid) && positiveDecimal(target.target.start_identity)
      && positiveInteger(target.target.window_id), `Agent readback ${target.label} identity is invalid`);
    const processKey = `${target.target.pid}:${target.target.start_identity}`;
    targetProcesses.add(processKey);
    targetWindows.add(`${processKey}:${target.target.window_id}`);
    requireCondition(!forbiddenProcesses.has(processKey),
      `Agent ${target.label} aliases a controller/observer/foreground/sentinel process`);
    const baseline = semanticReadback(
      target.baseline_readback_path,
      target.target,
      'baseline',
      operation,
      `Agent ${target.label} baseline readback`,
    );
    readbackReceipts.push(baseline);
    const actionReceipts = {};
    for (const [kind, phase] of [['mutation', 'mutated'], ['restoration', 'restored']]) {
      const action = target[kind];
      exactKeys(action, [
        'trace_call_id', 'family', 'readback_path', 'bundle_path', 'validator_report_path',
      ], `Agent readback ${target.label}.${kind}`);
      requireCondition(typeof action.trace_call_id === 'string' && !usedCallIDs.has(action.trace_call_id),
        `Agent readback ${target.label}.${kind} call ID is reused`);
      usedCallIDs.add(action.trace_call_id);
      requireCondition(!usedBundlePaths.has(action.bundle_path),
        `Agent readback ${target.label}.${kind} bundle is reused`);
      usedBundlePaths.add(action.bundle_path);
      const entry = trace.entriesByID.get(action.trace_call_id);
      requireCondition(action.family === normalizedToolName(action.family)
        && MUTATING_TOOLS.has(action.family), `Agent readback ${target.label}.${kind} family is invalid`);
      requireCondition(entry && normalizedToolName(entry.name) === action.family,
        `Agent readback ${target.label}.${kind} does not match its trace family`);
      requireCondition(entry.arguments?.pid === target.target.pid
        && entry.arguments?.window_id === target.target.window_id,
      `Agent readback ${target.label}.${kind} trace lacks the exact PID/window`);
      const expectedOperation = expectedBridgeOperation(action.family);
      requireCondition(expectedOperation !== null, `Agent ${target.label}.${kind} has no closed Bridge operation map`);
      const corpusEntry = corpus.get(action.bundle_path);
      requireCondition(corpusEntry
        && corpusEntry.validator.path === action.validator_report_path,
      `Agent ${target.label}.${kind} bundle/validator is absent from the complete corpus`);
      const signed = corpusEntry;
      requireCondition(signed.report.target_attested === true
        && signed.report.outcome_attested === true,
      `Agent ${target.label}.${kind} mutation lacks target/outcome attestation`);
      requireCondition(signed.payload.operation === expectedOperation,
        `Agent ${target.label}.${kind} signed operation differs from its Agent family`);
      requireCondition(signed.payload.outcome?.delivery_mode === 'background'
        && signed.payload.outcome?.dispatch_state === 'dispatched'
        && signed.payload.outcome?.mutation_dispatched === true,
      `Agent ${target.label}.${kind} signed outcome is not one definite background dispatch`);
      requireCondition(sameJSON(signedBundleTarget(signed.payload, `Agent ${target.label}.${kind}`), target.target),
        `Agent ${target.label}.${kind} signed target differs from its trace/readback target`);
      requireCondition(signed.payload.startedAtUnixMilliseconds >= operation.start
        && signed.payload.completedAtUnixMilliseconds <= operation.complete,
      `Agent ${target.label}.${kind} signed interval falls outside live-v4 operations`);
      const readback = semanticReadback(
        action.readback_path,
        target.target,
        phase,
        operation,
        `Agent ${target.label} ${kind} readback`,
      );
      requireCondition(signed.payload.completedAtUnixMilliseconds <= readback.value.observed_at_milliseconds,
        `Agent ${target.label}.${kind} readback predates its signed dispatch`);
      readbackReceipts.push(readback);
      actionReceipts[kind] = { action, signed, readback };
      actionIntervals.push({
        trace_call_id: action.trace_call_id,
        started_at_milliseconds: signed.payload.startedAtUnixMilliseconds,
        completed_at_milliseconds: signed.payload.completedAtUnixMilliseconds,
      });
    }
    requireCondition(actionReceipts.mutation.readback.value.value !== baseline.value.value,
      `Agent ${target.label} mutation did not change the baseline`);
    requireCondition(actionReceipts.restoration.readback.value.value === baseline.value.value,
      `Agent ${target.label} restoration did not restore the baseline`);
    requireCondition(
      baseline.value.observed_at_milliseconds
        <= actionReceipts.mutation.signed.payload.startedAtUnixMilliseconds
      && actionReceipts.mutation.signed.payload.completedAtUnixMilliseconds
        <= actionReceipts.mutation.readback.value.observed_at_milliseconds
      && actionReceipts.mutation.readback.value.observed_at_milliseconds
        <= actionReceipts.restoration.signed.payload.startedAtUnixMilliseconds
      && actionReceipts.restoration.signed.payload.completedAtUnixMilliseconds
        <= actionReceipts.restoration.readback.value.observed_at_milliseconds
      && actionReceipts.mutation.signed.payload.completedAtUnixMilliseconds
        <= actionReceipts.restoration.signed.payload.startedAtUnixMilliseconds
      && actionReceipts.mutation.readback.value.observed_at_milliseconds
        <= actionReceipts.restoration.readback.value.observed_at_milliseconds,
      `Agent ${target.label} baseline/mutation/restoration order is invalid`,
    );
    requireCondition(
      trace.entryIndexByID.get(actionReceipts.mutation.action.trace_call_id)
        < trace.entryIndexByID.get(actionReceipts.restoration.action.trace_call_id),
      `Agent ${target.label} trace restores before it mutates`,
    );
    mutationFamilies.add(target.mutation.family);
    if (target.label === 'target-b') {
      requireCondition(target.restoration.family !== target.mutation.family,
        'Agent target-b restoration did not use a different mutation family');
    }
  }
  requireCondition(targetProcesses.size === 2 && targetWindows.size === 2,
    'Agent targets must be two distinct process generations and windows');
  requireCondition(mutationFamilies.size >= 2, 'Agent did not use two primary mutation families');
  requireCondition(usedCallIDs.size === 4
    && sameJSON([...usedCallIDs].sort(), [...trace.dispatchedCallIDs].sort()),
  'Agent trace must contain exactly the four mapped dispatched mutation call IDs');
  for (const [bundlePath, item] of corpus.entries()) {
    if (usedBundlePaths.has(bundlePath)) continue;
    requireCondition(item.payload.outcome?.mutation_dispatched !== true
      && item.payload.outcome?.dispatch_state !== 'dispatched',
    'Agent corpus contains an unmapped dispatched mutation bundle');
  }
  return {
    retained,
    value,
    mutation_families: [...mutationFamilies].sort(),
    mapped_call_ids: [...usedCallIDs].sort(),
    bundle_count: corpus.size,
    bundles: [...corpus.entries()].map(([bundlePath, entry]) => ({
      bundle_path: bundlePath,
      bundle_sha256: entry.bundle.sha256,
      validator_report_path: entry.validator.path,
      validator_report_sha256: entry.validator.sha256,
      operation: entry.payload.operation,
    })).sort((left, right) => left.bundle_path.localeCompare(right.bundle_path)),
    readbacks: readbackReceipts.map((entry) => ({
      path: entry.retained.path,
      sha256: entry.retained.sha256,
      observed_at_milliseconds: entry.value.observed_at_milliseconds,
      value_sha256: entry.value_sha256,
    })),
    action_intervals: actionIntervals,
  };
}

const COMMON_LAUNCH_ENVIRONMENT_KEYS = [
  'HOME', 'LANG', 'LC_ALL', 'LC_CTYPE', 'LOGNAME', 'PATH', 'SSL_CERT_DIR',
  'SSL_CERT_FILE', 'TMPDIR', 'TZ', 'USER',
];
const AGENT_LAUNCH_ENVIRONMENT_KEYS = [
  ...COMMON_LAUNCH_ENVIRONMENT_KEYS,
  'ANTHROPIC_API_KEY', 'GEMINI_API_KEY', 'GOOGLE_API_KEY', 'GROK_API_KEY',
  'MINIMAX_API_KEY', 'MOONSHOT_API_KEY', 'OPENAI_API_KEY', 'OPENROUTER_API_KEY',
  'PEEKABOO_OPERATION_RECEIPT_DIRECTORY', 'XAI_API_KEY',
];

function validateLaunchEnvironment(value, kind) {
  requireCondition(value.environment_policy_version === 1
    && Array.isArray(value.environment_keys) && value.environment_keys.length > 0
    && value.environment_keys.every((key) => typeof key === 'string' && key.length > 0)
    && new Set(value.environment_keys).size === value.environment_keys.length
    && value.environment_keys.every((key, index) => index === 0
      || value.environment_keys[index - 1] < key)
    && HEX64.test(value.environment_sha256 ?? ''),
  `${kind} invocation environment receipt is malformed`);
  const allowlist = kind === 'Agent'
    ? AGENT_LAUNCH_ENVIRONMENT_KEYS : COMMON_LAUNCH_ENVIRONMENT_KEYS;
  requireCondition(value.environment_keys.every((key) => allowlist.includes(key))
    && value.environment_keys.includes('PATH')
    && !value.environment_keys.some((key) => key === 'NODE_OPTIONS' || key.startsWith('DYLD_')),
  `${kind} invocation environment exceeds the closed allowlist`);
  if (kind === 'Agent') {
    requireCondition(value.environment_keys.includes('PEEKABOO_OPERATION_RECEIPT_DIRECTORY'),
      'Agent invocation environment omits its receipt directory');
  }
}

function agentInvocation(filePath, agent, plan, planReceipt, lifetime) {
  const retained = readStableJSON(filePath, 'Agent invocation receipt');
  const value = retained.value;
  exactKeys(value, [
    'version', 'kind', 'pid', 'start_identity', 'executable_path', 'executable_sha256',
    'arguments', 'plan_path', 'plan_sha256', 'monitor_executable_path',
    'monitor_executable_sha256', 'monitor_code_signature_hash',
    'identity_handshake_path', 'identity_handshake_sha256',
    'stdout_path', 'stderr_path', 'environment_policy_version', 'environment_keys',
    'environment_sha256', 'captured_at_milliseconds', 'task_path', 'task_sha256',
    'receipt_directory', 'bridge_socket', 'background_only', 'allow_foreground', 'shell_available',
  ], 'Agent invocation receipt');
  requireCondition(value.version === 1 && value.kind === 'agent'
    && sameJSON({ pid: value.pid, start_identity: value.start_identity }, agent),
  'Agent invocation receipt belongs to another process generation');
  requireCondition(value.background_only === true && value.allow_foreground === false
    && value.shell_available === false, 'Agent invocation policy is not background-only without Shell');
  requireCondition(value.executable_path === plan.peekaboo_executable, 'Agent invocation executable differs from the live plan');
  const executable = requireStableExecutable(value.executable_path, 'Agent invocation executable', {
    allowRootOwner: true,
  });
  requireCondition(value.executable_sha256 === executable.sha256, 'Agent invocation executable bytes changed');
  const codeSignatureHash = verifiedCodeSignatureHash(value.executable_path, 'Agent invocation executable');
  requireCondition(value.bridge_socket === plan.bridge.socket_path,
    'Agent invocation Bridge socket differs from the live plan');
  requireCondition(value.plan_path === planReceipt.path && value.plan_sha256 === planReceipt.sha256,
    'Agent invocation plan bytes differ from validation');
  requireCondition(value.monitor_executable_path === plan.monitor_executable,
    'Agent invocation monitor executable differs from the live plan');
  const monitor = requireStableExecutable(value.monitor_executable_path, 'Agent invocation monitor', {
    allowRootOwner: true,
  });
  requireCondition(value.monitor_executable_sha256 === monitor.sha256,
    'Agent invocation monitor bytes changed');
  requireCondition(value.monitor_code_signature_hash === plan.monitor.code_signature_hash,
    'Agent invocation monitor CDHash differs from the plan');
  const handshake = readStableJSON(value.identity_handshake_path, 'Agent invocation identity handshake');
  exactKeys(handshake.value, ['pid', 'startIdentity'], 'Agent invocation identity handshake');
  requireCondition(handshake.sha256 === value.identity_handshake_sha256
    && handshake.value.pid === agent.pid && handshake.value.startIdentity === agent.start_identity,
  'Agent invocation identity handshake differs from its process');
  const task = readStableFile(value.task_path, 'Agent task');
  requireCondition(task.sha256 === value.task_sha256 && HEX64.test(value.task_sha256 ?? ''), 'Agent task bytes changed');
  const taskText = task.bytes.toString('utf8').replace(/\n$/, '');
  const expectedArguments = [
    'agent', 'run', taskText, '--no-cache', '--max-steps', '40',
    '--bridge-socket', value.bridge_socket, '--json',
  ];
  requireCondition(taskText.length > 0 && sameJSON(value.arguments, expectedArguments),
    'Agent invocation argv is not the exact closed background-only order');
  requirePrivateDirectory(value.receipt_directory, 'Agent receipt export directory');
  readStableFile(value.stdout_path, 'Agent stdout');
  readStableFile(value.stderr_path, 'Agent stderr');
  requireCondition(positiveInteger(value.captured_at_milliseconds)
    && value.captured_at_milliseconds >= lifetime.started_at_milliseconds
    && value.captured_at_milliseconds <= lifetime.completed_at_milliseconds,
  'Agent invocation receipt falls outside the Agent lifetime');
  validateLaunchEnvironment(value, 'Agent');
  return { retained, value, code_signature_hash: codeSignatureHash };
}

function coordinatorInvocation(filePath, coordinator, plan, planReceipt, eventsPath, lifetime) {
  const retained = readStableJSON(filePath, 'coordinator invocation receipt');
  const value = retained.value;
  exactKeys(value, [
    'version', 'kind', 'pid', 'start_identity', 'executable_path', 'executable_sha256',
    'arguments', 'plan_path', 'plan_sha256', 'monitor_executable_path',
    'monitor_executable_sha256', 'monitor_code_signature_hash',
    'identity_handshake_path', 'identity_handshake_sha256',
    'stdout_path', 'stderr_path', 'environment_policy_version', 'environment_keys',
    'environment_sha256', 'captured_at_milliseconds', 'coordinator_source_path',
    'coordinator_source_sha256',
  ], 'coordinator invocation receipt');
  requireCondition(value.version === 1 && value.kind === 'coordinator'
    && sameJSON({ pid: value.pid, start_identity: value.start_identity }, coordinator),
  'coordinator invocation belongs to another process generation');
  const executable = requireStableExecutable(value.executable_path, 'coordinator Node executable', {
    allowRootOwner: true,
  });
  requireCondition(value.executable_sha256 === executable.sha256,
    'coordinator Node executable bytes changed');
  const codeSignatureHash = verifiedCodeSignatureHash(
    value.executable_path,
    'coordinator Node executable',
  );
  const source = readStableFile(value.coordinator_source_path, 'coordinator source', {
    privateFile: false,
  });
  requireCondition(source.sha256 === value.coordinator_source_sha256,
    'coordinator source bytes changed');
  requireCondition(sameJSON(value.arguments, [source.path, '--plan', planReceipt.path]),
    'coordinator invocation argv is not the exact source and plan');
  requireCondition(value.plan_path === planReceipt.path && value.plan_sha256 === planReceipt.sha256,
    'coordinator invocation plan bytes differ from validation');
  requireCondition(value.monitor_executable_path === plan.monitor_executable,
    'coordinator invocation monitor differs from the plan');
  const monitor = requireStableExecutable(value.monitor_executable_path, 'coordinator invocation monitor', {
    allowRootOwner: true,
  });
  requireCondition(value.monitor_executable_sha256 === monitor.sha256,
    'coordinator invocation monitor bytes changed');
  requireCondition(value.monitor_code_signature_hash === plan.monitor.code_signature_hash,
    'coordinator invocation monitor CDHash differs from the plan');
  const handshake = readStableJSON(value.identity_handshake_path, 'coordinator identity handshake');
  exactKeys(handshake.value, ['pid', 'startIdentity'], 'coordinator identity handshake');
  requireCondition(handshake.sha256 === value.identity_handshake_sha256
    && handshake.value.pid === coordinator.pid
    && handshake.value.startIdentity === coordinator.start_identity,
  'coordinator identity handshake differs from its process');
  requireCondition(value.stdout_path === eventsPath,
    'coordinator stdout is not the validated event stream');
  readStableFile(value.stderr_path, 'coordinator stderr');
  requireCondition(positiveInteger(value.captured_at_milliseconds)
    && value.captured_at_milliseconds >= lifetime.started_at_milliseconds
    && value.captured_at_milliseconds <= lifetime.completed_at_milliseconds,
  'coordinator invocation receipt falls outside its lifetime');
  validateLaunchEnvironment(value, 'coordinator');
  return { retained, value, code_signature_hash: codeSignatureHash };
}

function integratedReadback(filePath, phase, expected) {
  const retained = readStableJSON(filePath, `integrated-CU ${phase} readback`);
  const value = retained.value;
  const common = [
    'version', 'execution_nonce', 'monitor_instance_id', 'phase', 'window_path', 'emitter',
    'target', 'observed_at_milliseconds', 'passed', 'observed_value_sha256',
  ];
  const phaseKeys = phase === 'perform'
    ? ['expected_value_sha256']
    : ['baseline_value_sha256', 'sentinel', 'observed_sentinel'];
  exactKeys(value, [...common, ...phaseKeys], `integrated-CU ${phase} readback`);
  requireCondition(value.version === 1 && value.phase === phase && value.passed === true, `integrated-CU ${phase} readback did not pass`);
  const observation = corroboratedObservationTime(retained, `integrated-CU ${phase} readback`);
  requireCondition(value.execution_nonce === expected.nonce && value.monitor_instance_id === expected.monitorID, `integrated-CU ${phase} readback is not run-bound`);
  requireCondition(value.window_path === expected.windowPath && sameJSON(value.emitter, expected.emitter), `integrated-CU ${phase} readback has another owner/emitter`);
  requireCondition(sameJSON(value.target, expected.target), `integrated-CU ${phase} readback has another target`);
  requireCondition(positiveInteger(value.observed_at_milliseconds) && value.observed_at_milliseconds <= expected.deadline,
    `integrated-CU ${phase} readback missed its deadline`);
  const expectedDigest = phase === 'perform' ? expected.markerSHA256 : expected.baselineSHA256;
  const field = phase === 'perform' ? 'expected_value_sha256' : 'baseline_value_sha256';
  requireCondition(value[field] === expectedDigest && value.observed_value_sha256 === expectedDigest,
    `integrated-CU ${phase} readback did not prove the expected value`);
  if (phase === 'restore') {
    requireCondition(sameJSON(value.sentinel, expected.sentinel), 'integrated-CU restore readback changed sentinel target');
    requireCondition(sameJSON(value.observed_sentinel, {
      pid: expected.sentinel.pid,
      start_identity: expected.sentinel.start_identity,
      window_id: expected.sentinel.window_id,
    }), 'integrated-CU restore readback did not observe the exact sentinel');
  }
  return { retained, value, observation };
}

export function validateConcurrentRun(specPath, outputPath, {
  authenticateBundle = authenticateLiveBridgeBundle,
} = {}) {
  const spec = readStableJSON(specPath, 'concurrent validation input').value;
  exactKeys(spec, [
    'version', 'plan', 'coordinator_invocation', 'coordinator_events', 'coordinator_exit', 'agent_result',
    'agent_exit', 'agent_invocation', 'agent_identity', 'agent_bundles', 'agent_readbacks',
    'integrated_cu',
  ], 'concurrent validation input');
  requireCondition(spec.version === 1, 'concurrent validation input version is not 1');
  exactKeys(spec.agent_identity, ['launch', 'perform', 'restore'], 'agent_identity');
  exactKeys(spec.integrated_cu, [
    'emitter', 'perform_readback', 'restore_readback',
  ], 'integrated_cu');

  const retainedPlan = readStableJSON(spec.plan, 'live-v4 plan');
  const plan = retainedPlan.value;
  requireCondition(plan.version === 1, 'live-v4 plan version is not 1');
  requireCondition(Array.isArray(plan.controllers) && plan.controllers.length === 2
    && plan.observer?.target, 'live-v4 plan lacks closed controller/observer targets');
  validateTarget(plan.monitor.foreground_target, 'plan foreground target');
  validateTarget(plan.monitor.sentinel, 'plan sentinel');
  const events = coordinatorEvents(spec.coordinator_events);
  const coordinatorExit = exitReceipt(spec.coordinator_exit, 'coordinator');
  requireCondition(coordinatorExit.started_at_milliseconds <= Number(events.retained.info.mtimeNs / 1_000_000n)
    && coordinatorExit.completed_at_milliseconds >= Number(events.retained.info.mtimeNs / 1_000_000n),
  'coordinator exit interval does not contain its JSONL evidence');
  const coordinatorLaunch = coordinatorInvocation(
    spec.coordinator_invocation,
    { pid: coordinatorExit.pid, start_identity: coordinatorExit.start_identity },
    plan,
    retainedPlan,
    spec.coordinator_events,
    coordinatorExit,
  );
  const summary = readStableFile(events.completed.summary_path, 'final certification summary');
  const operation = operationInterval(
    events.created.run_root,
    events.created.execution_nonce,
    events.created.monitor_instance_id,
  );
  requireCondition(operation.start < events.perform.deadline_milliseconds, 'perform deadline precedes operations-start');
  requireCondition(operation.complete < events.restore.deadline_milliseconds, 'restore deadline precedes operations-complete');

  const agentExit = exitReceipt(spec.agent_exit, 'agent');
  const agentIdentities = Object.fromEntries(Object.entries(spec.agent_identity).map(([phase, receipt]) => (
    [phase, processIdentity(receipt, `Agent ${phase} identity`)]
  )));
  const expectedAgent = { pid: agentExit.pid, start_identity: agentExit.start_identity };
  for (const [phase, identity] of Object.entries(agentIdentities)) {
    requireCondition(sameJSON({ pid: identity.pid, start_identity: identity.start_identity }, expectedAgent), `Agent ${phase} identity changed generation`);
    requireCondition(identity.mtime_milliseconds >= agentExit.started_at_milliseconds
      && identity.mtime_milliseconds <= agentExit.completed_at_milliseconds,
    `Agent ${phase} identity receipt falls outside the Agent lifetime`);
  }
  requireCondition(agentExit.started_at_milliseconds <= operation.start
    && agentExit.completed_at_milliseconds >= operation.complete,
  'Agent lifetime does not cover the complete live-v4 operation interval');
  requireCondition(agentIdentities.perform.mtime_milliseconds <= events.perform.deadline_milliseconds
    && agentIdentities.restore.mtime_milliseconds <= events.restore.deadline_milliseconds,
  'Agent phase identity receipt missed an external window deadline');
  requireCondition(agentIdentities.perform.mtime_milliseconds >= operation.start
    && agentIdentities.perform.mtime_milliseconds <= operation.complete,
  'Agent perform identity receipt falls outside live-v4 operations');
  requireCondition(agentIdentities.launch.mtime_milliseconds <= operation.start,
    'Agent launch identity receipt does not precede live-v4 operations');
  requireCondition(agentIdentities.restore.mtime_milliseconds >= operation.complete,
    'Agent restore identity receipt precedes operations-complete');
  const invocation = agentInvocation(
    spec.agent_invocation,
    expectedAgent,
    plan,
    retainedPlan,
    agentExit,
  );
  requireCondition(spec.agent_identity.launch === invocation.value.identity_handshake_path
    && agentIdentities.launch.sha256 === invocation.value.identity_handshake_sha256,
  'Agent launch process receipt is not the managed-launcher identity handshake');
  requireCondition(Array.isArray(plan.bridge.trusted_host_team_ids)
    && plan.bridge.trusted_host_team_ids.length > 0
    && plan.bridge.trusted_host_team_ids.every((teamID) => /^[A-Z0-9]{10}$/.test(teamID))
    && new Set(plan.bridge.trusted_host_team_ids).size === plan.bridge.trusted_host_team_ids.length,
  'live-v4 plan Bridge trust policy is invalid');

  requireCondition(typeof spec.integrated_cu.emitter === 'string', 'integrated-CU emitter calibration path is invalid');
  const emitterCalibration = readCalibrationEmitter(
    spec.integrated_cu.emitter,
    plan.monitor.foreground_target,
  );
  const emitter = emitterCalibration.emitter;
  validateEmitter(emitter, 'integrated-CU emitter');
  requireCondition(sameJSON(plan.monitor.foreground_controller, {
    pid: emitter.pid,
    start_identity: emitter.start_identity,
    code_signature_hash: emitter.code_signature_hash,
  }) && plan.monitor.foreground_controller_team_id === emitter.team_id,
  'integrated-CU emitter differs from the live plan');
  const performReadback = integratedReadback(spec.integrated_cu.perform_readback, 'perform', {
    nonce: events.created.execution_nonce,
    monitorID: events.created.monitor_instance_id,
    windowPath: events.perform.window_path,
    emitter,
    target: plan.monitor.foreground_target,
    deadline: events.perform.deadline_milliseconds,
    markerSHA256: operation.evidence.foreground_plan.expected_value_sha256,
  });
  const restoreReadback = integratedReadback(spec.integrated_cu.restore_readback, 'restore', {
    nonce: events.created.execution_nonce,
    monitorID: events.created.monitor_instance_id,
    windowPath: events.restore.window_path,
    emitter,
    target: plan.monitor.foreground_target,
    sentinel: plan.monitor.sentinel,
    deadline: events.restore.deadline_milliseconds,
    baselineSHA256: operation.evidence.foreground_plan.baseline_value_sha256,
  });
  requireCondition(performReadback.value.observed_at_milliseconds >= operation.start
    && performReadback.value.observed_at_milliseconds <= operation.complete,
  'integrated-CU perform readback does not overlap live-v4 operations');
  requireCondition(restoreReadback.value.observed_at_milliseconds >= operation.complete,
    'integrated-CU restore readback precedes operations-complete');

  const trace = traceReceipt(spec.agent_result);
  const corpus = agentBundleCorpus(
    spec.agent_bundles,
    invocation.value.receipt_directory,
    { ...expectedAgent, code_signature_hash: invocation.code_signature_hash },
    plan.bridge.expected_host,
    {
      authenticateBundle,
      executable_path: invocation.value.executable_path,
      executable_sha256: invocation.value.executable_sha256,
      bridge_socket: plan.bridge.socket_path,
      trusted_host_team_ids: plan.bridge.trusted_host_team_ids,
      expected_host: plan.bridge.expected_host,
    },
  );
  const readbacks = agentReadbacks(
    spec.agent_readbacks,
    expectedAgent,
    trace,
    operation,
    plan,
    corpus,
  );
  const cuPerformAt = performReadback.value.observed_at_milliseconds;
  requireCondition(readbacks.action_intervals.some((entry) => (
    entry.completed_at_milliseconds < cuPerformAt
  )) && readbacks.action_intervals.some((entry) => (
    entry.started_at_milliseconds > cuPerformAt
  )), 'Agent mutations do not prove progress both before and after integrated Computer Use');
  const report = {
    version: 1,
    passed: true,
    execution_nonce: events.created.execution_nonce,
    monitor_instance_id: events.created.monitor_instance_id,
    coordinator: {
      pid: coordinatorExit.pid,
      start_identity: coordinatorExit.start_identity,
      code_signature_hash: coordinatorLaunch.code_signature_hash,
      exit_code: coordinatorExit.exit_code,
      exit_receipt_sha256: coordinatorExit.sha256,
      invocation_sha256: coordinatorLaunch.retained.sha256,
      completed_event: 'completed',
      certification_eligible: true,
      plan_sha256: retainedPlan.sha256,
      events_sha256: events.retained.sha256,
      summary_sha256: summary.sha256,
      monitor_evidence_sha256: operation.retained.sha256,
    },
    agent: {
      pid: agentExit.pid,
      start_identity: agentExit.start_identity,
      executable_path: invocation.value.executable_path,
      executable_sha256: invocation.value.executable_sha256,
      code_signature_hash: invocation.code_signature_hash,
      exit_code: agentExit.exit_code,
      exit_receipt_sha256: agentExit.sha256,
      process_receipt_sha256: Object.fromEntries(Object.entries(agentIdentities).map(
        ([phase, identity]) => [phase, identity.sha256],
      )),
      invocation_sha256: invocation.retained.sha256,
      result_sha256: trace.retained.sha256,
      readbacks_sha256: readbacks.retained.sha256,
      mutation_families: readbacks.mutation_families,
      mapped_call_ids: readbacks.mapped_call_ids,
      signed_bundle_count: readbacks.bundle_count,
      signed_bundles: readbacks.bundles,
      semantic_readbacks: readbacks.readbacks,
      trace_entry_count: trace.trace.entries.length,
      progress_interleaving: {
        integrated_cu_perform_at_milliseconds: cuPerformAt,
        integrated_cu_perform_readback_mtime_milliseconds:
          performReadback.observation.retained_mtime_milliseconds,
        action_intervals: readbacks.action_intervals,
      },
    },
    monitor: {
      executable_path: invocation.value.monitor_executable_path,
      executable_sha256: invocation.value.monitor_executable_sha256,
      code_signature_hash: invocation.value.monitor_code_signature_hash,
    },
    integrated_cu: {
      emitter,
      calibration_sha256: emitterCalibration.retained.sha256,
      perform_readback_sha256: performReadback.retained.sha256,
      restore_readback_sha256: restoreReadback.retained.sha256,
    },
    overlap: {
      agent_started_at_milliseconds: agentExit.started_at_milliseconds,
      operations_started_at_milliseconds: operation.start,
      operations_completed_at_milliseconds: operation.complete,
      agent_completed_at_milliseconds: agentExit.completed_at_milliseconds,
      agent_covers_operation_interval: true,
    },
    externally_supplied_authority: [
      'coordinator and Agent exit receipts because their JSON outputs omit process exit status',
      'Agent phase process receipts because Agent JSON omits PID and process-start identity',
      'Agent readback evidence because executionTrace redacts values and does not link calls to signed receipt files',
      'integrated-CU emitter and semantic readbacks because integrated Computer Use emits no closed PID-generation-Team-CDHash receipt',
    ],
  };
  const written = writePrivateExclusive(outputPath, report);
  return { report, output_sha256: written.sha256 };
}

function invokedAsScript() {
  return process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
}

if (invokedAsScript()) {
  try {
    const options = parseOptions(process.argv.slice(2), ['input', 'output']);
    const result = validateConcurrentRun(options.input, options.output);
    process.stdout.write(`${JSON.stringify({ output: options.output, sha256: result.output_sha256 })}\n`);
  } catch (error) {
    process.stderr.write(`validate-concurrent-run: ${error.message}\n`);
    process.exitCode = 1;
  }
}
