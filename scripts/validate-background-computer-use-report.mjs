#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

function failure(caseId, rule, message) {
  return { case_id: caseId, rule, message };
}

function duplicateValues(values) {
  const seen = new Set();
  const duplicates = new Set();
  for (const value of values) {
    if (seen.has(value)) duplicates.add(value);
    seen.add(value);
  }
  return [...duplicates].sort();
}

function validateCatalog(catalog) {
  const failures = [];
  if (!catalog || catalog.version !== 1 || !Array.isArray(catalog.cases)) {
    return [failure("catalog", "schema", "Catalog must be version 1 with a cases array")];
  }
  if (!Array.isArray(catalog.required_evidence) || catalog.required_evidence.length === 0) {
    failures.push(failure("catalog", "schema", "Catalog must declare required_evidence"));
  }
  const ids = catalog.cases.map((entry) => entry?.id).filter(Boolean);
  for (const id of duplicateValues(ids)) {
    failures.push(failure(id, "duplicate_catalog_case", `Catalog case '${id}' is duplicated`));
  }
  if (ids.length !== catalog.cases.length) {
    failures.push(failure("catalog", "schema", "Every catalog case must have a nonempty id"));
  }
  for (const entry of catalog.cases) {
    if (entry?.surface !== "cli") {
      failures.push(failure(entry?.id ?? "catalog", "schema", "Catalog surface must be 'cli'"));
    }
    if (typeof entry?.command !== "string" || entry.command.length === 0) {
      failures.push(failure(entry?.id ?? "catalog", "schema", "Catalog command must be nonempty"));
    }
    if (!["background", "foreground"].includes(entry?.phase)) {
      failures.push(failure(entry?.id ?? "catalog", "schema", "Invalid catalog phase"));
    }
    if (!entry || !["success", "failure", "either"].includes(entry.expected_exit)) {
      failures.push(failure(entry?.id ?? "catalog", "schema", "Invalid expected_exit"));
    }
    if (!Array.isArray(entry?.required_oracles)) {
      failures.push(failure(entry?.id ?? "catalog", "schema", "required_oracles must be an array"));
    }
    if (entry?.allowed_outcomes !== undefined) {
      if (!Array.isArray(entry.allowed_outcomes) || entry.allowed_outcomes.length === 0
          || entry.allowed_outcomes.some((outcome) => !["success", "failure"].includes(outcome?.exit))) {
        failures.push(failure(entry?.id ?? "catalog", "schema", "allowed_outcomes must declare exit tuples"));
      }
    }
  }
  return failures;
}

function validateExitContract(expected, observed) {
  const exitedSuccessfully = observed.exit_code === 0;
  if (expected === "success") return exitedSuccessfully && observed.result_success === true;
  if (expected === "failure") return !exitedSuccessfully && observed.result_success === false;
  return (exitedSuccessfully && observed.result_success === true)
    || (!exitedSuccessfully && observed.result_success === false);
}

function matchesAllowedOutcome(outcome, observed) {
  const exitMatches = outcome.exit === "success"
    ? observed.exit_code === 0 && observed.result_success === true
    : observed.exit_code !== 0 && observed.result_success === false;
  return exitMatches
    && observed.effect === outcome.effect
    && observed.error_code === outcome.error_code;
}

