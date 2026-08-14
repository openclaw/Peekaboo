#!/usr/bin/env node

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const hex40 = /^[0-9a-f]{40}$/;
const hex64 = /^[0-9a-f]{64}$/;
const decimalIdentity = /^[1-9][0-9]*$/;

function failure(rule, message, controller = null) {
  return { rule, message, controller };
}

function exactKeys(value, expected) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  return actual.length === wanted.length && actual.every((key, index) => key === wanted[index]);
}

function positiveInteger(value) {
  return Number.isSafeInteger(value) && value > 0;
}

function finiteTimestamp(value) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0;
}

function exactProcessReceipt(value) {
  return exactKeys(value, ['pid', 'start_identity'])
    && validProcessFields(value);
}

function validProcessFields(value) {
  return positiveInteger(value?.pid)
    && typeof value.start_identity === 'string'
    && decimalIdentity.test(value.start_identity);
}

function exactTargetReceipt(value) {
  return exactKeys(value, ['pid', 'start_identity', 'window_id'])
    && validTargetFields(value);
}

function validTargetFields(value) {
  return validProcessFields(value) && positiveInteger(value?.window_id);
}

function validateCatalog(catalog) {
  const failures = [];
  if (!exactKeys(catalog, [
    'version', 'controllers', 'invariants', 'cursor_policy', 'required_evidence',
  ]) || catalog?.version !== 1) {
    return [failure('catalog_schema', 'Catalog must be one closed version-1 object')];
  }
  if (!Array.isArray(catalog.controllers) || catalog.controllers.length !== 2
      || catalog.controllers.map((entry) => entry?.id).join(',') !== 'A,B'
      || catalog.controllers.some((entry) => !exactKeys(
        entry,
        ['id', 'workflow_commands', 'restoration_command', 'minimum_observations'],
      ) || !Array.isArray(entry.workflow_commands) || entry.workflow_commands.length === 0
        || entry.workflow_commands.some((command) => !['type', 'press'].includes(command))
        || !['type', 'press'].includes(entry.restoration_command)
        || !positiveInteger(entry.minimum_observations))) {
    failures.push(failure('catalog_controllers', 'Catalog must define exact A and B controller requirements'));
  }
  for (const field of ['invariants', 'required_evidence']) {
    const values = catalog[field];
    if (!Array.isArray(values) || values.length === 0
        || values.some((value) => typeof value !== 'string' || value.length === 0)
        || new Set(values).size !== values.length) {
      failures.push(failure('catalog_schema', `${field} must contain unique nonempty names`));
    }
  }
  if (catalog.cursor_policy !== 'observational') {
    failures.push(failure('catalog_cursor_policy', 'Physical cursor policy must remain observational'));
  }
  return failures;
}

function validateHost(report, failures) {
  const host = report.host;
  if (!exactKeys(host, [
    'pid', 'start_identity', 'socket_path', 'source_commit', 'code_signature_hash',
    'protocol_major', 'protocol_minor', 'executable_sha256', 'stable',
  ]) || !validProcessFields(host)
      || typeof host.socket_path !== 'string' || !path.isAbsolute(host.socket_path)
      || !hex40.test(host.source_commit ?? '')
      || !hex40.test(host.code_signature_hash ?? '')
      || !hex64.test(host.executable_sha256 ?? '')
      || !positiveInteger(host.protocol_major)
      || !Number.isSafeInteger(host.protocol_minor) || host.protocol_minor < 0
      || host.stable !== true) {
    failures.push(failure('host_receipt', 'Signed current host receipt is incomplete, malformed, or unstable'));
  }
  if (host?.source_commit !== report.source_commit) {
    failures.push(failure('host_source', 'Host source commit differs from the certified CLI source'));
  }
}

function validateCLI(report, failures) {
  const cli = report.cli;
  if (!exactKeys(cli, ['source_commit', 'code_signature_hash', 'executable_sha256', 'executable_path'])
      || cli.source_commit !== report.source_commit
      || !hex40.test(cli.code_signature_hash ?? '')
      || !hex64.test(cli.executable_sha256 ?? '')
      || typeof cli.executable_path !== 'string' || !path.isAbsolute(cli.executable_path)) {
    failures.push(failure('cli_receipt', 'CLI build receipt is incomplete or differs from the certified source'));
  }
}

function validateMutation(entry, controller, target, cli, host, index, failures) {
  if (!exactKeys(entry, [
    'index', 'command', 'phase', 'started_at', 'finished_at', 'target_pid', 'target_window_id',
    'success', 'effect', 'mutation_dispatched', 'retry_safe', 'foreground', 'client_pid',
    'client_start_identity', 'reported_target_pid', 'reported_target_window_id',
    'target_start_identity_after', 'delivery_mode', 'client_executable_path',
    'host_pid', 'host_start_identity', 'host_code_signature_hash',
  ]) || entry.index !== index
      || !['type', 'press'].includes(entry.command)
      || !['workflow', 'restoration'].includes(entry.phase)
      || !finiteTimestamp(entry.started_at) || !finiteTimestamp(entry.finished_at)
      || entry.finished_at <= entry.started_at
      || entry.target_pid !== target.pid || entry.target_window_id !== target.window_id
      || !positiveInteger(entry.client_pid)
      || typeof entry.client_start_identity !== 'string'
      || !decimalIdentity.test(entry.client_start_identity)
      || entry.client_executable_path !== cli.executable_path
      || entry.host_pid !== host.pid
      || entry.host_start_identity !== host.start_identity
      || entry.host_code_signature_hash !== host.code_signature_hash
      || entry.reported_target_pid !== target.pid
      || entry.reported_target_window_id !== target.window_id
      || entry.target_start_identity_after !== target.start_identity
      || entry.delivery_mode !== 'background'
      || entry.success !== true
      || !['confirmed', 'unverifiable'].includes(entry.effect)
      || entry.mutation_dispatched !== true || entry.retry_safe !== false
      || entry.foreground !== false) {
    failures.push(failure('mutation_contract', `Controller ${controller} mutation ${index} is not exact`, controller));
  }
}

