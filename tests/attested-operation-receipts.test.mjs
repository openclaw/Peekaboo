import assert from 'node:assert/strict';
import {
  createPrivateKey,
  createPublicKey,
  createHash,
  sign,
} from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import * as adapter from '../scripts/receipt-adapters/canonical-attested-operation-receipts-v1.mjs';
import * as bridgeBundleAdapter from '../scripts/receipt-adapters/peekaboo-bridge-operation-receipt-bundle-1-29.mjs';
import {
  canonicalBytes,
  deterministicRequestID,
  validateAttestedOperationReceipts,
} from '../scripts/validate-attested-operation-receipts.mjs';

const PRIVATE_KEY_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');
const PRIVATE_KEY_SEED = Buffer.from('67'.repeat(32), 'hex');
const privateKey = createPrivateKey({
  key: Buffer.concat([PRIVATE_KEY_PREFIX, PRIVATE_KEY_SEED]),
  format: 'der',
  type: 'pkcs8',
});
const publicKeyDER = createPublicKey(privateKey).export({ format: 'der', type: 'spki' });
const publicKey = publicKeyDER.subarray(-32);
const testsDirectory = path.dirname(fileURLToPath(import.meta.url));
const canonicalAdapterPath = path.join(
  testsDirectory,
  '../scripts/receipt-adapters/canonical-attested-operation-receipts-v1.mjs',
);
const bridgeBundleAdapterPath = path.join(
  testsDirectory,
  '../scripts/receipt-adapters/peekaboo-bridge-operation-receipt-bundle-1-29.mjs',
);

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

function signature(value) {
  return {
    algorithm: 'ed25519',
    value: sign(null, canonicalBytes(value), privateKey).toString('base64'),
  };
}

function target(pid, startIdentity, windowID, x) {
  return {
    scope: 'window',
    pid,
    processStartIdentity: startIdentity,
    windowID,
    bounds: { x, y: 20, width: 480, height: 320 },
  };
}

function focusedElement(pid, windowID) {
  return {
    pid,
    windowID,
    role: 'AXTextField',
    title: 'Fixture editor',
    identifier: 'fixture-editor',
    frame: { x: 30, y: 40, width: 200, height: 30 },
  };
}

function successfulOutcome() {
  return {
    state: 'confirmed_change',
    route: 'bridge',
    deliveryMode: 'background',
    effect: 'confirmed',
    evidence: 'verified_change',
    dispatchState: 'dispatched',
    retrySafety: 'unsafe',
    mutationDispatched: true,
    retrySafe: false,
  };
}

function wireOutcome(outcome) {
  const result = {
    state: outcome.state,
    route: outcome.route,
    effect: outcome.effect,
    evidence: outcome.evidence,
    dispatch_state: outcome.dispatchState,
    retry_safety: outcome.retrySafety,
    escalation: 'none',
    mutation_dispatched: outcome.mutationDispatched,
    retry_safe: outcome.retrySafe,
    requires_fresh_observation: outcome.mutationDispatched && !outcome.retrySafe,
  };
  if (outcome.deliveryMode !== null) {
    result.delivery_mechanism = 'process_targeted_events';
    result.delivery_mode = outcome.deliveryMode;
  }
  if (outcome.dispatchState !== 'none') result.dispatched_unit_count = 1;
  return result;
}

function attributionFailureOutcome(stage) {
  if (stage === 'pre_dispatch') {
    return {
      state: 'refused',
      route: 'bridge',
      deliveryMode: null,
      effect: 'refused',
      evidence: 'request_refused',
      dispatchState: 'none',
      retrySafety: 'safe',
      mutationDispatched: false,
      retrySafe: true,
    };
  }
  return {
    state: 'indeterminate',
    route: 'bridge',
    deliveryMode: 'background',
    effect: 'unverifiable',
    evidence: 'completion_unknown',
    dispatchState: 'may_have_dispatched',
    retrySafety: 'unsafe',
    mutationDispatched: true,
    retrySafe: false,
  };
}

function makeFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'peekaboo-attested-receipts.'));
  const receiptDirectory = path.join(root, 'verified-receipts');
  fs.mkdirSync(receiptDirectory, { mode: 0o700 });
  fs.chmodSync(receiptDirectory, 0o700);
  const socketPath = path.join(root, 'bridge.sock');
  const listenerInstanceID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const hostArchiveRoot = path.join(
    root,
    'PeekabooOperationReceipts',
    sha256(Buffer.from(socketPath, 'utf8')),
  );
  const listenerArchive = path.join(hostArchiveRoot, listenerInstanceID);
  fs.mkdirSync(listenerArchive, { recursive: true, mode: 0o700 });
  fs.chmodSync(path.dirname(hostArchiveRoot), 0o700);
  fs.chmodSync(hostArchiveRoot, 0o700);
  fs.chmodSync(listenerArchive, 0o700);
  const signingPublicKeyBase64 = publicKey.toString('base64');
  const listener = {
    instanceID: listenerInstanceID,
    signingPublicKeyBase64,
    signingPublicKeySHA256: sha256(publicKey),
    bridgePID: 440,
    bridgeStartIdentity: '44000123',
    bridgeCodeSignatureHash: 'a'.repeat(40),
    createdAtMilliseconds: 1_000,
    receiptArchiveDirectory: listenerArchive,
  };
  const ownedTarget = target(501, '50100123', 601, 10);
  const foregroundTarget = target(502, '50200123', 602, 700);
  const requests = [
    {
      sessionID: '33333333-3333-4333-8333-333333333333',
      sessionSequence: '0',
      clientInstanceID: '55555555-5555-4555-8555-555555555555',
      kind: 'observation',
      operation: 'desktopObservation',
      requestEnvelopeCase: 'desktopObservation',
      requestCase: 'desktopObservation',
      responseEnvelopeCase: 'desktopObservation',
      responseCase: 'desktopObservation',
      client: { pid: 701, startIdentity: '70100123', codeSignatureHash: 'b'.repeat(40) },
      request: { desktopObservation: { _0: { fixture: true } } },
      response: { desktopObservation: { _0: { fixture: true } } },
      focusedElement: null,
      outcome: null,
      startedAtMilliseconds: 2_100,
      completedAtMilliseconds: 2_200,
    },
    {
      sessionID: '44444444-4444-4444-8444-444444444444',
      sessionSequence: '0',
      clientInstanceID: '66666666-6666-4666-8666-666666666666',
      kind: 'mutation',
      operation: 'exactWindowTargetedTypeActions',
      requestEnvelopeCase: 'projectedAction',
      requestCase: 'exactWindowTargetedTypeActions',
      responseEnvelopeCase: 'projectedAction',
      responseCase: 'typeResult',
      client: { pid: 702, startIdentity: '70200123', codeSignatureHash: 'c'.repeat(40) },
      request: {
        projectedAction: {
          _0: { request: { exactWindowTargetedTypeActions: { _0: { fixture: true } } } },
        },
      },
      response: {
        projectedAction: {
          _0: {
            response: { typeResult: { _0: { fixture: true } } },
            outcome: wireOutcome(successfulOutcome()),
          },
        },
      },
      focusedElement: focusedElement(ownedTarget.pid, ownedTarget.windowID),
      outcome: successfulOutcome(),
      startedAtMilliseconds: 2_300,
      completedAtMilliseconds: 2_400,
    },
  ];
  requests.forEach((request) => {
    request.requestID = deterministicRequestID(request.sessionID, request.sessionSequence);
  });
  const contract = {
    version: 3,
    certificationRunID: 'coexistence-fixture',
    adapter: {
      id: adapter.adapterID,
      sha256: sha256(fs.readFileSync(canonicalAdapterPath)),
    },
    protocolImplementation: {
      sourceCommit: '1'.repeat(40),
      sourceTree: '2'.repeat(40),
      peerBinding: 'darwin-audit-token-pidversion-euid-cdhash-v1',
      operationReceiptsSHA256: '3'.repeat(64),
      socketIOSHA256: '4'.repeat(64),
      hostClientsSHA256: '5'.repeat(64),
      privateArchiveSHA256: '6'.repeat(64),
    },
    protocol: { major: 1, minor: 29 },
    socketEndpoint: { path: socketPath, device: '16777233', inode: '99123' },
    listener,
    hostArchive: {
      temporaryRoot: root,
      rootDirectory: hostArchiveRoot,
      socketNamespaceSHA256: sha256(Buffer.from(socketPath, 'utf8')),
      listenerDirectoryLimit: 16,
      sessionDirectoryLimit: 64,
      attestationFileSHA256: '0'.repeat(64),
    },
    ownedTarget,
    foregroundTarget,
    interval: { startedAtMilliseconds: 2_000, completedAtMilliseconds: 3_000 },
    expectedOperations: requests.map((request) => ({
      operationID: `${request.kind}-${request.operation}`,
      requestID: request.requestID,
      kind: request.kind,
      operation: request.operation,
      requestEnvelopeCase: request.requestEnvelopeCase,
      requestCase: request.requestCase,
      responseEnvelopeCase: request.responseEnvelopeCase,
      responseCase: request.responseCase,
      targetRequired: true,
      client: request.client,
      requestSHA256: sha256(canonicalBytes(request.request)),
      responseSHA256: sha256(canonicalBytes(request.response)),
      target: ownedTarget,
      focusedElement: request.focusedElement,
      attributionFailure: null,
      outcome: request.outcome,
    })),
  };
  const socketEvidence = {
    path: socketPath,
    device: contract.socketEndpoint.device,
    inode: contract.socketEndpoint.inode,
    isSocket: true,
    isSymbolicLink: false,
  };
  const sourceEvidence = structuredClone(contract.protocolImplementation);
  const attestationPayload = {
    schemaVersion: 1,
    listenerInstanceID,
    signingPublicKeyBase64,
    bridgePID: listener.bridgePID,
    bridgeStartIdentity: listener.bridgeStartIdentity,
    bridgeCodeSignatureHash: listener.bridgeCodeSignatureHash,
    createdAtMilliseconds: listener.createdAtMilliseconds,
    receiptArchiveDirectory: listenerArchive,
  };
  const attestationDocument = {
    payload: attestationPayload,
    signature: signature(attestationPayload),
  };
  const attestationBytes = canonicalBytes(attestationDocument);
  contract.hostArchive.attestationFileSHA256 = sha256(attestationBytes);
  fs.writeFileSync(path.join(listenerArchive, 'attestation.json'), attestationBytes, { mode: 0o600 });
  fs.chmodSync(path.join(listenerArchive, 'attestation.json'), 0o600);
  const receiptDocuments = requests.map((request) => {
    const requestBytes = canonicalBytes(request.request);
    const responseBytes = canonicalBytes(request.response);
    const sessionPayload = {
      schemaVersion: 1,
      sessionID: request.sessionID,
      listenerInstanceID,
      listenerKeySHA256: listener.signingPublicKeySHA256,
      clientInstanceID: request.clientInstanceID,
      clientPID: request.client.pid,
      clientStartIdentity: request.client.startIdentity,
      clientCodeSignatureHash: request.client.codeSignatureHash,
      maximumRequestCount: 16,
      remainingClaimCount: 16,
      predecessorSessionID: null,
      createdAtMilliseconds: 1_100,
    };
    const sessionDocument = {
      payload: sessionPayload,
      signature: signature(sessionPayload),
    };
    const payload = {
      schemaVersion: 1,
      requestID: request.requestID,
      sessionID: request.sessionID,
      sessionSequence: request.sessionSequence,
      sessionAttestationSHA256: sha256(canonicalBytes(sessionDocument)),
      listenerInstanceID,
      listenerKeySHA256: listener.signingPublicKeySHA256,
      clientInstanceID: request.clientInstanceID,
      bridgePID: listener.bridgePID,
      bridgeStartIdentity: listener.bridgeStartIdentity,
      bridgeCodeSignatureHash: listener.bridgeCodeSignatureHash,
      clientPID: request.client.pid,
      clientStartIdentity: request.client.startIdentity,
      clientCodeSignatureHash: request.client.codeSignatureHash,
      operation: request.operation,
      requestSHA256: sha256(requestBytes),
      responseSHA256: sha256(responseBytes),
      target: ownedTarget,
      focusedElement: request.focusedElement,
      attributionFailure: null,
      outcome: request.outcome,
      remainingClaimCount: 15,
      requestEnvelopeCase: request.requestEnvelopeCase,
      requestCase: request.requestCase,
      responseEnvelopeCase: request.responseEnvelopeCase,
      responseCase: request.responseCase,
      responseOutcome: request.outcome,
      startedAtMilliseconds: request.startedAtMilliseconds,
      completedAtMilliseconds: request.completedAtMilliseconds,
    };
    return {
      session: sessionDocument,
      payload,
      requestCanonicalBase64: requestBytes.toString('base64'),
      responseCanonicalBase64: responseBytes.toString('base64'),
      signature: signature(payload),
    };
  });
  for (const document of receiptDocuments) {
    const receiptPath = path.join(receiptDirectory, `${document.payload.requestID}.json`);
    const bytes = canonicalBytes(document);
    fs.writeFileSync(receiptPath, bytes, { mode: 0o600 });
    fs.chmodSync(receiptPath, 0o600);
    const hostSessionDirectory = path.join(listenerArchive, 'sessions', document.payload.sessionID);
    fs.mkdirSync(hostSessionDirectory, { recursive: true, mode: 0o700 });
    fs.chmodSync(path.join(listenerArchive, 'sessions'), 0o700);
    fs.chmodSync(hostSessionDirectory, 0o700);
    fs.mkdirSync(path.join(listenerArchive, 'retired-sessions'), { recursive: true, mode: 0o700 });
    fs.chmodSync(path.join(listenerArchive, 'retired-sessions'), 0o700);
    const hostSessionPath = path.join(hostSessionDirectory, 'attestation.json');
    const hostSessionBytes = canonicalBytes(document.session);
    fs.writeFileSync(hostSessionPath, hostSessionBytes, { mode: 0o600 });
    fs.chmodSync(hostSessionPath, 0o600);
    const hostReceiptPath = path.join(hostSessionDirectory, `${document.payload.sessionSequence}.json`);
    fs.writeFileSync(hostReceiptPath, bytes, { mode: 0o600 });
    fs.chmodSync(hostReceiptPath, 0o600);
  }
  return {
    root,
    receiptDirectory,
    contract,
    socketEvidence,
    sourceEvidence,
    attestationDocument,
    receiptDocuments,
    cleanup() { fs.rmSync(root, { recursive: true, force: true }); },
  };
}

