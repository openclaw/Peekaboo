#!/usr/bin/env node

import {
  createHash,
  createPublicKey,
  verify as verifySignature,
} from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const HEX40 = /^[0-9a-f]{40}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const DECIMAL_IDENTITY = /^[1-9][0-9]*$/;
const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const RETAINED_LISTENER_DIRECTORY_LIMIT = 16;

function failure(rule, message, requestID = null) {
  return { rule, message, request_id: requestID };
}

function isPlainObject(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function exactKeys(value, expected) {
  if (!isPlainObject(value)) return false;
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  return actual.length === wanted.length
    && actual.every((key, index) => key === wanted[index]);
}

function canonicalValue(value) {
  if (value === null || typeof value === 'boolean' || typeof value === 'string') return value;
  if (typeof value === 'number') {
    if (!Number.isFinite(value) || Object.is(value, -0)
        || (Number.isInteger(value) && !Number.isSafeInteger(value))) {
      throw new TypeError('canonical JSON only accepts finite, lossless, non-negative-zero numbers');
    }
    return value;
  }
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (!isPlainObject(value)) throw new TypeError('canonical JSON only accepts plain JSON values');
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonicalValue(value[key])]));
}

export function canonicalBytes(value) {
  return Buffer.from(JSON.stringify(canonicalValue(value)), 'utf8');
}

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

function positiveInteger(value) {
  return Number.isSafeInteger(value) && value > 0;
}

function safeMilliseconds(value) {
  return Number.isSafeInteger(value) && value > 0;
}

function validProcess(value) {
  return exactKeys(value, ['pid', 'startIdentity', 'codeSignatureHash'])
    && positiveInteger(value.pid)
    && typeof value.startIdentity === 'string'
    && DECIMAL_IDENTITY.test(value.startIdentity)
    && typeof value.codeSignatureHash === 'string'
    && HEX40.test(value.codeSignatureHash);
}

function validBounds(value) {
  return exactKeys(value, ['x', 'y', 'width', 'height'])
    && [value.x, value.y, value.width, value.height].every(Number.isFinite)
    && value.width > 0 && value.height > 0;
}

function validTarget(value) {
  return exactKeys(value, ['scope', 'pid', 'processStartIdentity', 'windowID', 'bounds'])
    && value.scope === 'window'
    && positiveInteger(value.pid)
    && typeof value.processStartIdentity === 'string'
    && DECIMAL_IDENTITY.test(value.processStartIdentity)
    && positiveInteger(value.windowID)
    && value.windowID <= 0xffff_ffff
    && validBounds(value.bounds);
}

function validFocusedElement(value) {
  return exactKeys(value, ['pid', 'windowID', 'role', 'title', 'identifier', 'frame'])
    && positiveInteger(value.pid)
    && positiveInteger(value.windowID) && value.windowID <= 0xffff_ffff
    && typeof value.role === 'string' && value.role.length > 0
    && (value.title === null || typeof value.title === 'string')
    && (value.identifier === null || typeof value.identifier === 'string')
    && validBounds(value.frame);
}

function sameJSON(left, right) {
  try {
    return canonicalBytes(left).equals(canonicalBytes(right));
  } catch {
    return false;
  }
}

function validOutcomeShape(value) {
  return exactKeys(value, [
    'state', 'route', 'deliveryMode', 'effect', 'evidence', 'dispatchState', 'retrySafety',
    'mutationDispatched', 'retrySafe',
  ])
    && typeof value.state === 'string' && value.state.length > 0
    && value.route === 'bridge'
    && (value.deliveryMode === null || ['background', 'foreground'].includes(value.deliveryMode))
    && typeof value.effect === 'string' && value.effect.length > 0
    && typeof value.evidence === 'string' && value.evidence.length > 0
    && typeof value.dispatchState === 'string' && value.dispatchState.length > 0
    && typeof value.retrySafety === 'string' && value.retrySafety.length > 0
    && typeof value.mutationDispatched === 'boolean'
    && typeof value.retrySafe === 'boolean';
}

function validSuccessfulOutcome(value) {
  return validOutcomeShape(value)
    && value.deliveryMode === 'background'
    && ['confirmed', 'unverifiable'].includes(value.effect)
    && value.mutationDispatched === true
    && value.retrySafe === false;
}

function validAttributionFailure(value) {
  return exactKeys(value, ['code', 'message', 'stage', 'evidenceCount', 'evidenceSHA256'])
    && typeof value.code === 'string' && value.code.length > 0
    && typeof value.message === 'string' && value.message.length > 0
    && ['pre_dispatch', 'post_execution'].includes(value.stage)
    && positiveInteger(value.evidenceCount)
    && typeof value.evidenceSHA256 === 'string' && HEX64.test(value.evidenceSHA256);
}

