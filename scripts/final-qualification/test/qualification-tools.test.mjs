import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { projectBindings } from '../project-live-bindings.mjs';
import { constructLivePlan } from '../construct-live-plan.mjs';
import { compareCrashInventories } from '../crash-inventory.mjs';
import { runManagedLaunch } from '../managed-launcher.mjs';
import { classifyPolicyFile } from '../executable-policy-scanner.mjs';
import {
  accumulateDescendantPIDs,
  isFinalProcessTableSample,
  validateRepeatedExecutable,
  validateRepeatedObservation,
  validateSampleGap,
} from '../process-tree-collector.mjs';
import { publishCoordinatorMarker } from '../publish-coordinator-marker.mjs';
import {
  constructPlaygroundAlertLifecycle,
  PLAYGROUND_AX_SEE_BUDGET_MILLISECONDS,
  PLAYGROUND_OVERALL_SEE_BUDGET_MILLISECONDS,
  validatePlaygroundAlertLifecycle,
} from '../playground-alert-lifecycle.mjs';
import {
  generateManifest as generateManifestProduction,
  generateSourceManifest,
  verifyManifest as verifyManifestProduction,
  verifySourceManifest,
} from '../qualification-manifest.mjs';
import {
  validateAgentTraceOperationBinding,
  validateConcurrentRun as validateConcurrentRunProduction,
} from '../validate-concurrent-run.mjs';
import { aggregateSHA256 as multiTargetAggregateSHA256 } from '../../finalize-multi-target-certification.mjs';
import {
  aggregateSHA256,
  canonicalBytes,
  publishPrivateAtomicNoReplace,
  sha256,
} from '../lib.mjs';

const TEAM = 'FWJYW4S8P8';
const OPENCLAW_SOURCE = '9'.repeat(40);
const CDHASH = 'b'.repeat(40);
const PLAYGROUND_CDHASH = '5'.repeat(40);
const UUID = '12345678-1234-4abc-8def-123456789abc';
const SESSION_ID = '22345678-1234-4abc-8def-123456789abc';
const NONCE = 'c'.repeat(64);
const LOCAL_UUID = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
const STUDIO_UUID = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB';
const sourceToolRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const sourceRepositoryRoot = path.dirname(path.dirname(sourceToolRoot));
const qualificationSourceFiles = [
  'scripts/finalize-multi-target-certification.mjs',
  'scripts/run-live-multi-target-certification.mjs',
  'scripts/test-background-computer-use.sh',
  'scripts/final-qualification/README.md',
  'scripts/final-qualification/atomic-publish-no-replace.swift',
  'scripts/final-qualification/construct-live-plan.mjs',
  'scripts/final-qualification/crash-inventory.mjs',
  'scripts/final-qualification/executable-policy-scanner.mjs',
  'scripts/final-qualification/integrated-cu-emitter-calibrator.swift',
  'scripts/final-qualification/managed-launch-suspended.c',
  'scripts/final-qualification/lib.mjs',
  'scripts/final-qualification/managed-launcher.mjs',
  'scripts/final-qualification/project-live-bindings.mjs',
  'scripts/final-qualification/process-lifecycle-guard.c',
  'scripts/final-qualification/process-tree-collector.mjs',
  'scripts/final-qualification/playground-alert-lifecycle.mjs',
  'scripts/final-qualification/publish-agent-execution-acknowledgement.mjs',
  'scripts/final-qualification/publish-coordinator-marker.mjs',
  'scripts/final-qualification/qualification-manifest.mjs',
  'scripts/final-qualification/validate-concurrent-run.mjs',
  'scripts/final-qualification/test/qualification-tools.test.mjs',
  'scripts/multi-target-certification-catalog.json',
  'scripts/support/background-computer-use-probe.swift',
];
const qualificationRepositoryRoot = fs.mkdtempSync('/private/tmp/pbq-source-repository-');
fs.chmodSync(qualificationRepositoryRoot, 0o700);
fs.mkdirSync(path.join(qualificationRepositoryRoot, 'scripts'), { recursive: true });
fs.cpSync(sourceToolRoot, path.join(qualificationRepositoryRoot, 'scripts/final-qualification'), {
  recursive: true,
});
fs.mkdirSync(path.join(qualificationRepositoryRoot, 'scripts/support'), { recursive: true });
fs.copyFileSync(
  path.join(sourceRepositoryRoot, 'scripts/finalize-multi-target-certification.mjs'),
  path.join(qualificationRepositoryRoot, 'scripts/finalize-multi-target-certification.mjs'),
);
fs.copyFileSync(
  path.join(sourceRepositoryRoot, 'scripts/run-live-multi-target-certification.mjs'),
  path.join(qualificationRepositoryRoot, 'scripts/run-live-multi-target-certification.mjs'),
);
fs.copyFileSync(
  path.join(sourceRepositoryRoot, 'scripts/test-background-computer-use.sh'),
  path.join(qualificationRepositoryRoot, 'scripts/test-background-computer-use.sh'),
);
fs.copyFileSync(
  path.join(sourceRepositoryRoot, 'scripts/support/background-computer-use-probe.swift'),
  path.join(qualificationRepositoryRoot, 'scripts/support/background-computer-use-probe.swift'),
);
fs.copyFileSync(
  path.join(sourceRepositoryRoot, 'scripts/multi-target-certification-catalog.json'),
  path.join(qualificationRepositoryRoot, 'scripts/multi-target-certification-catalog.json'),
);
for (const arguments_ of [
  ['init', '--quiet'],
  ['config', 'user.name', 'Qualification Fixture'],
  ['config', 'user.email', 'qualification@example.invalid'],
  ['add', '--all'],
  ['commit', '--quiet', '-m', 'fixture'],
]) {
  const result = spawnSync('/usr/bin/git', ['-C', qualificationRepositoryRoot, ...arguments_], {
    encoding: 'utf8',
    env: {
      PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
      LANG: 'C',
      LC_ALL: 'C',
      GIT_AUTHOR_DATE: '2000-01-01T00:00:00Z',
      GIT_COMMITTER_DATE: '2000-01-01T00:00:00Z',
    },
  });
  assert.equal(result.status, 0, result.stderr);
}
const SOURCE = spawnSync(
  '/usr/bin/git',
  ['-C', qualificationRepositoryRoot, 'rev-parse', 'HEAD'],
  { encoding: 'utf8' },
).stdout.trim();
const toolRoot = path.join(qualificationRepositoryRoot, 'scripts/final-qualification');
process.on('exit', () => fs.rmSync(qualificationRepositoryRoot, { recursive: true, force: true }));

function fixtureAuthenticatedBundle({ bundlePath, expectedHost }) {
  const bytes = fs.readFileSync(bundlePath);
  const payload = JSON.parse(bytes).receipt.payload;
  return {
    valid: true,
    validator_id: 'peekaboo-bridge-receipt-validate-v1',
    trust_source: 'authenticated_live_listener',
    minimum_protocol_version: '1.29',
    request_id: String(payload.requestID).toLowerCase(),
    session_id: String(payload.sessionID).toLowerCase(),
    session_sequence: payload.sessionSequence,
    operation: payload.operation,
    listener_instance_id: String(payload.listenerInstanceID).toLowerCase(),
    client_instance_id: String(payload.clientInstanceID).toLowerCase(),
    host: {
      pid: expectedHost.process_identifier,
      start_identity: expectedHost.process_start_identity_decimal,
      code_signature_hash: expectedHost.code_signature_hash,
    },
    client: {
      pid: payload.client.processIdentifier,
      start_identity: payload.client.processStartIdentity,
      code_signature_hash: payload.client.codeSignatureHash,
    },
    host_source_commit: expectedHost.source_commit,
    host_protocol_version: '1.31',
    ...(payload.listenerPublicKeySHA256 === undefined ? {} : {
      listener_public_key_sha256: payload.listenerPublicKeySHA256,
      request_sha256: payload.requestSHA256,
      response_sha256: payload.responseSHA256,
    }),
    bundle_sha256: sha256(bytes),
    terminal_receipt_attested: true,
    target_attested: payload.target !== null,
    outcome_attested: payload.outcome !== undefined,
    retention_basis: 'exported_bundle',
  };
}

function validateConcurrentRun(specPath, outputPath) {
  return validateConcurrentRunProduction(specPath, outputPath, {
    authenticateBundle: fixtureAuthenticatedBundle,
  });
}

function generateManifest(inputPath, outputPath) {
  return generateManifestProduction(inputPath, outputPath, {
    authenticateBundle: fixtureAuthenticatedBundle,
  });
}

function verifyManifest(manifestPath) {
  return verifyManifestProduction(manifestPath, {
    authenticateBundle: fixtureAuthenticatedBundle,
  });
}

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

function launchEnvironment(kind, receiptDirectory = null) {
  const environment = { HOME: '/private/tmp/fixture-home', PATH: '/usr/bin:/bin:/usr/sbin:/sbin' };
  if (kind === 'agent') environment.PEEKABOO_OPERATION_RECEIPT_DIRECTORY = receiptDirectory;
  const environmentKeys = Object.keys(environment).sort();
  return {
    environment_policy_version: 1,
    environment_keys: environmentKeys,
    environment_sha256: sha256(canonicalBytes(environment)),
  };
}

function certificationSummaryFixture(monitorEvidence, planControllers) {
  const digest = '7'.repeat(64);
  const catalogDigest = sha256(fs.readFileSync(
    path.join(sourceRepositoryRoot, 'scripts/multi-target-certification-catalog.json'),
  ));
  const digestSpecDigest = sha256(fs.readFileSync(
    path.join(sourceRepositoryRoot, 'scripts/multi-target-digest-spec.json'),
  ));
  const host = { pid: 200, start_identity: '200001', code_signature_hash: 'd'.repeat(40) };
  assert.equal(planControllers.length, 2);
  const requestIDs = [
    '12345678-1234-8abc-8def-123456789ab1',
    '12345678-1234-8abc-8def-123456789ab4',
  ];
  const sessionIDs = [
    '12345678-1234-4abc-8def-123456789ab2',
    '12345678-1234-4abc-8def-123456789ab5',
  ];
  const clientInstanceIDs = [
    '12345678-1234-4abc-8def-123456789ab3',
    '12345678-1234-4abc-8def-123456789ab6',
  ];
  const rows = planControllers.map((entry, index) => ({
    slotID: `slot-${index + 1}`,
    operationID: `operation-${index + 1}`,
    controllerID: entry.controller_id,
    targetID: entry.target_id,
    requestID: requestIDs[index],
    sessionID: sessionIDs[index],
    clientInstanceID: clientInstanceIDs[index],
    controller: {
      pid: 901 + index,
      start_identity: `${901 + index}001`,
      code_signature_hash: CDHASH,
    },
    target: {
      scope: 'window',
      pid: entry.target.process_identifier,
      start_identity: entry.target.process_start_identity_decimal,
      window_id: entry.target.window_id,
      bounds: structuredClone(entry.target.bounds),
      is_minimized: entry.target.is_minimized,
    },
    interval: {
      started_at_milliseconds: 1 + (index * 2),
      completed_at_milliseconds: 2 + (index * 2),
    },
  }));
  const firstPartyVerdicts = rows.map((row) => ({
    slot_id: row.slotID,
    bundle_file: `${row.slotID}.json`,
    file_sha256: digest,
    verdict: {
      valid: true,
      validator_id: 'peekaboo-bridge-receipt-validate-v1',
      trust_source: 'authenticated_live_listener',
      minimum_protocol_version: '1.29',
      host_protocol_version: '1.31',
      request_id: row.requestID,
      session_id: row.sessionID,
      session_sequence: '0',
      predecessor_session_id: null,
      operation: 'listWindows',
      listener_instance_id: UUID,
      listener_public_key_sha256: digest,
      host,
      client_instance_id: row.clientInstanceID,
      host_source_commit: SOURCE,
      client: row.controller,
      request_sha256: digest,
      response_sha256: digest,
      bundle_sha256: digest,
      terminal_receipt_attested: true,
      target_attested: true,
      outcome_attested: false,
      retention_basis: 'exported_bundle',
    },
  }));
  const offlineReceipts = rows.map((row) => ({
    slot_id: row.slotID,
    operation_id: row.operationID,
    request_id: row.requestID,
    session_id: row.sessionID,
    session_sequence: '0',
    operation: 'listWindows',
    controller_id: row.controllerID,
    target_id: row.targetID,
    target: row.target,
    interval: row.interval,
    source: {
      protocol_source_commit: SOURCE,
      host_source_commit: SOURCE,
      listener_instance_id: UUID,
      host,
    },
    expected_outcome: null,
    request_sha256: digest,
    response_sha256: digest,
    file: `${row.slotID}.json`,
    file_sha256: digest,
  }));
  const offlineProtocolValidation = {
    version: 3,
    success: true,
    contract_sha256: digest,
    operation_manifest_sha256: digest,
    receipts: offlineReceipts,
    failures: [],
  };
  const summaryCore = {
    version: 2,
    certification_kind: 'live-physical',
    claim_scope: 'multi-target-background-with-attributed-foreground-overlap',
    authority: 'display-only-rerun-finalize-for-authoritative-result',
    structural_validation_passed: true,
    certification_run_id: 'multi-target-12345678-1234-4abc-8def-123456789abc',
    run_binding_sha256: digest,
    digest_spec_sha256: digestSpecDigest,
    catalog_file_sha256: catalogDigest,
    contract_sha256: digest,
    operation_manifest_sha256: digest,
    sanitized_raw_evidence_sha256: digest,
    monitor_evidence_sha256: multiTargetAggregateSHA256(
      'monitor-evidence', monitorEvidence,
    ),
    monitor_history_commitment_sha256: digest,
    monitor_baseline_commitment_sha256: digest,
    foreground_postcondition_sha256: digest,
    foreground_task_postcondition_passed: true,
    raw_bundle_inventory_sha256: digest,
    first_party_verdict_set_sha256: multiTargetAggregateSHA256(
      'first-party-verdict-set', firstPartyVerdicts,
    ),
    first_party_verdicts: firstPartyVerdicts,
    offline_protocol_validation_sha256: multiTargetAggregateSHA256(
      'offline-protocol-validation', offlineProtocolValidation,
    ),
    target_count: 2,
    slot_count: rows.length,
    controlled_targets: rows.map((row) => ({
      id: row.targetID,
      controller_id: row.controllerID,
      controller_sha256: multiTargetAggregateSHA256('controller', row.controller),
      target_sha256: multiTargetAggregateSHA256('controlled-target', row.target),
    })),
    slot_verdicts: rows.map((row, index) => ({
      slot_id: row.slotID,
      operation_id: row.operationID,
      manifest_slot_sha256: digest,
      request_id: row.requestID,
      session_id: row.sessionID,
      session_sequence: '0',
      bundle_sha256: digest,
      first_party_verdict_sha256: multiTargetAggregateSHA256(
        'first-party-verdict', firstPartyVerdicts[index],
      ),
      offline_receipt_sha256: multiTargetAggregateSHA256(
        'offline-receipt', offlineReceipts[index],
      ),
      passed: true,
    })),
    offline_protocol_validation: offlineProtocolValidation,
    failures: [],
  };
  return {
    ...summaryCore,
    summary_core_sha256: multiTargetAggregateSHA256('summary-core', summaryCore),
  };
}

function updateCoordinatorSummaryCommitment(eventsPath, summaryPath) {
  const events = fs.readFileSync(eventsPath, 'utf8').trim().split('\n').map(JSON.parse);
  const summary = fs.readFileSync(summaryPath);
  events.at(-1).summary_size = summary.length;
  events.at(-1).summary_sha256 = sha256(summary);
  writeFile(eventsPath, `${events.map(JSON.stringify).join('\n')}\n`);
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
    openclaw_source_commit: OPENCLAW_SOURCE,
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
  lifecycleGuardSHA256 = sha256(fs.readFileSync(path.join(toolRoot, 'process-lifecycle-guard.c'))),
  lifecycleGuardBinarySHA256 = '1'.repeat(64),
  forbiddenName = null,
  forbiddenRoot = false,
  orphan = false,
  processBindings = {},
  coverage = null,
  monitorExecutable = '/usr/bin/true',
} = {}) {
  const requiredClasses = role === 'local'
    ? (epoch === 'during'
      ? ['agent', 'agent_requester', 'bridge', 'coordinator', 'elevation', 'fixture', 'integrated_cu']
      : ['bridge', 'elevation', 'integrated_cu'])
    : (epoch === 'during' ? ['bridge', 'elevation', 'fixture'] : ['bridge', 'elevation']);
  const classPID = {
    agent: 710,
    agent_requester: 711,
    bridge: role === 'local' ? 720 : 820,
    coordinator: 730,
    elevation: role === 'local' ? 740 : 840,
    fixture: role === 'local' ? 750 : 850,
    integrated_cu: 760,
  };
  const executableNames = {
    agent: 'peekaboo',
    agent_requester: 'peekaboo',
    bridge: 'Peekaboo',
    coordinator: 'peekaboo-certification-controller',
    elevation: 'OpenClaw',
    fixture: 'Playground',
    integrated_cu: 'SkyComputerUseService',
  };
  const classCodeHash = {
    agent: '1', agent_requester: '1', bridge: '2', coordinator: '3', elevation: '4',
    fixture: '5', integrated_cu: '6',
  };
  const roots = requiredClasses.map((rootClass) => {
    const binding = processBindings[rootClass] ?? {};
    const pid = binding.pid ?? classPID[rootClass];
    return {
      root_id: `${rootClass}-root`,
      root_class: rootClass,
      pid,
      start_identity: binding.start_identity ?? `${pid}001`,
      code_signature_hash: binding.code_signature_hash ?? classCodeHash[rootClass].repeat(40),
    };
  }).sort((left, right) => (left.root_id < right.root_id ? -1 : 1));
  const processes = roots.map((authority) => {
    const binding = processBindings[authority.root_class] ?? {};
    const originalName = executableNames[authority.root_class];
    const executableName = forbiddenRoot && authority === roots[0] ? forbiddenName : originalName;
    return {
      pid: authority.pid,
      start_identity: authority.start_identity,
      parent_pid: null,
      parent_start_identity: null,
      executable_path: binding.executable_path ?? `/private/tmp/qualification/${executableName}`,
      executable_name: binding.executable_path ? path.basename(binding.executable_path) : executableName,
      executable_sha256: binding.executable_sha256 ?? 'a'.repeat(64),
      code_signature_hash: authority.code_signature_hash,
      signing_identifier: `fixture.${role}.${authority.root_class}`,
      team_id: TEAM,
    };
  });
  const parent = roots.find((root) => root.root_class === 'coordinator')
    ?? roots.find((root) => root.root_class === 'fixture')
    ?? roots[0];
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
  const coverageStartedAt = coverage?.started_at_milliseconds ?? 1787000010000 + (epochOffset * 1000);
  const coverageCompletedAt = coverage?.completed_at_milliseconds ?? coverageStartedAt + 500;
  const requestedObservation = coverage?.requested_observation_milliseconds ?? 400;
  const finalSampleStartedAt = coverage?.final_sample_started_at_milliseconds
    ?? coverageCompletedAt - 1;
  const capturedAt = coverage?.captured_at_milliseconds ?? coverageCompletedAt + 1;
  const lifecycleStartedAt = coverageStartedAt - 10;
  const readinessPublishedAt = coverageStartedAt + 1;
  const treeVariant = forbiddenName ?? (orphan ? 'orphan' : 'tree');
  const readyPath = path.join(root, `${role}-${epoch}-${treeVariant}-readiness.json`);
  const requiresAcknowledgement = role === 'local' && epoch === 'during';
  let acknowledgementControl = null;
  let acknowledgementAuthorization = null;
  if (requiresAcknowledgement) {
    const acknowledgementPath = coverage?.acknowledgement_path ?? writeJSON(
      path.join(root, `${role}-${epoch}-${treeVariant}-agent-ack.json`),
      { version: 1, acknowledged: true },
    );
    const acknowledgementParent = path.dirname(acknowledgementPath);
    const acknowledgementBasename = path.basename(acknowledgementPath);
    acknowledgementControl = {
      acknowledgement_path: acknowledgementPath,
      authorization_source_path: path.join(
        acknowledgementParent,
        `.${acknowledgementBasename}.lifecycle-source`,
      ),
      authorization_request_path: path.join(
        acknowledgementParent,
        `.${acknowledgementBasename}.lifecycle-request`,
      ),
      authorization_result_path: path.join(
        acknowledgementParent,
        `.${acknowledgementBasename}.lifecycle-result`,
      ),
    };
  }
  const readiness = writeJSON(readyPath, {
    version: 1,
    role,
    host_uuid: hostUUID,
    deployment_envelope_sha256: '8'.repeat(64),
    epoch,
    collector_sha256: collectorSHA256,
    monitor_executable_path: monitorExecutable,
    monitor_executable_sha256: sha256(fs.readFileSync(monitorExecutable)),
    monitor_code_signature_hash: codeSignatureHash(monitorExecutable),
    lifecycle_guard_sha256: lifecycleGuardSHA256,
    lifecycle_guard_binary_sha256: lifecycleGuardBinarySHA256,
    lifecycle_guard_executable_path: path.join(root, `${role}-${epoch}-${treeVariant}-guard`),
    lifecycle_guard_pid: 999,
    lifecycle_guard_start_identity: '999001',
    lifecycle_result_path: path.join(root, `${role}-${epoch}-${treeVariant}-guard-result.json`),
    lifecycle_started_at_milliseconds: lifecycleStartedAt,
    coverage_started_at_milliseconds: coverageStartedAt,
    published_at_milliseconds: readinessPublishedAt,
    lifecycle_watched_pids: processes.map((process) => process.pid),
    roots,
    observed_processes: processes,
    acknowledgement_control: acknowledgementControl,
    complete: true,
  });
  if (requiresAcknowledgement) {
    const acknowledgementSHA256 = sha256(fs.readFileSync(
      acknowledgementControl.acknowledgement_path,
    ));
    const acknowledgementValue = JSON.parse(fs.readFileSync(
      acknowledgementControl.acknowledgement_path,
    ));
    const requestedAt = Math.max(
      readinessPublishedAt + 1,
      acknowledgementValue.acknowledgedAt ?? 0,
    );
    const authorizedAt = requestedAt;
    writeJSON(acknowledgementControl.authorization_request_path, {
      version: 1,
      guard_pid: 999,
      acknowledgement_path: acknowledgementControl.acknowledgement_path,
      acknowledgement_sha256: acknowledgementSHA256,
      readiness_sha256: sha256(fs.readFileSync(readiness)),
      requested_at_milliseconds: requestedAt,
    });
    writeJSON(acknowledgementControl.authorization_result_path, {
      version: 1,
      guard_pid: 999,
      authorized_at_milliseconds: authorizedAt,
    });
    acknowledgementAuthorization = {
      acknowledgement_path: acknowledgementControl.acknowledgement_path,
      acknowledgement_sha256: acknowledgementSHA256,
      authorization_request_path: acknowledgementControl.authorization_request_path,
      authorization_request_sha256: sha256(fs.readFileSync(
        acknowledgementControl.authorization_request_path,
      )),
      authorization_result_path: acknowledgementControl.authorization_result_path,
      authorization_result_sha256: sha256(fs.readFileSync(
        acknowledgementControl.authorization_result_path,
      )),
      authorized_at_milliseconds: authorizedAt,
    };
  }
  return writeJSON(path.join(root, `${role}-${epoch}-${treeVariant}.json`), {
    version: 4,
    role,
    host_uuid: hostUUID,
    deployment_envelope_sha256: '8'.repeat(64),
    epoch,
    scope: 'task_owned_descendants',
    requested_observation_milliseconds: requestedObservation,
    target_sample_interval_milliseconds: 50,
    coverage_started_at_milliseconds: coverageStartedAt,
    final_sample_started_at_milliseconds: finalSampleStartedAt,
    coverage_completed_at_milliseconds: coverageCompletedAt,
    captured_at_milliseconds: capturedAt,
    sample_count: 5,
    maximum_sample_gap_milliseconds: 1000,
    observed_maximum_sample_gap_milliseconds: 100,
    continuous_lifecycle_observation: true,
    lifecycle_guard_sha256: lifecycleGuardSHA256,
    lifecycle_guard_binary_sha256: lifecycleGuardBinarySHA256,
    lifecycle_started_at_milliseconds: lifecycleStartedAt,
    lifecycle_completed_at_milliseconds: capturedAt + 10,
    lifecycle_watched_pids: processes.map((process) => process.pid),
    lifecycle_event_count: 0,
    collector_sha256: collectorSHA256,
    readiness_path: readiness,
    readiness_sha256: sha256(fs.readFileSync(readiness)),
    readiness_published_at_milliseconds: readinessPublishedAt,
    acknowledgement_authorization: acknowledgementAuthorization,
    monitor_executable_path: monitorExecutable,
    monitor_executable_sha256: sha256(fs.readFileSync(monitorExecutable)),
    monitor_code_signature_hash: codeSignatureHash(monitorExecutable),
    complete: true,
    roots,
    processes,
  });
}

function synchronizeProcessTreeAuthorization(tree) {
  const authorization = tree.acknowledgement_authorization;
  if (authorization === null) return;
  const readinessSHA256 = sha256(fs.readFileSync(tree.readiness_path));
  const acknowledgementValue = JSON.parse(fs.readFileSync(authorization.acknowledgement_path));
  const requestedAt = Math.max(
    tree.readiness_published_at_milliseconds + 1,
    acknowledgementValue.acknowledgedAt ?? 0,
  );
  const authorizedAt = Math.max(authorization.authorized_at_milliseconds, requestedAt);
  const acknowledgementSHA256 = sha256(fs.readFileSync(authorization.acknowledgement_path));
  writeJSON(authorization.authorization_request_path, {
    version: 1,
    guard_pid: JSON.parse(fs.readFileSync(tree.readiness_path)).lifecycle_guard_pid,
    acknowledgement_path: authorization.acknowledgement_path,
    acknowledgement_sha256: acknowledgementSHA256,
    readiness_sha256: readinessSHA256,
    requested_at_milliseconds: requestedAt,
  });
  writeJSON(authorization.authorization_result_path, {
    version: 1,
    guard_pid: JSON.parse(fs.readFileSync(tree.readiness_path)).lifecycle_guard_pid,
    authorized_at_milliseconds: authorizedAt,
  });
  authorization.acknowledgement_sha256 = acknowledgementSHA256;
  authorization.authorization_request_sha256 = sha256(fs.readFileSync(
    authorization.authorization_request_path,
  ));
  authorization.authorization_result_sha256 = sha256(fs.readFileSync(
    authorization.authorization_result_path,
  ));
  authorization.authorized_at_milliseconds = authorizedAt;
}

function writeSynchronizedProcessTree(root, name, tree) {
  const readiness = JSON.parse(fs.readFileSync(tree.readiness_path));
  readiness.role = tree.role;
  readiness.host_uuid = tree.host_uuid;
  readiness.deployment_envelope_sha256 = tree.deployment_envelope_sha256;
  readiness.epoch = tree.epoch;
  readiness.collector_sha256 = tree.collector_sha256;
  readiness.monitor_executable_path = tree.monitor_executable_path;
  readiness.monitor_executable_sha256 = tree.monitor_executable_sha256;
  readiness.monitor_code_signature_hash = tree.monitor_code_signature_hash;
  readiness.lifecycle_guard_sha256 = tree.lifecycle_guard_sha256;
  readiness.lifecycle_guard_binary_sha256 = tree.lifecycle_guard_binary_sha256;
  readiness.lifecycle_started_at_milliseconds = tree.lifecycle_started_at_milliseconds;
  readiness.coverage_started_at_milliseconds = tree.coverage_started_at_milliseconds;
  readiness.published_at_milliseconds = tree.readiness_published_at_milliseconds;
  readiness.lifecycle_watched_pids = structuredClone(tree.lifecycle_watched_pids);
  readiness.roots = structuredClone(tree.roots);
  readiness.observed_processes = structuredClone(tree.processes);
  if (tree.acknowledgement_authorization !== null) {
    const authorizationRoot = privateDirectory(root, `${name}-authorization`);
    const acknowledgementPath = writeFile(
      path.join(authorizationRoot, 'agent-execution-ack.json'),
      fs.readFileSync(tree.acknowledgement_authorization.acknowledgement_path),
      0o600,
    );
    const acknowledgementBasename = path.basename(acknowledgementPath);
    const control = {
      acknowledgement_path: acknowledgementPath,
      authorization_source_path: path.join(
        authorizationRoot,
        `.${acknowledgementBasename}.lifecycle-source`,
      ),
      authorization_request_path: path.join(
        authorizationRoot,
        `.${acknowledgementBasename}.lifecycle-request`,
      ),
      authorization_result_path: path.join(
        authorizationRoot,
        `.${acknowledgementBasename}.lifecycle-result`,
      ),
    };
    readiness.acknowledgement_control = control;
    tree.acknowledgement_authorization.acknowledgement_path = control.acknowledgement_path;
    tree.acknowledgement_authorization.authorization_request_path
      = control.authorization_request_path;
    tree.acknowledgement_authorization.authorization_result_path
      = control.authorization_result_path;
  }
  const readinessPath = writeJSON(path.join(root, `${name}-readiness.json`), readiness);
  tree.readiness_path = readinessPath;
  tree.readiness_sha256 = sha256(fs.readFileSync(readinessPath));
  synchronizeProcessTreeAuthorization(tree);
  return writeJSON(path.join(root, `${name}.json`), tree);
}

