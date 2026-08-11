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
  caseById(report, "type-text").invariant_violations = 1;

  const result = validateCertification(catalog, report);

  assert.equal(result.success, false);
  assert.ok(rules(result).has("canary"));
  assert.ok(rules(result).has("invariant"));
});
