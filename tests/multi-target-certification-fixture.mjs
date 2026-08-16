import {
  createHash,
  generateKeyPairSync,
  randomUUID,
  sign,
} from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

import {
  aggregateSHA256,
  canonicalBytes,
  canonicalSHA256,
  deriveCertificationRunID,
  deterministicRequestID,
  monitorBaselineCommitmentSHA256,
  monitorHistoryCommitmentSHA256,
} from '../scripts/finalize-multi-target-certification.mjs';

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function processIdentity(pid, startIdentity, codeSignatureHash) {
  return { pid, start_identity: startIdentity, code_signature_hash: codeSignatureHash };
}

function wireProcess(value) {
  return {
    processIdentifier: value.pid,
    processStartIdentity: value.start_identity,
    codeSignatureHash: value.code_signature_hash,
  };
}

function wireTarget(value) {
  return {
    kind: 'window',
    processIdentifier: value.pid,
    processStartIdentity: value.start_identity,
    windowID: value.window_id,
    capturedBounds: [
      [value.bounds.x, value.bounds.y],
      [value.bounds.width, value.bounds.height],
    ],
    ...(value.is_minimized === null ? {} : { isMinimized: value.is_minimized }),
  };
}

function normalizedOutcome(dispatchedUnitCount) {
  return {
    state: 'confirmed_change',
    route: 'bridge',
    delivery_mechanism: 'process_targeted_events',
    delivery_mode: 'background',
    effect: 'confirmed',
    evidence: 'verified_change',
    dispatch_state: 'dispatched',
    dispatched_unit_count: dispatchedUnitCount,
    retry_safety: 'not_applicable',
    escalation: 'none',
    refusal_reason: null,
    mutation_dispatched: true,
    retry_safe: false,
    requires_fresh_observation: false,
  };
}

function wireOutcome(value) {
  return structuredClone(value);
}

function signedDocument(payload, privateKey) {
  return {
    payload,
    signature: sign(null, canonicalBytes(payload), privateKey).toString('base64'),
  };
}

function bundleBytes(bundle) {
  return Buffer.from(`${JSON.stringify(bundle, null, 2)}\n`, 'utf8');
}

function makeRequestAndResponse(
  template,
  index,
  outcome,
  requestBindingValue,
  target,
  protocolClickType = 'triple',
  protocolClickPoint = null,
) {
  if (template.operation === 'exactWindowTargetedTypeActions') {
    return {
      request: {
        projectedAction: {
          _0: {
            request: {
              exactWindowTargetedTypeActions: {
                _0: {
                  actions: [{ kind: 'text', text: `fixture-${index}` }],
                  cadence: { kind: 'fixed', milliseconds: 0 },
                  snapshotId: requestBindingValue,
                },
              },
            },
          },
        },
      },
      response: {
        projectedAction: {
          _0: {
            outcome: wireOutcome(outcome),
            response: {
              typeResult: {
                _0: { totalCharacters: 9 + index, keyPresses: 9 + index },
              },
            },
          },
        },
      },
      requestEnvelopeCase: 'projectedAction',
      requestCase: 'exactWindowTargetedTypeActions',
      responseEnvelopeCase: 'projectedAction',
      responseCase: 'typeResult',
    };
  }
  if (template.operation === 'exactWindowTargetedClick') {
    return {
      request: {
        projectedAction: {
          _0: {
            request: {
              targetedClick: {
                _0: {
                  target: { coordinates: { _0: [protocolClickPoint ?? [
                    target.bounds.x + target.bounds.width / 2,
                    target.bounds.y + target.bounds.height / 2,
                  ]] } },
                  clickType: protocolClickType,
                  snapshotId: requestBindingValue,
                  targetProcessIdentifier: target.pid,
                  expectedProcessIdentity: {
                    processIdentifier: target.pid,
                    processStartIdentity: Number(target.start_identity),
                  },
                  targetWindowID: target.window_id,
                  expectedWindowIdentity: {
                    windowID: target.window_id,
                    ownerProcessIdentifier: target.pid,
                    ownerProcessStartIdentity: Number(target.start_identity),
                    capturedBounds: [
                      [target.bounds.x, target.bounds.y],
                      [target.bounds.width, target.bounds.height],
                    ],
                    ...(target.is_minimized === null ? {} : { isMinimized: target.is_minimized }),
                  },
                  expectedWindowBounds: [
                    [target.bounds.x, target.bounds.y],
                    [target.bounds.width, target.bounds.height],
                  ],
                },
              },
            },
          },
        },
      },
      response: {
        projectedAction: {
          _0: {
            outcome: wireOutcome(outcome),
            response: { ok: {} },
          },
        },
      },
      requestEnvelopeCase: 'projectedAction',
      requestCase: 'targetedClick',
      responseEnvelopeCase: 'projectedAction',
      responseCase: 'ok',
    };
  }
  return {
    request: {
      desktopObservation: {
        _0: {
          target: { windowID: { _0: 1 } },
          output: { snapshotID: requestBindingValue },
          checkpoint: template.checkpoint,
        },
      },
    },
    response: {
      desktopObservation: {
        _0: { checkpoint: template.checkpoint, success: true },
      },
    },
    requestEnvelopeCase: 'desktopObservation',
    requestCase: 'desktopObservation',
    responseEnvelopeCase: 'desktopObservation',
    responseCase: 'desktopObservation',
  };
}

