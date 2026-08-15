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

function sha256(relativePath) {
  return createHash('sha256').update(fs.readFileSync(path.join(root, relativePath))).digest('hex');
}

function exactKeys(value, expected) {
  return value && typeof value === 'object' && !Array.isArray(value)
    && JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort());
}

function validate(value) {
  const failures = [];
  if (!exactKeys(value, [
    'version', 'product_source', 'controllers', 'phases', 'invariants', 'receipt_requirements',
    'foreground_attribution_requirements', 'restoration_requirements', 'cursor_policy',
    'prohibited_mechanisms',
  ]) || value.version !== 1) failures.push('schema');
  if (!exactKeys(value.product_source, [
    'commit', 'tree', 'peer_binding', 'operation_receipts_sha256', 'socket_io_sha256',
    'host_clients_sha256', 'private_archive_sha256',
  ]) || value.product_source.peer_binding !== 'darwin-audit-token-pidversion-euid-cdhash-v1') {
    failures.push('source');
  }
  if (!Array.isArray(value.controllers) || value.controllers.length !== 2
      || value.controllers.map((entry) => entry.id).join(',') !== 'peekaboo,integrated-computer-use'
      || value.controllers[0].interaction_mode !== 'background'
      || value.controllers[1].interaction_mode !== 'foreground') failures.push('controllers');
  for (const key of ['phases', 'invariants', 'receipt_requirements', 'restoration_requirements']) {
    if (!Array.isArray(value[key]) || value[key].length === 0
        || new Set(value[key]).size !== value[key].length) failures.push(key);
  }
  if (value.cursor_policy !== 'observational') failures.push('cursor');
  const prohibited = new Set(value.prohibited_mechanisms ?? []);
  for (const mechanism of ['virtualization', 'lume', 'vnc', 'applescript', 'jxa']) {
    if (!prohibited.has(mechanism)) failures.push(`prohibited:${mechanism}`);
  }
  if (!exactKeys(value.foreground_attribution_requirements, [
    'minimum_event_count', 'active_target_set', 'grant_revision_monotonic',
    'revoke_before_clean_sample', 'unexpected_activation_fails',
  ]) || value.foreground_attribution_requirements.minimum_event_count < 1
      || value.foreground_attribution_requirements.grant_revision_monotonic !== true
      || value.foreground_attribution_requirements.revoke_before_clean_sample !== true
      || value.foreground_attribution_requirements.unexpected_activation_fails !== true) {
    failures.push('foreground_attribution');
  }
  return failures;
}

test('frozen physical overlap catalog pins exact PR 487 protocol owners', () => {
  assert.deepEqual(validate(catalog), []);
  assert.equal(catalog.product_source.commit, 'a712664b14f0cbe569bbdd3186f1e5a188e7c70c');
  assert.equal(
    execFileSync('git', ['rev-parse', `${catalog.product_source.commit}^{tree}`], {
      cwd: root,
      encoding: 'utf8',
    }).trim(),
    catalog.product_source.tree,
  );
  assert.equal(
    sha256('Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeOperationReceipts.swift'),
    catalog.product_source.operation_receipts_sha256,
  );
  assert.equal(
    sha256('Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeSocketIO.swift'),
    catalog.product_source.socket_io_sha256,
  );
  assert.equal(
    sha256('Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgeHost+Clients.swift'),
    catalog.product_source.host_clients_sha256,
  );
  assert.equal(
    sha256('Core/PeekabooCore/Sources/PeekabooBridge/PeekabooBridgePrivateReceiptArchive.swift'),
    catalog.product_source.private_archive_sha256,
  );
});

test('catalog cannot weaken mode attribution restoration or prohibited mechanisms', () => {
  const foreground = structuredClone(catalog);
  foreground.controllers[0].interaction_mode = 'foreground';
  assert.ok(validate(foreground).includes('controllers'));

  const cursor = structuredClone(catalog);
  cursor.cursor_policy = 'unchanged';
  assert.ok(validate(cursor).includes('cursor'));

  const attribution = structuredClone(catalog);
  attribution.foreground_attribution_requirements.minimum_event_count = 0;
  assert.ok(validate(attribution).includes('foreground_attribution'));

  const virtualized = structuredClone(catalog);
  virtualized.prohibited_mechanisms = virtualized.prohibited_mechanisms.filter(
    (entry) => entry !== 'virtualization',
  );
  assert.ok(validate(virtualized).includes('prohibited:virtualization'));

  const duplicate = structuredClone(catalog);
  duplicate.invariants[1] = duplicate.invariants[0];
  assert.ok(validate(duplicate).includes('invariants'));
});
