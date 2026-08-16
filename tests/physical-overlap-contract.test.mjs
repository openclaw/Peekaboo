import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const catalogPath = path.join(root, 'scripts/physical-overlap-contract-catalog.json');
const catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));

function sha256AtPinnedCommit(relativePath) {
  return createHash('sha256').update(execFileSync(
    'git',
    ['show', `${catalog.product_source.commit}:${relativePath}`],
    { cwd: root, encoding: null },
  )).digest('hex');
}

function exactKeys(value, expected) {
  return value && typeof value === 'object' && !Array.isArray(value)
    && JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort());
}

function validate(value) {
  const failures = [];
  if (!exactKeys(value, [
    'version', 'implementation_status', 'product_source', 'controllers', 'phases', 'invariants',
    'receipt_requirements', 'foreground_attribution_requirements', 'restoration_requirements',
    'cursor_policy', 'prohibited_mechanisms',
  ]) || value.version !== 1) failures.push('schema');
  if (!exactKeys(value.implementation_status, [
    'state', 'live_enabled', 'required_owner', 'acceptance_blockers',
  ]) || value.implementation_status.state !== 'contract-only-blocked'
      || value.implementation_status.live_enabled !== false
      || value.implementation_status.required_owner
        !== 'centralized-epoch-publication-and-focus-event-time-monitor'
      || JSON.stringify(value.implementation_status.acceptance_blockers) !== JSON.stringify([
        'atomic-event-epoch-through-heartbeat-publication',
        'ack-gate-every-authorization-changing-revision',
        'notification-time-generation-and-exact-window-focus-evidence',
      ])) failures.push('implementation_status');
  if (!exactKeys(value.product_source, [
    'commit', 'tree', 'peer_binding', 'client_sha256', 'client_transport_sha256',
    'operation_policy_sha256', 'operation_receipt_models_sha256',
    'operation_receipts_sha256', 'operation_receipt_archive_maintenance_sha256',
    'operation_response_target_evidence_sha256', 'operation_result_semantics_sha256',
    'operation_session_claim_sha256', 'server_operation_receipts_sha256',
    'server_handshake_sha256', 'socket_io_sha256', 'host_clients_sha256',
    'private_archive_sha256',
  ]) || value.product_source.peer_binding !== 'darwin-audit-token-pidversion-euid-cdhash-v1') {
    failures.push('source');
  }
  if (!Array.isArray(value.controllers) || value.controllers.length !== 2
      || value.controllers.map((entry) => entry.id).join(',') !== 'peekaboo,integrated-computer-use'
      || value.controllers[0].interaction_mode !== 'background'
      || value.controllers[1].interaction_mode !== 'foreground'
      || value.controllers[1].operation_evidence
        !== 'required-native-monitor-event-attribution-not-implemented') failures.push('controllers');
  for (const key of ['phases', 'invariants', 'receipt_requirements', 'restoration_requirements']) {
    if (!Array.isArray(value[key]) || value[key].length === 0
        || new Set(value[key]).size !== value[key].length) failures.push(key);
  }
  const mandatoryReceiptRequirements = [
    'complete-anchored-first-party-verdict-set',
    'first-party-offline-bundle-bijection',
    'exact-operation-request-session-binding',
    'catalog-derived-exact-operation-manifest',
  ];
  if (mandatoryReceiptRequirements.some((entry) => !value.receipt_requirements.includes(entry))) {
    failures.push('receipt_verdict_set');
  }
  if (value.cursor_policy !== 'observational') failures.push('cursor');
  const prohibited = new Set(value.prohibited_mechanisms ?? []);
  for (const mechanism of ['virtualization', 'lume', 'vnc', 'applescript', 'jxa']) {
    if (!prohibited.has(mechanism)) failures.push(`prohibited:${mechanism}`);
  }
  if (!exactKeys(value.foreground_attribution_requirements, [
    'minimum_event_count', 'active_target_set', 'grant_revision_monotonic',
    'baseline_revision_acknowledged', 'grant_revision_acknowledged_before_input',
    'exactly_one_controller_while_active', 'revoke_before_clean_sample',
    'revoke_revision_acknowledged_before_restore', 'zero_controllers_after_revoke',
    'post_revoke_clean_sample', 'unexpected_activation_fails',
  ]) || value.foreground_attribution_requirements.minimum_event_count < 1
      || value.foreground_attribution_requirements.grant_revision_monotonic !== true
      || value.foreground_attribution_requirements.baseline_revision_acknowledged !== true
      || value.foreground_attribution_requirements.grant_revision_acknowledged_before_input !== true
      || value.foreground_attribution_requirements.exactly_one_controller_while_active !== true
      || value.foreground_attribution_requirements.revoke_before_clean_sample !== true
      || value.foreground_attribution_requirements.revoke_revision_acknowledged_before_restore !== true
      || value.foreground_attribution_requirements.zero_controllers_after_revoke !== true
      || value.foreground_attribution_requirements.post_revoke_clean_sample !== true
      || value.foreground_attribution_requirements.unexpected_activation_fails !== true) {
    failures.push('foreground_attribution');
  }
  return failures;
}