function validateObservation(entry, controller, target, cli, host, index, failures) {
  if (!exactKeys(entry, [
    'index', 'started_at', 'finished_at', 'target_pid', 'target_window_id',
    'expected_token', 'token_present', 'other_token_absent', 'client_pid',
    'client_start_identity', 'reported_window_id', 'target_start_identity_after', 'route_receipt',
    'client_executable_path', 'host_pid', 'host_start_identity', 'host_code_signature_hash',
    'result_success',
  ]) || entry.index !== index
      || !finiteTimestamp(entry.started_at) || !finiteTimestamp(entry.finished_at)
      || entry.finished_at <= entry.started_at
      || entry.target_pid !== target.pid || entry.target_window_id !== target.window_id
      || !positiveInteger(entry.client_pid)
      || typeof entry.client_start_identity !== 'string'
      || !decimalIdentity.test(entry.client_start_identity)
      || entry.client_executable_path !== cli.executable_path
      || entry.host_pid !== host.pid
      || entry.host_start_identity !== host.start_identity
      || entry.host_code_signature_hash !== host.code_signature_hash
      || entry.reported_window_id !== target.window_id
      || entry.target_start_identity_after !== target.start_identity
      || entry.result_success !== true
      || typeof entry.expected_token !== 'string' || entry.expected_token.length === 0
      || entry.token_present !== true || entry.other_token_absent !== true) {
    failures.push(failure('observation_contract', `Controller ${controller} observation ${index} is not exact`, controller));
  }
  const route = entry?.route_receipt;
  if (!exactKeys(route, [
    'client_pid', 'client_start_identity', 'client_executable_path', 'host_pid',
    'host_start_identity', 'host_code_signature_hash', 'reported_target_pid',
    'reported_window_id', 'target_start_identity_after', 'result_success',
  ]) || !positiveInteger(route.client_pid)
      || typeof route.client_start_identity !== 'string'
      || !decimalIdentity.test(route.client_start_identity)
      || route.client_executable_path !== cli.executable_path
      || route.host_pid !== host.pid
      || route.host_start_identity !== host.start_identity
      || route.host_code_signature_hash !== host.code_signature_hash
      || route.reported_target_pid !== target.pid
      || route.reported_window_id !== target.window_id
      || route.target_start_identity_after !== target.start_identity
      || route.result_success !== true) {
    failures.push(failure('observation_route', `Controller ${controller} route receipt ${index} is not exact`, controller));
  }
}