function validAttributionFailureOutcome(failure, outcome) {
  if (!validAttributionFailure(failure) || !validOutcomeShape(outcome)) return false;
  if (failure.stage === 'pre_dispatch') {
    return outcome.state === 'refused'
      && outcome.evidence === 'request_refused'
      && outcome.dispatchState === 'none'
      && outcome.retrySafety === 'safe'
      && outcome.mutationDispatched === false
      && outcome.retrySafe === true;
  }
  return outcome.state === 'indeterminate'
    && outcome.evidence === 'completion_unknown'
    && ['dispatched', 'may_have_dispatched'].includes(outcome.dispatchState)
    && outcome.retrySafety === 'unsafe'
    && outcome.mutationDispatched === true
    && outcome.retrySafe === false;
}

function publicKeyFromRaw(rawKey) {
  if (!Buffer.isBuffer(rawKey) || rawKey.length !== 32) {
    throw new Error('listener signing public key must be exactly 32 bytes');
  }
  return createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, rawKey]),
    format: 'der',
    type: 'spki',
  });
}

function verifyEd25519(bytes, signature, rawKey) {
  return signature?.algorithm === 'ed25519'
    && Buffer.isBuffer(signature.bytes)
    && signature.bytes.length === 64
    && verifySignature(null, bytes, publicKeyFromRaw(rawKey), signature.bytes);
}

