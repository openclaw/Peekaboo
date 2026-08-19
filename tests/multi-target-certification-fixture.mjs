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

function wireBounds(value) {
  return [
    [value.bounds.x, value.bounds.y],
    [value.bounds.width, value.bounds.height],
  ];
}

const rawUInt64Prefix = '__peekaboo_raw_uint64_';
const rawUInt64Suffix = '__';

function wireUInt64(value, { quoted = false } = {}) {
  if (typeof value === 'number' && !Number.isSafeInteger(value)) {
    throw new TypeError('UInt64 fixture values above 2^53 must be provided as decimal strings');
  }
  const decimal = String(value);
  const parsed = BigInt(decimal);
  if (parsed < 0n || parsed > 18_446_744_073_709_551_615n || parsed.toString() !== decimal) {
    throw new TypeError('UInt64 fixture value is not one normalized decimal');
  }
  if (quoted) return decimal;
  return parsed <= BigInt(Number.MAX_SAFE_INTEGER)
    ? Number(parsed)
    : `${rawUInt64Prefix}${decimal}${rawUInt64Suffix}`;
}

function canonicalWireBytes(value) {
  const json = canonicalBytes(value).toString('utf8').replaceAll(
    new RegExp(`"${rawUInt64Prefix}(\\d+)${rawUInt64Suffix}"`, 'g'),
    '$1',
  );
  return Buffer.from(json, 'utf8');
}

function wireWindowIdentity(value, overrides = {}) {
  const minimized = Object.hasOwn(overrides, 'isMinimized')
    ? overrides.isMinimized
    : value.is_minimized;
  return {
    windowID: overrides.windowID ?? value.window_id,
    ownerProcessIdentifier: overrides.ownerProcessIdentifier ?? value.pid,
    ownerProcessStartIdentity: wireUInt64(
      overrides.ownerProcessStartIdentity ?? value.start_identity,
      { quoted: overrides.quoteOwnerProcessStartIdentity === true },
    ),
    capturedBounds: overrides.capturedBounds ?? wireBounds(value),
    ...(minimized === null ? {} : { isMinimized: minimized }),
  };
}

const graphemeSegmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });

function graphemeCount(value) {
  return Array.from(graphemeSegmenter.segment(value)).length;
}

function observationPath(template) {
  return `/private/tmp/peekaboo-certification-fixture/observations/${template.slot_id}.png`;
}

function wireObservationResponse(template, target, options) {
  const filePath = observationPath(template);
  const windowID = options.desktopObservationResponseWindowIDOverride ?? target.window_id;
  const bounds = wireBounds(target);
  const captureDigest = sha256(Buffer.from(`fixture-observation:${template.slot_id}`, 'utf8'));
  const rawDigest = options.desktopObservationDigestDrift === true
    ? 'f'.repeat(64)
    : captureDigest;
  const responseStartIdentity = options.desktopObservationResponseStartIdentityOverride
    ?? target.start_identity;
  const mutationIdentity = wireWindowIdentity(target, {
    windowID,
    ownerProcessStartIdentity: responseStartIdentity,
    quoteOwnerProcessStartIdentity:
      options.desktopObservationResponseStartIdentityAsString === true,
  });
  const metadataBounds = options.desktopObservationMetadataBoundsOverride ?? bounds;
  const metadataSize = options.desktopObservationMetadataSizeOverride
    ?? [
      Math.max(Math.trunc(target.bounds.width), 1),
      Math.max(Math.trunc(target.bounds.height), 1),
    ];
  const metadataMinimized = options.desktopObservationMetadataMinimizedOverride
    ?? target.is_minimized
    ?? false;
  return {
    desktopObservation: {
      _0: {
        target: {
          kind: { windowID: { _0: windowID } },
          app: {
            processIdentifier: target.pid,
            processStartIdentity: wireUInt64(responseStartIdentity, {
              quoted: options.desktopObservationResponseStartIdentityAsString === true,
            }),
            name: `Fixture Target ${target.pid}`,
          },
          window: {
            windowID,
            title: `Fixture Window ${windowID}`,
            bounds,
            index: 0,
          },
          bounds,
        },
        capture: {
          imageData: '',
          metadata: {
            size: metadataSize,
            mode: 'window',
            windowInfo: {
              window_id: windowID,
              title: `Fixture Window ${windowID}`,
              bounds: metadataBounds,
              isMinimized: metadataMinimized,
              isMainWindow: true,
              windowLevel: 0,
              alpha: 1,
              index: 0,
              isOffScreen: false,
              layer: 0,
              isOnScreen: true,
              isExcludedFromWindowsMenu: false,
              mutationIdentity,
            },
            timestamp: '2030-03-17T00:00:00Z',
          },
        },
        files: { rawScreenshotPath: filePath },
        timings: { spans: [] },
        diagnostics: { warnings: [] },
        captureContentDigest: {
          captureImageSHA256: captureDigest,
          rawScreenshotSHA256: rawDigest,
        },
      },
    },
  };
}