function validateController(observed, expected, other, runID, cli, host, failures) {
  if (!exactKeys(observed, [
    'id', 'controller_process', 'target', 'started_at', 'finished_at', 'mutations', 'observations',
    'initial_token', 'final_token', 'readback_token', 'restored_token',
    'restoration_readback', 'cross_target_clear',
  ]) || observed?.id !== expected.id || !exactProcessReceipt(observed?.controller_process)
      || !exactTargetReceipt(observed?.target)
      || !finiteTimestamp(observed?.started_at) || !finiteTimestamp(observed?.finished_at)
      || observed.finished_at <= observed.started_at
      || typeof observed.initial_token !== 'string' || observed.initial_token.length === 0
      || typeof observed.final_token !== 'string' || observed.final_token.length === 0
      || observed.final_token === observed.initial_token
      || observed.readback_token !== observed.final_token
      || observed.restored_token !== observed.initial_token
      || observed.restoration_readback !== observed.initial_token
      || observed.cross_target_clear !== true) {
    failures.push(failure('controller_schema', `Controller ${expected.id} receipt or postcondition is invalid`, expected.id));
    return;
  }
  if (observed.target.pid === other?.target?.pid
      || observed.target.window_id === other?.target?.window_id) {
    failures.push(failure('target_isolation', 'Controllers must own distinct process and window receipts', expected.id));
  }
  const namespace = `${runID}-${expected.id.toLowerCase()}-`;
  const ownTokens = new Set([
    observed.initial_token,
    observed.final_token,
    ...(observed.observations ?? []).map((entry) => entry?.expected_token),
  ]);
  const otherTokens = new Set([
    other?.initial_token,
    other?.final_token,
    ...(other?.observations ?? []).map((entry) => entry?.expected_token),
  ]);
  if ([...ownTokens].some((token) => typeof token !== 'string' || !token.startsWith(namespace))
      || [...ownTokens].some((token) => otherTokens.has(token))) {
    failures.push(failure('token_namespace', `Controller ${expected.id} token namespace is not isolated`, expected.id));
  }
  const workflowMutations = Array.isArray(observed.mutations)
    ? observed.mutations.filter((entry) => entry?.phase === 'workflow')
    : [];
  const restorationMutations = Array.isArray(observed.mutations)
    ? observed.mutations.filter((entry) => entry?.phase === 'restoration')
    : [];
  if (!Array.isArray(observed.mutations)
      || workflowMutations.length !== expected.workflow_commands.length
      || restorationMutations.length !== 1
      || observed.mutations.at(-1)?.phase !== 'restoration'
      || observed.mutations.slice(0, -1).some((entry) => entry?.phase !== 'workflow')) {
    failures.push(failure('mutation_count', `Controller ${expected.id} did not complete enough mutations`, expected.id));
  } else {
    observed.mutations.forEach((entry, index) => (
      validateMutation(entry, expected.id, observed.target, cli, host, index + 1, failures)
    ));
    if (workflowMutations.some((entry, index) => entry.command !== expected.workflow_commands[index])
        || restorationMutations[0]?.command !== expected.restoration_command) {
      failures.push(failure(
        'mutation_sequence',
        `Controller ${expected.id} did not execute the exact catalog workflow`,
        expected.id,
      ));
    }
    if (observed.mutations.some((entry) => (
      entry.started_at < observed.started_at || entry.finished_at > observed.finished_at
    ))) {
      failures.push(failure('mutation_timing', `Controller ${expected.id} mutation escaped its interval`, expected.id));
    }
    const restorationMutation = restorationMutations[0];
    if (workflowMutations.some((entry, index) => (
      entry.finished_at > restorationMutation.started_at
        || (index > 0 && entry.started_at < workflowMutations[index - 1].finished_at)
    ))) {
      failures.push(failure('mutation_timing', `Controller ${expected.id} workflow is not ordered before restoration`, expected.id));
    }
  }
  if (!Array.isArray(observed.observations) || observed.observations.length - 1 < expected.minimum_observations) {
    failures.push(failure('observation_count', `Controller ${expected.id} did not complete enough observations`, expected.id));
  } else {
    observed.observations.forEach((entry, index) => (
      validateObservation(entry, expected.id, observed.target, cli, host, index + 1, failures)
    ));
    if (observed.observations.some((entry) => (
      entry.started_at < observed.started_at || entry.finished_at > observed.finished_at
    ))) {
      failures.push(failure('observation_timing', `Controller ${expected.id} observation escaped its interval`, expected.id));
    }
    const firstMutation = observed.mutations?.[0];
    const restorationMutation = observed.mutations?.at(-1);
    const finalWorkflowMutation = workflowMutations.at(-1);
    const initialReadback = observed.observations[0];
    const finalReadback = observed.observations.find((entry) => (
      entry.expected_token === observed.final_token
        && entry.token_present === true
        && entry.started_at >= (finalWorkflowMutation?.finished_at ?? Infinity)
        && entry.finished_at <= (restorationMutation?.started_at ?? -Infinity)
    ));
    const restorationReadback = observed.observations.at(-1);
    const workflowObservations = observed.observations.slice(0, -1);
    const observationsOrdered = workflowObservations.every((entry, index) => (
      entry.finished_at <= (restorationMutation?.started_at ?? -Infinity)
        && (index === 0 || entry.started_at >= workflowObservations[index - 1].finished_at)
    ));
    const sequenceBound = initialReadback?.expected_token === observed.initial_token
      && initialReadback?.token_present === true
      && initialReadback.finished_at <= (firstMutation?.started_at ?? -Infinity)
      && finalReadback !== undefined
      && restorationReadback?.expected_token === observed.initial_token
      && restorationReadback?.token_present === true
      && restorationReadback.started_at >= (restorationMutation?.finished_at ?? Infinity)
      && observationsOrdered;
    if (!sequenceBound) {
      failures.push(failure(
        'independent_readback',
        `Controller ${expected.id} readbacks are missing or out of mutation order`,
        expected.id,
      ));
    }
  }
}

function validateRestorationCheckpoints(report, failures) {
  const checkpoints = report.restoration_checkpoints;
  const [controllerA, controllerB] = report.controllers ?? [];
  if (!Array.isArray(checkpoints) || checkpoints.length !== 2
      || checkpoints.map((entry) => entry?.after_controller).join(',') !== 'A,B'
      || checkpoints.some((entry) => !exactKeys(entry, ['after_controller', 'observations'])
        || !Array.isArray(entry.observations) || entry.observations.length !== 2)) {
    failures.push(failure(
      'restoration_checkpoint_schema',
      'Restoration checkpoints must read both targets after exact ordered A and B restorations',
    ));
    return;
  }

  const restorationA = controllerA?.mutations?.at(-1);
  const restorationB = controllerB?.mutations?.at(-1);
  const expected = [
    {
      after: 'A',
      tokens: [controllerA?.initial_token, controllerB?.final_token],
      notBefore: restorationA?.finished_at,
      notAfter: restorationB?.started_at,
    },
    {
      after: 'B',
      tokens: [controllerA?.initial_token, controllerB?.initial_token],
      notBefore: restorationB?.finished_at,
      notAfter: Math.min(controllerA?.finished_at ?? -Infinity, controllerB?.finished_at ?? -Infinity),
    },
  ];
  if (restorationA?.phase !== 'restoration' || restorationB?.phase !== 'restoration'
      || !finiteTimestamp(restorationA.finished_at) || !finiteTimestamp(restorationB.started_at)
      || restorationA.finished_at > restorationB.started_at) {
    failures.push(failure(
      'restoration_checkpoint_timing',
      'Controller A restoration must finish and be audited before controller B restoration starts',
    ));
  }

  checkpoints.forEach((checkpoint, checkpointIndex) => {
    const requirement = expected[checkpointIndex];
    checkpoint.observations.forEach((observation, targetIndex) => {
      const targetController = [controllerA, controllerB][targetIndex];
      validateObservation(
        observation,
        `restoration-${requirement.after}`,
        targetController?.target ?? {},
        report.cli,
        report.host,
        targetIndex + 1,
        failures,
      );
      if (observation?.expected_token !== requirement.tokens[targetIndex]
          || observation?.token_present !== true || observation?.other_token_absent !== true) {
        failures.push(failure(
          'restoration_checkpoint_contract',
          `Checkpoint after controller ${requirement.after} did not preserve both exact target states`,
          requirement.after,
        ));
      }
    });
    const [first, second] = checkpoint.observations;
    if (!finiteTimestamp(requirement.notBefore) || !finiteTimestamp(requirement.notAfter)
        || requirement.notAfter < requirement.notBefore
        || checkpoint.observations.some((observation) => (
          !finiteTimestamp(observation?.started_at) || !finiteTimestamp(observation?.finished_at)
            || observation.started_at < requirement.notBefore
            || observation.finished_at > requirement.notAfter
        )) || first.finished_at > second.started_at) {
      failures.push(failure(
        'restoration_checkpoint_timing',
        `Checkpoint after controller ${requirement.after} was not durably captured before the next state change`,
        requirement.after,
      ));
    }
  });
}