function artifactFixture(root, executablePath = '/usr/bin/true', monitorPath = '/usr/bin/true') {
  const peekaboo = writeJSON(path.join(root, 'peekaboo-artifact-manifest.json'), {
    schema: 6,
    phase: 'candidate_verified_not_installed',
    source_commit: SOURCE,
    version: '4.2.1',
    cli: {
      sha256: sha256(fs.readFileSync(executablePath)),
      cdhash: codeSignatureHash(executablePath),
    },
    monitor: {
      source_commit: SOURCE,
      source_path: 'scripts/support/background-computer-use-probe.swift',
      source_sha256: sha256(fs.readFileSync(
        path.join(path.dirname(toolRoot), 'support/background-computer-use-probe.swift'),
      )),
      executable_sha256: sha256(fs.readFileSync(monitorPath)),
      cdhash: codeSignatureHash(monitorPath),
    },
    app: { source_commit: SOURCE, zip_sha256: '2'.repeat(64), cdhash: 'd'.repeat(40) },
    playground: {
      source_commit: SOURCE,
      zip_sha256: '3'.repeat(64),
      cdhash: '5'.repeat(40),
    },
    verification: {
      cli_source: true,
      cli_native_only: true,
      monitor_source: true,
      monitor_native_only: true,
      app_source: true,
      app_native_only: true,
      playground_native_only: true,
    },
  }, 0o400);
  const openclawValue = {
    schemaVersion: 1,
    kind: 'openclaw-elevation-artifact',
    archive: 'OpenClaw.app.zip',
    archiveSha256: '4'.repeat(64),
    archiveChecksum: 'OpenClaw.app.zip.sha256',
    installer: 'install-openclaw-elevation',
    installerSha256: '5'.repeat(64),
    installerChecksum: 'install-openclaw-elevation.sha256',
    sourceCommit: OPENCLAW_SOURCE,
    peekabooCommit: SOURCE,
    version: '2026.8.2',
    build: '1',
    authority: 'Developer ID Application: Fixture',
    teamIdentifier: TEAM,
    cdhashes: { arm64: '6'.repeat(40), x86_64: '7'.repeat(40) },
    architectures: { main: 'arm64 x86_64', helper: 'arm64 x86_64' },
    entitlementsSha256: { main: '8'.repeat(64), helper: '9'.repeat(64) },
    notarizationId: '12345678-1234-4abc-8def-123456789abc',
  };
  const openclaw = writeJSON(path.join(root, 'openclaw-artifact-receipt.json'), openclawValue, 0o400);
  return { peekaboo, openclaw, openclawValue };
}

function elevationReceipt(root, role, artifact) {
  return writeJSON(path.join(root, `${role}-elevation-receipt.json`), {
    schemaVersion: 3,
    kind: 'openclaw-elevation-install',
    transactionState: 'installed',
    transactionId: role === 'local'
      ? 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'
      : 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB',
    sourceCommit: OPENCLAW_SOURCE,
    peekabooCommit: SOURCE,
    archiveSha256: artifact.openclawValue.archiveSha256,
    artifactReceiptSha256: sha256(fs.readFileSync(artifact.openclaw)),
    installerSha256: artifact.openclawValue.installerSha256,
    cdhashes: artifact.openclawValue.cdhashes,
    nodeId: `${role}-node`,
    nodeProfile: role === 'local' ? 'primary' : 'node',
    appPath: '/Applications/OpenClaw.app',
    stateDir: `/private/tmp/${role}/state`,
    configPath: `/private/tmp/${role}/state/openclaw.json`,
    backupPath: '',
    backupCDHashes: { arm64: '', x86_64: '' },
    plistPath: `/private/tmp/${role}/Library/LaunchAgents/ai.openclaw.elevation.plist`,
    previousPlist: '',
    previousPlistSha256: '',
    previousPlistWasLoaded: false,
    previousReceipt: '',
    previousReceiptSha256: '',
    migration: null,
    adoptedApp: { wasRunning: true, attachOnly: true },
  });
}