function validateContract(contract) {
  const failures = [];
  if (!exactKeys(contract, [
    'version', 'certificationRunID', 'adapter', 'protocolImplementation', 'protocol',
    'socketEndpoint', 'listener', 'hostArchive', 'ownedTarget', 'foregroundTarget',
    'interval', 'expectedOperations',
  ]) || contract.version !== 2) {
    return [failure('contract_schema', 'Contract must be one closed version-2 object')];
  }
  if (typeof contract.certificationRunID !== 'string' || contract.certificationRunID.length === 0) {
    failures.push(failure('contract_run', 'Certification run ID must be nonempty'));
  }
  if (!exactKeys(contract.adapter, ['id', 'sha256'])
      || typeof contract.adapter.id !== 'string' || contract.adapter.id.length === 0
      || typeof contract.adapter.sha256 !== 'string' || !HEX64.test(contract.adapter.sha256)) {
    failures.push(failure('contract_adapter', 'Contract must pin one exact adapter ID and source digest'));
  }
  if (!exactKeys(contract.protocolImplementation, [
    'sourceCommit', 'sourceTree', 'peerBinding', 'operationReceiptsSHA256',
    'socketIOSHA256', 'hostClientsSHA256', 'privateArchiveSHA256',
  ]) || typeof contract.protocolImplementation.sourceCommit !== 'string'
      || !/^[0-9a-f]{40}$/.test(contract.protocolImplementation.sourceCommit)
      || typeof contract.protocolImplementation.sourceTree !== 'string'
      || !/^[0-9a-f]{40}$/.test(contract.protocolImplementation.sourceTree)
      || contract.protocolImplementation.peerBinding !== 'darwin-audit-token-pidversion-euid-cdhash-v1'
      || ['operationReceiptsSHA256', 'socketIOSHA256', 'hostClientsSHA256', 'privateArchiveSHA256']
        .some((key) => typeof contract.protocolImplementation[key] !== 'string'
          || !HEX64.test(contract.protocolImplementation[key]))) {
    failures.push(failure(
      'contract_protocol_implementation',
      'Contract must pin the audited Darwin peer-binding implementation and source hashes',
    ));
  }
  if (!exactKeys(contract.protocol, ['major', 'minor'])
      || contract.protocol.major !== 1 || contract.protocol.minor < 29
      || !Number.isSafeInteger(contract.protocol.minor)) {
    failures.push(failure('contract_protocol', 'Coexistence certification requires Bridge protocol 1.29 or newer'));
  }
  if (!exactKeys(contract.socketEndpoint, ['path', 'device', 'inode'])
      || typeof contract.socketEndpoint.path !== 'string' || !path.isAbsolute(contract.socketEndpoint.path)
      || typeof contract.socketEndpoint.device !== 'string'
      || !DECIMAL_IDENTITY.test(contract.socketEndpoint.device)
      || typeof contract.socketEndpoint.inode !== 'string'
      || !DECIMAL_IDENTITY.test(contract.socketEndpoint.inode)) {
    failures.push(failure('contract_socket', 'Socket endpoint must bind an absolute path and exact device/inode'));
  }
  const listener = contract.listener;
  if (!exactKeys(listener, [
    'instanceID', 'signingPublicKeyBase64', 'signingPublicKeySHA256', 'bridgePID',
    'bridgeStartIdentity', 'bridgeCodeSignatureHash', 'createdAtMilliseconds', 'receiptArchiveDirectory',
  ]) || typeof listener.instanceID !== 'string' || !UUID.test(listener.instanceID)
      || typeof listener.signingPublicKeyBase64 !== 'string'
      || !BASE64.test(listener.signingPublicKeyBase64)
      || Buffer.from(listener.signingPublicKeyBase64, 'base64').length !== 32
      || typeof listener.signingPublicKeySHA256 !== 'string'
      || !HEX64.test(listener.signingPublicKeySHA256)
      || sha256(Buffer.from(listener.signingPublicKeyBase64, 'base64')) !== listener.signingPublicKeySHA256
      || !positiveInteger(listener.bridgePID)
      || typeof listener.bridgeStartIdentity !== 'string'
      || !DECIMAL_IDENTITY.test(listener.bridgeStartIdentity)
      || typeof listener.bridgeCodeSignatureHash !== 'string'
      || !HEX40.test(listener.bridgeCodeSignatureHash)
      || !safeMilliseconds(listener.createdAtMilliseconds)
      || typeof listener.receiptArchiveDirectory !== 'string'
      || !path.isAbsolute(listener.receiptArchiveDirectory)) {
    failures.push(failure('contract_listener', 'Listener contract is malformed or its public-key digest is wrong'));
  }
  const expectedSocketNamespace = typeof contract.socketEndpoint?.path === 'string'
    ? sha256(Buffer.from(contract.socketEndpoint.path, 'utf8'))
    : null;
  const hostArchive = contract.hostArchive;
  if (!exactKeys(hostArchive, [
    'temporaryRoot', 'rootDirectory', 'socketNamespaceSHA256', 'listenerDirectoryLimit',
    'attestationFileSHA256',
  ]) || typeof hostArchive.temporaryRoot !== 'string' || !path.isAbsolute(hostArchive.temporaryRoot)
      || typeof hostArchive.rootDirectory !== 'string' || !path.isAbsolute(hostArchive.rootDirectory)
      || hostArchive.socketNamespaceSHA256 !== expectedSocketNamespace
      || path.basename(hostArchive.rootDirectory) !== expectedSocketNamespace
      || path.basename(path.dirname(hostArchive.rootDirectory)) !== 'PeekabooOperationReceipts'
      || path.dirname(path.dirname(hostArchive.rootDirectory)) !== hostArchive.temporaryRoot
      || hostArchive.listenerDirectoryLimit !== RETAINED_LISTENER_DIRECTORY_LIMIT
      || typeof hostArchive.attestationFileSHA256 !== 'string'
      || !HEX64.test(hostArchive.attestationFileSHA256)) {
    failures.push(failure(
      'contract_archive_namespace',
      'Host archive must use the private hashed socket namespace and bounded retention contract',
    ));
  }
  if (listener?.receiptArchiveDirectory !== path.join(
    hostArchive?.rootDirectory ?? '',
    listener?.instanceID ?? '',
  )) {
    failures.push(failure('contract_archive_route', 'Listener archive is not bound to its hashed socket namespace'));
  }
  if (!validTarget(contract.ownedTarget) || !validTarget(contract.foregroundTarget)) {
    failures.push(failure('contract_targets', 'Owned and foreground targets must be exact window-generation receipts'));
  } else if (contract.ownedTarget.pid === contract.foregroundTarget.pid
      || contract.ownedTarget.windowID === contract.foregroundTarget.windowID
      || (contract.ownedTarget.pid === contract.foregroundTarget.pid
        && contract.ownedTarget.processStartIdentity === contract.foregroundTarget.processStartIdentity)) {
    failures.push(failure('contract_target_isolation', 'Peekaboo and foreground controllers must own distinct targets'));
  }
  if (!exactKeys(contract.interval, ['startedAtMilliseconds', 'completedAtMilliseconds'])
      || !safeMilliseconds(contract.interval.startedAtMilliseconds)
      || !safeMilliseconds(contract.interval.completedAtMilliseconds)
      || contract.interval.completedAtMilliseconds <= contract.interval.startedAtMilliseconds
      || listener?.createdAtMilliseconds > contract.interval.startedAtMilliseconds) {
    failures.push(failure('contract_interval', 'Certification interval is malformed or predates the listener'));
  }
  if (!Array.isArray(contract.expectedOperations) || contract.expectedOperations.length === 0) {
    failures.push(failure('contract_operations', 'At least one expected operation is required'));
  } else {
    const operationIDs = contract.expectedOperations.map((entry) => entry?.operationID);
    const requestIDs = contract.expectedOperations.map((entry) => entry?.requestID)
      .filter((requestID) => requestID !== null);
    if (new Set(operationIDs).size !== operationIDs.length
        || new Set(requestIDs).size !== requestIDs.length) {
      failures.push(failure('contract_operations', 'Expected operation and known request IDs must be unique'));
    }
    contract.expectedOperations.forEach((entry) => {
      if (!exactKeys(entry, [
        'operationID', 'requestID', 'kind', 'operation', 'requestEnvelopeCase', 'requestCase',
        'responseEnvelopeCase', 'responseCase', 'targetRequired', 'client', 'requestSHA256',
        'responseSHA256', 'target', 'focusedElement', 'attributionFailure', 'outcome',
      ]) || typeof entry.operationID !== 'string' || entry.operationID.length === 0
          || (entry.requestID !== null
            && (typeof entry.requestID !== 'string' || !UUID.test(entry.requestID)))
          || !['observation', 'mutation'].includes(entry.kind)
          || typeof entry.operation !== 'string' || entry.operation.length === 0
          || typeof entry.requestEnvelopeCase !== 'string' || entry.requestEnvelopeCase.length === 0
          || typeof entry.requestCase !== 'string' || entry.requestCase.length === 0
          || typeof entry.responseEnvelopeCase !== 'string' || entry.responseEnvelopeCase.length === 0
          || typeof entry.responseCase !== 'string' || entry.responseCase.length === 0
          || entry.targetRequired !== true
          || !validProcess(entry.client)
          || typeof entry.requestSHA256 !== 'string' || !HEX64.test(entry.requestSHA256)
          || typeof entry.responseSHA256 !== 'string' || !HEX64.test(entry.responseSHA256)
          || !sameJSON(entry.target, contract.ownedTarget)
          || (entry.focusedElement !== null && !validFocusedElement(entry.focusedElement))
          || entry.attributionFailure !== null
          || (entry.kind === 'observation' ? entry.outcome !== null : !validSuccessfulOutcome(entry.outcome))
          || (entry.kind === 'mutation'
            && (entry.requestEnvelopeCase !== 'projectedAction'
              || entry.responseEnvelopeCase !== 'projectedAction'))) {
        failures.push(failure(
          'contract_operation',
          `Expected operation ${entry?.operationID ?? 'unknown'} is malformed or escapes the owned target`,
          entry?.requestID ?? null,
        ));
      }
    });
  }
  return failures;
}