export function validateOverlapCertification(catalog, report, expectedCatalogSHA256 = null) {
  const failures = validateCatalog(catalog);
  if (!exactKeys(report, [
    'version', 'catalog_sha256', 'run_id', 'source_commit', 'cli', 'host', 'sentinel',
    'controllers', 'overlap', 'invariants', 'cursor_observation', 'restoration',
    'restoration_checkpoints', 'cleanup', 'evidence',
  ]) || report?.version !== 1) {
    failures.push(failure('report_schema', 'Report must be one closed version-1 object'));
    return { success: false, failures };
  }
  if (!hex64.test(report.catalog_sha256 ?? '')
      || (expectedCatalogSHA256 !== null && report.catalog_sha256 !== expectedCatalogSHA256)) {
    failures.push(failure('catalog_hash', 'Report is not bound to the exact catalog bytes'));
  }
  if (typeof report.run_id !== 'string' || !/^overlap-[0-9a-f-]{36}$/.test(report.run_id)) {
    failures.push(failure('run_id', 'Run ID must be one exact overlap UUID'));
  }
  if (!hex40.test(report.source_commit ?? '')) {
    failures.push(failure('source_commit', 'Source commit must be canonical 40-hex'));
  }
  validateHost(report, failures);
  validateCLI(report, failures);

  const sentinel = report.sentinel;
  if (!exactKeys(sentinel, [
    'pid', 'start_identity', 'window_id', 'initial_frontmost_pid', 'initial_top_window_id',
    'final_frontmost_pid', 'final_top_window_id',
  ]) || !validTargetFields(sentinel)
      || sentinel.initial_frontmost_pid !== sentinel.pid
      || sentinel.initial_top_window_id !== sentinel.window_id
      || sentinel.final_frontmost_pid !== sentinel.pid
      || sentinel.final_top_window_id !== sentinel.window_id) {
    failures.push(failure('sentinel_receipt', 'Sentinel did not retain exact frontmost and top-window identity'));
  }

  if (!Array.isArray(report.controllers) || report.controllers.length !== catalog.controllers.length
      || report.controllers.map((entry) => entry?.id).join(',') !== 'A,B') {
    failures.push(failure('controllers', 'Report must contain exact ordered A and B controller rows'));
  } else {
    const generationKey = (receipt) => `${receipt?.pid}:${receipt?.start_identity}`;
    const wrapperGenerations = report.controllers.map((entry) => generationKey(entry.controller_process));
    const operationGenerations = report.controllers.flatMap((entry) => [
      ...(entry.mutations ?? []).map((operation) => (
        `${operation.client_pid}:${operation.client_start_identity}`
      )),
      ...(entry.observations ?? []).flatMap((operation) => [
        `${operation.client_pid}:${operation.client_start_identity}`,
        `${operation.route_receipt?.client_pid}:${operation.route_receipt?.client_start_identity}`,
      ]),
    ]);
    const checkpointGenerations = (Array.isArray(report.restoration_checkpoints)
      ? report.restoration_checkpoints : []).flatMap((checkpoint) => (
      Array.isArray(checkpoint?.observations) ? checkpoint.observations : []
    )).flatMap((operation) => [
      `${operation?.client_pid}:${operation?.client_start_identity}`,
      `${operation?.route_receipt?.client_pid}:${operation?.route_receipt?.client_start_identity}`,
    ]);
    const allClientGenerations = [
      ...wrapperGenerations, ...operationGenerations, ...checkpointGenerations,
    ];
    if (new Set(allClientGenerations).size !== allClientGenerations.length) {
      failures.push(failure('client_isolation', 'Controllers and operations must use distinct process generations'));
    }
    validateController(
      report.controllers[0], catalog.controllers[0], report.controllers[1], report.run_id,
      report.cli, report.host, failures,
    );
    validateController(
      report.controllers[1], catalog.controllers[1], report.controllers[0], report.run_id,
      report.cli, report.host, failures,
    );
  }

  const [controllerA, controllerB] = report.controllers ?? [];
  validateRestorationCheckpoints(report, failures);
  const workflowMutationsA = (controllerA?.mutations ?? []).filter((entry) => entry?.phase === 'workflow');
  const workflowMutationsB = (controllerB?.mutations ?? []).filter((entry) => entry?.phase === 'workflow');
  const overlap = report.overlap;
  const calculatedPairs = [];
  for (const aMutation of workflowMutationsA) {
    for (const bMutation of workflowMutationsB) {
      const startedAt = Math.max(aMutation.started_at, bMutation.started_at);
      const finishedAt = Math.min(aMutation.finished_at, bMutation.finished_at);
      if (finishedAt > startedAt) {
        calculatedPairs.push({
          a_index: aMutation.index,
          b_index: bMutation.index,
          a_client_pid: aMutation.client_pid,
          a_client_start_identity: aMutation.client_start_identity,
          b_client_pid: bMutation.client_pid,
          b_client_start_identity: bMutation.client_start_identity,
          started_at: startedAt,
          finished_at: finishedAt,
          seconds: finishedAt - startedAt,
        });
      }
    }
  }
  const calculatedStart = Math.min(...calculatedPairs.map((pair) => pair.started_at));
  const calculatedEnd = Math.max(...calculatedPairs.map((pair) => pair.finished_at));
  const calculatedSeconds = calculatedPairs.reduce((total, pair) => total + pair.seconds, 0);
  const calculatedAMutations = new Set(calculatedPairs.map((pair) => pair.a_index)).size;
  const calculatedBMutations = new Set(calculatedPairs.map((pair) => pair.b_index)).size;
  const witness = overlap?.simultaneous_liveness_witness;
  const validActiveMarker = (marker, controller, pid, identity) => exactKeys(marker, [
    'controller', 'index', 'phase', 'pid', 'start_identity',
  ]) && marker.controller === controller
    && positiveInteger(marker.index)
    && marker.phase === 'workflow'
    && marker.pid === pid
    && marker.start_identity === identity;
  if (!exactKeys(overlap, [
    'started_at', 'finished_at', 'seconds', 'a_mutations_during_b', 'b_mutations_during_a',
    'concurrent_mutation_pairs', 'simultaneous_liveness_witness',
  ]) || overlap.started_at !== calculatedStart || overlap.finished_at !== calculatedEnd
      || Math.abs(overlap.seconds - calculatedSeconds) > 0.000_001
      || overlap.seconds <= 0
      || overlap.a_mutations_during_b !== calculatedAMutations
      || overlap.b_mutations_during_a !== calculatedBMutations
      || !positiveInteger(calculatedAMutations)
      || !positiveInteger(calculatedBMutations)
      || !Array.isArray(overlap.concurrent_mutation_pairs)
      || overlap.concurrent_mutation_pairs.length === 0
      || JSON.stringify(overlap.concurrent_mutation_pairs) !== JSON.stringify(calculatedPairs)
      || !exactKeys(witness, [
        'a_pid', 'a_start_identity', 'b_pid', 'b_start_identity',
        'a_checked_before_at', 'b_checked_at', 'a_checked_after_at', 'observed_at',
        'a_active_marker', 'b_active_marker', 'markers_unchanged',
      ])
      || !validActiveMarker(witness?.a_active_marker, 'A', witness?.a_pid, witness?.a_start_identity)
      || !validActiveMarker(witness?.b_active_marker, 'B', witness?.b_pid, witness?.b_start_identity)
      || witness?.markers_unchanged !== true
      || ![witness?.a_checked_before_at, witness?.b_checked_at, witness?.a_checked_after_at]
        .every((value) => typeof value === 'number' && Number.isFinite(value))
      || witness?.a_checked_before_at > witness?.b_checked_at
      || witness?.b_checked_at > witness?.a_checked_after_at
      || witness?.observed_at !== witness?.b_checked_at
      || !calculatedPairs.some((pair) => (
        pair.a_client_pid === witness.a_pid
          && pair.a_client_start_identity === witness.a_start_identity
          && pair.b_client_pid === witness.b_pid
          && pair.b_client_start_identity === witness.b_start_identity
          && pair.a_index === witness.a_active_marker.index
          && pair.b_index === witness.b_active_marker.index
          && witness.a_checked_before_at >= pair.started_at
          && witness.a_checked_after_at <= pair.finished_at
      ))) {
    failures.push(failure('overlap', 'Controller intervals do not prove real bidirectional overlap'));
  }

  if (!Array.isArray(report.invariants) || report.invariants.length !== catalog.invariants.length
      || report.invariants.map((entry) => entry?.name).join(',') !== catalog.invariants.join(',')) {
    failures.push(failure('invariant_schema', 'Invariant results must exactly match catalog order'));
  } else {
    for (const invariant of report.invariants) {
      if (!exactKeys(invariant, ['name', 'passed', 'evidence'])
          || invariant.passed !== true
          || typeof invariant.evidence !== 'string' || invariant.evidence.length === 0) {
        failures.push(failure('invariant_failed', `Invariant '${invariant?.name ?? 'unknown'}' did not pass`));
      }
    }
  }

  const cursor = report.cursor_observation;
  if (!exactKeys(cursor, ['policy', 'start_x', 'start_y', 'end_x', 'end_y', 'moved'])
      || cursor.policy !== 'observational'
      || [cursor.start_x, cursor.start_y, cursor.end_x, cursor.end_y].some((value) => (
        typeof value !== 'number' || !Number.isFinite(value)
      )) || typeof cursor.moved !== 'boolean') {
    failures.push(failure('cursor_observation', 'Cursor evidence must be observational and well formed'));
  }

  if (!exactKeys(report.restoration, ['controller_a', 'controller_b', 'sentinel'])
      || Object.values(report.restoration).some((value) => value !== true)) {
    failures.push(failure('restoration', 'Target and sentinel restoration did not complete'));
  }
  if (!Array.isArray(report.cleanup) || report.cleanup.length !== 2
      || report.cleanup.map((entry) => entry?.id).join(',') !== 'A,B'
      || report.cleanup.some((entry, index) => !exactKeys(
        entry,
        ['id', 'pid', 'start_identity', 'gone'],
      ) || entry.id !== ['A', 'B'][index]
        || entry.pid !== report.controllers?.[index]?.target?.pid
        || entry.start_identity !== report.controllers?.[index]?.target?.start_identity
        || entry.gone !== true)) {
    failures.push(failure('cleanup', 'Cleanup must remove exactly the two owned target generations'));
  }
  if (!exactKeys(report.evidence, Object.keys(Object.fromEntries(
    catalog.required_evidence.map((name) => [name, true]),
  ))) || catalog.required_evidence.some((name) => report.evidence[name] !== true)) {
    failures.push(failure('evidence', 'Every catalog evidence family must pass'));
  }
  return { success: failures.length === 0, failures };
}