test('frozen physical overlap catalog pins exact PR 487 protocol owners', () => {
  assert.deepEqual(validate(catalog), []);
  assert.equal(catalog.product_source.commit, 'e68a46c227b957ee8a430ecfcb002162b0eb0bbb');
  assert.equal(
    execFileSync('git', ['rev-parse', `${catalog.product_source.commit}^{tree}`], {
      cwd: root,
      encoding: 'utf8',
    }).trim(),
    catalog.product_source.tree,
  );
  const sourceOwners = [
    ['client_sha256', 'PeekabooBridgeClient.swift'],
    ['client_transport_sha256', 'PeekabooBridgeClient+Transport.swift'],
    ['operation_policy_sha256', 'PeekabooBridgeOperation+Policy.swift'],
    ['operation_receipt_models_sha256', 'PeekabooBridgeOperationReceiptModels.swift'],
    ['operation_receipts_sha256', 'PeekabooBridgeOperationReceipts.swift'],
    ['operation_receipt_archive_maintenance_sha256', 'PeekabooBridgeOperationReceiptArchiveMaintenance.swift'],
    ['operation_response_target_evidence_sha256', 'PeekabooBridgeOperationResponseTargetEvidence.swift'],
    ['operation_result_semantics_sha256', 'PeekabooBridgeOperationResultSemantics.swift'],
    ['operation_session_claim_sha256', 'PeekabooBridgeOperationSessionClaim.swift'],
    ['server_operation_receipts_sha256', 'PeekabooBridgeServer+OperationReceipts.swift'],
    ['server_handshake_sha256', 'PeekabooBridgeServer+Handshake.swift'],
    ['socket_io_sha256', 'PeekabooBridgeSocketIO.swift'],
    ['host_clients_sha256', 'PeekabooBridgeHost+Clients.swift'],
    ['private_archive_sha256', 'PeekabooBridgePrivateReceiptArchive.swift'],
  ];
  for (const [field, filename] of sourceOwners) {
    assert.equal(
      sha256AtPinnedCommit(`Core/PeekabooCore/Sources/PeekabooBridge/${filename}`),
      catalog.product_source[field],
      field,
    );
  }
});

test('catalog cannot weaken mode attribution restoration or prohibited mechanisms', () => {
  const live = structuredClone(catalog);
  live.implementation_status.live_enabled = true;
  assert.ok(validate(live).includes('implementation_status'));

  const foreground = structuredClone(catalog);
  foreground.controllers[0].interaction_mode = 'foreground';
  assert.ok(validate(foreground).includes('controllers'));

  const cursor = structuredClone(catalog);
  cursor.cursor_policy = 'unchanged';
  assert.ok(validate(cursor).includes('cursor'));

  const attribution = structuredClone(catalog);
  attribution.foreground_attribution_requirements.minimum_event_count = 0;
  assert.ok(validate(attribution).includes('foreground_attribution'));

  const activeCardinality = structuredClone(catalog);
  activeCardinality.foreground_attribution_requirements.exactly_one_controller_while_active = false;
  assert.ok(validate(activeCardinality).includes('foreground_attribution'));

  const revokeCardinality = structuredClone(catalog);
  revokeCardinality.foreground_attribution_requirements.zero_controllers_after_revoke = false;
  assert.ok(validate(revokeCardinality).includes('foreground_attribution'));

  const staleGrant = structuredClone(catalog);
  staleGrant.foreground_attribution_requirements.grant_revision_acknowledged_before_input = false;
  assert.ok(validate(staleGrant).includes('foreground_attribution'));

  const earlyRestore = structuredClone(catalog);
  earlyRestore.foreground_attribution_requirements.revoke_revision_acknowledged_before_restore = false;
  assert.ok(validate(earlyRestore).includes('foreground_attribution'));

  const virtualized = structuredClone(catalog);
  virtualized.prohibited_mechanisms = virtualized.prohibited_mechanisms.filter(
    (entry) => entry !== 'virtualization',
  );
  assert.ok(validate(virtualized).includes('prohibited:virtualization'));

  const duplicate = structuredClone(catalog);
  duplicate.invariants[1] = duplicate.invariants[0];
  assert.ok(validate(duplicate).includes('invariants'));

  const summaryOnlyReceipts = structuredClone(catalog);
  summaryOnlyReceipts.receipt_requirements = summaryOnlyReceipts.receipt_requirements.filter(
    (entry) => entry !== 'complete-anchored-first-party-verdict-set',
  );
  assert.ok(validate(summaryOnlyReceipts).includes('receipt_verdict_set'));
});