function validateAttestation(attestation, contract, failures) {
  const value = attestation?.normalized;
  if (!exactKeys(value, [
    'schemaVersion', 'listenerInstanceID', 'signingPublicKeyBase64', 'bridgePID',
    'bridgeStartIdentity', 'bridgeCodeSignatureHash', 'createdAtMilliseconds', 'receiptArchiveDirectory',
  ]) || value.schemaVersion !== 1
      || value.listenerInstanceID !== contract.listener.instanceID
      || value.signingPublicKeyBase64 !== contract.listener.signingPublicKeyBase64
      || value.bridgePID !== contract.listener.bridgePID
      || value.bridgeStartIdentity !== contract.listener.bridgeStartIdentity
      || value.bridgeCodeSignatureHash !== contract.listener.bridgeCodeSignatureHash
      || value.createdAtMilliseconds !== contract.listener.createdAtMilliseconds
      || value.receiptArchiveDirectory !== contract.listener.receiptArchiveDirectory) {
    failures.push(failure('listener_attestation', 'Listener attestation does not equal the pinned handshake contract'));
  }
  try {
    const rawKey = Buffer.from(contract.listener.signingPublicKeyBase64, 'base64');
    if (!verifyEd25519(attestation.signedBytes, attestation.signature, rawKey)) {
      failures.push(failure('listener_signature', 'Listener self-signature is invalid'));
    }
  } catch (error) {
    failures.push(failure('listener_signature', `Listener signature could not be verified: ${error.message}`));
  }
}

function validateSocketEvidence(evidence, contract, failures) {
  if (!exactKeys(evidence, ['path', 'device', 'inode', 'isSocket', 'isSymbolicLink'])
      || evidence.path !== contract.socketEndpoint.path
      || evidence.device !== contract.socketEndpoint.device
      || evidence.inode !== contract.socketEndpoint.inode
      || evidence.isSocket !== true || evidence.isSymbolicLink !== false) {
    failures.push(failure(
      'socket_endpoint',
      'Live socket evidence does not equal the run-pinned path/device/inode',
    ));
  }
}

function validateSourceEvidence(evidence, contract, failures) {
  const expected = contract.protocolImplementation;
  if (!exactKeys(evidence, [
    'sourceCommit', 'sourceTree', 'peerBinding', 'operationReceiptsSHA256',
    'socketIOSHA256', 'hostClientsSHA256', 'privateArchiveSHA256',
  ]) || !sameJSON(evidence, expected)) {
    failures.push(failure(
      'protocol_implementation',
      'Checked-out protocol owner files differ from the run-pinned audited implementation',
    ));
  }
}

