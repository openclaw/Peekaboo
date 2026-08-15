import { canonicalBytes } from '../validate-attested-operation-receipts.mjs';

export const adapterAPIVersion = 1;
export const adapterID = 'canonical-attested-operation-receipts-v1';

function decodeSignature(value, context) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || value.algorithm !== 'ed25519' || typeof value.value !== 'string') {
    throw new Error(`${context} has no Ed25519 signature`);
  }
  return {
    algorithm: value.algorithm,
    bytes: Buffer.from(value.value, 'base64'),
  };
}

export function decodeAttestation(document) {
  return {
    normalized: document?.payload,
    signedBytes: canonicalBytes(document?.payload),
    signature: decodeSignature(document?.signature, 'listener attestation'),
  };
}

export function decodeReceipt(document) {
  if (typeof document?.requestCanonicalBase64 !== 'string'
      || typeof document?.responseCanonicalBase64 !== 'string') {
    throw new Error('operation receipt is missing canonical request or response bytes');
  }
  return {
    normalized: document?.payload,
    signedBytes: canonicalBytes(document?.payload),
    signature: decodeSignature(document?.signature, 'operation receipt'),
    requestCanonicalBytes: Buffer.from(document.requestCanonicalBase64, 'base64'),
    responseCanonicalBytes: Buffer.from(document.responseCanonicalBase64, 'base64'),
  };
}
