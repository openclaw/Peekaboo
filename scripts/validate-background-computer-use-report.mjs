#!/usr/bin/env node

import fs from "node:fs";
import { createHash } from "node:crypto";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

function failure(caseId, rule, message) {
  return { case_id: caseId, rule, message };
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
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

const mutationCommands = new Set([
  "action",
  "app quit",
  "click",
  "menu click",
  "paste",
  "press",
  "scroll",
  "set-value",
  "type",
  "window close",
  "window maximize",
]);

function allowsSuccessfulMutation(entry) {
  const declaredSuccess = entry?.expected_exit === "success" || entry?.expected_exit === "either";
  const conditionalSuccess = Array.isArray(entry?.allowed_outcomes)
    && entry.allowed_outcomes.some((outcome) => outcome?.exit === "success");
  return mutationCommands.has(entry?.command) && (declaredSuccess || conditionalSuccess);
}

function validateCatalog(catalog) {
  const failures = [];
  if (!catalog || catalog.version !== 2 || !Array.isArray(catalog.cases)) {
    return [failure("catalog", "schema", "Catalog must be version 2 with a cases array")];
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
  if (!Array.isArray(catalog.physical_apps) || catalog.physical_apps.length !== 8
      || catalog.physical_apps.some((name) => typeof name !== "string" || name.length === 0)) {
    failures.push(failure("catalog", "schema", "Catalog must declare eight physical app names"));
  } else {
    for (const name of duplicateValues(catalog.physical_apps)) {
      failures.push(failure(name, "duplicate_physical_app", `Physical app '${name}' is duplicated`));
    }
  }
  if (!catalog.physical_app_bundle_ids
      || typeof catalog.physical_app_bundle_ids !== "object"
      || Array.isArray(catalog.physical_app_bundle_ids)
      || JSON.stringify(Object.keys(catalog.physical_app_bundle_ids).sort())
        !== JSON.stringify([...(catalog.physical_apps ?? [])].sort())
      || Object.values(catalog.physical_app_bundle_ids).some((bundleID) => (
        typeof bundleID !== "string" || bundleID.length === 0
      ))
      || new Set(Object.values(catalog.physical_app_bundle_ids)).size !== 8) {
    failures.push(failure(
      "catalog",
      "physical_app_bundle_ids",
      "Catalog must map every physical app to one distinct exact bundle identifier",
    ));
  }
  const physicalTitleKeys = catalog.physical_app_window_titles
    && typeof catalog.physical_app_window_titles === "object"
    && !Array.isArray(catalog.physical_app_window_titles)
    ? Object.keys(catalog.physical_app_window_titles).sort()
    : [];
  if (JSON.stringify(physicalTitleKeys) !== JSON.stringify(["activity-monitor"])
      || physicalTitleKeys.some((name) => !catalog.physical_apps?.includes(name))
      || Object.values(catalog.physical_app_window_titles ?? {}).some((title) => (
        typeof title !== "string" || title.length === 0 || title.trim() !== title
      ))) {
    failures.push(failure(
      "catalog",
      "physical_app_window_titles",
      "Catalog must declare one normalized exact Activity Monitor window title",
    ));
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
    if (entry?.expected_delivery !== undefined
        && !["background", "foreground"].includes(entry.expected_delivery)) {
      failures.push(failure(entry?.id ?? "catalog", "schema", "Invalid expected_delivery"));
    }
    if (allowsSuccessfulMutation(entry) && entry.expected_delivery !== "background") {
      failures.push(failure(
        entry?.id ?? "catalog",
        "mutation_delivery",
        "Every successful cataloged mutation must explicitly require background delivery",
      ));
    }
    if (!Array.isArray(entry?.required_oracles)) {
      failures.push(failure(entry?.id ?? "catalog", "schema", "required_oracles must be an array"));
    }
    if (entry?.physical_app !== undefined
        && !catalog.physical_apps?.includes(entry.physical_app)) {
      failures.push(failure(
        entry?.id ?? "catalog",
        "schema",
        "Case physical_app must name a declared physical app",
      ));
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
  if (Array.isArray(catalog.physical_apps)) {
    for (const name of catalog.physical_apps) {
      const coverage = catalog.cases.filter((entry) => entry?.physical_app === name);
      if (coverage.length !== 1) {
        failures.push(failure(
          name,
          "physical_app_coverage",
          `Physical app '${name}' must have exactly one certification case`,
        ));
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
const exactSHA256 = /^[0-9a-f]{64}$/;
const exactUUIDv4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

function isExactSourceCommit(value) {
  return typeof value === "string" && value.length === 40 && exactSourceCommit.test(value);
}

function isExactSourceArtifacts(value) {
  const keys = value && typeof value === "object" && !Array.isArray(value)
    ? Object.keys(value).sort()
    : [];
  const expected = [
    "bridge_code_signature_hash",
    "bridge_executable_device",
    "bridge_executable_inode",
    "bridge_executable_sha256",
    "catalog_sha256",
    "cli_code_signature_hash",
    "cli_executable_device",
    "cli_executable_inode",
    "cli_executable_sha256",
    "harness_sha256",
    "playground_code_signature_hash",
    "playground_executable_sha256",
    "playground_source_tree",
    "probe_executable_sha256",
    "probe_source_sha256",
    "reporter_sha256",
  ];
  return keys.length === expected.length
    && keys.every((key, index) => key === expected[index])
    && [
      value.catalog_sha256,
      value.cli_executable_sha256,
      value.harness_sha256,
      value.playground_executable_sha256,
      value.probe_executable_sha256,
      value.probe_source_sha256,
      value.reporter_sha256,
    ].every((digest) => typeof digest === "string" && exactSHA256.test(digest))
    && typeof value.cli_code_signature_hash === "string"
    && exactSourceCommit.test(value.cli_code_signature_hash)
    && [value.cli_executable_device, value.cli_executable_inode].every((entry) => (
      typeof entry === "string" && /^[1-9][0-9]*$/.test(entry)
    ))
    && ((value.bridge_executable_sha256 === null
        && value.bridge_code_signature_hash === null
        && value.bridge_executable_device === null
        && value.bridge_executable_inode === null)
      || (typeof value.bridge_executable_sha256 === "string"
        && exactSHA256.test(value.bridge_executable_sha256)
        && typeof value.bridge_code_signature_hash === "string"
        && exactSourceCommit.test(value.bridge_code_signature_hash)
        && typeof value.bridge_executable_device === "string"
        && /^[1-9][0-9]*$/.test(value.bridge_executable_device)
        && typeof value.bridge_executable_inode === "string"
        && /^[1-9][0-9]*$/.test(value.bridge_executable_inode)))
    && isExactSourceCommit(value.playground_source_tree)
    && typeof value.playground_code_signature_hash === "string"
    && exactSourceCommit.test(value.playground_code_signature_hash);
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
  const expectedKeys = ["codeSignatureHash", "pid", "socketPath", "sourceCommit", "startIdentity"];
  return keys.length === expectedKeys.length
    && keys.every((key, index) => key === expectedKeys[index])
    && Number.isSafeInteger(receipt.pid)
    && receipt.pid > 0
    && typeof receipt.startIdentity === "string"
    && receipt.startIdentity.length > 0
    && receipt.startIdentity[0] !== "0"
    && [...receipt.startIdentity].every((character) => character >= "0" && character <= "9")
    && isExactSocketPath(receipt.socketPath)
    && typeof receipt.codeSignatureHash === "string"
    && exactSourceCommit.test(receipt.codeSignatureHash)
    && isExactSourceCommit(receipt.sourceCommit);
}

function sameRemoteHostReceipt(left, right) {
  return isExactRemoteHostReceipt(left)
    && isExactRemoteHostReceipt(right)
    && left.pid === right.pid
    && left.startIdentity === right.startIdentity
    && left.socketPath === right.socketPath
    && left.codeSignatureHash === right.codeSignatureHash
    && left.sourceCommit === right.sourceCommit;
}

function isExactMonitorReceipt(receipt) {
  const keys = receipt && typeof receipt === "object" && !Array.isArray(receipt)
    ? Object.keys(receipt).sort()
    : [];
  const expectedKeys = [
    "execution_nonce", "final", "history_commitment_sha256", "monitor_instance_id",
    "producer_revision", "start",
  ];
  const validFence = (value) => value && typeof value === "object" && !Array.isArray(value)
    && JSON.stringify(Object.keys(value).sort()) === JSON.stringify([
      "authorization_epoch", "monotonic_microseconds", "producer_revision", "sequence",
      "wall_clock_milliseconds",
    ])
    && [
      value.authorization_epoch,
      value.monotonic_microseconds,
      value.producer_revision,
      value.sequence,
      value.wall_clock_milliseconds,
    ].every((number) => Number.isSafeInteger(number) && number > 0);
  return keys.length === expectedKeys.length
    && keys.every((key, index) => key === expectedKeys[index])
    && exactSHA256.test(receipt.execution_nonce ?? "")
    && exactUUIDv4.test(receipt.monitor_instance_id ?? "")
    && exactSHA256.test(receipt.history_commitment_sha256 ?? "")
    && Number.isSafeInteger(receipt.producer_revision) && receipt.producer_revision > 0
    && validFence(receipt.start) && validFence(receipt.final)
    && receipt.start.producer_revision === 1
    && receipt.final.producer_revision === receipt.producer_revision
    && receipt.final.sequence > receipt.start.sequence
    && receipt.final.authorization_epoch > receipt.start.authorization_epoch
    && receipt.final.monotonic_microseconds > receipt.start.monotonic_microseconds
    && receipt.final.wall_clock_milliseconds >= receipt.start.wall_clock_milliseconds;
}

function isExactPhysicalTarget(target, physicalApp, expectedBundleID, expectedWindowTitle) {
  const keys = target && typeof target === "object" && !Array.isArray(target)
    ? Object.keys(target).sort()
    : [];
  const expectedKeys = [
    "application_name", "bounds", "bundle_id", "executable", "physical_app", "pid",
    "process_start_identity", "window_id", "window_title",
  ];
  const executableKeys = target?.executable && typeof target.executable === "object"
    ? Object.keys(target.executable).sort()
    : [];
  return keys.length === expectedKeys.length
    && keys.every((key, index) => key === expectedKeys[index])
    && target.physical_app === physicalApp
    && typeof target.application_name === "string" && target.application_name.length > 0
    && (expectedWindowTitle === undefined || (
      target.application_name.trim() === expectedWindowTitle
      && typeof target.window_title === "string"
      && target.window_title.trim() === expectedWindowTitle
    ))
    && target.bundle_id === expectedBundleID
    && Number.isSafeInteger(target.pid) && target.pid > 0
    && typeof target.process_start_identity === "string"
    && /^[1-9][0-9]*$/.test(target.process_start_identity)
    && Number.isSafeInteger(target.window_id) && target.window_id > 0
    && typeof target.window_title === "string"
    && target.bounds
    && JSON.stringify(Object.keys(target.bounds).sort()) === JSON.stringify(["height", "width", "x", "y"])
    && ["height", "width", "x", "y"].every((key) => (
      Number.isFinite(target.bounds[key])
    ))
    && executableKeys.length === 3
    && executableKeys.every((key, index) => key === ["code_signature_hash", "path", "sha256"][index])
    && isExactSocketPath(target.executable.path)
    && exactSHA256.test(target.executable.sha256 ?? "")
    && exactSourceCommit.test(target.executable.code_signature_hash ?? "");
}

function validateProvenance(report, failures, trustedSourceArtifacts) {
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
    "source_artifacts",
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
  if (!isExactSourceArtifacts(provenance.source_artifacts)) {
    failures.push(failure(
      "certification",
      "source_artifacts",
      "Catalog, reporter, probe, harness, and Playground provenance must be exact digests",
    ));
  }
  if (trustedSourceArtifacts
      && (provenance.source_artifacts?.catalog_sha256 !== trustedSourceArtifacts.catalog_sha256
        || provenance.source_artifacts?.reporter_sha256 !== trustedSourceArtifacts.reporter_sha256)) {
    failures.push(failure(
      "certification",
      "trusted_source_artifacts",
      "Reported catalog or reporter digest differs from the trusted files used for validation",
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
    if (!exactSHA256.test(provenance.source_artifacts?.bridge_executable_sha256 ?? "")
        || provenance.source_artifacts?.bridge_code_signature_hash
          !== provenance.remote_host?.codeSignatureHash) {
      failures.push(failure(
        "certification",
        "bridge_binary_receipt",
        "Remote certification must bind the exact Bridge executable and code signature",
      ));
    }
  } else if (provenance.event_producer_source === "local"
      && (provenance.remote_host !== null || provenance.requested_bridge_socket !== null)) {
    failures.push(failure(
      "certification",
      "remote_host_receipt",
      "Local certification must not claim a remote host receipt",
    ));
  } else if (provenance.event_producer_source === "local"
      && (provenance.source_artifacts?.bridge_executable_sha256 !== null
        || provenance.source_artifacts?.bridge_code_signature_hash !== null
        || provenance.source_artifacts?.bridge_executable_device !== null
        || provenance.source_artifacts?.bridge_executable_inode !== null)) {
    failures.push(failure(
      "certification",
      "bridge_binary_receipt",
      "Local certification must not claim a remote Bridge binary",
    ));
  }
}

export function validateCertification(catalog, report, trustedSourceArtifacts = null) {
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
  if (report?.provenance_stable !== true) {
    failures.push(failure(
      "certification",
      "provenance_stability",
      "Source and executable provenance changed during certification",
    ));
  }
  validateProvenance(report, failures, trustedSourceArtifacts);

  const observedCases = Array.isArray(report?.cases) ? report.cases : [];
  const monitorReceipts = observedCases.map((entry) => entry?.monitor_receipt);
  if (monitorReceipts.some((receipt) => !isExactMonitorReceipt(receipt))) {
    failures.push(failure(
      "certification",
      "monitor_receipt",
      "Every case must carry one closed run-bound start/final monitor receipt",
    ));
  } else if (new Set(monitorReceipts.map((receipt) => receipt.execution_nonce)).size !== 1
      || new Set(monitorReceipts.map((receipt) => receipt.monitor_instance_id)).size
        !== monitorReceipts.length) {
    failures.push(failure(
      "certification",
      "monitor_run_binding",
      "Cases must share one execution nonce and use distinct monitor instances",
    ));
  }
  const physicalTargets = observedCases
    .filter((entry) => entry?.physical_app !== null && entry?.physical_app !== undefined)
    .map((entry) => entry?.physical_target);
  const physicalProcessGenerations = physicalTargets.map((target) => (
    `${target?.pid ?? "?"}:${target?.process_start_identity ?? "?"}`
  ));
  const physicalWindowIdentities = physicalTargets.map((target) => (
    `${target?.pid ?? "?"}:${target?.process_start_identity ?? "?"}:${target?.window_id ?? "?"}`
  ));
  if (physicalTargets.length !== 8
      || new Set(physicalProcessGenerations).size !== physicalProcessGenerations.length
      || new Set(physicalWindowIdentities).size !== physicalWindowIdentities.length) {
    failures.push(failure(
      "certification",
      "physical_target_duplicate",
      "The eight physical rows must use distinct process-generation and window identities",
    ));
  }
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
    if ((observed.physical_app ?? null) !== (expected.physical_app ?? null)) {
      failures.push(failure(
        expected.id,
        "physical_app_mismatch",
        `Expected physical app '${expected.physical_app ?? "none"}', observed '${observed.physical_app ?? "none"}'`,
      ));
    }
    if (expected.physical_app === undefined) {
      if (observed.physical_target !== null) {
        failures.push(failure(
          expected.id,
          "physical_target_mismatch",
          "Non-physical matrix cases must not claim a physical target receipt",
        ));
      }
    } else if (!isExactPhysicalTarget(
      observed.physical_target,
      expected.physical_app,
      catalog.physical_app_bundle_ids[expected.physical_app],
      catalog.physical_app_window_titles?.[expected.physical_app],
    )) {
      failures.push(failure(
        expected.id,
        "physical_target_mismatch",
        "Physical matrix case lacks an exact executable/signing/process/window receipt",
      ));
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
    if (expected.expected_delivery !== undefined
        && observed.result_success === true
        && observed.delivery_mode !== expected.expected_delivery) {
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
  const executionNonce = "a".repeat(64);
  const cases = catalog.cases.map((entry, index) => {
    const selectedOutcome = entry.allowed_outcomes?.[0];
    const exitsSuccessfully = selectedOutcome
      ? selectedOutcome.exit === "success"
      : entry.expected_exit !== "failure";
    const evidence = Object.fromEntries(catalog.required_evidence.map((name) => [name, true]));
    const oracles = Object.fromEntries(entry.required_oracles.map((name) => [name, true]));
    const invariants = catalog.invariants.map((name) => ({ name, passed: true }));
    const expectedWindowTitle = catalog.physical_app_window_titles?.[entry.physical_app];
    return {
      id: entry.id,
      surface: entry.surface,
      command: entry.command,
      phase: entry.phase,
      physical_app: entry.physical_app ?? null,
      physical_target: entry.physical_app === undefined ? null : {
        application_name: expectedWindowTitle ?? entry.physical_app,
        bundle_id: catalog.physical_app_bundle_ids[entry.physical_app],
        pid: index + 100,
        process_start_identity: String(index + 1000),
        window_id: index + 200,
        window_title: expectedWindowTitle ?? "Fixture",
        bounds: { x: 0, y: 0, width: 800, height: 600 },
        physical_app: entry.physical_app,
        executable: {
          path: `/System/Applications/${entry.physical_app}.app/Contents/MacOS/fixture`,
          sha256: "d".repeat(64),
          code_signature_hash: "e".repeat(40),
        },
      },
      expected_exit: entry.expected_exit,
      exit_code: exitsSuccessfully ? 0 : 1,
      result_success: exitsSuccessfully,
      effect: selectedOutcome?.effect ?? entry.expected_effect ?? null,
      delivery_mode: entry.expected_delivery ?? null,
      error_code: selectedOutcome?.error_code ?? entry.expected_error_code ?? null,
      event_producer: null,
      event_producer_stable: true,
      monitor_receipt: {
        execution_nonce: executionNonce,
        monitor_instance_id: `00000000-0000-4000-8${index.toString(16).padStart(3, "0")}-000000000001`,
        history_commitment_sha256: "b".repeat(64),
        producer_revision: index + 2,
        start: {
          sequence: 1,
          authorization_epoch: 1,
          monotonic_microseconds: 1000,
          producer_revision: 1,
          wall_clock_milliseconds: 1786870761000,
        },
        final: {
          sequence: 2,
          authorization_epoch: 2,
          monotonic_microseconds: 2000,
          producer_revision: index + 2,
          wall_clock_milliseconds: 1786870761001,
        },
      },
      invariants,
      evidence,
      oracles,
    };
  });
  const sourceCommit = "0123456789abcdef0123456789abcdef01234567";
  return {
    probe_canary: true,
    provenance_stable: true,
    provenance: {
      cli_source_commit: sourceCommit,
      event_producer_source: "local",
      event_producer_source_commit: sourceCommit,
      requested_bridge_socket: null,
      remote_host: null,
      source_artifacts: {
        bridge_code_signature_hash: null,
        bridge_executable_device: null,
        bridge_executable_inode: null,
        bridge_executable_sha256: null,
        catalog_sha256: "1".repeat(64),
        cli_code_signature_hash: "8".repeat(40),
        cli_executable_device: "1",
        cli_executable_inode: "2",
        cli_executable_sha256: "9".repeat(64),
        reporter_sha256: "2".repeat(64),
        probe_source_sha256: "3".repeat(64),
        probe_executable_sha256: "4".repeat(64),
        harness_sha256: "5".repeat(64),
        playground_source_tree: sourceCommit,
        playground_executable_sha256: "6".repeat(64),
        playground_code_signature_hash: "7".repeat(40),
      },
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
  const catalogBytes = fs.readFileSync(args.catalog);
  const catalog = JSON.parse(catalogBytes);
  const report = args.selfTest
    ? makePassingReport(catalog)
    : JSON.parse(fs.readFileSync(args.report ?? "", "utf8"));
  const trustedSourceArtifacts = args.selfTest ? null : {
    catalog_sha256: sha256(catalogBytes),
    reporter_sha256: sha256(fs.readFileSync(fileURLToPath(import.meta.url))),
  };
  const result = validateCertification(catalog, report, trustedSourceArtifacts);
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
