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
    codeSignatureHash: "89abcdef0123456789abcdef0123456789abcdef",
    pid: 4242,
    startIdentity: "987654321",
    socketPath: "/tmp/peekaboo-certification/bridge.sock",
    sourceCommit: report.provenance.cli_source_commit,
  };
  report.provenance.event_producer_source = "remote";
  report.provenance.requested_bridge_socket = receipt.socketPath;
  report.provenance.remote_host = receipt;
  report.provenance.source_artifacts.bridge_executable_sha256 = "a".repeat(64);
  report.provenance.source_artifacts.bridge_code_signature_hash = receipt.codeSignatureHash;
  report.provenance.source_artifacts.bridge_executable_device = "3";
  report.provenance.source_artifacts.bridge_executable_inode = "4";
  for (const caseResult of report.cases) {
    caseResult.event_producer = structuredClone(receipt);
  }
  return report;
}

test("passing report covers the complete 42-case catalog", () => {
  const report = makePassingReport(catalog);
  const result = validateCertification(catalog, report);

  assert.equal(catalog.cases.length, 42);
  assert.equal(result.success, true);
  assert.equal(result.expected_cases, 42);
  assert.equal(result.observed_cases, 42);
  assert.deepEqual(result.failures, []);
});

test("source artifact provenance is closed and exact", () => {
  const extra = makePassingReport(catalog);
  extra.provenance.source_artifacts.ignored = "0".repeat(64);
  assert.ok(rules(validateCertification(catalog, extra)).has("source_artifacts"));

  const drifted = makePassingReport(catalog);
  drifted.provenance.source_artifacts.probe_source_sha256 = "not-a-digest";
  assert.ok(rules(validateCertification(catalog, drifted)).has("source_artifacts"));

  const untrusted = makePassingReport(catalog);
  const result = validateCertification(catalog, untrusted, {
    catalog_sha256: "e".repeat(64),
    reporter_sha256: "f".repeat(64),
  });
  assert.ok(rules(result).has("trusted_source_artifacts"));
});

test("post-run provenance drift is part of the canonical verdict", () => {
  const report = makePassingReport(catalog);
  report.provenance_stable = false;
  assert.ok(rules(validateCertification(catalog, report)).has("provenance_stability"));
});

test("case monitor receipts are run-bound, ordered, and instance-distinct", () => {
  const mixed = makePassingReport(catalog);
  mixed.cases[1].monitor_receipt.execution_nonce = "c".repeat(64);
  assert.ok(rules(validateCertification(catalog, mixed)).has("monitor_run_binding"));

  const duplicate = makePassingReport(catalog);
  duplicate.cases[1].monitor_receipt.monitor_instance_id =
    duplicate.cases[0].monitor_receipt.monitor_instance_id;
  assert.ok(rules(validateCertification(catalog, duplicate)).has("monitor_run_binding"));

  const reordered = makePassingReport(catalog);
  reordered.cases[0].monitor_receipt.final.authorization_epoch = 1;
  assert.ok(rules(validateCertification(catalog, reordered)).has("monitor_receipt"));
});

test("catalog has no monitored process launch and covers eight physical apps exactly once", () => {
  assert.deepEqual(catalog.physical_apps, [
    "playground",
    "textedit",
    "safari",
    "calendar",
    "settings",
    "calculator",
    "activity-monitor",
    "finder",
  ]);
  assert.equal(catalog.cases.some((entry) => entry.command === "app launch"), false);
  const coveredApps = catalog.cases
    .map((entry) => entry.physical_app)
    .filter(Boolean)
    .sort();
  assert.deepEqual(coveredApps, [...catalog.physical_apps].sort());
});

test("keyboard contract requires exact-window positives and app/PID raw-key refusals", () => {
  const ambiguousType = catalog.cases.find((entry) => entry.id === "type-ambiguous-pid-refused");
  assert.equal(ambiguousType?.expected_exit, "failure");
  assert.equal(ambiguousType?.expected_error_code, "INVALID_INPUT");
  assert.deepEqual(
    {
      exit: catalog.cases.find((entry) => entry.id === "type-exact-window")?.expected_exit,
      delivery: catalog.cases.find((entry) => entry.id === "type-exact-window")?.expected_delivery,
    },
    { exit: "success", delivery: "background" },
  );
  assert.deepEqual(
    {
      exit: catalog.cases.find((entry) => entry.id === "press-exact-window")?.expected_exit,
      delivery: catalog.cases.find((entry) => entry.id === "press-exact-window")?.expected_delivery,
    },
    { exit: "success", delivery: "background" },
  );
  for (const id of ["press-app-refused", "press-pid-refused"]) {
    const entry = catalog.cases.find((candidate) => candidate.id === id);
    assert.equal(entry?.expected_exit, "failure");
    assert.equal(entry?.expected_error_code, "INTERACTION_FAILED");
  }
});