export function makePassingOverlapReport(catalog, catalogSHA256 = 'f'.repeat(64)) {
  const runID = 'overlap-01234567-89ab-cdef-0123-456789abcdef';
  const target = (pid, startIdentity, windowID) => ({
    pid,
    start_identity: startIdentity,
    window_id: windowID,
  });
  const mutation = (index, command, phase, startedAt, targetReceipt) => ({
    index,
    command,
    phase,
    started_at: startedAt,
    finished_at: startedAt + 0.2,
    target_pid: targetReceipt.pid,
    target_window_id: targetReceipt.window_id,
    client_pid: targetReceipt.pid + 1000 + index,
    client_start_identity: `${targetReceipt.pid + 1000 + index}00`,
    client_executable_path: '/artifacts/bin/peekaboo-certified',
    host_pid: 401,
    host_start_identity: '40100',
    host_code_signature_hash: 'a'.repeat(40),
    reported_target_pid: targetReceipt.pid,
    reported_target_window_id: targetReceipt.window_id,
    target_start_identity_after: targetReceipt.start_identity,
    delivery_mode: 'background',
    success: true,
    effect: 'confirmed',
    mutation_dispatched: true,
    retry_safe: false,
    foreground: false,
  });
  const observation = (index, startedAt, token, targetReceipt) => ({
    index,
    started_at: startedAt,
    finished_at: startedAt + 0.1,
    target_pid: targetReceipt.pid,
    target_window_id: targetReceipt.window_id,
    client_pid: targetReceipt.pid + 2000 + index,
    client_start_identity: `${targetReceipt.pid + 2000 + index}00`,
    client_executable_path: '/artifacts/bin/peekaboo-certified',
    host_pid: 401,
    host_start_identity: '40100',
    host_code_signature_hash: 'a'.repeat(40),
    result_success: true,
    reported_window_id: targetReceipt.window_id,
    target_start_identity_after: targetReceipt.start_identity,
    route_receipt: {
      client_pid: targetReceipt.pid + 3000 + index,
      client_start_identity: `${targetReceipt.pid + 3000 + index}00`,
      client_executable_path: '/artifacts/bin/peekaboo-certified',
      host_pid: 401,
      host_start_identity: '40100',
      host_code_signature_hash: 'a'.repeat(40),
      reported_target_pid: targetReceipt.pid,
      reported_window_id: targetReceipt.window_id,
      target_start_identity_after: targetReceipt.start_identity,
      result_success: true,
    },
    expected_token: token,
    token_present: true,
    other_token_absent: true,
  });
  const checkpointObservation = (index, startedAt, token, targetReceipt, generationSeed) => {
    const receipt = observation(index, startedAt, token, targetReceipt);
    receipt.client_pid = 6000 + generationSeed;
    receipt.client_start_identity = `${receipt.client_pid}00`;
    receipt.route_receipt.client_pid = 7000 + generationSeed;
    receipt.route_receipt.client_start_identity = `${receipt.route_receipt.client_pid}00`;
    return receipt;
  };
  const controller = (expected, clientPID, targetReceipt, startedAt, finishedAt, observationCount) => {
    const { id } = expected;
    const namespace = `${runID}-${id.toLowerCase()}-`;
    const initial = `${namespace}initial`;
    const final = `${namespace}final`;
    const mutationCommands = [...expected.workflow_commands, expected.restoration_command];
    const mutations = mutationCommands.map((command, index) => (
      mutation(
        index + 1,
        command,
        index === mutationCommands.length - 1 ? 'restoration' : 'workflow',
        startedAt + 0.2 + index * 0.5,
        targetReceipt,
      )
    ));
    const restorationMutation = mutations.at(-1);
    const finalWorkflowMutation = mutations.at(-2);
    const observations = [observation(1, startedAt + 0.05, initial, targetReceipt)];
    for (let index = 0; index < observationCount - 3; index += 1) {
      observations.push(observation(
        observations.length + 1,
        mutations[0].finished_at + 0.05 + index * 0.1,
        `${namespace}checkpoint-${index + 1}`,
        targetReceipt,
      ));
    }
    observations.push(observation(
      observations.length + 1,
      finalWorkflowMutation.finished_at + 0.05,
      final,
      targetReceipt,
    ));
    observations.push(observation(
      observations.length + 1,
      restorationMutation.finished_at + 0.05,
      initial,
      targetReceipt,
    ));
    return {
      id,
      controller_process: { pid: clientPID, start_identity: `${clientPID}00` },
      target: targetReceipt,
      started_at: startedAt,
      finished_at: finishedAt,
      mutations,
      observations,
      initial_token: initial,
      final_token: final,
      readback_token: final,
      restored_token: initial,
      restoration_readback: initial,
      cross_target_clear: true,
    };
  };
  const controllerA = controller(catalog.controllers[0], 301, target(101, '10100', 201), 10, 15, 4);
  const controllerB = controller(catalog.controllers[1], 302, target(202, '20200', 302), 9, 16, 5);
  const restorationA = controllerA.mutations.at(-1);
  const restorationB = controllerB.mutations.at(-1);
  restorationB.started_at = 12.5;
  restorationB.finished_at = 12.7;
  controllerA.observations.at(-1).started_at = 13.2;
  controllerA.observations.at(-1).finished_at = 13.3;
  controllerB.observations.at(-1).started_at = 13.35;
  controllerB.observations.at(-1).finished_at = 13.45;
  const restorationCheckpoints = [
    {
      after_controller: 'A',
      observations: [
        checkpointObservation(1, restorationA.finished_at + 0.2, controllerA.initial_token, controllerA.target, 1),
        checkpointObservation(2, restorationA.finished_at + 0.35, controllerB.final_token, controllerB.target, 2),
      ],
    },
    {
      after_controller: 'B',
      observations: [
        checkpointObservation(1, restorationB.finished_at + 0.1, controllerA.initial_token, controllerA.target, 3),
        checkpointObservation(2, restorationB.finished_at + 0.25, controllerB.initial_token, controllerB.target, 4),
      ],
    },
  ];
  return {
    version: 1,
    catalog_sha256: catalogSHA256,
    run_id: runID,
    source_commit: '0123456789abcdef0123456789abcdef01234567',
    cli: {
      source_commit: '0123456789abcdef0123456789abcdef01234567',
      code_signature_hash: 'd'.repeat(40),
      executable_sha256: 'c'.repeat(64),
      executable_path: '/artifacts/bin/peekaboo-certified',
    },
    host: {
      pid: 401,
      start_identity: '40100',
      socket_path: '/tmp/peekaboo-overlap/bridge.sock',
      source_commit: '0123456789abcdef0123456789abcdef01234567',
      code_signature_hash: 'a'.repeat(40),
      protocol_major: 1,
      protocol_minor: 25,
      executable_sha256: 'b'.repeat(64),
      stable: true,
    },
    sentinel: {
      ...target(501, '50100', 601),
      initial_frontmost_pid: 501,
      initial_top_window_id: 601,
      final_frontmost_pid: 501,
      final_top_window_id: 601,
    },
    controllers: [controllerA, controllerB],
    overlap: {
      started_at: 10.2,
      finished_at: 10.899999999999999,
      seconds: 0.3999999999999986,
      a_mutations_during_b: 2,
      b_mutations_during_a: 2,
      concurrent_mutation_pairs: [
        {
          a_index: 1,
          b_index: 3,
          a_client_pid: 1102,
          a_client_start_identity: '110200',
          b_client_pid: 1205,
          b_client_start_identity: '120500',
          started_at: 10.2,
          finished_at: 10.399999999999999,
          seconds: 0.1999999999999993,
        },
        {
          a_index: 2,
          b_index: 4,
          a_client_pid: 1103,
          a_client_start_identity: '110300',
          b_client_pid: 1206,
          b_client_start_identity: '120600',
          started_at: 10.7,
          finished_at: 10.899999999999999,
          seconds: 0.1999999999999993,
        },
      ],
      simultaneous_liveness_witness: {
        a_pid: 1102,
        a_start_identity: '110200',
        b_pid: 1205,
        b_start_identity: '120500',
        a_checked_before_at: 10.25,
        b_checked_at: 10.3,
        a_checked_after_at: 10.35,
        observed_at: 10.3,
        a_active_marker: {
          controller: 'A', index: 1, phase: 'workflow', pid: 1102, start_identity: '110200',
        },
        b_active_marker: {
          controller: 'B', index: 3, phase: 'workflow', pid: 1205, start_identity: '120500',
        },
        markers_unchanged: true,
      },
    },
    invariants: catalog.invariants.map((name) => ({ name, passed: true, evidence: `${name}.json` })),
    cursor_observation: {
      policy: 'observational', start_x: 20, start_y: 30, end_x: 40, end_y: 50, moved: true,
    },
    restoration: { controller_a: true, controller_b: true, sentinel: true },
    restoration_checkpoints: restorationCheckpoints,
    cleanup: [
      { id: 'A', pid: 101, start_identity: '10100', gone: true },
      { id: 'B', pid: 202, start_identity: '20200', gone: true },
    ],
    evidence: Object.fromEntries(catalog.required_evidence.map((name) => [name, true])),
  };
}

