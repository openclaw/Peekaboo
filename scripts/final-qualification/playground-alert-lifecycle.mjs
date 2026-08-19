#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  exactKeys,
  readStableFile,
  readStableJSON,
  requireCondition,
  writePrivateExclusive,
} from './lib.mjs';

export const PLAYGROUND_OVERALL_SEE_BUDGET_MILLISECONDS = 2500;
export const PLAYGROUND_AX_SEE_BUDGET_MILLISECONDS = 1500;

const SOURCE_COMMIT = /^[0-9a-f]{40}$/;
const EXECUTION_NONCE = /^[0-9a-f]{64}$/;
const CODE_SIGNATURE_HASH = /^[0-9a-f]{40}$/;
const SHA256 = /^[0-9a-f]{64}$/;
const PHASES = [
  'open-fixture-menu',
  'open-fixture-window',
  'initial-see',
  'show-alert',
  'dialog-observe',
  'dismiss',
  'post-dismiss-ax',
];
const EXPECTED_OPERATIONS = {
  'open-fixture-menu': 'clickMenuItem',
  'open-fixture-window': 'listWindows',
  'initial-see': 'desktopObservation',
  'show-alert': 'exactWindowTargetedClick',
  'dialog-observe': 'targetedDialogListElements',
  dismiss: 'exactDialogClickButton',
  'post-dismiss-ax': 'inspectAccessibilityTree',
};

function positiveInteger(value) {
  return Number.isSafeInteger(value) && value > 0;
}

function positiveDecimal(value) {
  return typeof value === 'string' && /^[1-9][0-9]*$/.test(value);
}

function fileReference(filePath, label) {
  const retained = readStableFile(filePath, label);
  return { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 };
}

function readReference(reference, label) {
  exactKeys(reference, ['path', 'size', 'sha256'], label);
  const retained = readStableFile(reference.path, label);
  requireCondition(retained.bytes.length === reference.size
    && retained.sha256 === reference.sha256, `${label} changed after lifecycle construction`);
  return retained;
}

function readJSONReference(reference, label) {
  const retained = readReference(reference, label);
  let value;
  try {
    value = JSON.parse(retained.bytes.toString('utf8'));
  } catch (error) {
    throw new TypeError(`${label} is not JSON: ${error.message}`);
  }
  return { retained, value };
}

function privateDirectory(directory, label) {
  const resolved = fs.realpathSync(directory);
  const info = fs.lstatSync(resolved);
  requireCondition(path.isAbsolute(directory) && resolved === directory
    && info.isDirectory() && !info.isSymbolicLink()
    && info.uid === process.geteuid() && (info.mode & 0o077) === 0,
  `${label} is not one canonical owner-private directory`);
  return resolved;
}

function directoryJSONFiles(directory, label) {
  privateDirectory(directory, label);
  const entries = fs.readdirSync(directory, { withFileTypes: true });
  requireCondition(entries.length > 0
    && entries.every((entry) => entry.isFile() && entry.name.endsWith('.json')),
  `${label} contains a non-bundle entry`);
  return entries
    .map((entry) => path.join(directory, entry.name))
    .sort();
}

function phaseReference(root, phase) {
  const caseDirectory = privateDirectory(path.join(root, 'phases', phase), `${phase} case`);
  const receiptDirectory = privateDirectory(
    path.join(root, 'receipts', phase),
    `${phase} receipt directory`,
  );
  const validatorDirectory = privateDirectory(
    path.join(root, 'validators', phase),
    `${phase} validator directory`,
  );
  const bundles = directoryJSONFiles(receiptDirectory, `${phase} receipt directory`);
  const validators = directoryJSONFiles(validatorDirectory, `${phase} validator directory`);
  requireCondition(bundles.length > 0 && bundles.length === validators.length,
    `${phase} does not retain a complete bundle/validator corpus`);
  const pairs = bundles.map((bundlePath) => {
    const validatorPath = path.join(validatorDirectory, path.basename(bundlePath));
    requireCondition(validators.includes(validatorPath),
      `${phase} bundle has no same-name live validator`);
    return {
      bundle: fileReference(bundlePath, `${phase} bundle`),
      validator: fileReference(validatorPath, `${phase} validator`),
    };
  });
  return {
    result: fileReference(path.join(caseDirectory, 'result.json'), `${phase} result`),
    timing: fileReference(path.join(caseDirectory, 'command-timing.json'), `${phase} timing`),
    summary: fileReference(path.join(caseDirectory, 'summary.json'), `${phase} monitor summary`),
    receipt_directory: receiptDirectory,
    validator_directory: validatorDirectory,
    bundles: pairs,
  };
}

