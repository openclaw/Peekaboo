import { canonicalBytes } from '../validate-attested-operation-receipts.mjs';

export const adapterAPIVersion = 1;
export const adapterID = 'peekaboo-bridge-operation-receipt-bundle-1.29';

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

function processIdentity(value, context) {
  const identity = object(value, context);
  return {
    pid: identity.processIdentifier,
    startIdentity: String(identity.processStartIdentity),
    codeSignatureHash: identity.codeSignatureHash,
  };
}

function listenerAttestation(document) {
  const root = object(document, 'verification bundle');
  return object(root.operationAttestation ?? root, 'operation attestation');
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
  const target = object(value, 'operation target');
  if (target.window) {
    const window = object(object(target.window, 'window target')._0, 'window receipt');
    return {
      scope: 'window',
      pid: window.ownerProcessIdentifier,
      processStartIdentity: String(window.ownerProcessStartIdentity),
      windowID: window.windowID,
      bounds: normalizeBounds(window.capturedBounds),
    };
  }
  if (target.process) {
    const process = processIdentity(object(target.process, 'process target')._0, 'process receipt');
    return { scope: 'process', pid: process.pid, processStartIdentity: process.startIdentity };
  }
  if (target.global) return { scope: 'global' };
  throw new Error('operation target uses an unknown enum case');
}

function normalizeOutcome(value) {
  if (value === null || value === undefined) return null;
  const outcome = object(value, 'desktop action outcome');
  return {
    deliveryMode: outcome.delivery_mode,
    effect: outcome.effect,
    mutationDispatched: outcome.mutation_dispatched,
    retrySafe: outcome.retry_safe,
  };
}

function normalizeReceiptPayload(value) {
  const host = processIdentity(value.host, 'receipt Bridge identity');
  const client = processIdentity(value.client, 'receipt client identity');
  return {
    schemaVersion: value.schemaVersion,
    requestID: uuid(value.requestID, 'request ID'),
    listenerInstanceID: uuid(value.listenerInstanceID, 'receipt listener instance'),
    listenerKeySHA256: value.listenerPublicKeySHA256,
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
    outcome: normalizeOutcome(value.outcome),
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
  const attestation = listenerAttestation(document);
  return {
    normalized: normalizeAttestation(attestation),
    signedBytes: canonicalBytes(unsignedAttestation(attestation)),
    signature: signature(attestation.signature, 'listener signature'),
  };
}

export function decodeReceipt(document) {
  const bundle = object(document, 'verification bundle');
  const receipt = object(bundle.receipt, 'signed operation receipt');
  const payload = object(receipt.payload, 'signed operation payload');
  return {
    normalized: normalizeReceiptPayload(payload),
    signedBytes: canonicalBytes(payload),
    signature: signature(receipt.signature, 'operation signature'),
    requestCanonicalBytes: base64(bundle.canonicalRequest, 'canonical request'),
    responseCanonicalBytes: base64(bundle.canonicalResponse, 'canonical response'),
  };
}
