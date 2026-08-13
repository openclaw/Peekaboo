import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  makePassingReport,
  validateCertification,
} from "../scripts/validate-background-computer-use-report.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const catalog = JSON.parse(fs.readFileSync(
  path.join(root, "scripts/background-computer-use-catalog.json"),
  "utf8",
));

function rules(result) {
  return new Set(result.failures.map((entry) => entry.rule));
}

function caseById(report, id) {
  const entry = report.cases.find((candidate) => candidate.id === id);
  assert.ok(entry, `Missing test fixture case ${id}`);
  return entry;
}

function invariantByName(caseResult, name) {
  const entry = caseResult.invariants.find((candidate) => candidate.name === name);
  assert.ok(entry, `Missing test fixture invariant ${name}`);
  return entry;
}

function makeRemoteReport() {
  const report = makePassingReport(catalog);
  const receipt = {
    pid: 4242,
    startIdentity: "987654321",
    socketPath: "/tmp/peekaboo-certification/bridge.sock",
    sourceCommit: report.provenance.cli_source_commit,
  };
  report.provenance.event_producer_source = "remote";
  report.provenance.requested_bridge_socket = receipt.socketPath;
  report.provenance.remote_host = receipt;
  for (const caseResult of report.cases) {
    caseResult.event_producer = structuredClone(receipt);
  }
  return report;
}

test("passing report covers the complete 34-case catalog", () => {
  const report = makePassingReport(catalog);
  const result = validateCertification(catalog, report);

  assert.equal(catalog.cases.length, 34);
  assert.equal(result.success, true);
  assert.equal(result.expected_cases, 34);
  assert.equal(result.observed_cases, 34);
  assert.deepEqual(result.failures, []);
});

test("deleted required row fails completeness", () => {
  const report = makePassingReport(catalog);
  report.cases.pop();

  const result = validateCertification(catalog, report);

  assert.equal(result.success, false);
  assert.ok(rules(result).has("missing_case"));
});

test("duplicate and unknown rows fail closed", () => {
  const report = makePassingReport(catalog);
  report.cases.push(structuredClone(report.cases[0]));
  report.cases.push({
    ...structuredClone(report.cases[0]),
    id: "not-cataloged",
  });

  const result = validateCertification(catalog, report);

  assert.equal(result.success, false);
  assert.ok(rules(result).has("duplicate_observed_case"));
  assert.ok(rules(result).has("unknown_case"));
});

test("surface command and phase drift are rejected", () => {
  const corruptions = [
    ["surface", "mcp", "surface_mismatch"],
    ["command", "type", "command_mismatch"],
    ["phase", "foreground", "phase_mismatch"],
  ];
  for (const [field, value, expectedRule] of corruptions) {
    const report = makePassingReport(catalog);
    caseById(report, "click-id")[field] = value;
    const result = validateCertification(catalog, report);

    assert.equal(result.success, false);
    assert.ok(rules(result).has(expectedRule));
  }
});

test("wrong refusal code is rejected", () => {
  const report = makePassingReport(catalog);
  caseById(report, "stale-snapshot").error_code = "UNKNOWN_ERROR";

  const result = validateCertification(catalog, report);

  assert.equal(result.success, false);
  assert.ok(rules(result).has("refusal_code"));
});

test("stale snapshot certification requires controlled window drift and restoration", () => {
  const staleCase = catalog.cases.find((entry) => entry.id === "stale-snapshot");
  assert.equal(staleCase?.expected_error_code, "SNAPSHOT_STALE");
  assert.deepEqual(staleCase?.required_oracles, ["snapshot_window_drift", "target_window_restored"]);

  for (const oracle of staleCase.required_oracles) {
    const report = makePassingReport(catalog);
    caseById(report, "stale-snapshot").oracles[oracle] = false;
    const result = validateCertification(catalog, report);

    assert.equal(result.success, false);
    assert.ok(rules(result).has("missing_oracle"));
  }
});

test("either exit still requires an explicit success envelope", () => {
  const report = makePassingReport(catalog);
  const quit = caseById(report, "lifecycle-quit");
  quit.exit_code = 1;
  quit.result_success = null;

  const result = validateCertification(catalog, report);

  assert.equal(result.success, false);
  assert.ok(rules(result).has("exit_contract"));
});

test("conditional outcomes reject unrelated failures", () => {
  const report = makePassingReport(catalog);
  const quit = caseById(report, "lifecycle-quit");
  quit.exit_code = 1;
  quit.result_success = false;
  quit.effect = "refused";
  quit.error_code = "INVALID_INPUT";

  const result = validateCertification(catalog, report);

  assert.equal(result.success, false);
  assert.ok(rules(result).has("outcome"));
});

test("missing standard evidence and named oracle are rejected", () => {
  const report = makePassingReport(catalog);
  caseById(report, "see-text").evidence.desktop_restored = false;
  caseById(report, "see-text").evidence.monitor_liveness = false;
  delete caseById(report, "see-text").oracles.snapshot_identifiers;

  const result = validateCertification(catalog, report);

  assert.equal(result.success, false);
  assert.ok(rules(result).has("missing_evidence"));
  assert.ok(rules(result).has("missing_oracle"));
});

test("effect and delivery drift are rejected", () => {
  const report = makePassingReport(catalog);
  caseById(report, "focus-basic-field").effect = "unverifiable";
  caseById(report, "focus-basic-field").delivery_mode = null;

  const result = validateCertification(catalog, report);

  assert.equal(result.success, false);
  assert.ok(rules(result).has("effect"));
  assert.ok(rules(result).has("delivery"));
});

