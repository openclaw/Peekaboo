import { createHash } from 'node:crypto';

import { canonicalBytes } from '../validate-attested-operation-receipts.mjs';

export const adapterAPIVersion = 3;
export const adapterID = 'peekaboo-bridge-operation-receipt-bundle-1.29-logical-session-v1';
export const embedsAttestation = true;

function object(value, context) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${context} must be an object`);
  }
  return value;
}

function base64(value, context) {
  if (typeof value !== 'string') throw new Error(`${context} must be base64`);
  const bytes = Buffer.from(value, 'base64');
  if (bytes.length === 0) throw new Error(`${context} must not be empty`);
  return bytes;
}

function uuid(value, context) {
  if (typeof value !== 'string') throw new Error(`${context} must be a UUID`);
  return value.toLowerCase();
}

function decimal(value, context) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new Error(`${context} must be a canonical decimal string`);
  }
  const parsed = BigInt(value);
  if (parsed > 0xffff_ffff_ffff_ffffn) throw new Error(`${context} exceeds UInt64`);
  return value;
}

function processIdentity(value, context) {
  const identity = object(value, context);
  if (typeof identity.processStartIdentity !== 'string'
      || !/^[1-9][0-9]*$/.test(identity.processStartIdentity)) {
    throw new Error(`${context} start identity is not a canonical positive decimal string`);
  }
  return {
    pid: identity.processIdentifier,
    startIdentity: identity.processStartIdentity,
    codeSignatureHash: identity.codeSignatureHash,
  };
}

function listenerAttestation(document) {
  const root = object(document, 'verification bundle');
  return object(root.operationAttestation, 'same-connection operation attestation');
}

function sessionAttestation(document) {
  const root = object(document, 'verification bundle');
  return object(root.operationSessionAttestation, 'same-connection operation session attestation');
}

function normalizeAttestation(value) {
  const host = processIdentity(value.host, 'attested Bridge identity');
  return {
    schemaVersion: value.schemaVersion,
    listenerInstanceID: uuid(value.listenerInstanceID, 'listener instance'),
    signingPublicKeyBase64: value.publicKey,
    bridgePID: host.pid,
    bridgeStartIdentity: host.startIdentity,
    bridgeCodeSignatureHash: host.codeSignatureHash,
    createdAtMilliseconds: value.createdAtUnixMilliseconds,
    receiptArchiveDirectory: value.receiptArchiveDirectory,
  };
}

function unsignedAttestation(value) {
  return {
    schemaVersion: value.schemaVersion,
    listenerInstanceID: value.listenerInstanceID,
    publicKey: value.publicKey,
    host: value.host,
    createdAtUnixMilliseconds: value.createdAtUnixMilliseconds,
    receiptArchiveDirectory: value.receiptArchiveDirectory,
  };
}

function normalizeSessionAttestation(value) {
  const client = processIdentity(value.client, 'session client identity');
  return {
    schemaVersion: value.schemaVersion,
    sessionID: uuid(value.sessionID, 'operation session ID'),
    listenerInstanceID: uuid(value.listenerInstanceID, 'session listener instance'),
    listenerKeySHA256: value.listenerPublicKeySHA256,
    clientInstanceID: uuid(value.clientInstanceID, 'session client instance'),
    clientPID: client.pid,
    clientStartIdentity: client.startIdentity,
    clientCodeSignatureHash: client.codeSignatureHash,
    maximumRequestCount: value.maximumRequestCount,
    remainingClaimCount: value.remainingClaimCount,
    predecessorSessionID: value.predecessorSessionID === undefined
      ? null
      : uuid(value.predecessorSessionID, 'predecessor session ID'),
    createdAtMilliseconds: value.createdAtUnixMilliseconds,
  };
}

function unsignedSessionAttestation(value) {
  return {
    schemaVersion: value.schemaVersion,
    sessionID: value.sessionID,
    listenerInstanceID: value.listenerInstanceID,
    listenerPublicKeySHA256: value.listenerPublicKeySHA256,
    clientInstanceID: value.clientInstanceID,
    client: value.client,
    maximumRequestCount: value.maximumRequestCount,
    remainingClaimCount: value.remainingClaimCount,
    ...(value.predecessorSessionID === undefined
      ? {}
      : { predecessorSessionID: value.predecessorSessionID }),
    createdAtUnixMilliseconds: value.createdAtUnixMilliseconds,
  };
}

function normalizeBounds(value) {
  if (!Array.isArray(value) || value.length !== 2
      || !Array.isArray(value[0]) || value[0].length !== 2
      || !Array.isArray(value[1]) || value[1].length !== 2) {
    throw new Error('window receipt capturedBounds must be one encoded CGRect');
  }
  return {
    x: value[0][0],
    y: value[0][1],
    width: value[1][0],
    height: value[1][1],
  };
}

function normalizeTarget(value) {
  if (value === null || value === undefined) return null;
  const target = object(value, 'operation target');
  if (target.kind === 'window') {
    if (typeof target.processStartIdentity !== 'string'
        || !/^[1-9][0-9]*$/.test(target.processStartIdentity)) {
      throw new Error('window target start identity is not a canonical positive decimal string');
    }
    return {
      scope: 'window',
      pid: target.processIdentifier,
      processStartIdentity: target.processStartIdentity,
      windowID: target.windowID,
      bounds: normalizeBounds(target.capturedBounds),
    };
  }
  if (target.kind === 'process') {
    if (typeof target.processStartIdentity !== 'string'
        || !/^[1-9][0-9]*$/.test(target.processStartIdentity)) {
      throw new Error('process target start identity is not a canonical positive decimal string');
    }
    return {
      scope: 'process',
      pid: target.processIdentifier,
      processStartIdentity: target.processStartIdentity,
    };
  }
  if (target.kind === 'global') return { scope: 'global' };
  throw new Error('operation target uses an unknown enum case');
}

function normalizeOutcome(value) {
  if (value === null || value === undefined) return null;
  const outcome = object(value, 'desktop action outcome');
  return {
    state: outcome.state,
    route: outcome.route,
    deliveryMode: outcome.delivery_mode ?? null,
    effect: outcome.effect,
    evidence: outcome.evidence,
    dispatchState: outcome.dispatch_state,
    retrySafety: outcome.retry_safety,
    mutationDispatched: outcome.mutation_dispatched,
    retrySafe: outcome.retry_safe,
  };
}

function normalizeFocusedElement(value) {
  if (value === null || value === undefined) return null;
  const focused = object(value, 'focused element identity');
  return {
    pid: focused.processIdentifier,
    windowID: focused.windowID,
    role: focused.role,
    title: focused.title ?? null,
    identifier: focused.identifier ?? null,
    frame: normalizeBounds(focused.frame),
  };
}

function normalizeAttributionFailure(value, evidence) {
  if (value === null || value === undefined) {
    if (evidence !== null && evidence !== undefined) {
      throw new Error('successful target attribution unexpectedly carries failure evidence');
    }
    return null;
  }
  const failure = object(value, 'target attribution failure');
  if (!Array.isArray(evidence) || evidence.length === 0) {
    throw new Error('target attribution failure is missing its signed evidence set');
  }
  return {
    code: failure.code,
    message: failure.message,
    stage: failure.stage,
    evidenceCount: evidence.length,
    evidenceSHA256: sha256(canonicalBytes(evidence)),
  };
}

function parseCanonicalJSON(bytes, context) {
  let value;
  try {
    value = JSON.parse(bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`${context} is not JSON: ${error.message}`);
  }
  if (!canonicalBytes(value).equals(bytes)) {
    throw new Error(`${context} is not the canonical sorted JSON payload`);
  }
  return value;
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function canonicalPayload(value, expected, context) {
  const bytes = base64(value, context);
  const parsed = parseCanonicalJSON(bytes, context);
  if (!canonicalBytes(parsed).equals(canonicalBytes(expected))) {
    throw new Error(`${context} does not equal the exported object`);
  }
  return bytes;
}

function enumCase(value, context) {
  const envelope = object(value, context);
  const keys = Object.keys(envelope);
  if (keys.length !== 1 || typeof keys[0] !== 'string' || keys[0].length === 0) {
    throw new Error(`${context} must contain exactly one enum case`);
  }
  return keys[0];
}

function associatedValue(value, caseName, context) {
  const associated = object(object(value, context)[caseName], `${context} case`);
  return object(associated._0, `${context} associated value`);
}

function wireFacts(requestBytes, responseBytes) {
  const request = parseCanonicalJSON(requestBytes, 'canonical request');
  const response = parseCanonicalJSON(responseBytes, 'canonical response');
  const requestEnvelopeCase = enumCase(request, 'canonical request');
  const requestValue = requestEnvelopeCase === 'projectedAction'
    ? object(associatedValue(request, requestEnvelopeCase, 'canonical request').request, 'projected request')
    : request;
  const requestCase = enumCase(requestValue, 'operation request');
  const responseEnvelopeCase = enumCase(response, 'canonical response');
  let responseValue = response;
  let responseOutcome = null;
  if (responseEnvelopeCase === 'projectedAction') {
    const projected = associatedValue(response, responseEnvelopeCase, 'canonical response');
    responseValue = object(projected.response, 'projected response');
    responseOutcome = normalizeOutcome(projected.outcome);
  } else if (responseEnvelopeCase === 'error') {
    const envelope = associatedValue(response, responseEnvelopeCase, 'canonical response');
    responseOutcome = normalizeOutcome(envelope.actionOutcome);
  }
  return {
    requestEnvelopeCase,
    requestCase,
    responseEnvelopeCase,
    responseCase: enumCase(responseValue, 'operation response'),
    responseOutcome,
  };
}

function normalizeReceiptPayload(value, facts) {
  const host = processIdentity(value.host, 'receipt Bridge identity');
  const client = processIdentity(value.client, 'receipt client identity');
  return {
    schemaVersion: value.schemaVersion,
    requestID: uuid(value.requestID, 'request ID'),
    sessionID: uuid(value.sessionID, 'receipt session ID'),
    sessionSequence: decimal(value.sessionSequence, 'receipt session sequence'),
    sessionAttestationSHA256: value.sessionAttestationSHA256,
    listenerInstanceID: uuid(value.listenerInstanceID, 'receipt listener instance'),
    listenerKeySHA256: value.listenerPublicKeySHA256,
    clientInstanceID: uuid(value.clientInstanceID, 'receipt client instance'),
    bridgePID: host.pid,
    bridgeStartIdentity: host.startIdentity,
    bridgeCodeSignatureHash: host.codeSignatureHash,
    clientPID: client.pid,
    clientStartIdentity: client.startIdentity,
    clientCodeSignatureHash: client.codeSignatureHash,
    operation: value.operation,
    requestSHA256: value.requestSHA256,
    responseSHA256: value.responseSHA256,
    target: normalizeTarget(value.target),
    focusedElement: normalizeFocusedElement(value.focusedElement),
    attributionFailure: normalizeAttributionFailure(
      value.targetAttributionFailure,
      value.targetAttributionEvidence,
    ),
    outcome: normalizeOutcome(value.outcome),
    remainingClaimCount: value.remainingClaimCount,
    requestEnvelopeCase: facts.requestEnvelopeCase,
    requestCase: facts.requestCase,
    responseEnvelopeCase: facts.responseEnvelopeCase,
    responseCase: facts.responseCase,
    responseOutcome: facts.responseOutcome,
    startedAtMilliseconds: value.startedAtUnixMilliseconds,
    completedAtMilliseconds: value.completedAtUnixMilliseconds,
  };
}

function signature(value, context) {
  return {
    algorithm: 'ed25519',
    bytes: base64(value, context),
  };
}

export function decodeAttestation(document) {
  const bundle = object(document, 'verification bundle');
  const attestation = listenerAttestation(document);
  return {
    normalized: normalizeAttestation(attestation),
    signedBytes: canonicalPayload(
      bundle.canonicalListenerAttestationPayload,
      unsignedAttestation(attestation),
      'canonical listener attestation payload',
    ),
    signature: signature(attestation.signature, 'listener signature'),
  };
}

export function decodeSessionAttestation(document) {
  const bundle = object(document, 'verification bundle');
  const attestation = sessionAttestation(document);
  return {
    normalized: normalizeSessionAttestation(attestation),
    documentBytes: canonicalBytes(attestation),
    signedBytes: canonicalPayload(
      bundle.canonicalSessionAttestationPayload,
      unsignedSessionAttestation(attestation),
      'canonical session attestation payload',
    ),
    signature: signature(attestation.signature, 'operation session signature'),
  };
}

export function decodeReceipt(document) {
  const bundle = object(document, 'verification bundle');
  const receipt = object(bundle.receipt, 'signed operation receipt');
  const payload = object(receipt.payload, 'signed operation payload');
  const requestCanonicalBytes = base64(bundle.canonicalRequest, 'canonical request');
  const responseCanonicalBytes = base64(bundle.canonicalResponse, 'canonical response');
  const facts = wireFacts(requestCanonicalBytes, responseCanonicalBytes);
  return {
    attestation: decodeAttestation(bundle),
    session: decodeSessionAttestation(bundle),
    normalized: normalizeReceiptPayload(payload, facts),
    signedBytes: canonicalPayload(
      bundle.canonicalReceiptPayload,
      payload,
      'canonical receipt payload',
    ),
    signature: signature(receipt.signature, 'operation signature'),
    requestCanonicalBytes,
    responseCanonicalBytes,
  };
}

export function hostAttestationBytes(document) {
  return canonicalBytes(listenerAttestation(document));
}

export function hostReceiptBytes(document) {
  return canonicalBytes(object(object(document, 'verification bundle').receipt, 'signed operation receipt'));
}

export function hostSessionAttestationBytes(document) {
  return canonicalBytes(sessionAttestation(document));
}
