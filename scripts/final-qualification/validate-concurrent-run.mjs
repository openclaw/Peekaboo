#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  aggregateSHA256 as multiTargetAggregateSHA256,
  validateSuccessfulCertificationSummary,
} from '../finalize-multi-target-certification.mjs';
import {
  HEX40,
  HEX64,
  authenticateAgentExecutionTerminalBundle,
  authenticateLiveBridgeBundle,
  authenticatedBridgeReceiptIdentity,
  canonicalBytes,
  controlledFixtureBindings,
  corroboratedObservationTime,
  decodeCanonicalBase64JSON,
  exactKeys,
  isAgentMutatingToolName,
  normalizedAgentToolName,
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
  requireUniqueAuthenticatedBridgeReceipts,
  sameJSON,
  sha256,
  validateEmitter,
  validateControlledFixtureSummary,
  validateAgentExecutionTrace,
  validateTarget,
  writePrivateExclusive,
} from './lib.mjs';

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
    'summary_path', 'summary_size', 'summary_sha256', 'certification_eligible',
  ], 'completed event');
  requireCondition(completed.certification_eligible === true
    && positiveInteger(completed.summary_size) && HEX64.test(completed.summary_sha256 ?? ''),
  'coordinator completion is not certification-eligible with an exact summary commitment');
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
    requireSingleLink: false,
  });
  const payload = bundle.value?.receipt?.payload;
  requireCondition(payload && payload.schemaVersion === 1
    && typeof payload.operation === 'string'
    && positiveInteger(payload.client?.processIdentifier)
    && positiveDecimal(payload.client?.processStartIdentity)
    && HEX40.test(payload.client?.codeSignatureHash ?? '')
    && positiveInteger(payload.startedAtUnixMilliseconds)
    && positiveInteger(payload.completedAtUnixMilliseconds)
    && payload.completedAtUnixMilliseconds > payload.startedAtUnixMilliseconds,
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
  const identity = authenticatedBridgeReceiptIdentity(payload, report, label);
  requireCondition(report?.valid === true
    && report.validator_id === 'peekaboo-bridge-receipt-validate-v1'
    && report.trust_source === 'authenticated_live_listener'
    && report.minimum_protocol_version === '1.29'
    && report.host_protocol_version === '1.31'
    && HEX40.test(report.host_source_commit ?? '')
    && report.terminal_receipt_attested === true
    && report.retention_basis === 'exported_bundle'
    && report.bundle_sha256 === bundle.sha256
    && report.operation === payload.operation
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
  return { bundle, validator, payload, report, identity };
}

function expectedBridgeOperation(family) {
  return {
    set_value: 'setValue',
    type: 'exactWindowTargetedTypeActions',
    paste: 'exactWindowTargetedTypeActions',
  }[family] ?? null;
}

function requiredTraceString(arguments_, key, label) {
  const value = arguments_?.[key];
  requireCondition(typeof value === 'string' && value.length > 0 && !value.includes('\0'),
    `${label} trace ${key} selector is missing`);
  return value;
}

function projectedSignedRequest(signed, requestCase, label) {
  const decoded = decodeCanonicalBase64JSON(
    signed.bundle.value?.canonicalRequest,
    `${label} signed canonical request`,
  ).value;
  exactKeys(decoded, ['projectedAction'], `${label} signed request`);
  exactKeys(decoded.projectedAction, ['_0'], `${label} signed projected action`);
  const projection = decoded.projectedAction._0;
  exactKeys(projection, ['request'], `${label} signed projected action payload`);
  exactKeys(projection.request, [requestCase], `${label} signed Bridge request case`);
  exactKeys(projection.request[requestCase], ['_0'], `${label} signed Bridge request payload`);
  const request = projection.request[requestCase]._0;
  requireCondition(request && typeof request === 'object' && !Array.isArray(request),
    `${label} signed Bridge request payload is malformed`);
  return request;
}

// Bind the provider-authored trace call to the listener-authenticated Bridge request. The
// readback map alone is not authority for call-ID-to-bundle correlation.
export function validateAgentTraceOperationBinding(entry, signed, family, expectedTarget, label) {
  requireCondition(entry && typeof entry.arguments === 'object' && !Array.isArray(entry.arguments),
    `${label} trace arguments are malformed`);
  if (family === 'set_value') {
    const on = requiredTraceString(entry.arguments, 'on', label);
    const snapshot = requiredTraceString(entry.arguments, 'snapshot', label);
    const request = projectedSignedRequest(signed, 'setValue', label);
    requireCondition(request.target === on && request.snapshotId === snapshot,
      `${label} trace selectors differ from the signed Bridge request`);
    return `set_value:${snapshot}:${on}`;
  }
  if (family === 'type') {
    const snapshot = requiredTraceString(entry.arguments, 'snapshot', label);
    const request = projectedSignedRequest(signed, 'exactWindowTargetedTypeActions', label);
    requireCondition(request.snapshotId === snapshot,
      `${label} trace snapshot differs from the signed Bridge request`);
    return `type:${snapshot}`;
  }
  if (family === 'paste') {
    const request = projectedSignedRequest(signed, 'exactWindowTargetedTypeActions', label);
    requireCondition(entry.arguments.pid === expectedTarget.pid
      && entry.arguments.window_id === expectedTarget.window_id
      && (request.snapshotId === undefined || request.snapshotId === null),
    `${label} exact trace target differs from the signed Bridge request target`);
    return [
      'paste',
      expectedTarget.pid,
      expectedTarget.start_identity,
      expectedTarget.window_id,
      signed.identity.request_key,
    ].join(':');
  }
  requireCondition(false, `${label} has no closed trace/request binding`);
}

export const AGENT_TASK_KIND = 'peekaboo-concurrent-agent-qualification';
export const AGENT_TASK_GOAL = 'two-target-background-mutate-verify-restore-with-concurrent-cu';
export const AGENT_TASK_CONSTRAINTS = Object.freeze({
  delivery_mode: 'background',
  foreground: 'forbidden',
  progress_interleaving: 'before-and-after-integrated-cu',
  shell: 'forbidden',
  skips_and_failures: 'forbidden',
});
export const AGENT_TASK_POSTCONDITIONS = Object.freeze({
  all_targets_restored: true,
  cleanup: 'restore-exact-baselines',
  exact_dispatched_mutation_count: 4,
  exact_target_count: 2,
  minimum_primary_mutation_family_count: 2,
  novel_restoration_family_required: true,
  target_b_distinct_restoration_family: true,
});
const AGENT_TASK_STEP_PHASES = [
  'baseline', 'mutate', 'verify-mutated', 'restore', 'verify-restored',
];

function taskExpectedValue(value, label) {
  requireCondition(typeof value === 'string' && Buffer.byteLength(value, 'utf8') <= 4096,
    `${label} expected value is invalid`);
  return value;
}

export function parseAgentTaskContract(taskReceipt, plan) {
  let fileText;
  try {
    fileText = new TextDecoder('utf-8', { fatal: true }).decode(taskReceipt.bytes);
  } catch {
    requireCondition(false, 'Agent task must be one closed UTF-8 JSON contract plus one terminal newline');
  }
  requireCondition(fileText.endsWith('\n'),
    'Agent task must be one closed UTF-8 JSON contract plus one terminal newline');
  const taskText = fileText.slice(0, -1);
  requireCondition(taskText.length > 0 && !taskText.endsWith('\n') && !taskText.includes('\0')
    && Buffer.from(`${taskText}\n`, 'utf8').equals(taskReceipt.bytes),
  'Agent task must be one closed UTF-8 JSON contract plus one terminal newline');
  let contract;
  try {
    contract = JSON.parse(taskText);
  } catch {
    requireCondition(false, 'Agent task must be one closed machine-readable JSON contract');
  }
  requireCondition(Buffer.from(taskText, 'utf8').equals(canonicalBytes(contract)),
    'Agent task must be the canonical JSON encoding of its closed contract');
  exactKeys(contract, [
    'version', 'kind', 'goal', 'constraints', 'targets', 'postconditions',
  ], 'Agent task contract');
  requireCondition(contract.version === 1 && contract.kind === AGENT_TASK_KIND,
    'Agent task contract kind/version is invalid');
  requireCondition(contract.goal === AGENT_TASK_GOAL,
    'Agent task contract goal is not the closed concurrent qualification goal');
  exactKeys(contract.constraints, Object.keys(AGENT_TASK_CONSTRAINTS),
    'Agent task contract constraints');
  requireCondition(sameJSON(contract.constraints, AGENT_TASK_CONSTRAINTS),
    'Agent task contract constraints do not require background-only, no-Shell, failure-free interleaving');
  exactKeys(contract.postconditions, Object.keys(AGENT_TASK_POSTCONDITIONS),
    'Agent task contract postconditions');
  requireCondition(sameJSON(contract.postconditions, AGENT_TASK_POSTCONDITIONS),
    'Agent task contract postconditions are not the closed restoration/cleanup contract');
  requireCondition(Array.isArray(contract.targets) && contract.targets.length === 2,
    'Agent task contract must contain exactly two controlled targets');
  const fixtureBindings = controlledFixtureBindings(plan, 'live-v4 plan').targets;
  const primaryMutationFamilies = new Set();
  const restorationFamilies = new Set();
  const targetExpectations = contract.targets.map((entry, index) => {
    const label = `target-${index === 0 ? 'a' : 'b'}`;
    exactKeys(entry, ['label', 'target', 'steps'], `Agent task contract ${label}`);
    requireCondition(entry.label === label, 'Agent task contract target order is not canonical');
    exactKeys(entry.target, ['pid', 'start_identity', 'window_id'],
      `Agent task contract ${label}.target`);
    requireCondition(positiveInteger(entry.target.pid)
      && positiveDecimal(entry.target.start_identity)
      && positiveInteger(entry.target.window_id),
    `Agent task contract ${label} target is malformed`);
    requireCondition(sameJSON(entry.target, fixtureBindings[index].target),
      `Agent task contract ${label} is not its exact live-v4 controlled fixture target`);
    requireCondition(Array.isArray(entry.steps) && entry.steps.length === 5,
      `Agent task contract ${label} must contain baseline/mutate/verify/restore/verify`);
    const [baseline, mutation, mutationVerification, restoration, restorationVerification]
      = entry.steps;
    for (const [stepIndex, step] of entry.steps.entries()) {
      const mutating = stepIndex === 1 || stepIndex === 3;
      exactKeys(step, mutating ? ['phase', 'family', 'expected_value'] : ['phase', 'expected_value'],
        `Agent task contract ${label}.steps[${stepIndex}]`);
      requireCondition(step.phase === AGENT_TASK_STEP_PHASES[stepIndex],
        `Agent task contract ${label} step order is not baseline/mutate/verify/restore/verify`);
      taskExpectedValue(step.expected_value,
        `Agent task contract ${label}.steps[${stepIndex}]`);
    }
    for (const [step, kind] of [[mutation, 'mutation'], [restoration, 'restoration']]) {
      requireCondition(step.family === normalizedAgentToolName(step.family)
        && expectedBridgeOperation(step.family) !== null,
      `Agent task contract ${label} ${kind} family is unsupported`);
    }
    requireCondition(mutation.expected_value !== baseline.expected_value
      && mutationVerification.expected_value === mutation.expected_value,
    `Agent task contract ${label} mutated value/postcondition is inconsistent`);
    requireCondition(restoration.expected_value === baseline.expected_value
      && restorationVerification.expected_value === baseline.expected_value,
    `Agent task contract ${label} restoration does not require the exact baseline`);
    primaryMutationFamilies.add(mutation.family);
    restorationFamilies.add(restoration.family);
    if (label === 'target-b') {
      requireCondition(restoration.family !== mutation.family,
        'Agent task contract target-b restoration family must differ from its primary mutation');
    }
    return {
      label,
      target: structuredClone(entry.target),
      baseline_value: baseline.expected_value,
      mutation: { family: mutation.family, expected_value: mutation.expected_value },
      restoration: { family: restoration.family, expected_value: restoration.expected_value },
    };
  });
  requireCondition(primaryMutationFamilies.size >= 2,
    'Agent task contract must require two primary mutation families');
  requireCondition([...restorationFamilies].some((family) => !primaryMutationFamilies.has(family)),
    'Agent task contract must require a restoration family outside the primary mutations');
  return {
    receipt: taskReceipt,
    text: taskText,
    contract,
    semantic_sha256: sha256(canonicalBytes(contract)),
    target_expectations: targetExpectations,
  };
}

export function projectAgentTaskContractReport(taskContract, terminal) {
  const signedTaskSHA256 = sha256(Buffer.from(taskContract.text, 'utf8'));
  requireCondition(terminal.response.taskSHA256 === signedTaskSHA256,
    'signed terminal task digest differs from the Agent task contract');
  return {
    version: 1,
    kind: taskContract.contract.kind,
    goal: taskContract.contract.goal,
    task_file_sha256: taskContract.receipt.sha256,
    signed_task_sha256: signedTaskSHA256,
    semantic_contract_sha256: taskContract.semantic_sha256,
    constraints: structuredClone(taskContract.contract.constraints),
    postconditions: structuredClone(taskContract.contract.postconditions),
    target_expectations: taskContract.target_expectations.map((entry) => ({
      label: entry.label,
      target: structuredClone(entry.target),
      baseline_value_sha256: sha256(Buffer.from(entry.baseline_value, 'utf8')),
      mutation_family: entry.mutation.family,
      mutated_value_sha256: sha256(Buffer.from(entry.mutation.expected_value, 'utf8')),
      restoration_family: entry.restoration.family,
      restored_value_sha256: sha256(Buffer.from(entry.restoration.expected_value, 'utf8')),
    })),
  };
}

function agentBundleCorpus(
  entries,
  receiptDirectory,
  expectedAgent,
  expectedHost,
  expectedListenerInstanceID,
  lifetime,
  authentication,
) {
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
  const authenticatedEntries = entries.map((entry, index) => {
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
      && signed.report.listener_instance_id === expectedListenerInstanceID,
    `Agent bundle ${index} belongs to another live listener`);
    requireCondition(signed.payload.startedAtUnixMilliseconds >= lifetime.released_at_milliseconds
      && signed.payload.completedAtUnixMilliseconds <= lifetime.terminal_observation_ended_at_milliseconds,
    `Agent bundle ${index} falls outside the signed Agent lifetime`);
    listenerIDs.add(signed.report.listener_instance_id);
    return signed;
  });
  requireUniqueAuthenticatedBridgeReceipts(authenticatedEntries, 'Agent bundle corpus');
  requireCondition(authenticatedEntries.every((entry) => entry.bundle.info.nlink === 1n),
    'Agent bundle corpus contains a hard-linked receipt');
  requireCondition(listenerIDs.size === 1,
    'Agent bundle corpus spans more than one live listener instance');
  const corpus = new Map(entries.map((entry, index) => (
    [entry.bundle_path, authenticatedEntries[index]]
  )));
  return corpus;
}

