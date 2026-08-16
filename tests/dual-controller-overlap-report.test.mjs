import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  firstPartyResultSetSHA256,
  makeOfflineContractForReport,
  makeOperationManifest,
  makePassingOverlapReport,
  operationManifestSHA256,
  receiptValidationResultSHA256,
  validateOverlapCertification,
} from '../scripts/validate-dual-controller-overlap-report.mjs';
import { offlineContractSHA256 } from '../scripts/validate-attested-operation-receipts.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const catalogPath = path.join(root, 'scripts/dual-controller-overlap-catalog.json');
const catalogBytes = fs.readFileSync(catalogPath);
const catalog = JSON.parse(catalogBytes);
const catalogSHA256 = createHash('sha256').update(catalogBytes).digest('hex');
const defaultReport = makePassingOverlapReport(catalog);
const defaultOfflineContract = makeOfflineContractForReport(catalog, defaultReport);
const defaultManifest = makeOperationManifest(catalog, defaultReport, defaultOfflineContract);

function validate(
  report,
  manifest = defaultManifest,
  offlineContract = defaultOfflineContract,
) {
  return validateOverlapCertification(
    catalog,
    report,
    report.catalog_sha256,
    manifest,
    offlineContract,
  );
}

function rules(result) {
  return new Set(result.failures.map((entry) => entry.rule));
}

function refreshFirstPartySummary(report) {
  const { first_party_results: results } = report.receipt_validation;
  report.receipt_validation.first_party_result_count = results.length;
  report.receipt_validation.receipt_count = results.length;
  report.receipt_validation.session_count = new Set(results.map((entry) => entry.session_id)).size;
  report.receipt_validation.first_party_result_set_sha256 = firstPartyResultSetSHA256(results);
}

function refreshOfflineSummary(report) {
  report.receipt_validation.result_sha256 = receiptValidationResultSHA256(
    report.receipt_validation.offline_result,
  );
}

test('passing report proves exact targets and bidirectional overlap', () => {
  const report = makePassingOverlapReport(catalog);
  const result = validate(report);
  assert.equal(result.success, true);
  assert.deepEqual(result.failures, []);
});

test('missing duplicate and unknown controllers fail closed', () => {
  const missing = makePassingOverlapReport(catalog);
  missing.controllers.pop();
  assert.ok(rules(validate(missing)).has('controllers'));

  const duplicate = makePassingOverlapReport(catalog);
  duplicate.controllers[1] = structuredClone(duplicate.controllers[0]);
  assert.ok(rules(validate(duplicate)).has('controllers'));

  const unknown = makePassingOverlapReport(catalog);
  unknown.controllers[1].id = 'C';
  assert.ok(rules(validate(unknown)).has('controllers'));
});

test('target receipts require distinct process generations and windows', () => {
  const report = makePassingOverlapReport(catalog);
  report.controllers[1].target.pid = report.controllers[0].target.pid;
  report.controllers[1].target.start_identity = report.controllers[0].target.start_identity;
  report.controllers[1].target.window_id = report.controllers[0].target.window_id;
  const result = validate(report);
  assert.equal(result.success, false);
  assert.ok(rules(result).has('target_isolation'));
});

test('controller and operation process generations must be distinct', () => {
  const wrapperReuse = makePassingOverlapReport(catalog);
  wrapperReuse.controllers[1].controller_process = structuredClone(
    wrapperReuse.controllers[0].controller_process,
  );
  assert.ok(rules(validate(wrapperReuse)).has('client_isolation'));

  const operationReuse = makePassingOverlapReport(catalog);
  operationReuse.controllers[1].mutations[0].client_pid =
    operationReuse.controllers[0].mutations[0].client_pid;
  operationReuse.controllers[1].mutations[0].client_start_identity =
    operationReuse.controllers[0].mutations[0].client_start_identity;
  assert.ok(rules(validate(operationReuse)).has('client_isolation'));

  const wrapperOperationReuse = makePassingOverlapReport(catalog);
  wrapperOperationReuse.controllers[0].mutations[0].client_pid =
    wrapperOperationReuse.controllers[0].controller_process.pid;
  wrapperOperationReuse.controllers[0].mutations[0].client_start_identity =
    wrapperOperationReuse.controllers[0].controller_process.start_identity;
  assert.ok(rules(validate(wrapperOperationReuse)).has('client_isolation'));
});

