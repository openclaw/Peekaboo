#!/usr/bin/env node

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  exactKeys,
  parseOptions,
  readStableJSON,
  requireCondition,
  sameJSON,
  writePrivateExclusive,
} from './lib.mjs';

const HEX40 = /^[0-9a-f]{40}$/;
const TEAM_ID = /^[A-Z0-9]{10}$/;

function positiveInteger(value) {
  return Number.isSafeInteger(value) && value > 0;
}

function positiveDecimal(value) {
  return typeof value === 'string' && /^[1-9][0-9]*$/.test(value);
}

function finiteNumber(value) {
  return typeof value === 'number' && Number.isFinite(value) && !Object.is(value, -0);
}

function protectedPath(filePath, label, kind) {
  requireCondition(typeof filePath === 'string' && path.isAbsolute(filePath)
    && !filePath.includes('\0'), `${label} must be absolute`);
  const info = fs.lstatSync(filePath);
  const unsafeMode = kind === 'directory' ? (info.mode & 0o077) !== 0 : (info.mode & 0o022) !== 0;
  requireCondition(!unsafeMode && info.uid === process.geteuid() && !info.isSymbolicLink()
    && (kind !== 'file' || (info.isFile() && info.nlink === 1))
    && (kind !== 'directory' || info.isDirectory()), `${label} is not one protected ${kind}`);
  if (kind === 'file') fs.accessSync(filePath, fs.constants.X_OK);
}

function validateBounds(value, label) {
  exactKeys(value, ['x', 'y', 'width', 'height'], label);
  requireCondition([value.x, value.y, value.width, value.height].every(finiteNumber)
    && value.width > 0 && value.height > 0, `${label} is invalid`);
}

function validateTarget(value, label, controller = false) {
  exactKeys(value, controller
    ? ['process_identifier', 'process_start_identity_decimal', 'window_id', 'bounds', 'is_minimized', 'click_point']
    : ['scope', 'pid', 'start_identity', 'window_id', 'bounds', 'is_minimized'], label);
  const pid = controller ? value.process_identifier : value.pid;
  const start = controller ? value.process_start_identity_decimal : value.start_identity;
  requireCondition((controller || value.scope === 'window') && positiveInteger(pid)
    && positiveDecimal(start) && positiveInteger(value.window_id)
    && value.window_id <= 0xffffffff
    && (value.is_minimized === null || typeof value.is_minimized === 'boolean'),
  `${label} identity is invalid`);
  validateBounds(value.bounds, `${label}.bounds`);
  if (controller) {
    exactKeys(value.click_point, ['x', 'y'], `${label}.click_point`);
    requireCondition([value.click_point.x, value.click_point.y].every(finiteNumber)
      && value.click_point.x >= value.bounds.x
      && value.click_point.x <= value.bounds.x + value.bounds.width
      && value.click_point.y >= value.bounds.y
      && value.click_point.y <= value.bounds.y + value.bounds.height,
    `${label}.click_point is outside its exact window`);
  }
}

