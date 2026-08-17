import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  aggregateSHA256,
  computeDigestClaim,
  deriveCertificationRunID,
  makeLiveCertificationContract,
  makeLivePIDAttestationPlan,
  monitorHistoryCommitmentSHA256,
  projectFinalizerSourceBytes,
  requireCanonicalDiagnosticReportsDirectory,
  validateCatalog,
  validateMultiTargetCertificationStructure,
  makeOperationManifest,
  readCertificationArtifacts,
  verifyDigestClaims,
  verifyCurrentBuildSourceBinding,
} from '../scripts/finalize-multi-target-certification.mjs';
import {
  makeMultiTargetFixture,
  makeControllerReceipts,
  rehashFixture,
  writeFixtureArtifact,
} from './multi-target-certification-fixture.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const catalogPath = path.join(root, 'scripts/multi-target-certification-catalog.json');
const catalogBytes = fs.readFileSync(catalogPath);
const catalog = JSON.parse(catalogBytes);
const catalogFileSHA256 = createHash('sha256').update(catalogBytes).digest('hex');

function makeFixture() {
  return makeMultiTargetFixture(catalog, catalogFileSHA256);
}

function assemble(fixture, controllerReceipts = makeControllerReceipts(fixture)) {
  return makeLiveCertificationContract({
    catalog,
    catalogSHA256: catalogFileSHA256,
    controllerReceipts,
    bundles: fixture.bundles,
    monitorEvidence: fixture.evidence.monitor_evidence,
    firstPartyValidator: fixture.contract.first_party_validator,
    socketEndpoint: fixture.contract.socket_endpoint,
  });
}

function fixtureFirstPartyValidator(fixture) {
  const rows = new Map(fixture.firstPartyVerdicts.map((row) => [row.slot_id, row]));
  return async ({ slot }) => structuredClone(rows.get(slot.slot_id)?.verdict);
}

async function finalize(fixture) {
  return validateMultiTargetCertificationStructure({
    catalog,
    catalogFileSHA256,
    ...fixture,
    firstPartyValidator: fixtureFirstPartyValidator(fixture),
  });
}

function refreshBundle(fixture, index) {
  const bundle = fixture.bundles[index];
  bundle.bytes = Buffer.from(`${JSON.stringify(bundle.document, null, 2)}\n`, 'utf8');
  bundle.sha256 = createHash('sha256').update(bundle.bytes).digest('hex');
  fixture.manifest.slots[index].bundle_sha256 = bundle.sha256;
  fixture.firstPartyVerdicts[index].file_sha256 = bundle.sha256;
  fixture.firstPartyVerdicts[index].verdict.bundle_sha256 = bundle.sha256;
  rehashFixture(fixture, catalogFileSHA256);
}

async function assertRejected(fixture, message) {
  const result = await finalize(fixture);
  assert.equal('success' in result, false, message);
  assert.equal('certified' in result, false, message);
  assert.equal(result.structural_validation_passed, false, message);
  assert.ok(result.failures.length > 0, message);
  return result;
}

test('complete synthetic fixture is structurally valid but cannot mint a live certificate', async () => {
  const fixture = makeFixture();
  const result = await finalize(fixture);
  assert.equal('success' in result, false);
  assert.equal('certified' in result, false);
  assert.equal(result.structural_validation_passed, true);
  assert.equal(result.foreground_task_postcondition_passed, true);
  assert.deepEqual(result.failures.map((entry) => entry.rule), ['live_execution_required']);
  assert.equal(result.version, 2);
  assert.equal(result.controlled_targets.length, 2);
  assert.equal(result.slot_verdicts.length, catalog.slots.length);
  assert.equal(result.offline_protocol_validation.version, 3);
  assert.equal(result.offline_protocol_validation.success, true);
  assert.equal(result.offline_protocol_validation.receipts.length, catalog.slots.length);
  assert.ok(result.slot_verdicts.every((row) => row.passed));
  assert.equal(result.operation_manifest_sha256, aggregateSHA256('operation-manifest', fixture.manifest));

  const repeated = result.offline_protocol_validation.receipts.filter((row) => (
    row.controller_id === 'controller-a' && row.operation === 'desktopObservation'
  ));
  assert.equal(repeated.length, 2);
  assert.equal(repeated[0].session_id, repeated[1].session_id);
  assert.notEqual(repeated[0].session_sequence, repeated[1].session_sequence);
  assert.notEqual(repeated[0].request_id, repeated[1].request_id);
});

test('canonical requests retain and unwrap their outer attested-operation carriage', async () => {
  const fixture = makeFixture();
  for (const bundle of fixture.bundles) {
    const request = JSON.parse(Buffer.from(bundle.document.canonicalRequest, 'base64'));
    assert.deepEqual(Object.keys(request), ['attestedOperation']);
    assert.equal(
      request.attestedOperation._0.requestID,
      bundle.document.receipt.payload.requestID,
    );
  }

  const result = await finalize(fixture);
  assert.equal(result.structural_validation_passed, true);
  assert.ok(fixture.contract.operation_slots.every((slot) => (
    slot.request_envelope_case === 'attestedOperation'
  )));
});

test('attested-operation carriage must match its signed receipt identity', async () => {
  const fixture = makeMultiTargetFixture(catalog, catalogFileSHA256, {
    mismatchAttestedRequestID: true,
  });
  const result = await assertRejected(fixture, 'attested request ID mismatch');
  assert.ok(result.failures.some((entry) => entry.rule === 'offline_bundle_validation'));
});

test('signed observation and typing semantics must match their target and request', async (t) => {
  await t.test('desktop observation window', async () => {
    const fixture = makeMultiTargetFixture(catalog, catalogFileSHA256, {
      desktopObservationWindowIDOverride: 1,
    });
    const result = await assertRejected(fixture, 'desktop observation target mismatch');
    assert.ok(result.failures.some((entry) => entry.rule === 'offline_bundle_validation'));
  });

  await t.test('desktop observation foreground focus', async () => {
    const fixture = makeMultiTargetFixture(catalog, catalogFileSHA256, {
      desktopObservationFocusOverride: 'foreground',
    });
    const result = await assertRejected(fixture, 'desktop observation foreground focus');
    assert.ok(result.failures.some((entry) => entry.rule === 'offline_bundle_validation'));
  });

  await t.test('desktop observation response target', async () => {
    const fixture = makeMultiTargetFixture(catalog, catalogFileSHA256, {
      desktopObservationResponseWindowIDOverride: 1,
    });
    const result = await assertRejected(fixture, 'desktop observation response target drift');
    assert.ok(result.failures.some((entry) => entry.rule === 'offline_bundle_validation'));
  });

  await t.test('desktop observation content digest', async () => {
    const fixture = makeMultiTargetFixture(catalog, catalogFileSHA256, {
      desktopObservationDigestDrift: true,
    });
    const result = await assertRejected(fixture, 'desktop observation content digest drift');
    assert.ok(result.failures.some((entry) => entry.rule === 'offline_bundle_validation'));
  });

  const observationMetadataDrifts = [
    ['capture size', { desktopObservationMetadataSizeOverride: [641, 480] }],
    ['window bounds', {
      desktopObservationMetadataBoundsOverride: [[11, 20], [640, 480]],
    }],
    ['minimized state', { desktopObservationMetadataMinimizedOverride: true }],
  ];
  for (const [name, options] of observationMetadataDrifts) {
    await t.test(`desktop observation metadata ${name}`, async () => {
      const fixture = makeMultiTargetFixture(catalog, catalogFileSHA256, options);
      const result = await assertRejected(fixture, `desktop observation metadata ${name} drift`);
      assert.ok(result.failures.some((entry) => entry.rule === 'offline_bundle_validation'));
    });
  }

  await t.test('type result counts', async () => {
    const fixture = makeMultiTargetFixture(catalog, catalogFileSHA256, {
      typeResultCountDelta: 1,
    });
    const result = await assertRejected(fixture, 'type result count mismatch');
    assert.ok(result.failures.some((entry) => entry.rule === 'offline_bundle_validation'));
  });

  const typeTargetDrifts = [
    ['window', { exactWindowTypeWindowIDOverride: 1 }],
    ['pid', { exactWindowTypePIDOverride: 9991 }],
    ['generation', { exactWindowTypeStartIdentityOverride: 999100 }],
    ['bounds', { exactWindowTypeBoundsOverride: [[11, 20], [640, 480]] }],
    ['minimized', { exactWindowTypeMinimizedOverride: true }],
  ];
  for (const [name, options] of typeTargetDrifts) {
    await t.test(`exact-window type target ${name}`, async () => {
      const fixture = makeMultiTargetFixture(catalog, catalogFileSHA256, options);
      const result = await assertRejected(fixture, `exact-window type target ${name} mismatch`);
      assert.ok(result.failures.some((entry) => entry.rule === 'offline_bundle_validation'));
    });
  }
});

