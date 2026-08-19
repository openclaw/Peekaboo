#!/usr/bin/env node

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  HEX40,
  TEAM_ID,
  exactKeys,
  parseCodesignReceipt,
  parseOptions,
  positiveDecimal,
  positiveInteger,
  readCalibrationEmitter,
  readStableJSON,
  requireCondition,
  requirePrivateDirectory,
  requireStableExecutable,
  sameJSON,
  sha256,
  validateBounds,
  writePrivateExclusive,
} from './lib.mjs';

function processIdentity(filePath, label) {
  const receipt = readStableJSON(filePath, label).value;
  exactKeys(receipt, ['pid', 'startIdentity'], label);
  requireCondition(positiveInteger(receipt.pid) && positiveDecimal(receipt.startIdentity), `${label} is malformed`);
  return { pid: receipt.pid, start_identity: receipt.startIdentity };
}

function exactWindow(filePath, process, label) {
  const receipt = readStableJSON(filePath, label).value;
  requireCondition(receipt.success === true, `${label} did not succeed`);
  requireCondition(receipt.data && typeof receipt.data === 'object', `${label}.data is missing`);
  requireCondition(receipt.data.inventory_completeness === 'complete'
    && Array.isArray(receipt.data.inventory_warnings)
    && receipt.data.inventory_warnings.length === 0,
  `${label} is not one complete, omission-free window inventory`);
  const windows = receipt.data.windows;
  requireCondition(Array.isArray(windows) && windows.length === 1, `${label} must contain exactly one window`);
  requireCondition(receipt.data.target_application_info?.pid === process.pid, `${label} target PID differs from its process receipt`);
  const window = windows[0];
  requireCondition(window && typeof window === 'object' && !Array.isArray(window), `${label} window is malformed`);
  requireCondition(positiveInteger(window.window_id) && window.window_id <= 0xffff_ffff, `${label} window ID is invalid`);
  requireCondition(window.is_on_screen === true && (window.layer === 0 || window.layer === undefined), `${label} window is not one visible layer-zero target`);
  validateBounds(window.bounds, `${label}.data.windows[0].bounds`);
  return {
    scope: 'window',
    pid: process.pid,
    start_identity: process.start_identity,
    window_id: window.window_id,
    bounds: structuredClone(window.bounds),
    is_minimized: false,
  };
}

function targetFromReceipts(value, label) {
  exactKeys(value, ['process_identity', 'window_inventory'], label);
  const process = processIdentity(value.process_identity, `${label}.process_identity`);
  return exactWindow(value.window_inventory, process, `${label}.window_inventory`);
}

function semanticReceipt(filePath, observerTarget) {
  const label = 'receipts.observer_semantic';
  const receipt = readStableJSON(filePath, label).value;
  exactKeys(receipt, ['version', 'target', 'focused_element', 'baseline_value'], label);
  requireCondition(receipt.version === 1, `${label} version is not 1`);
  exactKeys(receipt.target, ['pid', 'start_identity', 'window_id'], `${label}.target`);
  requireCondition(sameJSON(receipt.target, {
    pid: observerTarget.pid,
    start_identity: observerTarget.start_identity,
    window_id: observerTarget.window_id,
  }), `${label} target differs from the observer receipts`);
  exactKeys(receipt.focused_element, ['role', 'identifier', 'title', 'frame'], `${label}.focused_element`);
  const element = receipt.focused_element;
  const semanticString = (value) => value === null || (
    typeof value === 'string' && value.length > 0 && !value.includes('\0') && Buffer.byteLength(value) <= 1024
  );
  requireCondition(typeof element.role === 'string' && element.role.length > 0 && !element.role.includes('\0'), `${label} role is invalid`);
  requireCondition(semanticString(element.identifier) && semanticString(element.title), `${label} identifier/title is invalid`);
  requireCondition(element.identifier !== null || element.title !== null, `${label} needs an identifier or title`);
  validateBounds(element.frame, `${label}.focused_element.frame`);
  const bounds = observerTarget.bounds;
  requireCondition(
    element.frame.x >= bounds.x && element.frame.y >= bounds.y
      && element.frame.x + element.frame.width <= bounds.x + bounds.width
      && element.frame.y + element.frame.height <= bounds.y + bounds.height,
    `${label} element frame is outside the observer window`,
  );
  requireCondition(
    typeof receipt.baseline_value === 'string' && receipt.baseline_value.length > 0
      && Buffer.byteLength(receipt.baseline_value) <= 4096,
    `${label} baseline is invalid`,
  );
  return {
    semantic_element: { role: element.role, identifier: element.identifier, title: element.title },
    baseline_value: receipt.baseline_value,
  };
}