function validateReceipt(receipt, expected, contract, rawKey, failures) {
  const value = receipt?.normalized;
  const requestID = value?.requestID ?? expected?.requestID ?? null;
  if (!exactKeys(value, [
    'schemaVersion', 'requestID', 'listenerInstanceID', 'listenerKeySHA256',
    'bridgePID', 'bridgeStartIdentity', 'bridgeCodeSignatureHash',
    'clientPID', 'clientStartIdentity', 'clientCodeSignatureHash',
    'operation', 'requestSHA256', 'responseSHA256', 'target', 'focusedElement',
    'attributionFailure', 'outcome', 'requestEnvelopeCase', 'requestCase',
    'responseEnvelopeCase', 'responseCase', 'responseOutcome',
    'startedAtMilliseconds', 'completedAtMilliseconds',
  ]) || value.schemaVersion !== 1 || typeof value.requestID !== 'string' || !UUID.test(value.requestID)
      || value.listenerInstanceID !== contract.listener.instanceID
      || value.listenerKeySHA256 !== contract.listener.signingPublicKeySHA256
      || value.bridgePID !== contract.listener.bridgePID
      || value.bridgeStartIdentity !== contract.listener.bridgeStartIdentity
      || value.bridgeCodeSignatureHash !== contract.listener.bridgeCodeSignatureHash
      || !positiveInteger(value.clientPID)
      || typeof value.clientStartIdentity !== 'string'
      || !DECIMAL_IDENTITY.test(value.clientStartIdentity)
      || typeof value.clientCodeSignatureHash !== 'string'
      || !HEX40.test(value.clientCodeSignatureHash)
      || typeof value.operation !== 'string' || value.operation.length === 0
      || typeof value.requestSHA256 !== 'string' || !HEX64.test(value.requestSHA256)
      || typeof value.responseSHA256 !== 'string' || !HEX64.test(value.responseSHA256)
      || (value.target !== null && !validTarget(value.target))
      || (value.focusedElement !== null && !validFocusedElement(value.focusedElement))
      || (value.attributionFailure !== null && !validAttributionFailure(value.attributionFailure))
      || ((value.target === null) === (value.attributionFailure === null))
      || (value.focusedElement !== null
        && (value.target === null || value.focusedElement.pid !== value.target.pid
          || value.focusedElement.windowID !== value.target.windowID))
      || (value.outcome !== null && !validOutcomeShape(value.outcome))
      || typeof value.requestEnvelopeCase !== 'string' || value.requestEnvelopeCase.length === 0
      || typeof value.requestCase !== 'string' || value.requestCase.length === 0
      || typeof value.responseEnvelopeCase !== 'string' || value.responseEnvelopeCase.length === 0
      || typeof value.responseCase !== 'string' || value.responseCase.length === 0
      || !sameJSON(value.responseOutcome, value.outcome)
      || !safeMilliseconds(value.startedAtMilliseconds)
      || !safeMilliseconds(value.completedAtMilliseconds)
      || value.completedAtMilliseconds < value.startedAtMilliseconds) {
    failures.push(failure('receipt_schema', 'Attested operation receipt is malformed', requestID));
    return;
  }
  try {
    if (!verifyEd25519(receipt.signedBytes, receipt.signature, rawKey)) {
      failures.push(failure('receipt_signature', 'Operation receipt signature is invalid', requestID));
    }
  } catch (error) {
    failures.push(failure('receipt_signature', `Operation signature could not be verified: ${error.message}`, requestID));
  }
  if (!Buffer.isBuffer(receipt.requestCanonicalBytes)
      || sha256(receipt.requestCanonicalBytes) !== value.requestSHA256) {
    failures.push(failure('request_digest', 'Canonical request bytes do not match the signed digest', requestID));
  }
  if (!Buffer.isBuffer(receipt.responseCanonicalBytes)
      || sha256(receipt.responseCanonicalBytes) !== value.responseSHA256) {
    failures.push(failure('response_digest', 'Canonical response bytes do not match the signed digest', requestID));
  }
  if (!expected) {
    failures.push(failure('unexpected_receipt', 'Archive contains an unclaimed operation receipt', requestID));
    return;
  }
  if ((expected.requestID !== null && value.requestID !== expected.requestID)
      || value.operation !== expected.operation
      || value.requestEnvelopeCase !== expected.requestEnvelopeCase
      || value.requestCase !== expected.requestCase
      || value.responseEnvelopeCase !== expected.responseEnvelopeCase
      || value.responseCase !== expected.responseCase
      || value.clientPID !== expected.client.pid
      || value.clientStartIdentity !== expected.client.startIdentity
      || value.clientCodeSignatureHash !== expected.client.codeSignatureHash
      || value.requestSHA256 !== expected.requestSHA256
      || value.responseSHA256 !== expected.responseSHA256
      || !sameJSON(value.target, expected.target)
      || !sameJSON(value.focusedElement, expected.focusedElement)
      || !sameJSON(value.attributionFailure, expected.attributionFailure)
      || !sameJSON(value.outcome, expected.outcome)) {
    failures.push(failure('receipt_contract', 'Receipt differs from the exact requested operation', requestID));
  }
  if (value.attributionFailure !== null) {
    failures.push(failure(
      'attribution_failure',
      `Operation target attribution failed at ${value.attributionFailure.stage}`,
      requestID,
    ));
    if (expected.kind === 'mutation'
        && !validAttributionFailureOutcome(value.attributionFailure, value.outcome)) {
      failures.push(failure(
        'attribution_semantics',
        'Target attribution failure stage/evidence contradicts its action outcome',
        requestID,
      ));
    }
  }
  if (expected.targetRequired !== true || !sameJSON(value.target, contract.ownedTarget)
      || sameJSON(value.target, contract.foregroundTarget)) {
    failures.push(failure('target_ownership', 'Peekaboo receipt is not isolated to its owned target', requestID));
  }
  if (expected.kind === 'mutation' && !validSuccessfulOutcome(value.outcome)) {
    failures.push(failure('background_outcome', 'Mutation lacks a retry-unsafe background outcome', requestID));
  }
  if (expected.kind === 'observation' && value.outcome !== null) {
    failures.push(failure('observation_outcome', 'Observation unexpectedly carries a mutation outcome', requestID));
  }
  if (value.startedAtMilliseconds < contract.interval.startedAtMilliseconds
      || value.completedAtMilliseconds > contract.interval.completedAtMilliseconds) {
    failures.push(failure('receipt_interval', 'Receipt escaped the certified overlap interval', requestID));
  }
}