export function expectedAlertDismissButton(cycle) {
  requireCondition(Number.isSafeInteger(cycle) && cycle >= 1 && cycle <= 5,
    'Playground alert lifecycle cycle is outside 1...5');
  return cycle % 2 === 1 ? 'OK' : 'Cancel';
}

function parseNamedOptions(arguments_, names) {
  requireCondition(arguments_.length === names.length * 2,
    `usage requires ${names.map((name) => `--${name} VALUE`).join(' ')}`);
  const result = {};
  for (let index = 0; index < arguments_.length; index += 2) {
    const option = arguments_[index];
    const name = option.startsWith('--') ? option.slice(2) : '';
    requireCondition(names.includes(name) && result[name] === undefined,
      `unexpected option ${option}`);
    result[name] = arguments_[index + 1];
  }
  requireCondition(names.every((name) => typeof result[name] === 'string' && result[name].length > 0),
    'required option is missing');
  return result;
}

export function constructPlaygroundAlertLifecycle({
  root,
  physicalTargets,
  cycle,
  executionNonce,
  peekabooSourceCommit,
  bridgeSourceCommit,
  button,
}) {
  const canonicalRoot = privateDirectory(root, 'Playground alert lifecycle root');
  const numericCycle = Number(cycle);
  requireCondition(Number.isSafeInteger(numericCycle) && numericCycle >= 1 && numericCycle <= 5,
    'qualification cycle is outside 1...5');
  requireCondition(EXECUTION_NONCE.test(executionNonce)
    && SOURCE_COMMIT.test(peekabooSourceCommit)
    && bridgeSourceCommit === peekabooSourceCommit
    && button === expectedAlertDismissButton(numericCycle),
  'Playground alert run binding is invalid');
  const report = {
    version: 2,
    qualification_cycle: numericCycle,
    execution_nonce: executionNonce,
    peekaboo_source_commit: peekabooSourceCommit,
    bridge_source_commit: bridgeSourceCommit,
    dismiss_button: button,
    physical_targets: fileReference(physicalTargets, 'physical targets'),
    target_before: fileReference(path.join(canonicalRoot, 'target-before.json'), 'target before'),
    target_after: fileReference(path.join(canonicalRoot, 'target-after.json'), 'target after'),
    initial_screenshot: fileReference(
      path.join(canonicalRoot, 'initial-see.png'),
      'initial screenshot',
    ),
    crash_comparison: fileReference(
      path.join(canonicalRoot, 'crash-comparison.json'),
      'alert crash comparison',
    ),
    phases: Object.fromEntries(PHASES.map((phase) => [phase, phaseReference(canonicalRoot, phase)])),
  };
  validatePlaygroundAlertLifecycle(report);
  return report;
}

function exactTargetReceipt(result, expected, label) {
  const target = result.target_receipt;
  requireCondition(target && target.pid === expected.pid
    && target.process_start_identity_decimal === expected.start_identity
    && target.window_id === expected.window_id,
  `${label} does not carry the exact Playground target receipt`);
}

function completeMonitorSummary(reference, executionNonce, label) {
  const value = readJSONReference(reference, label).value;
  requireCondition(value.result_success === true
    && value.evidence?.result_contract === true
    && value.evidence?.monitor_liveness === true
    && value.evidence?.contamination_clear === true
    && value.evidence?.desktop_restored === true
    && value.evidence?.clipboard_policy === true
    && value.monitor_receipt?.execution_nonce === executionNonce
    && Array.isArray(value.invariants) && value.invariants.length > 0
    && value.invariants.every((entry) => entry?.passed === true),
  `${label} did not preserve the monitored background invariants`);
}