export function runOverlapContractSelfTest(catalog, catalogSHA256) {
  const passing = makePassingOverlapReport(catalog, catalogSHA256);
  assert.equal(validateOverlapCertification(catalog, passing, catalogSHA256).success, true);
  const corruptions = [
    ['missing controller', (report) => report.controllers.pop(), 'controllers'],
    ['reused target', (report) => { report.controllers[1].target.pid = report.controllers[0].target.pid; }, 'target_isolation'],
    ['reused controller generation', (report) => {
      report.controllers[1].controller_process = structuredClone(report.controllers[0].controller_process);
    }, 'client_isolation'],
    ['serialized intervals', (report) => {
      report.controllers[1].mutations.filter((entry) => entry.phase === 'workflow').forEach((entry) => {
        entry.started_at += 20;
        entry.finished_at += 20;
      });
    }, 'overlap'],
    ['foreground mutation', (report) => { report.controllers[0].mutations[0].foreground = true; }, 'mutation_contract'],
    ['false target receipt', (report) => { report.controllers[0].mutations[0].reported_target_pid = 102; }, 'mutation_contract'],
    ['cross target leak', (report) => { report.controllers[0].cross_target_clear = false; }, 'controller_schema'],
    ['host restart', (report) => { report.host.stable = false; }, 'host_receipt'],
    ['sentinel focus theft', (report) => { report.sentinel.final_frontmost_pid = 999; }, 'sentinel_receipt'],
    ['global input', (report) => { report.invariants[4].passed = false; }, 'invariant_failed'],
    ['clipboard drift', (report) => { report.invariants[5].passed = false; }, 'invariant_failed'],
    ['overlay leak', (report) => { report.invariants[6].passed = false; }, 'invariant_failed'],
    ['cursor made strict', (report) => { report.cursor_observation.policy = 'unchanged'; }, 'cursor_observation'],
    ['bare cleanup pid', (report) => { report.cleanup[0].start_identity = ''; }, 'cleanup'],
    ['unknown report key', (report) => { report.ignored = true; }, 'report_schema'],
    ['catalog mismatch', (report) => { report.catalog_sha256 = '0'.repeat(64); }, 'catalog_hash'],
    ['no concurrent commands', (report) => { report.overlap.concurrent_mutation_pairs = []; }, 'overlap'],
    ['changed active marker', (report) => {
      report.overlap.simultaneous_liveness_witness.markers_unchanged = false;
    }, 'overlap'],
    ['missing restoration checkpoint', (report) => {
      report.restoration_checkpoints.pop();
    }, 'restoration_checkpoint_schema'],
    ['masked cross-target restoration', (report) => {
      report.restoration_checkpoints[0].observations[1].token_present = false;
    }, 'restoration_checkpoint_contract'],
    ['masked peer cross-target restoration', (report) => {
      report.restoration_checkpoints[1].observations[0].token_present = false;
    }, 'restoration_checkpoint_contract'],
    ['concurrent peer restoration', (report) => {
      const checkpoint = report.restoration_checkpoints[0].observations[1];
      const restoration = report.controllers[1].mutations.at(-1);
      restoration.started_at = checkpoint.finished_at - 0.05;
      restoration.finished_at = restoration.started_at + 0.2;
    }, 'restoration_checkpoint_timing'],
    ['restoration counted as workflow', (report) => { report.controllers[0].mutations.splice(1, 1); }, 'mutation_count'],
    ['workflow command drift', (report) => { report.controllers[0].mutations[1].command = 'type'; }, 'mutation_sequence'],
  ];
  for (const [name, mutate, expectedRule] of corruptions) {
    const report = structuredClone(passing);
    mutate(report);
    const result = validateOverlapCertification(catalog, report, catalogSHA256);
    assert.equal(result.success, false, name);
    assert.ok(result.failures.some((entry) => entry.rule === expectedRule), name);
  }
  return { success: true, tests: corruptions.length + 1 };
}