function convertToBridgeBundles(fixture) {
  fixture.contract.adapter = {
    id: bridgeBundleAdapter.adapterID,
    sha256: sha256(fs.readFileSync(bridgeBundleAdapterPath)),
  };
  const rawAttestation = {
    schemaVersion: 1,
    listenerInstanceID: fixture.contract.listener.instanceID.toUpperCase(),
    publicKey: fixture.contract.listener.signingPublicKeyBase64,
    host: {
      processIdentifier: fixture.contract.listener.bridgePID,
      processStartIdentity: fixture.contract.listener.bridgeStartIdentity,
      codeSignatureHash: fixture.contract.listener.bridgeCodeSignatureHash,
    },
    createdAtUnixMilliseconds: fixture.contract.listener.createdAtMilliseconds,
    receiptArchiveDirectory: fixture.contract.listener.receiptArchiveDirectory,
  };
  const signedAttestation = {
    ...rawAttestation,
    signature: signature(rawAttestation).value,
  };
  fixture.receiptDocuments = fixture.receiptDocuments.map((document, index) => {
    const normalized = document.payload;
    const normalizedSession = document.session.payload;
    const targetReceipt = {
      kind: 'window',
      processIdentifier: normalized.target.pid,
      processStartIdentity: normalized.target.processStartIdentity,
      windowID: normalized.target.windowID,
      capturedBounds: [
        [normalized.target.bounds.x, normalized.target.bounds.y],
        [normalized.target.bounds.width, normalized.target.bounds.height],
      ],
      isMinimized: false,
    };
    const outcome = normalized.outcome === null ? null : {
      state: normalized.outcome.state,
      effect: normalized.outcome.effect,
      route: normalized.outcome.route,
      delivery_mechanism: 'process_targeted_events',
      delivery_mode: normalized.outcome.deliveryMode,
      evidence: normalized.outcome.evidence,
      dispatch_state: normalized.outcome.dispatchState,
      dispatched_unit_count: 1,
      retry_safety: normalized.outcome.retrySafety,
      escalation: 'none',
      mutation_dispatched: normalized.outcome.mutationDispatched,
      retry_safe: normalized.outcome.retrySafe,
      requires_fresh_observation: true,
    };
    const rawFocusedElement = normalized.focusedElement === null ? undefined : {
      processIdentifier: normalized.focusedElement.pid,
      windowID: normalized.focusedElement.windowID,
      role: normalized.focusedElement.role,
      title: normalized.focusedElement.title,
      identifier: normalized.focusedElement.identifier,
      frame: [
        [normalized.focusedElement.frame.x, normalized.focusedElement.frame.y],
        [normalized.focusedElement.frame.width, normalized.focusedElement.frame.height],
      ],
    };
    const rawPayload = {
      schemaVersion: 1,
      requestID: normalized.requestID.toUpperCase(),
      sessionID: normalized.sessionID.toUpperCase(),
      sessionSequence: normalized.sessionSequence,
      listenerInstanceID: normalized.listenerInstanceID.toUpperCase(),
      listenerPublicKeySHA256: normalized.listenerKeySHA256,
      clientInstanceID: normalized.clientInstanceID.toUpperCase(),
      host: {
        processIdentifier: normalized.bridgePID,
        processStartIdentity: normalized.bridgeStartIdentity,
        codeSignatureHash: normalized.bridgeCodeSignatureHash,
      },
      client: {
        processIdentifier: normalized.clientPID,
        processStartIdentity: normalized.clientStartIdentity,
        codeSignatureHash: normalized.clientCodeSignatureHash,
      },
      operation: normalized.operation,
      requestSHA256: normalized.requestSHA256,
      responseSHA256: normalized.responseSHA256,
      target: targetReceipt,
      ...(rawFocusedElement === undefined ? {} : { focusedElement: rawFocusedElement }),
      outcome,
      remainingClaimCount: normalized.remainingClaimCount,
      startedAtUnixMilliseconds: normalized.startedAtMilliseconds,
      completedAtUnixMilliseconds: normalized.completedAtMilliseconds,
    };
    const rawSessionPayload = {
      schemaVersion: 1,
      sessionID: normalizedSession.sessionID.toUpperCase(),
      listenerInstanceID: normalizedSession.listenerInstanceID.toUpperCase(),
      listenerPublicKeySHA256: normalizedSession.listenerKeySHA256,
      clientInstanceID: normalizedSession.clientInstanceID.toUpperCase(),
      client: {
        processIdentifier: normalizedSession.clientPID,
        processStartIdentity: normalizedSession.clientStartIdentity,
        codeSignatureHash: normalizedSession.clientCodeSignatureHash,
      },
      maximumRequestCount: normalizedSession.maximumRequestCount,
      remainingClaimCount: normalizedSession.remainingClaimCount,
      ...(normalizedSession.predecessorSessionID === null
        ? {}
        : { predecessorSessionID: normalizedSession.predecessorSessionID.toUpperCase() }),
      createdAtUnixMilliseconds: normalizedSession.createdAtMilliseconds,
    };
    const signedSessionAttestation = {
      ...rawSessionPayload,
      signature: signature(rawSessionPayload).value,
    };
    rawPayload.sessionAttestationSHA256 = sha256(canonicalBytes(signedSessionAttestation));
    const bundle = {
      operationAttestation: signedAttestation,
      operationSessionAttestation: signedSessionAttestation,
      receipt: {
        payload: rawPayload,
        signature: signature(rawPayload).value,
      },
      canonicalListenerAttestationPayload: canonicalBytes(rawAttestation).toString('base64'),
      canonicalSessionAttestationPayload: canonicalBytes(rawSessionPayload).toString('base64'),
      canonicalReceiptPayload: canonicalBytes(rawPayload).toString('base64'),
      canonicalRequest: document.requestCanonicalBase64,
      canonicalResponse: document.responseCanonicalBase64,
    };
    return bundle;
  });
  fixture.receiptDocuments.forEach((_, index) => writeBridgeBundle(fixture, index));
  const hostAttestationPath = path.join(
    fixture.contract.listener.receiptArchiveDirectory,
    'attestation.json',
  );
  const hostAttestationBytes = canonicalBytes(signedAttestation);
  fs.writeFileSync(hostAttestationPath, hostAttestationBytes, { mode: 0o600 });
  fs.chmodSync(hostAttestationPath, 0o600);
  fixture.contract.hostArchive.attestationFileSHA256 = sha256(hostAttestationBytes);
  fixture.attestationDocument = fixture.receiptDocuments[0];
  return fixture;
}

