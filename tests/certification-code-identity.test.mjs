import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { PassThrough } from 'node:stream';
import test from 'node:test';

import {
  embeddedSourceCommit as finalizerSourceCommit,
  inspectFirstPartyExecutable,
  inspectCodeIdentity as inspectWithFinalizer,
  removeCodeIdentityInspectorStage,
  runStagedPIDAttestationCommand,
  stageCodeIdentityInspector,
  verifyAppleSigningRequirement,
} from '../scripts/finalize-multi-target-certification.mjs';
import {
  embeddedSourceCommit as coordinatorSourceCommit,
  inspectCodeIdentity as inspectWithCoordinator,
} from '../scripts/run-live-multi-target-certification.mjs';

const TEAM_ID = 'FWJYW4S8P8';
const CDHASH = 'a'.repeat(40);
const OTHER_CDHASH = 'c'.repeat(40);
const SOURCE_COMMIT = 'b'.repeat(40);
const INSPECTOR_PID = 4321;

function sha256(filePath) {
  return createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function inspectorReceipt(plan, mutate = (value) => value) {
  const process = {
    pid: INSPECTOR_PID,
    start_identity: '432100',
    code_signature_hash: CDHASH,
  };
  const inspected = plan.subject.kind === 'executable' ? {
    kind: 'executable',
    process: null,
    executable_path: plan.subject.executable_path,
    executable_sha256: sha256(plan.subject.executable_path),
    code_signature_hash: CDHASH,
    team_id: plan.subject.expected_team_id,
    source_commit: SOURCE_COMMIT,
  } : {
    kind: 'process',
    process: {
      pid: plan.subject.process_identifier,
      start_identity: plan.subject.process_start_identity,
      code_signature_hash: CDHASH,
    },
    executable_path: plan.expected_inspector_build.executable_path,
    executable_sha256: null,
    code_signature_hash: CDHASH,
    team_id: plan.subject.expected_team_id,
    source_commit: SOURCE_COMMIT,
  };
  return mutate({
    version: 1,
    inspector_process: process,
    inspector_build: plan.expected_inspector_build,
    subject: inspected,
  });
}

function inspectionHarness({
  mutateReceipt = (value) => value,
  calls = [],
  liveExecutable = null,
  liveCodeSignatureHash = CDHASH,
  liveVerificationStatus = 0,
  delayPipeClose = false,
  envelopeReceipt = null,
  reportedSourceCommit = SOURCE_COMMIT,
} = {}) {
  const xml = reportedSourceCommit === null
    ? '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict></dict></plist>'
    : `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>PeekabooSourceCommit</key><string>${reportedSourceCommit}</string></dict></plist>`;
  let active = null;
  const runner = (executable, args, options = {}) => {
    calls.push([executable, args]);
    if (executable === '/usr/bin/codesign') {
      if (args.includes('--display')) {
        const subject = args.at(-1);
        const subjectExecutable = subject.startsWith('+')
          ? (liveExecutable ?? active?.executable ?? '/private/tmp/missing-child') : subject;
        return {
          status: 0,
          stdout: '',
          stderr: `Executable=${subjectExecutable}\nCDHash=${liveCodeSignatureHash}\nTeamIdentifier=${TEAM_ID}\n`,
        };
      }
      if (String(args.at(-1)).startsWith('+') && liveVerificationStatus !== 0) {
        return { status: liveVerificationStatus, stdout: '', stderr: '' };
      }
      return {
        status: args.some((value) => value.includes(`subject.OU] = "${TEAM_ID}"`)) ? 0 : 1,
        stdout: '',
        stderr: '',
      };
    }
    if (executable === '/usr/bin/otool') return { status: 0, stdout: xml, stderr: '' };
    if (executable === '/usr/bin/plutil') {
      const value = reportedSourceCommit === null ? {} : { PeekabooSourceCommit: reportedSourceCommit };
      return { status: 0, stdout: JSON.stringify(value), stderr: '' };
    }
    if (args[0] === '--version') {
      return {
        status: 0,
        stdout: JSON.stringify({ success: true, data: { sourceCommit: SOURCE_COMMIT } }),
        stderr: '',
      };
    }
    throw new Error(`unexpected command: ${executable} ${args.join(' ')} ${options.input ?? ''}`);
  };
  const spawnChild = (executable, args) => {
    const child = new EventEmitter();
    child.pid = INSPECTOR_PID;
    child.stdout = new PassThrough();
    child.stderr = new PassThrough();
    const plan = JSON.parse(fs.readFileSync(args[1]));
    const receipt = args[0] === '--inspect-code'
      ? inspectorReceipt(plan, mutateReceipt)
      : mutateReceipt({ version: 1, staged_attestation_fixture: true });
    fs.writeFileSync(plan.output_path, `${JSON.stringify(receipt, null, 2)}\n`, {
      flag: 'wx', mode: 0o600,
    });
    active = { child, executable, plan, exited: false };
    return child;
  };
  const signalProcess = (pid, signal) => {
    assert.equal(pid, INSPECTOR_PID);
    if (!active || active.exited) return;
    if (signal === 'SIGCONT') {
      const release = JSON.parse(fs.readFileSync(active.plan.release_path));
      assert.deepEqual(release, {
        version: 1, execution_nonce: active.plan.execution_nonce, phase: 'release',
      });
      active.exited = true;
      const closeStreams = () => {
        active.child.stdout.end(`${JSON.stringify({
          result: 'passed', receipt: envelopeReceipt ?? active.plan.output_path,
        })}\n`);
        active.child.stderr.end();
        queueMicrotask(() => active.child.emit('close', 0, null));
      };
      queueMicrotask(() => active.child.emit('exit', 0, null));
      if (delayPipeClose) setImmediate(closeStreams);
      else closeStreams();
    } else if (signal === 'SIGTERM') {
      active.exited = true;
      queueMicrotask(() => {
        active.child.emit('exit', null, 'SIGTERM');
        active.child.emit('close', null, 'SIGTERM');
      });
    }
  };
  return {
    calls,
    runner,
    spawnChild,
    signalProcess,
    waitForStopped: async () => {},
  };
}

async function stagedInspector(t, harness = inspectionHarness()) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'peekaboo-code-identity-test-'));
  const source = path.join(root, 'controller');
  fs.writeFileSync(source, '#!/bin/sh\nexit 0\n', { mode: 0o700 });
  const stage = await stageCodeIdentityInspector(source, [TEAM_ID], SOURCE_COMMIT, harness);
  t.after(() => {
    removeCodeIdentityInspectorStage(stage);
    fs.rmSync(root, { recursive: true, force: true });
  });
  return stage;
}