function bridgeReceipt(filePath, catalog) {
  const label = 'receipts.bridge_status';
  const report = readStableJSON(filePath, label).value;
  requireCondition(report.success === true, `${label} did not succeed`);
  const selected = report.data?.selected;
  requireCondition(selected?.source === 'remote' && path.isAbsolute(selected.socketPath), `${label} did not select one remote socket`);
  const handshake = selected.handshake;
  const identity = handshake?.hostIdentity;
  requireCondition(['gui', 'daemon'].includes(handshake?.hostKind), `${label} host kind is invalid`);
  exactKeys(handshake?.negotiatedVersion, ['major', 'minor'], `${label} negotiatedVersion`);
  requireCondition(handshake.negotiatedVersion.major === 1
    && handshake.negotiatedVersion.minor === 31, `${label} must be protocol 1.31`);
  requireCondition(identity && positiveInteger(identity.processIdentifier), `${label} host PID is invalid`);
  const start = identity.processStartIdentityDecimal;
  requireCondition(positiveDecimal(start), `${label} host generation is not lossless decimal`);
  requireCondition(HEX40.test(identity.codeSignatureHash ?? '') && HEX40.test(identity.sourceCommit ?? ''), `${label} host build identity is incomplete`);
  return {
    socket_path: selected.socketPath,
    trusted_host_team_ids: structuredClone(catalog.trusted_bridge_host_team_ids),
    expected_host: {
      host_kind: handshake.hostKind,
      process_identifier: identity.processIdentifier,
      process_start_identity_decimal: start,
      code_signature_hash: identity.codeSignatureHash,
      source_commit: identity.sourceCommit,
    },
  };
}

function catalogReceipt(filePath) {
  const catalog = readStableJSON(filePath, 'paths.catalog', { privateFile: false }).value;
  for (const key of ['trusted_bridge_host_team_ids', 'trusted_monitor_team_ids', 'controlled_target_ids']) {
    requireCondition(Array.isArray(catalog[key]) && catalog[key].length > 0, `catalog ${key} is missing`);
  }
  requireCondition(
    catalog.trusted_bridge_host_team_ids.every((value) => TEAM_ID.test(value))
      && catalog.trusted_monitor_team_ids.every((value) => TEAM_ID.test(value)),
    'catalog trust IDs are invalid',
  );
  requireCondition(sameJSON(catalog.controlled_target_ids, ['target-a', 'target-b']), 'catalog controlled targets are not canonical');
  return catalog;
}