function commandTiming(reference, label) {
  const value = readJSONReference(reference, label).value;
  exactKeys(value, [
    'version', 'started_at_milliseconds', 'completed_at_milliseconds',
    'wall_time_milliseconds',
  ], label);
  requireCondition(value.version === 1
    && positiveInteger(value.started_at_milliseconds)
    && positiveInteger(value.completed_at_milliseconds)
    && value.completed_at_milliseconds > value.started_at_milliseconds
    && value.wall_time_milliseconds
      === value.completed_at_milliseconds - value.started_at_milliseconds,
  `${label} is not one retained wall-clock interval`);
  return value;
}

function stringsIn(value, matches = []) {
  if (typeof value === 'string') matches.push(value);
  else if (Array.isArray(value)) value.forEach((entry) => stringsIn(entry, matches));
  else if (value && typeof value === 'object') {
    Object.values(value).forEach((entry) => stringsIn(entry, matches));
  }
  return matches;
}

function validatePhaseCorpus(phase, value) {
  exactKeys(value, [
    'result', 'timing', 'summary', 'receipt_directory', 'validator_directory', 'bundles',
  ], `${phase} phase`);
  const currentBundles = directoryJSONFiles(value.receipt_directory, `${phase} receipt directory`);
  const currentValidators = directoryJSONFiles(
    value.validator_directory,
    `${phase} validator directory`,
  );
  requireCondition(Array.isArray(value.bundles) && value.bundles.length > 0
    && value.bundles.length === currentBundles.length
    && value.bundles.length === currentValidators.length,
  `${phase} phase does not list its complete retained receipt corpus`);
  let expectedOperations = 0;
  const corpus = value.bundles.map((pair, index) => {
    exactKeys(pair, ['bundle', 'validator'], `${phase}.bundles[${index}]`);
    const bundle = readJSONReference(pair.bundle, `${phase} bundle ${index}`);
    const validator = readJSONReference(pair.validator, `${phase} validator ${index}`);
    requireCondition(currentBundles.includes(bundle.retained.path)
      && currentValidators.includes(validator.retained.path)
      && path.basename(bundle.retained.path) === path.basename(validator.retained.path)
      && validator.value.success === true && validator.value.data?.valid === true
      && validator.value.data.bundle_sha256 === bundle.retained.sha256
      && validator.value.data.operation === bundle.value?.receipt?.payload?.operation,
    `${phase} bundle ${index} is not paired with its retained live validator`);
    if (validator.value.data.operation === EXPECTED_OPERATIONS[phase]) expectedOperations += 1;
    return { bundle, validator };
  });
  requireCondition(expectedOperations === 1,
    `${phase} phase lacks exactly one ${EXPECTED_OPERATIONS[phase]} receipt`);
  return corpus;
}

