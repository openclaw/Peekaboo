import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  makePassingOverlapReport,
  validateOverlapCertification,
} from '../scripts/validate-dual-controller-overlap-report.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const catalog = JSON.parse(fs.readFileSync(
  path.join(root, 'scripts/dual-controller-overlap-catalog.json'),
  'utf8',
));

function validate(report) {
  return validateOverlapCertification(catalog, report, report.catalog_sha256);
}

function rules(result) {
  return new Set(result.failures.map((entry) => entry.rule));
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
});

test('catalog hash must match independently supplied bytes', () => {
  const report = makePassingOverlapReport(catalog);
  const result = validateOverlapCertification(catalog, report, '0'.repeat(64));
  assert.equal(result.success, false);
  assert.ok(rules(result).has('catalog_hash'));
});