function pidAttestationPlan(t, prefix, executionNonce) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const planPath = path.join(directory, 'plan.json');
  const outputPath = path.join(directory, 'response.json');
  const releasePath = path.join(directory, 'release.json');
  fs.writeFileSync(planPath, JSON.stringify({
    execution_nonce: executionNonce,
    output_path: outputPath,
    release_path: releasePath,
  }), { mode: 0o600 });
  return { planPath, outputPath, releasePath, executionNonce };
}

test('staged inspector bootstrap tests Apple anchors without deriving display metadata', async (t) => {
  const calls = [];
  const stage = await stagedInspector(t, inspectionHarness({ calls }));
  assert.equal(stage.teamID, TEAM_ID);
  const codesignCalls = calls.filter(([executable]) => executable === '/usr/bin/codesign');
  assert.equal(codesignCalls.length, 4);
  assert.ok(codesignCalls[0][1].includes('--verify'));
  assert.ok(!codesignCalls[0][1].includes('--display'));
  assert.ok(codesignCalls[1][1].includes('--display'));
  assert.ok(!codesignCalls[1][1].includes('--verify'));
  assert.ok(codesignCalls.every(([, args]) => !(args.includes('--verify') && args.includes('--display'))));
});

test('false-Team Apple requirement fails in a verify-only invocation', () => {
  const calls = [];
  const harness = inspectionHarness({ calls });
  assert.throws(() => verifyAppleSigningRequirement(
    '/private/tmp/signed-fixture',
    'AAAAAAAAAA',
    'false-Team fixture',
    harness.runner,
  ), /does not satisfy the Apple-anchored signing requirement/);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], '/usr/bin/codesign');
  assert.ok(calls[0][1].includes('--verify'));
  assert.ok(!calls[0][1].includes('--display'));
  assert.ok(calls[0][1].some((value) => value.includes('subject.OU] = "AAAAAAAAAA"')));
});