export function validatePlaygroundAlertLifecycle(value, expected = null) {
  const label = expected?.label ?? 'Playground alert lifecycle';
  exactKeys(value, [
    'version', 'qualification_cycle', 'execution_nonce', 'peekaboo_source_commit',
    'bridge_source_commit', 'dismiss_button', 'physical_targets', 'target_before',
    'target_after', 'initial_screenshot', 'crash_comparison', 'phases',
  ], label);
  requireCondition(value.version === 2
    && Number.isSafeInteger(value.qualification_cycle)
    && value.qualification_cycle >= 1 && value.qualification_cycle <= 5
    && EXECUTION_NONCE.test(value.execution_nonce ?? '')
    && SOURCE_COMMIT.test(value.peekaboo_source_commit ?? '')
    && value.bridge_source_commit === value.peekaboo_source_commit
    && value.dismiss_button === expectedAlertDismissButton(value.qualification_cycle),
  `${label} is not one source-bound alert lifecycle`);
  if (expected !== null) {
    requireCondition(value.qualification_cycle === expected.cycle
      && value.execution_nonce === expected.execution_nonce
      && value.peekaboo_source_commit === expected.peekaboo_source_commit
      && value.bridge_source_commit === expected.bridge_source_commit,
    `${label} differs from its bound matrix cycle`);
  }

  const physical = readJSONReference(value.physical_targets, `${label} physical targets`).value;
  const playground = physical?.targets?.playground;
  requireCondition(physical.version === 1 && playground
    && positiveInteger(playground.pid) && positiveDecimal(playground.process_start_identity)
    && positiveInteger(playground.window_id)
    && CODE_SIGNATURE_HASH.test(playground.executable?.code_signature_hash ?? '')
    && SHA256.test(playground.executable?.sha256 ?? ''),
  `${label} lacks one exact signed Playground physical target`);
  if (expected !== null) {
    requireCondition(playground.executable.code_signature_hash
      === expected.playground_code_signature_hash,
    `${label} Playground CDHash differs from the candidate artifact`);
  }
  for (const [key, reference] of [
    ['target before', value.target_before], ['target after', value.target_after],
  ]) {
    const process = readJSONReference(reference, `${label} ${key}`).value;
    requireCondition(process.pid === playground.pid
      && process.startIdentity === playground.process_start_identity
      && process.path === playground.executable.path
      && process.sha256 === playground.executable.sha256,
    `${label} ${key} differs from the signed Playground generation`);
  }
  const crash = readJSONReference(value.crash_comparison, `${label} crash comparison`).value;
  requireCondition(crash.version === 1 && crash.passed === true
    && ['added', 'changed', 'removed'].every((key) => (
      Array.isArray(crash[key]) && crash[key].length === 0
    )), `${label} has no zero-delta crash report`);
  const screenshot = readReference(value.initial_screenshot, `${label} initial screenshot`);
  const pngSignature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  requireCondition(screenshot.bytes.length > pngSignature.length
    && screenshot.bytes.subarray(0, pngSignature.length).equals(pngSignature),
  `${label} initial screenshot is not one retained PNG artifact`);

  exactKeys(value.phases, PHASES, `${label}.phases`);
  const phaseData = {};
  const evidencePaths = new Set();
  for (const phase of PHASES) {
    const phaseValue = value.phases[phase];
    completeMonitorSummary(
      phaseValue.summary,
      value.execution_nonce,
      `${label} ${phase} monitor`,
    );
    const timing = commandTiming(phaseValue.timing, `${label} ${phase} timing`);
    const result = readJSONReference(phaseValue.result, `${label} ${phase} result`).value;
    requireCondition(result.success === true, `${label} ${phase} CLI result did not succeed`);
    const corpus = validatePhaseCorpus(phase, phaseValue);
    for (const reference of [
      phaseValue.result, phaseValue.timing, phaseValue.summary,
      ...phaseValue.bundles.flatMap((pair) => [pair.bundle, pair.validator]),
    ]) {
      requireCondition(!evidencePaths.has(reference.path),
        `${label} reuses raw evidence path ${reference.path}`);
      evidencePaths.add(reference.path);
    }
    phaseData[phase] = { result, timing, corpus };
  }
  requireCondition(PHASES.every((phase, index) => index === 0
    || phaseData[PHASES[index - 1]].timing.completed_at_milliseconds
      < phaseData[phase].timing.started_at_milliseconds),
  `${label} phases are not strictly ordered`);

  const windowResult = phaseData['open-fixture-window'].result;
  const dialogWindows = (windowResult.data?.windows ?? []).filter((window) => (
    window.window_title === 'Dialog Fixture' && positiveInteger(window.window_id)
  ));
  requireCondition(dialogWindows.length === 1
    && windowResult.data?.target_application_info?.pid === playground.pid,
  `${label} did not resolve one exact Dialog Fixture window`);
  const target = {
    pid: playground.pid,
    start_identity: playground.process_start_identity,
    window_id: dialogWindows[0].window_id,
  };
  const initial = phaseData['initial-see'];
  exactTargetReceipt(initial.result, target, `${label} initial See`);
  const showElements = initial.result.data?.ui_elements ?? [];
  const showElement = showElements.find((element) => (
    element.identifier === 'dialog-fixture-show-alert' && typeof element.id === 'string'
  ));
  requireCondition(showElement
    && typeof initial.result.data?.snapshot_id === 'string'
    && initial.result.data.snapshot_id.length > 0
    && initial.result.data.screenshot_raw === value.initial_screenshot.path
    && initial.timing.wall_time_milliseconds < PLAYGROUND_OVERALL_SEE_BUDGET_MILLISECONDS
    && initial.result.data.screenshot_annotated === '',
  `${label} initial screenshot See lacks its exact Show Alert element or 2.5-second budget`);

  const show = phaseData['show-alert'].result;
  exactTargetReceipt(show, target, `${label} Show Alert`);
  requireCondition(show.outcome?.delivery_mode === 'background'
    && show.outcome?.dispatch_state === 'dispatched'
    && show.outcome?.mutation_dispatched === true,
  `${label} Show Alert was not one background dispatch`);
  const dialog = phaseData['dialog-observe'].result;
  exactTargetReceipt(dialog, target, `${label} dialog observation`);
  requireCondition(dialog.data?.role === 'AXSheet'
    && ['Cancel', 'OK'].every((button) => dialog.data?.buttons?.includes(button)),
  `${label} did not observe the exact OK/Cancel alert sheet`);
  const dismiss = phaseData.dismiss.result;
  exactTargetReceipt(dismiss, target, `${label} dialog dismissal`);
  requireCondition(dismiss.data?.button === value.dismiss_button
    && dismiss.outcome?.delivery_mode === 'background'
    && dismiss.outcome?.dispatch_state === 'dispatched'
    && dismiss.outcome?.mutation_dispatched === true,
  `${label} did not background-dismiss its exact alert button`);

  const post = phaseData['post-dismiss-ax'];
  exactTargetReceipt(post.result, target, `${label} post-dismiss See`);
  const postElements = post.result.data?.ui_elements ?? [];
  const resultElement = postElements.find((element) => (
    element.identifier === 'dialog-fixture-last-alert-result'
  ));
  const resultStrings = stringsIn(resultElement ?? {});
  requireCondition(typeof post.result.data?.snapshot_id === 'string'
    && post.result.data.snapshot_id.length > 0
    && post.result.data.snapshot_id !== initial.result.data.snapshot_id
    && resultStrings.includes(value.dismiss_button)
    && post.result.data.is_dialog === false
    && post.result.data.truncation == null
    && post.result.data.screenshot_raw === ''
    && post.result.data.screenshot_annotated === ''
    && post.timing.wall_time_milliseconds < PLAYGROUND_AX_SEE_BUDGET_MILLISECONDS,
  `${label} lacks a fresh complete no-dialog AX-only See below the 1.5-second budget`);
  return { value, playground, target, phaseData };
}