test('synthetic type results count Unicode extended grapheme clusters like Swift String', async () => {
  const text = 'e\u0301👨‍👩‍👧‍👦';
  const fixture = makeMultiTargetFixture(catalog, catalogFileSHA256, {
    typeTextOverride: text,
  });
  const result = await finalize(fixture);
  assert.equal(result.structural_validation_passed, true);

  const typeBundles = fixture.bundles.filter((bundle) => (
    bundle.document.receipt.payload.operation === 'exactWindowTargetedTypeActions'
  ));
  assert.equal(typeBundles.length, 2);
  for (const bundle of typeBundles) {
    const request = JSON.parse(Buffer.from(bundle.document.canonicalRequest, 'base64'));
    const payload = request.attestedOperation._0.request
      .projectedAction._0.request.exactWindowTargetedTypeActions._0;
    const response = JSON.parse(Buffer.from(bundle.document.canonicalResponse, 'base64'));
    const counts = response.projectedAction._0.response.typeResult._0;
    assert.equal(payload.actions[0].text, text);
    assert.deepEqual(counts, { totalCharacters: 2, keyPresses: 2 });
  }
});

test('window generations above 2^53 retain exact UInt64 JSON identity', async () => {
  const generation = '9007199254740993';
  const fixture = makeMultiTargetFixture(catalog, catalogFileSHA256, {
    targetStartIdentityOverride: generation,
  });
  const result = await finalize(fixture);
  assert.equal(result.structural_validation_passed, true);

  const numericToken = `"ownerProcessStartIdentity":${generation}`;
  const appToken = `"processStartIdentity":${generation}`;
  const requestDocuments = fixture.bundles.map((bundle) => (
    Buffer.from(bundle.document.canonicalRequest, 'base64').toString('utf8')
  ));
  const responseDocuments = fixture.bundles.map((bundle) => (
    Buffer.from(bundle.document.canonicalResponse, 'base64').toString('utf8')
  ));
  assert.ok(requestDocuments.filter((document) => document.includes(numericToken)).length >= 4);
  assert.ok(responseDocuments.filter((document) => (
    document.includes(numericToken) && document.includes(appToken)
  )).length >= 4);
});

test('adjacent lossy UInt64 generations cannot collide across operation wires', async (t) => {
  const targetGeneration = '9007199254740993';
  const adjacentGeneration = '9007199254740992';
  const cases = [
    ['type', { exactWindowTypeStartIdentityOverride: adjacentGeneration }],
    ['observation', { desktopObservationResponseStartIdentityOverride: adjacentGeneration }],
    ['click', { protocolClickStartIdentityOverride: adjacentGeneration }],
  ];
  for (const [name, options] of cases) {
    await t.test(name, async () => {
      const fixture = makeMultiTargetFixture(catalog, catalogFileSHA256, {
        targetStartIdentityOverride: targetGeneration,
        ...options,
      });
      const result = await assertRejected(fixture, `${name} UInt64 generation collision`);
      assert.ok(result.failures.some((entry) => entry.rule === 'offline_bundle_validation'));
    });
  }
});

test('quoted UInt64 strings cannot masquerade as numeric operation identities', async (t) => {
  const generation = '9007199254740993';
  const cases = [
    ['type', { exactWindowTypeStartIdentityAsString: true }],
    ['observation', { desktopObservationResponseStartIdentityAsString: true }],
    ['click', { protocolClickStartIdentityAsString: true }],
  ];
  for (const [name, options] of cases) {
    await t.test(name, async () => {
      const fixture = makeMultiTargetFixture(catalog, catalogFileSHA256, {
        targetStartIdentityOverride: generation,
        ...options,
      });
      const result = await assertRejected(fixture, `${name} quoted UInt64 identity`);
      assert.ok(result.failures.some((entry) => entry.rule === 'offline_bundle_validation'));
    });
  }
});

test('retained verdict JSON cannot substitute for an active first-party verifier', async () => {
  const fixture = makeFixture();
  const result = await validateMultiTargetCertificationStructure({
    catalog,
    catalogFileSHA256,
    ...fixture,
  });
  assert.equal('success' in result, false);
  assert.equal('certified' in result, false);
  assert.equal(result.structural_validation_passed, false);
  assert.ok(result.failures.some((entry) => entry.rule === 'first_party_execution'));
  assert.ok(result.slot_verdicts.every((row) => !row.passed));
});

test('omitted requests cannot leave a gap in a signed operation session', async () => {
  const fixture = makeMultiTargetFixture(catalog, catalogFileSHA256, {
    gapControllerASession: true,
  });
  const result = await assertRejected(fixture, 'session claim gap');
  assert.ok(result.failures.some((entry) => entry.rule === 'offline_session_completeness'));
});

test('production preparer derives the closed manifest from canonical raw exports', () => {
  const fixture = makeFixture();
  const manifest = makeOperationManifest(
    catalog,
    catalogFileSHA256,
    fixture.contract,
    fixture.bundles,
  );
  assert.deepEqual(manifest, fixture.manifest);
});

test('source-owned assembler derives the exact v4 contract from controller and monitor evidence', () => {
  const fixture = makeFixture();
  assert.deepEqual(assemble(fixture), fixture.contract);
});

test('source-owned assembler preserves finite fractional macOS point geometry', () => {
  const fixture = makeMultiTargetFixture(catalog, catalogFileSHA256, {
    fractionalBounds: true,
  });
  assert.deepEqual(assemble(fixture), fixture.contract);
  assert.deepEqual(fixture.contract.controlled_targets[0].target.bounds, {
    x: 10.25,
    y: 20.5,
    width: 640.75,
    height: 480.125,
  });
});

test('source-owned assembler rejects nonfinite and nonpositive target geometry', () => {
  const invalidGeometry = [
    ['x', Number.NaN],
    ['x', Number.POSITIVE_INFINITY],
    ['height', Number.NEGATIVE_INFINITY],
    ['width', Number.MAX_SAFE_INTEGER + 1],
    ['width', 0],
    ['height', -1],
    ['width', -0],
  ];
  for (const [key, value] of invalidGeometry) {
    const fixture = makeFixture();
    const receipts = makeControllerReceipts(fixture);
    receipts[0].target.bounds[key] = value;
    assert.throws(
      () => assemble(fixture, receipts),
      /controller receipt is not one closed four-slot passed run/,
      `invalid target bounds ${key}=${String(value)}`,
    );
  }
});