async function validate(
  fixture,
  selectedAdapter = adapter,
  selectedAdapterPath = canonicalAdapterPath,
) {
  return validateAttestedOperationReceipts({
    contract: fixture.contract,
    attestationDocument: fixture.attestationDocument,
    receiptDirectory: fixture.receiptDirectory,
    adapter: selectedAdapter,
    adapterSHA256: sha256(fs.readFileSync(selectedAdapterPath)),
    socketEvidence: fixture.socketEvidence,
    sourceEvidence: fixture.sourceEvidence,
  });
}

function rules(result) {
  return new Set(result.failures.map((entry) => entry.rule));
}

function hostSessionDirectory(fixture, document) {
  const payload = document.receipt?.payload ?? document.payload;
  return path.join(
    fixture.contract.listener.receiptArchiveDirectory,
    'sessions',
    payload.sessionID.toLowerCase(),
  );
}

function hostReceiptPath(fixture, document) {
  const payload = document.receipt?.payload ?? document.payload;
  return path.join(hostSessionDirectory(fixture, document), `${payload.sessionSequence}.json`);
}

function writeReceipt(fixture, index, { resign = true } = {}) {
  const document = fixture.receiptDocuments[index];
  if (resign) document.signature = signature(document.payload);
  const requestID = fixture.contract.expectedOperations[index].requestID;
  const receiptPath = path.join(fixture.receiptDirectory, `${requestID}.json`);
  const bytes = canonicalBytes(document);
  fs.writeFileSync(receiptPath, bytes, { mode: 0o600 });
  fs.chmodSync(receiptPath, 0o600);
  const archivedReceipt = hostReceiptPath(fixture, document);
  const sessionDirectory = hostSessionDirectory(fixture, document);
  fs.mkdirSync(sessionDirectory, { recursive: true, mode: 0o700 });
  const sessionPath = path.join(sessionDirectory, 'attestation.json');
  const sessionBytes = canonicalBytes(document.session);
  fs.writeFileSync(sessionPath, sessionBytes, { mode: 0o600 });
  fs.chmodSync(sessionPath, 0o600);
  fs.writeFileSync(archivedReceipt, bytes, { mode: 0o600 });
  fs.chmodSync(archivedReceipt, 0o600);
}

function rewriteCanonicalSession(fixture, index, {
  sessionID,
  sessionSequence,
  clientInstanceID,
  client,
  predecessorSessionID = null,
  remainingClaimCount,
  createdAtMilliseconds,
}) {
  const document = fixture.receiptDocuments[index];
  const oldRequestID = document.payload.requestID;
  const oldSessionID = document.payload.sessionID;
  const oldSequence = document.payload.sessionSequence;
  const sessionPayload = document.session.payload;
  sessionPayload.sessionID = sessionID;
  sessionPayload.clientInstanceID = clientInstanceID;
  sessionPayload.clientPID = client.pid;
  sessionPayload.clientStartIdentity = client.startIdentity;
  sessionPayload.clientCodeSignatureHash = client.codeSignatureHash;
  sessionPayload.predecessorSessionID = predecessorSessionID;
  sessionPayload.createdAtMilliseconds = createdAtMilliseconds;
  document.session.signature = signature(sessionPayload);

  const requestID = deterministicRequestID(sessionID, sessionSequence);
  document.payload.requestID = requestID;
  document.payload.sessionID = sessionID;
  document.payload.sessionSequence = sessionSequence;
  document.payload.sessionAttestationSHA256 = sha256(canonicalBytes(document.session));
  document.payload.clientInstanceID = clientInstanceID;
  document.payload.clientPID = client.pid;
  document.payload.clientStartIdentity = client.startIdentity;
  document.payload.clientCodeSignatureHash = client.codeSignatureHash;
  document.payload.remainingClaimCount = remainingClaimCount;
  const expected = fixture.contract.expectedOperations[index];
  expected.requestID = requestID;
  expected.client = structuredClone(client);

  fs.rmSync(path.join(fixture.receiptDirectory, `${oldRequestID}.json`), { force: true });
  fs.rmSync(path.join(
    fixture.contract.listener.receiptArchiveDirectory,
    'sessions',
    oldSessionID,
    `${oldSequence}.json`,
  ), { force: true });
  if (oldSessionID !== sessionID
      && !fixture.receiptDocuments.some((candidate, candidateIndex) => (
        candidateIndex !== index && candidate.payload.sessionID === oldSessionID
      ))) {
    fs.rmSync(path.join(
      fixture.contract.listener.receiptArchiveDirectory,
      'sessions',
      oldSessionID,
    ), { recursive: true, force: true });
  }
  writeReceipt(fixture, index);
}

function writeBridgeBundle(fixture, index) {
  const requestID = fixture.contract.expectedOperations[index].requestID;
  const bundle = fixture.receiptDocuments[index];
  const receiptPath = path.join(fixture.receiptDirectory, `${requestID}.json`);
  fs.writeFileSync(receiptPath, canonicalBytes(bundle), { mode: 0o600 });
  fs.chmodSync(receiptPath, 0o600);
  const sessionDirectory = hostSessionDirectory(fixture, bundle);
  fs.mkdirSync(sessionDirectory, { recursive: true, mode: 0o700 });
  const sessionBytes = canonicalBytes(bundle.operationSessionAttestation);
  const sessionPath = path.join(sessionDirectory, 'attestation.json');
  fs.writeFileSync(sessionPath, sessionBytes, { mode: 0o600 });
  fs.chmodSync(sessionPath, 0o600);
  const archivedReceipt = hostReceiptPath(fixture, bundle);
  fs.writeFileSync(archivedReceipt, canonicalBytes(bundle.receipt), { mode: 0o600 });
  fs.chmodSync(archivedReceipt, 0o600);
}

function resignBridgeReceipt(fixture, index) {
  const bundle = fixture.receiptDocuments[index];
  bundle.receipt.signature = signature(bundle.receipt.payload).value;
  bundle.canonicalReceiptPayload = canonicalBytes(bundle.receipt.payload).toString('base64');
  writeBridgeBundle(fixture, index);
}