export function validatePlaygroundAlertLifecycleFile(filePath, expected = null) {
  const retained = readStableJSON(filePath, expected?.label ?? 'Playground alert lifecycle');
  const validated = validatePlaygroundAlertLifecycle(retained.value, expected);
  return {
    ...validated,
    receipt: { path: retained.path, size: retained.bytes.length, sha256: retained.sha256 },
  };
}

function invokedAsScript() {
  return process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
}

if (invokedAsScript()) {
  try {
    const [action, ...arguments_] = process.argv.slice(2);
    if (action === 'construct') {
      const options = parseNamedOptions(arguments_, [
        'root', 'physical-targets', 'cycle', 'execution-nonce',
        'peekaboo-source', 'bridge-source', 'button', 'output',
      ]);
      const report = constructPlaygroundAlertLifecycle({
        root: path.resolve(options.root),
        physicalTargets: path.resolve(options['physical-targets']),
        cycle: options.cycle,
        executionNonce: options['execution-nonce'],
        peekabooSourceCommit: options['peekaboo-source'],
        bridgeSourceCommit: options['bridge-source'],
        button: options.button,
      });
      writePrivateExclusive(path.resolve(options.output), report);
    } else if (action === 'validate') {
      const options = parseNamedOptions(arguments_, ['input']);
      const result = validatePlaygroundAlertLifecycleFile(path.resolve(options.input));
      process.stdout.write(`${JSON.stringify({ success: true, data: result.value }, null, 2)}\n`);
    } else {
      throw new Error('usage: playground-alert-lifecycle.mjs construct|validate ...');
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