test('live crash scans require the current user canonical DiagnosticReports directory', () => {
  const temporary = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'peekaboo-crash-binding-')));
  try {
    const home = path.join(temporary, 'home');
    const expected = path.join(home, 'Library', 'Logs', 'DiagnosticReports');
    const decoy = path.join(temporary, 'decoy');
    fs.mkdirSync(expected, { recursive: true });
    fs.mkdirSync(decoy);

    assert.equal(
      requireCanonicalDiagnosticReportsDirectory(expected, { homeDirectory: home }),
      expected,
    );
    assert.throws(
      () => requireCanonicalDiagnosticReportsDirectory(decoy, { homeDirectory: home }),
      /current user DiagnosticReports/,
    );
    assert.throws(
      () => requireCanonicalDiagnosticReportsDirectory(
        '/Users/fixture/Library/Logs/DiagnosticReports',
        { homeDirectory: home },
      ),
      /current user DiagnosticReports/,
    );

    fs.rmSync(expected, { recursive: true });
    fs.symlinkSync(decoy, expected);
    assert.throws(
      () => requireCanonicalDiagnosticReportsDirectory(expected, { homeDirectory: home }),
      /not canonical/,
    );
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

test('live PID attestation plan carries the exact peer receipt and no legacy PID field', () => {
  const fixture = makeFixture();
  const expectedPeer = fixture.contract.controlled_targets[0].controller;
  const plan = makeLivePIDAttestationPlan({
    contract: fixture.contract,
    responseKind: 'monitor',
    socketPath: fixture.contract.monitor_binding.monitor_attestation_socket_path,
    expectedProcess: expectedPeer,
    temporaryDirectory: '/private/tmp/peekaboo-live-pid-plan',
    outputPath: '/private/tmp/peekaboo-live-pid-plan/response.json',
    releasePath: '/private/tmp/peekaboo-live-pid-plan/release.json',
  });
  assert.deepEqual(Object.keys(plan).sort(), [
    'artifacts_directory', 'execution_nonce', 'expected_peer', 'maximum_response_bytes',
    'monitor_instance_id', 'output_path', 'release_path', 'response_kind',
    'socket_path', 'timeout_milliseconds', 'version',
  ]);
  assert.deepEqual(plan.expected_peer, expectedPeer);
  assert.equal('expected_peer_pid' in plan, false);
});

test('controller receipts require explicit canonical nulls for optional target and handshake metadata', () => {
  const fixture = makeFixture();
  const receipts = makeControllerReceipts(fixture);
  for (const receipt of receipts) {
    receipt.handshake.build = null;
    receipt.handshake.host.bundle_identifier = null;
    receipt.handshake.host.bundle_short_version = null;
    receipt.handshake.host.bundle_version = null;
  }
  assert.deepEqual(assemble(fixture, receipts), fixture.contract);

  const missingPaths = [
    ['target', 'is_minimized'],
    ['handshake', 'build'],
    ['handshake', 'host', 'bundle_identifier'],
    ['handshake', 'host', 'bundle_short_version'],
    ['handshake', 'host', 'bundle_version'],
  ];
  for (const keys of missingPaths) {
    const incomplete = structuredClone(receipts);
    let parent = incomplete[0];
    for (const key of keys.slice(0, -1)) parent = parent[key];
    delete parent[keys.at(-1)];
    assert.throws(
      () => assemble(fixture, incomplete),
      /controller receipt is not one closed four-slot passed run/,
      `missing canonical null at ${keys.join('.')}`,
    );
  }
});

test('source-owned assembler rejects controller, socket, and bundle aggregation drift', () => {
  const duplicate = makeFixture();
  const duplicateReceipts = makeControllerReceipts(duplicate);
  duplicateReceipts[1] = structuredClone(duplicateReceipts[0]);
  assert.throws(() => assemble(duplicate, duplicateReceipts), /controller receipt/);

  const wrongSocket = makeFixture();
  const wrongSocketReceipts = makeControllerReceipts(wrongSocket);
  wrongSocketReceipts[1].handshake.socket_path = '/private/tmp/other.sock';
  assert.throws(() => assemble(wrongSocket, wrongSocketReceipts), /handshake differs/);

  const wrongBuild = makeFixture();
  const wrongBuildReceipts = makeControllerReceipts(wrongBuild);
  wrongBuildReceipts[1].build.executable_sha256 = '0'.repeat(64);
  assert.throws(() => assemble(wrongBuild, wrongBuildReceipts), /exact source-authenticated build/);

  const missingBundle = makeFixture();
  const missingBundleReceipts = makeControllerReceipts(missingBundle);
  missingBundle.bundles.pop();
  assert.throws(() => assemble(missingBundle, missingBundleReceipts), /closed signed corpus/);
});

test('source-owned assembler requires one current-build commit across every signed executable', () => {
  const wrongController = makeFixture();
  const wrongControllerReceipts = makeControllerReceipts(wrongController);
  wrongControllerReceipts[1].build.source_commit = 'd'.repeat(40);
  assert.throws(
    () => assemble(wrongController, wrongControllerReceipts),
    /exact source-authenticated build/,
  );

  const wrongValidator = makeFixture();
  wrongValidator.contract.first_party_validator.source_commit = 'd'.repeat(40);
  assert.throws(
    () => assemble(wrongValidator),
    /controller, validator, and listener host/,
  );

  const wrongListener = makeFixture();
  const wrongListenerReceipts = makeControllerReceipts(wrongListener);
  for (const receipt of wrongListenerReceipts) receipt.handshake.host.source_commit = 'd'.repeat(40);
  assert.throws(
    () => assemble(wrongListener, wrongListenerReceipts),
    /controller, validator, and listener host/,
  );
});

test('documented digest command reproduces every aggregate root', async () => {
  const fixture = makeFixture();
  const summary = await finalize(fixture);
  assert.equal(
    computeDigestClaim({
      kindID: 'contract',
      inputBytes: Buffer.from(JSON.stringify(fixture.contract)),
    }).digest,
    summary.contract_sha256,
  );
  assert.equal(
    computeDigestClaim({
      kindID: 'operation-manifest',
      inputBytes: Buffer.from(JSON.stringify(fixture.manifest)),
    }).digest,
    summary.operation_manifest_sha256,
  );
  assert.equal(
    computeDigestClaim({
      kindID: 'summary-core',
      inputBytes: Buffer.from(JSON.stringify(summary)),
    }).digest,
    summary.summary_core_sha256,
  );
  assert.equal(
    computeDigestClaim({
      kindID: 'run-binding',
      inputBytes: Buffer.from(JSON.stringify(fixture.contract)),
    }).digest,
    summary.run_binding_sha256,
  );
  const cachedEvidence = structuredClone(fixture.evidence);
  cachedEvidence.offline_protocol_validation = { success: true };
  assert.equal(
    computeDigestClaim({
      kindID: 'raw-evidence',
      inputBytes: Buffer.from(JSON.stringify(cachedEvidence)),
    }).digest,
    summary.sanitized_raw_evidence_sha256,
  );
});

test('digest verifier rejects every claimed root and leaf mismatch', async (t) => {
  const fixture = makeFixture();
  const summary = await finalize(fixture);
  const mutations = [
    ['digest-spec-file', (value) => { value.digest_spec_sha256 = '0'.repeat(64); }],
    ['catalog-file', (value) => { value.catalog_file_sha256 = '0'.repeat(64); }],
    ['contract', (value) => { value.contract_sha256 = '0'.repeat(64); }],
    ['run-binding', (value) => { value.run_binding_sha256 = '0'.repeat(64); }],
    ['operation-manifest', (value) => { value.operation_manifest_sha256 = '0'.repeat(64); }],
    ['raw-evidence', (value) => { value.sanitized_raw_evidence_sha256 = '0'.repeat(64); }],
    ['monitor-evidence', (value) => { value.monitor_evidence_sha256 = '0'.repeat(64); }],
    ['monitor-baseline', (value) => {
      value.monitor_baseline_commitment_sha256 = '0'.repeat(64);
    }],
    ['monitor-history', (value) => {
      value.monitor_history_commitment_sha256 = '0'.repeat(64);
    }],
    ['foreground-postcondition', (value) => {
      value.foreground_postcondition_sha256 = '0'.repeat(64);
    }],
    ['raw-bundle-inventory', (value) => { value.raw_bundle_inventory_sha256 = '0'.repeat(64); }],
    ['first-party-verdict-set', (value) => { value.first_party_verdict_set_sha256 = '0'.repeat(64); }],
    ['offline-protocol-validation', (value) => {
      value.offline_protocol_validation_sha256 = '0'.repeat(64);
    }],
    ['controller', (value) => { value.controlled_targets[0].controller_sha256 = '0'.repeat(64); }],
    ['controlled-target', (value) => { value.controlled_targets[0].target_sha256 = '0'.repeat(64); }],
    ['manifest-slot', (value) => { value.slot_verdicts[0].manifest_slot_sha256 = '0'.repeat(64); }],
    ['bundle-file', (value) => { value.slot_verdicts[0].bundle_sha256 = '0'.repeat(64); }],
    ['first-party-verdict', (value) => { value.slot_verdicts[0].first_party_verdict_sha256 = '0'.repeat(64); }],
    ['offline-receipt', (value) => { value.slot_verdicts[0].offline_receipt_sha256 = '0'.repeat(64); }],
    ['summary-core', (value) => { value.summary_core_sha256 = '0'.repeat(64); }],
  ];
  for (const [kind, mutate] of mutations) {
    await t.test(kind, () => {
      const changed = structuredClone(summary);
      mutate(changed);
      const result = verifyDigestClaims({ catalogBytes, artifacts: fixture, summary: changed });
      assert.equal(result.success, false);
      assert.ok(result.checks.some((entry) => entry.kind === kind && !entry.match));
    });
  }
  const unknownField = structuredClone(summary);
  unknownField.unrecognized_projection = true;
  assert.equal(verifyDigestClaims({ catalogBytes, artifacts: fixture, summary: unknownField }).success, false);

  const forgedAuthority = structuredClone(summary);
  forgedAuthority.success = true;
  const forgedAuthorityResult = verifyDigestClaims({
    catalogBytes,
    artifacts: fixture,
    summary: forgedAuthority,
  });
  assert.equal(forgedAuthorityResult.success, false);
  assert.ok(forgedAuthorityResult.failures.some((entry) => entry.kind === 'summary'));
});

test('digest verifier requires bijective target and slot coverage', async (t) => {
  const fixture = makeFixture();
  const baseline = await finalize(fixture);
  const recomputeSummaryCore = (summary) => {
    summary.summary_core_sha256 = computeDigestClaim({
      kindID: 'summary-core',
      inputBytes: Buffer.from(JSON.stringify(summary)),
    }).digest;
  };
  const cases = [
    ['controlled targets', (summary) => {
      summary.controlled_targets[1] = structuredClone(summary.controlled_targets[0]);
    }],
    ['slot verdicts', (summary) => {
      summary.slot_verdicts[1] = structuredClone(summary.slot_verdicts[0]);
    }],
    ['first-party verdicts', (summary) => {
      summary.first_party_verdicts[1] = structuredClone(summary.first_party_verdicts[0]);
      summary.first_party_verdict_set_sha256 = computeDigestClaim({
        kindID: 'first-party-verdict-set',
        inputBytes: Buffer.from(JSON.stringify(summary.first_party_verdicts)),
      }).digest;
    }],
    ['offline receipts', (summary) => {
      summary.offline_protocol_validation.receipts[1] = structuredClone(
        summary.offline_protocol_validation.receipts[0],
      );
      summary.offline_protocol_validation_sha256 = computeDigestClaim({
        kindID: 'offline-protocol-validation',
        inputBytes: Buffer.from(JSON.stringify(summary.offline_protocol_validation)),
      }).digest;
    }],
  ];
  for (const [name, mutate] of cases) {
    await t.test(name, () => {
      const summary = structuredClone(baseline);
      mutate(summary);
      recomputeSummaryCore(summary);
      const result = verifyDigestClaims({ catalogBytes, artifacts: fixture, summary });
      assert.equal(result.success, false);
      assert.ok(result.failures.some((entry) => /cardinality differs/.test(entry.message)));
    });
  }
});

test('digest verifier binds every duplicated summary slot identity to the manifest', async (t) => {
  const fixture = makeFixture();
  const baseline = await finalize(fixture);
  for (const field of ['operation_id', 'request_id', 'session_id', 'session_sequence']) {
    await t.test(field, () => {
      const summary = structuredClone(baseline);
      const replacement = baseline.slot_verdicts.find((row) => (
        row[field] !== baseline.slot_verdicts[0][field]
      ));
      assert.ok(replacement, `fixture needs a distinct ${field}`);
      summary.slot_verdicts[0][field] = replacement[field];
      summary.summary_core_sha256 = computeDigestClaim({
        kindID: 'summary-core',
        inputBytes: Buffer.from(JSON.stringify(summary)),
      }).digest;
      const result = verifyDigestClaims({ catalogBytes, artifacts: fixture, summary });
      assert.equal(result.success, false);
      assert.ok(result.failures.some((entry) => (
        entry.kind === 'manifest-slot'
          && entry.subject === summary.slot_verdicts[0].slot_id
          && entry.message === 'Manifest and summary slot metadata differ'
      )));
    });
  }
});

test('paired deletion and extra valid evidence cannot redefine the source-controlled slot set', async () => {
  const pairedDeletion = makeFixture();
  pairedDeletion.contract.operation_slots.pop();
  pairedDeletion.manifest.slots.pop();
  pairedDeletion.firstPartyVerdicts.pop();
  pairedDeletion.bundles.pop();
  const runID = deriveCertificationRunID({
    catalogSHA256: catalogFileSHA256,
    listenerInstanceID: pairedDeletion.contract.listener.instance_id,
    executionNonce: pairedDeletion.contract.execution_nonce,
    currentBuildSource: pairedDeletion.contract.current_build_source,
    monitorBinding: pairedDeletion.contract.monitor_binding,
    controllerBuild: pairedDeletion.contract.controller_build,
    operationSlots: pairedDeletion.contract.operation_slots,
  });
  pairedDeletion.contract.certification_run_id = runID;
  pairedDeletion.contract.operation_slots.forEach((slot, index) => {
    slot.operation_id = `${runID}:${slot.slot_id}`;
    pairedDeletion.manifest.slots[index].operation_id = slot.operation_id;
  });
  rehashFixture(pairedDeletion, catalogFileSHA256);
  const pairedDeletionResult = await assertRejected(pairedDeletion, 'paired deletion');
  assert.ok(pairedDeletionResult.failures.some((entry) => entry.rule === 'contract_slots'));
  assert.ok(pairedDeletionResult.failures.every((entry) => entry.rule !== 'contract_run'));

  const extra = makeFixture();
  const original = extra.bundles[2];
  extra.bundles.push({
    file: 'auxiliary-checkpoint.json',
    sha256: original.sha256,
    bytes: Buffer.from(original.bytes),
    document: structuredClone(original.document),
  });
  await assertRejected(extra, 'extra valid bundle and auxiliary verdict');
});

test('same-operation cross-target slot swap fails after coherent ordinary rehashing', async () => {
  const fixture = makeFixture();
  const leftManifest = fixture.manifest.slots[0];
  const rightManifest = fixture.manifest.slots[1];
  [leftManifest.bundle_file, rightManifest.bundle_file] = [rightManifest.bundle_file, leftManifest.bundle_file];
  [leftManifest.bundle_sha256, rightManifest.bundle_sha256] = [
    rightManifest.bundle_sha256,
    leftManifest.bundle_sha256,
  ];
  const leftVerdict = fixture.firstPartyVerdicts[0];
  const rightVerdict = fixture.firstPartyVerdicts[1];
  [leftVerdict.bundle_file, rightVerdict.bundle_file] = [rightVerdict.bundle_file, leftVerdict.bundle_file];
  [leftVerdict.file_sha256, rightVerdict.file_sha256] = [
    rightVerdict.file_sha256,
    leftVerdict.file_sha256,
  ];
  [leftVerdict.verdict.bundle_sha256, rightVerdict.verdict.bundle_sha256] = [
    rightVerdict.verdict.bundle_sha256,
    leftVerdict.verdict.bundle_sha256,
  ];
  rehashFixture(fixture, catalogFileSHA256);
  await assertRejected(fixture, 'same operation cross-target swap');
});

test('same-target checkpoint and final-bounds receipts cannot swap slots', async () => {
  const fixture = makeFixture();
  const leftIndex = fixture.contract.operation_slots.findIndex((slot) => (
    slot.slot_id === 'controller-a-checkpoint-001'
  ));
  const rightIndex = fixture.contract.operation_slots.findIndex((slot) => (
    slot.slot_id === 'controller-a-final-bounds'
  ));
  const left = fixture.contract.operation_slots[leftIndex];
  const right = fixture.contract.operation_slots[rightIndex];
  const signedFields = [
    'controller', 'client', 'request_id', 'session', 'operation', 'request_envelope_case',
    'request_case', 'response_envelope_case', 'response_case', 'request_sha256',
    'response_sha256', 'target', 'focused_element', 'selected_leaf_evidence',
    'interval', 'source', 'expected_outcome',
  ];
  for (const field of signedFields) {
    [left[field], right[field]] = [structuredClone(right[field]), structuredClone(left[field])];
  }
  const leftManifest = fixture.manifest.slots[leftIndex];
  const rightManifest = fixture.manifest.slots[rightIndex];
  const manifestFields = [
    'bundle_file', 'bundle_sha256', 'client', 'request_id', 'session_id',
    'session_sequence', 'session_attestation_sha256', 'predecessor_session_id',
    'client_instance_id', 'operation', 'request_sha256', 'response_sha256',
  ];
  for (const field of manifestFields) {
    [leftManifest[field], rightManifest[field]] = [
      structuredClone(rightManifest[field]),
      structuredClone(leftManifest[field]),
    ];
  }
  const leftVerdict = fixture.firstPartyVerdicts[leftIndex];
  const rightVerdict = fixture.firstPartyVerdicts[rightIndex];
  [leftVerdict.bundle_file, rightVerdict.bundle_file] = [rightVerdict.bundle_file, leftVerdict.bundle_file];
  [leftVerdict.file_sha256, rightVerdict.file_sha256] = [rightVerdict.file_sha256, leftVerdict.file_sha256];
  [leftVerdict.verdict, rightVerdict.verdict] = [
    structuredClone(rightVerdict.verdict),
    structuredClone(leftVerdict.verdict),
  ];
  const runID = deriveCertificationRunID({
    catalogSHA256: catalogFileSHA256,
    listenerInstanceID: fixture.contract.listener.instance_id,
    executionNonce: fixture.contract.execution_nonce,
    currentBuildSource: fixture.contract.current_build_source,
    monitorBinding: fixture.contract.monitor_binding,
    controllerBuild: fixture.contract.controller_build,
    operationSlots: fixture.contract.operation_slots,
  });
  fixture.contract.certification_run_id = runID;
  fixture.contract.operation_slots.forEach((slot, index) => {
    slot.operation_id = `${runID}:${slot.slot_id}`;
    fixture.manifest.slots[index].operation_id = slot.operation_id;
  });
  rehashFixture(fixture, catalogFileSHA256);
  const result = await assertRejected(fixture, 'same-target checkpoint swap');
  assert.ok(result.failures.some((entry) => (
    entry.rule === 'offline_bundle_validation'
      && entry.message.includes('desktop observation request')
  )));
});

test('signed corpus cannot be relabeled as a different certification run', async () => {
  const fixture = makeFixture();
  const replacement = 'multi-target-00000000-0000-8000-8000-000000000001';
  fixture.contract.certification_run_id = replacement;
  fixture.contract.operation_slots.forEach((slot) => {
    slot.operation_id = `${replacement}:${slot.slot_id}`;
  });
  fixture.manifest.slots.forEach((slot) => {
    slot.operation_id = `${replacement}:${slot.slot_id}`;
  });
  rehashFixture(fixture, catalogFileSHA256);
  const result = await assertRejected(fixture, 'cross-contract run relabel');
  assert.ok(result.failures.some((entry) => entry.rule === 'contract_run'));
});

test('current-build commit is part of the run binding and every runtime identity', async (t) => {
  const baseline = makeFixture();
  const changedRunID = deriveCertificationRunID({
    catalogSHA256: catalogFileSHA256,
    listenerInstanceID: baseline.contract.listener.instance_id,
    executionNonce: baseline.contract.execution_nonce,
    currentBuildSource: { commit: 'd'.repeat(40) },
    monitorBinding: baseline.contract.monitor_binding,
    controllerBuild: baseline.contract.controller_build,
    operationSlots: baseline.contract.operation_slots,
  });
  assert.notEqual(changedRunID, baseline.contract.certification_run_id);

  const cases = [
    ['malformed binding', (fixture) => {
      fixture.contract.current_build_source.extra = true;
    }, 'contract_current_build_source'],
    ['controller commit', (fixture) => {
      fixture.contract.controller_build.source_commit = 'd'.repeat(40);
    }, 'contract_controller_build'],
    ['validator commit', (fixture) => {
      fixture.contract.first_party_validator.source_commit = 'd'.repeat(40);
    }, 'contract_first_party_validator'],
    ['listener commit', (fixture) => {
      fixture.contract.listener.source_commit = 'd'.repeat(40);
    }, 'contract_listener'],
    ['coordinator runtime commit', (fixture) => {
      fixture.contract.monitor_binding.coordinator_runtime_commit = 'd'.repeat(40);
    }, 'contract_monitor'],
    ['observer commit', (fixture) => {
      fixture.evidence.monitor_evidence.foreground_plan.observer_build.source_commit = 'd'.repeat(40);
    }, 'monitor_foreground_plan'],
  ];
  for (const [name, mutate, rule] of cases) {
    await t.test(name, async () => {
      const fixture = makeFixture();
      mutate(fixture);
      rehashFixture(fixture, catalogFileSHA256);
      const result = await assertRejected(fixture, name);
      assert.ok(result.failures.some((entry) => entry.rule === rule));
    });
  }
});

test('host protocol cannot be inflated or collapsed into the receipt floor', async () => {
  const fixture = makeFixture();
  fixture.contract.protocol.host_handshake.minor = 999;
  rehashFixture(fixture, catalogFileSHA256);
  const result = await assertRejected(fixture, 'protocol inflation');
  assert.ok(result.failures.some((entry) => entry.rule === 'contract_protocol'));
});

test('legacy non-live catalog and v3 contract cannot enter live finalization', async () => {
  const fixture = makeFixture();
  const legacyCatalog = structuredClone(catalog);
  legacyCatalog.version = 1;
  legacyCatalog.live_physical_mode = false;
  delete legacyCatalog.certification_kind;
  delete legacyCatalog.claim_scope;
  const result = await validateMultiTargetCertificationStructure({
    catalog: legacyCatalog,
    catalogFileSHA256,
    ...fixture,
    firstPartyValidator: fixtureFirstPartyValidator(fixture),
  });
  assert.equal('success' in result, false);
  assert.equal('certified' in result, false);
  assert.equal(result.structural_validation_passed, false);
  assert.ok(result.failures.some((entry) => entry.rule === 'catalog_schema'));
});

test('current-build catalog binding is closed, sorted, commit-free, and acyclic', () => {
  assert.deepEqual(validateCatalog(catalog), []);
  assert.equal(JSON.stringify(catalog.current_build_source).includes('"commit"'), false);

  const corruptions = [
    (value) => { value.current_build_source.commit = '0'.repeat(40); },
    (value) => { value.current_build_source.coordinator.commit = '0'.repeat(40); },
    (value) => { value.current_build_source.controller_source_manifest.reverse(); },
    (value) => { value.current_build_source.controller_source_manifest.push(
      structuredClone(value.current_build_source.controller_source_manifest[0]),
    ); },
    (value) => { value.current_build_source.controller_source_manifest[0].path = 'scripts/not-controller.swift'; },
    (value) => { value.current_build_source.coordinator.path = 'scripts/other.mjs'; },
    (value) => { value.current_build_source.receipt_validator.path = 'scripts/other.swift'; },
    (value) => { value.current_build_source.finalizer.path = 'scripts/other.mjs'; },
    (value) => { value.current_build_source.finalizer.projection = 'identity'; },
  ];
  for (const corrupt of corruptions) {
    const changed = structuredClone(catalog);
    corrupt(changed);
    assert.ok(validateCatalog(changed).some((entry) => entry.rule === 'catalog_current_build_source'));
  }

  const finalizerBytes = fs.readFileSync(path.join(root, catalog.current_build_source.finalizer.path));
  const projected = projectFinalizerSourceBytes(finalizerBytes);
  assert.equal(createHash('sha256').update(projected).digest('hex'),
    catalog.current_build_source.finalizer.projected_sha256);
  const replacement = Buffer.from(finalizerBytes.toString('utf8').replace(
    /^const BUILTIN_CATALOG_SHA256 = '[0-9a-f]{64}';$/m,
    `const BUILTIN_CATALOG_SHA256 = '${'f'.repeat(64)}';`,
  ));
  assert.deepEqual(projectFinalizerSourceBytes(replacement), projected);
  assert.notEqual(
    createHash('sha256').update(projectFinalizerSourceBytes(Buffer.concat([
      finalizerBytes,
      Buffer.from('\n// projected source drift\n'),
    ]))).digest('hex'),
    catalog.current_build_source.finalizer.projected_sha256,
  );
  assert.throws(
    () => projectFinalizerSourceBytes(Buffer.concat([finalizerBytes, Buffer.from(
      `\nconst BUILTIN_CATALOG_SHA256 = '${'0'.repeat(64)}';\n`,
    )])),
    /exactly one/,
  );
});

test('live crash oracle covers the signed Playground fixture executable', () => {
  const project = fs.readFileSync(path.join(
    root,
    'Apps/Playground/Playground.xcodeproj/project.pbxproj',
  ), 'utf8');
  assert.match(project, /productName = Playground;/);
  assert.match(project, /PRODUCT_NAME = "\$\(TARGET_NAME\)";/);
  assert.ok(catalog.monitor_contract.crash_report_prefixes.includes('Playground'));
});

test('source binding verifies exact files and rejects dirty or expanded source trees', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'peekaboo-current-build-source-'));
  try {
    const bindings = [
      ...catalog.current_build_source.controller_source_manifest,
      catalog.current_build_source.coordinator,
      catalog.current_build_source.receipt_validator,
      catalog.current_build_source.finalizer,
    ];
    for (const binding of bindings) {
      const destination = path.join(temporary, binding.path);
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      fs.copyFileSync(path.join(root, binding.path), destination);
    }
    for (const args of [
      ['init', '-q'],
      ['config', 'user.name', 'Peekaboo Test'],
      ['config', 'user.email', 'peekaboo-test@example.invalid'],
      ['config', 'commit.gpgsign', 'false'],
      ['add', '.'],
      ['commit', '-qm', 'source fixture'],
    ]) {
      const run = spawnSync('/usr/bin/git', ['-C', temporary, ...args], { encoding: 'utf8' });
      assert.equal(run.status, 0, run.stderr);
    }
    assert.match(verifyCurrentBuildSourceBinding(catalog, temporary).commit, /^[0-9a-f]{40}$/);

    const badProjection = structuredClone(catalog);
    badProjection.current_build_source.finalizer.projected_sha256 = '0'.repeat(64);
    assert.throws(
      () => verifyCurrentBuildSourceBinding(badProjection, temporary, { requireClean: false }),
      /projected bytes differ/,
    );

    const extra = path.join(
      temporary,
      'Apps/CLI/Sources/PeekabooCertificationController/UnboundSource.swift',
    );
    fs.writeFileSync(extra, '// unbound source\n');
    assert.throws(
      () => verifyCurrentBuildSourceBinding(catalog, temporary, { requireClean: false }),
      /manifest differs/,
    );
    fs.rmSync(extra);

    fs.appendFileSync(path.join(temporary, catalog.current_build_source.receipt_validator.path), '\n');
    assert.throws(
      () => verifyCurrentBuildSourceBinding(catalog, temporary),
      /clean Git worktree/,
    );
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

test('live monitor run binding and stable fences fail closed under coherent evidence rehashing', async (t) => {
  const cases = [
    ['execution nonce', (fixture) => {
      fixture.evidence.monitor_evidence.execution_nonce = '0'.repeat(64);
    }, 'monitor_schema'],
    ['monitor instance', (fixture) => {
      fixture.evidence.monitor_evidence.monitor_instance_id = '00000000-0000-4000-8000-000000000001';
    }, 'monitor_schema'],
    ['monitor attestation endpoint substitution', (fixture) => {
      fixture.evidence.monitor_evidence.monitor_attestation_socket_path =
        '/private/tmp/substituted-monitor-attestation.sock';
    }, 'monitor_schema'],
    ['observer attestation endpoint aliases monitor', (fixture) => {
      fixture.evidence.monitor_evidence.foreground_plan.observer_attestation_socket_path =
        fixture.evidence.monitor_evidence.monitor_attestation_socket_path;
    }, 'monitor_foreground_plan'],
    ['producer revision gap', (fixture) => {
      fixture.evidence.monitor_evidence.producer_sets.grant.revision += 1;
    }, 'monitor_producers'],
    ['listener producer omission', (fixture) => {
      fixture.evidence.monitor_evidence.producer_sets.baseline.producers.shift();
    }, 'monitor_producers'],
    ['transient acknowledgement substituted for stable fence', (fixture) => {
      fixture.evidence.monitor_evidence.fences[1].heartbeat.transitionAcknowledged = true;
    }, 'monitor_fences'],
    ['nonmonotonic authorization epoch', (fixture) => {
      fixture.evidence.monitor_evidence.fences[3].heartbeat.authorizationEpoch = 2;
    }, 'monitor_order'],
    ['nonmonotonic monotonic clock', (fixture) => {
      fixture.evidence.monitor_evidence.fences[3].heartbeat.monotonicMicroseconds =
        fixture.evidence.monitor_evidence.fences[2].heartbeat.monotonicMicroseconds;
    }, 'monitor_order'],
    ['inconsistent wall clock jump', (fixture) => {
      fixture.evidence.monitor_evidence.fences[3].heartbeat.wallClockMilliseconds += 10_000;
    }, 'monitor_order'],
    ['fractional committed clock', (fixture) => {
      fixture.evidence.monitor_evidence.fences[3].heartbeat.monotonicMicroseconds += 0.5;
    }, 'monitor_fences'],
    ['zero foreground activity', (fixture) => {
      const heartbeat = fixture.evidence.monitor_evidence.fences[3].heartbeat;
      heartbeat.attributedForegroundEventCount = 0;
      heartbeat.attributedForegroundSourcePIDs = [];
      heartbeat.foregroundActivityObserved = false;
    }, 'monitor_activity'],
    ['wrong foreground producer', (fixture) => {
      fixture.evidence.monitor_evidence.fences[3].heartbeat.attributedForegroundSourcePIDs = [9999];
    }, 'monitor_activity'],
    ['recorded violation', (fixture) => {
      fixture.evidence.monitor_evidence.violation_records.push({ kind: 'frontmost_pid' });
    }, 'monitor_cleanliness'],
    ['recorded contamination', (fixture) => {
      fixture.evidence.monitor_evidence.contamination_records.push({ state: 'blocked_active_attempt' });
    }, 'monitor_cleanliness'],
    ['crash delta', (fixture) => {
      fixture.evidence.monitor_evidence.crash_evidence.new_reports.push(
        'Peekaboo-2026-08-16.crash',
      );
    }, 'monitor_cleanliness'],
    ['restoration failure', (fixture) => {
      fixture.evidence.monitor_evidence.restoration.foreground_target = false;
    }, 'monitor_restoration'],
    ['clipboard drift', (fixture) => {
      fixture.evidence.monitor_evidence.final_sample.clipboard_change_count += 1;
    }, 'monitor_sentinel'],
    ['missing history commitment', (fixture) => {
      fixture.evidence.monitor_evidence.history_commitment_sha256 = '0'.repeat(64);
    }, 'monitor_history_commitment'],
  ];
  for (const [name, mutate, rule] of cases) {
    await t.test(name, async () => {
      const fixture = makeFixture();
      mutate(fixture);
      rehashFixture(fixture, catalogFileSHA256);
      const result = await assertRejected(fixture, name);
      assert.ok(result.failures.some((entry) => entry.rule === rule));
    });
  }
});

test('foreground controller and target cannot alias a background owner', async () => {
  const fixture = makeFixture();
  fixture.contract.monitor_binding.foreground_controller = structuredClone(
    fixture.contract.controlled_targets[0].controller,
  );
  fixture.contract.monitor_binding.foreground_target = structuredClone(
    fixture.contract.controlled_targets[0].target,
  );
  rehashFixture(fixture, catalogFileSHA256);
  const result = await assertRejected(fixture, 'foreground alias');
  assert.ok(result.failures.some((entry) => entry.rule === 'contract_foreground_isolation'));

  const mutableDrift = makeFixture();
  const aliased = structuredClone(mutableDrift.contract.controlled_targets[0].target);
  aliased.bounds.x += 1;
  mutableDrift.contract.monitor_binding.foreground_target = aliased;
  mutableDrift.evidence.monitor_evidence.foreground_target = structuredClone(aliased);
  mutableDrift.evidence.monitor_evidence.producer_sets.grant.foreground.target = {
    pid: aliased.pid,
    startIdentity: aliased.start_identity,
    windowID: aliased.window_id,
  };
  for (const name of ['grant-stable', 'operations-start', 'operations-complete']) {
    const heartbeat = mutableDrift.evidence.monitor_evidence.fences.find((entry) => entry.name === name).heartbeat;
    heartbeat.foregroundTargetPID = aliased.pid;
    heartbeat.foregroundTargetWindowID = aliased.window_id;
  }
  mutableDrift.evidence.foreground_postcondition.target = structuredClone(aliased);
  rehashFixture(mutableDrift, catalogFileSHA256);
  const driftResult = await assertRejected(mutableDrift, 'mutable foreground alias');
  assert.ok(driftResult.failures.some((entry) => entry.rule === 'contract_foreground_isolation'));
});

test('signed protocol-1.30 slot requires a triple click and authenticated 1.30 host', async () => {
  const wrongRequest = makeMultiTargetFixture(catalog, catalogFileSHA256, {
    protocolClickType: 'double',
  });
  const requestResult = await assertRejected(wrongRequest, 'protocol-1.30 request');
  assert.ok(requestResult.failures.some((entry) => (
    entry.rule === 'offline_bundle_validation'
      && entry.message.includes('protocol-1.30 click')
  )));

  const wrongTarget = makeMultiTargetFixture(catalog, catalogFileSHA256, {
    protocolClickPoint: [0, 0],
  });
  const targetResult = await assertRejected(wrongTarget, 'protocol-1.30 click target');
  assert.ok(targetResult.failures.some((entry) => (
    entry.rule === 'offline_bundle_validation'
      && entry.message.includes('protocol-1.30 click')
  )));

  const wrongMinimized = makeMultiTargetFixture(catalog, catalogFileSHA256, {
    protocolClickMinimizedOverride: true,
  });
  const minimizedResult = await assertRejected(wrongMinimized, 'protocol-1.30 minimized state');
  assert.ok(minimizedResult.failures.some((entry) => (
    entry.rule === 'offline_bundle_validation'
      && entry.message.includes('protocol-1.30 click')
  )));

  const wrongHost = makeFixture();
  wrongHost.firstPartyVerdicts[0].verdict.host_protocol_version = '1.29';
  const hostResult = await assertRejected(wrongHost, 'protocol-1.30 host');
  assert.ok(hostResult.failures.some((entry) => entry.rule === 'first_party_execution'));
});

test('foreground activity must occur while every designated background slot is in flight', async () => {
  const fixture = makeFixture();
  const slot = fixture.contract.operation_slots.find((entry) => (
    entry.slot_id === catalog.monitor_contract.overlap_slot_ids[0]
  ));
  slot.interval.completed_at_milliseconds = (
    fixture.evidence.monitor_evidence.fences[3].heartbeat.wallClockMilliseconds
  );
  rehashFixture(fixture, catalogFileSHA256);
  const result = await assertRejected(fixture, 'foreground overlap bracket');
  assert.ok(result.failures.some((entry) => entry.rule === 'monitor_overlap'));
});

test('foreground activity cannot stand in for an independent semantic postcondition', async (t) => {
  const cases = [
    ['wrong observed value', (fixture) => {
      fixture.evidence.foreground_postcondition.observed_value_sha256 = '5'.repeat(64);
    }, 'foreground_postcondition'],
    ['self-observation by foreground controller', (fixture) => {
      fixture.evidence.foreground_postcondition.observer = structuredClone(
        fixture.contract.monitor_binding.foreground_controller,
      );
    }, 'foreground_postcondition'],
    ['observation outside overlap bracket', (fixture) => {
      fixture.evidence.foreground_postcondition.interval.completed_at_milliseconds = (
        fixture.contract.interval.completed_at_milliseconds - 1
      );
    }, 'foreground_postcondition_interval'],
    ['missing restoration', (fixture) => {
      fixture.evidence.foreground_postcondition.restored = false;
    }, 'foreground_postcondition'],
    ['focused discriminator mismatch', (fixture) => {
      fixture.evidence.foreground_postcondition.focused_element.identifier = 'different-field';
    }, 'foreground_postcondition'],
    ['focused element outside exact target', (fixture) => {
      fixture.evidence.foreground_postcondition.focused_element.frame.x = 10_000;
    }, 'foreground_postcondition'],
  ];
  for (const [name, mutate, rule] of cases) {
    await t.test(name, async () => {
      const fixture = makeFixture();
      mutate(fixture);
      rehashFixture(fixture, catalogFileSHA256);
      const result = await assertRejected(fixture, name);
      assert.ok(result.failures.some((entry) => entry.rule === rule));
    });
  }

  const coherentlyForged = makeFixture();
  const forgedHash = '5'.repeat(64);
  coherentlyForged.evidence.monitor_evidence.foreground_plan.expected_value_sha256 = forgedHash;
  coherentlyForged.evidence.foreground_postcondition.expected_value_sha256 = forgedHash;
  coherentlyForged.evidence.foreground_postcondition.observed_value_sha256 = forgedHash;
  const commitment = monitorHistoryCommitmentSHA256(coherentlyForged.evidence.monitor_evidence);
  coherentlyForged.evidence.monitor_evidence.history_commitment_sha256 = commitment;
  coherentlyForged.evidence.monitor_evidence.fences.at(-1).heartbeat.historyCommitmentSHA256 = commitment;
  rehashFixture(coherentlyForged, catalogFileSHA256);
  const forgedResult = await assertRejected(coherentlyForged, 'coherent expected value forgery');
  assert.ok(forgedResult.failures.some((entry) => entry.rule === 'monitor_foreground_plan'));

  const aliasedObserver = makeFixture();
  const backgroundController = aliasedObserver.contract.controlled_targets[0].controller;
  aliasedObserver.evidence.monitor_evidence.foreground_plan.observer = structuredClone(backgroundController);
  aliasedObserver.evidence.foreground_postcondition.observer = structuredClone(backgroundController);
  const aliasCommitment = monitorHistoryCommitmentSHA256(aliasedObserver.evidence.monitor_evidence);
  aliasedObserver.evidence.monitor_evidence.history_commitment_sha256 = aliasCommitment;
  aliasedObserver.evidence.monitor_evidence.fences.at(-1).heartbeat.historyCommitmentSHA256 = aliasCommitment;
  rehashFixture(aliasedObserver, catalogFileSHA256);
  const aliasResult = await assertRejected(aliasedObserver, 'background controller observer alias');
  assert.ok(aliasResult.failures.some((entry) => entry.rule === 'monitor_foreground_plan'));
});

test('controller ownership and per-slot first-party verdicts remain exact', async () => {
  const controller = makeFixture();
  controller.contract.controlled_targets[0].controller_id = 'controller-b';
  rehashFixture(controller, catalogFileSHA256);
  await assertRejected(controller, 'controller ownership transplant');

  const verdict = makeFixture();
  verdict.firstPartyVerdicts[0].verdict.target_attested = false;
  const result = await assertRejected(verdict, 'unattested target verdict');
  assert.equal(result.slot_verdicts[0].passed, false);
});

test('cross-contract identity, target, interval, source, and outcome transplants all fail closed', async (t) => {
  const mutations = [
    ['scope', (fixture) => {
      fixture.contract.controlled_targets[0].target.scope = 'process';
      fixture.contract.operation_slots[0].target.scope = 'process';
    }],
    ['pid', (fixture) => {
      fixture.contract.controlled_targets[0].target.pid += 1;
      fixture.contract.operation_slots[0].target.pid += 1;
    }],
    ['generation', (fixture) => {
      fixture.contract.controlled_targets[0].target.start_identity = '999100';
      fixture.contract.operation_slots[0].target.start_identity = '999100';
    }],
    ['window', (fixture) => {
      fixture.contract.controlled_targets[0].target.window_id += 1;
      fixture.contract.operation_slots[0].target.window_id += 1;
    }],
    ['bounds', (fixture) => {
      fixture.contract.controlled_targets[0].target.bounds.x += 1;
      fixture.contract.operation_slots[0].target.bounds.x += 1;
    }],
    ['target owner', (fixture) => {
      fixture.contract.operation_slots[0].target = structuredClone(
        fixture.contract.controlled_targets[1].target,
      );
    }],
    ['controller generation', (fixture) => {
      const replacement = '999200';
      fixture.contract.controlled_targets[0].controller.start_identity = replacement;
      fixture.contract.operation_slots.forEach((slot, index) => {
        if (slot.target_id !== 'target-a') return;
        slot.controller.start_identity = replacement;
        slot.client.start_identity = replacement;
        fixture.manifest.slots[index].client.start_identity = replacement;
        fixture.firstPartyVerdicts[index].verdict.client.start_identity = replacement;
      });
    }],
    ['client generation', (fixture) => {
      fixture.contract.operation_slots[0].client.start_identity = '999300';
      fixture.manifest.slots[0].client.start_identity = '999300';
    }],
    ['interval', (fixture) => {
      fixture.contract.operation_slots[0].interval.started_at_milliseconds += 1;
    }],
    ['source', (fixture) => {
      fixture.contract.source.commit = '1'.repeat(40);
      fixture.contract.operation_slots[0].source.protocol_source_commit = '1'.repeat(40);
      fixture.evidence.source_evidence.commit = '1'.repeat(40);
    }],
    ['outcome', (fixture) => {
      fixture.contract.operation_slots[0].expected_outcome = structuredClone(
        fixture.contract.operation_slots[1].expected_outcome,
      );
    }],
  ];
  for (const [name, mutate] of mutations) {
    await t.test(name, async () => {
      const fixture = makeFixture();
      mutate(fixture);
      rehashFixture(fixture, catalogFileSHA256);
      await assertRejected(fixture, name);
    });
  }
});

test('sequential cross-target receipts cannot claim one concurrent run', async () => {
  const fixture = makeFixture();
  const second = fixture.contract.operation_slots[1];
  second.interval.started_at_milliseconds = fixture.contract.operation_slots[0].interval.completed_at_milliseconds + 1;
  second.interval.completed_at_milliseconds = second.interval.started_at_milliseconds + 100;
  fixture.contract.interval.completed_at_milliseconds = Math.max(
    ...fixture.contract.operation_slots.map((slot) => slot.interval.completed_at_milliseconds),
  );
  rehashFixture(fixture, catalogFileSHA256);
  const result = await assertRejected(fixture, 'serialized run');
  assert.ok(result.failures.some((entry) => entry.rule === 'contract_concurrency'));
});

test('post-mutation and final-bounds slots require signed chronological order', async () => {
  const fixture = makeFixture();
  const mutation = fixture.contract.operation_slots[0];
  const checkpoint = fixture.contract.operation_slots.find((slot) => (
    slot.slot_id === 'controller-a-checkpoint-001'
  ));
  checkpoint.interval.started_at_milliseconds = mutation.interval.started_at_milliseconds - 100;
  checkpoint.interval.completed_at_milliseconds = mutation.interval.started_at_milliseconds - 1;
  fixture.contract.interval.started_at_milliseconds = checkpoint.interval.started_at_milliseconds;
  const runID = deriveCertificationRunID({
    catalogSHA256: catalogFileSHA256,
    listenerInstanceID: fixture.contract.listener.instance_id,
    executionNonce: fixture.contract.execution_nonce,
    currentBuildSource: fixture.contract.current_build_source,
    monitorBinding: fixture.contract.monitor_binding,
    controllerBuild: fixture.contract.controller_build,
    operationSlots: fixture.contract.operation_slots,
  });
  fixture.contract.certification_run_id = runID;
  fixture.contract.operation_slots.forEach((slot, index) => {
    slot.operation_id = `${runID}:${slot.slot_id}`;
    fixture.manifest.slots[index].operation_id = slot.operation_id;
  });
  rehashFixture(fixture, catalogFileSHA256);
  const result = await assertRejected(fixture, 'checkpoint chronology');
  assert.ok(result.failures.some((entry) => entry.rule === 'contract_checkpoint_order'));
});

test('caller-provided cached offline success is deleted and never influences finalization', async () => {
  const baseline = makeFixture();
  const baselineResult = await finalize(baseline);
  assert.equal(baselineResult.structural_validation_passed, true);

  const cached = makeFixture();
  cached.evidence.offline_protocol_validation = {
    version: 3,
    success: true,
    receipts: [],
    failures: [],
  };
  const cachedResult = await finalize(cached);
  assert.equal(cachedResult.structural_validation_passed, true);
  assert.equal('offline_protocol_validation' in cached.evidence, true);
  assert.equal('offline_protocol_validation' in cachedResult, true);
  assert.equal(
    'offline_protocol_validation' in cachedResult.offline_protocol_validation,
    false,
  );

  const forged = makeFixture();
  forged.bundles[0].document.canonicalResponse = Buffer.from('{"tampered":true}', 'utf8').toString('base64');
  refreshBundle(forged, 0);
  forged.evidence.offline_protocol_validation = {
    version: 3, success: true, receipts: [], failures: [],
  };
  const forgedResult = await assertRejected(forged, 'forged cached success');
  assert.equal(forgedResult.offline_protocol_validation.success, false);
});

test('an unmanifested final-bounds checkpoint is rejected even when its bundle is valid', async () => {
  const fixture = makeFixture();
  const original = fixture.bundles.at(-1);
  fixture.bundles.push({
    file: 'unmanifested-final-bounds.json',
    sha256: original.sha256,
    bytes: Buffer.from(original.bytes),
    document: structuredClone(original.document),
  });
  const result = await assertRejected(fixture, 'unmanifested final bounds');
  assert.ok(result.failures.some((entry) => entry.rule === 'offline_bundle_inventory'));
});

test('artifact loader accepts only owner-private closed artifacts', () => {
  const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'peekaboo-multi-target-test-'));
  fs.chmodSync(temporaryRoot, 0o700);
  const artifactRoot = path.join(temporaryRoot, 'artifacts');
  const fixture = makeFixture();
  writeFixtureArtifact(fixture, artifactRoot);
  const loaded = readCertificationArtifacts(artifactRoot);
  assert.equal(loaded.bundles.length, catalog.slots.length);

  fs.chmodSync(path.join(artifactRoot, 'raw-evidence.json'), 0o644);
  assert.throws(() => readCertificationArtifacts(artifactRoot), /owner-private/);
  fs.chmodSync(path.join(artifactRoot, 'raw-evidence.json'), 0o600);

  const firstBundle = path.join(artifactRoot, 'bundles', fixture.bundles[0].file);
  const hardlink = path.join(temporaryRoot, 'bundle-hardlink.json');
  fs.linkSync(firstBundle, hardlink);
  assert.throws(() => readCertificationArtifacts(artifactRoot), /non-hardlinked/);
  fs.unlinkSync(hardlink);

  const original = path.join(temporaryRoot, 'bundle-original.json');
  fs.renameSync(firstBundle, original);
  fs.symlinkSync(original, firstBundle);
  assert.throws(() => readCertificationArtifacts(artifactRoot));
  fs.unlinkSync(firstBundle);
  fs.renameSync(original, firstBundle);
  fs.rmSync(temporaryRoot, { recursive: true, force: true });
});