function resignBridgeSession(fixture, index) {
  const bundle = fixture.receiptDocuments[index];
  const unsigned = { ...bundle.operationSessionAttestation };
  delete unsigned.signature;
  bundle.operationSessionAttestation.signature = signature(unsigned).value;
  bundle.canonicalSessionAttestationPayload = canonicalBytes(unsigned).toString('base64');
  bundle.receipt.payload.sessionAttestationSHA256 = sha256(canonicalBytes(
    bundle.operationSessionAttestation,
  ));
  resignBridgeReceipt(fixture, index);
}

function replaceBridgeResponse(fixture, index, response) {
  const bundle = fixture.receiptDocuments[index];
  const bytes = canonicalBytes(response);
  const digest = sha256(bytes);
  bundle.canonicalResponse = bytes.toString('base64');
  bundle.receipt.payload.responseSHA256 = digest;
  fixture.contract.expectedOperations[index].responseSHA256 = digest;
  resignBridgeReceipt(fixture, index);
}

function replaceBridgeRequest(fixture, index, request) {
  const bundle = fixture.receiptDocuments[index];
  const bytes = canonicalBytes(request);
  const digest = sha256(bytes);
  bundle.canonicalRequest = bytes.toString('base64');
  bundle.receipt.payload.requestSHA256 = digest;
  fixture.contract.expectedOperations[index].requestSHA256 = digest;
  resignBridgeReceipt(fixture, index);
}

test('accepts exact signed receipts for one isolated background target', async (t) => {
  const fixture = makeFixture();
  t.after(fixture.cleanup);
  const result = await validate(fixture);
  assert.equal(result.success, true);
  assert.deepEqual(result.failures, []);
  assert.deepEqual(
    result.receipts.map((entry) => entry.request_id),
    fixture.contract.expectedOperations.map((entry) => entry.requestID).sort(),
  );
});

test('protocol 1.29 adapter verifies the real same-connection bundle shape', async (t) => {
  const fixture = convertToBridgeBundles(makeFixture());
  t.after(fixture.cleanup);
  const result = await validate(fixture, bridgeBundleAdapter, bridgeBundleAdapterPath);
  assert.equal(result.success, true);
  assert.deepEqual(result.failures, []);

  const tampered = convertToBridgeBundles(makeFixture());
  t.after(tampered.cleanup);
  tampered.receiptDocuments[0].canonicalResponse = Buffer.from('{}').toString('base64');
  writeBridgeBundle(tampered, 0);
  assert.ok(rules(await validate(tampered, bridgeBundleAdapter, bridgeBundleAdapterPath)).has('receipt_decode'));

  const largeIdentity = convertToBridgeBundles(makeFixture());
  t.after(largeIdentity.cleanup);
  largeIdentity.contract.expectedOperations[0].client.startIdentity = '9007199254740993';
  largeIdentity.receiptDocuments[0].receipt.payload.client.processStartIdentity = '9007199254740993';
  largeIdentity.receiptDocuments[0].operationSessionAttestation.client.processStartIdentity =
    '9007199254740993';
  resignBridgeSession(largeIdentity, 0);
  assert.equal(
    (await validate(largeIdentity, bridgeBundleAdapter, bridgeBundleAdapterPath)).success,
    true,
  );

  const mixedListener = convertToBridgeBundles(makeFixture());
  t.after(mixedListener.cleanup);
  mixedListener.receiptDocuments[1].operationAttestation.listenerInstanceID =
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  const mixedUnsigned = { ...mixedListener.receiptDocuments[1].operationAttestation };
  delete mixedUnsigned.signature;
  mixedListener.receiptDocuments[1].operationAttestation.signature = signature(mixedUnsigned).value;
  mixedListener.receiptDocuments[1].canonicalListenerAttestationPayload =
    canonicalBytes(mixedUnsigned).toString('base64');
  writeBridgeBundle(mixedListener, 1);
  const mixedResult = await validate(mixedListener, bridgeBundleAdapter, bridgeBundleAdapterPath);
  assert.ok(rules(mixedResult).has('listener_attestation'));

  const globalTarget = convertToBridgeBundles(makeFixture());
  t.after(globalTarget.cleanup);
  globalTarget.receiptDocuments[0].receipt.payload.target = { kind: 'global' };
  globalTarget.receiptDocuments[0].receipt.signature =
    signature(globalTarget.receiptDocuments[0].receipt.payload).value;
  globalTarget.receiptDocuments[0].canonicalReceiptPayload = canonicalBytes(
    globalTarget.receiptDocuments[0].receipt.payload,
  ).toString('base64');
  writeBridgeBundle(globalTarget, 0);
  assert.ok(rules(await validate(globalTarget, bridgeBundleAdapter, bridgeBundleAdapterPath))
    .has('receipt_schema'));
});

test('logical session request IDs and decimal sequences are canonical and deterministic', async (t) => {
  assert.equal(
    deterministicRequestID('33333333-3333-4333-8333-333333333333', '0'),
    '1d16724c-2cb5-8441-853f-549bc677faa9',
  );
  assert.equal(
    deterministicRequestID('44444444-4444-4444-8444-444444444444', '0'),
    '0aca3ce7-caf2-8c63-b4ca-39ab6dcc6784',
  );

  const wrongID = convertToBridgeBundles(makeFixture());
  t.after(wrongID.cleanup);
  wrongID.receiptDocuments[0].receipt.payload.requestID =
    'aaaaaaaa-aaaa-8aaa-8aaa-aaaaaaaaaaaa';
  resignBridgeReceipt(wrongID, 0);
  assert.ok(rules(await validate(wrongID, bridgeBundleAdapter, bridgeBundleAdapterPath))
    .has('receipt_schema'));

  for (const sequence of ['01', '18446744073709551616', 0]) {
    const malformed = convertToBridgeBundles(makeFixture());
    t.after(malformed.cleanup);
    malformed.receiptDocuments[0].receipt.payload.sessionSequence = sequence;
    resignBridgeReceipt(malformed, 0);
    assert.ok(rules(await validate(malformed, bridgeBundleAdapter, bridgeBundleAdapterPath))
      .has('receipt_decode'));
  }
});