test('serialized or one-way work cannot claim overlap', () => {
  const serialized = makePassingOverlapReport(catalog);
  serialized.controllers[1].mutations.filter((entry) => entry.phase === 'workflow').forEach((entry) => {
    entry.started_at += 20;
    entry.finished_at += 20;
  });
  assert.ok(rules(validate(serialized)).has('overlap'));

  const oneWay = makePassingOverlapReport(catalog);
  oneWay.overlap.b_mutations_during_a = 0;
  assert.ok(rules(validate(oneWay)).has('overlap'));

  const noConcurrentCommands = makePassingOverlapReport(catalog);
  const starts = [10.45, 10.95, 11.45, 11.95, 12.2];
  noConcurrentCommands.controllers[1].mutations.forEach((mutation, index) => {
    mutation.started_at = starts[index];
    mutation.finished_at = starts[index] + 0.1;
  });
  noConcurrentCommands.overlap.b_mutations_during_a = 4;
  noConcurrentCommands.overlap.concurrent_mutation_pairs = [];
  assert.ok(rules(validate(noConcurrentCommands)).has('overlap'));

  const falseLivenessWitness = makePassingOverlapReport(catalog);
  falseLivenessWitness.overlap.simultaneous_liveness_witness.a_start_identity = '999';
  assert.ok(rules(validate(falseLivenessWitness)).has('overlap'));

  const changedMarkers = makePassingOverlapReport(catalog);
  changedMarkers.overlap.simultaneous_liveness_witness.markers_unchanged = false;
  assert.ok(rules(validate(changedMarkers)).has('overlap'));

  const staleMarker = makePassingOverlapReport(catalog);
  staleMarker.overlap.simultaneous_liveness_witness.b_active_marker.index = 4;
  assert.ok(rules(validate(staleMarker)).has('overlap'));

  const unbracketed = makePassingOverlapReport(catalog);
  unbracketed.overlap.simultaneous_liveness_witness.a_checked_after_at = 10.45;
  assert.ok(rules(validate(unbracketed)).has('overlap'));
});

test('foreground or cross-target mutations fail', () => {
  const foreground = makePassingOverlapReport(catalog);
  foreground.controllers[0].mutations[0].foreground = true;
  assert.ok(rules(validate(foreground)).has('mutation_contract'));

  const leaked = makePassingOverlapReport(catalog);
  leaked.controllers[1].cross_target_clear = false;
  assert.ok(rules(validate(leaked)).has('controller_schema'));

  const falseReceipt = makePassingOverlapReport(catalog);
  falseReceipt.controllers[0].mutations[0].reported_target_pid = falseReceipt.controllers[1].target.pid;
  assert.ok(rules(validate(falseReceipt)).has('mutation_contract'));

  const falseObservationReceipt = makePassingOverlapReport(catalog);
  falseObservationReceipt.controllers[0].observations[0].route_receipt.reported_target_pid =
    falseObservationReceipt.controllers[1].target.pid;
  assert.ok(rules(validate(falseObservationReceipt)).has('observation_route'));
});

test('independent readback and restoration are mandatory', () => {
  const staleReadback = makePassingOverlapReport(catalog);
  staleReadback.controllers[0].readback_token = staleReadback.controllers[0].initial_token;
  assert.ok(rules(validate(staleReadback)).has('controller_schema'));

  const missingRestore = makePassingOverlapReport(catalog);
  missingRestore.restoration.controller_b = false;
  assert.ok(rules(validate(missingRestore)).has('restoration'));

  const earlyRestore = makePassingOverlapReport(catalog);
  earlyRestore.controllers[0].observations.at(-1).started_at =
    earlyRestore.controllers[0].mutations.at(-1).started_at;
  earlyRestore.controllers[0].observations.at(-1).finished_at =
    earlyRestore.controllers[0].mutations.at(-1).started_at + 0.05;
  assert.ok(rules(validate(earlyRestore)).has('independent_readback'));
});