test('packaged CLI has discoverable help and rejects a caller-selected catalog', () => {
  const script = path.join(root, 'scripts/finalize-multi-target-certification.mjs');
  const help = spawnSync(process.execPath, [script, '--help'], { encoding: 'utf8' });
  assert.equal(help.status, 0, help.stderr);
  assert.match(help.stdout, /peekaboo-certify finalize --artifacts DIR --peekaboo PATH/);
  assert.match(help.stdout, /peekaboo-certify prepare --controller-receipts DIR --bundles DIR/);
  assert.match(help.stdout, /--monitor-evidence FILE/);
  assert.match(help.stdout, /--foreground-postcondition FILE/);
  assert.match(help.stdout, /peekaboo-certify verify-digests --artifacts DIR --summary FILE/);

  const arbitraryCatalog = spawnSync(process.execPath, [script, '--catalog', catalogPath], {
    encoding: 'utf8',
  });
  assert.equal(arbitraryCatalog.status, 2);
  assert.match(arbitraryCatalog.stderr, /Unknown or incomplete argument: --catalog/);
});

test('operator digest surfaces verify supplied artifacts without source access', async () => {
  const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'peekaboo-digest-cli-'));
  fs.chmodSync(temporaryRoot, 0o700);
  const artifactRoot = path.join(temporaryRoot, 'artifacts');
  const summaryPath = path.join(temporaryRoot, 'summary.json');
  const fixture = makeFixture();
  const summary = await finalize(fixture);
  writeFixtureArtifact(fixture, artifactRoot);
  fs.writeFileSync(summaryPath, `${JSON.stringify(summary, null, 2)}\n`, { mode: 0o600 });
  const script = path.join(root, 'scripts/finalize-multi-target-certification.mjs');

  const verify = spawnSync(process.execPath, [
    script, 'verify-digests', '--artifacts', artifactRoot, '--summary', summaryPath,
  ], { encoding: 'utf8' });
  assert.equal(verify.status, 0, verify.stderr);
  const verification = JSON.parse(verify.stdout);
  assert.equal(verification.success, true);
  assert.ok(verification.checks.length > 20);
  assert.ok(verification.checks.every((entry) => entry.match));

  const manifestDigest = spawnSync(process.execPath, [
    script,
    'digest',
    '--kind', 'operation-manifest',
    '--projection', 'whole-document',
    '--input', path.join(artifactRoot, 'operation-manifest.json'),
  ], { encoding: 'utf8' });
  assert.equal(manifestDigest.status, 0, manifestDigest.stderr);
  assert.equal(JSON.parse(manifestDigest.stdout).digest, summary.operation_manifest_sha256);

  const runBindingDigest = spawnSync(process.execPath, [
    script,
    'digest',
    '--kind', 'run-binding',
    '--projection', 'contract-run-binding',
    '--input', path.join(artifactRoot, 'contract.json'),
  ], { encoding: 'utf8' });
  assert.equal(runBindingDigest.status, 0, runBindingDigest.stderr);
  assert.equal(JSON.parse(runBindingDigest.stdout).digest, summary.run_binding_sha256);

  const spec = spawnSync(process.execPath, [script, 'digest', '--spec'], { encoding: 'utf8' });
  assert.equal(spec.status, 0, spec.stderr);
  assert.equal(JSON.parse(spec.stdout).version, 2);

  const unknownKind = spawnSync(process.execPath, [
    script, 'digest', '--kind', 'unknown', '--input', summaryPath,
  ], { encoding: 'utf8' });
  assert.equal(unknownKind.status, 2);
  assert.match(unknownKind.stderr, /Unknown digest kind/);

  const unknownProjection = spawnSync(process.execPath, [
    script,
    'digest',
    '--kind', 'operation-manifest',
    '--projection', 'unknown',
    '--input', path.join(artifactRoot, 'operation-manifest.json'),
  ], { encoding: 'utf8' });
  assert.equal(unknownProjection.status, 2);
  assert.match(unknownProjection.stderr, /requires projection whole-document/);
  fs.rmSync(temporaryRoot, { recursive: true, force: true });
});