export function makeMultiTargetFixture(catalog, catalogFileSHA256, options = {}) {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const rawPublicKey = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32);
  const listenerPublicKeyBase64 = rawPublicKey.toString('base64');
  const listenerPublicKeySHA256 = sha256(rawPublicKey);
  const listenerInstanceID = randomUUID().toLowerCase();
  const host = processIdentity(9001, '900100', 'a'.repeat(40));
  const clientA = processIdentity(4101, '410100', 'd'.repeat(40));
  const clientB = processIdentity(4201, '420100', 'e'.repeat(40));
  const foregroundController = processIdentity(4301, '430100', 'f'.repeat(40));
  const semanticObserver = processIdentity(4401, '440100', 'b'.repeat(40));
  const targetA = {
    scope: 'window',
    pid: 5101,
    start_identity: '510100',
    window_id: 6101,
    bounds: { x: 10, y: 20, width: 640, height: 480 },
    is_minimized: null,
  };
  const targetB = {
    scope: 'window',
    pid: 5201,
    start_identity: '520100',
    window_id: 6201,
    bounds: { x: 700, y: 20, width: 640, height: 480 },
    is_minimized: false,
  };
  const foregroundTarget = {
    scope: 'window',
    pid: 5301,
    start_identity: '530100',
    window_id: 6301,
    bounds: { x: 1400, y: 20, width: 500, height: 700 },
    is_minimized: false,
  };
  const sentinel = {
    scope: 'window',
    pid: 5401,
    start_identity: '540100',
    window_id: 6401,
    bounds: { x: 20, y: 540, width: 700, height: 400 },
    is_minimized: false,
  };
  const executionNonce = '9'.repeat(64);
  const currentBuildCommit = options.currentBuildCommit ?? 'c'.repeat(40);
  const monitorInstanceID = randomUUID().toLowerCase();
  const monitorProcess = {
    pid: 8001,
    start_identity: '800100',
    executable_path: '/private/tmp/peekaboo-monitor-fixture',
    executable_sha256: '8'.repeat(64),
    code_signature_hash: '8'.repeat(40),
    team_id: catalog.trusted_monitor_team_ids[0],
    source_commit: catalog.monitor_source.commit,
    heartbeat_path: '/private/tmp/peekaboo-monitor-heartbeat.json',
  };
  const controlledTargets = [
    { id: 'target-a', controller_id: 'controller-a', controller: clientA, target: targetA },
    { id: 'target-b', controller_id: 'controller-b', controller: clientB, target: targetB },
  ];
  const targetByID = new Map(controlledTargets.map((entry) => [entry.id, entry]));
  const sessionByController = new Map([
    ['controller-a', {
      id: randomUUID().toLowerCase(),
      client_instance_id: randomUUID().toLowerCase(),
      client: clientA,
    }],
    ['controller-b', {
      id: randomUUID().toLowerCase(),
      client_instance_id: randomUUID().toLowerCase(),
      client: clientB,
    }],
  ]);
  const sessionIndex = new Map();
  const globalInterval = {
    started_at_milliseconds: 1_900_000_000_000,
    completed_at_milliseconds: 1_900_000_020_000,
  };
  const listener = {
    instance_id: listenerInstanceID,
    public_key_base64: listenerPublicKeyBase64,
    public_key_sha256: listenerPublicKeySHA256,
    host,
    source_commit: currentBuildCommit,
    created_at_milliseconds: globalInterval.started_at_milliseconds - 1000,
    receipt_archive_directory: `/private/tmp/receipts/${listenerInstanceID}`,
  };
  const operationSlots = [];
  const bundleRecords = [];

  const listenerUnsigned = {
    schemaVersion: 1,
    listenerInstanceID: listenerInstanceID.toUpperCase(),
    publicKey: listenerPublicKeyBase64,
    host: wireProcess(host),
    createdAtUnixMilliseconds: globalInterval.started_at_milliseconds - 1000,
    receiptArchiveDirectory: `/private/tmp/receipts/${listenerInstanceID}`,
  };
  const listenerDocument = {
    ...listenerUnsigned,
    signature: sign(null, canonicalBytes(listenerUnsigned), privateKey).toString('base64'),
  };

  catalog.slots.forEach((template, index) => {
    const owner = targetByID.get(template.target_id);
    const sessionSeed = sessionByController.get(template.controller_id);
    const ordinal = sessionIndex.get(template.controller_id) ?? 0;
    const sequence = options.gapControllerASession === true
      && template.controller_id === 'controller-a' && ordinal > 0
      ? ordinal + 1
      : ordinal;
    sessionIndex.set(template.controller_id, ordinal + 1);
    const sequenceText = String(sequence);
    const requestID = deterministicRequestID(sessionSeed.id, sequenceText);
    const outcome = template.kind === 'operation'
      ? normalizedOutcome(template.operation === 'exactWindowTargetedClick'
        ? 7
        : (template.controller_id === 'controller-a' ? 11 : 13))
      : null;
    const requestBindingValue = `peekaboo-certification-run:${executionNonce}:slot:${template.slot_id}`;
    const wire = makeRequestAndResponse(
      template,
      index,
      outcome,
      requestBindingValue,
      owner.target,
      options.protocolClickType,
      options.protocolClickPoint,
    );
    const requestBytes = canonicalBytes(wire.request);
    const responseBytes = canonicalBytes(wire.response);
    const interval = index < 2 ? {
      started_at_milliseconds: globalInterval.started_at_milliseconds + 1000,
      completed_at_milliseconds: globalInterval.started_at_milliseconds + 5000,
    } : {
      started_at_milliseconds: globalInterval.started_at_milliseconds + 5200 + (index - 2) * 400,
      completed_at_milliseconds: globalInterval.started_at_milliseconds + 5450 + (index - 2) * 400,
    };
    const slot = {
      slot_id: template.slot_id,
      operation_id: `pending:${template.slot_id}`,
      kind: template.kind,
      checkpoint: template.checkpoint,
      controller_id: template.controller_id,
      target_id: template.target_id,
      controller: structuredClone(owner.controller),
      client: structuredClone(sessionSeed.client),
      request_id: requestID,
      session: {
        id: sessionSeed.id,
        sequence: sequenceText,
        predecessor_id: null,
        client_instance_id: sessionSeed.client_instance_id,
      },
      operation: template.operation,
      request_binding: {
        path: structuredClone(template.request_binding_path),
        value: requestBindingValue,
      },
      request_envelope_case: wire.requestEnvelopeCase,
      request_case: wire.requestCase,
      response_envelope_case: wire.responseEnvelopeCase,
      response_case: wire.responseCase,
      request_sha256: sha256(requestBytes),
      response_sha256: sha256(responseBytes),
      target: structuredClone(owner.target),
      focused_element: null,
      selected_leaf_evidence: null,
      interval,
      source: {
        protocol_source_commit: catalog.protocol_source.commit,
        host_source_commit: listener.source_commit,
        listener_instance_id: listenerInstanceID,
        host: structuredClone(host),
      },
      expected_outcome: outcome,
    };
    const sessionUnsigned = {
      schemaVersion: 1,
      sessionID: sessionSeed.id.toUpperCase(),
      listenerInstanceID: listenerInstanceID.toUpperCase(),
      listenerPublicKeySHA256: listenerPublicKeySHA256,
      clientInstanceID: sessionSeed.client_instance_id.toUpperCase(),
      client: wireProcess(sessionSeed.client),
      maximumRequestCount: 16384,
      remainingClaimCount: 16384,
      createdAtUnixMilliseconds: globalInterval.started_at_milliseconds - 500,
    };
    const sessionDocument = {
      ...sessionUnsigned,
      signature: sign(null, canonicalBytes(sessionUnsigned), privateKey).toString('base64'),
    };
    slot.session.attestation_sha256 = sha256(canonicalBytes(sessionDocument));
    slot.session.listener_instance_id = listenerInstanceID;
    slot.session.listener_public_key_sha256 = listenerPublicKeySHA256;
    operationSlots.push(slot);
    const receiptPayload = {
      schemaVersion: 1,
      requestID: requestID.toUpperCase(),
      sessionID: sessionSeed.id.toUpperCase(),
      sessionSequence: sequenceText,
      sessionAttestationSHA256: slot.session.attestation_sha256,
      listenerInstanceID: listenerInstanceID.toUpperCase(),
      listenerPublicKeySHA256: listenerPublicKeySHA256,
      clientInstanceID: sessionSeed.client_instance_id.toUpperCase(),
      host: wireProcess(host),
      client: wireProcess(sessionSeed.client),
      operation: template.operation,
      requestSHA256: slot.request_sha256,
      responseSHA256: slot.response_sha256,
      target: wireTarget(owner.target),
      ...(outcome === null ? {} : { outcome: wireOutcome(outcome) }),
      remainingClaimCount: 16383 - sequence,
      startedAtUnixMilliseconds: interval.started_at_milliseconds,
      completedAtUnixMilliseconds: interval.completed_at_milliseconds,
    };
    const receiptDocument = signedDocument(receiptPayload, privateKey);
    const bundle = {
      operationAttestation: listenerDocument,
      operationSessionAttestation: sessionDocument,
      receipt: receiptDocument,
      canonicalListenerAttestationPayload: canonicalBytes(listenerUnsigned).toString('base64'),
      canonicalSessionAttestationPayload: canonicalBytes(sessionUnsigned).toString('base64'),
      canonicalReceiptPayload: canonicalBytes(receiptPayload).toString('base64'),
      canonicalRequest: requestBytes.toString('base64'),
      canonicalResponse: responseBytes.toString('base64'),
    };
    const bytes = bundleBytes(bundle);
    bundleRecords.push({
      file: `${requestID}.json`,
      sha256: sha256(bytes),
      bytes,
      document: bundle,
    });
  });

  const exactInterval = {
    started_at_milliseconds: globalInterval.started_at_milliseconds,
    completed_at_milliseconds: globalInterval.started_at_milliseconds + 8000,
  };
  const monitorBinding = {
    version: 1,
    monitor_instance_id: monitorInstanceID,
    execution_nonce: executionNonce,
    monitor_source_commit: catalog.monitor_source.commit,
    monitor_source_sha256: catalog.monitor_source.probe_sha256,
    coordinator_runtime_commit: currentBuildCommit,
    coordinator_source_sha256: catalog.current_build_source.coordinator.sha256,
    monitor_process: monitorProcess,
    monitor_attestation_socket_path: '/private/tmp/peekaboo-monitor-attestation.sock',
    sentinel,
    foreground_controller: foregroundController,
    foreground_target: foregroundTarget,
    revisions: { baseline: 1, grant: 2, revoke: 3 },
  };
  const controllerBuild = {
    source_commit: currentBuildCommit,
    executable_path: '/private/tmp/peekaboo-certification-controller',
    executable_sha256: '6'.repeat(64),
    team_id: catalog.trusted_controller_team_ids[0],
  };
  const runID = deriveCertificationRunID({
    catalogSHA256: catalogFileSHA256,
    listenerInstanceID,
    executionNonce,
    currentBuildSource: { commit: currentBuildCommit },
    monitorBinding,
    controllerBuild,
    operationSlots,
  });
  operationSlots.forEach((slot) => {
    slot.operation_id = `${runID}:${slot.slot_id}`;
  });
  const contract = {
    version: 4,
    certification_kind: 'live-physical',
    claim_scope: 'multi-target-background-with-attributed-foreground-overlap',
    execution_nonce: executionNonce,
    catalog_sha256: catalogFileSHA256,
    certification_run_id: runID,
    protocol: {
      host_handshake: structuredClone(catalog.protocol.host_handshake),
      receipt_protocol_floor: structuredClone(catalog.protocol.receipt_protocol_floor),
    },
    source: structuredClone(catalog.protocol_source),
    current_build_source: { commit: currentBuildCommit },
    first_party_validator: {
      id: 'peekaboo-bridge-receipt-validate-v1',
      source_commit: currentBuildCommit,
      executable_sha256: 'f'.repeat(64),
      code_signature_hash: '1'.repeat(40),
      team_id: catalog.trusted_first_party_validator_team_ids[0],
      runtime_libraries: [],
      trusted_host_team_ids: [catalog.trusted_bridge_host_team_ids[0]],
    },
    listener,
    socket_endpoint: {
      path: '/private/tmp/peekaboo-multi-target-fixture.sock',
      device: '42',
      inode: '84',
    },
    interval: exactInterval,
    monitor_binding: monitorBinding,
    controller_build: controllerBuild,
    controlled_targets: controlledTargets,
    operation_slots: operationSlots,
  };
  const contractSHA256 = canonicalSHA256(contract);
  const manifest = {
    version: 1,
    catalog_sha256: catalogFileSHA256,
    contract_sha256: contractSHA256,
    slots: operationSlots.map((slot, index) => ({
      slot_id: slot.slot_id,
      operation_id: slot.operation_id,
      bundle_file: bundleRecords[index].file,
      bundle_sha256: bundleRecords[index].sha256,
      controller_id: slot.controller_id,
      target_id: slot.target_id,
      client: structuredClone(slot.client),
      request_id: slot.request_id,
      session_id: slot.session.id,
      session_sequence: slot.session.sequence,
      session_attestation_sha256: slot.session.attestation_sha256,
      predecessor_session_id: slot.session.predecessor_id,
      client_instance_id: slot.session.client_instance_id,
      operation: slot.operation,
      request_binding: structuredClone(slot.request_binding),
      request_sha256: slot.request_sha256,
      response_sha256: slot.response_sha256,
    })),
  };
  const manifestSHA256 = aggregateSHA256('operation-manifest', manifest);
  const firstPartyVerdicts = operationSlots.map((slot, index) => ({
      slot_id: slot.slot_id,
      bundle_file: bundleRecords[index].file,
      file_sha256: bundleRecords[index].sha256,
      verdict: {
        valid: true,
        validator_id: 'peekaboo-bridge-receipt-validate-v1',
        trust_source: 'authenticated_live_listener',
        minimum_protocol_version: '1.29',
        host_protocol_version: '1.30',
        request_id: slot.request_id,
        session_id: slot.session.id,
        session_sequence: slot.session.sequence,
        predecessor_session_id: slot.session.predecessor_id,
        operation: slot.operation,
        listener_instance_id: listenerInstanceID,
        listener_public_key_sha256: listenerPublicKeySHA256,
        host: structuredClone(host),
        host_source_commit: currentBuildCommit,
        client_instance_id: slot.session.client_instance_id,
        client: structuredClone(slot.client),
        request_sha256: slot.request_sha256,
        response_sha256: slot.response_sha256,
        bundle_sha256: bundleRecords[index].sha256,
        terminal_receipt_attested: true,
        target_attested: true,
        outcome_attested: slot.expected_outcome !== null,
        retention_basis: 'exported_bundle',
      },
    }));
  const baselineProducers = [
    { pid: host.pid, startIdentity: host.start_identity, role: 'bridge' },
    { pid: clientA.pid, startIdentity: clientA.start_identity, role: 'bridge' },
    { pid: clientB.pid, startIdentity: clientB.start_identity, role: 'bridge' },
  ];
  const foregroundProducer = {
    pid: foregroundController.pid,
    startIdentity: foregroundController.start_identity,
    role: 'foreground-controller',
  };
  const producerSet = (revision, foreground) => ({
    revision,
    executionNonce,
    monitorInstanceID,
    producers: foreground ? [...baselineProducers, foregroundProducer] : baselineProducers,
    foreground: {
      active: foreground,
      target: foreground ? {
        pid: foregroundTarget.pid,
        startIdentity: foregroundTarget.start_identity,
        windowID: foregroundTarget.window_id,
      } : null,
    },
  });
  const heartbeat = ({
    sequence,
    offsetMilliseconds,
    revision,
    authorizationEpoch,
    foreground,
    activityCount = 0,
  }) => ({
    sequence,
    monotonicMicroseconds: 10_000_000 + offsetMilliseconds * 1000,
    wallClockMilliseconds: globalInterval.started_at_milliseconds + offsetMilliseconds,
    lastCleanSequence: sequence,
    contaminationRetries: 0,
    contaminationBlocked: false,
    inputAttributionAvailable: true,
    allowedProducerRevision: revision,
    phase: 'running',
    cursorMovementObserved: false,
    pendingActivationCount: 0,
    pendingFocusedWindowChange: false,
    authorizationEpoch,
    transitionAcknowledged: false,
    foregroundActive: foreground,
    foregroundTargetPID: foreground ? foregroundTarget.pid : null,
    foregroundTargetWindowID: foreground ? foregroundTarget.window_id : null,
    attributedForegroundEventCount: activityCount,
    attributedForegroundSourcePIDs: activityCount > 0 ? [foregroundController.pid] : [],
    foregroundActivityObserved: activityCount > 0,
    executionNonce,
    monitorInstanceID,
    historyCommitmentSHA256: '0'.repeat(64),
  });
  const monitorEvidence = {
    version: 1,
    execution_nonce: executionNonce,
    monitor_instance_id: monitorInstanceID,
    monitor_source_sha256: catalog.monitor_source.probe_sha256,
    coordinator_source_sha256: catalog.current_build_source.coordinator.sha256,
    monitor_process: structuredClone(monitorProcess),
    monitor_attestation_socket_path: '/private/tmp/peekaboo-monitor-attestation.sock',
    sentinel: structuredClone(sentinel),
    foreground_controller: structuredClone(foregroundController),
    foreground_target: structuredClone(foregroundTarget),
    baseline_commitment_sha256: '0'.repeat(64),
    history_commitment_sha256: '0'.repeat(64),
    producer_sets: {
      baseline: producerSet(1, false),
      grant: producerSet(2, true),
      revoke: producerSet(3, false),
    },
    fences: [
      ['baseline-stable', heartbeat({
        sequence: 1, offsetMilliseconds: 0, revision: 1, authorizationEpoch: 1, foreground: false,
      })],
      ['grant-stable', heartbeat({
        sequence: 2, offsetMilliseconds: 500, revision: 2, authorizationEpoch: 2, foreground: true,
      })],
      ['operations-start', heartbeat({
        sequence: 3, offsetMilliseconds: 1500, revision: 2, authorizationEpoch: 3, foreground: true,
      })],
      ['operations-complete', heartbeat({
        sequence: 4,
        offsetMilliseconds: 2500,
        revision: 2,
        authorizationEpoch: 4,
        foreground: true,
        activityCount: 3,
      })],
      ['revoke-stable', heartbeat({
        sequence: 5, offsetMilliseconds: 6500, revision: 3, authorizationEpoch: 5, foreground: false,
      })],
      ['final-stable', heartbeat({
        sequence: 6, offsetMilliseconds: 8000, revision: 3, authorizationEpoch: 6, foreground: false,
      })],
    ].map(([name, value]) => ({ name, heartbeat: value })),
    baseline_sample: {
      frontmost_pid: sentinel.pid,
      frontmost_window_id: sentinel.window_id,
      clipboard_change_count: 7,
      clipboard_digest: '7'.repeat(64),
    },
    final_sample: {
      frontmost_pid: sentinel.pid,
      frontmost_window_id: sentinel.window_id,
      clipboard_change_count: 7,
      clipboard_digest: '7'.repeat(64),
    },
    foreground_plan: {
      request_marker: `peekaboo-foreground-postcondition:${executionNonce}`,
      expected_value_sha256: sha256(Buffer.from(
        `peekaboo-foreground-postcondition:${executionNonce}`,
        'utf8',
      )),
      baseline_value_sha256: '1'.repeat(64),
      observer: structuredClone(semanticObserver),
      observer_build: structuredClone(controllerBuild),
      semantic_element: {
        role: 'AXTextArea',
        identifier: 'foreground-certification-field',
        title: null,
      },
      observation_path: '/private/tmp/peekaboo-foreground-observation.json',
      restoration_path: '/private/tmp/peekaboo-foreground-restoration.json',
      witness_path: '/private/tmp/peekaboo-foreground-witness.json',
      observer_attestation_socket_path: '/private/tmp/peekaboo-observer-attestation.sock',
    },
    violation_records: [],
    contamination_records: [],
    crash_evidence: {
      version: 1,
      directory: '/Users/fixture/Library/Logs/DiagnosticReports',
      prefixes: structuredClone(catalog.monitor_contract.crash_report_prefixes),
      baseline: [],
      final: [],
      new_reports: [],
    },
    restoration: {
      background_final_bounds_slot_ids: [
        'controller-a-final-bounds',
        'controller-b-final-bounds',
      ],
      foreground_postcondition_sha256: '0'.repeat(64),
      sentinel_sample_sha256: '0'.repeat(64),
    },
  };
  const foregroundPostcondition = {
    version: 1,
    execution_nonce: executionNonce,
    target: structuredClone(foregroundTarget),
    observer: structuredClone(semanticObserver),
    focused_element: {
      role: monitorEvidence.foreground_plan.semantic_element.role,
      identifier: monitorEvidence.foreground_plan.semantic_element.identifier,
      title: monitorEvidence.foreground_plan.semantic_element.title,
      frame: { x: 1450, y: 100, width: 300, height: 300 },
    },
    interval: {
      started_at_milliseconds: globalInterval.started_at_milliseconds + 1700,
      completed_at_milliseconds: globalInterval.started_at_milliseconds + 2300,
    },
    request_marker: `peekaboo-foreground-postcondition:${executionNonce}`,
    before_value_sha256: '1'.repeat(64),
    expected_value_sha256: monitorEvidence.foreground_plan.expected_value_sha256,
    observed_value_sha256: monitorEvidence.foreground_plan.expected_value_sha256,
    restored_value_sha256: '1'.repeat(64),
    observation_path: monitorEvidence.foreground_plan.observation_path,
    observation_file_sha256: '3'.repeat(64),
    restoration_path: monitorEvidence.foreground_plan.restoration_path,
    restoration_file_sha256: '4'.repeat(64),
    passed: true,
    restored: true,
  };
  monitorEvidence.restoration.foreground_postcondition_sha256 = aggregateSHA256(
    'foreground-postcondition',
    foregroundPostcondition,
  );
  monitorEvidence.restoration.sentinel_sample_sha256 = aggregateSHA256(
    'monitor-sample',
    monitorEvidence.final_sample,
  );
  monitorEvidence.baseline_commitment_sha256 = monitorBaselineCommitmentSHA256(monitorEvidence);
  monitorEvidence.fences[0].heartbeat.historyCommitmentSHA256 =
    monitorEvidence.baseline_commitment_sha256;
  monitorEvidence.history_commitment_sha256 = monitorHistoryCommitmentSHA256(monitorEvidence);
  monitorEvidence.fences.at(-1).heartbeat.historyCommitmentSHA256 =
    monitorEvidence.history_commitment_sha256;
  const evidence = {
    version: 2,
    certification_kind: 'live-physical',
    execution_nonce: executionNonce,
    catalog_sha256: catalogFileSHA256,
    contract_sha256: contractSHA256,
    operation_manifest_sha256: manifestSHA256,
    first_party_validator_executable_sha256: 'f'.repeat(64),
    socket_evidence: {
      path: contract.socket_endpoint.path,
      device: contract.socket_endpoint.device,
      inode: contract.socket_endpoint.inode,
      is_socket: true,
      is_symbolic_link: false,
    },
    source_evidence: structuredClone(contract.source),
    monitor_evidence: monitorEvidence,
    foreground_postcondition: foregroundPostcondition,
  };
  return { contract, manifest, evidence, bundles: bundleRecords, firstPartyVerdicts };
}