function agentReadbacks(filePath, agent, trace, operation, plan, corpus, taskContract) {
  const retained = readStableJSON(filePath, 'Agent readback evidence');
  const value = retained.value;
  exactKeys(value, ['version', 'agent', 'targets'], 'Agent readback evidence');
  requireCondition(value.version === 1, 'Agent readback evidence version is not 1');
  exactKeys(value.agent, ['pid', 'start_identity'], 'Agent readback agent');
  requireCondition(sameJSON(value.agent, { pid: agent.pid, start_identity: agent.start_identity }),
    'Agent readback evidence belongs to another process generation');
  requireCondition(Array.isArray(value.targets) && value.targets.length === 2,
    'Agent readback evidence needs exactly two targets');
  const fixtureBindings = controlledFixtureBindings(plan, 'live-v4 plan').targets;
  const forbiddenProcesses = new Set([
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
  const orderedActionCallIDs = [];
  const traceRequestBindings = new Set();
  for (const [index, target] of value.targets.entries()) {
    exactKeys(target, [
      'label', 'target', 'baseline_readback_path', 'mutation', 'restoration',
    ], `Agent readback target ${index}`);
    requireCondition(target.label === `target-${index === 0 ? 'a' : 'b'}`,
      'Agent readback target order is not canonical');
    exactKeys(target.target, ['pid', 'start_identity', 'window_id'], `Agent readback ${target.label}.target`);
    requireCondition(positiveInteger(target.target.pid) && positiveDecimal(target.target.start_identity)
      && positiveInteger(target.target.window_id), `Agent readback ${target.label} identity is invalid`);
    requireCondition(sameJSON(target.target, fixtureBindings[index].target),
      `Agent ${target.label} is not its exact live-v4 controlled fixture target`);
    const taskExpectation = taskContract.target_expectations[index];
    requireCondition(taskExpectation.label === target.label
      && sameJSON(taskExpectation.target, target.target),
    `Agent ${target.label} readback map differs from its signed task contract`);
    const processKey = `${target.target.pid}:${target.target.start_identity}`;
    targetProcesses.add(processKey);
    targetWindows.add(`${processKey}:${target.target.window_id}`);
    requireCondition(!forbiddenProcesses.has(processKey),
      `Agent ${target.label} aliases Bridge/observer/foreground/sentinel infrastructure`);
    const baseline = semanticReadback(
      target.baseline_readback_path,
      target.target,
      'baseline',
      operation,
      `Agent ${target.label} baseline readback`,
    );
    requireCondition(baseline.value.value === taskExpectation.baseline_value,
      `Agent ${target.label} baseline differs from its signed task expectation`);
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
      requireCondition(action.family === normalizedAgentToolName(action.family)
        && isAgentMutatingToolName(action.family), `Agent readback ${target.label}.${kind} family is invalid`);
      const taskAction = taskExpectation[kind];
      requireCondition(action.family === taskAction.family,
        `Agent readback ${target.label}.${kind} family differs from its signed task contract`);
      requireCondition(entry && normalizedAgentToolName(entry.name) === action.family,
        `Agent readback ${target.label}.${kind} does not match its trace family`);
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
      const traceRequestBinding = validateAgentTraceOperationBinding(
        entry,
        signed,
        action.family,
        target.target,
        `Agent ${target.label}.${kind}`,
      );
      requireCondition(!traceRequestBindings.has(traceRequestBinding),
        `Agent ${target.label}.${kind} reuses a trace/request binding`);
      traceRequestBindings.add(traceRequestBinding);
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
      requireCondition(readback.value.value === taskAction.expected_value,
        `Agent ${target.label}.${kind} readback differs from its signed task expected value`);
      requireCondition(signed.payload.completedAtUnixMilliseconds < readback.value.observed_at_milliseconds,
        `Agent ${target.label}.${kind} readback does not strictly follow its signed dispatch`);
      readbackReceipts.push(readback);
      actionReceipts[kind] = { action, signed, readback };
      actionIntervals.push({
        trace_call_id: action.trace_call_id,
        started_at_milliseconds: signed.payload.startedAtUnixMilliseconds,
        completed_at_milliseconds: signed.payload.completedAtUnixMilliseconds,
      });
      orderedActionCallIDs.push(action.trace_call_id);
    }
    requireCondition(actionReceipts.mutation.readback.value.value !== baseline.value.value,
      `Agent ${target.label} mutation did not change the baseline`);
    requireCondition(actionReceipts.restoration.readback.value.value === baseline.value.value,
      `Agent ${target.label} restoration did not restore the baseline`);
    requireCondition(
      baseline.value.observed_at_milliseconds
        < actionReceipts.mutation.signed.payload.startedAtUnixMilliseconds
      && actionReceipts.mutation.signed.payload.completedAtUnixMilliseconds
        < actionReceipts.mutation.readback.value.observed_at_milliseconds
      && actionReceipts.mutation.readback.value.observed_at_milliseconds
        < actionReceipts.restoration.signed.payload.startedAtUnixMilliseconds
      && actionReceipts.restoration.signed.payload.completedAtUnixMilliseconds
        < actionReceipts.restoration.readback.value.observed_at_milliseconds
      && actionReceipts.mutation.signed.payload.completedAtUnixMilliseconds
        < actionReceipts.restoration.signed.payload.startedAtUnixMilliseconds
      && actionReceipts.mutation.readback.value.observed_at_milliseconds
        < actionReceipts.restoration.readback.value.observed_at_milliseconds,
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
  requireCondition(orderedActionCallIDs.every((callID, index) => index === 0
    || trace.entryIndexByID.get(orderedActionCallIDs[index - 1])
      < trace.entryIndexByID.get(callID)),
  'Agent trace does not follow the signed target-a then target-b mutate/restore task order');
  requireCondition(actionIntervals.every((entry, index) => index === 0
    || actionIntervals[index - 1].completed_at_milliseconds
      < entry.started_at_milliseconds),
  'Agent signed mutation intervals do not follow the task action order');
  for (const [bundlePath, item] of corpus.entries()) {
    if (usedBundlePaths.has(bundlePath)) continue;
    requireCondition(item.payload.outcome?.mutation_dispatched !== true
      && item.payload.outcome?.dispatch_state !== 'dispatched',
    'Agent corpus contains an unmapped dispatched mutation bundle');
  }
  return {
    retained,
    value,
    controlled_fixture_targets: fixtureBindings,
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

function validateCoordinatorLaunchEnvironment(value) {
  requireCondition(value.environment_policy_version === 1
    && Array.isArray(value.environment_keys) && value.environment_keys.length > 0
    && value.environment_keys.every((key) => typeof key === 'string' && key.length > 0)
    && new Set(value.environment_keys).size === value.environment_keys.length
    && value.environment_keys.every((key, index) => index === 0
      || value.environment_keys[index - 1] < key)
    && HEX64.test(value.environment_sha256 ?? ''),
  'coordinator invocation environment receipt is malformed');
  requireCondition(value.environment_keys.every((key) => COMMON_LAUNCH_ENVIRONMENT_KEYS.includes(key))
    && value.environment_keys.includes('PATH')
    && !value.environment_keys.some((key) => key === 'NODE_OPTIONS' || key.startsWith('DYLD_')),
  'coordinator invocation environment exceeds the closed allowlist');
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
    'coordinator_source_sha256', 'execution_source_sha256', 'execution_plan_sha256',
    'execution_staged',
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
  requireCondition(value.execution_staged === true
    && value.execution_source_sha256 === source.sha256
    && value.execution_plan_sha256 === planReceipt.sha256,
  'coordinator execution staging differs from its retained source/plan bytes');
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
  validateCoordinatorLaunchEnvironment(value);
  return { retained, value, code_signature_hash: codeSignatureHash };
}

export function validateCoordinatorExecutionEvidence({
  plan,
  planReceipt,
  invocationPath,
  eventsPath,
  exitPath,
}) {
  const events = coordinatorEvents(eventsPath);
  const exit = exitReceipt(exitPath, 'coordinator');
  requireCondition(exit.started_at_milliseconds
    <= Number(events.retained.info.mtimeNs / 1_000_000n)
    && exit.completed_at_milliseconds
      >= Number(events.retained.info.mtimeNs / 1_000_000n),
  'coordinator exit interval does not contain its JSONL evidence');
  const invocation = coordinatorInvocation(
    invocationPath,
    { pid: exit.pid, start_identity: exit.start_identity },
    plan,
    planReceipt,
    eventsPath,
    exit,
  );
  return { events, exit, invocation };
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

export function validateConcurrentRunSpec(spec, outputPath, {
  authenticateBundle = authenticateLiveBridgeBundle,
} = {}) {
  exactKeys(spec, [
    'version', 'plan', 'coordinator_invocation', 'coordinator_events', 'coordinator_exit',
    'agent_task', 'agent_run_root', 'agent_execution_bundle',
    'agent_execution_validator_report', 'agent_bundles', 'agent_readbacks', 'integrated_cu',
  ], 'concurrent validation input');
  requireCondition(spec.version === 1, 'concurrent validation input version is not 1');
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
  const coordinatorAuthority = validateCoordinatorExecutionEvidence({
    plan,
    planReceipt: retainedPlan,
    invocationPath: spec.coordinator_invocation,
    eventsPath: spec.coordinator_events,
    exitPath: spec.coordinator_exit,
  });
  const {
    events,
    exit: coordinatorExit,
    invocation: coordinatorLaunch,
  } = coordinatorAuthority;
  const summary = readStableJSON(events.completed.summary_path, 'final certification summary');
  requireCondition(summary.bytes.length === events.completed.summary_size
    && summary.sha256 === events.completed.summary_sha256,
  'final certification summary differs from the coordinator completion commitment');
  validateSuccessfulCertificationSummary(summary.value, 'final certification summary');
  validateControlledFixtureSummary(
    summary,
    controlledFixtureBindings(plan, 'live-v4 plan'),
    'final certification summary',
  );
  const operation = operationInterval(
    events.created.run_root,
    events.created.execution_nonce,
    events.created.monitor_instance_id,
  );
  requireCondition(summary.value.monitor_evidence_sha256
    === multiTargetAggregateSHA256('monitor-evidence', operation.evidence),
  'final certification summary belongs to another monitor run');
  requireCondition(operation.start < events.perform.deadline_milliseconds, 'perform deadline precedes operations-start');
  requireCondition(operation.complete < events.restore.deadline_milliseconds, 'restore deadline precedes operations-complete');

  requireCondition(Array.isArray(plan.bridge.trusted_host_team_ids)
    && plan.bridge.trusted_host_team_ids.length > 0
    && plan.bridge.trusted_host_team_ids.every((teamID) => /^[A-Z0-9]{10}$/.test(teamID))
    && new Set(plan.bridge.trusted_host_team_ids).size === plan.bridge.trusted_host_team_ids.length,
  'live-v4 plan Bridge trust policy is invalid');
  requirePrivateDirectory(spec.agent_run_root, 'Agent execution run root');
  const agentTask = parseAgentTaskContract(
    readStableFile(spec.agent_task, 'Agent task'),
    plan,
  );
  const taskText = agentTask.text;
  const agentExecutable = requireStableExecutable(plan.peekaboo_executable, 'Agent executable', {
    allowRootOwner: true,
  });
  const expectedAgentRequest = {
    task: taskText,
    maxSteps: 40,
    runRootPath: spec.agent_run_root,
    coordinationReceiptPath: path.join(spec.agent_run_root, 'agent-execution-coordination.json'),
    acknowledgementPath: path.join(spec.agent_run_root, 'agent-execution-ack.json'),
    startTimeoutMilliseconds: 30_000,
    runTimeoutMilliseconds: 900_000,
  };
  const terminal = authenticateAgentExecutionTerminalBundle({
    bundlePath: spec.agent_execution_bundle,
    validatorReportPath: spec.agent_execution_validator_report,
    executablePath: agentExecutable.path,
    expectedExecutableSHA256: agentExecutable.sha256,
    socketPath: plan.bridge.socket_path,
    trustedHostTeamIDs: plan.bridge.trusted_host_team_ids,
    expectedHost: plan.bridge.expected_host,
    expectedRequest: expectedAgentRequest,
    authenticateBundle,
  });
  const expectedAgent = {
    pid: terminal.child.processIdentifier,
    start_identity: terminal.child.processStartIdentity,
    code_signature_hash: terminal.child.codeSignatureHash,
  };
  const requestingPeer = {
    pid: terminal.requester.processIdentifier,
    start_identity: terminal.requester.processStartIdentity,
    code_signature_hash: terminal.requester.codeSignatureHash,
  };
  requireCondition(terminal.response.releasedAt <= operation.start
    && terminal.response.terminalObservationEndedAt >= operation.complete,
  'signed Agent lifetime does not cover the complete live-v4 operation interval');

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

  const trace = validateAgentExecutionTrace(terminal.stdoutRoot);
  const corpus = agentBundleCorpus(
    spec.agent_bundles,
    terminal.response.operationReceiptDirectoryPath,
    expectedAgent,
    plan.bridge.expected_host,
    terminal.identity.listener_instance_id,
    {
      released_at_milliseconds: terminal.response.releasedAt,
      terminal_observation_ended_at_milliseconds: terminal.response.terminalObservationEndedAt,
    },
    {
      authenticateBundle,
      executable_path: agentExecutable.path,
      executable_sha256: agentExecutable.sha256,
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
    agentTask,
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
      pid: expectedAgent.pid,
      start_identity: expectedAgent.start_identity,
      code_signature_hash: expectedAgent.code_signature_hash,
      requester: requestingPeer,
      run_root: terminal.response.runRootPath,
      acknowledgement_path: terminal.response.acknowledgementPath,
      executable_path: terminal.process.executablePath,
      executable_sha256: terminal.process.executableSHA256,
      terminal_bundle_sha256: terminal.bundle.sha256,
      terminal_validator_report_sha256: terminal.validator.sha256,
      listener_instance_id: terminal.identity.listener_instance_id,
      process_disposition: terminal.response.processDisposition,
      output_disposition: terminal.response.outputDisposition,
      stdout_sha256: terminal.stdout.value.sha256,
      stderr_sha256: terminal.stderr.value.sha256,
      coordination_receipt_sha256: terminal.coordinationReceipt.value.sha256,
      acknowledgement_sha256: terminal.acknowledgement.value.sha256,
      spawned_at_milliseconds: terminal.response.spawnedAt,
      coordination_published_at_milliseconds: terminal.response.coordinationReceiptPublishedAt,
      acknowledged_at_milliseconds: terminal.response.acknowledgedAt,
      released_at_milliseconds: terminal.response.releasedAt,
      terminal_observation_ended_at_milliseconds: terminal.response.terminalObservationEndedAt,
      task_contract: projectAgentTaskContractReport(agentTask, terminal),
      readbacks_sha256: readbacks.retained.sha256,
      controlled_fixture_targets: readbacks.controlled_fixture_targets,
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
      executable_path: coordinatorLaunch.value.monitor_executable_path,
      executable_sha256: coordinatorLaunch.value.monitor_executable_sha256,
      code_signature_hash: coordinatorLaunch.value.monitor_code_signature_hash,
    },
    integrated_cu: {
      emitter,
      calibration_sha256: emitterCalibration.retained.sha256,
      perform_readback_sha256: performReadback.retained.sha256,
      restore_readback_sha256: restoreReadback.retained.sha256,
    },
    overlap: {
      agent_started_at_milliseconds: terminal.response.spawnedAt,
      operations_started_at_milliseconds: operation.start,
      operations_completed_at_milliseconds: operation.complete,
      agent_completed_at_milliseconds: terminal.response.terminalObservationEndedAt,
      agent_covers_operation_interval: true,
    },
    externally_supplied_authority: [
      'coordinator invocation and exit receipts because its JSONL output omits process authority',
      'listener-signed Agent terminal bundle for exact requester/child, policy, output, release, and exit authority',
      'Agent readback evidence because executionTrace redacts values and does not link calls to signed receipt files',
      'integrated-CU emitter and semantic readbacks because integrated Computer Use emits no closed PID-generation-Team-CDHash receipt',
    ],
  };
  const written = writePrivateExclusive(outputPath, report);
  return { report, output_sha256: written.sha256 };
}

export function validateConcurrentRun(specPath, outputPath, options = {}) {
  const spec = readStableJSON(specPath, 'concurrent validation input').value;
  return validateConcurrentRunSpec(spec, outputPath, options);
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
