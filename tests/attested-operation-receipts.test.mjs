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

function makeFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'peekaboo-attested-receipts.'));
  const receiptDirectory = path.join(root, 'verified-receipts');
  fs.mkdirSync(receiptDirectory, { mode: 0o700 });
  fs.chmodSync(receiptDirectory, 0o700);
  const socketPath = path.join(root, 'bridge.sock');
  const listenerInstanceID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const listenerArchive = path.join(`${socketPath}.receipts`, listenerInstanceID);
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
      requestID: '11111111-1111-4111-8111-111111111111',
      kind: 'observation',
      operation: 'see',
      client: { pid: 701, startIdentity: '70100123', codeSignatureHash: 'b'.repeat(40) },
      request: { command: 'see', target: ownedTarget },
      response: { success: true, snapshotID: 'fixture' },
      outcome: null,
      startedAtMilliseconds: 2_100,
      completedAtMilliseconds: 2_200,
    },
    {
      requestID: '22222222-2222-4222-8222-222222222222',
      kind: 'mutation',
      operation: 'type',
      client: { pid: 702, startIdentity: '70200123', codeSignatureHash: 'c'.repeat(40) },
      request: { command: 'type', target: ownedTarget, textDigest: 'fixture' },
      response: { success: true, effect: 'confirmed' },
      outcome: {
        deliveryMode: 'background',
        effect: 'confirmed',
        mutationDispatched: true,
        retrySafe: false,
      },
      startedAtMilliseconds: 2_300,
      completedAtMilliseconds: 2_400,
    },
  ];
  const contract = {
    version: 1,
    certificationRunID: 'coexistence-fixture',
    adapter: {
      id: adapter.adapterID,
      sha256: sha256(fs.readFileSync(canonicalAdapterPath)),
    },
    protocol: { major: 1, minor: 29 },
    socketEndpoint: { path: socketPath, device: '16777233', inode: '99123' },
    listener,
    ownedTarget,
    foregroundTarget,
    interval: { startedAtMilliseconds: 2_000, completedAtMilliseconds: 3_000 },
    expectedOperations: requests.map((request) => ({
      operationID: `${request.kind}-${request.operation}`,
      requestID: request.requestID,
      kind: request.kind,
      operation: request.operation,
      client: request.client,
      requestSHA256: sha256(canonicalBytes(request.request)),
      responseSHA256: sha256(canonicalBytes(request.response)),
      target: ownedTarget,
      outcome: request.outcome,
    })),
  };
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
  const receiptDocuments = requests.map((request) => {
    const requestBytes = canonicalBytes(request.request);
    const responseBytes = canonicalBytes(request.response);
    const payload = {
      schemaVersion: 1,
      requestID: request.requestID,
      listenerInstanceID,
      listenerKeySHA256: listener.signingPublicKeySHA256,
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
      outcome: request.outcome,
      startedAtMilliseconds: request.startedAtMilliseconds,
      completedAtMilliseconds: request.completedAtMilliseconds,
    };
    return {
      payload,
      requestCanonicalBase64: requestBytes.toString('base64'),
      responseCanonicalBase64: responseBytes.toString('base64'),
      signature: signature(payload),
    };
  });
  for (const document of receiptDocuments) {
    const receiptPath = path.join(receiptDirectory, `${document.payload.requestID}.json`);
    fs.writeFileSync(receiptPath, `${JSON.stringify(document)}\n`, { mode: 0o600 });
    fs.chmodSync(receiptPath, 0o600);
  }
  return {
    root,
    receiptDirectory,
    contract,
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
      processStartIdentity: Number(fixture.contract.listener.bridgeStartIdentity),
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
    const targetReceipt = {
      window: {
        _0: {
          capturedBounds: [
            [normalized.target.bounds.x, normalized.target.bounds.y],
            [normalized.target.bounds.width, normalized.target.bounds.height],
          ],
          isMinimized: false,
          ownerProcessIdentifier: normalized.target.pid,
          ownerProcessStartIdentity: Number(normalized.target.processStartIdentity),
          windowID: normalized.target.windowID,
        },
      },
    };
    const outcome = normalized.outcome === null ? null : {
      state: 'confirmed_change',
      effect: normalized.outcome.effect,
      route: 'bridge',
      delivery_mechanism: 'process_targeted_events',
      delivery_mode: normalized.outcome.deliveryMode,
      evidence: 'verified_change',
      dispatch_state: 'dispatched',
      dispatched_unit_count: 1,
      retry_safety: 'unsafe',
      escalation: 'none',
      mutation_dispatched: normalized.outcome.mutationDispatched,
      retry_safe: normalized.outcome.retrySafe,
      requires_fresh_observation: true,
    };
    const rawPayload = {
      schemaVersion: 1,
      requestID: normalized.requestID.toUpperCase(),
      listenerInstanceID: normalized.listenerInstanceID.toUpperCase(),
      listenerPublicKeySHA256: normalized.listenerKeySHA256,
      host: {
        processIdentifier: normalized.bridgePID,
        processStartIdentity: Number(normalized.bridgeStartIdentity),
        codeSignatureHash: normalized.bridgeCodeSignatureHash,
      },
      client: {
        processIdentifier: normalized.clientPID,
        processStartIdentity: Number(normalized.clientStartIdentity),
        codeSignatureHash: normalized.clientCodeSignatureHash,
      },
      operation: normalized.operation,
      requestSHA256: normalized.requestSHA256,
      responseSHA256: normalized.responseSHA256,
      target: targetReceipt,
      outcome,
      startedAtUnixMilliseconds: normalized.startedAtMilliseconds,
      completedAtUnixMilliseconds: normalized.completedAtMilliseconds,
    };
    const bundle = {
      operationAttestation: signedAttestation,
      receipt: {
        payload: rawPayload,
        signature: signature(rawPayload).value,
      },
      canonicalRequest: document.requestCanonicalBase64,
      canonicalResponse: document.responseCanonicalBase64,
    };
    const receiptPath = path.join(
      fixture.receiptDirectory,
      `${fixture.contract.expectedOperations[index].requestID}.json`,
    );
    fs.writeFileSync(receiptPath, `${JSON.stringify(bundle)}\n`, { mode: 0o600 });
    fs.chmodSync(receiptPath, 0o600);
    return bundle;
  });
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
  });
}