export function rehashFixture(fixture, catalogFileSHA256) {
  fixture.contract.catalog_sha256 = catalogFileSHA256;
  const contractSHA256 = canonicalSHA256(fixture.contract);
  fixture.manifest.catalog_sha256 = catalogFileSHA256;
  fixture.manifest.contract_sha256 = contractSHA256;
  const manifestSHA256 = aggregateSHA256('operation-manifest', fixture.manifest);
  fixture.evidence.catalog_sha256 = catalogFileSHA256;
  fixture.evidence.contract_sha256 = contractSHA256;
  fixture.evidence.operation_manifest_sha256 = manifestSHA256;
  return fixture;
}

export function makeControllerReceipts(fixture) {
  return fixture.contract.controlled_targets.map((controlledTarget) => {
    const slots = fixture.contract.operation_slots.filter((slot) => (
      slot.controller_id === controlledTarget.controller_id
    ));
    const firstSession = slots[0].session;
    return {
      version: 1,
      result: 'passed',
      execution_nonce: fixture.contract.execution_nonce,
      monitor_instance_id: fixture.contract.monitor_binding.monitor_instance_id,
      controller_id: controlledTarget.controller_id,
      target_id: controlledTarget.id,
      controller: structuredClone(controlledTarget.controller),
      build: structuredClone(fixture.contract.controller_build),
      handshake: {
        socket_path: fixture.contract.socket_endpoint.path,
        negotiated_version: structuredClone(fixture.contract.protocol.host_handshake),
        host_kind: 'gui',
        build: 'fixture',
        listener_instance_id: fixture.contract.listener.instance_id,
        host: {
          process: structuredClone(fixture.contract.listener.host),
          bundle_identifier: 'boo.peekaboo.mac',
          bundle_short_version: '4.2.1',
          bundle_version: '1',
          source_commit: fixture.contract.listener.source_commit,
        },
        session: {
          id: firstSession.id,
          client_instance_id: firstSession.client_instance_id,
          maximum_request_count: 16384,
          initial_remaining_claim_count: 16384,
        },
      },
      target: structuredClone(controlledTarget.target),
      interval: {
        started_at_milliseconds: Math.min(...slots.map((slot) => slot.interval.started_at_milliseconds)),
        completed_at_milliseconds: Math.max(...slots.map((slot) => slot.interval.completed_at_milliseconds)),
      },
      slots: slots.map((slot) => {
        const bundle = fixture.bundles.find((entry) => entry.file === `${slot.request_id}.json`);
        return {
          slot_id: slot.slot_id,
          kind: slot.kind,
          operation: slot.operation,
          checkpoint: slot.checkpoint,
          marker: slot.request_binding.value,
          request_id: slot.request_id,
          session_id: slot.session.id,
          session_sequence: slot.session.sequence,
          listener_instance_id: slot.session.listener_instance_id,
          target: structuredClone(slot.target),
          interval: structuredClone(slot.interval),
          controller_interval: structuredClone(slot.interval),
          outcome: structuredClone(slot.expected_outcome),
          result: { status: 'passed' },
          bundle: {
            file: `bundles/${bundle.file}`,
            sha256: bundle.sha256,
            request_sha256: slot.request_sha256,
            response_sha256: slot.response_sha256,
          },
        };
      }),
    };
  });
}

export function writeFixtureArtifact(fixture, directory) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  fs.chmodSync(directory, 0o700);
  const bundlesDirectory = path.join(directory, 'bundles');
  fs.mkdirSync(bundlesDirectory, { mode: 0o700 });
  const writeJSON = (name, value) => {
    const filePath = path.join(directory, name);
    fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
    fs.chmodSync(filePath, 0o600);
  };
  writeJSON('contract.json', fixture.contract);
  writeJSON('operation-manifest.json', fixture.manifest);
  writeJSON('raw-evidence.json', fixture.evidence);
  for (const bundle of fixture.bundles) {
    const filePath = path.join(bundlesDirectory, bundle.file);
    fs.writeFileSync(filePath, bundle.bytes, { mode: 0o600 });
    fs.chmodSync(filePath, 0o600);
  }
}