test('logical session signatures canonical payloads and receipt digests fail closed', async (t) => {
  const canonical = convertToBridgeBundles(makeFixture());
  t.after(canonical.cleanup);
  canonical.receiptDocuments[0].canonicalSessionAttestationPayload =
    Buffer.from('{}').toString('base64');
  writeBridgeBundle(canonical, 0);
  assert.ok(rules(await validate(canonical, bridgeBundleAdapter, bridgeBundleAdapterPath))
    .has('receipt_decode'));

  const signatureFixture = convertToBridgeBundles(makeFixture());
  t.after(signatureFixture.cleanup);
  signatureFixture.receiptDocuments[0].operationSessionAttestation.signature =
    Buffer.alloc(64, 7).toString('base64');
  writeBridgeBundle(signatureFixture, 0);
  assert.ok(rules(await validate(signatureFixture, bridgeBundleAdapter, bridgeBundleAdapterPath))
    .has('session_signature'));

  const digestFixture = convertToBridgeBundles(makeFixture());
  t.after(digestFixture.cleanup);
  digestFixture.receiptDocuments[0].receipt.payload.sessionAttestationSHA256 = '0'.repeat(64);
  resignBridgeReceipt(digestFixture, 0);
  assert.ok(rules(await validate(digestFixture, bridgeBundleAdapter, bridgeBundleAdapterPath))
    .has('session_digest'));

  const clientFixture = convertToBridgeBundles(makeFixture());
  t.after(clientFixture.cleanup);
  clientFixture.receiptDocuments[0].receipt.payload.clientInstanceID =
    '77777777-7777-4777-8777-777777777777';
  resignBridgeReceipt(clientFixture, 0);
  assert.ok(rules(await validate(clientFixture, bridgeBundleAdapter, bridgeBundleAdapterPath))
    .has('session_attestation'));

  const capacityFixture = convertToBridgeBundles(makeFixture());
  t.after(capacityFixture.cleanup);
  capacityFixture.receiptDocuments[0].operationSessionAttestation.maximumRequestCount = 16385;
  capacityFixture.receiptDocuments[0].operationSessionAttestation.remainingClaimCount = 16385;
  resignBridgeSession(capacityFixture, 0);
  assert.ok(rules(await validate(capacityFixture, bridgeBundleAdapter, bridgeBundleAdapterPath))
    .has('session_attestation'));
});

test('session claims reject out-of-range and duplicate tuple or budget evidence', async (t) => {
  const outOfRange = makeFixture();
  t.after(outOfRange.cleanup);
  const original = outOfRange.receiptDocuments[0];
  rewriteCanonicalSession(outOfRange, 0, {
    sessionID: original.payload.sessionID,
    sessionSequence: '16',
    clientInstanceID: original.payload.clientInstanceID,
    client: outOfRange.contract.expectedOperations[0].client,
    remainingClaimCount: 15,
    createdAtMilliseconds: 1_100,
  });
  assert.ok(rules(await validate(outOfRange)).has('session_claim'));

  const duplicateTuple = makeFixture();
  t.after(duplicateTuple.cleanup);
  duplicateTuple.receiptDocuments[1] = structuredClone(duplicateTuple.receiptDocuments[0]);
  writeReceipt(duplicateTuple, 1);
  assert.ok(rules(await validate(duplicateTuple)).has('session_replay'));

  const duplicateBudget = makeFixture();
  t.after(duplicateBudget.cleanup);
  const first = duplicateBudget.receiptDocuments[0];
  rewriteCanonicalSession(duplicateBudget, 1, {
    sessionID: first.payload.sessionID,
    sessionSequence: '1',
    clientInstanceID: first.payload.clientInstanceID,
    client: duplicateBudget.contract.expectedOperations[0].client,
    remainingClaimCount: first.payload.remainingClaimCount,
    createdAtMilliseconds: 1_100,
  });
  assert.ok(rules(await validate(duplicateBudget)).has('session_claim_replay'));
});

test('successor sessions require an exact same-client signed predecessor chain', async (t) => {
  const valid = makeFixture();
  t.after(valid.cleanup);
  const predecessor = valid.receiptDocuments[0];
  const successor = valid.receiptDocuments[1];
  rewriteCanonicalSession(valid, 1, {
    sessionID: successor.payload.sessionID,
    sessionSequence: successor.payload.sessionSequence,
    clientInstanceID: predecessor.payload.clientInstanceID,
    client: valid.contract.expectedOperations[0].client,
    predecessorSessionID: predecessor.payload.sessionID,
    remainingClaimCount: 15,
    createdAtMilliseconds: 1_200,
  });
  assert.equal((await validate(valid)).success, true);

  const orphan = makeFixture();
  t.after(orphan.cleanup);
  const orphanDocument = orphan.receiptDocuments[1];
  rewriteCanonicalSession(orphan, 1, {
    sessionID: orphanDocument.payload.sessionID,
    sessionSequence: orphanDocument.payload.sessionSequence,
    clientInstanceID: orphanDocument.payload.clientInstanceID,
    client: orphan.contract.expectedOperations[1].client,
    predecessorSessionID: '77777777-7777-4777-8777-777777777777',
    remainingClaimCount: 15,
    createdAtMilliseconds: 1_200,
  });
  assert.ok(rules(await validate(orphan)).has('session_predecessor'));

  const crossClient = makeFixture();
  t.after(crossClient.cleanup);
  const crossClientDocument = crossClient.receiptDocuments[1];
  rewriteCanonicalSession(crossClient, 1, {
    sessionID: crossClientDocument.payload.sessionID,
    sessionSequence: crossClientDocument.payload.sessionSequence,
    clientInstanceID: crossClientDocument.payload.clientInstanceID,
    client: crossClient.contract.expectedOperations[1].client,
    predecessorSessionID: crossClient.receiptDocuments[0].payload.sessionID,
    remainingClaimCount: 15,
    createdAtMilliseconds: 1_200,
  });
  assert.ok(rules(await validate(crossClient)).has('session_predecessor'));
});

test('listener identity and self-signature are pinned', async (t) => {
  const fixture = makeFixture();
  t.after(fixture.cleanup);
  fixture.attestationDocument.payload.bridgePID += 1;
  const result = await validate(fixture);
  assert.equal(result.success, false);
  assert.ok(rules(result).has('listener_attestation'));
  assert.ok(rules(result).has('listener_signature'));
});

test('receipt signature and canonical request/response digests fail closed', async (t) => {
  const signatureFixture = makeFixture();
  t.after(signatureFixture.cleanup);
  signatureFixture.receiptDocuments[1].payload.clientPID += 1;
  writeReceipt(signatureFixture, 1, { resign: false });
  assert.ok(rules(await validate(signatureFixture)).has('receipt_signature'));

  const requestFixture = makeFixture();
  t.after(requestFixture.cleanup);
  requestFixture.receiptDocuments[0].requestCanonicalBase64 = Buffer.from('{}').toString('base64');
  writeReceipt(requestFixture, 0);
  assert.ok(rules(await validate(requestFixture)).has('request_digest'));

  const responseFixture = makeFixture();
  t.after(responseFixture.cleanup);
  responseFixture.receiptDocuments[0].responseCanonicalBase64 = Buffer.from('{}').toString('base64');
  writeReceipt(responseFixture, 0);
  assert.ok(rules(await validate(responseFixture)).has('response_digest'));
});