function rules(result) {
  return new Set(result.failures.map((entry) => entry.rule));
}

function writeReceipt(fixture, index, { resign = true } = {}) {
  const document = fixture.receiptDocuments[index];
  if (resign) document.signature = signature(document.payload);
  const receiptPath = path.join(fixture.receiptDirectory, `${fixture.contract.expectedOperations[index].requestID}.json`);
  fs.writeFileSync(receiptPath, `${JSON.stringify(document)}\n`, { mode: 0o600 });
  fs.chmodSync(receiptPath, 0o600);
}

test('accepts exact signed receipts for one isolated background target', async (t) => {
  const fixture = makeFixture();
  t.after(fixture.cleanup);
  const result = await validate(fixture);
  assert.equal(result.success, true);
  assert.deepEqual(result.failures, []);
  assert.deepEqual(result.receipts.map((entry) => entry.request_id), [
    '11111111-1111-4111-8111-111111111111',
    '22222222-2222-4222-8222-222222222222',
  ]);
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
  const receiptPath = path.join(
    tampered.receiptDirectory,
    `${tampered.contract.expectedOperations[0].requestID}.json`,
  );
  fs.writeFileSync(receiptPath, `${JSON.stringify(tampered.receiptDocuments[0])}\n`, { mode: 0o600 });
  fs.chmodSync(receiptPath, 0o600);
  assert.ok(rules(await validate(tampered, bridgeBundleAdapter, bridgeBundleAdapterPath)).has('response_digest'));
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

test('missing receipt is an indeterminate retry-unsafe lost response', async (t) => {
  const fixture = makeFixture();
  t.after(fixture.cleanup);
  fs.unlinkSync(path.join(fixture.receiptDirectory, '22222222-2222-4222-8222-222222222222.json'));
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
  assert.deepEqual(result.receipts.map((entry) => entry.operation_id), ['observation-see', 'mutation-type']);

  const missing = makeFixture();
  t.after(missing.cleanup);
  missing.contract.expectedOperations.forEach((entry) => { entry.requestID = null; });
  fs.unlinkSync(path.join(missing.receiptDirectory, '22222222-2222-4222-8222-222222222222.json'));
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
  writeReceipt(targetFixture, 1);
  const targetResult = await validate(targetFixture);
  assert.ok(rules(targetResult).has('receipt_contract'));
  assert.ok(rules(targetResult).has('target_ownership'));

  const modeFixture = makeFixture();
  t.after(modeFixture.cleanup);
  modeFixture.receiptDocuments[1].payload.outcome.deliveryMode = 'foreground';
  writeReceipt(modeFixture, 1);
  const modeResult = await validate(modeFixture);
  assert.ok(rules(modeResult).has('receipt_schema'));
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
    '11111111-1111-4111-8111-111111111111.json',
  ), 0o644);
  assert.ok(rules(await validate(fileFixture)).has('archive_permissions'));

  const extraFixture = makeFixture();
  t.after(extraFixture.cleanup);
  fs.writeFileSync(path.join(extraFixture.receiptDirectory, 'partial.tmp'), '{}', { mode: 0o600 });
  assert.ok(rules(await validate(extraFixture)).has('archive_completeness'));
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
});

test('adapter boundary is explicit and versioned', async (t) => {
  const fixture = makeFixture();
  t.after(fixture.cleanup);
  const result = await validate(fixture, { adapterAPIVersion: 2, adapterID: 'future' });
  assert.equal(result.success, false);
  assert.ok(rules(result).has('adapter_contract'));

  const identityFixture = makeFixture();
  t.after(identityFixture.cleanup);
  identityFixture.contract.adapter.sha256 = '0'.repeat(64);
  assert.ok(rules(await validate(identityFixture)).has('adapter_identity'));
});
