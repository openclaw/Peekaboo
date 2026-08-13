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
  if (!Array.isArray(catalog.invariants) || catalog.invariants.length === 0) {
    failures.push(failure("catalog", "schema", "Catalog must declare invariants"));
  } else {
    if (catalog.invariants.some((name) => typeof name !== "string" || name.length === 0)) {
      failures.push(failure("catalog", "schema", "Catalog invariants must be nonempty strings"));
    }
    for (const name of duplicateValues(catalog.invariants)) {
      failures.push(failure("catalog", "duplicate_catalog_invariant", `Catalog invariant '${name}' is duplicated`));
    }
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
    if (entry?.contamination_retry_safe !== undefined
        && typeof entry.contamination_retry_safe !== "boolean") {
      failures.push(failure(
        entry?.id ?? "catalog",
        "schema",
        "contamination_retry_safe must be a boolean",
      ));
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

const exactSourceCommit = /^[0-9a-f]{40}$/;

function isExactSourceCommit(value) {
  return typeof value === "string" && value.length === 40 && exactSourceCommit.test(value);
}

function isExactSocketPath(value) {
  return typeof value === "string"
    && path.isAbsolute(value)
    && !["\0", "\r", "\n"].some((character) => value.includes(character));
}

function isExactRemoteHostReceipt(receipt) {
  const keys = receipt && typeof receipt === "object" && !Array.isArray(receipt)
    ? Object.keys(receipt).sort()
    : [];
  const expectedKeys = ["pid", "socketPath", "sourceCommit", "startIdentity"];
  return keys.length === expectedKeys.length
    && keys.every((key, index) => key === expectedKeys[index])
    && Number.isSafeInteger(receipt.pid)
    && receipt.pid > 0
    && typeof receipt.startIdentity === "string"
    && receipt.startIdentity.length > 0
    && receipt.startIdentity[0] !== "0"
    && [...receipt.startIdentity].every((character) => character >= "0" && character <= "9")
    && isExactSocketPath(receipt.socketPath)
    && isExactSourceCommit(receipt.sourceCommit);
}

function sameRemoteHostReceipt(left, right) {
  return isExactRemoteHostReceipt(left)
    && isExactRemoteHostReceipt(right)
    && left.pid === right.pid
    && left.startIdentity === right.startIdentity
    && left.socketPath === right.socketPath
    && left.sourceCommit === right.sourceCommit;
}

function validateProvenance(report, failures) {
  const provenance = report?.provenance;
  const keys = provenance && typeof provenance === "object" && !Array.isArray(provenance)
    ? Object.keys(provenance).sort()
    : [];
  const expectedKeys = [
    "cli_source_commit",
    "event_producer_source",
    "event_producer_source_commit",
    "remote_host",
    "requested_bridge_socket",
  ];
  if (keys.length !== expectedKeys.length
      || keys.some((key, index) => key !== expectedKeys[index])) {
    failures.push(failure(
      "certification",
      "provenance_schema",
      "Provenance must be a closed CLI/event-producer source receipt",
    ));
    return;
  }
  if (!isExactSourceCommit(provenance.cli_source_commit)
      || !isExactSourceCommit(provenance.event_producer_source_commit)) {
    failures.push(failure(
      "certification",
      "source_commit",
      "CLI and event-producer source commits must be canonical 40-hex values",
    ));
  }
  if (!["local", "remote"].includes(provenance.event_producer_source)) {
    failures.push(failure(
      "certification",
      "event_producer_source",
      "Event-producer source must be local or remote",
    ));
  }
  if (provenance.cli_source_commit !== provenance.event_producer_source_commit) {
    failures.push(failure(
      "certification",
      "source_commit_mismatch",
      "CLI and event-producer source commits differ",
    ));
  }
  if (provenance.event_producer_source === "remote") {
    if (!isExactRemoteHostReceipt(provenance.remote_host)
        || provenance.remote_host.sourceCommit !== provenance.event_producer_source_commit) {
      failures.push(failure(
        "certification",
        "remote_host_receipt",
        "Remote certification requires one exact socket and process-generation source receipt",
      ));
    }
    if (!isExactSocketPath(provenance.requested_bridge_socket)
        || provenance.remote_host?.socketPath !== provenance.requested_bridge_socket) {
      failures.push(failure(
        "certification",
        "bridge_socket_mismatch",
        "Remote host receipt does not match the exact requested Bridge socket",
      ));
    }
  } else if (provenance.event_producer_source === "local"
      && (provenance.remote_host !== null || provenance.requested_bridge_socket !== null)) {
    failures.push(failure(
      "certification",
      "remote_host_receipt",
      "Local certification must not claim a remote host receipt",
    ));
  }
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
  validateProvenance(report, failures);

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
    const provenance = report?.provenance;
    const eventProducerMatches = provenance?.event_producer_source === "remote"
      ? sameRemoteHostReceipt(observed.event_producer, provenance.remote_host)
      : provenance?.event_producer_source === "local" && observed.event_producer === null;
    if (!eventProducerMatches) {
      failures.push(failure(
        expected.id,
        "event_producer_receipt",
        "Case event producer does not match the certification provenance receipt",
      ));
    }
    if (observed.event_producer_stable !== true) {
      failures.push(failure(
        expected.id,
        "event_producer_stability",
        "Case did not retain one event-producer generation across dispatch",
      ));
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
    const invariantResults = observed.invariants;
    if (!Array.isArray(invariantResults)) {
      failures.push(failure(expected.id, "invariant_schema", "Observed invariants must be an array"));
    } else {
      const validInvariantResults = [];
      for (const result of invariantResults) {
        const keys = result && typeof result === "object" && !Array.isArray(result)
          ? Object.keys(result).sort()
          : [];
        if (keys.length !== 2 || keys[0] !== "name" || keys[1] !== "passed"
            || typeof result.name !== "string" || result.name.length === 0
            || typeof result.passed !== "boolean") {
          failures.push(failure(
            expected.id,
            "invariant_schema",
            "Invariant results must be closed {name, passed} entries",
          ));
          continue;
        }
        validInvariantResults.push(result);
      }
      const observedInvariantNames = validInvariantResults.map((result) => result.name);
      for (const invariantName of duplicateValues(observedInvariantNames)) {
        failures.push(failure(
          expected.id,
          "duplicate_invariant_result",
          `Invariant result '${invariantName}' is duplicated`,
        ));
      }
      for (const invariantName of catalog.invariants) {
        const matchingResults = validInvariantResults.filter((result) => result.name === invariantName);
        if (matchingResults.length === 0) {
          failures.push(failure(
            expected.id,
            "missing_invariant",
            `Missing invariant '${invariantName}'`,
          ));
        } else if (matchingResults.some((result) => result.passed !== true)) {
          failures.push(failure(
            expected.id,
            "violated_invariant",
            `Invariant '${invariantName}' did not pass`,
          ));
        }
      }
      for (const invariantName of observedInvariantNames) {
        if (!catalog.invariants.includes(invariantName)) {
          failures.push(failure(
            expected.id,
            "unknown_invariant",
            `Observed invariant '${invariantName}' is not cataloged`,
          ));
        }
      }
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
    const invariants = catalog.invariants.map((name) => ({ name, passed: true }));
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
      event_producer: null,
      event_producer_stable: true,
      invariants,
      evidence,
      oracles,
    };
  });
  const sourceCommit = "0123456789abcdef0123456789abcdef01234567";
  return {
    probe_canary: true,
    provenance: {
      cli_source_commit: sourceCommit,
      event_producer_source: "local",
      event_producer_source_commit: sourceCommit,
      requested_bridge_socket: null,
      remote_host: null,
    },
    cases,
  };
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