function validatePrivateDirectory(directory, expectedCount, failures) {
  let directoryStat;
  try {
    directoryStat = fs.lstatSync(directory);
  } catch (error) {
    failures.push(failure('archive_directory', `Receipt export directory is unavailable: ${error.message}`));
    return [];
  }
  if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink()
      || (directoryStat.mode & 0o077) !== 0
      || (typeof process.geteuid === 'function' && directoryStat.uid !== process.geteuid())) {
    failures.push(failure('archive_permissions', 'Receipt export must be a real private directory (0700 or stricter)'));
    return [];
  }
  const names = fs.readdirSync(directory).sort();
  if (names.length !== expectedCount
      || names.some((name) => !/^[0-9a-f-]{36}\.json$/.test(name))) {
    failures.push(failure(
      'archive_completeness',
      'Receipt export does not contain exactly one canonical JSON file per expected operation',
    ));
  }
  const documents = [];
  for (const name of names) {
    if (!/^[0-9a-f-]{36}\.json$/.test(name)) continue;
    const absolute = path.join(directory, name);
    try {
      const before = fs.lstatSync(absolute);
      if (!before.isFile() || before.isSymbolicLink() || (before.mode & 0o177) !== 0) {
        failures.push(failure('archive_permissions', `Receipt file is not a private regular file: ${name}`));
        continue;
      }
      const bytes = fs.readFileSync(absolute);
      const after = fs.lstatSync(absolute);
      if (before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size
          || before.mtimeMs !== after.mtimeMs || bytes.length !== before.size || bytes.length === 0) {
        failures.push(failure('archive_atomicity', `Receipt file changed while it was consumed: ${name}`));
        continue;
      }
      documents.push({ name, bytes, sha256: sha256(bytes) });
    } catch (error) {
      failures.push(failure('archive_read', `Receipt file could not be read safely: ${name}: ${error.message}`));
    }
  }
  return documents;
}

function validateHostArchive(contract, attestationBytes, receiptBytesByID, failures) {
  const root = contract.hostArchive.rootDirectory;
  const listenerDirectory = contract.listener.receiptArchiveDirectory;
  const namespaceDirectory = path.dirname(root);
  let resolvedTemporaryRoot;
  try {
    resolvedTemporaryRoot = fs.realpathSync(contract.hostArchive.temporaryRoot);
    const systemTemporaryRoot = fs.realpathSync(os.tmpdir());
    if (resolvedTemporaryRoot !== systemTemporaryRoot
        && !resolvedTemporaryRoot.startsWith(`${systemTemporaryRoot}${path.sep}`)) {
      failures.push(failure('host_archive_namespace', 'Host archive is outside the private system temporary root'));
    }
  } catch (error) {
    failures.push(failure('host_archive_namespace', `Host temporary root is unavailable: ${error.message}`));
    return;
  }
  for (const [directory, label] of [
    [contract.hostArchive.temporaryRoot, 'temporary root'],
    [namespaceDirectory, 'namespace'],
    [root, 'root'],
    [listenerDirectory, 'listener'],
  ]) {
    let info;
    try {
      info = fs.lstatSync(directory);
    } catch (error) {
      failures.push(failure('host_archive_directory', `${label} archive directory is unavailable: ${error.message}`));
      return;
    }
    if (!info.isDirectory() || info.isSymbolicLink() || (info.mode & 0o077) !== 0
        || (typeof process.geteuid === 'function' && info.uid !== process.geteuid())) {
      failures.push(failure('host_archive_permissions', `${label} archive directory is not private and owner-bound`));
      return;
    }
  }
  const listenerNames = fs.readdirSync(root).sort();
  if (listenerNames.length > contract.hostArchive.listenerDirectoryLimit
      || listenerNames.some((name) => !UUID.test(name))) {
    failures.push(failure('host_archive_retention', 'Hashed archive exceeds or escapes bounded listener retention'));
  }
  const expectedFiles = new Map([['attestation.json', attestationBytes]]);
  for (const [requestID, bytes] of receiptBytesByID) {
    expectedFiles.set(`${requestID}.json`, bytes);
  }
  const actualFiles = fs.readdirSync(listenerDirectory).sort();
  if (actualFiles.length !== expectedFiles.size
      || actualFiles.some((name) => !expectedFiles.has(name))) {
    failures.push(failure('host_archive_completeness', 'Listener archive differs from the certified operation set'));
  }
  for (const [name, expectedBytes] of expectedFiles) {
    const filePath = path.join(listenerDirectory, name);
    try {
      const before = fs.lstatSync(filePath);
      const bytes = fs.readFileSync(filePath);
      const after = fs.lstatSync(filePath);
      if (!before.isFile() || before.isSymbolicLink() || (before.mode & 0o177) !== 0
          || (typeof process.geteuid === 'function' && before.uid !== process.geteuid())
          || before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size
          || before.mtimeMs !== after.mtimeMs || !bytes.equals(expectedBytes)) {
        failures.push(failure('host_archive_file', `Host archive file is unsafe or mismatched: ${name}`));
      }
      if (name === 'attestation.json'
          && sha256(bytes) !== contract.hostArchive.attestationFileSHA256) {
        failures.push(failure('host_archive_attestation', 'Archived listener attestation hash is wrong'));
      }
    } catch (error) {
      failures.push(failure('host_archive_file', `Host archive file is unavailable: ${name}: ${error.message}`));
    }
  }
}