export function constructLivePlan(bindingsPath, outputPath) {
  const retained = readStableJSON(bindingsPath, 'live-v4 bindings');
  const bindings = retained.value;
  exactKeys(bindings, [
    'runs_directory', 'peekaboo_executable', 'controller_executable', 'monitor_executable',
    'bridge', 'controllers', 'observer', 'monitor',
    'external_foreground_timeout_seconds', 'operation_timeout_seconds',
  ], 'bindings');
  protectedPath(bindings.runs_directory, 'runs_directory', 'directory');
  for (const key of ['peekaboo_executable', 'controller_executable', 'monitor_executable']) {
    protectedPath(bindings[key], key, 'file');
  }

  exactKeys(bindings.bridge, ['socket_path', 'trusted_host_team_ids', 'expected_host'], 'bridge');
  requireCondition(path.isAbsolute(bindings.bridge.socket_path)
    && Array.isArray(bindings.bridge.trusted_host_team_ids)
    && bindings.bridge.trusted_host_team_ids.length > 0
    && bindings.bridge.trusted_host_team_ids.every((entry) => TEAM_ID.test(entry)),
  'bridge trust is invalid');
  exactKeys(bindings.bridge.expected_host, [
    'host_kind', 'process_identifier', 'process_start_identity_decimal',
    'code_signature_hash', 'source_commit',
  ], 'bridge.expected_host');
  requireCondition(['gui', 'daemon'].includes(bindings.bridge.expected_host.host_kind)
    && positiveInteger(bindings.bridge.expected_host.process_identifier)
    && positiveDecimal(bindings.bridge.expected_host.process_start_identity_decimal)
    && HEX40.test(bindings.bridge.expected_host.code_signature_hash)
    && HEX40.test(bindings.bridge.expected_host.source_commit),
  'bridge host identity is invalid');

  requireCondition(Array.isArray(bindings.controllers) && bindings.controllers.length === 2,
    'exactly two controllers are required');
  bindings.controllers.forEach((controller, index) => {
    exactKeys(controller, ['controller_id', 'target_id', 'target'], `controllers[${index}]`);
    const suffix = index === 0 ? 'a' : 'b';
    requireCondition(controller.controller_id === `controller-${suffix}`
      && controller.target_id === `target-${suffix}`, 'controller order/IDs are not canonical');
    validateTarget(controller.target, `controllers[${index}].target`, true);
  });
  requireCondition(new Set(bindings.controllers.map(({ target }) => (
    `${target.process_identifier}:${target.process_start_identity_decimal}:${target.window_id}`
  ))).size === 2, 'controller windows must be distinct');

  exactKeys(bindings.observer, ['target', 'semantic_element', 'baseline_value'], 'observer');
  validateTarget(bindings.observer.target, 'observer.target');
  exactKeys(bindings.observer.semantic_element, ['role', 'identifier', 'title'],
    'observer.semantic_element');
  const semanticString = (value) => value === null || (
    typeof value === 'string' && value.length > 0 && !value.includes('\0')
      && Buffer.byteLength(value) <= 1024
  );
  requireCondition(typeof bindings.observer.semantic_element.role === 'string'
    && bindings.observer.semantic_element.role.length > 0
    && semanticString(bindings.observer.semantic_element.identifier)
    && semanticString(bindings.observer.semantic_element.title)
    && (bindings.observer.semantic_element.identifier !== null
      || bindings.observer.semantic_element.title !== null)
    && typeof bindings.observer.baseline_value === 'string'
    && bindings.observer.baseline_value.length > 0
    && Buffer.byteLength(bindings.observer.baseline_value) <= 4096,
  'observer semantic binding is invalid');

  exactKeys(bindings.monitor, [
    'sentinel', 'foreground_controller', 'foreground_controller_team_id', 'foreground_target',
    'invariant_names', 'crash_directory', 'interval_milliseconds', 'code_signature_hash',
  ], 'monitor');
  validateTarget(bindings.monitor.sentinel, 'monitor.sentinel');
  validateTarget(bindings.monitor.foreground_target, 'monitor.foreground_target');
  exactKeys(bindings.monitor.foreground_controller, ['pid', 'start_identity', 'code_signature_hash'],
    'monitor.foreground_controller');
  requireCondition(positiveInteger(bindings.monitor.foreground_controller.pid)
    && positiveDecimal(bindings.monitor.foreground_controller.start_identity)
    && HEX40.test(bindings.monitor.foreground_controller.code_signature_hash)
    && TEAM_ID.test(bindings.monitor.foreground_controller_team_id)
    && HEX40.test(bindings.monitor.code_signature_hash)
    && sameJSON(bindings.monitor.foreground_target, bindings.observer.target)
    && sameJSON(bindings.monitor.invariant_names,
      ['focus', 'window', 'cursor', 'input', 'clipboard', 'overlay'])
    && bindings.monitor.crash_directory
      === path.join(os.homedir(), 'Library', 'Logs', 'DiagnosticReports')
    && Number.isSafeInteger(bindings.monitor.interval_milliseconds)
    && bindings.monitor.interval_milliseconds >= 5
    && bindings.monitor.interval_milliseconds <= 100,
  'monitor binding is invalid');
  const processGenerations = [
    ...bindings.controllers.map(({ target }) => (
      `${target.process_identifier}:${target.process_start_identity_decimal}`
    )),
    `${bindings.observer.target.pid}:${bindings.observer.target.start_identity}`,
    `${bindings.monitor.sentinel.pid}:${bindings.monitor.sentinel.start_identity}`,
  ];
  requireCondition(new Set(processGenerations).size === 4,
    'controller, observer, and sentinel generations must all be distinct');
  requireCondition(!new Set([
    bindings.bridge.expected_host.process_identifier,
    ...bindings.controllers.map(({ target }) => target.process_identifier),
  ]).has(bindings.monitor.foreground_controller.pid),
  'foreground controller must be distinct from background owners');

  requireCondition(Number.isSafeInteger(bindings.external_foreground_timeout_seconds)
    && bindings.external_foreground_timeout_seconds >= 5
    && bindings.external_foreground_timeout_seconds <= 150
    && Number.isSafeInteger(bindings.operation_timeout_seconds)
    && bindings.operation_timeout_seconds > 0 && bindings.operation_timeout_seconds <= 3600
    && bindings.operation_timeout_seconds
      >= (3 * bindings.external_foreground_timeout_seconds) + 50,
  'operation timeout does not cover both external windows and lifecycle margin');
  const plan = { version: 1, ...bindings };
  writePrivateExclusive(outputPath, plan);
  return plan;
}

function invokedAsScript() {
  return process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
}

if (invokedAsScript()) {
  try {
    const [action, ...arguments_] = process.argv.slice(2);
    if (action !== 'construct') {
      throw new Error('usage: construct-live-plan.mjs construct --bindings BINDINGS.json --output ABSENT_PLAN.json');
    }
    const options = parseOptions(arguments_, ['bindings', 'output']);
    constructLivePlan(options.bindings, options.output);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