test("probe canary and invariant violations are unsuppressible", () => {
  const report = makePassingReport(catalog);
  report.probe_canary = false;
  invariantByName(caseById(report, "type-text"), "physical_cursor").passed = false;

  const result = validateCertification(catalog, report);

  assert.equal(result.success, false);
  assert.ok(rules(result).has("canary"));
  assert.ok(rules(result).has("violated_invariant"));
});

test("source provenance is exact closed and identical across the event producer", () => {
  const missing = makePassingReport(catalog);
  delete missing.provenance;
  assert.ok(rules(validateCertification(catalog, missing)).has("provenance_schema"));

  const malformed = makePassingReport(catalog);
  malformed.provenance.cli_source_commit = "unknown";
  assert.ok(rules(validateCertification(catalog, malformed)).has("source_commit"));

  const terminated = makePassingReport(catalog);
  terminated.provenance.cli_source_commit += "\n";
  terminated.provenance.event_producer_source_commit += "\n";
  assert.ok(rules(validateCertification(catalog, terminated)).has("source_commit"));

  const mismatch = makePassingReport(catalog);
  mismatch.provenance.event_producer_source = "remote";
  mismatch.provenance.event_producer_source_commit =
    "fedcba9876543210fedcba9876543210fedcba98";
  assert.ok(rules(validateCertification(catalog, mismatch)).has("source_commit_mismatch"));

  const receiptlessRemote = makePassingReport(catalog);
  receiptlessRemote.provenance.event_producer_source = "remote";
  assert.ok(rules(validateCertification(catalog, receiptlessRemote)).has("remote_host_receipt"));

  const remote = makeRemoteReport();
  assert.equal(validateCertification(catalog, remote).success, true);

  const rerouted = makeRemoteReport();
  rerouted.provenance.requested_bridge_socket = "/tmp/different-bridge.sock";
  assert.ok(rules(validateCertification(catalog, rerouted)).has("bridge_socket_mismatch"));

  caseById(remote, "see-text").event_producer.pid += 1;
  assert.ok(rules(validateCertification(catalog, remote)).has("event_producer_receipt"));

  const unstable = makeRemoteReport();
  caseById(unstable, "see-text").event_producer_stable = false;
  assert.ok(rules(validateCertification(catalog, unstable)).has("event_producer_stability"));
});

test("catalog invariants are required nonempty and unique", () => {
  const corruptions = [
    [[], "schema"],
    [[...catalog.invariants, catalog.invariants[0]], "duplicate_catalog_invariant"],
    [[...catalog.invariants, ""], "schema"],
  ];

  for (const [invariants, expectedRule] of corruptions) {
    const corruptCatalog = structuredClone(catalog);
    corruptCatalog.invariants = invariants;
    const result = validateCertification(corruptCatalog, makePassingReport(catalog));

    assert.equal(result.success, false);
    assert.ok(rules(result).has(expectedRule));
  }
});

test("catalog contamination retry policy is explicitly boolean", () => {
  const corruptCatalog = structuredClone(catalog);
  corruptCatalog.cases[0].contamination_retry_safe = "yes";

  const result = validateCertification(corruptCatalog, makePassingReport(catalog));

  assert.equal(result.success, false);
  assert.ok(rules(result).has("schema"));
});

test("missing unknown and violated invariant results fail closed", () => {
  const report = makePassingReport(catalog);
  const typeCase = caseById(report, "type-text");
  typeCase.invariants = typeCase.invariants.filter((entry) => entry.name !== "frontmost_window");
  invariantByName(typeCase, "physical_cursor").passed = false;
  typeCase.invariants.push({ name: "not_cataloged", passed: true });

  const result = validateCertification(catalog, report);

  assert.equal(result.success, false);
  assert.ok(rules(result).has("missing_invariant"));
  assert.ok(rules(result).has("violated_invariant"));
  assert.ok(rules(result).has("unknown_invariant"));
});

test("duplicate invariant results remain visible after JSON parsing and fail closed", () => {
  const report = makePassingReport(catalog);
  const typeCase = caseById(report, "type-text");
  invariantByName(typeCase, "physical_cursor").passed = false;
  typeCase.invariants.push({ name: "physical_cursor", passed: true });
  const parsedReport = JSON.parse(JSON.stringify(report));

  const result = validateCertification(catalog, parsedReport);

  assert.equal(result.success, false);
  assert.ok(rules(result).has("duplicate_invariant_result"));
  assert.ok(rules(result).has("violated_invariant"));
});

test("invariant result entries have a closed typed schema", () => {
  const corruptions = [
    "not-an-entry",
    { name: "physical_cursor", passed: "yes" },
    { name: "", passed: true },
    { name: "physical_cursor", passed: true, ignored: false },
  ];
  for (const corruption of corruptions) {
    const report = makePassingReport(catalog);
    caseById(report, "type-text").invariants[0] = corruption;

    const result = validateCertification(catalog, report);

    assert.equal(result.success, false);
    assert.ok(rules(result).has("invariant_schema"));
  }
});

test("legacy violation counts and invariant objects cannot stand in for named invariant results", () => {
  const report = makePassingReport(catalog);
  const typeCase = caseById(report, "type-text");
  typeCase.invariants = { physical_cursor: true };
  typeCase.invariant_violations = 0;

  const result = validateCertification(catalog, report);

  assert.equal(result.success, false);
  assert.ok(rules(result).has("invariant_schema"));
});