test('serialized restoration checkpoints prevent peer restoration from masking cross-target dispatch', () => {
  const missingCheckpoint = makePassingOverlapReport(catalog);
  missingCheckpoint.restoration_checkpoints.pop();
  assert.ok(rules(validate(missingCheckpoint)).has('restoration_checkpoint_schema'));

  const maskedCrossTargetClear = makePassingOverlapReport(catalog);
  maskedCrossTargetClear.restoration_checkpoints[0].observations[1].token_present = false;
  assert.ok(rules(validate(maskedCrossTargetClear)).has('restoration_checkpoint_contract'));

  const maskedPeerCrossTargetClear = makePassingOverlapReport(catalog);
  maskedPeerCrossTargetClear.restoration_checkpoints[1].observations[0].token_present = false;
  assert.ok(rules(validate(maskedPeerCrossTargetClear)).has('restoration_checkpoint_contract'));

  const concurrentPeerRestore = makePassingOverlapReport(catalog);
  const firstCheckpoint = concurrentPeerRestore.restoration_checkpoints[0].observations[1];
  const peerRestoration = concurrentPeerRestore.controllers[1].mutations.at(-1);
  peerRestoration.started_at = firstCheckpoint.finished_at - 0.05;
  peerRestoration.finished_at = peerRestoration.started_at + 0.2;
  assert.ok(rules(validate(concurrentPeerRestore)).has('restoration_checkpoint_timing'));
});

test('workflow minima exclude restoration operations', () => {
  const report = makePassingOverlapReport(catalog);
  report.controllers[0].mutations.splice(1, 1);
  const result = validate(report);
  assert.equal(result.success, false);
  assert.ok(rules(result).has('mutation_count'));
});

test('catalog binds exact controller workflows and restoration commands', () => {
  const missingReturn = makePassingOverlapReport(catalog);
  missingReturn.controllers[0].mutations[1].command = 'type';
  assert.ok(rules(validate(missingReturn)).has('mutation_sequence'));

  const unexpectedPress = makePassingOverlapReport(catalog);
  unexpectedPress.controllers[1].mutations[2].command = 'press';
  assert.ok(rules(validate(unexpectedPress)).has('mutation_sequence'));

  const wrongRestore = makePassingOverlapReport(catalog);
  wrongRestore.controllers[0].mutations.at(-1).command = 'press';
  assert.ok(rules(validate(wrongRestore)).has('mutation_sequence'));
});

test('observations and route receipts require successful JSON envelopes', () => {
  const failedObservation = makePassingOverlapReport(catalog);
  failedObservation.controllers[0].observations[0].result_success = false;
  assert.ok(rules(validate(failedObservation)).has('observation_contract'));

  const failedRoute = makePassingOverlapReport(catalog);
  failedRoute.controllers[0].observations[0].route_receipt.result_success = false;
  assert.ok(rules(validate(failedRoute)).has('observation_route'));
});

test('synthetic overlap evidence cannot replace signed protocol 1.29 receipt validation', () => {
  const failed = makePassingOverlapReport(catalog);
  failed.receipt_validation.success = false;
  assert.ok(rules(validate(failed)).has('receipt_validation'));

  const missing = makePassingOverlapReport(catalog);
  delete missing.receipt_validation;
  assert.ok(rules(validate(missing)).has('report_schema'));

  const incomplete = makePassingOverlapReport(catalog);
  incomplete.receipt_validation.receipt_count -= 1;
  assert.ok(rules(validate(incomplete)).has('receipt_validation'));

  const unboundFirstParty = makePassingOverlapReport(catalog);
  unboundFirstParty.receipt_validation.first_party_result_set_sha256 = 'invalid';
  assert.ok(rules(validate(unboundFirstParty)).has('receipt_validation'));

  const untrustedFirstParty = makePassingOverlapReport(catalog);
  untrustedFirstParty.receipt_validation.first_party_trust_source = 'bundle_self_signature';
  assert.ok(rules(validate(untrustedFirstParty)).has('receipt_validation'));

  const missingFirstPartyResult = makePassingOverlapReport(catalog);
  missingFirstPartyResult.receipt_validation.first_party_result_count -= 1;
  assert.ok(rules(validate(missingFirstPartyResult)).has('receipt_validation'));

  const legacyProtocol = makePassingOverlapReport(catalog);
  legacyProtocol.host.protocol_minor = 28;
  assert.ok(rules(validate(legacyProtocol)).has('host_receipt'));
});