function loadJSON(bytes, context) {
  try {
    return JSON.parse(bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`${context} is not valid JSON: ${error.message}`);
  }
}

export async function validateAttestedOperationReceipts({
  contract,
  attestationDocument,
  receiptDirectory,
  adapter,
  adapterSHA256,
  socketEvidence,
  sourceEvidence,
}) {
  const failures = validateContract(contract);
  if (failures.some((entry) => entry.rule === 'contract_schema')) {
    return { success: false, adapter: null, receipts: [], failures };
  }
  if (!adapter || adapter.adapterAPIVersion !== 2 || typeof adapter.adapterID !== 'string'
      || typeof adapter.embedsAttestation !== 'boolean'
      || typeof adapter.decodeAttestation !== 'function' || typeof adapter.decodeReceipt !== 'function'
      || typeof adapter.hostAttestationBytes !== 'function'
      || typeof adapter.hostReceiptBytes !== 'function') {
    failures.push(failure('adapter_contract', 'Receipt adapter does not implement API version 2'));
    return { success: false, adapter: null, receipts: [], failures };
  }
  if (adapter.adapterID !== contract.adapter?.id
      || typeof adapterSHA256 !== 'string' || adapterSHA256 !== contract.adapter?.sha256) {
    failures.push(failure('adapter_identity', 'Receipt adapter differs from the run-pinned ID or source digest'));
    return {
      success: false,
      adapter: { id: adapter.adapterID, api_version: adapter.adapterAPIVersion, sha256: adapterSHA256 ?? null },
      receipts: [],
      failures,
    };
  }
  validateSocketEvidence(socketEvidence, contract, failures);
  validateSourceEvidence(sourceEvidence, contract, failures);

  let attestation;
  let hostAttestationBytes = Buffer.alloc(0);
  try {
    attestation = await adapter.decodeAttestation(attestationDocument);
    hostAttestationBytes = await adapter.hostAttestationBytes(attestationDocument);
    validateAttestation(attestation, contract, failures);
  } catch (error) {
    failures.push(failure('listener_decode', `Listener attestation could not be decoded: ${error.message}`));
  }

  const expectedOperations = contract.expectedOperations ?? [];
  const files = validatePrivateDirectory(receiptDirectory, expectedOperations.length, failures);
  const expectedByRequestID = new Map(expectedOperations
    .filter((entry) => entry.requestID !== null)
    .map((entry) => [entry.requestID, entry]));
  const unclaimedOperationIDs = new Set(expectedOperations.map((entry) => entry.operationID));
  const decodedReceipts = [];
  const hostReceiptBytesByID = new Map();
  const seenRequestIDs = new Set();
  const rawKey = Buffer.from(contract.listener?.signingPublicKeyBase64 ?? '', 'base64');
  for (const file of files) {
    let decoded;
    try {
      const document = loadJSON(file.bytes, file.name);
      decoded = await adapter.decodeReceipt(document, { fileName: file.name, fileSHA256: file.sha256 });
      const hostReceiptBytes = await adapter.hostReceiptBytes(document);
      if (adapter.embedsAttestation) {
        if (!decoded?.attestation) {
          failures.push(failure('listener_decode', 'Receipt bundle omitted its same-connection attestation'));
        } else {
          validateAttestation(decoded.attestation, contract, failures);
        }
      }
      const requestID = decoded?.normalized?.requestID;
      if (`${requestID}.json` !== file.name) {
        failures.push(failure('archive_filename', 'Receipt filename does not equal its signed request ID', requestID ?? null));
      }
      if (seenRequestIDs.has(requestID)) {
        failures.push(failure('receipt_replay', 'Request ID appears more than once', requestID ?? null));
      }
      seenRequestIDs.add(requestID);
      if (typeof requestID === 'string' && Buffer.isBuffer(hostReceiptBytes)) {
        hostReceiptBytesByID.set(requestID, hostReceiptBytes);
      }
      let expected = expectedByRequestID.get(requestID);
      if (!expected) {
        const candidates = expectedOperations.filter((entry) => entry.requestID === null
          && unclaimedOperationIDs.has(entry.operationID)
          && entry.operation === decoded?.normalized?.operation
          && entry.client.pid === decoded?.normalized?.clientPID
          && entry.client.startIdentity === decoded?.normalized?.clientStartIdentity
          && entry.client.codeSignatureHash === decoded?.normalized?.clientCodeSignatureHash);
        if (candidates.length === 1) [expected] = candidates;
      }
      validateReceipt(decoded, expected, contract, rawKey, failures);
      if (expected) unclaimedOperationIDs.delete(expected.operationID);
      decodedReceipts.push({
        operation_id: expected?.operationID ?? null,
        request_id: requestID ?? null,
        operation: decoded?.normalized?.operation ?? null,
        file: file.name,
        file_sha256: file.sha256,
      });
    } catch (error) {
      failures.push(failure('receipt_decode', `Receipt ${file.name} could not be decoded: ${error.message}`));
    }
  }
  for (const operationID of unclaimedOperationIDs) {
    const expected = expectedOperations.find((entry) => entry.operationID === operationID);
    if (expected) {
      failures.push(failure(
        'lost_response',
        `Expected operation ${operationID} has no verified response receipt; delivery is indeterminate and retry-unsafe`,
        expected.requestID,
      ));
    }
  }
  validateHostArchive(
    contract,
    hostAttestationBytes,
    hostReceiptBytesByID,
    failures,
  );
  return {
    success: failures.length === 0,
    adapter: { id: adapter.adapterID, api_version: adapter.adapterAPIVersion, sha256: adapterSHA256 },
    receipts: decodedReceipts.sort((left, right) => left.request_id.localeCompare(right.request_id)),
    failures,
  };
}