test('native inspector drains stdout after exit before parsing its envelope', async (t) => {
  const stage = await stagedInspector(t, inspectionHarness({ delayPipeClose: true }));
  assert.equal(stage.codeSignatureHash, CDHASH);
});

test('PID attestation runs only the retained stage across source swap and restore', async (t) => {
  const stage = await stagedInspector(t);
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'peekaboo-pid-attestation-test-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const planPath = path.join(directory, 'plan.json');
  const outputPath = path.join(directory, 'response.json');
  const releasePath = path.join(directory, 'release.json');
  const executionNonce = 'e'.repeat(64);
  fs.writeFileSync(planPath, JSON.stringify({
    execution_nonce: executionNonce,
    output_path: outputPath,
    release_path: releasePath,
  }), { mode: 0o600 });
  const source = path.join(path.dirname(stage.directory), 'mutable-contract-controller');
  const backup = `${source}.backup`;
  fs.writeFileSync(source, 'original\n', { mode: 0o700 });
  t.after(() => {
    fs.rmSync(source, { force: true });
    fs.rmSync(backup, { force: true });
  });
  let launched;
  const harness = inspectionHarness();
  const spawnChild = (executable, args, options) => {
    launched = executable;
    fs.renameSync(source, backup);
    fs.writeFileSync(source, 'replacement\n', { mode: 0o700 });
    fs.rmSync(source);
    fs.renameSync(backup, source);
    return harness.spawnChild(executable, args, options);
  };

  await runStagedPIDAttestationCommand({
    inspectorStage: stage,
    planPath,
    expectedOutputPath: outputPath,
    releasePath,
    executionNonce,
    label: 'fixture',
    ...harness,
    spawnChild,
  });
  assert.equal(launched, stage.executable);
  assert.equal(fs.readFileSync(source, 'utf8'), 'original\n');
});

test('PID attestation rejects a staged child envelope for another receipt', async (t) => {
  const stage = await stagedInspector(t);
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'peekaboo-pid-envelope-test-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const planPath = path.join(directory, 'plan.json');
  const outputPath = path.join(directory, 'response.json');
  const releasePath = path.join(directory, 'release.json');
  const executionNonce = 'f'.repeat(64);
  fs.writeFileSync(planPath, JSON.stringify({
    execution_nonce: executionNonce,
    output_path: outputPath,
    release_path: releasePath,
  }), { mode: 0o600 });
  const harness = inspectionHarness({ envelopeReceipt: '/private/tmp/other-response.json' });
  await assert.rejects(runStagedPIDAttestationCommand({
    inspectorStage: stage,
    planPath,
    expectedOutputPath: outputPath,
    releasePath,
    executionNonce,
    label: 'fixture',
    ...harness,
  }), /not bound to its staged child receipt/);
});

test('PID attestation rejects a forged live attester at the staged pathname', async (t) => {
  const stage = await stagedInspector(t);
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'peekaboo-pid-forged-test-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const planPath = path.join(directory, 'plan.json');
  const outputPath = path.join(directory, 'response.json');
  const releasePath = path.join(directory, 'release.json');
  const forgedExecutable = path.join(directory, 'forged-attester');
  fs.writeFileSync(forgedExecutable, 'forged\n', { mode: 0o700 });
  const executionNonce = 'd'.repeat(64);
  fs.writeFileSync(planPath, JSON.stringify({
    execution_nonce: executionNonce,
    output_path: outputPath,
    release_path: releasePath,
  }), { mode: 0o600 });
  const harness = inspectionHarness({ liveExecutable: forgedExecutable });
  await assert.rejects(runStagedPIDAttestationCommand({
    inspectorStage: stage,
    planPath,
    expectedOutputPath: outputPath,
    releasePath,
    executionNonce,
    label: 'fixture',
    ...harness,
  }), /live child differs from the retained inspector stage/);
});

