#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  HEX64,
  exactKeys,
  parseOptions,
  positiveInteger,
  publishPrivateAtomicNoReplace,
  readStableJSON,
  requireCondition,
  sameJSON,
  sha256,
  validateEmitter,
  validateTarget,
} from './lib.mjs';

function commonWindow(window, windowPath) {
  requireCondition(window.version === 1, 'owner window version is not 1');
  requireCondition(typeof window.execution_nonce === 'string' && HEX64.test(window.execution_nonce), 'owner window nonce is invalid');
  requireCondition(typeof window.monitor_instance_id === 'string' && /^[0-9a-f-]{36}$/.test(window.monitor_instance_id), 'owner window monitor ID is invalid');
  requireCondition(['perform', 'restore'].includes(window.phase), 'owner window phase is invalid');
  requireCondition(positiveInteger(window.deadline_milliseconds), 'owner window deadline is invalid');
  requireCondition(path.basename(windowPath) === 'external-foreground-window.json', 'owner window filename is not canonical');
  validateTarget(window.target, 'owner window target');
}

export function validateReadbackEvidence(value, window, windowPath) {
  const commonKeys = [
    'version', 'execution_nonce', 'monitor_instance_id', 'phase', 'window_path', 'emitter',
    'target', 'observed_at_milliseconds', 'passed',
  ];
  const phaseKeys = window.phase === 'perform'
    ? ['expected_value_sha256', 'observed_value_sha256']
    : ['baseline_value_sha256', 'observed_value_sha256', 'sentinel', 'observed_sentinel'];
  exactKeys(value, [...commonKeys, ...phaseKeys], 'readback evidence');
  requireCondition(value.version === 1 && value.execution_nonce === window.execution_nonce
    && value.monitor_instance_id === window.monitor_instance_id && value.phase === window.phase,
  'readback evidence is not bound to the owner window');
  requireCondition(value.window_path === windowPath, 'readback evidence references another owner window path');
  validateEmitter(value.emitter, 'readback evidence emitter');
  requireCondition(sameJSON(value.target, window.target), 'readback target differs from the owner window');
  requireCondition(positiveInteger(value.observed_at_milliseconds)
    && value.observed_at_milliseconds <= window.deadline_milliseconds,
  'readback occurred after the owner deadline');
  requireCondition(value.passed === true, 'readback evidence did not pass');
  requireCondition(HEX64.test(value.observed_value_sha256 ?? ''), 'observed value digest is invalid');
  if (window.phase === 'perform') {
    const expected = sha256(Buffer.from(window.request_marker, 'utf8'));
    requireCondition(value.expected_value_sha256 === expected
      && value.observed_value_sha256 === expected,
    'perform readback does not prove the exact request marker');
  } else {
    const baseline = sha256(Buffer.from(window.baseline_value, 'utf8'));
    requireCondition(value.baseline_value_sha256 === baseline
      && value.observed_value_sha256 === baseline,
    'restore readback does not prove the exact baseline');
    validateTarget(window.sentinel, 'owner window sentinel');
    requireCondition(sameJSON(value.sentinel, window.sentinel), 'restore readback sentinel differs from the owner window');
    exactKeys(value.observed_sentinel, ['pid', 'start_identity', 'window_id'], 'readback observed_sentinel');
    requireCondition(sameJSON(value.observed_sentinel, {
      pid: window.sentinel.pid,
      start_identity: window.sentinel.start_identity,
      window_id: window.sentinel.window_id,
    }), 'restore readback did not re-observe the exact sentinel');
  }
  return value;
}

export function publishCoordinatorMarker(windowPath, readbackPath) {
  const retainedWindow = readStableJSON(windowPath, 'owner window');
  const window = retainedWindow.value;
  if (window.phase === 'perform') {
    exactKeys(window, [
      'version', 'execution_nonce', 'monitor_instance_id', 'phase', 'request_marker',
      'target', 'task_complete_path', 'deadline_milliseconds',
    ], 'owner window');
    requireCondition(typeof window.request_marker === 'string' && window.request_marker.length > 0, 'perform request marker is invalid');
  } else if (window.phase === 'restore') {
    exactKeys(window, [
      'version', 'execution_nonce', 'monitor_instance_id', 'phase', 'baseline_value',
      'target', 'sentinel', 'restore_complete_path', 'deadline_milliseconds',
    ], 'owner window');
    requireCondition(typeof window.baseline_value === 'string' && window.baseline_value.length > 0, 'restore baseline is invalid');
  }
  commonWindow(window, windowPath);
  const outputPath = window.phase === 'perform' ? window.task_complete_path : window.restore_complete_path;
  const expectedName = window.phase === 'perform'
    ? 'external-foreground-task-complete.json'
    : 'external-foreground-restore-complete.json';
  requireCondition(path.isAbsolute(outputPath) && path.dirname(outputPath) === path.dirname(windowPath)
    && path.basename(outputPath) === expectedName,
  'owner window marker path is not the canonical sibling');
  const retainedReadback = readStableJSON(readbackPath, 'readback evidence');
  validateReadbackEvidence(retainedReadback.value, window, windowPath);
  const windowModified = Number(retainedWindow.info.mtimeNs / 1_000_000n);
  const readbackModified = Number(retainedReadback.info.mtimeNs / 1_000_000n);
  requireCondition(retainedReadback.value.observed_at_milliseconds + 1000 >= windowModified,
    'readback observation predates the owner window');
  requireCondition(retainedReadback.value.observed_at_milliseconds <= readbackModified + 1000,
    'readback file predates its claimed observation');
  requireCondition(readbackModified <= window.deadline_milliseconds,
    'readback evidence file was published after the owner deadline');
  const marker = {
    version: 1,
    execution_nonce: window.execution_nonce,
    monitor_instance_id: window.monitor_instance_id,
    phase: window.phase === 'perform' ? 'task-complete' : 'restore-complete',
  };
  const written = publishPrivateAtomicNoReplace(outputPath, marker);
  return { marker, output: outputPath, sha256: written.sha256 };
}

function invokedAsScript() {
  return process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
}

if (invokedAsScript()) {
  try {
    const options = parseOptions(process.argv.slice(2), ['window', 'readback']);
    const result = publishCoordinatorMarker(options.window, options.readback);
    process.stdout.write(`${JSON.stringify({ output: result.output, sha256: result.sha256 })}\n`);
  } catch (error) {
    process.stderr.write(`publish-coordinator-marker: ${error.message}\n`);
    process.exitCode = 1;
  }
}