test('reporter emits and requires the independently frozen operation manifest', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'peekaboo-operation-manifest-test.'));
  try {
    const reportPath = path.join(directory, 'report.json');
    const manifestPath = path.join(directory, 'operation-manifest.json');
    const offlineContractPath = path.join(directory, 'offline-contract.json');
    const report = makePassingOverlapReport(catalog, catalogSHA256);
    const offlineContract = makeOfflineContractForReport(catalog, report);
    report.receipt_validation.version = 2;
    report.receipt_validation.contract_sha256 = 'legacy-v2-contract-hash';
    report.receipt_validation.operation_manifest_sha256 = '0'.repeat(64);
    report.receipt_validation.offline_contract_sha256 = '0'.repeat(64);
    report.evidence.catalog_derived_exact_operation_manifest = false;
    report.evidence.offline_policy_contract_binding = false;
    fs.writeFileSync(reportPath, `${JSON.stringify(report)}\n`);
    fs.writeFileSync(offlineContractPath, `${JSON.stringify(offlineContract)}\n`);
    const reporter = path.join(root, 'scripts/validate-dual-controller-overlap-report.mjs');
    execFileSync(process.execPath, [
      reporter,
      '--catalog', catalogPath,
      '--report', reportPath,
      '--offline-contract', offlineContractPath,
      '--finalize-operation-manifest', manifestPath,
    ]);
    const finalized = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    assert.equal(finalized.receipt_validation.version, 3);
    assert.equal('contract_sha256' in finalized.receipt_validation, false);
    assert.equal(
      finalized.receipt_validation.operation_manifest_sha256,
      operationManifestSHA256(manifest),
    );
    assert.equal(
      finalized.receipt_validation.offline_contract_sha256,
      manifest.offline_contract_sha256,
    );
    assert.equal(finalized.evidence.catalog_derived_exact_operation_manifest, true);
    assert.equal(finalized.evidence.offline_policy_contract_binding, true);
    const validation = JSON.parse(execFileSync(process.execPath, [
      reporter,
      '--catalog', catalogPath,
      '--report', reportPath,
      '--operation-manifest', manifestPath,
      '--offline-contract', offlineContractPath,
    ], { encoding: 'utf8' }));
    assert.equal(validation.success, true);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('anchored per-bundle verdicts are retained and independently checked', () => {
  const missingVerdict = makePassingOverlapReport(catalog);
  missingVerdict.receipt_validation.first_party_results.shift();
  refreshFirstPartySummary(missingVerdict);
  assert.ok(rules(validate(missingVerdict)).has('receipt_validation'));

  const rewrittenHost = makePassingOverlapReport(catalog);
  rewrittenHost.receipt_validation.first_party_results[0].host.pid += 1;
  refreshFirstPartySummary(rewrittenHost);
  assert.ok(rules(validate(rewrittenHost)).has('receipt_validation'));

  const rewrittenOperation = makePassingOverlapReport(catalog);
  rewrittenOperation.receipt_validation.first_party_results[0].operation = 'permissionsStatus';
  refreshFirstPartySummary(rewrittenOperation);
  assert.ok(rules(validate(rewrittenOperation)).has('receipt_validation'));

  const duplicateBundle = makePassingOverlapReport(catalog);
  duplicateBundle.receipt_validation.first_party_results[1].bundle_sha256 =
    duplicateBundle.receipt_validation.first_party_results[0].bundle_sha256;
  refreshFirstPartySummary(duplicateBundle);
  assert.ok(rules(validate(duplicateBundle)).has('receipt_validation'));

  const reordered = makePassingOverlapReport(catalog);
  reordered.receipt_validation.first_party_results.reverse();
  refreshFirstPartySummary(reordered);
  assert.ok(rules(validate(reordered)).has('receipt_validation'));

  const untrackedClient = makePassingOverlapReport(catalog);
  const extra = structuredClone(untrackedClient.receipt_validation.first_party_results.at(-1));
  extra.request_id = 'ffffffff-ffff-8fff-bfff-ffffffffffff';
  extra.session_id = 'ffffffff-ffff-4fff-bfff-ffffffffffff';
  extra.client_instance_id = 'eeeeeeee-eeee-4eee-aeee-eeeeeeeeeeee';
  extra.bundle_sha256 = 'e'.repeat(64);
  extra.client.pid = 99999;
  extra.client.start_identity = '9999900';
  untrackedClient.receipt_validation.first_party_results.push(extra);
  refreshFirstPartySummary(untrackedClient);
  assert.ok(rules(validate(untrackedClient)).has('receipt_validation'));
});

test('first-party verdicts and offline bundle rows form one exact bijection', () => {
  const deletedPair = makePassingOverlapReport(catalog);
  deletedPair.receipt_validation.first_party_results.shift();
  deletedPair.receipt_validation.offline_result.receipts.shift();
  refreshFirstPartySummary(deletedPair);
  refreshOfflineSummary(deletedPair);
  assert.ok(rules(validate(deletedPair)).has('receipt_validation'));

  const substitutedBundle = makePassingOverlapReport(catalog);
  substitutedBundle.receipt_validation.offline_result.receipts[0].file_sha256 = 'e'.repeat(64);
  refreshOfflineSummary(substitutedBundle);
  assert.ok(rules(validate(substitutedBundle)).has('receipt_validation'));

  const donor = makePassingOverlapReport(catalog);
  donor.receipt_validation.first_party_results[0].bundle_sha256 = 'e'.repeat(64);
  donor.controllers[0].mutations[0].operation_receipts[0].bundle_sha256 = 'e'.repeat(64);
  donor.receipt_validation.offline_result.receipts[0].file_sha256 = 'e'.repeat(64);
  refreshFirstPartySummary(donor);
  refreshOfflineSummary(donor);
  const donorOfflineContract = makeOfflineContractForReport(catalog, donor);
  const donorManifest = makeOperationManifest(catalog, donor, donorOfflineContract);
  donor.receipt_validation.operation_manifest_sha256 = operationManifestSHA256(donorManifest);
  assert.equal(validate(donor, donorManifest, donorOfflineContract).success, true);
  const splicedSets = makePassingOverlapReport(catalog);
  splicedSets.receipt_validation.offline_result.receipts[0] = structuredClone(
    donor.receipt_validation.offline_result.receipts[0],
  );
  refreshOfflineSummary(splicedSets);
  assert.ok(rules(validate(splicedSets)).has('receipt_validation'));

  const duplicateOfflineBundle = makePassingOverlapReport(catalog);
  duplicateOfflineBundle.receipt_validation.offline_result.receipts[1].file_sha256 =
    duplicateOfflineBundle.receipt_validation.offline_result.receipts[0].file_sha256;
  refreshOfflineSummary(duplicateOfflineBundle);
  assert.ok(rules(validate(duplicateOfflineBundle)).has('receipt_validation'));

  const reorderedOfflineRows = makePassingOverlapReport(catalog);
  reorderedOfflineRows.receipt_validation.offline_result.receipts.reverse();
  refreshOfflineSummary(reorderedOfflineRows);
  assert.ok(rules(validate(reorderedOfflineRows)).has('receipt_validation'));

  const staleOfflineHash = makePassingOverlapReport(catalog);
  staleOfflineHash.receipt_validation.offline_result.receipts[0].operation_id = 'rewritten';
  assert.ok(rules(validate(staleOfflineHash)).has('receipt_validation'));

  const summaryOnly = makePassingOverlapReport(catalog);
  delete summaryOnly.receipt_validation.offline_result;
  assert.ok(rules(validate(summaryOnly)).has('receipt_validation'));
});

test('offline policy contract and operation IDs cannot be transplanted', () => {
  const targetMutators = [
    (target) => { target.scope = 'screen'; },
    (target) => { target.pid += 1; },
    (target) => { target.processStartIdentity = `${target.processStartIdentity}1`; },
    (target) => { target.windowID += 1; },
    (target) => { target.bounds.x += 1; },
    (target) => { target.bounds.y += 1; },
    (target) => { target.bounds.width += 1; },
    (target) => { target.bounds.height += 1; },
  ];
  const mutations = targetMutators.map((mutateTarget) => (contract) => {
    const originalPID = contract.ownedTarget.pid;
    mutateTarget(contract.ownedTarget);
    contract.expectedOperations.filter((entry) => (
      entry.target.pid === originalPID
    )).forEach((entry) => { mutateTarget(entry.target); });
  }).concat([
    (contract) => { contract.interval.completedAtMilliseconds += 1; },
    (contract) => { contract.protocolImplementation.sourceCommit = 'f'.repeat(40); },
    (contract) => { contract.expectedOperations[0].outcome.retrySafe = true; },
  ]);
  for (const mutate of mutations) {
    const report = makePassingOverlapReport(catalog);
    const transplantedContract = structuredClone(defaultOfflineContract);
    mutate(transplantedContract);
    const digest = offlineContractSHA256(transplantedContract);
    report.receipt_validation.offline_contract_sha256 = digest;
    report.receipt_validation.offline_result.contract_sha256 = digest;
    refreshOfflineSummary(report);
    assert.throws(
      () => makeOperationManifest(catalog, report, transplantedContract),
      /Offline contract does not contain|Offline contract does not bind/,
    );
    assert.ok(rules(validate(report, defaultManifest, transplantedContract)).has(
      'operation_manifest',
    ));
  }

  const wrongSlot = makePassingOverlapReport(catalog);
  wrongSlot.receipt_validation.offline_result.receipts[0].operation_id =
    defaultManifest.slots[1].offline_operation_id;
  refreshOfflineSummary(wrongSlot);
  assert.ok(rules(validate(wrongSlot)).has('receipt_validation'));
});

test('exact operation receipt instances cannot be overwritten or spliced', () => {
  const auxiliaryInstance = makePassingOverlapReport(catalog);
  const primaryMutation = auxiliaryInstance.controllers[0].mutations[0];
  const primaryResult = auxiliaryInstance.receipt_validation.first_party_results.find(
    (entry) => entry.request_id === primaryMutation.operation_receipts[0].request_id,
  );
  const auxiliaryResult = structuredClone(primaryResult);
  auxiliaryResult.request_id = 'ffffffff-ffff-8fff-bfff-ffffffffffff';
  auxiliaryResult.session_sequence = '1';
  auxiliaryResult.operation = 'listWindows';
  auxiliaryResult.request_sha256 = 'a'.repeat(64);
  auxiliaryResult.response_sha256 = 'b'.repeat(64);
  auxiliaryResult.bundle_sha256 = 'e'.repeat(64);
  auxiliaryResult.target_attested = false;
  auxiliaryResult.outcome_attested = false;
  auxiliaryInstance.receipt_validation.first_party_results.push(auxiliaryResult);
  primaryMutation.operation_receipts.push({
    request_id: auxiliaryResult.request_id,
    session_id: auxiliaryResult.session_id,
    session_sequence: auxiliaryResult.session_sequence,
    operation: auxiliaryResult.operation,
    request_sha256: auxiliaryResult.request_sha256,
    response_sha256: auxiliaryResult.response_sha256,
    bundle_sha256: auxiliaryResult.bundle_sha256,
  });
  auxiliaryInstance.receipt_validation.offline_result.receipts.push({
    operation_id: 'overlap-operation-auxiliary',
    request_id: auxiliaryResult.request_id,
    operation: auxiliaryResult.operation,
    file: `${auxiliaryResult.request_id}.json`,
    file_sha256: auxiliaryResult.bundle_sha256,
  });
  refreshFirstPartySummary(auxiliaryInstance);
  refreshOfflineSummary(auxiliaryInstance);
  assert.ok(rules(validate(auxiliaryInstance)).has('mutation_contract'));

  const pairedDeletion = makePassingOverlapReport(catalog);
  const removedRequestID = pairedDeletion.controllers[0].mutations[0].operation_receipts[0].request_id;
  pairedDeletion.controllers[0].mutations[0].operation_receipts = [];
  pairedDeletion.receipt_validation.first_party_results =
    pairedDeletion.receipt_validation.first_party_results.filter((entry) => (
      entry.request_id !== removedRequestID
    ));
  pairedDeletion.receipt_validation.offline_result.receipts =
    pairedDeletion.receipt_validation.offline_result.receipts.filter((entry) => (
      entry.request_id !== removedRequestID
    ));
  refreshFirstPartySummary(pairedDeletion);
  refreshOfflineSummary(pairedDeletion);
  const pairedDeletionRules = rules(validate(pairedDeletion));
  assert.ok(pairedDeletionRules.has('mutation_contract'));
  assert.ok(pairedDeletionRules.has('receipt_validation'));

  const staleManifest = makePassingOverlapReport(catalog);
  staleManifest.receipt_validation.operation_manifest_sha256 = '2'.repeat(64);
  assert.ok(rules(validate(staleManifest)).has('receipt_validation'));

  const sameOperationReplacement = makePassingOverlapReport(catalog);
  const replacedReceipt = sameOperationReplacement.controllers[0].mutations[0].operation_receipts[0];
  const replacementResult = structuredClone(
    sameOperationReplacement.receipt_validation.first_party_results.find((entry) => (
      entry.request_id === replacedReceipt.request_id
    )),
  );
  replacementResult.request_id = 'ffffffff-ffff-8fff-bfff-ffffffffffff';
  replacementResult.session_id = 'ffffffff-ffff-4fff-bfff-ffffffffffff';
  replacementResult.client_instance_id = 'eeeeeeee-eeee-4eee-aeee-eeeeeeeeeeee';
  replacementResult.request_sha256 = 'a'.repeat(64);
  replacementResult.response_sha256 = 'b'.repeat(64);
  replacementResult.bundle_sha256 = 'e'.repeat(64);
  sameOperationReplacement.controllers[0].mutations[0].operation_receipts[0] = {
    request_id: replacementResult.request_id,
    session_id: replacementResult.session_id,
    session_sequence: replacementResult.session_sequence,
    operation: replacementResult.operation,
    request_sha256: replacementResult.request_sha256,
    response_sha256: replacementResult.response_sha256,
    bundle_sha256: replacementResult.bundle_sha256,
  };
  sameOperationReplacement.receipt_validation.first_party_results =
    sameOperationReplacement.receipt_validation.first_party_results.map((entry) => (
      entry.request_id === replacedReceipt.request_id ? replacementResult : entry
    )).sort((left, right) => left.request_id.localeCompare(right.request_id));
  sameOperationReplacement.receipt_validation.offline_result.receipts =
    sameOperationReplacement.receipt_validation.offline_result.receipts.map((entry) => (
      entry.request_id === replacedReceipt.request_id ? {
        ...entry,
        request_id: replacementResult.request_id,
        operation: replacementResult.operation,
        file: `${replacementResult.request_id}.json`,
        file_sha256: replacementResult.bundle_sha256,
      } : entry
    )).sort((left, right) => left.request_id.localeCompare(right.request_id));
  refreshFirstPartySummary(sameOperationReplacement);
  refreshOfflineSummary(sameOperationReplacement);
  assert.ok(rules(validate(sameOperationReplacement)).has('receipt_validation'));

  const substitutedInstance = makePassingOverlapReport(catalog);
  [
    substitutedInstance.controllers[0].mutations[0].operation_receipts,
    substitutedInstance.controllers[1].mutations[0].operation_receipts,
  ] = [
    substitutedInstance.controllers[1].mutations[0].operation_receipts,
    substitutedInstance.controllers[0].mutations[0].operation_receipts,
  ];
  assert.ok(rules(validate(substitutedInstance)).has('receipt_validation'));

  const duplicateInstance = makePassingOverlapReport(catalog);
  duplicateInstance.controllers[0].mutations[2].operation_receipts = structuredClone(
    duplicateInstance.controllers[0].mutations[0].operation_receipts,
  );
  assert.ok(rules(validate(duplicateInstance)).has('receipt_validation'));

  const repeatedGeneration = makePassingOverlapReport(catalog);
  const firstMutation = repeatedGeneration.controllers[0].mutations[0];
  const laterMutation = repeatedGeneration.controllers[0].mutations[2];
  const firstResult = repeatedGeneration.receipt_validation.first_party_results.find(
    (entry) => entry.request_id === firstMutation.operation_receipts[0].request_id,
  );
  const laterResult = repeatedGeneration.receipt_validation.first_party_results.find(
    (entry) => entry.request_id === laterMutation.operation_receipts[0].request_id,
  );
  laterMutation.client_pid = firstMutation.client_pid;
  laterMutation.client_start_identity = firstMutation.client_start_identity;
  laterResult.client = structuredClone(firstResult.client);
  laterResult.client_instance_id = firstResult.client_instance_id;
  laterResult.session_id = firstResult.session_id;
  laterResult.session_sequence = '1';
  laterMutation.operation_receipts[0].session_id = firstResult.session_id;
  laterMutation.operation_receipts[0].session_sequence = '1';
  refreshFirstPartySummary(repeatedGeneration);
  const repeatedResult = validate(repeatedGeneration);
  assert.ok(rules(repeatedResult).has('client_isolation'));
  assert.ok(rules(repeatedResult).has('receipt_validation'));
});

test('controller token namespaces are run-bound and disjoint', () => {
  const report = makePassingOverlapReport(catalog);
  report.controllers[1].initial_token = report.controllers[0].initial_token;
  const result = validate(report);
  assert.equal(result.success, false);
  assert.ok(rules(result).has('token_namespace'));
});

test('host restart and sentinel drift fail', () => {
  const hostRestart = makePassingOverlapReport(catalog);
  hostRestart.host.stable = false;
  assert.ok(rules(validate(hostRestart)).has('host_receipt'));

  const focusTheft = makePassingOverlapReport(catalog);
  focusTheft.sentinel.final_frontmost_pid = 999;
  assert.ok(rules(validate(focusTheft)).has('sentinel_receipt'));
});

test('every named invariant is unsuppressible', () => {
  for (let index = 0; index < catalog.invariants.length; index += 1) {
    const report = makePassingOverlapReport(catalog);
    report.invariants[index].passed = false;
    const result = validate(report);
    assert.equal(result.success, false, catalog.invariants[index]);
    assert.ok(rules(result).has('invariant_failed'), catalog.invariants[index]);
  }
});

test('physical cursor is evidence but never an unchanged oracle', () => {
  const moved = makePassingOverlapReport(catalog);
  moved.cursor_observation.moved = true;
  assert.equal(validate(moved).success, true);

  const strict = makePassingOverlapReport(catalog);
  strict.cursor_observation.policy = 'unchanged';
  assert.ok(rules(validate(strict)).has('cursor_observation'));
});

test('cleanup requires exact process generation receipts', () => {
  const report = makePassingOverlapReport(catalog);
  report.cleanup[0].start_identity = '';
  const result = validate(report);
  assert.equal(result.success, false);
  assert.ok(rules(result).has('cleanup'));
});

test('unknown fields and legacy aggregate results fail closed', () => {
  const unknown = makePassingOverlapReport(catalog);
  unknown.ignored = true;
  assert.ok(rules(validate(unknown)).has('report_schema'));

  const aggregate = makePassingOverlapReport(catalog);
  aggregate.invariants = { violations: 0 };
  assert.ok(rules(validate(aggregate)).has('invariant_schema'));

  const legacyReport = makePassingOverlapReport(catalog);
  legacyReport.version = 2;
  assert.ok(rules(validate(legacyReport)).has('report_schema'));
});

test('catalog hash must match independently supplied bytes', () => {
  const report = makePassingOverlapReport(catalog);
  const result = validateOverlapCertification(catalog, report, '0'.repeat(64));
  assert.equal(result.success, false);
  assert.ok(rules(result).has('catalog_hash'));
});