function parseArguments(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (['--contract', '--attestation', '--receipts', '--adapter', '--output'].includes(value)
        && argv[index + 1]) {
      result[value.slice(2)] = argv[index + 1];
      index += 1;
    } else {
      throw new Error(`Unknown or incomplete argument: ${value}`);
    }
  }
  return result;
}

async function runCLI() {
  const args = parseArguments(process.argv.slice(2));
  for (const required of ['contract', 'receipts', 'adapter']) {
    if (!args[required]) throw new Error(`--${required} is required`);
  }
  const contract = JSON.parse(fs.readFileSync(args.contract, 'utf8'));
  const receiptDirectory = path.resolve(args.receipts);
  const attestationPath = args.attestation ?? fs.readdirSync(receiptDirectory)
    .filter((name) => name.endsWith('.json'))
    .sort()
    .map((name) => path.join(receiptDirectory, name))[0];
  if (!attestationPath) throw new Error('receipt directory has no attestation-bearing JSON bundle');
  const attestationDocument = JSON.parse(fs.readFileSync(attestationPath, 'utf8'));
  const adapterURL = pathToFileURL(path.resolve(args.adapter));
  const adapterSHA256 = sha256(fs.readFileSync(args.adapter));
  const adapter = await import(`${adapterURL.href}?sha256=${adapterSHA256}`);
  const socketStat = fs.lstatSync(contract.socketEndpoint.path, { bigint: true });
  const socketEvidence = {
    path: contract.socketEndpoint.path,
    device: String(socketStat.dev),
    inode: String(socketStat.ino),
    isSocket: socketStat.isSocket(),
    isSymbolicLink: socketStat.isSymbolicLink(),
  };
  const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const fileDigest = (relativePath) => sha256(fs.readFileSync(path.join(repositoryRoot, relativePath)));
  const sourceCommit = execFileSync(
    'git',
    ['rev-parse', contract.protocolImplementation.sourceCommit],
    { cwd: repositoryRoot, encoding: 'utf8' },
  ).trim();
  const sourceTree = execFileSync(
    'git',
    ['rev-parse', `${sourceCommit}^{tree}`],
    { cwd: repositoryRoot, encoding: 'utf8' },
  ).trim();
  const sourceEvidence = {
    sourceCommit,
    sourceTree,
    peerBinding: 'darwin-audit-token-pidversion-euid-cdhash-v1',
    operationReceiptsSHA256: fileDigest(
      'Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeOperationReceipts.swift',
    ),
    socketIOSHA256: fileDigest(
      'Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeSocketIO.swift',
    ),
    hostClientsSHA256: fileDigest(
      'Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeHost+Clients.swift',
    ),
    privateArchiveSHA256: fileDigest(
      'Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgePrivateReceiptArchive.swift',
    ),
  };
  const result = await validateAttestedOperationReceipts({
    contract,
    attestationDocument,
    receiptDirectory,
    adapter,
    adapterSHA256,
    socketEvidence,
    sourceEvidence,
  });
  const output = `${JSON.stringify(result, null, 2)}\n`;
  if (args.output) fs.writeFileSync(args.output, output, { mode: 0o600 });
  else process.stdout.write(output);
  if (!result.success) process.exitCode = 1;
}

const invokedAsScript = process.argv[1]
  && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedAsScript) {
  runCLI().catch((error) => {
    process.stderr.write(`attested operation receipt validator: ${error.message}\n`);
    process.exitCode = 2;
  });
}