test('PID attestation installs its error handler before rejecting an invalid spawn', async (t) => {
  const stage = await stagedInspector(t);
  const plan = pidAttestationPlan(t, 'peekaboo-pid-spawn-error-', 'c'.repeat(64));
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  let errorHandlerInstalled = false;
  const once = child.once.bind(child);
  child.once = (event, handler) => {
    if (event === 'error') errorHandlerInstalled = true;
    return once(event, handler);
  };
  const rejected = assert.rejects(runStagedPIDAttestationCommand({
    inspectorStage: stage,
    expectedOutputPath: plan.outputPath,
    releasePath: plan.releasePath,
    label: 'fixture',
    spawnChild: () => {
      queueMicrotask(() => child.emit('error', new Error('spawn failed')));
      return child;
    },
    ...plan,
  }), /challenge failed/);
  await rejected;
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(errorHandlerInstalled, true);
});

test('PID attestation rejects missing and mismatched live source provenance', async (t) => {
  const stage = await stagedInspector(t);
  for (const [index, reportedSourceCommit] of [null, 'c'.repeat(40)].entries()) {
    const plan = pidAttestationPlan(
      t,
      `peekaboo-pid-source-${index}-`,
      String(index + 1).repeat(64),
    );
    const harness = inspectionHarness({ reportedSourceCommit });
    await assert.rejects(runStagedPIDAttestationCommand({
      inspectorStage: stage,
      expectedOutputPath: plan.outputPath,
      releasePath: plan.releasePath,
      label: `fixture ${index}`,
      ...harness,
      ...plan,
    }), /no exact source stamp|differs from the retained inspector stage/);
  }
});

test('first-party contract is derived from separate verify and display calls on one staged copy', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'peekaboo-validator-source-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const source = path.join(root, 'peekaboo');
  fs.writeFileSync(source, '#!/bin/sh\nexit 0\n', { mode: 0o700 });
  const calls = [];
  const harness = inspectionHarness({ calls });
  const contract = inspectFirstPartyExecutable(source, {
    trusted_first_party_validator_team_ids: [TEAM_ID],
    trusted_bridge_host_team_ids: [TEAM_ID],
  }, { runner: harness.runner });
  assert.equal(contract.team_id, TEAM_ID);
  assert.equal(contract.code_signature_hash, CDHASH);
  assert.equal(contract.source_commit, SOURCE_COMMIT);
  const codesignCalls = calls.filter(([executable]) => executable === '/usr/bin/codesign');
  assert.equal(codesignCalls.length, 2);
  assert.ok(codesignCalls[0][1].includes('--verify'));
  assert.ok(!codesignCalls[0][1].includes('--display'));
  assert.ok(codesignCalls[1][1].includes('--display'));
  assert.ok(!codesignCalls[1][1].includes('--verify'));
  assert.equal(codesignCalls[0][1].at(-1), codesignCalls[1][1].at(-1));
  assert.match(codesignCalls[0][1].at(-1), /peekaboo-validator\./);
});

test('native code-identity receipt schemas are closed at the root', async (t) => {
  const stage = await stagedInspector(t);
  const harness = inspectionHarness({
    mutateReceipt: (receipt) => ({ ...receipt, caller_success: true }),
  });
  await assert.rejects(inspectWithFinalizer({
    inspectorStage: stage,
    subject: {
      kind: 'executable', executable_path: stage.executable, expected_team_id: TEAM_ID,
    },
    expected: {
      kind: 'executable',
      executablePath: stage.executable,
      executableSHA256: stage.executableSHA256,
      codeSignatureHash: CDHASH,
      teamID: TEAM_ID,
      sourceCommit: SOURCE_COMMIT,
    },
    label: 'closed receipt fixture',
    ...harness,
  }), /does not bind the exact inspector build and process/);
});