test("physical app identity drift is rejected", () => {
  const report = makePassingReport(catalog);
  caseById(report, "physical-safari").physical_app = "calendar";

  const result = validateCertification(catalog, report);

  assert.equal(result.success, false);
  assert.ok(rules(result).has("physical_app_mismatch"));
});

test("physical app binary and signing drift is rejected", () => {
  const report = makePassingReport(catalog);
  caseById(report, "physical-safari").physical_target.executable.sha256 = "invalid";
  assert.ok(rules(validateCertification(catalog, report)).has("physical_target_mismatch"));
});

test("physical app rows reject cross-app bundle relabeling", () => {
  const report = makePassingReport(catalog);
  caseById(report, "physical-safari").physical_target.bundle_id = "com.apple.calculator";
  assert.ok(rules(validateCertification(catalog, report)).has("physical_target_mismatch"));
});

test("physical app rows reject duplicate process-generation window identities", () => {
  const report = makePassingReport(catalog);
  const safari = caseById(report, "physical-safari").physical_target;
  const calendar = caseById(report, "physical-calendar").physical_target;
  calendar.pid = safari.pid;
  calendar.process_start_identity = safari.process_start_identity;
  calendar.window_id = safari.window_id;
  assert.ok(rules(validateCertification(catalog, report)).has("physical_target_duplicate"));
});

test("physical app rows reject a reused process generation with a relabeled window", () => {
  const report = makePassingReport(catalog);
  const safari = caseById(report, "physical-safari").physical_target;
  const calendar = caseById(report, "physical-calendar").physical_target;
  calendar.pid = safari.pid;
  calendar.process_start_identity = safari.process_start_identity;
  assert.notEqual(calendar.window_id, safari.window_id);
  assert.ok(rules(validateCertification(catalog, report)).has("physical_target_duplicate"));
});

test("missing or duplicate catalog physical-app coverage fails closed", () => {
  const missing = structuredClone(catalog);
  delete missing.cases.find((entry) => entry.id === "physical-safari").physical_app;
  assert.ok(rules(validateCertification(missing, makePassingReport(catalog))).has("physical_app_coverage"));

  const duplicate = structuredClone(catalog);
  duplicate.cases.find((entry) => entry.id === "physical-calendar").physical_app = "safari";
  assert.ok(rules(validateCertification(duplicate, makePassingReport(catalog))).has("physical_app_coverage"));
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
  invariantByName(
    caseById(report, "type-exact-window"),
    "producer_pointer_event",
  ).passed = false;

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
  const typeCase = caseById(report, "type-exact-window");
  typeCase.invariants = typeCase.invariants.filter((entry) => entry.name !== "frontmost_window");
  invariantByName(typeCase, "producer_pointer_event").passed = false;
  typeCase.invariants.push({ name: "not_cataloged", passed: true });

  const result = validateCertification(catalog, report);

  assert.equal(result.success, false);
  assert.ok(rules(result).has("missing_invariant"));
  assert.ok(rules(result).has("violated_invariant"));
  assert.ok(rules(result).has("unknown_invariant"));
});

test("duplicate invariant results remain visible after JSON parsing and fail closed", () => {
  const report = makePassingReport(catalog);
  const typeCase = caseById(report, "type-exact-window");
  invariantByName(typeCase, "producer_pointer_event").passed = false;
  typeCase.invariants.push({ name: "producer_pointer_event", passed: true });
  const parsedReport = JSON.parse(JSON.stringify(report));

  const result = validateCertification(catalog, parsedReport);

  assert.equal(result.success, false);
  assert.ok(rules(result).has("duplicate_invariant_result"));
  assert.ok(rules(result).has("violated_invariant"));
});

test("invariant result entries have a closed typed schema", () => {
  const corruptions = [
    "not-an-entry",
    { name: "producer_pointer_event", passed: "yes" },
    { name: "", passed: true },
    { name: "producer_pointer_event", passed: true, ignored: false },
  ];
  for (const corruption of corruptions) {
    const report = makePassingReport(catalog);
    caseById(report, "type-exact-window").invariants[0] = corruption;

    const result = validateCertification(catalog, report);

    assert.equal(result.success, false);
    assert.ok(rules(result).has("invariant_schema"));
  }
});

test("legacy violation counts and invariant objects cannot stand in for named invariant results", () => {
  const report = makePassingReport(catalog);
  const typeCase = caseById(report, "type-exact-window");
  typeCase.invariants = { producer_pointer_event: true };
  typeCase.invariant_violations = 0;

  const result = validateCertification(catalog, report);

  assert.equal(result.success, false);
  assert.ok(rules(result).has("invariant_schema"));
});