test('request case response case and response outcome are independently pinned', async (t) => {
  const requestCase = convertToBridgeBundles(makeFixture());
  t.after(requestCase.cleanup);
  replaceBridgeRequest(requestCase, 1, {
    projectedAction: {
      _0: { request: { exactWindowTargetedHotkey: { _0: { fixture: true } } } },
    },
  });
  assert.ok(rules(await validate(requestCase, bridgeBundleAdapter, bridgeBundleAdapterPath))
    .has('receipt_contract'));

  const responseCase = convertToBridgeBundles(makeFixture());
  t.after(responseCase.cleanup);
  replaceBridgeResponse(responseCase, 1, {
    projectedAction: {
      _0: { response: { ok: {} }, outcome: wireOutcome(successfulOutcome()) },
    },
  });
  assert.ok(rules(await validate(responseCase, bridgeBundleAdapter, bridgeBundleAdapterPath))
    .has('receipt_contract'));

  const responseOutcome = convertToBridgeBundles(makeFixture());
  t.after(responseOutcome.cleanup);
  const foreground = { ...successfulOutcome(), deliveryMode: 'foreground' };
  replaceBridgeResponse(responseOutcome, 1, {
    projectedAction: {
      _0: { response: { typeResult: { _0: { fixture: true } } }, outcome: wireOutcome(foreground) },
    },
  });
  assert.ok(rules(await validate(responseOutcome, bridgeBundleAdapter, bridgeBundleAdapterPath))
    .has('receipt_schema'));
});

test('attribution failures retain stage evidence and retry semantics but cannot certify', async (t) => {
  for (const stage of ['pre_dispatch', 'post_execution']) {
    const fixture = convertToBridgeBundles(makeFixture());
    t.after(fixture.cleanup);
    const bundle = fixture.receiptDocuments[1];
    const outcome = attributionFailureOutcome(stage);
    delete bundle.receipt.payload.target;
    delete bundle.receipt.payload.focusedElement;
    bundle.receipt.payload.targetAttributionFailure = {
      code: stage === 'pre_dispatch' ? 'missing_process_generation' : 'contradictory_process_generation',
      message: `fixture ${stage}`,
      stage,
    };
    bundle.receipt.payload.targetAttributionEvidence = [{
      processIdentifier: fixture.contract.ownedTarget.pid,
      processIdentityProcessIdentifier: fixture.contract.ownedTarget.pid,
      processIdentityStartIdentity: fixture.contract.ownedTarget.processStartIdentity,
    }];
    bundle.receipt.payload.outcome = wireOutcome(outcome);
    const response = {
      projectedAction: {
        _0: {
          response: { error: { _0: { code: 'invalidRequest', message: 'fixture' } } },
          outcome: wireOutcome(outcome),
        },
      },
    };
    replaceBridgeResponse(fixture, 1, response);
    const result = await validate(fixture, bridgeBundleAdapter, bridgeBundleAdapterPath);
    assert.equal(result.success, false, stage);
    assert.ok(rules(result).has('attribution_failure'), stage);
    assert.ok(!rules(result).has('attribution_semantics'), stage);
  }

  const contradicted = convertToBridgeBundles(makeFixture());
  t.after(contradicted.cleanup);
  const bundle = contradicted.receiptDocuments[1];
  const safe = attributionFailureOutcome('pre_dispatch');
  delete bundle.receipt.payload.target;
  delete bundle.receipt.payload.focusedElement;
  bundle.receipt.payload.targetAttributionFailure = {
    code: 'contradictory_process_generation',
    message: 'fixture post dispatch with safe outcome',
    stage: 'post_execution',
  };
  bundle.receipt.payload.targetAttributionEvidence = [{ processIdentifier: 501 }];
  bundle.receipt.payload.outcome = wireOutcome(safe);
  replaceBridgeResponse(contradicted, 1, {
    projectedAction: {
      _0: {
        response: { error: { _0: { code: 'invalidRequest', message: 'fixture' } } },
        outcome: wireOutcome(safe),
      },
    },
  });
  assert.ok(rules(await validate(contradicted, bridgeBundleAdapter, bridgeBundleAdapterPath))
    .has('attribution_semantics'));
});

test('missing receipt is an indeterminate retry-unsafe lost response', async (t) => {
  const fixture = makeFixture();
  t.after(fixture.cleanup);
  fs.unlinkSync(path.join(
    fixture.receiptDirectory,
    `${fixture.contract.expectedOperations[1].requestID}.json`,
  ));
  const result = await validate(fixture);
  assert.equal(result.success, false);
  assert.ok(rules(result).has('archive_completeness'));
  assert.ok(rules(result).has('lost_response'));
});

test('duplicate request IDs are rejected as replay', async (t) => {
  const fixture = makeFixture();
  t.after(fixture.cleanup);
  fixture.receiptDocuments[1] = structuredClone(fixture.receiptDocuments[0]);
  writeReceipt(fixture, 1);
  const result = await validate(fixture);
  assert.equal(result.success, false);
  assert.ok(rules(result).has('receipt_replay'));
  assert.ok(rules(result).has('lost_response'));
});

test('unknown request IDs bind to one exact client generation and operation', async (t) => {
  const fixture = makeFixture();
  t.after(fixture.cleanup);
  fixture.contract.expectedOperations.forEach((entry) => { entry.requestID = null; });
  const result = await validate(fixture);
  assert.equal(result.success, true);
  assert.deepEqual(result.receipts.map((entry) => entry.operation_id).sort(), [
    'mutation-exactWindowTargetedTypeActions',
    'observation-desktopObservation',
  ]);

  const missing = makeFixture();
  t.after(missing.cleanup);
  missing.contract.expectedOperations.forEach((entry) => { entry.requestID = null; });
  fs.unlinkSync(path.join(
    missing.receiptDirectory,
    `${missing.receiptDocuments[1].payload.requestID}.json`,
  ));
  assert.ok(rules(await validate(missing)).has('lost_response'));
});

test('client generation listener and operation must equal the request contract', async (t) => {
  const fixture = makeFixture();
  t.after(fixture.cleanup);
  fixture.receiptDocuments[1].payload.clientStartIdentity = '999999';
  fixture.receiptDocuments[1].payload.clientCodeSignatureHash = 'd'.repeat(40);
  fixture.receiptDocuments[1].payload.operation = 'press';
  writeReceipt(fixture, 1);
  assert.ok(rules(await validate(fixture)).has('receipt_contract'));
});