function parseArguments(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === '--self-test') result.selfTest = true;
    else if (['--catalog', '--report', '--output'].includes(value) && argv[index + 1]) {
      result[value.slice(2)] = argv[index + 1];
      index += 1;
    } else throw new Error(`Unknown or incomplete argument: ${value}`);
  }
  return result;
}

function runCLI() {
  const args = parseArguments(process.argv.slice(2));
  if (args.selfTest) {
    if (!args.catalog) throw new Error('--catalog is required with --self-test');
    const catalogBytes = fs.readFileSync(args.catalog);
    const catalog = JSON.parse(catalogBytes);
    const catalogSHA256 = createHash('sha256').update(catalogBytes).digest('hex');
    process.stdout.write(`${JSON.stringify(runOverlapContractSelfTest(catalog, catalogSHA256))}\n`);
    return;
  }
  if (!args.catalog || !args.report) throw new Error('--catalog and --report are required');
  const catalogBytes = fs.readFileSync(args.catalog);
  const catalog = JSON.parse(catalogBytes);
  const report = JSON.parse(fs.readFileSync(args.report, 'utf8'));
  const catalogSHA256 = createHash('sha256').update(catalogBytes).digest('hex');
  const result = validateOverlapCertification(catalog, report, catalogSHA256);
  const output = `${JSON.stringify(result, null, 2)}\n`;
  if (args.output) fs.writeFileSync(args.output, output);
  else process.stdout.write(output);
  if (!result.success) process.exitCode = 1;
}

const invokedAsScript = process.argv[1]
  && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedAsScript) {
  try {
    runCLI();
  } catch (error) {
    process.stderr.write(`dual-controller overlap reporter: ${error.message}\n`);
    process.exitCode = 2;
  }
}