function wireTarget(value) {
  return {
    kind: 'window',
    processIdentifier: value.pid,
    processStartIdentity: value.start_identity,
    windowID: value.window_id,
    capturedBounds: wireBounds(value),
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
  options,
) {
  if (template.operation === 'exactWindowTargetedTypeActions') {
    const text = options.typeTextOverride ?? `fixture-${index}`;
    const resultCount = graphemeCount(text) + (options.typeResultCountDelta ?? 0);
    const expectedBounds = options.exactWindowTypeBoundsOverride ?? wireBounds(target);
    const identityOverrides = {
      ...(options.exactWindowTypeWindowIDOverride === undefined ? {} : {
        windowID: options.exactWindowTypeWindowIDOverride,
      }),
      ...(options.exactWindowTypePIDOverride === undefined ? {} : {
        ownerProcessIdentifier: options.exactWindowTypePIDOverride,
      }),
      ...(options.exactWindowTypeStartIdentityOverride === undefined ? {} : {
        ownerProcessStartIdentity: options.exactWindowTypeStartIdentityOverride,
      }),
      ...(options.exactWindowTypeStartIdentityAsString !== true ? {} : {
        quoteOwnerProcessStartIdentity: true,
      }),
      ...(options.exactWindowTypeBoundsOverride === undefined ? {} : {
        capturedBounds: options.exactWindowTypeBoundsOverride,
      }),
      ...(options.exactWindowTypeMinimizedOverride === undefined ? {} : {
        isMinimized: options.exactWindowTypeMinimizedOverride,
      }),
    };
    return {
      request: {
        projectedAction: {
          _0: {
            request: {
              exactWindowTargetedTypeActions: {
                _0: {
                  actions: [{ kind: 'text', text }],
                  cadence: { kind: 'fixed', milliseconds: 0 },
                  snapshotId: requestBindingValue,
                  expectedWindowIdentity: wireWindowIdentity(target, identityOverrides),
                  expectedWindowBounds: expectedBounds,
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
                _0: { totalCharacters: resultCount, keyPresses: resultCount },
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
                  target: { coordinates: { _0: [options.protocolClickPoint ?? [
                    target.bounds.x + target.bounds.width / 2,
                    target.bounds.y + target.bounds.height / 2,
                  ]] } },
                  clickType: options.protocolClickType ?? 'triple',
                  snapshotId: requestBindingValue,
                  targetProcessIdentifier: target.pid,
                  expectedProcessIdentity: {
                    processIdentifier: target.pid,
                    processStartIdentity: wireUInt64(
                      options.protocolClickStartIdentityOverride ?? target.start_identity,
                      { quoted: options.protocolClickStartIdentityAsString === true },
                    ),
                  },
                  targetWindowID: target.window_id,
                  expectedWindowIdentity: wireWindowIdentity(
                    target,
                    {
                      ...(options.protocolClickStartIdentityOverride === undefined ? {} : {
                        ownerProcessStartIdentity: options.protocolClickStartIdentityOverride,
                      }),
                      ...(options.protocolClickStartIdentityAsString !== true ? {} : {
                        quoteOwnerProcessStartIdentity: true,
                      }),
                      ...(options.protocolClickMinimizedOverride === undefined ? {} : {
                        isMinimized: options.protocolClickMinimizedOverride,
                      }),
                    },
                  ),
                  expectedWindowBounds: wireBounds(target),
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
  const filePath = observationPath(template);
  return {
    request: {
      desktopObservation: {
        _0: {
          target: {
            windowID: {
              _0: options.desktopObservationWindowIDOverride ?? target.window_id,
            },
          },
          capture: {
            engine: 'auto',
            scale: { logical1x: {} },
            focus: options.desktopObservationFocusOverride ?? 'background',
            visualizerMode: { none: {} },
            includeMenuBar: false,
          },
          detection: {
            mode: { none: {} },
            allowWebFocusFallback: false,
            includeMenuBarElements: false,
            preferOCR: false,
            traversalBudget: {
              maxDepth: 12,
              maxElementCount: 1000,
              maxChildrenPerNode: 250,
            },
          },
          output: {
            path: filePath,
            format: 'png',
            saveRawScreenshot: true,
            saveAnnotatedScreenshot: false,
            saveSnapshot: false,
            snapshotID: requestBindingValue,
          },
          timeout: { overall: 30 },
        },
      },
    },
    response: wireObservationResponse(template, target, options),
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
  const targetABounds = options.fractionalBounds
    ? { x: 10.25, y: 20.5, width: 640.75, height: 480.125 }
    : { x: 10, y: 20, width: 640, height: 480 };
  const targetA = {
    scope: 'window',
    pid: 5101,
    start_identity: options.targetStartIdentityOverride ?? '510100',
    window_id: 6101,
    bounds: targetABounds,
    is_minimized: null,
  };
  const targetB = {
    scope: 'window',
    pid: 5201,
    start_identity: options.targetStartIdentityOverride ?? '520100',
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
      options,
    );
    const attestedRequestID = options.mismatchAttestedRequestID === true
      ? deterministicRequestID(sessionSeed.id, String(sequence + 100))
      : requestID;
    wire.request = {
      attestedOperation: {
        _0: {
          requestID: attestedRequestID.toUpperCase(),
          sessionID: sessionSeed.id.toUpperCase(),
          sessionSequence: sequenceText,
          expectedListenerInstanceID: listenerInstanceID.toUpperCase(),
          clientInstanceID: sessionSeed.client_instance_id.toUpperCase(),
          client: wireProcess(sessionSeed.client),
          request: wire.request,
        },
      },
    };
    wire.requestEnvelopeCase = 'attestedOperation';
    const requestBytes = canonicalWireBytes(wire.request);
    const responseBytes = canonicalWireBytes(wire.response);
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
        host_protocol_version: '1.31',
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

function controllerResultForSlot(slot, bundle) {
  const response = JSON.parse(Buffer.from(bundle.document.canonicalResponse, 'base64'));
  const result = {
    status: 'passed',
    total_characters: null,
    key_presses: null,
    observation_file: null,
    observation_sha256: null,
    observed_bounds: null,
  };
  if (slot.operation === 'exactWindowTargetedTypeActions') {
    const counts = response.projectedAction._0.response.typeResult._0;
    result.total_characters = counts.totalCharacters;
    result.key_presses = counts.keyPresses;
  } else if (slot.operation === 'desktopObservation') {
    const observation = response.desktopObservation._0;
    result.observation_file = `observations/${slot.slot_id}.png`;
    result.observation_sha256 = observation.captureContentDigest.rawScreenshotSHA256;
    result.observed_bounds = structuredClone(slot.target.bounds);
  }
  return result;
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
          result: controllerResultForSlot(slot, bundle),
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