test('target ownership and background outcome cannot be weakened', async (t) => {
  const targetFixture = makeFixture();
  t.after(targetFixture.cleanup);
  targetFixture.receiptDocuments[1].payload.target = structuredClone(targetFixture.contract.foregroundTarget);
  targetFixture.receiptDocuments[1].payload.focusedElement = focusedElement(
    targetFixture.contract.foregroundTarget.pid,
    targetFixture.contract.foregroundTarget.windowID,
  );
  writeReceipt(targetFixture, 1);
  const targetResult = await validate(targetFixture);
  assert.ok(rules(targetResult).has('receipt_contract'));
  assert.ok(rules(targetResult).has('target_ownership'));

  const focusFixture = makeFixture();
  t.after(focusFixture.cleanup);
  focusFixture.receiptDocuments[1].payload.focusedElement.windowID += 1;
  writeReceipt(focusFixture, 1);
  assert.ok(rules(await validate(focusFixture)).has('receipt_schema'));

  const signedFocusFixture = convertToBridgeBundles(makeFixture());
  t.after(signedFocusFixture.cleanup);
  signedFocusFixture.receiptDocuments[1].receipt.payload.focusedElement.identifier = 'other-field';
  resignBridgeReceipt(signedFocusFixture, 1);
  assert.ok(rules(await validate(
    signedFocusFixture,
    bridgeBundleAdapter,
    bridgeBundleAdapterPath,
  )).has('receipt_contract'));

  const modeFixture = makeFixture();
  t.after(modeFixture.cleanup);
  modeFixture.receiptDocuments[1].payload.outcome.deliveryMode = 'foreground';
  writeReceipt(modeFixture, 1);
  const modeResult = await validate(modeFixture);
  assert.equal(modeResult.success, false);
  assert.ok([...rules(modeResult)].some((rule) => [
    'receipt_schema', 'receipt_contract', 'background_outcome',
  ].includes(rule)));
});

test('operation timestamps must remain inside the observed overlap', async (t) => {
  const fixture = makeFixture();
  t.after(fixture.cleanup);
  fixture.receiptDocuments[0].payload.startedAtMilliseconds = 1_999;
  writeReceipt(fixture, 0);
  assert.ok(rules(await validate(fixture)).has('receipt_interval'));
});

test('export directory and files must remain private and exact', async (t) => {
  const directoryFixture = makeFixture();
  t.after(directoryFixture.cleanup);
  fs.chmodSync(directoryFixture.receiptDirectory, 0o755);
  assert.ok(rules(await validate(directoryFixture)).has('archive_permissions'));

  const fileFixture = makeFixture();
  t.after(fileFixture.cleanup);
  fs.chmodSync(path.join(
    fileFixture.receiptDirectory,
    `${fileFixture.receiptDocuments[0].payload.requestID}.json`,
  ), 0o644);
  assert.ok(rules(await validate(fileFixture)).has('archive_permissions'));

  const extraFixture = makeFixture();
  t.after(extraFixture.cleanup);
  fs.writeFileSync(path.join(extraFixture.receiptDirectory, 'partial.tmp'), '{}', { mode: 0o600 });
  assert.ok(rules(await validate(extraFixture)).has('archive_completeness'));
});

test('host archive namespace retention and archived bytes are mandatory', async (t) => {
  const missing = makeFixture();
  t.after(missing.cleanup);
  fs.unlinkSync(hostReceiptPath(missing, missing.receiptDocuments[0]));
  const missingResult = await validate(missing);
  assert.ok(rules(missingResult).has('host_archive_completeness'));
  assert.ok(rules(missingResult).has('host_archive_file'));

  const tampered = makeFixture();
  t.after(tampered.cleanup);
  fs.writeFileSync(
    path.join(tampered.contract.listener.receiptArchiveDirectory, 'attestation.json'),
    '{}',
    { mode: 0o600 },
  );
  const tamperedResult = await validate(tampered);
  assert.ok(rules(tamperedResult).has('host_archive_file'));
  assert.ok(rules(tamperedResult).has('host_archive_attestation'));

  const retention = makeFixture();
  t.after(retention.cleanup);
  for (let index = 0; index < 16; index += 1) {
    const name = `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`;
    fs.mkdirSync(path.join(retention.contract.hostArchive.rootDirectory, name), { mode: 0o700 });
  }
  assert.ok(rules(await validate(retention)).has('host_archive_retention'));
});

test('export bundles remain authoritative when bounded session retention prunes host copies', async (t) => {
  const pruned = makeFixture();
  t.after(pruned.cleanup);
  fs.rmSync(hostSessionDirectory(pruned, pruned.receiptDocuments[0]), {
    recursive: true,
    force: true,
  });
  const prunedResult = await validate(pruned);
  assert.equal(prunedResult.success, true);
  assert.deepEqual(prunedResult.failures, []);

  const concurrent = makeFixture();
  t.after(concurrent.cleanup);
  const concurrentSession = path.join(
    concurrent.contract.listener.receiptArchiveDirectory,
    'sessions',
    '77777777-7777-4777-8777-777777777777',
  );
  fs.mkdirSync(concurrentSession, { mode: 0o700 });
  fs.writeFileSync(path.join(concurrentSession, 'attestation.json'), '{}', { mode: 0o600 });
  assert.equal((await validate(concurrent)).success, true);

  fs.writeFileSync(path.join(concurrentSession, 'latest.json'), '{}', { mode: 0o600 });
  assert.ok(rules(await validate(concurrent)).has('host_archive_layout'));
});

test('contract pins protocol socket listener archive and distinct targets', async (t) => {
  const fixture = makeFixture();
  t.after(fixture.cleanup);
  fixture.contract.protocol.minor = 28;
  fixture.contract.listener.receiptArchiveDirectory = '/tmp/rerouted';
  fixture.contract.foregroundTarget = structuredClone(fixture.contract.ownedTarget);
  const result = await validate(fixture);
  assert.equal(result.success, false);
  assert.ok(rules(result).has('contract_protocol'));
  assert.ok(rules(result).has('contract_archive_route'));
  assert.ok(rules(result).has('contract_target_isolation'));

  const socketFixture = makeFixture();
  t.after(socketFixture.cleanup);
  socketFixture.socketEvidence.inode = '99124';
  assert.ok(rules(await validate(socketFixture)).has('socket_endpoint'));

  const sourceFixture = makeFixture();
  t.after(sourceFixture.cleanup);
  sourceFixture.sourceEvidence.socketIOSHA256 = 'f'.repeat(64);
  assert.ok(rules(await validate(sourceFixture)).has('protocol_implementation'));

  const peerBindingFixture = makeFixture();
  t.after(peerBindingFixture.cleanup);
  peerBindingFixture.contract.protocolImplementation.peerBinding = 'pid-only';
  assert.ok(rules(await validate(peerBindingFixture)).has('contract_protocol_implementation'));
});

test('adapter boundary is explicit and versioned', async (t) => {
  const fixture = makeFixture();
  t.after(fixture.cleanup);
  const result = await validate(fixture, {
    adapterAPIVersion: 2,
    adapterID: 'future',
    embedsAttestation: false,
  });
  assert.equal(result.success, false);
  assert.ok(rules(result).has('adapter_contract'));

  const identityFixture = makeFixture();
  t.after(identityFixture.cleanup);
  identityFixture.contract.adapter.sha256 = '0'.repeat(64);
  assert.ok(rules(await validate(identityFixture)).has('adapter_identity'));
});