function deploymentFixture(
  root,
  qualificationToolsAggregate,
  artifact,
  concurrentReport,
  plan,
  { studioEntries = null } = {},
) {
  const localUUID = LOCAL_UUID;
  const studioUUID = STUDIO_UUID;
  const artifactRoots = Object.fromEntries([
    ['openclaw_app', 'installed-openclaw-root'],
    ['peekaboo_app', 'installed-peekaboo-root'],
    ['peekaboo_cli', 'installed-cli-root'],
  ].map(([artifactName, directoryName]) => [artifactName, privateDirectory(root, directoryName)]));
  const installedFile = (artifactName, relativePath, bytes, mode) => {
    const filePath = path.join(artifactRoots[artifactName], relativePath);
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    writeFile(filePath, bytes, mode);
    return {
      artifact: artifactName,
      relative_path: relativePath,
      type: 'file',
      mode,
      size: fs.statSync(filePath).size,
      sha256: sha256(fs.readFileSync(filePath)),
    };
  };
  const entries = [
    installedFile(
      'openclaw_app',
      'OpenClaw.app/Contents/MacOS/OpenClaw',
      fs.readFileSync('/usr/bin/true'),
      0o755,
    ),
    installedFile(
      'openclaw_app',
      'OpenClaw.app/Contents/Resources/bootstrap.sh',
      '#!/bin/sh\nexit 0\n',
      0o755,
    ),
    installedFile(
      'peekaboo_app',
      'Peekaboo.app/Contents/MacOS/Peekaboo',
      fs.readFileSync('/usr/bin/true'),
      0o755,
    ),
    installedFile(
      'peekaboo_cli',
      'runtime/libswiftCompatibilitySpan.dylib',
      Buffer.concat([Buffer.from('cafebabe', 'hex'), Buffer.from('fixture native library')]),
      0o644,
    ),
    installedFile(
      'peekaboo_cli',
      'runtime/peekaboo',
      fs.readFileSync('/usr/bin/true'),
      0o755,
    ),
    {
      artifact: 'peekaboo_cli', relative_path: 'symlink/peekaboo',
      type: 'symlink', mode: 0o777, target: '../runtime/peekaboo',
    },
  ].sort((left, right) => (
    `${left.artifact}\0${left.relative_path}`.localeCompare(`${right.artifact}\0${right.relative_path}`)
  ));
  const symlinkPath = path.join(artifactRoots.peekaboo_cli, 'symlink/peekaboo');
  fs.mkdirSync(path.dirname(symlinkPath), { recursive: true });
  fs.symlinkSync('../runtime/peekaboo', symlinkPath);
  entries.find((entry) => entry.type === 'symlink').mode = Number(
    fs.lstatSync(symlinkPath, { bigint: true }).mode & 0o7777n,
  );
  const elevationReceipts = [
    elevationReceipt(root, 'local', artifact),
    elevationReceipt(root, 'studio', artifact),
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
  const localBindings = {
    agent: {
      pid: concurrentReport.agent.pid,
      start_identity: concurrentReport.agent.start_identity,
      executable_path: concurrentReport.agent.executable_path,
      executable_sha256: concurrentReport.agent.executable_sha256,
      code_signature_hash: concurrentReport.agent.code_signature_hash,
    },
    agent_requester: {
      pid: concurrentReport.agent.requester.pid,
      start_identity: concurrentReport.agent.requester.start_identity,
      executable_path: concurrentReport.agent.executable_path,
      executable_sha256: concurrentReport.agent.executable_sha256,
      code_signature_hash: concurrentReport.agent.requester.code_signature_hash,
    },
    bridge: {
      pid: plan.bridge.expected_host.process_identifier,
      start_identity: plan.bridge.expected_host.process_start_identity_decimal,
      code_signature_hash: plan.bridge.expected_host.code_signature_hash,
    },
    coordinator: {
      pid: concurrentReport.coordinator.pid,
      start_identity: concurrentReport.coordinator.start_identity,
      code_signature_hash: concurrentReport.coordinator.code_signature_hash,
    },
    elevation: {
      pid: 740,
      start_identity: '740001',
      code_signature_hash: artifact.openclawValue.cdhashes.arm64,
    },
    integrated_cu: concurrentReport.integrated_cu.emitter,
  };
  const studioBindings = {
    bridge: {
      pid: 820,
      start_identity: '820001',
      code_signature_hash: 'd'.repeat(40),
    },
    elevation: {
      pid: 840,
      start_identity: '840001',
      code_signature_hash: artifact.openclawValue.cdhashes.arm64,
    },
  };
  const localCoverage = {
    before: {
      started_at_milliseconds: concurrentReport.overlap.operations_started_at_milliseconds - 1000,
      completed_at_milliseconds: concurrentReport.overlap.operations_started_at_milliseconds - 500,
      captured_at_milliseconds: concurrentReport.overlap.operations_started_at_milliseconds - 499,
    },
    during: {
      started_at_milliseconds: concurrentReport.agent.released_at_milliseconds - 30,
      completed_at_milliseconds: concurrentReport.overlap.operations_completed_at_milliseconds + 100,
      captured_at_milliseconds: concurrentReport.overlap.operations_completed_at_milliseconds + 101,
      acknowledgement_path: concurrentReport.agent.acknowledgement_path,
    },
    after: {
      started_at_milliseconds: concurrentReport.overlap.operations_completed_at_milliseconds + 200,
      completed_at_milliseconds: concurrentReport.overlap.operations_completed_at_milliseconds + 700,
      captured_at_milliseconds: concurrentReport.overlap.operations_completed_at_milliseconds + 701,
    },
  };
  const processTrees = [
    ...['before', 'during', 'after'].map((epoch) => (
      taskProcessTree(root, 'local', localUUID, epoch, {
        collectorSHA256,
        processBindings: epoch === 'during'
          ? localBindings
          : {
              bridge: localBindings.bridge,
              elevation: localBindings.elevation,
              integrated_cu: localBindings.integrated_cu,
            },
        coverage: localCoverage[epoch],
      })
    )),
    ...['before', 'during', 'after'].map((epoch) => (
      taskProcessTree(root, 'studio', studioUUID, epoch, {
        collectorSHA256,
        lifecycleGuardBinarySHA256: '2'.repeat(64),
        processBindings: studioBindings,
      })
    )),
  ];
  const localDuringTree = JSON.parse(fs.readFileSync(processTrees[1]));
  const firstFixtureRoot = localDuringTree.roots.find((entry) => entry.root_class === 'fixture');
  const firstFixtureProcess = localDuringTree.processes.find((entry) => (
    entry.pid === firstFixtureRoot.pid
    && entry.start_identity === firstFixtureRoot.start_identity
  ));
  const [firstControlled, secondControlled] = plan.controllers.map((controller) => ({
    pid: controller.target.process_identifier,
    start_identity: controller.target.process_start_identity_decimal,
  }));
  firstFixtureRoot.pid = firstControlled.pid;
  firstFixtureRoot.start_identity = firstControlled.start_identity;
  firstFixtureProcess.pid = firstControlled.pid;
  firstFixtureProcess.start_identity = firstControlled.start_identity;
  localDuringTree.roots.push({
    ...firstFixtureRoot,
    root_id: 'fixture-root-b',
    pid: secondControlled.pid,
    start_identity: secondControlled.start_identity,
  });
  localDuringTree.processes.push({
    ...firstFixtureProcess,
    pid: secondControlled.pid,
    start_identity: secondControlled.start_identity,
  });
  localDuringTree.roots.sort((left, right) => (left.root_id < right.root_id ? -1 : 1));
  localDuringTree.processes.sort((left, right) => left.pid - right.pid);
  localDuringTree.lifecycle_watched_pids = localDuringTree.processes.map((entry) => entry.pid);
  const localDuringReadiness = JSON.parse(fs.readFileSync(localDuringTree.readiness_path));
  localDuringReadiness.roots = structuredClone(localDuringTree.roots);
  localDuringReadiness.lifecycle_watched_pids = [...localDuringTree.lifecycle_watched_pids];
  localDuringReadiness.observed_processes = structuredClone(localDuringTree.processes);
  writeJSON(localDuringTree.readiness_path, localDuringReadiness);
  localDuringTree.readiness_sha256 = sha256(fs.readFileSync(localDuringTree.readiness_path));
  const localDuringAuthorizationRequest = JSON.parse(fs.readFileSync(
    localDuringTree.acknowledgement_authorization.authorization_request_path,
  ));
  localDuringAuthorizationRequest.readiness_sha256 = localDuringTree.readiness_sha256;
  writeJSON(
    localDuringTree.acknowledgement_authorization.authorization_request_path,
    localDuringAuthorizationRequest,
  );
  localDuringTree.acknowledgement_authorization.authorization_request_sha256 = sha256(
    fs.readFileSync(localDuringTree.acknowledgement_authorization.authorization_request_path),
  );
  writeJSON(processTrees[1], localDuringTree);
  const policyScanner = path.join(toolRoot, 'executable-policy-scanner.mjs');
  const policyReports = [
    ['local', localUUID], ['studio', studioUUID],
  ].map(([role], inventoryIndex) => {
    const specPath = writeJSON(path.join(root, `${role}-policy-spec.json`), {
      version: 1,
      installed_inventory: installed[inventoryIndex],
      artifact_roots: artifactRoots,
    });
    const outputPath = path.join(root, `${role}-executable-policy.json`);
    const result = spawnSync(process.execPath, [
      policyScanner, 'generate', '--spec', specPath, '--output', outputPath,
    ], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    return outputPath;
  });
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
    artifactRoots,
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
      timestamp_nanoseconds: '9007199254740993',
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
      inventory_completeness: 'complete',
      inventory_warnings: [],
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
  fs.chmodSync(crashDirectory, 0o770);
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
          negotiatedVersion: { major: 1, minor: 31 },
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
    assert.equal(fs.statSync(fix.spec.paths.crash_directory).mode & 0o777, 0o770);
    assert.equal(result.bindings.monitor.foreground_controller.pid, 205);
    assert.equal(bindings.monitor.code_signature_hash, 'f'.repeat(40));
    assert.deepEqual(bindings.controllers.map((entry) => entry.controller_id), ['controller-a', 'controller-b']);
    assert.equal(bindings.controllers[0].target.click_point.x, 200);
    assert.equal(fs.statSync(output).mode & 0o777, 0o600);
    const planPath = path.join(root, 'live-v4-plan.json');
    const plan = constructLivePlan(output, planPath);
    assert.equal(plan.version, 1);
    assert.equal(plan.bridge.expected_host.source_commit, SOURCE);
    assert.equal(fs.statSync(planPath).mode & 0o777, 0o600);

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

    ambiguous.data.windows.pop();
    ambiguous.data.inventory_completeness = 'partial';
    ambiguous.data.inventory_warnings = ['Accessibility omitted one unmatched window row'];
    writeJSON(fix.spec.receipts.controller_a.window_inventory, ambiguous);
    assert.throws(
      () => projectBindings(input, path.join(root, 'partial.json')),
      /complete, omission-free window inventory/,
    );

    ambiguous.data.inventory_completeness = 'complete';
    writeJSON(fix.spec.receipts.controller_a.window_inventory, ambiguous);
    assert.throws(
      () => projectBindings(input, path.join(root, 'omitted-row.json')),
      /complete, omission-free window inventory/,
    );
  } finally {
    if (priorHome === undefined) delete process.env.HOME;
    else process.env.HOME = priorHome;
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('Playground alert lifecycle requires exact generation, ordered background dismissal, fresh AX, and latency budget', () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-alert-lifecycle-');
  fs.chmodSync(root, 0o700);
  const startedAt = 1_900_000_000_000;
  try {
    const fixture = playgroundAlertLifecycleFixture(
      root, 1, '1'.repeat(64), startedAt, codeSignatureHash('/usr/bin/true'),
    );
    const expected = {
      label: 'cycle 1 alert',
      cycle: 1,
      execution_nonce: '1'.repeat(64),
      peekaboo_source_commit: SOURCE,
      bridge_source_commit: SOURCE,
      playground_code_signature_hash: PLAYGROUND_CDHASH,
    };
    assert.equal(validatePlaygroundAlertLifecycle(fixture.report, expected).target.window_id,
      fixture.target.window_id);

    const wrongGeneration = structuredClone(fixture.report);
    wrongGeneration.target_after.sha256 = '0'.repeat(64);
    assert.throws(() => validatePlaygroundAlertLifecycle(wrongGeneration, expected),
      /changed after lifecycle construction/);

    const driftedScreenshot = structuredClone(fixture.report);
    driftedScreenshot.initial_screenshot.sha256 = '0'.repeat(64);
    assert.throws(() => validatePlaygroundAlertLifecycle(driftedScreenshot, expected),
      /changed after lifecycle construction/);

    const foregroundDismiss = structuredClone(fixture.report);
    const dismissResult = JSON.parse(fs.readFileSync(foregroundDismiss.phases.dismiss.result.path));
    dismissResult.outcome.delivery_mode = 'foreground';
    const forgedDismissPath = writeJSON(path.join(root, 'foreground-dismiss.json'), dismissResult);
    foregroundDismiss.phases.dismiss.result = {
      path: forgedDismissPath,
      size: fs.statSync(forgedDismissPath).size,
      sha256: sha256(fs.readFileSync(forgedDismissPath)),
    };
    assert.throws(() => validatePlaygroundAlertLifecycle(foregroundDismiss, expected),
      /background-dismiss/);

    const stalePostDismiss = structuredClone(fixture.report);
    const postResult = JSON.parse(fs.readFileSync(
      stalePostDismiss.phases['post-dismiss-ax'].result.path,
    ));
    postResult.data.snapshot_id = JSON.parse(fs.readFileSync(
      stalePostDismiss.phases['initial-see'].result.path,
    )).data.snapshot_id;
    const stalePostPath = writeJSON(path.join(root, 'stale-post.json'), postResult);
    stalePostDismiss.phases['post-dismiss-ax'].result = {
      path: stalePostPath,
      size: fs.statSync(stalePostPath).size,
      sha256: sha256(fs.readFileSync(stalePostPath)),
    };
    assert.throws(() => validatePlaygroundAlertLifecycle(stalePostDismiss, expected),
      /fresh complete no-dialog AX-only See/);

    const slowAX = structuredClone(fixture.report);
    const timing = JSON.parse(fs.readFileSync(slowAX.phases['post-dismiss-ax'].timing.path));
    timing.completed_at_milliseconds = timing.started_at_milliseconds
      + PLAYGROUND_AX_SEE_BUDGET_MILLISECONDS;
    timing.wall_time_milliseconds = PLAYGROUND_AX_SEE_BUDGET_MILLISECONDS;
    const slowTimingPath = writeJSON(path.join(root, 'slow-ax-timing.json'), timing);
    slowAX.phases['post-dismiss-ax'].timing = {
      path: slowTimingPath,
      size: fs.statSync(slowTimingPath).size,
      sha256: sha256(fs.readFileSync(slowTimingPath)),
    };
    assert.throws(() => validatePlaygroundAlertLifecycle(slowAX, expected),
      /1.5-second budget/);

    const slowOverall = structuredClone(fixture.report);
    const initialTiming = JSON.parse(fs.readFileSync(slowOverall.phases['initial-see'].timing.path));
    const timingShift = PLAYGROUND_OVERALL_SEE_BUDGET_MILLISECONDS
      - initialTiming.wall_time_milliseconds;
    initialTiming.completed_at_milliseconds += timingShift;
    initialTiming.wall_time_milliseconds = PLAYGROUND_OVERALL_SEE_BUDGET_MILLISECONDS;
    const slowOverallPath = writeJSON(path.join(root, 'slow-overall-timing.json'), initialTiming);
    slowOverall.phases['initial-see'].timing = {
      path: slowOverallPath, size: fs.statSync(slowOverallPath).size,
      sha256: sha256(fs.readFileSync(slowOverallPath)),
    };
    ['show-alert', 'dialog-observe', 'dismiss', 'post-dismiss-ax'].forEach((phase, index) => {
      const timing = JSON.parse(fs.readFileSync(slowOverall.phases[phase].timing.path));
      timing.started_at_milliseconds += timingShift;
      timing.completed_at_milliseconds += timingShift;
      const timingPath = writeJSON(path.join(root, `slow-overall-${index}.json`), timing);
      slowOverall.phases[phase].timing = {
        path: timingPath, size: fs.statSync(timingPath).size,
        sha256: sha256(fs.readFileSync(timingPath)),
      };
    });
    assert.throws(() => validatePlaygroundAlertLifecycle(slowOverall, expected),
      /2.5-second budget/);

    const wrongButton = structuredClone(fixture.report);
    wrongButton.dismiss_button = 'Cancel';
    assert.throws(() => validatePlaygroundAlertLifecycle(wrongButton, expected),
      /source-bound alert lifecycle/);

    const omittedBundle = structuredClone(fixture.report);
    omittedBundle.phases['show-alert'].bundles = [];
    assert.throws(() => validatePlaygroundAlertLifecycle(omittedBundle, expected),
      /complete retained receipt corpus/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('crash comparison binds zero delta to one complete matrix cycle', () => {
  const startedAt = 1_900_000_000_000;
  const completedAt = startedAt + 1000;
  const inventory = (capturedAt, entries = []) => ({
    version: 1,
    directory: '/Users/fixture/Library/Logs/DiagnosticReports',
    prefixes: ['Peekaboo', 'Playground'],
    entries,
    captured_at_milliseconds: capturedAt,
  });
  const binding = {
    version: 2,
    cycle: 1,
    success: true,
    catalog_version: 2,
    expected_cases: 42,
    observed_cases: 42,
    failures: [],
    execution_nonce: '1'.repeat(64),
    host_uuid: LOCAL_UUID,
    peekaboo_source_commit: SOURCE,
    bridge_source_commit: SOURCE,
    deployment_envelope_sha256: '8'.repeat(64),
    installed_inventory_aggregate_sha256: '9'.repeat(64),
    peekaboo_artifact_manifest_sha256: 'a'.repeat(64),
    started_at_milliseconds: startedAt,
    completed_at_milliseconds: completedAt,
  };
  const result = compareCrashInventories(
    inventory(startedAt - 10), inventory(completedAt + 10), binding,
  );
  assert.equal(result.version, 2);
  assert.equal(result.passed, true);
  assert.equal(result.execution_nonce, binding.execution_nonce);

  assert.throws(() => compareCrashInventories(
    inventory(startedAt + 1), inventory(completedAt + 10), binding,
  ), /do not bracket/);
  const crashed = compareCrashInventories(
    inventory(startedAt - 10),
    inventory(completedAt + 10, [{
      name: 'Playground-2026-08-19.crash', size: 1,
      modified_at_milliseconds: completedAt, sha256: 'b'.repeat(64),
    }]),
    binding,
  );
  assert.equal(crashed.passed, false);
  assert.equal(crashed.added.length, 1);
});

test('documented alert and crash helper CLI entrypoints parse their closed options', () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-alert-helper-cli-');
  fs.chmodSync(root, 0o700);
  try {
    const startedAt = 1_900_000_000_000;
    const completedAt = startedAt + 1000;
    const lifecycle = playgroundAlertLifecycleFixture(
      root, 1, '1'.repeat(64), startedAt, codeSignatureHash('/usr/bin/true'),
    );
    const alertRun = spawnSync(process.execPath, [
      path.join(toolRoot, 'playground-alert-lifecycle.mjs'),
      'validate', '--input', lifecycle.reportPath,
    ], { encoding: 'utf8' });
    assert.equal(alertRun.status, 0, alertRun.stderr);
    assert.equal(JSON.parse(alertRun.stdout).success, true);

    const inventory = (capturedAt) => ({
      version: 1,
      directory: '/Users/fixture/Library/Logs/DiagnosticReports',
      prefixes: ['Peekaboo', 'Playground'],
      entries: [],
      captured_at_milliseconds: capturedAt,
    });
    const baseline = writeJSON(path.join(root, 'baseline.json'), inventory(startedAt - 10));
    const final = writeJSON(path.join(root, 'final.json'), inventory(completedAt + 10));
    const binding = writeJSON(path.join(root, 'binding.json'), {
      version: 2, cycle: 1, success: true, catalog_version: 2,
      expected_cases: 42, observed_cases: 42, failures: [],
      execution_nonce: '1'.repeat(64), host_uuid: LOCAL_UUID,
      peekaboo_source_commit: SOURCE, bridge_source_commit: SOURCE,
      deployment_envelope_sha256: '8'.repeat(64),
      installed_inventory_aggregate_sha256: '9'.repeat(64),
      peekaboo_artifact_manifest_sha256: 'a'.repeat(64),
      started_at_milliseconds: startedAt, completed_at_milliseconds: completedAt,
    });
    const output = path.join(root, 'comparison.json');
    const crashRun = spawnSync(process.execPath, [
      path.join(toolRoot, 'crash-inventory.mjs'), 'compare',
      '--baseline', baseline, '--final', final, '--binding', binding, '--output', output,
    ], { encoding: 'utf8' });
    assert.equal(crashRun.status, 0, crashRun.stderr);
    assert.equal(JSON.parse(fs.readFileSync(output)).passed, true);
  } finally {
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
    const publication = path.join(root, 'publication-self-test.json');
    const publicationTest = spawnSync(
      binary,
      ['--self-test-output', publication],
      { encoding: 'utf8' },
    );
    assert.equal(publicationTest.status, 0, publicationTest.stderr);
    assert.deepEqual(JSON.parse(fs.readFileSync(publication)), { success: true, tests: 1 });
    assert.equal(fs.statSync(publication).mode & 0o777, 0o600);
    const duplicate = spawnSync(
      binary,
      ['--self-test-output', publication],
      { encoding: 'utf8' },
    );
    assert.notEqual(duplicate.status, 0);
    assert.match(duplicate.stderr, /absent|already exists/);
    assert.deepEqual(JSON.parse(fs.readFileSync(publication)), { success: true, tests: 1 });
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('policy scanner classifies every thin and fat Mach-O byte order as loadable code', () => {
  const magics = [
    'feedface', 'cefaedfe',
    'feedfacf', 'cffaedfe',
    'cafebabe', 'bebafeca',
    'cafebabf', 'bfbafeca',
  ];
  for (const magic of magics) {
    const bytes = Buffer.concat([Buffer.from(magic, 'hex'), Buffer.from('fixture')]);
    assert.equal(classifyPolicyFile('runtime/library.dylib', 0o644, bytes), 'executable');
    const nearMagic = Buffer.from(bytes);
    nearMagic[0] ^= 0x10;
    assert.equal(classifyPolicyFile('runtime/library.bin', 0o644, nearMagic), 'data');
    assert.equal(
      classifyPolicyFile('runtime/library.bin', 0o644, bytes.subarray(0, 3)),
      'data',
    );
  }
});

test('process-tree collector is read-only and continuously detects short-lived children', async () => {
  const collector = path.join(toolRoot, 'process-tree-collector.mjs');
  const source = fs.readFileSync(collector, 'utf8');
  assert.doesNotMatch(source, /\b(?:killall|pkill)\b|process\.kill\s*\(/);
  const selfTest = spawnSync(process.execPath, [collector, '--self-test'], { encoding: 'utf8' });
  assert.equal(selfTest.status, 0, selfTest.stderr);
  assert.deepEqual(JSON.parse(selfTest.stdout), { version: 1, passed: true });
  const root = fs.mkdtempSync('/private/tmp/pbq-lifecycle-guard-');
  fs.chmodSync(root, 0o700);
  let parent = null;
  let lifecycle = null;
  try {
    const guard = path.join(root, 'process-lifecycle-guard');
    const build = spawnSync('/usr/bin/xcrun', [
      'cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
      path.join(toolRoot, 'process-lifecycle-guard.c'), '-o', guard,
    ], { encoding: 'utf8' });
    assert.equal(build.status, 0, build.stderr);
    const guardSelfTest = spawnSync(guard, ['--self-test'], { encoding: 'utf8' });
    assert.equal(guardSelfTest.status, 0, guardSelfTest.stderr);
    assert.deepEqual(JSON.parse(guardSelfTest.stdout), { version: 1, passed: true });
    const parentSource = writeFile(path.join(root, 'fork-parent.c'), [
      '#include <signal.h>',
      '#include <stdbool.h>',
      '#include <stdio.h>',
      '#include <sys/wait.h>',
      '#include <time.h>',
      '#include <unistd.h>',
      'static volatile sig_atomic_t should_fork = 0;',
      'static void request_fork(int value) { (void)value; should_fork = 1; }',
      'int main(int argc, char **argv) {',
      '  if (argc != 2) return 1;',
      '  if (signal(SIGUSR1, request_fork) == SIG_ERR) return 2;',
      '  puts("READY"); fflush(stdout);',
      '  while (true) {',
      '    if (should_fork) {',
      '      should_fork = 0;',
      '      pid_t child = fork();',
      '      if (child < 0) return 3;',
      '      if (child == 0) _exit(0);',
      '      while (waitpid(child, NULL, 0) < 0) {}',
      '      FILE *marker = fopen(argv[1], "w");',
      '      if (!marker) return 4;',
      '      fputs("forked\\n", marker); fclose(marker);',
      '    }',
      '    struct timespec delay = { .tv_sec = 0, .tv_nsec = 1000000 };',
      '    nanosleep(&delay, NULL);',
      '  }',
      '}',
      '',
    ].join('\n'), 0o400);
    const parentBinary = path.join(root, 'fork-parent');
    const forkedMarker = path.join(root, 'forked.marker');
    const parentBuild = spawnSync('/usr/bin/xcrun', [
      'cc', '-std=c11', '-Wall', '-Wextra', '-Werror', parentSource, '-o', parentBinary,
    ], { encoding: 'utf8' });
    assert.equal(parentBuild.status, 0, parentBuild.stderr);
    parent = spawn(parentBinary, [forkedMarker], { stdio: ['ignore', 'pipe', 'pipe'] });
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('fork parent did not become ready')), 5000);
      parent.stdout.once('data', (bytes) => {
        clearTimeout(timeout);
        assert.match(bytes.toString('utf8'), /READY/);
        resolve();
      });
    });
    const ready = path.join(root, 'lifecycle-ready.json');
    const stop = path.join(root, 'lifecycle-stop.json');
    const output = path.join(root, 'lifecycle-result.json');
    lifecycle = spawn(guard, [
      '--ready', ready, '--stop', stop, '--output', output, '--pid', String(parent.pid),
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
    const waitForPath = async (filePath) => {
      const startedAt = Date.now();
      while (!fs.existsSync(filePath) && Date.now() - startedAt < 5000) {
        await new Promise((resolve) => setTimeout(resolve, 5));
      }
      assert.equal(fs.existsSync(filePath), true, `${filePath} was not published`);
    };
    await waitForPath(ready);
    parent.kill('SIGUSR1');
    await waitForPath(forkedMarker);
    writeJSON(stop, { version: 1, stop_at_milliseconds: Date.now() });
    await waitForPath(output);
    const violation = JSON.parse(fs.readFileSync(output));
    assert.equal(violation.passed, false);
    assert.equal(violation.event_pid, parent.pid);
    assert.equal((violation.event_flags & 0x40000000) !== 0, true);
  } finally {
    if (lifecycle?.exitCode === null && lifecycle?.signalCode === null) lifecycle.kill('SIGKILL');
    if (parent?.exitCode === null && parent?.signalCode === null) parent.kill('SIGKILL');
    fs.rmSync(root, { recursive: true, force: true });
  }
  const observedPIDs = new Set();
  accumulateDescendantPIDs(observedPIDs, new Map([[10, 1]]), [10]);
  accumulateDescendantPIDs(observedPIDs, new Map([[10, 1], [11, 10]]), [10]);
  accumulateDescendantPIDs(observedPIDs, new Map([[10, 1]]), [10]);
  assert.deepEqual([...observedPIDs].sort((left, right) => left - right), [10, 11]);
  assert.throws(
    () => validateRepeatedObservation(
      { start_identity: '1001' },
      { pid: 10, startIdentity: '1002' },
      1,
      1,
      10,
    ),
    /was reused during collection/,
  );
  assert.throws(
    () => validateRepeatedObservation(
      { start_identity: '1001' },
      { pid: 10, startIdentity: '1001' },
      1,
      2,
      10,
    ),
    /changed parent during collection/,
  );
  assert.throws(
    () => validateRepeatedExecutable(
      {
        executable_path: '/usr/bin/true', executable_sha256: '1'.repeat(64),
        code_signature_hash: '2'.repeat(40), signing_identifier: 'com.apple.true',
        team_id: TEAM,
      },
      {
        executable_path: '/usr/bin/osascript', executable_sha256: '3'.repeat(64),
        code_signature_hash: '4'.repeat(40), signing_identifier: 'com.apple.osascript',
        team_id: TEAM,
      },
      10,
    ),
    /changed executable identity during collection/,
  );
  assert.equal(validateSampleGap(1000, 1100, 100), 100);
  assert.throws(
    () => validateSampleGap(1000, 1101, 100),
    /sampling gap 101ms exceeds 100ms/,
  );
  assert.equal(isFinalProcessTableSample(2, 1099, 1100), false);
  assert.equal(isFinalProcessTableSample(2, 1100, 1100), true);
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

test('retained atomic publisher uses a closed toolchain and revalidates published bytes', () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-tools-retained-atomic-');
  fs.chmodSync(root, 0o700);
  const priorDeveloperDirectory = process.env.DEVELOPER_DIR;
  const priorToolchains = process.env.TOOLCHAINS;
  try {
    process.env.DEVELOPER_DIR = '/private/tmp/does-not-exist';
    process.env.TOOLCHAINS = 'untrusted-toolchain';
    const output = path.join(root, 'marker.json');
    const result = publishPrivateAtomicNoReplace(output, { version: 1, passed: true });
    assert.equal(result.path, output);
    assert.deepEqual(JSON.parse(result.bytes), { passed: true, version: 1 });
    assert.equal(result.sha256, sha256(fs.readFileSync(output)));
    assert.equal(fs.statSync(output).mode & 0o777, 0o600);
    assert.throws(
      () => publishPrivateAtomicNoReplace(output, { version: 1, passed: false }),
      /already exists/,
    );
    assert.deepEqual(JSON.parse(fs.readFileSync(output)), { passed: true, version: 1 });
  } finally {
    if (priorDeveloperDirectory === undefined) delete process.env.DEVELOPER_DIR;
    else process.env.DEVELOPER_DIR = priorDeveloperDirectory;
    if (priorToolchains === undefined) delete process.env.TOOLCHAINS;
    else process.env.TOOLCHAINS = priorToolchains;
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

test('managed launcher suspends the coordinator until signed-monitor identity and records actual exits', async () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-tools-launcher-');
  fs.chmodSync(root, 0o700);
  const priorCWD = process.cwd();
  const priorNodeOptions = process.env.NODE_OPTIONS;
  try {
    process.chdir(root);
    const injectionMarker = path.join(root, 'node-options-injected');
    const injectionSource = writeFile(
      path.join(root, 'node-options-injection.cjs'),
      `require('node:fs').writeFileSync(${JSON.stringify(injectionMarker)}, 'injected\\n');\n`,
      0o400,
    );
    process.env.NODE_OPTIONS = `--require=${injectionSource}`;
    const childMarker = path.join(root, 'coordinator-child-ran');
    const monitorSource = writeFile(path.join(root, 'process-identity.c'), [
      '#include <fcntl.h>',
      '#include <libproc.h>',
      '#include <stdio.h>',
      '#include <stdlib.h>',
      '#include <string.h>',
      '#include <sys/proc_info.h>',
      '#include <unistd.h>',
      'int main(int argc, char **argv) {',
      `  if (access("${childMarker}", F_OK) == 0) return 3;`,
      '  int pid = 0; const char *output = NULL;',
      '  for (int i = 1; i + 1 < argc; i++) {',
      '    if (strcmp(argv[i], "--pid") == 0) pid = atoi(argv[++i]);',
      '    else if (strcmp(argv[i], "--output") == 0) output = argv[++i];',
      '  }',
      '  if (pid <= 0 || output == NULL) return 4;',
      '  struct proc_bsdinfo info;',
      '  if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 5;',
      '  unsigned long long start = (info.pbi_start_tvsec * 1000000ULL) + info.pbi_start_tvusec;',
      '  int fd = open(output, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);',
      '  if (fd < 0) return 6;',
      '  if (dprintf(fd, "{\\n  \\"pid\\": %d,\\n  \\"startIdentity\\": \\"%llu\\"\\n}\\n", pid, start) < 0) return 7;',
      '  if (fsync(fd) != 0 || close(fd) != 0) return 8;',
      '  return 0;',
      '}',
      '',
    ].join('\n'), 0o400);
    const monitor = path.join(root, 'process-identity-monitor');
    const monitorBuild = spawnSync('/usr/bin/xcrun', [
      'cc', '-std=c11', '-Wall', '-Wextra', '-Werror', monitorSource, '-o', monitor, '-lproc',
    ], { encoding: 'utf8' });
    assert.equal(monitorBuild.status, 0, monitorBuild.stderr);
    const bridgeSocket = path.join(root, 'bridge.sock');
    const planPath = writeJSON(path.join(root, 'plan.json'), {
      version: 1,
      peekaboo_executable: '/usr/bin/true',
      monitor_executable: monitor,
      bridge: { socket_path: bridgeSocket },
      monitor: { code_signature_hash: codeSignatureHash(monitor) },
      fixture_value: 'retained-plan',
    });
    const coordinatorSource = writeFile(path.join(root, 'coordinator.mjs'), [
      'import fs from "node:fs";',
      'const plan = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));',
      `fs.writeFileSync(${JSON.stringify(childMarker)}, "ran\\n");`,
      'process.stdout.write(`retained-source:${plan.fixture_value}\\n`);',
      '',
    ].join('\n'), 0o400);
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
    const retainedCoordinatorSource = fs.readFileSync(coordinatorSource);
    const retainedPlan = fs.readFileSync(planPath);
    const coordinatorRun = await runManagedLaunch(
      coordinatorSpecPath,
      {
        afterSuspendedSpawn: () => {
          fs.chmodSync(coordinatorSource, 0o600);
          writeFile(coordinatorSource, 'process.stdout.write("replacement-source\\n");\n', 0o400);
          fs.chmodSync(planPath, 0o600);
          const replacementPlan = JSON.parse(retainedPlan);
          replacementPlan.fixture_value = 'replacement-plan';
          writeJSON(planPath, replacementPlan);
        },
      },
    );
    fs.chmodSync(coordinatorSource, 0o600);
    writeFile(coordinatorSource, retainedCoordinatorSource, 0o400);
    fs.chmodSync(planPath, 0o600);
    writeFile(planPath, retainedPlan, 0o600);
    assert.equal(coordinatorRun.exit_code, 0);
    assert.match(fs.readFileSync(coordinatorSpec.stdout_path, 'utf8'), /retained-source:retained-plan/);
    assert.doesNotMatch(fs.readFileSync(coordinatorSpec.stdout_path, 'utf8'), /replacement/);
    const coordinatorInvocation = JSON.parse(fs.readFileSync(coordinatorSpec.invocation_receipt_path));
    assert.equal(coordinatorInvocation.kind, 'coordinator');
    assert.equal(coordinatorInvocation.execution_staged, true);
    assert.equal(coordinatorInvocation.execution_source_sha256, sha256(retainedCoordinatorSource));
    assert.equal(coordinatorInvocation.execution_plan_sha256, sha256(retainedPlan));
    assert.equal(coordinatorInvocation.environment_keys.includes('NODE_OPTIONS'), false);
    assert.equal(fs.existsSync(injectionMarker), false);
    assert.equal(fs.readFileSync(childMarker, 'utf8'), 'ran\n');
    fs.unlinkSync(childMarker);

    const rejectedAgentSpec = managedLaunchSpec(
      root,
      'agent',
      planPath,
      process.execPath,
      [coordinatorSource, '--plan', planPath],
      { coordinator_source_path: coordinatorSource },
      'rejected-agent',
    );
    await assert.rejects(
      runManagedLaunch(writeJSON(path.join(root, 'rejected-agent-spec.json'), rejectedAgentSpec)),
      /managed launch kind\/version is invalid/,
    );
    assert.equal(fs.existsSync(rejectedAgentSpec.pid_path), false);

    const timeoutSource = writeFile(
      path.join(root, 'timeout-coordinator.mjs'),
      'process.on("SIGTERM", () => process.exit(0));\nsetInterval(() => {}, 1000);\n',
      0o400,
    );
    const timeoutSpec = managedLaunchSpec(
      root,
      'coordinator',
      planPath,
      process.execPath,
      [timeoutSource, '--plan', planPath],
      { coordinator_source_path: timeoutSource },
      'timeout',
    );
    timeoutSpec.run_timeout_seconds = 5;
    await assert.rejects(
      runManagedLaunch(writeJSON(path.join(root, 'timeout-spec.json'), timeoutSpec)),
      /guardian failed \(3\)/,
    );
    assert.equal(fs.existsSync(timeoutSpec.exit_receipt_path), false);

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

    const orphanSource = writeFile(
      path.join(root, 'orphan-coordinator.mjs'),
      'setTimeout(() => {}, 30_000);\n',
      0o400,
    );
    const orphanSpec = managedLaunchSpec(
      root,
      'coordinator',
      planPath,
      process.execPath,
      [orphanSource, '--plan', planPath],
      { coordinator_source_path: orphanSource },
      'orphan',
    );
    await assert.rejects(
      runManagedLaunch(
        writeJSON(path.join(root, 'orphan-spec.json'), orphanSpec),
        { afterRelease: ({ guardian }) => guardian.kill('SIGKILL') },
      ),
      /guardian failed/,
    );
    const orphanPID = JSON.parse(fs.readFileSync(orphanSpec.pid_path)).pid;
    assert.throws(() => process.kill(orphanPID, 0), /ESRCH/);
    assert.equal(fs.existsSync(orphanSpec.exit_receipt_path), false);

    const noHandshakePlan = writeJSON(path.join(root, 'no-handshake-plan.json'), {
      version: 1,
      peekaboo_executable: '/usr/bin/true',
      monitor_executable: '/usr/bin/true',
      bridge: { socket_path: bridgeSocket },
      monitor: { code_signature_hash: codeSignatureHash('/usr/bin/true') },
    });
    const failedSpec = managedLaunchSpec(
      root,
      'coordinator',
      noHandshakePlan,
      process.execPath,
      [coordinatorSource, '--plan', noHandshakePlan],
      { coordinator_source_path: coordinatorSource },
      'failed',
    );
    await assert.rejects(
      runManagedLaunch(writeJSON(path.join(root, 'failed-spec.json'), failedSpec)),
      /identity\.json|ENOENT|handshake/,
    );
    assert.equal(fs.existsSync(failedSpec.invocation_receipt_path), false);
    assert.equal(fs.existsSync(failedSpec.exit_receipt_path), false);
    assert.equal(fs.existsSync(childMarker), false);
    const failedPID = JSON.parse(fs.readFileSync(failedSpec.pid_path)).pid;
    assert.throws(() => process.kill(failedPID, 0), /ESRCH/);
    assert.doesNotMatch(
      fs.readFileSync(path.join(toolRoot, 'managed-launcher.mjs'), 'utf8'),
      /process\.kill\(childPID/,
    );
  } finally {
    process.chdir(priorCWD);
    if (priorNodeOptions === undefined) delete process.env.NODE_OPTIONS;
    else process.env.NODE_OPTIONS = priorNodeOptions;
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('managed guardian cleans only its owned child even when the PID receipt is substituted', async () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-tools-guardian-');
  fs.chmodSync(root, 0o700);
  let sentinel = null;
  let guardian = null;
  let pipeGuardian = null;
  let ackGuardian = null;
  try {
    const binary = path.join(root, 'managed-launch-suspended');
    const build = spawnSync('/usr/bin/xcrun', [
      'cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
      path.join(toolRoot, 'managed-launch-suspended.c'), '-o', binary, '-lproc',
    ], { encoding: 'utf8' });
    assert.equal(build.status, 0, build.stderr);
    sentinel = spawn('/bin/sleep', ['30'], { stdio: 'ignore' });
    const pidPath = path.join(root, 'child-pid.json');
    guardian = spawn(binary, [
      '--stdout', path.join(root, 'child.stdout'),
      '--stderr', path.join(root, 'child.stderr'),
      '--pid-file', pidPath,
      '--ack-file', path.join(root, 'start.ack'),
      '--start-timeout', '10',
      '--run-timeout', '30',
      '--', '/bin/sleep', '30',
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
    const spawnedLine = await new Promise((resolve, reject) => {
      let output = '';
      const timeout = setTimeout(() => reject(new Error('guardian did not publish SPAWNED')), 5000);
      guardian.stdout.on('data', (bytes) => {
        output += bytes.toString('utf8');
        const line = output.split('\n').find((entry) => entry.startsWith('SPAWNED '));
        if (line) {
          clearTimeout(timeout);
          resolve(line);
        }
      });
      guardian.once('error', (error) => {
        clearTimeout(timeout);
        reject(error);
      });
    });
    const childPID = Number(spawnedLine.split(' ')[1]);
    assert.equal(Number.isSafeInteger(childPID) && childPID > 0, true);
    writeJSON(pidPath, { version: 1, pid: sentinel.pid });
    const guardianClosed = new Promise((resolve) => {
      guardian.once('close', (code, signal) => resolve({ code, signal }));
    });
    guardian.kill('SIGTERM');
    const guardianResult = await guardianClosed;
    assert.equal(guardianResult.code, 2);
    assert.equal(guardianResult.signal, null);
    assert.throws(() => process.kill(childPID, 0), /ESRCH/);
    assert.doesNotThrow(() => process.kill(sentinel.pid, 0));

    const pipePIDPath = path.join(root, 'pipe-child-pid.json');
    pipeGuardian = spawn(binary, [
      '--stdout', path.join(root, 'pipe-child.stdout'),
      '--stderr', path.join(root, 'pipe-child.stderr'),
      '--pid-file', pipePIDPath,
      '--ack-file', path.join(root, 'pipe-start.ack'),
      '--start-timeout', '10',
      '--run-timeout', '30',
      '--', '/bin/sleep', '30',
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
    const pipeGuardianClosed = new Promise((resolve) => {
      pipeGuardian.once('close', (code, signal) => resolve({ code, signal }));
    });
    pipeGuardian.stdout.destroy();
    await new Promise((resolve, reject) => {
      const startedAt = Date.now();
      const interval = setInterval(() => {
        if (fs.existsSync(pipePIDPath)) {
          clearInterval(interval);
          resolve();
        } else if (Date.now() - startedAt >= 5000) {
          clearInterval(interval);
          reject(new Error('SIGPIPE guardian did not publish its child PID'));
        }
      }, 5);
    });
    const pipeChildPID = JSON.parse(fs.readFileSync(pipePIDPath)).pid;
    const pipeGuardianResult = await pipeGuardianClosed;
    assert.equal(pipeGuardianResult.code, 2);
    assert.equal(pipeGuardianResult.signal, null);
    assert.throws(() => process.kill(pipeChildPID, 0), /ESRCH/);

    const ackPIDPath = path.join(root, 'ack-child-pid.json');
    const ackPath = path.join(root, 'content-bound-start.json');
    ackGuardian = spawn(binary, [
      '--stdout', path.join(root, 'ack-child.stdout'),
      '--stderr', path.join(root, 'ack-child.stderr'),
      '--pid-file', ackPIDPath,
      '--ack-file', ackPath,
      '--start-timeout', '10',
      '--run-timeout', '30',
      '--', '/bin/sleep', '30',
    ], { stdio: ['pipe', 'pipe', 'pipe'] });
    let ackProtocol = '';
    let ackStderr = '';
    ackGuardian.stdout.on('data', (bytes) => { ackProtocol += bytes.toString('utf8'); });
    ackGuardian.stderr.on('data', (bytes) => { ackStderr += bytes.toString('utf8'); });
    await new Promise((resolve, reject) => {
      const startedAt = Date.now();
      const interval = setInterval(() => {
        if (fs.existsSync(ackPIDPath)) {
          clearInterval(interval);
          resolve();
        } else if (Date.now() - startedAt >= 5000) {
          clearInterval(interval);
          reject(new Error('content-bound guardian did not publish its child PID'));
        }
      }, 5);
    });
    const ackChildPID = JSON.parse(fs.readFileSync(ackPIDPath)).pid;
    const wrongStart = '1';
    const invocationSHA256 = '0'.repeat(64);
    writeFile(ackPath, [
      '{',
      `  "invocation_sha256": "${invocationSHA256}",`,
      '  "phase": "start",',
      `  "pid": ${ackChildPID},`,
      `  "start_identity": "${wrongStart}",`,
      '  "version": 1',
      '}',
      '',
    ].join('\n'));
    const ackGuardianClosed = new Promise((resolve) => {
      ackGuardian.once('close', (code, signal) => resolve({ code, signal }));
    });
    ackGuardian.stdin.end(`ACK 1 ${ackChildPID} ${wrongStart} ${invocationSHA256}\n`);
    const ackGuardianResult = await ackGuardianClosed;
    assert.equal(ackGuardianResult.code, 2);
    assert.equal(ackGuardianResult.signal, null);
    assert.match(ackStderr, /process generation differs/);
    assert.doesNotMatch(ackProtocol, /RELEASED/);
    assert.throws(() => process.kill(ackChildPID, 0), /ESRCH/);
  } finally {
    if (ackGuardian?.exitCode === null && ackGuardian?.signalCode === null) {
      ackGuardian.kill('SIGKILL');
    }
    if (pipeGuardian?.exitCode === null && pipeGuardian?.signalCode === null) {
      pipeGuardian.kill('SIGKILL');
    }
    if (guardian?.exitCode === null && guardian?.signalCode === null) guardian.kill('SIGKILL');
    if (sentinel?.exitCode === null && sentinel?.signalCode === null) sentinel.kill('SIGKILL');
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

function agentExecutionOutcome() {
  return {
    state: 'dispatched_unverified', effect: 'unverifiable', route: 'bridge',
    delivery_mechanism: 'native_framework', delivery_mode: 'background',
    evidence: 'delivery_accepted', dispatch_state: 'dispatched', dispatched_unit_count: 1,
    retry_safety: 'unsafe', escalation: 'observe_before_retry', mutation_dispatched: true,
    retry_safe: false, requires_fresh_observation: true,
  };
}

function playgroundAlertLifecycleFixture(root, cycle, executionNonce, startedAt, cliCDHash) {
  const lifecycleRoot = privateDirectory(root, `playground-alert-${cycle}`);
  for (const directory of ['phases', 'receipts', 'validators']) {
    privateDirectory(lifecycleRoot, directory);
  }
  const target = { pid: 500 + cycle, start_identity: `${500 + cycle}001`, window_id: 600 + cycle };
  const button = cycle % 2 === 1 ? 'OK' : 'Cancel';
  const executablePath = '/usr/bin/true';
  const initialScreenshotPath = writeFile(
    path.join(lifecycleRoot, 'initial-see.png'),
    Buffer.concat([
      Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      Buffer.from(`cycle-${cycle}-screenshot`, 'utf8'),
    ]),
    0o600,
  );
  const physicalTargets = writeJSON(path.join(lifecycleRoot, 'physical-targets.json'), {
    version: 1,
    targets: {
      playground: {
        pid: target.pid,
        process_start_identity: target.start_identity,
        window_id: 700 + cycle,
        executable: {
          path: executablePath,
          sha256: sha256(fs.readFileSync(executablePath)),
          code_signature_hash: PLAYGROUND_CDHASH,
        },
      },
    },
  });
  const processValue = {
    pid: target.pid,
    startIdentity: target.start_identity,
    path: executablePath,
    sha256: sha256(fs.readFileSync(executablePath)),
  };
  writeJSON(path.join(lifecycleRoot, 'target-before.json'), processValue);
  writeJSON(path.join(lifecycleRoot, 'target-after.json'), processValue);
  writeJSON(path.join(lifecycleRoot, 'crash-comparison.json'), {
    version: 1, passed: true, added: [], changed: [], removed: [],
  });
  const targetReceipt = {
    pid: target.pid,
    process_start_identity: Number(target.start_identity),
    process_start_identity_decimal: target.start_identity,
    window_id: target.window_id,
  };
  const envelope = (data, outcome = null, receipt = targetReceipt) => ({
    success: true,
    effect: outcome?.effect ?? null,
    outcome,
    data,
    target_identity: receipt === null ? null : {
      kind: 'window', pid: receipt.pid,
      process_start_identity_decimal: receipt.process_start_identity_decimal,
      window_id: receipt.window_id,
    },
    target_receipt: receipt,
    debug_logs: [],
    error: null,
  });
  const snapshotID = `cycle-${cycle}-show-snapshot`;
  const postSnapshotID = `cycle-${cycle}-post-snapshot`;
  const showElementID = 'B42';
  const phaseSpecs = [
    ['open-fixture-menu', 'clickMenuItem', true, envelope({ clicked: true }, actionOutcome())],
    ['open-fixture-window', 'listWindows', false, envelope({
      windows: [{ window_title: 'Dialog Fixture', window_id: target.window_id }],
      target_application_info: { pid: target.pid },
    }, null, null)],
    ['initial-see', 'desktopObservation', false, envelope({
      snapshot_id: snapshotID, screenshot_raw: initialScreenshotPath,
      screenshot_annotated: '', is_dialog: false, truncation: null, execution_time: 0.8,
      ui_elements: [{ id: showElementID, identifier: 'dialog-fixture-show-alert' }],
    })],
    ['show-alert', 'exactWindowTargetedClick', true, envelope({ clicked: true }, actionOutcome())],
    ['dialog-observe', 'targetedDialogListElements', false, envelope({
      role: 'AXSheet', buttons: ['OK', 'Cancel'],
    })],
    ['dismiss', 'exactDialogClickButton', true, envelope({ button }, actionOutcome())],
    ['post-dismiss-ax', 'inspectAccessibilityTree', false, envelope({
      snapshot_id: postSnapshotID, screenshot_raw: '', screenshot_annotated: '',
      is_dialog: false, truncation: null, execution_time: 0.8,
      ui_elements: [{
        id: 'T42', identifier: 'dialog-fixture-last-alert-result', label: button,
      }],
    })],
  ];
  let cursor = startedAt + 100;
  for (const [phase, operation, mutating, result] of phaseSpecs) {
    const phaseDirectory = privateDirectory(path.join(lifecycleRoot, 'phases'), phase);
    const receiptDirectory = privateDirectory(path.join(lifecycleRoot, 'receipts'), phase);
    const validatorDirectory = privateDirectory(path.join(lifecycleRoot, 'validators'), phase);
    const duration = ['initial-see', 'post-dismiss-ax'].includes(phase) ? 800 : 50;
    writeJSON(path.join(phaseDirectory, 'result.json'), result);
    writeJSON(path.join(phaseDirectory, 'command-timing.json'), {
      version: 1,
      started_at_milliseconds: cursor,
      completed_at_milliseconds: cursor + duration,
      wall_time_milliseconds: duration,
    });
    writeJSON(path.join(phaseDirectory, 'summary.json'), {
      result_success: true,
      evidence: {
        result_contract: true, monitor_liveness: true, contamination_clear: true,
        desktop_restored: true, clipboard_policy: true,
      },
      monitor_receipt: { execution_nonce: executionNonce },
      invariants: [{ name: 'focus', passed: true }],
    });
    writeJSON(path.join(phaseDirectory, 'before.json'), { phase, moment: 'before' });
    writeJSON(path.join(phaseDirectory, 'after.json'), { phase, moment: 'after' });
    const canonicalRequestValue = phase === 'show-alert'
      ? { snapshot_id: snapshotID, element_id: showElementID }
      : phase === 'dismiss' ? { button }
        : phase === 'initial-see' ? {
          phase, capture: { engine: 'auto' }, output: { path: initialScreenshotPath },
        } : { phase };
    const canonicalResponseValue = phase === 'initial-see'
      ? {
        snapshotId: snapshotID,
        screenshotPath: initialScreenshotPath,
        screenshotSHA256: sha256(fs.readFileSync(initialScreenshotPath)),
        elements: [{ id: showElementID, identifier: 'dialog-fixture-show-alert' }],
      }
      : phase === 'dialog-observe' ? { role: 'AXSheet', buttons: ['Cancel', 'OK'] }
        : phase === 'post-dismiss-ax' ? {
          snapshotId: postSnapshotID,
          screenshotPath: '',
          metadata: { isDialog: false },
          elements: [{
            id: 'T42', identifier: 'dialog-fixture-last-alert-result', label: button,
          }],
        } : { success: true };
    const pair = signedBundleFixture(
      validatorDirectory,
      phase,
      operation,
      target,
      cursor,
      cursor + duration,
      {
        mutating,
        outcomeAttested: true,
        directory: receiptDirectory,
        client: { pid: 800 + cycle, start_identity: `${800 + cycle}001`, code_signature_hash: cliCDHash },
        canonicalRequestValue,
        canonicalResponseValue,
      },
    );
    fs.renameSync(pair.validator, path.join(validatorDirectory, path.basename(pair.bundle)));
    cursor += duration + 50;
  }
  const report = constructPlaygroundAlertLifecycle({
    root: lifecycleRoot,
    physicalTargets,
    cycle,
    executionNonce,
    peekabooSourceCommit: SOURCE,
    bridgeSourceCommit: SOURCE,
    button,
  });
  const reportPath = writeJSON(path.join(lifecycleRoot, 'report.json'), report);
  return { report, reportPath, root: lifecycleRoot, target };
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

function traceEntry(id, name, pid, windowID, arguments_ = null) {
  return {
    id,
    name,
    arguments: arguments_ ?? { pid, window_id: windowID, foreground: false },
    result: { success: true, mutation_dispatched: true, mutation_dispatch: 'dispatched' },
    isError: false, disposition: 'executed/succeeded', mutationDispatch: 'dispatched',
    actionOutcome: actionOutcome(),
  };
}

function signedOperationRequestFixture(operation, traceArguments) {
  const [requestCase, payload] = operation === 'setValue'
    ? ['setValue', { target: traceArguments.on, snapshotId: traceArguments.snapshot }]
    : ['exactWindowTargetedTypeActions', { snapshotId: traceArguments.snapshot ?? null }];
  return canonicalBytes({
    projectedAction: { _0: { request: { [requestCase]: { _0: payload } } } },
  }).toString('base64');
}

test('same-target paste bindings remain distinct by authenticated request identity', () => {
  const target = { pid: 302, start_identity: '302001', window_id: 402 };
  const entry = traceEntry('paste', 'paste', target.pid, target.window_id);
  const signed = (requestKey) => ({
    bundle: {
      value: {
        canonicalRequest: signedOperationRequestFixture(
          'exactWindowTargetedTypeActions',
          entry.arguments,
        ),
      },
    },
    identity: { request_key: requestKey },
  });
  const first = validateAgentTraceOperationBinding(
    entry, signed('listener:first'), 'paste', target, 'first paste',
  );
  const second = validateAgentTraceOperationBinding(
    entry, signed('listener:second'), 'paste', target, 'second paste',
  );
  assert.notEqual(first, second);
});

let fixtureRequestCounter = 1;
function signedBundleFixture(root, name, operation, targetValue, startedAt, completedAt, {
  mutating = true,
  sourceCommit = SOURCE,
  directory = root,
  client = { pid: 901, start_identity: '901001', code_signature_hash: 'a'.repeat(40) },
  host = { pid: 200, start_identity: '200001', code_signature_hash: 'd'.repeat(40) },
  listenerInstanceID = UUID,
  clientInstanceID = UUID,
  sessionID = SESSION_ID,
  sessionSequence = null,
  targetAbsent = false,
  outcome = null,
  outcomeAttested = mutating,
  traceArguments = {},
  canonicalRequestValue = null,
  canonicalResponseValue = {},
} = {}) {
  const requestOrdinal = fixtureRequestCounter++;
  const requestID = `00000000-0000-4000-8000-${String(requestOrdinal).padStart(12, '0')}`;
  const resolvedSessionSequence = sessionSequence ?? String(requestOrdinal);
  const payload = {
    schemaVersion: 1,
    requestID,
    sessionID,
    operation,
    listenerInstanceID,
    clientInstanceID,
    sessionSequence: resolvedSessionSequence,
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
  const bundle = writeJSON(path.join(directory, `${name}-bundle.json`), {
    receipt: { payload },
    canonicalRequest: canonicalRequestValue === null
      ? signedOperationRequestFixture(operation, traceArguments)
      : canonicalBytes(canonicalRequestValue).toString('base64'),
    canonicalResponse: canonicalBytes(canonicalResponseValue).toString('base64'),
  });
  const validator = writeJSON(path.join(root, `${name}-validator.json`), {
    success: true,
    data: {
      valid: true,
      validator_id: 'peekaboo-bridge-receipt-validate-v1',
      trust_source: 'authenticated_live_listener',
      minimum_protocol_version: '1.29',
      request_id: requestID,
      session_id: sessionID,
      operation,
      listener_instance_id: listenerInstanceID,
      client_instance_id: clientInstanceID,
      session_sequence: resolvedSessionSequence,
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
      host_protocol_version: '1.31',
      bundle_sha256: sha256(fs.readFileSync(bundle)),
      terminal_receipt_attested: true,
      target_attested: !targetAbsent,
      outcome_attested: outcomeAttested,
      retention_basis: 'exported_bundle',
    },
  });
  return { bundle, validator, payload };
}

function agentTerminalBundleFixture(root, {
  executablePath,
  bridgeSocket,
  runRoot,
  task,
  trace,
  spawnedAt,
  releasedAt,
  completedAt,
  child,
  requester,
  host,
}) {
  const request = {
    task,
    maxSteps: 40,
    runRootPath: runRoot,
    coordinationReceiptPath: path.join(runRoot, 'agent-execution-coordination.json'),
    acknowledgementPath: path.join(runRoot, 'agent-execution-ack.json'),
    startTimeoutMilliseconds: 30_000,
    runTimeoutMilliseconds: 900_000,
  };
  const arguments_ = [
    'agent', 'run', task, '--no-cache', '--max-steps', '40',
    '--bridge-socket', bridgeSocket, '--json',
  ];
  const stdoutRoot = {
    success: true,
    result: { content: 'complete', executionTrace: trace },
  };
  const stdoutBytes = canonicalBytes(stdoutRoot);
  const evidence = (bytes) => ({
    bytes: bytes.toString('base64'),
    sha256: sha256(bytes),
    byteCount: bytes.length,
    truncated: false,
    readErrorCode: null,
  });
  const coordinationBytes = canonicalBytes({ version: 1, fixture: 'coordination' });
  const processIdentity = {
    processIdentifier: child.pid,
    processStartIdentity: child.start_identity,
    codeSignatureHash: child.code_signature_hash,
  };
  const processReceipt = {
    processIdentity,
    executablePath,
    executableSHA256: sha256(fs.readFileSync(executablePath)),
  };
  const requestingPeer = {
    processIdentifier: requester.pid,
    processStartIdentity: requester.start_identity,
    codeSignatureHash: requester.code_signature_hash,
  };
  const taskSHA256 = sha256(Buffer.from(task, 'utf8'));
  const argumentsSHA256 = sha256(canonicalBytes(arguments_));
  const environmentSHA256 = 'e'.repeat(64);
  const acknowledgementBytes = canonicalBytes({
    version: 1,
    challenge: 'c'.repeat(64),
    coordinationReceiptSHA256: sha256(coordinationBytes),
    requestingPeer,
    process: processReceipt,
    taskSHA256,
    argumentsSHA256,
    environmentSHA256,
    acknowledgedAt: releasedAt - 1,
  });
  writeFile(request.coordinationReceiptPath, coordinationBytes);
  writeFile(request.acknowledgementPath, acknowledgementBytes);
  const response = {
    version: 1,
    process: processReceipt,
    requestingPeer,
    bridgeSocketPath: bridgeSocket,
    runRootPath: runRoot,
    coordinationReceiptPath: request.coordinationReceiptPath,
    acknowledgementPath: request.acknowledgementPath,
    operationReceiptDirectoryPath: path.join(runRoot, 'agent-operation-receipts'),
    taskSHA256,
    maxSteps: 40,
    startTimeoutMilliseconds: 30_000,
    runTimeoutMilliseconds: 900_000,
    arguments: arguments_,
    argumentsSHA256,
    backgroundOnly: true,
    allowForeground: false,
    shellAvailable: false,
    processCreationLimit: 0,
    environmentPolicyVersion: 3,
    environmentKeys: [
      'PATH', 'PEEKABOO_AGENT_EXECUTION_GATE_CHALLENGE',
      'PEEKABOO_AGENT_EXECUTION_GATE_FD', 'PEEKABOO_AGENT_EXECUTION_LOCKDOWN_FD',
      'PEEKABOO_AGENT_EXECUTION_PROCESS_LIMIT', 'PEEKABOO_OPERATION_RECEIPT_DIRECTORY',
    ],
    environmentSHA256,
    stdout: evidence(stdoutBytes),
    stderr: evidence(Buffer.alloc(0)),
    coordinationReceipt: evidence(coordinationBytes),
    acknowledgement: evidence(acknowledgementBytes),
    processDisposition: 'exited',
    outputDisposition: 'validated_execution_trace',
    executionTrace: trace,
    exitCode: 0,
    terminationSignal: null,
    spawnedAt,
    lockdownAcknowledgedAt: spawnedAt + 1,
    coordinationReceiptPublishedAt: releasedAt - 50,
    acknowledgedAt: releasedAt - 1,
    releasedAt,
    terminalObservationEndedAt: completedAt,
  };
  const outcome = agentExecutionOutcome();
  const canonicalRequest = canonicalBytes({
    projectedAction: { _0: { request: { agentExecutionTrace: { _0: request } } } },
  });
  const canonicalResponse = canonicalBytes({
    projectedAction: { _0: { outcome, response: { agentExecutionTrace: { _0: response } } } },
  });
  const requestOrdinal = fixtureRequestCounter++;
  const requestID = `00000000-0000-4000-8000-${String(requestOrdinal).padStart(12, '0')}`;
  const listenerPublicKeySHA256 = 'f'.repeat(64);
  const payload = {
    schemaVersion: 1,
    requestID,
    sessionID: SESSION_ID,
    operation: 'agentExecutionTrace',
    listenerInstanceID: UUID,
    clientInstanceID: UUID,
    sessionSequence: String(requestOrdinal),
    listenerPublicKeySHA256,
    requestSHA256: sha256(canonicalRequest),
    responseSHA256: sha256(canonicalResponse),
    client: {
      processIdentifier: requester.pid,
      processStartIdentity: requester.start_identity,
      codeSignatureHash: requester.code_signature_hash,
    },
    startedAtUnixMilliseconds: spawnedAt - 1,
    completedAtUnixMilliseconds: completedAt + 1,
    target: {
      kind: 'process',
      processIdentifier: child.pid,
      processStartIdentity: child.start_identity,
    },
    outcome,
  };
  const bundle = writeJSON(path.join(root, 'agent-terminal-bundle.json'), {
    canonicalRequest: canonicalRequest.toString('base64'),
    canonicalResponse: canonicalResponse.toString('base64'),
    receipt: { payload },
  });
  const validator = writeJSON(path.join(root, 'agent-terminal-validator.json'), {
    success: true,
    data: fixtureAuthenticatedBundle({ bundlePath: bundle, expectedHost: host }),
  });
  return { bundle, validator, request, response, payload, stdoutRoot };
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

function agentTaskContractFixture(targetA, targetB) {
  const steps = (baseline, mutationFamily, mutated, restorationFamily) => [
    { phase: 'baseline', expected_value: baseline },
    { phase: 'mutate', family: mutationFamily, expected_value: mutated },
    { phase: 'verify-mutated', expected_value: mutated },
    { phase: 'restore', family: restorationFamily, expected_value: baseline },
    { phase: 'verify-restored', expected_value: baseline },
  ];
  return {
    version: 1,
    kind: 'peekaboo-concurrent-agent-qualification',
    goal: 'two-target-background-mutate-verify-restore-with-concurrent-cu',
    constraints: {
      delivery_mode: 'background',
      foreground: 'forbidden',
      progress_interleaving: 'before-and-after-integrated-cu',
      shell: 'forbidden',
      skips_and_failures: 'forbidden',
    },
    targets: [
      {
        label: 'target-a',
        target: structuredClone(targetA),
        steps: steps('alpha', 'set_value', 'alpha!', 'set_value'),
      },
      {
        label: 'target-b',
        target: structuredClone(targetB),
        steps: steps('beta', 'paste', 'beta!', 'type'),
      },
    ],
    postconditions: {
      all_targets_restored: true,
      cleanup: 'restore-exact-baselines',
      exact_dispatched_mutation_count: 4,
      exact_target_count: 2,
      minimum_primary_mutation_family_count: 2,
      novel_restoration_family_required: true,
      target_b_distinct_restoration_family: true,
    },
  };
}

function concurrentFixture(root, {
  agentFinishesBeforeIntegratedCU = false,
  agentTouchesIntegratedCUBoundary = false,
  taskTextOverride = null,
  taskContractMutator = null,
  taskEncoding = 'canonical',
} = {}) {
  const runRoot = privateDirectory(root, 'run');
  const monitorDirectory = privateDirectory(runRoot, 'monitor');
  const agentExecutable = '/usr/bin/true';
  const monitorCodeSignatureHash = codeSignatureHash('/usr/bin/true');
  const bridgeSocket = path.join(root, 'bridge.sock');
  const now = Date.now();
  const operationsStart = now - 3000;
  const operationsComplete = now - 2000;
  const foregroundTarget = target(203, '203001', 303);
  const sentinel = target(204, '204001', 304, 500);
  const targetA = { pid: 301, start_identity: '301001', window_id: 401 };
  const targetB = { pid: 302, start_identity: '302001', window_id: 402 };
  const planValue = {
    version: 1,
    peekaboo_executable: agentExecutable,
    monitor_executable: '/usr/bin/true',
    bridge: {
      socket_path: bridgeSocket,
      trusted_host_team_ids: [TEAM],
      expected_host: {
        host_kind: 'gui',
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
        target: {
          process_identifier: 301,
          process_start_identity_decimal: '301001',
          window_id: 401,
          bounds: { x: 0, y: 0, width: 400, height: 300 },
          is_minimized: false,
          click_point: { x: 200, y: 150 },
        },
      },
      {
        controller_id: 'controller-b',
        target_id: 'target-b',
        target: {
          process_identifier: 302,
          process_start_identity_decimal: '302001',
          window_id: 402,
          bounds: { x: 500, y: 0, width: 400, height: 300 },
          is_minimized: false,
          click_point: { x: 700, y: 150 },
        },
      },
    ],
    observer: { target: foregroundTarget },
    monitor: {
      code_signature_hash: monitorCodeSignatureHash,
      foreground_target: foregroundTarget,
      sentinel,
      foreground_controller: { pid: 205, start_identity: '205001', code_signature_hash: 'e'.repeat(40) },
      foreground_controller_team_id: TEAM,
    },
  };
  const plan = writeJSON(path.join(root, 'plan.json'), planValue);
  const marker = `peekaboo-foreground-postcondition:${NONCE}`;
  const baselineDigest = '1'.repeat(64);
  const monitorEvidenceValue = {
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
  };
  const monitorEvidence = writeJSON(
    path.join(monitorDirectory, 'monitor-evidence.json'),
    monitorEvidenceValue,
  );
  const summary = writeJSON(
    path.join(runRoot, 'certification-summary.json'),
    certificationSummaryFixture(monitorEvidenceValue, planValue.controllers),
  );
  const windowPath = path.join(runRoot, 'external-foreground-window.json');
  const events = [
    { event: 'run-created', version: 1, execution_nonce: NONCE, monitor_instance_id: UUID, run_root: runRoot },
    { event: 'external-foreground-window', version: 1, execution_nonce: NONCE, monitor_instance_id: UUID, phase: 'perform', window_path: windowPath, deadline_milliseconds: now + 30_000 },
    { event: 'external-foreground-window', version: 1, execution_nonce: NONCE, monitor_instance_id: UUID, phase: 'restore', window_path: windowPath, deadline_milliseconds: now + 60_000 },
    {
      event: 'completed', version: 1, execution_nonce: NONCE, monitor_instance_id: UUID,
      run_root: runRoot, summary_path: summary,
      summary_size: fs.statSync(summary).size,
      summary_sha256: sha256(fs.readFileSync(summary)), certification_eligible: true,
    },
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
    monitor_code_signature_hash: monitorCodeSignatureHash,
    identity_handshake_path: coordinatorHandshake,
    identity_handshake_sha256: sha256(fs.readFileSync(coordinatorHandshake)),
    stdout_path: eventPath,
    stderr_path: coordinatorStderr,
    ...launchEnvironment('coordinator'),
    captured_at_milliseconds: now - 4500,
    coordinator_source_path: coordinatorSource,
    coordinator_source_sha256: sha256(fs.readFileSync(coordinatorSource)),
    execution_source_sha256: sha256(fs.readFileSync(coordinatorSource)),
    execution_plan_sha256: sha256(fs.readFileSync(plan)),
    execution_staged: true,
  });
  const taskContract = agentTaskContractFixture(targetA, targetB);
  if (taskContractMutator !== null) taskContractMutator(taskContract);
  const encodedTask = taskEncoding === 'pretty'
    ? JSON.stringify(taskContract, null, 2)
    : canonicalBytes(taskContract).toString('utf8');
  const taskText = taskTextOverride ?? encodedTask;
  const taskPath = writeFile(path.join(root, 'agent-task.txt'), `${taskText}\n`, 0o400);
  const agentRunRoot = privateDirectory(root, 'agent-run-root');
  const agentReceipts = privateDirectory(agentRunRoot, 'agent-operation-receipts');
  const traceArguments = {
    aMutate: { on: 'fixture-a', snapshot: 'snapshot-a' },
    aRestore: { on: 'fixture-a', snapshot: 'snapshot-a-restore' },
    bMutate: { pid: 302, window_id: 402, foreground: false },
    bRestore: { on: 'fixture-b', snapshot: 'snapshot-b-restore' },
  };
  const entries = [
    traceEntry('a-mutate', 'set_value', 301, 401, traceArguments.aMutate),
    traceEntry('a-restore', 'set_value', 301, 401, traceArguments.aRestore),
    traceEntry('b-mutate', 'paste', 302, 402, traceArguments.bMutate),
    traceEntry('b-restore', 'type', 302, 402, traceArguments.bRestore),
  ];
  const agentTrace = { entries, totalCallCount: entries.length, truncated: false };
  const agentClient = {
    pid: 901,
    start_identity: '901001',
    code_signature_hash: codeSignatureHash(agentExecutable),
  };
  const agentRequester = {
    pid: 899,
    start_identity: '899001',
    code_signature_hash: agentClient.code_signature_hash,
  };
  const terminal = agentTerminalBundleFixture(root, {
    executablePath: agentExecutable,
    bridgeSocket,
    runRoot: agentRunRoot,
    task: taskText,
    trace: agentTrace,
    spawnedAt: now - 4000,
    releasedAt: operationsStart - 100,
    completedAt: now + 1000,
    child: agentClient,
    requester: agentRequester,
    host: planValue.bridge.expected_host,
  });
  const baselineA = semanticReadbackFixture(root, 'a-baseline', targetA, 'baseline', 'alpha', operationsStart + 50);
  const mutationA = semanticReadbackFixture(root, 'a-mutate', targetA, 'mutated', 'alpha!', operationsStart + 250);
  const restorationA = semanticReadbackFixture(root, 'a-restore', targetA, 'restored', 'alpha', operationsStart + 450);
  const baselineB = semanticReadbackFixture(root, 'b-baseline', targetB, 'baseline', 'beta', operationsStart + 350);
  const mutationBObservedAt = operationsStart + (agentFinishesBeforeIntegratedCU
    ? 445 : agentTouchesIntegratedCUBoundary ? 495 : 700);
  const restorationBObservedAt = operationsStart + (agentFinishesBeforeIntegratedCU
    ? 500 : agentTouchesIntegratedCUBoundary ? 600 : 900);
  const mutationB = semanticReadbackFixture(
    root, 'b-mutate', targetB, 'mutated', 'beta!', mutationBObservedAt,
  );
  const restorationB = semanticReadbackFixture(
    root, 'b-restore', targetB, 'restored', 'beta', restorationBObservedAt,
  );
  const bundleA = signedBundleFixture(
    root, 'a-mutate', 'setValue', targetA, operationsStart + 100, operationsStart + 200,
    { directory: agentReceipts, client: agentClient, traceArguments: traceArguments.aMutate },
  );
  const bundleARestore = signedBundleFixture(
    root, 'a-restore', 'setValue', targetA, operationsStart + 300, operationsStart + 400,
    { directory: agentReceipts, client: agentClient, traceArguments: traceArguments.aRestore },
  );
  const bundleB = signedBundleFixture(
    root, 'b-mutate', 'exactWindowTargetedTypeActions', targetB,
    operationsStart + (agentFinishesBeforeIntegratedCU
      ? 410
      : agentTouchesIntegratedCUBoundary ? 450 : 550),
    operationsStart + (agentFinishesBeforeIntegratedCU
      ? 440
      : agentTouchesIntegratedCUBoundary ? 490 : 650),
    { directory: agentReceipts, client: agentClient, traceArguments: traceArguments.bMutate },
  );
  const bundleBRestore = signedBundleFixture(
    root, 'b-restore', 'exactWindowTargetedTypeActions', targetB,
    operationsStart + (agentFinishesBeforeIntegratedCU
      ? 450
      : agentTouchesIntegratedCUBoundary ? 500 : 750),
    operationsStart + (agentFinishesBeforeIntegratedCU
      ? 480
      : agentTouchesIntegratedCUBoundary ? 550 : 850),
    { directory: agentReceipts, client: agentClient, traceArguments: traceArguments.bRestore },
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
  fs.utimesSync(performReadback, new Date(now - 2500), new Date(now - 2500));
  fs.utimesSync(restoreReadback, new Date(now - 1500), new Date(now - 1500));
  const spec = {
    version: 1, plan, coordinator_invocation: coordinatorInvocation,
    coordinator_events: eventPath, coordinator_exit: coordinatorExit,
    agent_task: taskPath,
    agent_run_root: agentRunRoot,
    agent_execution_bundle: terminal.bundle,
    agent_execution_validator_report: terminal.validator,
    agent_bundles: agentBundles,
    agent_readbacks: agentReadbacks,
    integrated_cu: { emitter: emitterSpec, perform_readback: performReadback, restore_readback: restoreReadback },
  };
  return {
    spec,
    terminal,
    summary,
    monitorEvidence,
    semanticReadbacks: [baselineA, mutationA, restorationA, baselineB, mutationB, restorationB],
    agentBundles,
  };
}

function refreshFixtureBundleValidator(spec, entry) {
  const plan = JSON.parse(fs.readFileSync(spec.plan));
  const validator = JSON.parse(fs.readFileSync(entry.validator_report_path));
  validator.data = fixtureAuthenticatedBundle({
    bundlePath: entry.bundle_path,
    expectedHost: plan.bridge.expected_host,
  });
  writeJSON(entry.validator_report_path, validator);
}

function mutateFixtureBundle(spec, entry, mutate) {
  const bundle = JSON.parse(fs.readFileSync(entry.bundle_path));
  mutate(bundle.receipt.payload);
  writeJSON(entry.bundle_path, bundle);
  refreshFixtureBundleValidator(spec, entry);
}

function mutateAgentTerminalBundle(spec, mutate) {
  const bundle = JSON.parse(fs.readFileSync(spec.agent_execution_bundle));
  const responseWire = JSON.parse(Buffer.from(bundle.canonicalResponse, 'base64'));
  const response = responseWire.projectedAction._0.response.agentExecutionTrace._0;
  const stdoutRoot = JSON.parse(Buffer.from(response.stdout.bytes, 'base64'));
  mutate({ response, stdoutRoot, payload: bundle.receipt.payload, responseWire });
  const stdoutBytes = canonicalBytes(stdoutRoot);
  response.stdout.bytes = stdoutBytes.toString('base64');
  response.stdout.sha256 = sha256(stdoutBytes);
  response.stdout.byteCount = stdoutBytes.length;
  response.executionTrace = structuredClone(stdoutRoot.result.executionTrace);
  const responseBytes = canonicalBytes(responseWire);
  bundle.canonicalResponse = responseBytes.toString('base64');
  bundle.receipt.payload.responseSHA256 = sha256(responseBytes);
  writeJSON(spec.agent_execution_bundle, bundle);
  const plan = JSON.parse(fs.readFileSync(spec.plan));
  const validator = JSON.parse(fs.readFileSync(spec.agent_execution_validator_report));
  validator.data = fixtureAuthenticatedBundle({
    bundlePath: spec.agent_execution_bundle,
    expectedHost: plan.bridge.expected_host,
  });
  writeJSON(spec.agent_execution_validator_report, validator);
}

function substituteAgentTerminalTask(spec, taskText) {
  const bundle = JSON.parse(fs.readFileSync(spec.agent_execution_bundle));
  const requestWire = JSON.parse(Buffer.from(bundle.canonicalRequest, 'base64'));
  const responseWire = JSON.parse(Buffer.from(bundle.canonicalResponse, 'base64'));
  const request = requestWire.projectedAction._0.request.agentExecutionTrace._0;
  const response = responseWire.projectedAction._0.response.agentExecutionTrace._0;
  request.task = taskText;
  const taskSHA256 = sha256(Buffer.from(taskText, 'utf8'));
  response.taskSHA256 = taskSHA256;
  response.arguments[2] = taskText;
  response.argumentsSHA256 = sha256(canonicalBytes(response.arguments));
  const acknowledgement = JSON.parse(Buffer.from(response.acknowledgement.bytes, 'base64'));
  acknowledgement.taskSHA256 = taskSHA256;
  acknowledgement.argumentsSHA256 = response.argumentsSHA256;
  const acknowledgementBytes = canonicalBytes(acknowledgement);
  writeFile(response.acknowledgementPath, acknowledgementBytes);
  response.acknowledgement = {
    bytes: acknowledgementBytes.toString('base64'),
    sha256: sha256(acknowledgementBytes),
    byteCount: acknowledgementBytes.length,
    truncated: false,
    readErrorCode: null,
  };
  const requestBytes = canonicalBytes(requestWire);
  const responseBytes = canonicalBytes(responseWire);
  bundle.canonicalRequest = requestBytes.toString('base64');
  bundle.canonicalResponse = responseBytes.toString('base64');
  bundle.receipt.payload.requestSHA256 = sha256(requestBytes);
  bundle.receipt.payload.responseSHA256 = sha256(responseBytes);
  fs.chmodSync(spec.agent_task, 0o600);
  writeFile(spec.agent_task, `${taskText}\n`, 0o400);
  writeJSON(spec.agent_execution_bundle, bundle);
  const plan = JSON.parse(fs.readFileSync(spec.plan));
  const validator = JSON.parse(fs.readFileSync(spec.agent_execution_validator_report));
  validator.data = fixtureAuthenticatedBundle({
    bundlePath: spec.agent_execution_bundle,
    expectedHost: plan.bridge.expected_host,
  });
  writeJSON(spec.agent_execution_validator_report, validator);
  return { response, taskSHA256 };
}

function resealAgentTarget(fixture, targetIndex, replacement) {
  const readbackMap = JSON.parse(fs.readFileSync(fixture.spec.agent_readbacks));
  const targetEntry = readbackMap.targets[targetIndex];
  targetEntry.target = structuredClone(replacement);

  const semanticPaths = [
    targetEntry.baseline_readback_path,
    targetEntry.mutation.readback_path,
    targetEntry.restoration.readback_path,
  ];
  for (const filePath of semanticPaths) {
    const readback = JSON.parse(fs.readFileSync(filePath));
    readback.target = structuredClone(replacement);
    writeJSON(filePath, readback);
    fs.utimesSync(
      filePath,
      new Date(readback.observed_at_milliseconds),
      new Date(readback.observed_at_milliseconds),
    );
  }

  for (const action of [targetEntry.mutation, targetEntry.restoration]) {
    const bundle = JSON.parse(fs.readFileSync(action.bundle_path));
    bundle.receipt.payload.target.processIdentifier = replacement.pid;
    bundle.receipt.payload.target.processStartIdentity = replacement.start_identity;
    bundle.receipt.payload.target.windowID = replacement.window_id;
    writeJSON(action.bundle_path, bundle);
    const validator = JSON.parse(fs.readFileSync(action.validator_report_path));
    validator.data.bundle_sha256 = sha256(fs.readFileSync(action.bundle_path));
    writeJSON(action.validator_report_path, validator);
  }

  const traceCallIDs = new Set([
    targetEntry.mutation.trace_call_id,
    targetEntry.restoration.trace_call_id,
  ]);
  mutateAgentTerminalBundle(fixture.spec, ({ stdoutRoot }) => {
    for (const entry of stdoutRoot.result.executionTrace.entries) {
      if (traceCallIDs.has(entry.id)) {
        entry.arguments.pid = replacement.pid;
        entry.arguments.window_id = replacement.window_id;
      }
    }
  });
  writeJSON(fixture.spec.agent_readbacks, readbackMap);
}

test('post-run validator rejects signed-consistent complex Agent-task substitutions', async (t) => {
  const cases = [
    {
      name: 'empty task',
      options: { taskTextOverride: '' },
      error: /closed UTF-8 JSON contract/,
    },
    {
      name: 'plausible but unstructured task',
      options: {
        taskTextOverride: 'Operate safely in the background on two controlled windows and restore them.',
      },
      error: /closed machine-readable JSON contract/,
    },
    {
      name: 'empty semantic goal',
      options: {
        taskContractMutator: (contract) => {
          contract.goal = '';
        },
      },
      error: /goal is not the closed concurrent qualification goal/,
    },
    {
      name: 'open task contract',
      options: {
        taskContractMutator: (contract) => {
          contract.caller_claim = true;
        },
      },
      error: /Agent task contract keys are not closed/,
    },
    {
      name: 'noncanonical task encoding',
      options: { taskEncoding: 'pretty' },
      error: /canonical JSON encoding/,
    },
    {
      name: 'plausible but wrong expected value',
      options: {
        taskContractMutator: (contract) => {
          contract.targets[0].steps[1].expected_value = 'alpha?';
          contract.targets[0].steps[2].expected_value = 'alpha?';
        },
      },
      error: /mutation readback differs from its signed task expected value/,
    },
    {
      name: 'cross-target expectation substitution',
      options: {
        taskContractMutator: (contract) => {
          const firstValues = contract.targets[0].steps.map((step) => step.expected_value);
          const secondValues = contract.targets[1].steps.map((step) => step.expected_value);
          contract.targets[0].steps.forEach((step, index) => {
            step.expected_value = secondValues[index];
          });
          contract.targets[1].steps.forEach((step, index) => {
            step.expected_value = firstValues[index];
          });
        },
      },
      error: /baseline differs from its signed task expectation/,
    },
    {
      name: 'task-goal substitution',
      options: {
        taskContractMutator: (contract) => {
          contract.goal = 'observe-two-controlled-targets-and-report';
        },
      },
      error: /goal is not the closed concurrent qualification goal/,
    },
    {
      name: 'non-novel restoration family',
      options: {
        taskContractMutator: (contract) => {
          contract.targets[1].steps[3].family = 'set_value';
        },
      },
      error: /restoration family outside the primary mutations/,
    },
  ];
  for (const item of cases) {
    await t.test(item.name, () => {
      const root = fs.mkdtempSync('/private/tmp/pbq-tools-task-contract-');
      fs.chmodSync(root, 0o700);
      try {
        const fix = concurrentFixture(root, item.options);
        const specPath = writeJSON(path.join(root, 'validation-input.json'), fix.spec);
        assert.throws(
          () => validateConcurrentRun(specPath, path.join(root, 'invalid-task-report.json')),
          item.error,
        );
      } finally {
        fs.rmSync(root, { recursive: true, force: true });
      }
    });
  }
});

test('post-run validator requires zero exits, exact Agent generation, background trace, restoration, and overlap', () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-tools-validate-');
  fs.chmodSync(root, 0o700);
  try {
    const fix = concurrentFixture(root);
    const specPath = writeJSON(path.join(root, 'validation-input.json'), fix.spec);
    const output = path.join(root, 'validation-report.json');
    const result = validateConcurrentRun(specPath, output);
    assert.equal(result.report.passed, true);
    const taskFileBytes = fs.readFileSync(fix.spec.agent_task);
    const signedTaskBytes = taskFileBytes.subarray(0, taskFileBytes.length - 1);
    assert.equal(result.report.agent.task_contract.task_file_sha256, sha256(taskFileBytes));
    assert.equal(result.report.agent.task_contract.signed_task_sha256, sha256(signedTaskBytes));
    assert.equal(
      result.report.agent.task_contract.semantic_contract_sha256,
      sha256(canonicalBytes(JSON.parse(signedTaskBytes.toString('utf8')))),
    );
    assert.deepEqual(result.report.agent.mutation_families, ['paste', 'set_value']);
    assert.equal(result.report.overlap.agent_covers_operation_interval, true);
    assert.equal(
      result.report.agent.progress_interleaving
        .integrated_cu_perform_readback_mtime_milliseconds,
      Number(fs.statSync(fix.spec.integrated_cu.perform_readback, { bigint: true }).mtimeNs / 1_000_000n),
    );

    const performValue = JSON.parse(fs.readFileSync(fix.spec.integrated_cu.perform_readback));
    fs.utimesSync(
      fix.spec.integrated_cu.perform_readback,
      new Date(performValue.observed_at_milliseconds + 3000),
      new Date(performValue.observed_at_milliseconds + 3000),
    );
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'uncorroborated-perform-report.json')),
      /integrated-CU perform readback file time does not corroborate its observation time/,
    );
    fs.utimesSync(
      fix.spec.integrated_cu.perform_readback,
      new Date(performValue.observed_at_milliseconds),
      new Date(performValue.observed_at_milliseconds),
    );

    const baselineABytes = fs.readFileSync(fix.semanticReadbacks[0]);
    const baselineAValue = JSON.parse(baselineABytes);
    baselineAValue.observed_at_milliseconds
      = result.report.overlap.operations_started_at_milliseconds + 101;
    writeJSON(fix.semanticReadbacks[0], baselineAValue);
    fs.utimesSync(
      fix.semanticReadbacks[0],
      new Date(baselineAValue.observed_at_milliseconds),
      new Date(baselineAValue.observed_at_milliseconds),
    );
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'late-baseline-report.json')),
      /baseline\/mutation\/restoration order is invalid/,
    );
    writeFile(fix.semanticReadbacks[0], baselineABytes);
    fs.utimesSync(
      fix.semanticReadbacks[0],
      new Date(JSON.parse(baselineABytes).observed_at_milliseconds),
      new Date(JSON.parse(baselineABytes).observed_at_milliseconds),
    );

    const mutationABytes = fs.readFileSync(fix.semanticReadbacks[1]);
    const mutationAValue = JSON.parse(mutationABytes);
    mutationAValue.observed_at_milliseconds
      = result.report.overlap.operations_started_at_milliseconds + 301;
    writeJSON(fix.semanticReadbacks[1], mutationAValue);
    fs.utimesSync(
      fix.semanticReadbacks[1],
      new Date(mutationAValue.observed_at_milliseconds),
      new Date(mutationAValue.observed_at_milliseconds),
    );
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'late-mutation-observation-report.json')),
      /baseline\/mutation\/restoration order is invalid/,
    );
    writeFile(fix.semanticReadbacks[1], mutationABytes);
    fs.utimesSync(
      fix.semanticReadbacks[1],
      new Date(JSON.parse(mutationABytes).observed_at_milliseconds),
      new Date(JSON.parse(mutationABytes).observed_at_milliseconds),
    );

    const originalTerminalBundle = fs.readFileSync(fix.spec.agent_execution_bundle);
    const originalTerminalValidator = fs.readFileSync(fix.spec.agent_execution_validator_report);
    mutateAgentTerminalBundle(fix.spec, ({ stdoutRoot }) => {
      stdoutRoot.result.executionTrace.entries[0].actionOutcome.delivery_mode = 'foreground';
    });
    assert.throws(() => validateConcurrentRun(specPath, path.join(root, 'bad-report.json')), /foreground delivery/);
    writeFile(fix.spec.agent_execution_bundle, originalTerminalBundle);
    writeFile(fix.spec.agent_execution_validator_report, originalTerminalValidator);

    mutateAgentTerminalBundle(fix.spec, ({ stdoutRoot }) => {
      stdoutRoot.result.executionTrace.entries.push(traceEntry('extra-mutation', 'click', 303, 403));
      stdoutRoot.result.executionTrace.totalCallCount += 1;
    });
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'extra-report.json')),
      /exactly the four mapped dispatched mutation call IDs/,
    );
    writeFile(fix.spec.agent_execution_bundle, originalTerminalBundle);
    writeFile(fix.spec.agent_execution_validator_report, originalTerminalValidator);

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
      /retained validator report differs from authenticated live validation/,
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

    const receiptDirectory = path.join(fix.spec.agent_run_root, 'agent-operation-receipts');
    writeJSON(path.join(receiptDirectory, 'unlisted.json'), { unexpected: true });
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'unlisted-report.json')),
      /does not equal the complete receipt-directory inventory/,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('post-run validator deduplicates signed receipts by bytes and authenticated identity', async (t) => {
  const cases = [
    ['copied bundle', (source, duplicate) => fs.copyFileSync(source, duplicate)],
    ['hard-linked bundle', (source, duplicate) => fs.linkSync(source, duplicate)],
  ];
  for (const [name, duplicateBundle] of cases) {
    await t.test(name, () => {
      const root = fs.mkdtempSync('/private/tmp/pbq-tools-receipt-duplicate-');
      fs.chmodSync(root, 0o700);
      try {
        const fix = concurrentFixture(root);
        const source = fix.agentBundles[0];
        const receiptDirectory = path.dirname(source.bundle_path);
        const duplicatePath = path.join(receiptDirectory, `${name.replaceAll(' ', '-')}.json`);
        const duplicateValidator = path.join(root, `${name.replaceAll(' ', '-')}-validator.json`);
        duplicateBundle(source.bundle_path, duplicatePath);
        fs.chmodSync(duplicatePath, 0o600);
        fs.copyFileSync(source.validator_report_path, duplicateValidator);
        fs.chmodSync(duplicateValidator, 0o600);
        fix.spec.agent_bundles.push({
          bundle_path: duplicatePath,
          validator_report_path: duplicateValidator,
        });
        const specPath = writeJSON(path.join(root, 'validation-input.json'), fix.spec);
        assert.throws(
          () => validateConcurrentRun(specPath, path.join(root, 'duplicate-report.json')),
          /reuses a bundle SHA-256/,
        );
      } finally {
        fs.rmSync(root, { recursive: true, force: true });
      }
    });
  }

  await t.test('repeated request identity with distinct bytes', () => {
    const root = fs.mkdtempSync('/private/tmp/pbq-tools-request-duplicate-');
    fs.chmodSync(root, 0o700);
    try {
      const fix = concurrentFixture(root);
      const first = JSON.parse(fs.readFileSync(fix.agentBundles[0].bundle_path)).receipt.payload;
      mutateFixtureBundle(fix.spec, fix.agentBundles[1], (payload) => {
        payload.requestID = first.requestID;
      });
      const specPath = writeJSON(path.join(root, 'validation-input.json'), fix.spec);
      assert.throws(
        () => validateConcurrentRun(specPath, path.join(root, 'duplicate-request-report.json')),
        /reuses an authenticated request identity/,
      );
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });

  await t.test('repeated listener-session claim with distinct request and bytes', () => {
    const root = fs.mkdtempSync('/private/tmp/pbq-tools-session-duplicate-');
    fs.chmodSync(root, 0o700);
    try {
      const fix = concurrentFixture(root);
      const first = JSON.parse(fs.readFileSync(fix.agentBundles[0].bundle_path)).receipt.payload;
      mutateFixtureBundle(fix.spec, fix.agentBundles[1], (payload) => {
        payload.listenerInstanceID = first.listenerInstanceID;
        payload.sessionID = first.sessionID;
        payload.sessionSequence = first.sessionSequence;
      });
      const specPath = writeJSON(path.join(root, 'validation-input.json'), fix.spec);
      assert.throws(
        () => validateConcurrentRun(specPath, path.join(root, 'duplicate-session-report.json')),
        /reuses an authenticated session claim/,
      );
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });
});

test('post-run validator rejects trace remapping through a copied signed receipt', () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-tools-trace-remap-');
  fs.chmodSync(root, 0o700);
  try {
    const fix = concurrentFixture(root);
    const readbacks = JSON.parse(fs.readFileSync(fix.spec.agent_readbacks));
    const mutation = readbacks.targets[0].mutation;
    const restoration = readbacks.targets[0].restoration;
    fs.copyFileSync(mutation.bundle_path, restoration.bundle_path);
    fs.chmodSync(restoration.bundle_path, 0o600);
    refreshFixtureBundleValidator(fix.spec, {
      bundle_path: restoration.bundle_path,
      validator_report_path: restoration.validator_report_path,
    });
    const specPath = writeJSON(path.join(root, 'validation-input.json'), fix.spec);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'remapped-report.json')),
      /reuses a bundle SHA-256/,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('post-run validator binds every allowed trace target to its signed Bridge request', async (t) => {
  const cases = [
    {
      name: 'set-value snapshot substitution',
      index: 0,
      mutate: (arguments_) => { arguments_.snapshot = 'substituted-set-value-snapshot'; },
      error: /trace selectors differ from the signed Bridge request/,
    },
    {
      name: 'paste exact-target substitution',
      index: 2,
      mutate: (arguments_) => {
        arguments_.pid = 999;
        arguments_.window_id = 1999;
      },
      error: /exact trace target differs from the signed Bridge request target/,
    },
    {
      name: 'type snapshot substitution',
      index: 3,
      mutate: (arguments_) => { arguments_.snapshot = 'substituted-type-snapshot'; },
      error: /trace snapshot differs from the signed Bridge request/,
    },
  ];
  for (const testCase of cases) {
    await t.test(testCase.name, () => {
      const root = fs.mkdtempSync('/private/tmp/pbq-tools-trace-request-binding-');
      fs.chmodSync(root, 0o700);
      try {
        const fix = concurrentFixture(root);
        mutateAgentTerminalBundle(fix.spec, ({ stdoutRoot }) => {
          testCase.mutate(stdoutRoot.result.executionTrace.entries[testCase.index].arguments);
        });
        const specPath = writeJSON(path.join(root, 'validation-input.json'), fix.spec);
        assert.throws(
          () => validateConcurrentRun(specPath, path.join(root, 'binding-substitution-report.json')),
          testCase.error,
        );
      } finally {
        fs.rmSync(root, { recursive: true, force: true });
      }
    });
  }
});

test('post-run validator requires one closed successful certification summary', () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-tools-summary-');
  fs.chmodSync(root, 0o700);
  try {
    const fix = concurrentFixture(root);
    const specPath = writeJSON(path.join(root, 'validation-input.json'), fix.spec);
    const originalSummary = fs.readFileSync(fix.summary);

    writeFile(fix.summary, `${originalSummary.toString('utf8').trimEnd()} \n`);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'summary-drift-report.json')),
      /differs from the coordinator completion commitment/,
    );

    writeFile(fix.summary, '{ malformed\n');
    updateCoordinatorSummaryCommitment(fix.spec.coordinator_events, fix.summary);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'malformed-summary-report.json')),
      /final certification summary is not JSON/,
    );

    const openSummary = JSON.parse(originalSummary);
    openSummary.caller_success = true;
    writeJSON(fix.summary, openSummary);
    updateCoordinatorSummaryCommitment(fix.spec.coordinator_events, fix.summary);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'open-summary-report.json')),
      /not one closed version-2 object/,
    );

    const failedNestedSummary = JSON.parse(originalSummary);
    failedNestedSummary.first_party_verdicts[0].verdict.valid = false;
    failedNestedSummary.first_party_verdict_set_sha256 = multiTargetAggregateSHA256(
      'first-party-verdict-set', failedNestedSummary.first_party_verdicts,
    );
    failedNestedSummary.slot_verdicts[0].first_party_verdict_sha256
      = multiTargetAggregateSHA256(
        'first-party-verdict', failedNestedSummary.first_party_verdicts[0],
      );
    delete failedNestedSummary.summary_core_sha256;
    failedNestedSummary.summary_core_sha256 = multiTargetAggregateSHA256(
      'summary-core', failedNestedSummary,
    );
    writeJSON(fix.summary, failedNestedSummary);
    updateCoordinatorSummaryCommitment(fix.spec.coordinator_events, fix.summary);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'failed-nested-summary-report.json')),
      /first-party verdict rows are not closed/,
    );

    const emptyNestedSummary = JSON.parse(originalSummary);
    emptyNestedSummary.first_party_verdicts[0].verdict.host = {};
    emptyNestedSummary.first_party_verdict_set_sha256 = multiTargetAggregateSHA256(
      'first-party-verdict-set', emptyNestedSummary.first_party_verdicts,
    );
    emptyNestedSummary.slot_verdicts[0].first_party_verdict_sha256
      = multiTargetAggregateSHA256(
        'first-party-verdict', emptyNestedSummary.first_party_verdicts[0],
      );
    delete emptyNestedSummary.summary_core_sha256;
    emptyNestedSummary.summary_core_sha256 = multiTargetAggregateSHA256(
      'summary-core', emptyNestedSummary,
    );
    writeJSON(fix.summary, emptyNestedSummary);
    updateCoordinatorSummaryCommitment(fix.spec.coordinator_events, fix.summary);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'empty-nested-summary-report.json')),
      /first-party verdict rows are not closed/,
    );

    const openNestedSummary = JSON.parse(originalSummary);
    openNestedSummary.offline_protocol_validation.receipts[0].caller_success = true;
    openNestedSummary.offline_protocol_validation_sha256 = multiTargetAggregateSHA256(
      'offline-protocol-validation', openNestedSummary.offline_protocol_validation,
    );
    openNestedSummary.slot_verdicts[0].offline_receipt_sha256 = multiTargetAggregateSHA256(
      'offline-receipt', openNestedSummary.offline_protocol_validation.receipts[0],
    );
    delete openNestedSummary.summary_core_sha256;
    openNestedSummary.summary_core_sha256 = multiTargetAggregateSHA256(
      'summary-core', openNestedSummary,
    );
    writeJSON(fix.summary, openNestedSummary);
    updateCoordinatorSummaryCommitment(fix.spec.coordinator_events, fix.summary);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'open-nested-summary-report.json')),
      /offline receipt rows are not closed/,
    );

    const foreignCatalogSummary = JSON.parse(originalSummary);
    foreignCatalogSummary.catalog_file_sha256 = '0'.repeat(64);
    delete foreignCatalogSummary.summary_core_sha256;
    foreignCatalogSummary.summary_core_sha256 = multiTargetAggregateSHA256(
      'summary-core', foreignCatalogSummary,
    );
    writeJSON(fix.summary, foreignCatalogSummary);
    updateCoordinatorSummaryCommitment(fix.spec.coordinator_events, fix.summary);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'foreign-catalog-summary-report.json')),
      /coordinator exit interval does not contain its JSONL evidence|not one successful live certification core/,
    );

    const mixedSlotSummary = JSON.parse(originalSummary);
    mixedSlotSummary.slot_verdicts[0].request_id = 'another-request';
    delete mixedSlotSummary.summary_core_sha256;
    mixedSlotSummary.summary_core_sha256 = multiTargetAggregateSHA256(
      'summary-core', mixedSlotSummary,
    );
    writeJSON(fix.summary, mixedSlotSummary);
    updateCoordinatorSummaryCommitment(fix.spec.coordinator_events, fix.summary);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'mixed-slot-summary-report.json')),
      /slot evidence commitments are invalid/,
    );

    const unlistedTargetSummary = JSON.parse(originalSummary);
    unlistedTargetSummary.offline_protocol_validation.receipts[0].target_id = 'target-c';
    unlistedTargetSummary.offline_protocol_validation_sha256 = multiTargetAggregateSHA256(
      'offline-protocol-validation', unlistedTargetSummary.offline_protocol_validation,
    );
    unlistedTargetSummary.slot_verdicts[0].offline_receipt_sha256
      = multiTargetAggregateSHA256(
        'offline-receipt', unlistedTargetSummary.offline_protocol_validation.receipts[0],
      );
    delete unlistedTargetSummary.summary_core_sha256;
    unlistedTargetSummary.summary_core_sha256 = multiTargetAggregateSHA256(
      'summary-core', unlistedTargetSummary,
    );
    writeJSON(fix.summary, unlistedTargetSummary);
    updateCoordinatorSummaryCommitment(fix.spec.coordinator_events, fix.summary);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'unlisted-target-summary-report.json')),
      /slot evidence commitments are invalid/,
    );

    const duplicatePhysicalTargetSummary = JSON.parse(originalSummary);
    duplicatePhysicalTargetSummary.offline_protocol_validation.receipts[1].target
      = structuredClone(duplicatePhysicalTargetSummary.offline_protocol_validation.receipts[0].target);
    duplicatePhysicalTargetSummary.controlled_targets[1].target_sha256
      = multiTargetAggregateSHA256(
        'controlled-target',
        duplicatePhysicalTargetSummary.offline_protocol_validation.receipts[1].target,
      );
    duplicatePhysicalTargetSummary.offline_protocol_validation_sha256
      = multiTargetAggregateSHA256(
        'offline-protocol-validation',
        duplicatePhysicalTargetSummary.offline_protocol_validation,
      );
    duplicatePhysicalTargetSummary.slot_verdicts[1].offline_receipt_sha256
      = multiTargetAggregateSHA256(
        'offline-receipt',
        duplicatePhysicalTargetSummary.offline_protocol_validation.receipts[1],
      );
    delete duplicatePhysicalTargetSummary.summary_core_sha256;
    duplicatePhysicalTargetSummary.summary_core_sha256 = multiTargetAggregateSHA256(
      'summary-core', duplicatePhysicalTargetSummary,
    );
    writeJSON(fix.summary, duplicatePhysicalTargetSummary);
    updateCoordinatorSummaryCommitment(fix.spec.coordinator_events, fix.summary);
    assert.throws(
      () => validateConcurrentRun(
        specPath,
        path.join(root, 'duplicate-physical-target-summary-report.json'),
      ),
      /controlled targets are not physically distinct/,
    );

    const foreignMonitorSummary = JSON.parse(originalSummary);
    foreignMonitorSummary.monitor_evidence_sha256 = multiTargetAggregateSHA256(
      'monitor-evidence', { another: 'run' },
    );
    delete foreignMonitorSummary.summary_core_sha256;
    foreignMonitorSummary.summary_core_sha256 = multiTargetAggregateSHA256(
      'summary-core', foreignMonitorSummary,
    );
    writeJSON(fix.summary, foreignMonitorSummary);
    updateCoordinatorSummaryCommitment(fix.spec.coordinator_events, fix.summary);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'foreign-monitor-summary-report.json')),
      /belongs to another monitor run/,
    );

    const failedSummary = JSON.parse(originalSummary);
    failedSummary.structural_validation_passed = false;
    failedSummary.failures = [{ rule: 'fixture_failure', message: 'failed', slot_id: null }];
    delete failedSummary.summary_core_sha256;
    failedSummary.summary_core_sha256 = multiTargetAggregateSHA256('summary-core', failedSummary);
    writeJSON(fix.summary, failedSummary);
    updateCoordinatorSummaryCommitment(fix.spec.coordinator_events, fix.summary);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'failed-summary-report.json')),
      /not one successful live certification core/,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('post-run validator requires positive signed durations and strict readback ordering', async (t) => {
  await t.test('zero-duration dispatch', () => {
    const root = fs.mkdtempSync('/private/tmp/pbq-tools-zero-duration-');
    fs.chmodSync(root, 0o700);
    try {
      const fix = concurrentFixture(root);
      mutateFixtureBundle(fix.spec, fix.agentBundles[0], (payload) => {
        payload.completedAtUnixMilliseconds = payload.startedAtUnixMilliseconds;
      });
      const specPath = writeJSON(path.join(root, 'validation-input.json'), fix.spec);
      assert.throws(
        () => validateConcurrentRun(specPath, path.join(root, 'zero-duration-report.json')),
        /signed payload is malformed/,
      );
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });

  await t.test('readback at dispatch completion', () => {
    const root = fs.mkdtempSync('/private/tmp/pbq-tools-equal-readback-');
    fs.chmodSync(root, 0o700);
    try {
      const fix = concurrentFixture(root);
      const payload = JSON.parse(fs.readFileSync(fix.agentBundles[0].bundle_path)).receipt.payload;
      const readbackPath = fix.semanticReadbacks[1];
      const readback = JSON.parse(fs.readFileSync(readbackPath));
      readback.observed_at_milliseconds = payload.completedAtUnixMilliseconds;
      writeJSON(readbackPath, readback);
      fs.utimesSync(readbackPath, new Date(readback.observed_at_milliseconds), new Date(readback.observed_at_milliseconds));
      const specPath = writeJSON(path.join(root, 'validation-input.json'), fix.spec);
      assert.throws(
        () => validateConcurrentRun(specPath, path.join(root, 'equal-readback-report.json')),
        /does not strictly follow its signed dispatch/,
      );
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });

  await t.test('cross-target signed interval overlap', () => {
    const root = fs.mkdtempSync('/private/tmp/pbq-tools-overlapping-actions-');
    fs.chmodSync(root, 0o700);
    try {
      const fix = concurrentFixture(root);
      const firstPayload = JSON.parse(
        fs.readFileSync(fix.agentBundles[0].bundle_path),
      ).receipt.payload;
      const operationsStart = firstPayload.startedAtUnixMilliseconds - 100;
      mutateFixtureBundle(fix.spec, fix.agentBundles[2], (payload) => {
        payload.startedAtUnixMilliseconds = operationsStart + 360;
        payload.completedAtUnixMilliseconds = operationsStart + 390;
      });
      const specPath = writeJSON(path.join(root, 'validation-input.json'), fix.spec);
      assert.throws(
        () => validateConcurrentRun(specPath, path.join(root, 'overlapping-actions-report.json')),
        /signed mutation intervals do not follow the task action order/,
      );
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });
});

test('post-run validator does not accept caller-authored validator JSON without live authentication', () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-tools-validator-auth-');
  fs.chmodSync(root, 0o700);
  try {
    const fix = concurrentFixture(root);
    const specPath = writeJSON(path.join(root, 'validation-input.json'), fix.spec);
    assert.throws(
      () => validateConcurrentRunProduction(
        specPath,
        path.join(root, 'unauthenticated-report.json'),
      ),
      /authenticated live validation returned invalid JSON/,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('post-run validator rejects an unrelated Agent window after all caller evidence is resealed', () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-tools-unrelated-target-');
  fs.chmodSync(root, 0o700);
  try {
    const fix = concurrentFixture(root);
    resealAgentTarget(fix, 0, { pid: 999, start_identity: '999001', window_id: 1999 });
    const specPath = writeJSON(path.join(root, 'validation-input.json'), fix.spec);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'unrelated-target-report.json')),
      /not its exact live-v4 controlled fixture target/,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('post-run validator rejects swapped Agent fixture identities after every claim is resealed', () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-tools-swapped-targets-');
  fs.chmodSync(root, 0o700);
  try {
    const fix = concurrentFixture(root);
    const readbacks = JSON.parse(fs.readFileSync(fix.spec.agent_readbacks));
    const first = structuredClone(readbacks.targets[0].target);
    const second = structuredClone(readbacks.targets[1].target);
    resealAgentTarget(fix, 0, second);
    resealAgentTarget(fix, 1, first);
    const specPath = writeJSON(path.join(root, 'validation-input.json'), fix.spec);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'swapped-targets-report.json')),
      /not its exact live-v4 controlled fixture target/,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

for (const [name, replacement] of [
  ['generation', { pid: 301, start_identity: '301999', window_id: 401 }],
  ['window', { pid: 301, start_identity: '301001', window_id: 1401 }],
]) {
  test(`post-run validator rejects resealed Agent ${name} drift`, () => {
    const root = fs.mkdtempSync(`/private/tmp/pbq-tools-${name}-drift-`);
    fs.chmodSync(root, 0o700);
    try {
      const fix = concurrentFixture(root);
      resealAgentTarget(fix, 0, replacement);
      const specPath = writeJSON(path.join(root, 'validation-input.json'), fix.spec);
      assert.throws(
        () => validateConcurrentRun(specPath, path.join(root, `${name}-drift-report.json`)),
        /not its exact live-v4 controlled fixture target/,
      );
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });
}

test('post-run validator requires Agent progress on both sides of integrated Computer Use', () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-tools-interleaving-');
  fs.chmodSync(root, 0o700);
  try {
    const fix = concurrentFixture(root, { agentFinishesBeforeIntegratedCU: true });
    const specPath = writeJSON(path.join(root, 'validation-input.json'), fix.spec);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'non-interleaved-report.json')),
      /progress both before and after integrated Computer Use/,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('post-run validator requires strict progress beyond the integrated-CU boundary', () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-tools-strict-interleaving-');
  fs.chmodSync(root, 0o700);
  try {
    const fix = concurrentFixture(root, { agentTouchesIntegratedCUBoundary: true });
    const specPath = writeJSON(path.join(root, 'validation-input.json'), fix.spec);
    assert.throws(
      () => validateConcurrentRun(specPath, path.join(root, 'boundary-report.json')),
      /progress both before and after integrated Computer Use/,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('source manifest binds exact clean Git HEAD blobs and rejects hidden byte drift', () => {
  const root = fs.mkdtempSync('/private/tmp/pbq-source-proof-');
  fs.chmodSync(root, 0o700);
  const repository = privateDirectory(root, 'repository');
  const evidenceRoot = privateDirectory(root, 'evidence');
  const runGit = (...arguments_) => {
    const result = spawnSync('/usr/bin/git', ['-C', repository, ...arguments_], {
      encoding: 'utf8',
      env: {
        PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
        LANG: 'C',
        LC_ALL: 'C',
        GIT_AUTHOR_DATE: '2000-01-01T00:00:00Z',
        GIT_COMMITTER_DATE: '2000-01-01T00:00:00Z',
      },
    });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  try {
    writeFile(path.join(repository, 'bound.txt'), 'bound\n', 0o644);
    writeFile(path.join(repository, 'other.txt'), 'other\n', 0o644);
    runGit('init', '--quiet');
    runGit('config', 'user.name', 'Qualification Fixture');
    runGit('config', 'user.email', 'qualification@example.invalid');
    runGit('add', '--all');
    runGit('commit', '--quiet', '-m', 'initial');
    const sourceCommit = runGit('rev-parse', 'HEAD');
    const manifestPath = path.join(evidenceRoot, 'source.json');
    generateSourceManifest(repository, ['bound.txt'], manifestPath, sourceCommit);
    fs.chmodSync(manifestPath, 0o400);
    assert.equal(
      verifySourceManifest(manifestPath, ['bound.txt'], sourceCommit).value.source_commit,
      sourceCommit,
    );

    assert.throws(
      () => generateSourceManifest(
        repository,
        ['bound.txt'],
        path.join(evidenceRoot, 'fake-source.json'),
        '0'.repeat(40),
      ),
      /commit is not the exact repository HEAD/,
    );
    writeFile(path.join(repository, 'other.txt'), 'dirty\n', 0o644);
    assert.throws(
      () => generateSourceManifest(
        repository,
        ['bound.txt'],
        path.join(evidenceRoot, 'dirty-source.json'),
        sourceCommit,
      ),
      /pre-read tree is not clean/,
    );
    writeFile(path.join(repository, 'other.txt'), 'other\n', 0o644);
    writeFile(path.join(repository, 'untracked.txt'), 'untracked\n', 0o644);
    assert.throws(
      () => generateSourceManifest(
        repository,
        ['bound.txt'],
        path.join(evidenceRoot, 'untracked-source.json'),
        sourceCommit,
      ),
      /pre-read tree is not clean/,
    );
    fs.unlinkSync(path.join(repository, 'untracked.txt'));

    runGit('update-index', '--skip-worktree', 'bound.txt');
    writeFile(path.join(repository, 'bound.txt'), 'hidden drift\n', 0o644);
    assert.throws(
      () => generateSourceManifest(
        repository,
        ['bound.txt'],
        path.join(evidenceRoot, 'hidden-drift-source.json'),
        sourceCommit,
      ),
      /differs from commit/,
    );
    writeFile(path.join(repository, 'bound.txt'), 'bound\n', 0o644);
    runGit('update-index', '--no-skip-worktree', 'bound.txt');

    writeFile(path.join(repository, 'other.txt'), 'new clean head\n', 0o644);
    runGit('add', 'other.txt');
    runGit('commit', '--quiet', '-m', 'advance head');
    assert.throws(
      () => verifySourceManifest(manifestPath, ['bound.txt'], sourceCommit),
      /commit is not the exact repository HEAD/,
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
    const matrixStartedAt = Date.now() - 200_000;
    const matrixCLICDHash = codeSignatureHash('/usr/bin/true');
    const matrix = Array.from({ length: 5 }, (_, cycleIndex) => {
      const cycle = cycleIndex + 1;
      const startedAt = matrixStartedAt + (cycleIndex * 10_000);
      const completedAt = startedAt + 5000;
      const executionNonce = `${cycle}`.repeat(64);
      const alertLifecycle = playgroundAlertLifecycleFixture(
        root, cycle, executionNonce, startedAt, matrixCLICDHash,
      );
      return {
        certificate: writeJSON(path.join(root, `matrix-${cycle}.json`), {
          version: 2,
          cycle,
          success: true,
          catalog_version: 2,
          expected_cases: 42,
          observed_cases: 42,
          failures: [],
          execution_nonce: executionNonce,
          host_uuid: LOCAL_UUID,
          peekaboo_source_commit: SOURCE,
          bridge_source_commit: SOURCE,
          started_at_milliseconds: startedAt,
          completed_at_milliseconds: completedAt,
        }),
        crash_inventory: writeJSON(path.join(root, `crash-${cycle}.json`), {
          version: 2,
          cycle,
          execution_nonce: executionNonce,
          host_uuid: LOCAL_UUID,
          peekaboo_source_commit: SOURCE,
          started_at_milliseconds: startedAt - 10,
          completed_at_milliseconds: completedAt + 10,
          passed: true,
          added: [],
          changed: [],
          removed: [],
        }),
        playground_alert_lifecycle: alertLifecycle.reportPath,
      };
    });
    const adjunctTarget = { pid: 301, start_identity: '301001', window_id: 401 };
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
    const pointerHost = { pid: 200, start_identity: '200001', code_signature_hash: 'd'.repeat(40) };
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
          targetAbsent: [
            'createExactWindowHeldPointerOwner', 'disconnectExactWindowHeldPointerOwner',
          ].includes(operation),
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
    const toolsManifest = path.join(root, 'qualification-tools-source.json');
    generateSourceManifest(
      qualificationRepositoryRoot,
      qualificationSourceFiles,
      toolsManifest,
      SOURCE,
    );
    fs.chmodSync(toolsManifest, 0o400);
    const coordinatorInvocation = JSON.parse(fs.readFileSync(concurrent.spec.coordinator_invocation));
    const liveEvents = fs.readFileSync(concurrent.spec.coordinator_events, 'utf8')
      .trim().split('\n').map(JSON.parse);
    const completion = liveEvents.at(-1);
    const qualificationToolsAggregate = JSON.parse(fs.readFileSync(toolsManifest)).aggregate_sha256;
    const artifact = artifactFixture(root);
    const concurrentValue = JSON.parse(fs.readFileSync(concurrentReport));
    const planValue = JSON.parse(fs.readFileSync(concurrent.spec.plan));
    const deployment = deploymentFixture(
      root,
      qualificationToolsAggregate,
      artifact,
      concurrentValue,
      planValue,
    );
    const localPolicyReport = JSON.parse(fs.readFileSync(deployment.policyReports[0]));
    assert.equal(localPolicyReport.file_coverage.find((entry) => (
      entry.relative_path === 'runtime/libswiftCompatibilitySpan.dylib'
    )).classification, 'executable');
    const artifactManifest = writeJSON(path.join(root, 'artifact-binding.json'), {
      version: 2,
      deployment_envelope_sha256: '8'.repeat(64),
      peekaboo_source_commit: SOURCE,
      openclaw_source_commit: OPENCLAW_SOURCE,
      qualification_tools_aggregate_sha256: qualificationToolsAggregate,
      peekaboo_artifact_manifest: {
        path: artifact.peekaboo,
        sha256: sha256(fs.readFileSync(artifact.peekaboo)),
      },
      openclaw_artifact_receipt: {
        path: artifact.openclaw,
        sha256: sha256(fs.readFileSync(artifact.openclaw)),
      },
    }, 0o400);
    const installedAggregate = JSON.parse(fs.readFileSync(deployment.installed[0])).aggregate_sha256;
    const candidateBinding = {
      deployment_envelope_sha256: '8'.repeat(64),
      installed_inventory_aggregate_sha256: installedAggregate,
      peekaboo_artifact_manifest_sha256: sha256(fs.readFileSync(artifact.peekaboo)),
    };
    for (const cycle of matrix) {
      writeJSON(cycle.certificate, {
        ...JSON.parse(fs.readFileSync(cycle.certificate)),
        ...candidateBinding,
      });
      writeJSON(cycle.crash_inventory, {
        ...JSON.parse(fs.readFileSync(cycle.crash_inventory)),
        ...candidateBinding,
      });
    }
    const inputValue = {
      version: 2,
      artifact_manifest: artifactManifest,
      deployment: {
        installed_inventories: deployment.installed,
        elevation_receipts: deployment.elevationReceipts,
        process_tree_collector: deployment.collector,
        process_tree_monitor: planValue.monitor_executable,
        process_trees: deployment.processTrees,
        executable_policy_scanner: deployment.policyScanner,
        executable_policy_reports: deployment.policyReports,
      },
      tooling: {
        qualification_tools_manifest: toolsManifest,
        plan_constructor: path.join(
          qualificationRepositoryRoot,
          'scripts/final-qualification/construct-live-plan.mjs',
        ),
        crash_scanner: path.join(
          qualificationRepositoryRoot,
          'scripts/final-qualification/crash-inventory.mjs',
        ),
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
        task: concurrent.spec.agent_task,
        run_root: concurrent.spec.agent_run_root,
        agent_execution_bundle: concurrent.spec.agent_execution_bundle,
        agent_execution_validator_report: concurrent.spec.agent_execution_validator_report,
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
    const installedScriptPath = path.join(
      deployment.artifactRoots.openclaw_app,
      'OpenClaw.app/Contents/Resources/bootstrap.sh',
    );
    const cleanInstalledScript = fs.readFileSync(installedScriptPath);
    writeFile(installedScriptPath, '#!/bin/sh\nexec osascript forbidden.applescript\n', 0o755);
    const forbiddenScannerEntries = structuredClone(
      JSON.parse(fs.readFileSync(deployment.installed[0])).entries,
    );
    const forbiddenScriptEntry = forbiddenScannerEntries.find((entry) => (
      entry.relative_path === 'OpenClaw.app/Contents/Resources/bootstrap.sh'
    ));
    forbiddenScriptEntry.size = fs.statSync(installedScriptPath).size;
    forbiddenScriptEntry.sha256 = sha256(fs.readFileSync(installedScriptPath));
    const forbiddenScannerInventory = installedInventory(
      root,
      'local',
      deployment.localUUID,
      forbiddenScannerEntries,
      qualificationToolsAggregate,
      sha256(fs.readFileSync(deployment.elevationReceipts[0])),
      '-forbidden-scanner',
    );
    const forbiddenScannerSpec = writeJSON(path.join(root, 'forbidden-scanner-spec.json'), {
      version: 1,
      installed_inventory: forbiddenScannerInventory,
      artifact_roots: deployment.artifactRoots,
    });
    const forbiddenScannerRun = spawnSync(process.execPath, [
      deployment.policyScanner,
      'generate',
      '--spec', forbiddenScannerSpec,
      '--output', path.join(root, 'forbidden-scanner-report.json'),
    ], { encoding: 'utf8' });
    assert.notEqual(forbiddenScannerRun.status, 0);
    assert.match(forbiddenScannerRun.stderr, /forbidden executable or script markers/);
    writeFile(installedScriptPath, cleanInstalledScript, 0o755);
    const installedDylibPath = path.join(
      deployment.artifactRoots.peekaboo_cli,
      'runtime/libswiftCompatibilitySpan.dylib',
    );
    const cleanInstalledDylib = fs.readFileSync(installedDylibPath);
    writeFile(
      installedDylibPath,
      Buffer.concat([Buffer.from('cffaedfe', 'hex'), Buffer.from(' osascript ')]),
      0o644,
    );
    const forbiddenDylibEntries = structuredClone(
      JSON.parse(fs.readFileSync(deployment.installed[0])).entries,
    );
    const forbiddenDylibEntry = forbiddenDylibEntries.find((entry) => (
      entry.relative_path === 'runtime/libswiftCompatibilitySpan.dylib'
    ));
    forbiddenDylibEntry.size = fs.statSync(installedDylibPath).size;
    forbiddenDylibEntry.sha256 = sha256(fs.readFileSync(installedDylibPath));
    const forbiddenDylibInventory = installedInventory(
      root,
      'local',
      deployment.localUUID,
      forbiddenDylibEntries,
      qualificationToolsAggregate,
      sha256(fs.readFileSync(deployment.elevationReceipts[0])),
      '-forbidden-dylib',
    );
    const forbiddenDylibSpec = writeJSON(path.join(root, 'forbidden-dylib-spec.json'), {
      version: 1,
      installed_inventory: forbiddenDylibInventory,
      artifact_roots: deployment.artifactRoots,
    });
    const forbiddenDylibRun = spawnSync(process.execPath, [
      deployment.policyScanner,
      'generate',
      '--spec', forbiddenDylibSpec,
      '--output', path.join(root, 'forbidden-dylib-report.json'),
    ], { encoding: 'utf8' });
    assert.notEqual(forbiddenDylibRun.status, 0);
    assert.match(forbiddenDylibRun.stderr, /forbidden executable or script markers/);
    writeFile(installedDylibPath, cleanInstalledDylib, 0o644);
    const legacyInput = structuredClone(inputValue);
    legacyInput.version = 1;
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'legacy-v1-input.json'), legacyInput),
        path.join(root, 'legacy-v1-manifest.json'),
      ),
      /input version is not 2/,
    );
    const forgedSummaryInput = structuredClone(inputValue);
    const forgedSummaryValue = JSON.parse(fs.readFileSync(completion.summary_path));
    const foreignSummaryTarget = {
      scope: 'window', pid: 999, start_identity: '999001', window_id: 1999,
      bounds: { x: 0, y: 0, width: 400, height: 300 }, is_minimized: false,
    };
    forgedSummaryValue.offline_protocol_validation.receipts[0].target
      = foreignSummaryTarget;
    forgedSummaryValue.controlled_targets[0].target_sha256
      = multiTargetAggregateSHA256('controlled-target', foreignSummaryTarget);
    forgedSummaryValue.slot_verdicts[0].offline_receipt_sha256
      = multiTargetAggregateSHA256(
        'offline-receipt',
        forgedSummaryValue.offline_protocol_validation.receipts[0],
      );
    forgedSummaryValue.offline_protocol_validation_sha256
      = multiTargetAggregateSHA256(
        'offline-protocol-validation',
        forgedSummaryValue.offline_protocol_validation,
      );
    delete forgedSummaryValue.summary_core_sha256;
    forgedSummaryValue.summary_core_sha256 = multiTargetAggregateSHA256(
      'summary-core', forgedSummaryValue,
    );
    const forgedSummary = writeJSON(
      path.join(root, 'forged-controlled-target-summary.json'),
      forgedSummaryValue,
    );
    const forgedSummaryBytes = fs.readFileSync(forgedSummary);
    const forgedEventsValue = fs.readFileSync(concurrent.spec.coordinator_events, 'utf8')
      .trim().split('\n').map(JSON.parse);
    forgedEventsValue.at(-1).summary_path = forgedSummary;
    forgedEventsValue.at(-1).summary_size = forgedSummaryBytes.length;
    forgedEventsValue.at(-1).summary_sha256 = sha256(forgedSummaryBytes);
    const forgedEvents = writeFile(
      path.join(root, 'forged-controlled-target-events.jsonl'),
      `${forgedEventsValue.map(JSON.stringify).join('\n')}\n`,
    );
    const forgedSummaryReportValue = JSON.parse(fs.readFileSync(concurrentReport));
    forgedSummaryReportValue.coordinator.summary_sha256 = sha256(forgedSummaryBytes);
    forgedSummaryReportValue.coordinator.events_sha256 = sha256(fs.readFileSync(forgedEvents));
    const forgedSummaryReport = writeJSON(
      path.join(root, 'forged-controlled-target-report.json'),
      forgedSummaryReportValue,
    );
    forgedSummaryInput.live_v4.certification_summary = forgedSummary;
    forgedSummaryInput.live_v4.coordinator_events = forgedEvents;
    forgedSummaryInput.agent_cu.validation_report = forgedSummaryReport;
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'forged-controlled-target-input.json'), forgedSummaryInput),
        path.join(root, 'forged-controlled-target-manifest.json'),
      ),
      /completion summary path is not canonical|final certification summary target-a target differs/,
    );
    for (const [artifactDrift, mutateArtifact, expectedError] of [
      [
        'cli',
        (value) => { value.cli.sha256 = '0'.repeat(64); },
        /CLI artifact differs from the installed executable/,
      ],
      [
        'cli-cdhash',
        (value) => { value.cli.cdhash = '0'.repeat(40); },
        /not executed by the candidate CLI|exercised Agent CLI differs from the candidate\/deployed executable/,
      ],
      [
        'monitor-executable',
        (value) => { value.monitor.executable_sha256 = '0'.repeat(64); },
        /process monitor differs from the candidate-bound executable/,
      ],
      [
        'monitor-source',
        (value) => { value.monitor.source_sha256 = '0'.repeat(64); },
        /monitor source differs from the reviewed Git tree/,
      ],
      [
        'app',
        (value) => { value.app.cdhash = '0'.repeat(40); },
        /Peekaboo\.app artifact differs from the local Bridge root/,
      ],
      [
        'playground',
        (value) => { value.playground.cdhash = '0'.repeat(40); },
        /Playground CDHash differs from the candidate artifact|Playground artifact differs from the local fixture root/,
      ],
    ]) {
      const driftedArtifactValue = structuredClone(JSON.parse(fs.readFileSync(artifact.peekaboo)));
      mutateArtifact(driftedArtifactValue);
      const driftedArtifact = writeJSON(
        path.join(root, `drifted-${artifactDrift}-artifact.json`),
        driftedArtifactValue,
        0o400,
      );
      const driftedBindingValue = structuredClone(JSON.parse(fs.readFileSync(artifactManifest)));
      driftedBindingValue.peekaboo_artifact_manifest = {
        path: driftedArtifact,
        sha256: sha256(fs.readFileSync(driftedArtifact)),
      };
      const driftedInput = structuredClone(inputValue);
      driftedInput.artifact_manifest = writeJSON(
        path.join(root, `drifted-${artifactDrift}-binding.json`),
        driftedBindingValue,
        0o400,
      );
      driftedInput.matrix_cycles = matrix.map((cycle, cycleIndex) => {
        const certificate = JSON.parse(fs.readFileSync(cycle.certificate));
        const crash = JSON.parse(fs.readFileSync(cycle.crash_inventory));
        certificate.peekaboo_artifact_manifest_sha256 = sha256(fs.readFileSync(driftedArtifact));
        crash.peekaboo_artifact_manifest_sha256 = certificate.peekaboo_artifact_manifest_sha256;
        return {
          certificate: writeJSON(
            path.join(root, `drifted-${artifactDrift}-certificate-${cycleIndex}.json`),
            certificate,
          ),
          crash_inventory: writeJSON(
            path.join(root, `drifted-${artifactDrift}-crash-${cycleIndex}.json`),
            crash,
          ),
          playground_alert_lifecycle: cycle.playground_alert_lifecycle,
        };
      });
      assert.throws(
        () => generateManifest(
          writeJSON(path.join(root, `drifted-${artifactDrift}-input.json`), driftedInput),
          path.join(root, `drifted-${artifactDrift}-manifest.json`),
        ),
        expectedError,
      );
    }
    const localInventory = JSON.parse(fs.readFileSync(deployment.installed[0]));
    const installedDrifts = [
      ['size', (entries) => { entries[0].size += 1; }],
      ['path', (entries) => { entries[0].relative_path = 'OpenClaw.app/Contents/MacOS/OpenClaw2'; }],
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
    const fixturePIDs = new Set(missingRootTree.roots
      .filter((entry) => entry.root_class === 'fixture')
      .map((entry) => entry.pid));
    missingRootTree.roots = missingRootTree.roots.filter((entry) => entry.root_class !== 'fixture');
    missingRootTree.processes = missingRootTree.processes.filter((entry) => !fixturePIDs.has(entry.pid));
    missingRootTree.lifecycle_watched_pids = missingRootTree.lifecycle_watched_pids.filter(
      (pid) => !fixturePIDs.has(pid),
    );
    missingRootInput.deployment.process_trees[1] = writeSynchronizedProcessTree(
      root,
      'missing-root-process-tree',
      missingRootTree,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'missing-root-input.json'), missingRootInput),
        path.join(root, 'missing-root-manifest.json'),
      ),
      /root coverage is incomplete/,
    );
    const wrongFixtureGenerationInput = structuredClone(inputValue);
    const wrongFixtureGenerationTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
    const wrongFixtureRoot = wrongFixtureGenerationTree.roots.find((entry) => (
      entry.root_class === 'fixture' && entry.pid === planValue.controllers[0].target.process_identifier
    ));
    const wrongFixtureProcess = wrongFixtureGenerationTree.processes.find((entry) => (
      entry.pid === wrongFixtureRoot.pid
      && entry.start_identity === wrongFixtureRoot.start_identity
    ));
    wrongFixtureRoot.start_identity = '301999';
    wrongFixtureProcess.start_identity = '301999';
    wrongFixtureGenerationInput.deployment.process_trees[1] = writeSynchronizedProcessTree(
      root,
      'wrong-fixture-generation-process-tree',
      wrongFixtureGenerationTree,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(
          path.join(root, 'wrong-fixture-generation-input.json'),
          wrongFixtureGenerationInput,
        ),
        path.join(root, 'wrong-fixture-generation-manifest.json'),
      ),
      /local\/during fixture roots omit a controlled Agent target generation/,
    );
    const wrongAgentBytesInput = structuredClone(inputValue);
    const wrongAgentBytesTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
    const wrongAgentRoot = wrongAgentBytesTree.roots.find((entry) => entry.root_class === 'agent');
    wrongAgentBytesTree.processes.find((entry) => (
      entry.pid === wrongAgentRoot.pid && entry.start_identity === wrongAgentRoot.start_identity
    )).executable_sha256 = '0'.repeat(64);
    wrongAgentBytesInput.deployment.process_trees[1] = writeSynchronizedProcessTree(
      root,
      'wrong-agent-bytes-process-tree',
      wrongAgentBytesTree,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'wrong-agent-bytes-input.json'), wrongAgentBytesInput),
        path.join(root, 'wrong-agent-bytes-manifest.json'),
      ),
      /exercised Agent CLI differs from the candidate\/deployed executable/,
    );
    const wrongRequesterBytesInput = structuredClone(inputValue);
    const wrongRequesterBytesTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
    const wrongRequesterRoot = wrongRequesterBytesTree.roots.find((entry) => (
      entry.root_class === 'agent_requester'
    ));
    const wrongRequesterProcess = wrongRequesterBytesTree.processes.find((entry) => (
      entry.pid === wrongRequesterRoot.pid
        && entry.start_identity === wrongRequesterRoot.start_identity
    ));
    wrongRequesterProcess.executable_path = '/private/tmp/qualification/peekaboo-copy';
    wrongRequesterProcess.executable_name = 'peekaboo-copy';
    wrongRequesterProcess.executable_sha256 = '0'.repeat(64);
    wrongRequesterBytesInput.deployment.process_trees[1] = writeSynchronizedProcessTree(
      root,
      'wrong-requester-bytes-process-tree',
      wrongRequesterBytesTree,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'wrong-requester-bytes-input.json'), wrongRequesterBytesInput),
        path.join(root, 'wrong-requester-bytes-manifest.json'),
      ),
      /Agent requester CLI differs from the candidate\/deployed executable/,
    );
    const wrongMonitorTreeInput = structuredClone(inputValue);
    const wrongMonitorTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
    wrongMonitorTree.monitor_executable_sha256 = '0'.repeat(64);
    wrongMonitorTreeInput.deployment.process_trees[1] = writeSynchronizedProcessTree(
      root,
      'wrong-monitor-process-tree',
      wrongMonitorTree,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'wrong-monitor-tree-input.json'), wrongMonitorTreeInput),
        path.join(root, 'wrong-monitor-tree-manifest.json'),
      ),
      /process tree monitor differs from the exact authenticated executable/,
    );
    const wrongCollectorInput = structuredClone(inputValue);
    const wrongCollectorTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
    wrongCollectorTree.collector_sha256 = '0'.repeat(64);
    wrongCollectorInput.deployment.process_trees[1] = writeSynchronizedProcessTree(
      root,
      'wrong-collector-process-tree',
      wrongCollectorTree,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'wrong-collector-input.json'), wrongCollectorInput),
        path.join(root, 'wrong-collector-manifest.json'),
      ),
      /collector differs from the bound source/,
    );
    const wrongLifecycleGuardInput = structuredClone(inputValue);
    const wrongLifecycleGuardTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
    wrongLifecycleGuardTree.lifecycle_guard_sha256 = '0'.repeat(64);
    wrongLifecycleGuardInput.deployment.process_trees[1] = writeSynchronizedProcessTree(
      root,
      'wrong-lifecycle-guard-process-tree',
      wrongLifecycleGuardTree,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'wrong-lifecycle-guard-input.json'), wrongLifecycleGuardInput),
        path.join(root, 'wrong-lifecycle-guard-manifest.json'),
      ),
      /process lifecycle guard differs from the bound source/,
    );
    const substitutedMonitorInput = structuredClone(inputValue);
    const substitutedMonitor = writeFile(
      path.join(root, 'substituted-process-monitor'),
      fs.readFileSync('/usr/bin/true'),
      0o500,
    );
    substitutedMonitorInput.deployment.process_tree_monitor = substitutedMonitor;
    substitutedMonitorInput.deployment.process_trees = deployment.processTrees.map((treePath, index) => {
      const tree = JSON.parse(fs.readFileSync(treePath));
      tree.monitor_executable_path = substitutedMonitor;
      return writeSynchronizedProcessTree(root, `substituted-monitor-tree-${index}`, tree);
    });
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'substituted-monitor-input.json'), substitutedMonitorInput),
        path.join(root, 'substituted-monitor-manifest.json'),
      ),
      /process monitor differs from the candidate-bound executable/,
    );
    const substitutedToolInput = structuredClone(inputValue);
    const substitutedToolDirectory = privateDirectory(root, 'substituted-process-tools');
    const substitutedCollector = writeFile(
      path.join(substitutedToolDirectory, 'process-tree-collector.mjs'),
      fs.readFileSync(deployment.collector),
      0o400,
    );
    const substitutedGuard = writeFile(
      path.join(substitutedToolDirectory, 'process-lifecycle-guard.c'),
      `${fs.readFileSync(path.join(toolRoot, 'process-lifecycle-guard.c'), 'utf8')}\n/* altered */\n`,
      0o400,
    );
    substitutedToolInput.deployment.process_tree_collector = substitutedCollector;
    substitutedToolInput.deployment.process_trees = deployment.processTrees.map((treePath, index) => {
      const tree = JSON.parse(fs.readFileSync(treePath));
      tree.collector_sha256 = sha256(fs.readFileSync(substitutedCollector));
      tree.lifecycle_guard_sha256 = sha256(fs.readFileSync(substitutedGuard));
      return writeSynchronizedProcessTree(root, `substituted-tool-tree-${index}`, tree);
    });
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'substituted-tool-input.json'), substitutedToolInput),
        path.join(root, 'substituted-tool-manifest.json'),
      ),
      /differs from the reviewed qualification tools/,
    );
    const timestampInput = structuredClone(inputValue);
    const timestampTree = JSON.parse(fs.readFileSync(deployment.processTrees[0]));
    timestampTree.captured_at_milliseconds = JSON.parse(
      fs.readFileSync(deployment.processTrees[1]),
    ).captured_at_milliseconds;
    timestampTree.lifecycle_completed_at_milliseconds
      = timestampTree.captured_at_milliseconds + 10;
    timestampInput.deployment.process_trees[0] = writeJSON(
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
    generationDriftInput.deployment.process_trees[1] = writeSynchronizedProcessTree(
      root,
      'generation-drift-process-tree',
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
    duplicatePIDInput.deployment.process_trees[1] = writeSynchronizedProcessTree(
      root,
      'duplicate-pid-process-tree',
      duplicatePIDTree,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'duplicate-pid-input.json'), duplicatePIDInput),
        path.join(root, 'duplicate-pid-manifest.json'),
      ),
      /PID reuse in one epoch/,
    );
    for (const [substitutionIndex, rootClass] of [
      'agent', 'agent_requester', 'coordinator', 'bridge', 'integrated_cu',
    ].entries()) {
      const substitutionInput = structuredClone(inputValue);
      const treeIndexes = ['bridge', 'integrated_cu'].includes(rootClass) ? [0, 1, 2] : [1];
      const duringTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
      const replacementPID = duringTree.roots.find((entry) => (
        entry.root_class === rootClass
      )).pid + 10_000 + substitutionIndex;
      for (const treeIndex of treeIndexes) {
        const substitutionTree = JSON.parse(fs.readFileSync(deployment.processTrees[treeIndex]));
        const rootEntry = substitutionTree.roots.find((entry) => entry.root_class === rootClass);
        const processEntry = substitutionTree.processes.find((entry) => entry.pid === rootEntry.pid
          && entry.start_identity === rootEntry.start_identity);
        const priorPID = rootEntry.pid;
        const priorStartIdentity = rootEntry.start_identity;
        rootEntry.pid = replacementPID;
        rootEntry.start_identity = `${rootEntry.pid}001`;
        if (rootClass !== 'bridge') rootEntry.code_signature_hash = '0'.repeat(40);
        processEntry.pid = rootEntry.pid;
        processEntry.start_identity = rootEntry.start_identity;
        processEntry.code_signature_hash = rootEntry.code_signature_hash;
        for (const process of substitutionTree.processes) {
          if (process.parent_pid === priorPID
            && process.parent_start_identity === priorStartIdentity) {
            process.parent_pid = rootEntry.pid;
            process.parent_start_identity = rootEntry.start_identity;
          }
        }
        substitutionTree.lifecycle_watched_pids = substitutionTree.lifecycle_watched_pids
          .map((pid) => (pid === priorPID ? rootEntry.pid : pid))
          .sort((left, right) => left - right);
        substitutionTree.processes.sort((left, right) => left.pid - right.pid);
        substitutionInput.deployment.process_trees[treeIndex] = writeSynchronizedProcessTree(
          root,
          `substituted-${rootClass}-process-tree-${treeIndex}`,
          substitutionTree,
        );
      }
      assert.throws(
        () => generateManifest(
          writeJSON(path.join(root, `substituted-${rootClass}-input.json`), substitutionInput),
          path.join(root, `substituted-${rootClass}-manifest.json`),
        ),
        new RegExp(`local/during ${rootClass} root differs from the concurrent run`),
      );
    }
    const resealedInvocationInput = structuredClone(inputValue);
    const retainedTerminalBundle = fs.readFileSync(concurrent.spec.agent_execution_bundle);
    const retainedTerminalValidator = fs.readFileSync(
      concurrent.spec.agent_execution_validator_report,
    );
    mutateAgentTerminalBundle(concurrent.spec, ({ response }) => {
      response.process.executableSHA256 = '0'.repeat(64);
    });
    const resealedConcurrent = structuredClone(concurrentValue);
    resealedConcurrent.agent.executable_sha256 = '0'.repeat(64);
    resealedConcurrent.agent.terminal_bundle_sha256 = sha256(
      fs.readFileSync(concurrent.spec.agent_execution_bundle),
    );
    resealedConcurrent.agent.terminal_validator_report_sha256 = sha256(
      fs.readFileSync(concurrent.spec.agent_execution_validator_report),
    );
    resealedInvocationInput.agent_cu.validation_report = writeJSON(
      path.join(root, 'resealed-concurrent-report.json'),
      resealedConcurrent,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'resealed-agent-invocation-input.json'), resealedInvocationInput),
        path.join(root, 'resealed-agent-invocation-manifest.json'),
      ),
      /child\/requester executable identity is inconsistent/,
    );
    writeFile(concurrent.spec.agent_execution_bundle, retainedTerminalBundle);
    writeFile(concurrent.spec.agent_execution_validator_report, retainedTerminalValidator);
    const traceSelectorInput = structuredClone(inputValue);
    mutateAgentTerminalBundle(concurrent.spec, ({ stdoutRoot }) => {
      stdoutRoot.result.executionTrace.entries[0].arguments.snapshot
        = 'manifest-substituted-snapshot';
    });
    const traceSelectorBundle = JSON.parse(fs.readFileSync(
      concurrent.spec.agent_execution_bundle,
    ));
    const traceSelectorResponseWire = JSON.parse(Buffer.from(
      traceSelectorBundle.canonicalResponse,
      'base64',
    ));
    const traceSelectorResponse = traceSelectorResponseWire.projectedAction._0.response
      .agentExecutionTrace._0;
    const traceSelectorConcurrent = structuredClone(concurrentValue);
    traceSelectorConcurrent.agent.terminal_bundle_sha256 = sha256(fs.readFileSync(
      concurrent.spec.agent_execution_bundle,
    ));
    traceSelectorConcurrent.agent.terminal_validator_report_sha256 = sha256(fs.readFileSync(
      concurrent.spec.agent_execution_validator_report,
    ));
    traceSelectorConcurrent.agent.stdout_sha256 = traceSelectorResponse.stdout.sha256;
    traceSelectorInput.agent_cu.validation_report = writeJSON(
      path.join(root, 'trace-selector-substitution-concurrent.json'),
      traceSelectorConcurrent,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'trace-selector-substitution-input.json'), traceSelectorInput),
        path.join(root, 'trace-selector-substitution-manifest.json'),
      ),
      /trace selectors differ from the signed Bridge request/,
    );
    writeFile(concurrent.spec.agent_execution_bundle, retainedTerminalBundle);
    writeFile(concurrent.spec.agent_execution_validator_report, retainedTerminalValidator);
    const retainedAgentTask = fs.readFileSync(concurrent.spec.agent_task);
    const retainedAgentAcknowledgement = fs.readFileSync(
      path.join(concurrent.spec.agent_run_root, 'agent-execution-ack.json'),
    );
    const arbitraryTaskContract = JSON.parse(retainedAgentTask);
    arbitraryTaskContract.goal = 'arbitrary-signed-goal';
    const arbitraryTaskText = canonicalBytes(arbitraryTaskContract).toString('utf8');
    const substitutedTask = substituteAgentTerminalTask(concurrent.spec, arbitraryTaskText);
    const arbitraryTaskInput = structuredClone(inputValue);
    const arbitraryTaskConcurrent = structuredClone(concurrentValue);
    arbitraryTaskConcurrent.agent.terminal_bundle_sha256 = sha256(fs.readFileSync(
      concurrent.spec.agent_execution_bundle,
    ));
    arbitraryTaskConcurrent.agent.terminal_validator_report_sha256 = sha256(fs.readFileSync(
      concurrent.spec.agent_execution_validator_report,
    ));
    arbitraryTaskConcurrent.agent.acknowledgement_sha256
      = substitutedTask.response.acknowledgement.sha256;
    arbitraryTaskConcurrent.agent.task_contract.task_file_sha256 = sha256(fs.readFileSync(
      concurrent.spec.agent_task,
    ));
    arbitraryTaskConcurrent.agent.task_contract.signed_task_sha256 = substitutedTask.taskSHA256;
    arbitraryTaskConcurrent.agent.task_contract.semantic_contract_sha256
      = substitutedTask.taskSHA256;
    arbitraryTaskInput.agent_cu.validation_report = writeJSON(
      path.join(root, 'arbitrary-signed-task-concurrent.json'),
      arbitraryTaskConcurrent,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'arbitrary-signed-task-input.json'), arbitraryTaskInput),
        path.join(root, 'arbitrary-signed-task-manifest.json'),
      ),
      /goal is not the closed concurrent qualification goal/,
    );
    fs.chmodSync(concurrent.spec.agent_task, 0o600);
    writeFile(concurrent.spec.agent_task, retainedAgentTask, 0o400);
    writeFile(
      path.join(concurrent.spec.agent_run_root, 'agent-execution-ack.json'),
      retainedAgentAcknowledgement,
    );
    writeFile(concurrent.spec.agent_execution_bundle, retainedTerminalBundle);
    writeFile(concurrent.spec.agent_execution_validator_report, retainedTerminalValidator);
    for (const taskMismatch of [
      {
        name: 'signed-task-value-mismatch',
        mutateTask: (task) => {
          task.targets[0].steps[1].expected_value = 'signed-alpha-different';
          task.targets[0].steps[2].expected_value = 'signed-alpha-different';
        },
        mutateReport: (report) => {
          report.agent.task_contract.target_expectations[0].mutated_value_sha256
            = sha256(Buffer.from('signed-alpha-different'));
        },
        error: /readback differs from (?:its signed task expected value|its authenticated task expectation)/,
      },
      {
        name: 'signed-task-per-target-family-swap',
        mutateTask: (task) => {
          task.targets[0].steps[1].family = 'paste';
          task.targets[1].steps[1].family = 'set_value';
        },
        mutateReport: (report) => {
          report.agent.task_contract.target_expectations[0].mutation_family = 'paste';
          report.agent.task_contract.target_expectations[1].mutation_family = 'set_value';
        },
        error: /family differs from its signed task contract|differs from its signed terminal trace/,
      },
    ]) {
      const task = JSON.parse(retainedAgentTask);
      taskMismatch.mutateTask(task);
      const taskText = canonicalBytes(task).toString('utf8');
      const substituted = substituteAgentTerminalTask(concurrent.spec, taskText);
      const mismatchInput = structuredClone(inputValue);
      const mismatchConcurrent = structuredClone(concurrentValue);
      mismatchConcurrent.agent.terminal_bundle_sha256 = sha256(fs.readFileSync(
        concurrent.spec.agent_execution_bundle,
      ));
      mismatchConcurrent.agent.terminal_validator_report_sha256 = sha256(fs.readFileSync(
        concurrent.spec.agent_execution_validator_report,
      ));
      mismatchConcurrent.agent.acknowledgement_sha256
        = substituted.response.acknowledgement.sha256;
      mismatchConcurrent.agent.task_contract.task_file_sha256 = sha256(fs.readFileSync(
        concurrent.spec.agent_task,
      ));
      mismatchConcurrent.agent.task_contract.signed_task_sha256 = substituted.taskSHA256;
      mismatchConcurrent.agent.task_contract.semantic_contract_sha256 = substituted.taskSHA256;
      taskMismatch.mutateReport(mismatchConcurrent);
      mismatchInput.agent_cu.validation_report = writeJSON(
        path.join(root, `${taskMismatch.name}-concurrent.json`),
        mismatchConcurrent,
      );
      assert.throws(
        () => generateManifest(
          writeJSON(path.join(root, `${taskMismatch.name}-input.json`), mismatchInput),
          path.join(root, `${taskMismatch.name}-manifest.json`),
        ),
        taskMismatch.error,
      );
      fs.chmodSync(concurrent.spec.agent_task, 0o600);
      writeFile(concurrent.spec.agent_task, retainedAgentTask, 0o400);
      writeFile(
        path.join(concurrent.spec.agent_run_root, 'agent-execution-ack.json'),
        retainedAgentAcknowledgement,
      );
      writeFile(concurrent.spec.agent_execution_bundle, retainedTerminalBundle);
      writeFile(concurrent.spec.agent_execution_validator_report, retainedTerminalValidator);
    }
    const requesterSubstitutionInput = structuredClone(inputValue);
    const requesterSubstitutionConcurrent = structuredClone(concurrentValue);
    requesterSubstitutionConcurrent.agent.requester.pid += 20_000;
    requesterSubstitutionConcurrent.agent.requester.start_identity
      = `${requesterSubstitutionConcurrent.agent.requester.pid}001`;
    requesterSubstitutionInput.agent_cu.validation_report = writeJSON(
      path.join(root, 'requester-substitution-concurrent.json'),
      requesterSubstitutionConcurrent,
    );
    const requesterSubstitutionTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
    const requesterRoot = requesterSubstitutionTree.roots.find((entry) => (
      entry.root_class === 'agent_requester'
    ));
    const requesterProcess = requesterSubstitutionTree.processes.find((entry) => (
      entry.pid === requesterRoot.pid && entry.start_identity === requesterRoot.start_identity
    ));
    const priorRequesterPID = requesterRoot.pid;
    requesterRoot.pid = requesterSubstitutionConcurrent.agent.requester.pid;
    requesterRoot.start_identity = requesterSubstitutionConcurrent.agent.requester.start_identity;
    requesterProcess.pid = requesterRoot.pid;
    requesterProcess.start_identity = requesterRoot.start_identity;
    requesterSubstitutionTree.lifecycle_watched_pids
      = requesterSubstitutionTree.lifecycle_watched_pids.map((pid) => (
        pid === priorRequesterPID ? requesterRoot.pid : pid
      )).sort((left, right) => left - right);
    requesterSubstitutionTree.processes.sort((left, right) => left.pid - right.pid);
    requesterSubstitutionInput.deployment.process_trees[1] = writeSynchronizedProcessTree(
      root,
      'requester-substitution-process-tree',
      requesterSubstitutionTree,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'requester-substitution-input.json'), requesterSubstitutionInput),
        path.join(root, 'requester-substitution-manifest.json'),
      ),
      /concurrent validation report differs from fresh concurrent evidence validation/,
    );
    const acknowledgementPathInput = structuredClone(inputValue);
    const acknowledgementPathConcurrent = structuredClone(concurrentValue);
    acknowledgementPathConcurrent.agent.acknowledgement_path = path.join(
      acknowledgementPathConcurrent.agent.run_root,
      'substituted-agent-execution-ack.json',
    );
    acknowledgementPathInput.agent_cu.validation_report = writeJSON(
      path.join(root, 'acknowledgement-path-concurrent.json'),
      acknowledgementPathConcurrent,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'acknowledgement-path-input.json'), acknowledgementPathInput),
        path.join(root, 'acknowledgement-path-manifest.json'),
      ),
      /concurrent validation report differs from fresh concurrent evidence validation/,
    );
    const terminalTimingInput = structuredClone(inputValue);
    const terminalTimingConcurrent = structuredClone(concurrentValue);
    terminalTimingConcurrent.agent.released_at_milliseconds += 1;
    terminalTimingInput.agent_cu.validation_report = writeJSON(
      path.join(root, 'terminal-timing-concurrent.json'),
      terminalTimingConcurrent,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'terminal-timing-input.json'), terminalTimingInput),
        path.join(root, 'terminal-timing-manifest.json'),
      ),
      /concurrent validation report differs from fresh concurrent evidence validation/,
    );
    for (const [phase, readbackPath] of [
      ['perform', concurrent.spec.integrated_cu.perform_readback],
      ['restore', concurrent.spec.integrated_cu.restore_readback],
    ]) {
      const failedReadbackInput = structuredClone(inputValue);
      const failedReadbackValue = JSON.parse(fs.readFileSync(readbackPath));
      failedReadbackValue.passed = false;
      const failedReadbackPath = writeJSON(
        path.join(root, `failed-${phase}-integrated-readback.json`),
        failedReadbackValue,
      );
      failedReadbackInput.agent_cu[`${phase}_readback`] = failedReadbackPath;
      const failedReadbackConcurrent = structuredClone(concurrentValue);
      failedReadbackConcurrent.integrated_cu[`${phase}_readback_sha256`]
        = sha256(fs.readFileSync(failedReadbackPath));
      failedReadbackInput.agent_cu.validation_report = writeJSON(
        path.join(root, `failed-${phase}-integrated-concurrent.json`),
        failedReadbackConcurrent,
      );
      assert.throws(
        () => generateManifest(
          writeJSON(path.join(root, `failed-${phase}-integrated-input.json`), failedReadbackInput),
          path.join(root, `failed-${phase}-integrated-manifest.json`),
        ),
        new RegExp(`integrated-CU ${phase} readback did not pass`),
      );
    }
    const overlapDriftInput = structuredClone(inputValue);
    const overlapDriftConcurrent = structuredClone(concurrentValue);
    overlapDriftConcurrent.overlap.operations_started_at_milliseconds += 1;
    overlapDriftInput.agent_cu.validation_report = writeJSON(
      path.join(root, 'overlap-drift-concurrent.json'),
      overlapDriftConcurrent,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'overlap-drift-input.json'), overlapDriftInput),
        path.join(root, 'overlap-drift-manifest.json'),
      ),
      /concurrent validation report differs from fresh concurrent evidence validation/,
    );
    const traceRemapInput = structuredClone(inputValue);
    const traceRemapReadbacks = JSON.parse(fs.readFileSync(concurrent.spec.agent_readbacks));
    const originalTraceCallID = traceRemapReadbacks.targets[0].mutation.trace_call_id;
    const replacementTraceCallID = 'resealed-unrelated-trace-call';
    traceRemapReadbacks.targets[0].mutation.trace_call_id = replacementTraceCallID;
    const traceRemapReadbacksPath = writeJSON(
      path.join(root, 'trace-remap-readbacks.json'),
      traceRemapReadbacks,
    );
    traceRemapInput.agent_cu.agent_readbacks = traceRemapReadbacksPath;
    const traceRemapConcurrent = structuredClone(concurrentValue);
    traceRemapConcurrent.agent.readbacks_sha256 = sha256(fs.readFileSync(traceRemapReadbacksPath));
    traceRemapConcurrent.agent.mapped_call_ids = traceRemapConcurrent.agent.mapped_call_ids
      .map((callID) => (callID === originalTraceCallID ? replacementTraceCallID : callID))
      .sort();
    for (const interval of traceRemapConcurrent.agent.progress_interleaving.action_intervals) {
      if (interval.trace_call_id === originalTraceCallID) {
        interval.trace_call_id = replacementTraceCallID;
      }
    }
    traceRemapInput.agent_cu.validation_report = writeJSON(
      path.join(root, 'trace-remap-concurrent.json'),
      traceRemapConcurrent,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'trace-remap-input.json'), traceRemapInput),
        path.join(root, 'trace-remap-manifest.json'),
      ),
      /does not match its trace family|signed terminal trace does not contain exactly the mapped dispatched calls/,
    );
    const extraShellInput = structuredClone(inputValue);
    mutateAgentTerminalBundle(concurrent.spec, ({ stdoutRoot }) => {
      stdoutRoot.result.executionTrace.entries.push({
        id: 'extra-failed-shell-observation',
        name: 'shell',
        arguments: {},
        result: { success: false },
        isError: true,
        disposition: 'executed/failed',
      });
      stdoutRoot.result.executionTrace.totalCallCount += 1;
    });
    const extraShellBundle = JSON.parse(fs.readFileSync(concurrent.spec.agent_execution_bundle));
    const extraShellResponseWire = JSON.parse(Buffer.from(
      extraShellBundle.canonicalResponse,
      'base64',
    ));
    const extraShellResponse = extraShellResponseWire.projectedAction._0.response
      .agentExecutionTrace._0;
    const extraShellConcurrent = structuredClone(concurrentValue);
    extraShellConcurrent.agent.terminal_bundle_sha256 = sha256(fs.readFileSync(
      concurrent.spec.agent_execution_bundle,
    ));
    extraShellConcurrent.agent.terminal_validator_report_sha256 = sha256(fs.readFileSync(
      concurrent.spec.agent_execution_validator_report,
    ));
    extraShellConcurrent.agent.stdout_sha256 = extraShellResponse.stdout.sha256;
    extraShellConcurrent.agent.trace_entry_count += 1;
    extraShellInput.agent_cu.validation_report = writeJSON(
      path.join(root, 'extra-shell-concurrent.json'),
      extraShellConcurrent,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'extra-shell-input.json'), extraShellInput),
        path.join(root, 'extra-shell-manifest.json'),
      ),
      /trace contains Shell/,
    );
    writeFile(concurrent.spec.agent_execution_bundle, retainedTerminalBundle);
    writeFile(concurrent.spec.agent_execution_validator_report, retainedTerminalValidator);
    const completedOnlyInput = structuredClone(inputValue);
    const completedOnlyEvents = fs.readFileSync(
      concurrent.spec.coordinator_events,
      'utf8',
    ).trim().split('\n').map(JSON.parse).at(-1);
    const completedOnlyEventsPath = writeFile(
      path.join(root, 'completed-only-events.jsonl'),
      `${JSON.stringify(completedOnlyEvents)}\n`,
    );
    const completedOnlyConcurrent = structuredClone(concurrentValue);
    completedOnlyConcurrent.coordinator.events_sha256 = sha256(fs.readFileSync(
      completedOnlyEventsPath,
    ));
    completedOnlyInput.live_v4.coordinator_events = completedOnlyEventsPath;
    completedOnlyInput.agent_cu.validation_report = writeJSON(
      path.join(root, 'completed-only-concurrent.json'),
      completedOnlyConcurrent,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'completed-only-input.json'), completedOnlyInput),
        path.join(root, 'completed-only-manifest.json'),
      ),
      /exactly four lifecycle events/,
    );
    const nonzeroCoordinatorExitInput = structuredClone(inputValue);
    const nonzeroCoordinatorExit = JSON.parse(fs.readFileSync(concurrent.spec.coordinator_exit));
    nonzeroCoordinatorExit.exit_code = 1;
    const nonzeroCoordinatorExitPath = writeJSON(
      path.join(root, 'nonzero-coordinator-exit.json'),
      nonzeroCoordinatorExit,
    );
    const nonzeroCoordinatorExitConcurrent = structuredClone(concurrentValue);
    nonzeroCoordinatorExitConcurrent.coordinator.exit_receipt_sha256 = sha256(fs.readFileSync(
      nonzeroCoordinatorExitPath,
    ));
    nonzeroCoordinatorExitInput.live_v4.coordinator_exit = nonzeroCoordinatorExitPath;
    nonzeroCoordinatorExitInput.agent_cu.validation_report = writeJSON(
      path.join(root, 'nonzero-coordinator-exit-concurrent.json'),
      nonzeroCoordinatorExitConcurrent,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(
          path.join(root, 'nonzero-coordinator-exit-input.json'),
          nonzeroCoordinatorExitInput,
        ),
        path.join(root, 'nonzero-coordinator-exit-manifest.json'),
      ),
      /does not prove zero exit/,
    );
    const coordinatorInvocationDriftInput = structuredClone(inputValue);
    const coordinatorInvocationDrift = JSON.parse(fs.readFileSync(
      concurrent.spec.coordinator_invocation,
    ));
    coordinatorInvocationDrift.pid += 1;
    const coordinatorInvocationDriftPath = writeJSON(
      path.join(root, 'coordinator-invocation-drift.json'),
      coordinatorInvocationDrift,
    );
    const coordinatorInvocationDriftConcurrent = structuredClone(concurrentValue);
    coordinatorInvocationDriftConcurrent.coordinator.invocation_sha256 = sha256(fs.readFileSync(
      coordinatorInvocationDriftPath,
    ));
    coordinatorInvocationDriftInput.live_v4.coordinator_invocation
      = coordinatorInvocationDriftPath;
    coordinatorInvocationDriftInput.agent_cu.validation_report = writeJSON(
      path.join(root, 'coordinator-invocation-drift-concurrent.json'),
      coordinatorInvocationDriftConcurrent,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(
          path.join(root, 'coordinator-invocation-drift-input.json'),
          coordinatorInvocationDriftInput,
        ),
        path.join(root, 'coordinator-invocation-drift-manifest.json'),
      ),
      /coordinator invocation belongs to another process generation/,
    );
    const lateCoverageInput = structuredClone(inputValue);
    const lateCoverageTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
    lateCoverageTree.coverage_started_at_milliseconds
      = concurrentValue.agent.released_at_milliseconds + 1;
    lateCoverageTree.readiness_published_at_milliseconds
      = lateCoverageTree.coverage_started_at_milliseconds + 1;
    lateCoverageTree.acknowledgement_authorization.authorized_at_milliseconds
      = lateCoverageTree.readiness_published_at_milliseconds;
    lateCoverageInput.deployment.process_trees[1] = writeSynchronizedProcessTree(
      root,
      'late-coverage-process-tree',
      lateCoverageTree,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'late-coverage-input.json'), lateCoverageInput),
        path.join(root, 'late-coverage-manifest.json'),
      ),
      /coverage does not bracket the concurrent operation interval/,
    );
    const earlyCoverageInput = structuredClone(inputValue);
    const earlyCoverageTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
    earlyCoverageTree.coverage_completed_at_milliseconds
      = concurrentValue.overlap.operations_completed_at_milliseconds - 1;
    earlyCoverageTree.final_sample_started_at_milliseconds
      = earlyCoverageTree.coverage_completed_at_milliseconds - 1;
    earlyCoverageTree.captured_at_milliseconds
      = earlyCoverageTree.coverage_completed_at_milliseconds + 1;
    earlyCoverageInput.deployment.process_trees[1] = writeJSON(
      path.join(root, 'early-coverage-process-tree.json'),
      earlyCoverageTree,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'early-coverage-input.json'), earlyCoverageInput),
        path.join(root, 'early-coverage-manifest.json'),
      ),
      /coverage does not bracket the concurrent operation interval/,
    );
    const lateEnrichmentInput = structuredClone(inputValue);
    const lateEnrichmentTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
    lateEnrichmentTree.final_sample_started_at_milliseconds
      = concurrentValue.overlap.operations_completed_at_milliseconds - 1;
    lateEnrichmentInput.deployment.process_trees[1] = writeJSON(
      path.join(root, 'late-enrichment-process-tree.json'),
      lateEnrichmentTree,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'late-enrichment-input.json'), lateEnrichmentInput),
        path.join(root, 'late-enrichment-manifest.json'),
      ),
      /coverage does not bracket the concurrent operation interval/,
    );
    for (const [timingDrift, mutateTiming] of [
      ['legacy-version', (tree) => { tree.version = 1; }],
      [
        'excessive-gap',
        (tree) => {
          tree.observed_maximum_sample_gap_milliseconds
            = tree.maximum_sample_gap_milliseconds + 1;
        },
      ],
      [
        'insufficient-samples',
        (tree) => {
          tree.maximum_sample_gap_milliseconds = 100;
          tree.observed_maximum_sample_gap_milliseconds = 50;
          tree.sample_count = 4;
        },
      ],
      [
        'missing-continuous-lifecycle',
        (tree) => { tree.continuous_lifecycle_observation = false; },
      ],
    ]) {
      const timingInput = structuredClone(inputValue);
      const timingTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
      mutateTiming(timingTree);
      timingInput.deployment.process_trees[1] = writeJSON(
        path.join(root, `${timingDrift}-process-tree.json`),
        timingTree,
      );
      assert.throws(
        () => generateManifest(
          writeJSON(path.join(root, `${timingDrift}-input.json`), timingInput),
          path.join(root, `${timingDrift}-manifest.json`),
        ),
        /process_trees\[1\] is malformed/,
      );
    }
    const wrongElevationInput = structuredClone(inputValue);
    wrongElevationInput.deployment.elevation_receipts[1] = writeJSON(
      path.join(root, 'wrong-elevation-receipt.json'),
      {
        ...JSON.parse(fs.readFileSync(deployment.elevationReceipts[1])),
        transactionId: 'CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC',
      },
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'wrong-elevation-input.json'), wrongElevationInput),
        path.join(root, 'wrong-elevation-manifest.json'),
      ),
      /elevation receipt differs from its installed inventory/,
    );
    const duplicateElevationInput = structuredClone(inputValue);
    const duplicateElevationReceipt = writeFile(
      path.join(root, 'duplicate-local-as-studio-elevation.json'),
      fs.readFileSync(deployment.elevationReceipts[0]),
    );
    duplicateElevationInput.deployment.elevation_receipts[1] = duplicateElevationReceipt;
    duplicateElevationInput.deployment.installed_inventories[1] = installedInventory(
      root,
      'studio',
      deployment.studioUUID,
      localInventory.entries,
      qualificationToolsAggregate,
      sha256(fs.readFileSync(duplicateElevationReceipt)),
      '-duplicate-elevation',
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'duplicate-elevation-input.json'), duplicateElevationInput),
        path.join(root, 'duplicate-elevation-manifest.json'),
      ),
      /elevation transaction IDs are not host-distinct/,
    );
    const duplicateNodeInput = structuredClone(inputValue);
    const duplicateNodeReceiptValue = JSON.parse(fs.readFileSync(deployment.elevationReceipts[1]));
    duplicateNodeReceiptValue.nodeId = JSON.parse(
      fs.readFileSync(deployment.elevationReceipts[0]),
    ).nodeId;
    const duplicateNodeReceipt = writeJSON(
      path.join(root, 'duplicate-node-elevation.json'),
      duplicateNodeReceiptValue,
    );
    duplicateNodeInput.deployment.elevation_receipts[1] = duplicateNodeReceipt;
    duplicateNodeInput.deployment.installed_inventories[1] = installedInventory(
      root,
      'studio',
      deployment.studioUUID,
      localInventory.entries,
      qualificationToolsAggregate,
      sha256(fs.readFileSync(duplicateNodeReceipt)),
      '-duplicate-node',
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'duplicate-node-input.json'), duplicateNodeInput),
        path.join(root, 'duplicate-node-manifest.json'),
      ),
      /elevation node IDs are not host-distinct/,
    );
    const invalidProfileInput = structuredClone(inputValue);
    const invalidProfileReceiptValue = JSON.parse(fs.readFileSync(deployment.elevationReceipts[0]));
    invalidProfileReceiptValue.nodeProfile = 'local';
    const invalidProfileReceipt = writeJSON(
      path.join(root, 'invalid-profile-elevation.json'),
      invalidProfileReceiptValue,
    );
    invalidProfileInput.deployment.elevation_receipts[0] = invalidProfileReceipt;
    invalidProfileInput.deployment.installed_inventories[0] = installedInventory(
      root,
      'local',
      deployment.localUUID,
      localInventory.entries,
      qualificationToolsAggregate,
      sha256(fs.readFileSync(invalidProfileReceipt)),
      '-invalid-profile',
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'invalid-profile-input.json'), invalidProfileInput),
        path.join(root, 'invalid-profile-manifest.json'),
      ),
      /not one installed source-bound elevation receipt/,
    );
    const wrongElevationRootInput = structuredClone(inputValue);
    for (const treeIndex of [0, 1, 2]) {
      const tree = JSON.parse(fs.readFileSync(deployment.processTrees[treeIndex]));
      const elevationRoot = tree.roots.find((entry) => entry.root_class === 'elevation');
      const elevationProcess = tree.processes.find((entry) => entry.pid === elevationRoot.pid
        && entry.start_identity === elevationRoot.start_identity);
      elevationRoot.code_signature_hash = '0'.repeat(40);
      elevationProcess.code_signature_hash = elevationRoot.code_signature_hash;
      wrongElevationRootInput.deployment.process_trees[treeIndex] = writeSynchronizedProcessTree(
        root,
        `wrong-elevation-root-tree-${treeIndex}`,
        tree,
      );
    }
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'wrong-elevation-root-input.json'), wrongElevationRootInput),
        path.join(root, 'wrong-elevation-root-manifest.json'),
      ),
      /local elevation root differs from its installed receipt/,
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
    wrongToolsAggregateInput.deployment.executable_policy_reports
      = deployment.policyReports.map((_reportPath, reportIndex) => {
        const role = reportIndex === 0 ? 'local' : 'studio';
        const specPath = writeJSON(path.join(root, `wrong-tools-policy-spec-${reportIndex}.json`), {
          version: 1,
          installed_inventory: wrongToolsAggregateInput.deployment.installed_inventories[reportIndex],
          artifact_roots: deployment.artifactRoots,
        });
        const outputPath = path.join(root, `wrong-tools-policy-${reportIndex}.json`);
        const result = spawnSync(process.execPath, [
          deployment.policyScanner, 'generate', '--spec', specPath, '--output', outputPath,
        ], { encoding: 'utf8' });
        assert.equal(result.status, 0, `${role}: ${result.stderr}`);
        return outputPath;
      });
    wrongToolsAggregateInput.artifact_manifest = writeJSON(
      path.join(root, 'wrong-tools-artifact-binding.json'),
      {
        ...JSON.parse(fs.readFileSync(artifactManifest)),
        qualification_tools_aggregate_sha256: '0'.repeat(64),
      },
      0o400,
    );
    const wrongInstalledAggregate = JSON.parse(fs.readFileSync(
      wrongToolsAggregateInput.deployment.installed_inventories[0],
    )).aggregate_sha256;
    wrongToolsAggregateInput.matrix_cycles = matrix.map((cycle, cycleIndex) => {
      const certificate = JSON.parse(fs.readFileSync(cycle.certificate));
      const crash = JSON.parse(fs.readFileSync(cycle.crash_inventory));
      certificate.installed_inventory_aggregate_sha256 = wrongInstalledAggregate;
      crash.installed_inventory_aggregate_sha256 = wrongInstalledAggregate;
      return {
        certificate: writeJSON(
          path.join(root, `wrong-tools-cycle-${cycleIndex + 1}.json`),
          certificate,
        ),
        crash_inventory: writeJSON(
          path.join(root, `wrong-tools-crash-${cycleIndex + 1}.json`),
          crash,
        ),
        playground_alert_lifecycle: cycle.playground_alert_lifecycle,
      };
    });
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'wrong-tools-aggregate-input.json'), wrongToolsAggregateInput),
        path.join(root, 'wrong-tools-aggregate-manifest.json'),
      ),
      /qualification tools aggregate differs from installed inventories/,
    );
    const substitutedScannerInput = structuredClone(inputValue);
    const substitutedScannerDirectory = privateDirectory(root, 'substituted-policy-scanner');
    writeFile(
      path.join(substitutedScannerDirectory, 'lib.mjs'),
      fs.readFileSync(path.join(toolRoot, 'lib.mjs')),
      0o400,
    );
    const substitutedScanner = writeFile(
      path.join(substitutedScannerDirectory, 'executable-policy-scanner.mjs'),
      fs.readFileSync(deployment.policyScanner),
      0o500,
    );
    substitutedScannerInput.deployment.executable_policy_scanner = substitutedScanner;
    substitutedScannerInput.deployment.executable_policy_reports = deployment.policyReports.map(
      (reportPath, reportIndex) => {
        const report = JSON.parse(fs.readFileSync(reportPath));
        report.scanner_path = substitutedScanner;
        return writeJSON(path.join(root, `substituted-scanner-report-${reportIndex}.json`), report);
      },
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'substituted-scanner-input.json'), substitutedScannerInput),
        path.join(root, 'substituted-scanner-manifest.json'),
      ),
      /executable-policy-scanner\.mjs differs from the reviewed qualification tools/,
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
    const forgedClassificationInput = structuredClone(inputValue);
    const forgedClassification = JSON.parse(fs.readFileSync(deployment.policyReports[0]));
    const forgedExecutable = forgedClassification.file_coverage.find((entry) => (
      entry.classification === 'executable'
    ));
    forgedExecutable.classification = 'data';
    forgedClassification.scanned_executable_count -= 1;
    forgedClassification.coverage_aggregate_sha256 = aggregateSHA256(
      'executable-policy-coverage',
      {
        scanner_sha256: forgedClassification.scanner_sha256,
        installed_inventory_sha256: forgedClassification.installed_inventory_sha256,
        installed_inventory_aggregate_sha256:
          forgedClassification.installed_inventory_aggregate_sha256,
        artifact_roots: forgedClassification.artifact_roots,
        scanned_roots: forgedClassification.scanned_roots,
        covered_entries: forgedClassification.covered_entries,
        file_coverage: forgedClassification.file_coverage,
      },
    );
    forgedClassificationInput.deployment.executable_policy_reports[0] = writeJSON(
      path.join(root, 'forged-classification-policy.json'),
      forgedClassification,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'forged-classification-input.json'), forgedClassificationInput),
        path.join(root, 'forged-classification-manifest.json'),
      ),
      /fresh source-owned scan/,
    );
    const subsetPolicyInput = structuredClone(inputValue);
    const subsetPolicy = JSON.parse(fs.readFileSync(deployment.policyReports[0]));
    subsetPolicy.covered_entries = subsetPolicy.covered_entries.slice(0, -1);
    const subsetCoverage = {
      installed_inventory_aggregate_sha256: subsetPolicy.installed_inventory_aggregate_sha256,
      scanned_roots: subsetPolicy.scanned_roots,
      covered_entries: subsetPolicy.covered_entries,
      file_coverage: subsetPolicy.file_coverage,
    };
    subsetPolicy.coverage_aggregate_sha256 = aggregateSHA256(
      'executable-policy-coverage',
      subsetCoverage,
    );
    subsetPolicyInput.deployment.executable_policy_reports[0] = writeJSON(
      path.join(root, 'subset-executable-policy.json'),
      subsetPolicy,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'subset-executable-policy-input.json'), subsetPolicyInput),
        path.join(root, 'subset-executable-policy-manifest.json'),
      ),
      /does not cover the complete installed inventory/,
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
    const substitutedQualificationToolInput = structuredClone(inputValue);
    const substitutedPlanConstructor = writeFile(
      path.join(privateDirectory(root, 'substituted-plan-constructor'), 'construct-live-plan.mjs'),
      fs.readFileSync(inputValue.tooling.plan_constructor),
      0o500,
    );
    substitutedQualificationToolInput.tooling.plan_constructor = substitutedPlanConstructor;
    assert.throws(
      () => generateManifest(
        writeJSON(
          path.join(root, 'substituted-qualification-tool-input.json'),
          substitutedQualificationToolInput,
        ),
        path.join(root, 'substituted-qualification-tool-manifest.json'),
      ),
      /differs from the reviewed qualification tools/,
    );
    const duplicateCycleInput = structuredClone(inputValue);
    const duplicateCycleCertificate = JSON.parse(fs.readFileSync(matrix[1].certificate));
    const duplicateCycleCrash = JSON.parse(fs.readFileSync(matrix[1].crash_inventory));
    const duplicateAlertLifecycle = JSON.parse(fs.readFileSync(
      matrix[1].playground_alert_lifecycle,
    ));
    duplicateCycleCertificate.execution_nonce
      = JSON.parse(fs.readFileSync(matrix[0].certificate)).execution_nonce;
    duplicateCycleCrash.execution_nonce = duplicateCycleCertificate.execution_nonce;
    duplicateAlertLifecycle.execution_nonce = duplicateCycleCertificate.execution_nonce;
    duplicateCycleInput.matrix_cycles[1] = {
      certificate: writeJSON(
        path.join(root, 'duplicate-cycle-certificate.json'),
        duplicateCycleCertificate,
      ),
      crash_inventory: writeJSON(
        path.join(root, 'duplicate-cycle-crash.json'),
        duplicateCycleCrash,
      ),
      playground_alert_lifecycle: writeJSON(
        path.join(root, 'duplicate-cycle-alert.json'),
        duplicateAlertLifecycle,
      ),
    };
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'duplicate-cycle-input.json'), duplicateCycleInput),
        path.join(root, 'duplicate-cycle-manifest.json'),
      ),
      /matrix cycle nonces are not distinct/,
    );
    const staleCandidateCycleInput = structuredClone(inputValue);
    const staleCandidateCertificate = JSON.parse(fs.readFileSync(matrix[0].certificate));
    staleCandidateCertificate.peekaboo_artifact_manifest_sha256 = '0'.repeat(64);
    staleCandidateCycleInput.matrix_cycles[0].certificate = writeJSON(
      path.join(root, 'stale-candidate-cycle.json'),
      staleCandidateCertificate,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'stale-candidate-cycle-input.json'), staleCandidateCycleInput),
        path.join(root, 'stale-candidate-cycle-manifest.json'),
      ),
      /passing 42\/42 certificate/,
    );
    const badCrashInput = structuredClone(inputValue);
    badCrashInput.matrix_cycles[0].crash_inventory = writeJSON(
      path.join(root, 'bad-crash.json'),
      {
        ...JSON.parse(fs.readFileSync(matrix[0].crash_inventory)),
        passed: false,
        added: [{ name: 'Peekaboo.crash' }],
      },
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'bad-crash-input.json'), badCrashInput),
        path.join(root, 'bad-crash-manifest.json'),
      ),
      /zero-delta crash comparison/,
    );
    const missingAlertInput = structuredClone(inputValue);
    delete missingAlertInput.matrix_cycles[0].playground_alert_lifecycle;
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'missing-alert-input.json'), missingAlertInput),
        path.join(root, 'missing-alert-manifest.json'),
      ),
      /matrix_cycles\[0\] keys are not closed/,
    );
    const slowAlertInput = structuredClone(inputValue);
    const slowAlert = JSON.parse(fs.readFileSync(matrix[0].playground_alert_lifecycle));
    const slowAlertTiming = JSON.parse(fs.readFileSync(
      slowAlert.phases['post-dismiss-ax'].timing.path,
    ));
    slowAlertTiming.completed_at_milliseconds = slowAlertTiming.started_at_milliseconds
      + PLAYGROUND_AX_SEE_BUDGET_MILLISECONDS;
    slowAlertTiming.wall_time_milliseconds = PLAYGROUND_AX_SEE_BUDGET_MILLISECONDS;
    const slowAlertTimingPath = writeJSON(
      path.join(root, 'slow-alert-timing.json'),
      slowAlertTiming,
    );
    slowAlert.phases['post-dismiss-ax'].timing = {
      path: slowAlertTimingPath,
      size: fs.statSync(slowAlertTimingPath).size,
      sha256: sha256(fs.readFileSync(slowAlertTimingPath)),
    };
    slowAlertInput.matrix_cycles[0].playground_alert_lifecycle = writeJSON(
      path.join(root, 'slow-alert.json'),
      slowAlert,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'slow-alert-input.json'), slowAlertInput),
        path.join(root, 'slow-alert-manifest.json'),
      ),
      /1.5-second budget/,
    );
    const splicedElementInput = structuredClone(inputValue);
    const splicedElementReport = JSON.parse(fs.readFileSync(
      matrix[0].playground_alert_lifecycle,
    ));
    const splicedInitial = JSON.parse(fs.readFileSync(
      splicedElementReport.phases['initial-see'].result.path,
    ));
    splicedInitial.data.ui_elements.find((element) => (
      element.identifier === 'dialog-fixture-show-alert'
    )).id = 'SPLICED-ELEMENT';
    const splicedInitialPath = writeJSON(
      path.join(root, 'spliced-initial-see.json'),
      splicedInitial,
    );
    splicedElementReport.phases['initial-see'].result = {
      path: splicedInitialPath,
      size: fs.statSync(splicedInitialPath).size,
      sha256: sha256(fs.readFileSync(splicedInitialPath)),
    };
    splicedElementInput.matrix_cycles[0].playground_alert_lifecycle = writeJSON(
      path.join(root, 'spliced-element-report.json'),
      splicedElementReport,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'spliced-element-input.json'), splicedElementInput),
        path.join(root, 'spliced-element-manifest.json'),
      ),
      /signed observation\/click bytes do not bind the exact Show Alert snapshot element/,
    );

    const forgedPostInput = structuredClone(inputValue);
    const forgedPostReport = JSON.parse(fs.readFileSync(
      matrix[0].playground_alert_lifecycle,
    ));
    const postPair = forgedPostReport.phases['post-dismiss-ax'].bundles[0];
    const forgedBundleValue = JSON.parse(fs.readFileSync(postPair.bundle.path));
    const postSnapshot = JSON.parse(fs.readFileSync(
      forgedPostReport.phases['post-dismiss-ax'].result.path,
    )).data.snapshot_id;
    forgedBundleValue.canonicalResponse = canonicalBytes({
      snapshotId: postSnapshot,
      screenshotPath: '',
      metadata: { isDialog: true },
      elements: [{
        id: 'T42', identifier: 'dialog-fixture-last-alert-result', label: 'OK',
      }],
    }).toString('base64');
    const forgedReceiptDirectory = privateDirectory(root, 'forged-post-receipts');
    const forgedValidatorDirectory = privateDirectory(root, 'forged-post-validators');
    const forgedBundlePath = writeJSON(
      path.join(forgedReceiptDirectory, path.basename(postPair.bundle.path)),
      forgedBundleValue,
    );
    const forgedValidatorValue = JSON.parse(fs.readFileSync(postPair.validator.path));
    forgedValidatorValue.data.bundle_sha256 = sha256(fs.readFileSync(forgedBundlePath));
    const forgedValidatorPath = writeJSON(
      path.join(forgedValidatorDirectory, path.basename(postPair.validator.path)),
      forgedValidatorValue,
    );
    forgedPostReport.phases['post-dismiss-ax'].receipt_directory = forgedReceiptDirectory;
    forgedPostReport.phases['post-dismiss-ax'].validator_directory = forgedValidatorDirectory;
    forgedPostReport.phases['post-dismiss-ax'].bundles = [{
      bundle: {
        path: forgedBundlePath,
        size: fs.statSync(forgedBundlePath).size,
        sha256: sha256(fs.readFileSync(forgedBundlePath)),
      },
      validator: {
        path: forgedValidatorPath,
        size: fs.statSync(forgedValidatorPath).size,
        sha256: sha256(fs.readFileSync(forgedValidatorPath)),
      },
    }];
    forgedPostInput.matrix_cycles[0].playground_alert_lifecycle = writeJSON(
      path.join(root, 'forged-post-report.json'),
      forgedPostReport,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'forged-post-input.json'), forgedPostInput),
        path.join(root, 'forged-post-manifest.json'),
      ),
      /signed post-dismiss observation does not bind the fresh AX result/,
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
      /execution staging differs from its retained source\/plan bytes|differs from concurrent validation/,
    );
    const fabricatedInterleavingInput = structuredClone(inputValue);
    const fabricatedInterleaving = JSON.parse(fs.readFileSync(concurrentReport));
    fabricatedInterleaving.agent.progress_interleaving.action_intervals[0]
      .started_at_milliseconds -= 1;
    fabricatedInterleavingInput.agent_cu.validation_report = writeJSON(
      path.join(root, 'fabricated-interleaving-report.json'),
      fabricatedInterleaving,
    );
    assert.throws(
      () => generateManifest(
        writeJSON(
          path.join(root, 'fabricated-interleaving-input.json'),
          fabricatedInterleavingInput,
        ),
        path.join(root, 'fabricated-interleaving-manifest.json'),
      ),
      /concurrent validation report differs from fresh concurrent evidence validation|progress interleaving differs from the bound bundles\/readback/,
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
    const agentValidatorPath = inputValue.agent_cu.live_validator_reports[0];
    const agentValidatorBytes = fs.readFileSync(agentValidatorPath);
    const forgedAgentValidator = JSON.parse(agentValidatorBytes);
    forgedAgentValidator.data.host.pid += 1;
    writeJSON(agentValidatorPath, forgedAgentValidator);
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'forged-agent-validator-input.json'), inputValue),
        path.join(root, 'forged-agent-validator-manifest.json'),
      ),
      /retained validator(?: report)? differs from authenticated live validation/,
    );
    writeFile(agentValidatorPath, agentValidatorBytes);

    const baselinePath = inputValue.agent_cu.semantic_readbacks[0];
    const baselineBytes = fs.readFileSync(baselinePath);
    const lateBaseline = JSON.parse(baselineBytes);
    lateBaseline.observed_at_milliseconds
      = concurrentValue.overlap.operations_started_at_milliseconds + 101;
    writeJSON(baselinePath, lateBaseline);
    fs.utimesSync(
      baselinePath,
      new Date(lateBaseline.observed_at_milliseconds),
      new Date(lateBaseline.observed_at_milliseconds),
    );
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'late-baseline-input.json'), inputValue),
        path.join(root, 'late-baseline-manifest.json'),
      ),
      /baseline\/mutation\/restoration order is invalid/,
    );
    writeFile(baselinePath, baselineBytes);
    const baselineObservedAt = JSON.parse(baselineBytes).observed_at_milliseconds;
    fs.utimesSync(baselinePath, new Date(baselineObservedAt), new Date(baselineObservedAt));

    const staleMiddleSourceInput = structuredClone(inputValue);
    const staleMiddleValidator = JSON.parse(fs.readFileSync(middleBundle.validator));
    staleMiddleValidator.data.host_source_commit = '0'.repeat(40);
    staleMiddleSourceInput.adjuncts.middle_click.live_validator_reports = [writeJSON(
      path.join(root, 'stale-middle-source-validator.json'), staleMiddleValidator,
    )];
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'stale-middle-source-input.json'), staleMiddleSourceInput),
        path.join(root, 'stale-middle-source-manifest.json'),
      ),
      /differs from the exact candidate Bridge host/,
    );
    const foreignHeldKeyHostInput = structuredClone(inputValue);
    const foreignHeldKeyValidator = JSON.parse(fs.readFileSync(keyBundle.validator));
    foreignHeldKeyValidator.data.host.pid += 1;
    foreignHeldKeyHostInput.adjuncts.held_key.live_validator_reports = [writeJSON(
      path.join(root, 'foreign-held-key-host-validator.json'), foreignHeldKeyValidator,
    )];
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'foreign-held-key-host-input.json'), foreignHeldKeyHostInput),
        path.join(root, 'foreign-held-key-host-manifest.json'),
      ),
      /differs from the exact candidate Bridge host/,
    );
    const foreignPointerTargetInput = structuredClone(inputValue);
    const foreignPointerController = JSON.parse(fs.readFileSync(pointerControllerResult));
    foreignPointerController.target.pid = 999;
    foreignPointerController.target.start_identity = '999001';
    foreignPointerController.target.window_id = 999;
    foreignPointerTargetInput.adjuncts.held_pointer.controller_results = [writeJSON(
      path.join(root, 'foreign-pointer-target-controller.json'), foreignPointerController,
    )];
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'foreign-pointer-target-input.json'), foreignPointerTargetInput),
        path.join(root, 'foreign-pointer-target-manifest.json'),
      ),
      /is not one exact controlled fixture target/,
    );
    const foreignPointerListInput = structuredClone(inputValue);
    const foreignPointerListBundleValue = JSON.parse(fs.readFileSync(pointerPairs[0].bundle));
    foreignPointerListBundleValue.receipt.payload.target.processIdentifier = 999;
    foreignPointerListBundleValue.receipt.payload.target.processStartIdentity = '999001';
    foreignPointerListBundleValue.receipt.payload.target.windowID = 999;
    const foreignPointerListBundle = writeJSON(
      path.join(root, 'foreign-pointer-list-bundle.json'),
      foreignPointerListBundleValue,
    );
    const foreignPointerListValidatorValue = JSON.parse(fs.readFileSync(pointerPairs[0].validator));
    foreignPointerListValidatorValue.data.bundle_sha256 = sha256(fs.readFileSync(foreignPointerListBundle));
    const foreignPointerListValidator = writeJSON(
      path.join(root, 'foreign-pointer-list-validator.json'),
      foreignPointerListValidatorValue,
    );
    const foreignPointerListControllerValue = JSON.parse(fs.readFileSync(pointerControllerResult));
    foreignPointerListControllerValue.operations[0].bundle.sha256
      = sha256(fs.readFileSync(foreignPointerListBundle));
    foreignPointerListInput.adjuncts.held_pointer.raw_bundles[0] = foreignPointerListBundle;
    foreignPointerListInput.adjuncts.held_pointer.live_validator_reports[0]
      = foreignPointerListValidator;
    foreignPointerListInput.adjuncts.held_pointer.controller_results = [writeJSON(
      path.join(root, 'foreign-pointer-list-controller.json'),
      foreignPointerListControllerValue,
    )];
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'foreign-pointer-list-input.json'), foreignPointerListInput),
        path.join(root, 'foreign-pointer-list-manifest.json'),
      ),
      /target-bearing operation differs from the controlled fixture/,
    );
    const targetedPointerCreateInput = structuredClone(inputValue);
    const targetedPointerCreateBundleValue = JSON.parse(fs.readFileSync(pointerPairs[2].bundle));
    targetedPointerCreateBundleValue.receipt.payload.target = {
      kind: 'window',
      processIdentifier: adjunctTarget.pid,
      processStartIdentity: adjunctTarget.start_identity,
      windowID: adjunctTarget.window_id,
    };
    const targetedPointerCreateBundle = writeJSON(
      path.join(root, 'targeted-pointer-create-bundle.json'),
      targetedPointerCreateBundleValue,
    );
    const targetedPointerCreateValidatorValue = JSON.parse(fs.readFileSync(pointerPairs[2].validator));
    targetedPointerCreateValidatorValue.data.target_attested = true;
    targetedPointerCreateValidatorValue.data.bundle_sha256
      = sha256(fs.readFileSync(targetedPointerCreateBundle));
    const targetedPointerCreateValidator = writeJSON(
      path.join(root, 'targeted-pointer-create-validator.json'),
      targetedPointerCreateValidatorValue,
    );
    const targetedPointerCreateControllerValue = JSON.parse(fs.readFileSync(pointerControllerResult));
    targetedPointerCreateControllerValue.operations[2].bundle.sha256
      = sha256(fs.readFileSync(targetedPointerCreateBundle));
    targetedPointerCreateInput.adjuncts.held_pointer.raw_bundles[2]
      = targetedPointerCreateBundle;
    targetedPointerCreateInput.adjuncts.held_pointer.live_validator_reports[2]
      = targetedPointerCreateValidator;
    targetedPointerCreateInput.adjuncts.held_pointer.controller_results = [writeJSON(
      path.join(root, 'targeted-pointer-create-controller.json'),
      targetedPointerCreateControllerValue,
    )];
    assert.throws(
      () => generateManifest(
        writeJSON(path.join(root, 'targeted-pointer-create-input.json'), targetedPointerCreateInput),
        path.join(root, 'targeted-pointer-create-manifest.json'),
      ),
      /targetless held-pointer operation claimed a target/,
    );
    const restoredLocalDuringTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
    synchronizeProcessTreeAuthorization(restoredLocalDuringTree);
    writeJSON(deployment.processTrees[1], restoredLocalDuringTree);
    const input = writeJSON(path.join(root, 'manifest-input.json'), inputValue);
    const output = path.join(root, 'qualification-manifest.json');
    generateManifest(input, output);
    const verified = verifyManifest(output);
    assert.equal(verified.version, 2);
    assert.equal(verified.valid, true);
    assert.equal(verified.adjuncts_are_live_v4_slots, false);
    const retainedLocalDuringTree = JSON.parse(fs.readFileSync(deployment.processTrees[1]));
    const retainedAuthorization = retainedLocalDuringTree.acknowledgement_authorization;
    const retainedAuthorizationRequest = fs.readFileSync(
      retainedAuthorization.authorization_request_path,
    );
    const retainedAuthorizationResult = fs.readFileSync(
      retainedAuthorization.authorization_result_path,
    );
    const retainedAcknowledgement = fs.readFileSync(retainedAuthorization.acknowledgement_path);
    const changedAuthorizationResult = JSON.parse(retainedAuthorizationResult);
    changedAuthorizationResult.authorized_at_milliseconds += 1;
    writeJSON(retainedAuthorization.authorization_result_path, changedAuthorizationResult);
    assert.throws(
      () => verifyManifest(output),
      /authorization artifacts are invalid or changed/,
    );
    writeFile(retainedAuthorization.authorization_result_path, retainedAuthorizationResult, 0o600);
    const removedAuthorizationRequest = `${retainedAuthorization.authorization_request_path}.removed`;
    fs.renameSync(retainedAuthorization.authorization_request_path, removedAuthorizationRequest);
    assert.throws(() => verifyManifest(output), /ENOENT|no such file/i);
    fs.renameSync(removedAuthorizationRequest, retainedAuthorization.authorization_request_path);
    writeJSON(retainedAuthorization.acknowledgement_path, {
      version: 1,
      challenge: '0'.repeat(64),
    });
    assert.throws(
      () => verifyManifest(output),
      /acknowledgement keys are not closed|authorization artifacts are invalid or changed/,
    );
    writeFile(retainedAuthorization.acknowledgement_path, retainedAcknowledgement, 0o600);
    assert.equal(verifyManifest(output).valid, true);
    assert.equal(
      sha256(fs.readFileSync(retainedAuthorization.authorization_request_path)),
      sha256(retainedAuthorizationRequest),
    );
    const generatedManifest = JSON.parse(fs.readFileSync(output));
    assert.equal(generatedManifest.version, 2);
    assert.equal(generatedManifest.evidence.deployment.installed_inventories.length, 2);
    assert.equal(generatedManifest.evidence.deployment.process_trees.length, 6);
    assert.deepEqual(
      generatedManifest.evidence.agent_cu.controlled_fixture_targets,
      [
        {
          label: 'target-a', controller_id: 'controller-a',
          target: { pid: 301, start_identity: '301001', window_id: 401 },
        },
        {
          label: 'target-b', controller_id: 'controller-b',
          target: { pid: 302, start_identity: '302001', window_id: 402 },
        },
      ],
    );

    const resealedTargetManifest = structuredClone(generatedManifest);
    resealedTargetManifest.evidence.agent_cu.controlled_fixture_targets.reverse();
    resealedTargetManifest.evidence_aggregate_sha256 = aggregateSHA256(
      'evidence-manifest',
      resealedTargetManifest.evidence,
    );
    const resealedTargetManifestPath = writeJSON(
      path.join(root, 'resealed-controlled-target-manifest.json'),
      resealedTargetManifest,
    );
    assert.throws(
      () => verifyManifest(resealedTargetManifestPath),
      /controlled_fixture_targets\[0\] is not canonical/,
    );

    const originalSummaryBytes = fs.readFileSync(concurrent.summary);
    const originalCoordinatorEventBytes = fs.readFileSync(concurrent.spec.coordinator_events);
    const resealedFailedSummary = JSON.parse(originalSummaryBytes);
    resealedFailedSummary.structural_validation_passed = false;
    resealedFailedSummary.failures = [{
      rule: 'resealed_failure', message: 'failed', slot_id: null,
    }];
    delete resealedFailedSummary.summary_core_sha256;
    resealedFailedSummary.summary_core_sha256 = multiTargetAggregateSHA256(
      'summary-core',
      resealedFailedSummary,
    );
    writeJSON(concurrent.summary, resealedFailedSummary);
    updateCoordinatorSummaryCommitment(
      concurrent.spec.coordinator_events,
      concurrent.summary,
    );
    const resealedSummaryManifest = structuredClone(generatedManifest);
    const resealedSummaryBytes = fs.readFileSync(concurrent.summary);
    resealedSummaryManifest.evidence.live_v4.certification_summary = {
      path: concurrent.summary,
      size: resealedSummaryBytes.length,
      sha256: sha256(resealedSummaryBytes),
    };
    const resealedCoordinatorEventBytes = fs.readFileSync(concurrent.spec.coordinator_events);
    resealedSummaryManifest.evidence.live_v4.coordinator_events = {
      path: concurrent.spec.coordinator_events,
      size: resealedCoordinatorEventBytes.length,
      sha256: sha256(resealedCoordinatorEventBytes),
    };
    const resealedSummaryReportValue = JSON.parse(fs.readFileSync(concurrentReport));
    resealedSummaryReportValue.coordinator.summary_sha256 = sha256(resealedSummaryBytes);
    resealedSummaryReportValue.coordinator.events_sha256
      = sha256(resealedCoordinatorEventBytes);
    const resealedSummaryReport = writeJSON(
      path.join(root, 'resealed-failed-summary-report.json'),
      resealedSummaryReportValue,
    );
    const resealedSummaryReportBytes = fs.readFileSync(resealedSummaryReport);
    resealedSummaryManifest.evidence.agent_cu.validation_report = {
      path: resealedSummaryReport,
      size: resealedSummaryReportBytes.length,
      sha256: sha256(resealedSummaryReportBytes),
    };
    resealedSummaryManifest.evidence_aggregate_sha256 = aggregateSHA256(
      'evidence-manifest',
      resealedSummaryManifest.evidence,
    );
    const resealedSummaryPath = writeJSON(
      path.join(root, 'resealed-failed-summary-manifest.json'),
      resealedSummaryManifest,
    );
    assert.throws(
      () => verifyManifest(resealedSummaryPath),
      /coordinator exit interval does not contain its JSONL evidence|not one successful live certification core/,
    );
    writeFile(concurrent.summary, originalSummaryBytes);
    writeFile(concurrent.spec.coordinator_events, originalCoordinatorEventBytes);
    const retainedCoordinatorExitValue = JSON.parse(fs.readFileSync(
      concurrent.spec.coordinator_exit,
    ));
    const restoredCoordinatorEventTime = new Date(
      retainedCoordinatorExitValue.completed_at_milliseconds - 1,
    );
    fs.utimesSync(
      concurrent.spec.coordinator_events,
      restoredCoordinatorEventTime,
      restoredCoordinatorEventTime,
    );

    const resealedInterleavingManifest = structuredClone(generatedManifest);
    const resealedInterleavingReportValue = JSON.parse(fs.readFileSync(concurrentReport));
    resealedInterleavingReportValue.agent.progress_interleaving
      .integrated_cu_perform_at_milliseconds += 1;
    const resealedInterleavingReport = writeJSON(
      path.join(root, 'resealed-fabricated-interleaving-report.json'),
      resealedInterleavingReportValue,
    );
    const resealedInterleavingBytes = fs.readFileSync(resealedInterleavingReport);
    resealedInterleavingManifest.evidence.agent_cu.validation_report = {
      path: resealedInterleavingReport,
      size: resealedInterleavingBytes.length,
      sha256: sha256(resealedInterleavingBytes),
    };
    resealedInterleavingManifest.evidence_aggregate_sha256 = aggregateSHA256(
      'evidence-manifest',
      resealedInterleavingManifest.evidence,
    );
    const resealedInterleavingPath = writeJSON(
      path.join(root, 'resealed-fabricated-interleaving-manifest.json'),
      resealedInterleavingManifest,
    );
    assert.throws(
      () => verifyManifest(resealedInterleavingPath),
      /verified concurrent validation report differs from fresh concurrent evidence validation|progress interleaving differs from the bound bundles\/readback/,
    );

    const resealedMtimeManifest = structuredClone(generatedManifest);
    const resealedMtimeReportValue = JSON.parse(fs.readFileSync(concurrentReport));
    resealedMtimeReportValue.agent.progress_interleaving
      .integrated_cu_perform_readback_mtime_milliseconds += 1;
    const resealedMtimeReport = writeJSON(
      path.join(root, 'resealed-fabricated-perform-mtime-report.json'),
      resealedMtimeReportValue,
    );
    const resealedMtimeBytes = fs.readFileSync(resealedMtimeReport);
    resealedMtimeManifest.evidence.agent_cu.validation_report = {
      path: resealedMtimeReport,
      size: resealedMtimeBytes.length,
      sha256: sha256(resealedMtimeBytes),
    };
    resealedMtimeManifest.evidence_aggregate_sha256 = aggregateSHA256(
      'evidence-manifest',
      resealedMtimeManifest.evidence,
    );
    const resealedMtimePath = writeJSON(
      path.join(root, 'resealed-fabricated-perform-mtime-manifest.json'),
      resealedMtimeManifest,
    );
    assert.throws(
      () => verifyManifest(resealedMtimePath),
      /verified concurrent validation report differs from fresh concurrent evidence validation|progress interleaving differs from the bound bundles\/readback/,
    );

    const resealedForeignAdjunctManifest = structuredClone(generatedManifest);
    const resealedForeignValidator = JSON.parse(fs.readFileSync(keyBundle.validator));
    resealedForeignValidator.data.host_source_commit = '0'.repeat(40);
    const resealedForeignValidatorPath = writeJSON(
      path.join(root, 'resealed-foreign-adjunct-validator.json'),
      resealedForeignValidator,
    );
    const resealedForeignValidatorBytes = fs.readFileSync(resealedForeignValidatorPath);
    resealedForeignAdjunctManifest.evidence.adjuncts.held_key.live_validator_reports[0] = {
      path: resealedForeignValidatorPath,
      size: resealedForeignValidatorBytes.length,
      sha256: sha256(resealedForeignValidatorBytes),
    };
    resealedForeignAdjunctManifest.evidence_aggregate_sha256 = aggregateSHA256(
      'evidence-manifest',
      resealedForeignAdjunctManifest.evidence,
    );
    const resealedForeignAdjunctPath = writeJSON(
      path.join(root, 'resealed-foreign-adjunct-manifest.json'),
      resealedForeignAdjunctManifest,
    );
    assert.throws(
      () => verifyManifest(resealedForeignAdjunctPath),
      /differs from the exact candidate Bridge host/,
    );

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

    const retainedAlertReport = JSON.parse(fs.readFileSync(
      inputValue.matrix_cycles[0].playground_alert_lifecycle,
    ));
    const rawPostDismissPath = retainedAlertReport.phases['post-dismiss-ax'].result.path;
    const originalRawPostDismiss = fs.readFileSync(rawPostDismissPath);
    fs.appendFileSync(rawPostDismissPath, 'drift');
    assert.throws(() => verifyManifest(output), /changed after lifecycle construction/);
    writeFile(rawPostDismissPath, originalRawPostDismiss);

    const originalAlertLifecycle = fs.readFileSync(
      inputValue.matrix_cycles[0].playground_alert_lifecycle,
    );
    fs.appendFileSync(inputValue.matrix_cycles[0].playground_alert_lifecycle, 'drift');
    assert.throws(() => verifyManifest(output), /changed after manifest generation/);
    writeFile(
      inputValue.matrix_cycles[0].playground_alert_lifecycle,
      originalAlertLifecycle,
    );

    fs.appendFileSync(inputValue.matrix_cycles[0].certificate, 'drift');
    assert.throws(() => verifyManifest(output), /changed after manifest generation/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