export function validateCertification(catalog, report) {
  const failures = validateCatalog(catalog);
  if (failures.length > 0) {
    return {
      success: false,
      catalog_version: catalog?.version ?? null,
      expected_cases: catalog?.cases?.length ?? 0,
      observed_cases: report?.cases?.length ?? 0,
      failures,
    };
  }

  if (report?.probe_canary !== true) {
    failures.push(failure("certification", "canary", "Invariant probe self-test did not pass"));
  }

  const observedCases = Array.isArray(report?.cases) ? report.cases : [];
  const catalogById = new Map(catalog.cases.map((entry) => [entry.id, entry]));
  const observedIds = observedCases.map((entry) => entry?.id).filter(Boolean);
  for (const id of duplicateValues(observedIds)) {
    failures.push(failure(id, "duplicate_observed_case", `Observed case '${id}' is duplicated`));
  }
  for (const observed of observedCases) {
    if (!observed?.id) {
      failures.push(failure("report", "schema", "Every observed case must have a nonempty id"));
    } else if (!catalogById.has(observed.id)) {
      failures.push(failure(observed.id, "unknown_case", `Observed case '${observed.id}' is not cataloged`));
    }
  }

  const observedById = new Map(observedCases.map((entry) => [entry.id, entry]));
  for (const expected of catalog.cases) {
    const observed = observedById.get(expected.id);
    if (!observed) {
      failures.push(failure(expected.id, "missing_case", `Required case '${expected.id}' is missing`));
      continue;
    }
    for (const field of ["surface", "command", "phase"]) {
      if (observed[field] !== expected[field]) {
        failures.push(failure(
          expected.id,
          `${field}_mismatch`,
          `Expected ${field} '${expected[field]}', observed '${observed[field] ?? "missing"}'`,
        ));
      }
    }
    if (observed.expected_exit !== expected.expected_exit) {
      failures.push(failure(expected.id, "expectation", "Observed exit expectation differs from catalog"));
    }
    if (!validateExitContract(expected.expected_exit, observed)) {
      failures.push(failure(expected.id, "exit_contract", "Exit code and success envelope violate expectation"));
    }
    if (expected.allowed_outcomes !== undefined
        && !expected.allowed_outcomes.some((outcome) => matchesAllowedOutcome(outcome, observed))) {
      failures.push(failure(expected.id, "outcome", "Observed exit/effect/error tuple is not allowed"));
    }
    if (expected.expected_effect !== undefined && observed.effect !== expected.expected_effect) {
      failures.push(failure(
        expected.id,
        "effect",
        `Expected effect '${expected.expected_effect}', observed '${observed.effect ?? "missing"}'`,
      ));
    }
    if (expected.expected_delivery !== undefined && observed.delivery_mode !== expected.expected_delivery) {
      failures.push(failure(
        expected.id,
        "delivery",
        `Expected delivery '${expected.expected_delivery}', observed '${observed.delivery_mode ?? "missing"}'`,
      ));
    }
    if (expected.expected_error_code !== undefined && observed.error_code !== expected.expected_error_code) {
      failures.push(failure(
        expected.id,
        "refusal_code",
        `Expected error '${expected.expected_error_code}', observed '${observed.error_code ?? "missing"}'`,
      ));
    }
    if (observed.invariant_violations !== 0) {
      failures.push(failure(expected.id, "invariant", "Invariant monitor recorded a violation"));
    }
    for (const evidenceName of catalog.required_evidence) {
      if (observed.evidence?.[evidenceName] !== true) {
        failures.push(failure(expected.id, "missing_evidence", `Missing evidence '${evidenceName}'`));
      }
    }
    for (const oracleName of expected.required_oracles) {
      if (observed.oracles?.[oracleName] !== true) {
        failures.push(failure(expected.id, "missing_oracle", `Missing oracle '${oracleName}'`));
      }
    }
  }

  return {
    success: failures.length === 0,
    catalog_version: catalog.version,
    expected_cases: catalog.cases.length,
    observed_cases: observedCases.length,
    failures,
  };
}

export function makePassingReport(catalog) {
  const cases = catalog.cases.map((entry) => {
    const selectedOutcome = entry.allowed_outcomes?.[0];
    const exitsSuccessfully = selectedOutcome
      ? selectedOutcome.exit === "success"
      : entry.expected_exit !== "failure";
    const evidence = Object.fromEntries(catalog.required_evidence.map((name) => [name, true]));
    const oracles = Object.fromEntries(entry.required_oracles.map((name) => [name, true]));
    return {
      id: entry.id,
      surface: entry.surface,
      command: entry.command,
      phase: entry.phase,
      expected_exit: entry.expected_exit,
      exit_code: exitsSuccessfully ? 0 : 1,
      result_success: exitsSuccessfully,
      effect: selectedOutcome?.effect ?? entry.expected_effect ?? null,
      delivery_mode: entry.expected_delivery ?? null,
      error_code: selectedOutcome?.error_code ?? entry.expected_error_code ?? null,
      invariant_violations: 0,
      evidence,
      oracles,
    };
  });
  return { probe_canary: true, cases };
}

function parseArguments(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--self-test") {
      args.selfTest = true;
    } else if (["--catalog", "--report", "--output"].includes(value)) {
      args[value.slice(2)] = argv[index + 1];
      index += 1;
    } else {
      throw new Error(`Unknown or incomplete argument: ${value}`);
    }
  }
  return args;
}

function writeResult(result, outputPath) {
  const data = `${JSON.stringify(result, null, 2)}\n`;
  if (outputPath) fs.writeFileSync(outputPath, data);
  else process.stdout.write(data);
}

function runCLI() {
  const args = parseArguments(process.argv.slice(2));
  if (!args.catalog) throw new Error("--catalog is required");
  const catalog = JSON.parse(fs.readFileSync(args.catalog, "utf8"));
  const report = args.selfTest
    ? makePassingReport(catalog)
    : JSON.parse(fs.readFileSync(args.report ?? "", "utf8"));
  const result = validateCertification(catalog, report);
  writeResult(result, args.output);
  if (!result.success) process.exitCode = 1;
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  try {
    runCLI();
  } catch (error) {
    process.stderr.write(`background certification reporter: ${error.message}\n`);
    process.exitCode = 2;
  }
}