test('native inspector rejects a forged live child even when its receipt claims the staged PID', async (t) => {
  const stage = await stagedInspector(t);
  const harness = inspectionHarness({
    liveCodeSignatureHash: OTHER_CDHASH,
    mutateReceipt: (receipt) => {
      receipt.inspector_process.code_signature_hash = OTHER_CDHASH;
      return receipt;
    },
  });
  await assert.rejects(inspectWithFinalizer({
    inspectorStage: stage,
    subject: { kind: 'executable', executable_path: stage.executable, expected_team_id: TEAM_ID },
    expected: {
      kind: 'executable',
      executablePath: stage.executable,
      executableSHA256: stage.executableSHA256,
      codeSignatureHash: CDHASH,
      teamID: TEAM_ID,
      sourceCommit: SOURCE_COMMIT,
    },
    label: 'forged child fixture',
    ...harness,
  }), /does not bind the exact inspector build and process/);
});

test('native inspector rejects an ancestor-swapped live executable path', async (t) => {
  const stage = await stagedInspector(t);
  const replacementRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'peekaboo-swapped-ancestor-'));
  t.after(() => fs.rmSync(replacementRoot, { recursive: true, force: true }));
  const replacement = path.join(replacementRoot, 'peekaboo-certification-controller');
  fs.copyFileSync(stage.executable, replacement);
  const harness = inspectionHarness({ liveExecutable: replacement });
  await assert.rejects(inspectWithFinalizer({
    inspectorStage: stage,
    subject: { kind: 'executable', executable_path: stage.executable, expected_team_id: TEAM_ID },
    expected: {
      kind: 'executable',
      executablePath: stage.executable,
      executableSHA256: stage.executableSHA256,
      codeSignatureHash: CDHASH,
      teamID: TEAM_ID,
      sourceCommit: SOURCE_COMMIT,
    },
    label: 'ancestor swap fixture',
    ...harness,
  }), /does not bind the exact inspector build and process/);
});

test('native inspector rejects a false-Team live-process requirement before display', async (t) => {
  const stage = await stagedInspector(t);
  const harness = inspectionHarness({ liveVerificationStatus: 1 });
  await assert.rejects(inspectWithFinalizer({
    inspectorStage: stage,
    subject: { kind: 'executable', executable_path: stage.executable, expected_team_id: TEAM_ID },
    expected: {
      kind: 'executable',
      executablePath: stage.executable,
      executableSHA256: stage.executableSHA256,
      codeSignatureHash: CDHASH,
      teamID: TEAM_ID,
      sourceCommit: SOURCE_COMMIT,
    },
    label: 'false live requirement fixture',
    ...harness,
  }), /does not satisfy the Apple-anchored signing requirement/);
  const liveCalls = harness.calls.filter(([executable, args]) => (
    executable === '/usr/bin/codesign' && String(args.at(-1)).startsWith('+')
  ));
  assert.equal(liveCalls.length, 1);
  assert.ok(liveCalls[0][1].includes('--verify'));
  assert.ok(!liveCalls[0][1].includes('--display'));
});