export function projectBindings(specPath, outputPath) {
  const spec = readStableJSON(specPath, 'projection input').value;
  exactKeys(spec, ['version', 'paths', 'receipts', 'timeouts'], 'projection input');
  requireCondition(spec.version === 1, 'projection input version is not 1');
  exactKeys(spec.paths, [
    'catalog', 'runs_directory', 'peekaboo_executable', 'controller_executable',
    'monitor_executable', 'crash_directory',
  ], 'paths');
  exactKeys(spec.receipts, [
    'bridge_status', 'controller_a', 'controller_b', 'observer', 'sentinel',
    'observer_semantic', 'integrated_cu_emitter', 'monitor_codesign',
  ], 'receipts');
  exactKeys(spec.timeouts, [
    'external_foreground_timeout_seconds', 'operation_timeout_seconds', 'monitor_interval_milliseconds',
  ], 'timeouts');

  const catalog = catalogReceipt(spec.paths.catalog);
  requirePrivateDirectory(spec.paths.runs_directory, 'paths.runs_directory', { empty: true });
  requireStableExecutable(spec.paths.peekaboo_executable, 'paths.peekaboo_executable');
  requireStableExecutable(spec.paths.controller_executable, 'paths.controller_executable');
  requireStableExecutable(spec.paths.monitor_executable, 'paths.monitor_executable');
  const canonicalCrashDirectory = path.join(os.homedir(), 'Library', 'Logs', 'DiagnosticReports');
  requireCondition(spec.paths.crash_directory === canonicalCrashDirectory, 'crash_directory is not the canonical current-user path');
  const crashDirectoryInfo = fs.lstatSync(spec.paths.crash_directory);
  requireCondition(crashDirectoryInfo.isDirectory()
    && crashDirectoryInfo.uid === process.geteuid()
    && fs.realpathSync(spec.paths.crash_directory) === spec.paths.crash_directory,
  'paths.crash_directory must be one canonical current-user-owned directory');

  const monitorSignature = parseCodesignReceipt(spec.receipts.monitor_codesign, 'receipts.monitor_codesign');
  requireCondition(fs.realpathSync(monitorSignature.executable) === spec.paths.monitor_executable, 'monitor codesign receipt names another executable');
  requireCondition(catalog.trusted_monitor_team_ids.includes(monitorSignature.team_id), 'monitor Team ID is not source-trusted');

  const controllerA = targetFromReceipts(spec.receipts.controller_a, 'receipts.controller_a');
  const controllerB = targetFromReceipts(spec.receipts.controller_b, 'receipts.controller_b');
  const observerTarget = targetFromReceipts(spec.receipts.observer, 'receipts.observer');
  const sentinelTarget = targetFromReceipts(spec.receipts.sentinel, 'receipts.sentinel');
  const physicalProcesses = [controllerA, controllerB, observerTarget, sentinelTarget]
    .map((target) => `${target.pid}:${target.start_identity}`);
  requireCondition(new Set(physicalProcesses).size === 4, 'controller, observer, and sentinel generations must be distinct');
  requireCondition(new Set([controllerA, controllerB].map((target) => `${target.pid}:${target.start_identity}:${target.window_id}`)).size === 2, 'controller windows must be distinct');
  const semantic = semanticReceipt(spec.receipts.observer_semantic, observerTarget);
  requireCondition(typeof spec.receipts.integrated_cu_emitter === 'string', 'integrated-CU emitter receipt path is invalid');
  const emitter = readCalibrationEmitter(
    spec.receipts.integrated_cu_emitter,
    observerTarget,
  ).emitter;
  const bridge = bridgeReceipt(spec.receipts.bridge_status, catalog);
  requireCondition(
    ![bridge.expected_host.process_identifier, controllerA.pid, controllerB.pid].includes(emitter.pid),
    'integrated-CU emitter must differ from Bridge and controller owners',
  );

  const externalTimeout = spec.timeouts.external_foreground_timeout_seconds;
  const operationTimeout = spec.timeouts.operation_timeout_seconds;
  const interval = spec.timeouts.monitor_interval_milliseconds;
  requireCondition(Number.isSafeInteger(externalTimeout) && externalTimeout >= 5 && externalTimeout <= 150, 'external foreground timeout is invalid');
  requireCondition(Number.isSafeInteger(operationTimeout) && operationTimeout > 0 && operationTimeout <= 3600, 'operation timeout is invalid');
  const constructorMinimum = (3 * externalTimeout) + 50;
  const coordinatorMinimum = (2 * externalTimeout) + 80;
  requireCondition(operationTimeout >= Math.max(constructorMinimum, coordinatorMinimum),
    'operation timeout does not cover controller typing, both windows, and lifecycle margin');
  requireCondition(Number.isSafeInteger(interval) && interval >= 5 && interval <= 100, 'monitor interval is invalid');

  const controllerPlan = (target, index) => ({
    controller_id: `controller-${index === 0 ? 'a' : 'b'}`,
    target_id: `target-${index === 0 ? 'a' : 'b'}`,
    target: {
      process_identifier: target.pid,
      process_start_identity_decimal: target.start_identity,
      window_id: target.window_id,
      bounds: structuredClone(target.bounds),
      is_minimized: false,
      click_point: {
        x: target.bounds.x + (target.bounds.width / 2),
        y: target.bounds.y + (target.bounds.height / 2),
      },
    },
  });
  const bindings = {
    runs_directory: spec.paths.runs_directory,
    peekaboo_executable: spec.paths.peekaboo_executable,
    controller_executable: spec.paths.controller_executable,
    monitor_executable: spec.paths.monitor_executable,
    bridge,
    controllers: [controllerPlan(controllerA, 0), controllerPlan(controllerB, 1)],
    observer: {
      target: observerTarget,
      semantic_element: semantic.semantic_element,
      baseline_value: semantic.baseline_value,
    },
    monitor: {
      sentinel: sentinelTarget,
      foreground_controller: {
        pid: emitter.pid,
        start_identity: emitter.start_identity,
        code_signature_hash: emitter.code_signature_hash,
      },
      foreground_controller_team_id: emitter.team_id,
      foreground_target: structuredClone(observerTarget),
      invariant_names: ['focus', 'window', 'cursor', 'input', 'clipboard', 'overlay'],
      crash_directory: spec.paths.crash_directory,
      interval_milliseconds: interval,
      code_signature_hash: monitorSignature.code_signature_hash,
    },
    external_foreground_timeout_seconds: externalTimeout,
    operation_timeout_seconds: operationTimeout,
  };
  const written = writePrivateExclusive(outputPath, bindings);
  return { bindings, output_sha256: written.sha256, bindings_sha256: sha256(Buffer.from(JSON.stringify(bindings))) };
}

function invokedAsScript() {
  return process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
}

if (invokedAsScript()) {
  try {
    const options = parseOptions(process.argv.slice(2), ['input', 'output']);
    const result = projectBindings(options.input, options.output);
    process.stdout.write(`${JSON.stringify({ output: options.output, sha256: result.output_sha256 })}\n`);
  } catch (error) {
    process.stderr.write(`project-live-bindings: ${error.message}\n`);
    process.exitCode = 1;
  }
}