for (const [name, inspect] of [
  ['finalizer', inspectWithFinalizer],
  ['coordinator', inspectWithCoordinator],
]) {
  test(`${name} refuses a forged executable receipt after a path swap`, async (t) => {
    const stage = await stagedInspector(t);
    const target = path.join(path.dirname(stage.directory), `target-${name}`);
    fs.writeFileSync(target, 'target\n', { mode: 0o500 });
    t.after(() => fs.rmSync(target, { force: true }));
    const swapped = `${target}.swapped`;
    const harness = inspectionHarness({
      mutateReceipt: (receipt) => {
        receipt.subject.executable_path = swapped;
        return receipt;
      },
    });
    await assert.rejects(inspect({
      inspectorStage: stage,
      subject: { kind: 'executable', executable_path: target, expected_team_id: TEAM_ID },
      expected: {
        kind: 'executable',
        executablePath: target,
        executableSHA256: sha256(target),
        codeSignatureHash: CDHASH,
        teamID: TEAM_ID,
        sourceCommit: SOURCE_COMMIT,
      },
      label: `${name} swapped fixture`,
      ...harness,
    }), /differs from the exact expectation/);
  });

  test(`${name} refuses a forged same-PID exec receipt`, async (t) => {
    const stage = await stagedInspector(t);
    const expectedProcess = {
      pid: 9876,
      start_identity: '987600',
      code_signature_hash: CDHASH,
    };
    const harness = inspectionHarness({
      mutateReceipt: (receipt) => {
        receipt.subject.executable_path = '/private/tmp/replaced-at-exec';
        receipt.subject.code_signature_hash = OTHER_CDHASH;
        receipt.subject.process.code_signature_hash = OTHER_CDHASH;
        return receipt;
      },
    });
    await assert.rejects(inspect({
      inspectorStage: stage,
      subject: {
        kind: 'process', process_identifier: expectedProcess.pid,
        process_start_identity: expectedProcess.start_identity, expected_team_id: TEAM_ID,
      },
      expected: {
        kind: 'process',
        process: expectedProcess,
        executablePath: stage.executable,
        executableSHA256: null,
        codeSignatureHash: CDHASH,
        teamID: TEAM_ID,
        sourceCommit: SOURCE_COMMIT,
      },
      label: `${name} same-PID exec fixture`,
      ...harness,
    }), /differs from the exact expectation|code-signature hash differs/);
  });
}

function sourceStampRunner(calls, nodeArchitecture) {
  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>PeekabooSourceCommit</key><string>${SOURCE_COMMIT}</string></dict></plist>`;
  return (executable, args, options) => {
    calls.push([executable, args, options?.input]);
    if (executable === '/usr/bin/otool') {
      const architecture = nodeArchitecture === 'arm64' ? 'arm64' : 'x86_64';
      assert.deepEqual(args, [
        '-arch', architecture, '-X', '-P', '/private/tmp/fixture',
      ]);
      return { status: 0, stdout: xml, stderr: '' };
    }
    if (executable === '/usr/bin/plutil') {
      assert.equal(options.input, xml);
      return { status: 0, stdout: JSON.stringify({ PeekabooSourceCommit: SOURCE_COMMIT }), stderr: '' };
    }
    throw new Error(`unexpected executable: ${executable}`);
  };
}

for (const [name, readSourceCommit] of [
  ['finalizer', finalizerSourceCommit],
  ['coordinator', coordinatorSourceCommit],
]) {
  test(`${name} selects one native slice and parses dedicated info-plist output`, () => {
    for (const nodeArchitecture of ['arm64', 'x64']) {
      const calls = [];
      assert.equal(readSourceCommit('/private/tmp/fixture', 'fixture', {
        runner: sourceStampRunner(calls, nodeArchitecture),
        nodeArchitecture,
      }), SOURCE_COMMIT);
      assert.equal(calls.length, 2);
    }
  });
}

test('production otool path extracts a stamped native Mach-O fixture', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'peekaboo-info-plist-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const source = path.join(directory, 'main.c');
  const plist = path.join(directory, 'Info.plist');
  const executable = path.join(directory, 'fixture');
  fs.writeFileSync(source, 'int main(void) { return 0; }\n');
  fs.writeFileSync(plist, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>PeekabooSourceCommit</key><string>${SOURCE_COMMIT}</string></dict></plist>\n`);
  const compilation = spawnSync('/usr/bin/xcrun', [
    'clang', source, `-Wl,-sectcreate,__TEXT,__info_plist,${plist}`, '-o', executable,
  ], { encoding: 'utf8' });
  assert.equal(compilation.status, 0, compilation.stderr);

  assert.equal(finalizerSourceCommit(executable, 'native fixture'), SOURCE_COMMIT);
  assert.equal(coordinatorSourceCommit(executable, 'native fixture'), SOURCE_COMMIT);
});
