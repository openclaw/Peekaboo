#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  exactKeys,
  parseOptions,
  readStableJSON,
  requireCondition,
  requireStableExecutable,
  sha256,
  writePrivateExclusive,
} from './lib.mjs';

const HOST_ROLES = ['local', 'studio'];
const EPOCHS = ['before', 'during', 'after'];
const ROOT_CLASSES = ['agent', 'bridge', 'coordinator', 'elevation', 'fixture', 'integrated_cu'];
const HOST_UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;
const HEX40 = /^[0-9a-f]{40}$/;
const HEX64 = /^[0-9a-f]{64}$/;

function run(executable, arguments_, label) {
  const result = spawnSync(executable, arguments_, {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', LANG: 'C', LC_ALL: 'C' },
  });
  requireCondition(result.status === 0,
    `${label} failed: ${String(result.stderr || result.stdout).trim()}`);
  return `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
}

function processTable() {
  const output = run('/bin/ps', ['-axo', 'pid=,ppid='], 'process table');
  const table = new Map();
  for (const [index, line] of output.trim().split('\n').entries()) {
    const match = line.trim().match(/^([1-9][0-9]*)\s+([0-9]+)$/);
    requireCondition(match !== null, `process table row ${index + 1} is malformed`);
    const pid = Number(match[1]);
    const parentPID = Number(match[2]);
    requireCondition(Number.isSafeInteger(pid) && Number.isSafeInteger(parentPID),
      `process table row ${index + 1} is out of range`);
    requireCondition(!table.has(pid), `process table repeats PID ${pid}`);
    table.set(pid, parentPID);
  }
  return table;
}

function descendantPIDs(table, roots) {
  const selected = new Set(roots);
  let changed = true;
  while (changed) {
    changed = false;
    for (const [pid, parentPID] of table) {
      if (!selected.has(pid) && selected.has(parentPID)) {
        selected.add(pid);
        changed = true;
      }
    }
  }
  return [...selected].sort((left, right) => left - right);
}

function monitorJSON(monitor, command, pid, directory, sequence) {
  const output = path.join(directory, `${sequence}-${command}-${pid}.json`);
  run(monitor, [command, '--pid', String(pid), '--output', output], `monitor ${command} for PID ${pid}`);
  return readStableJSON(output, `monitor ${command} for PID ${pid}`).value;
}

function signingMetadata(executablePath) {
  const output = run('/usr/bin/codesign', ['-dvvv', executablePath], `codesign ${executablePath}`);
  const value = (key) => output.match(new RegExp(`^${key}=(.+)$`, 'm'))?.[1] ?? null;
  const codeSignatureHash = value('CDHash');
  const signingIdentifier = value('Identifier');
  const teamID = value('TeamIdentifier');
  requireCondition(HEX40.test(codeSignatureHash ?? '') && typeof signingIdentifier === 'string'
    && signingIdentifier.length > 0 && /^[A-Z0-9]{10}$/.test(teamID ?? ''),
  `codesign identity is incomplete for ${executablePath}`);
  return { codeSignatureHash, signingIdentifier, teamID };
}

function validateSpec(value) {
  exactKeys(value, [
    'version', 'role', 'host_uuid', 'deployment_envelope_sha256', 'epoch', 'roots',
  ], 'collector spec');
  requireCondition(value.version === 1 && HOST_ROLES.includes(value.role)
    && HOST_UUID.test(value.host_uuid) && HEX64.test(value.deployment_envelope_sha256)
    && EPOCHS.includes(value.epoch) && Array.isArray(value.roots) && value.roots.length > 0,
  'collector spec is malformed');
  const roots = value.roots.map((root, index) => {
    exactKeys(root, [
      'root_id', 'root_class', 'pid', 'start_identity', 'code_signature_hash',
    ], `collector spec roots[${index}]`);
    requireCondition(typeof root.root_id === 'string' && /^[a-z][a-z0-9_-]{0,63}$/.test(root.root_id)
      && ROOT_CLASSES.includes(root.root_class) && Number.isSafeInteger(root.pid) && root.pid > 0
      && typeof root.start_identity === 'string' && /^[1-9][0-9]*$/.test(root.start_identity)
      && HEX40.test(root.code_signature_hash), `collector spec roots[${index}] is malformed`);
    return root;
  });
  requireCondition(new Set(roots.map((root) => root.root_id)).size === roots.length,
    'collector spec repeats a root ID');
  requireCondition(roots.every((root, index) => index === 0
    || roots[index - 1].root_id < root.root_id), 'collector spec roots are not canonical');
  return { ...value, roots };
}

export function collectProcessTree(specPath, monitorPath, outputPath) {
  const spec = validateSpec(readStableJSON(specPath, 'collector spec').value);
  requireStableExecutable(monitorPath, 'signed process monitor');
  const collectorBytes = fs.readFileSync(fileURLToPath(import.meta.url));
  const before = processTable();
  requireCondition(spec.roots.every((root) => before.has(root.pid)),
    'one or more task roots are absent');
  const pids = descendantPIDs(before, spec.roots.map((root) => root.pid));
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'pbq-process-tree.'));
  fs.chmodSync(temporary, 0o700);
  try {
    const identities = new Map();
    for (const [index, pid] of pids.entries()) {
      const executable = monitorJSON(monitorPath, 'process-executable', pid, temporary, index);
      exactKeys(executable, ['pid', 'startIdentity', 'path', 'sha256'], `process executable ${pid}`);
      requireCondition(executable.pid === pid && /^[1-9][0-9]*$/.test(executable.startIdentity)
        && path.isAbsolute(executable.path) && HEX64.test(executable.sha256),
      `process executable ${pid} is malformed`);
      const canonicalPath = fs.realpathSync(executable.path);
      requireCondition(canonicalPath === executable.path, `process executable ${pid} is not canonical`);
      const signing = signingMetadata(canonicalPath);
      identities.set(pid, {
        pid,
        start_identity: executable.startIdentity,
        executable_path: canonicalPath,
        executable_name: path.basename(canonicalPath),
        executable_sha256: executable.sha256,
        code_signature_hash: signing.codeSignatureHash,
        signing_identifier: signing.signingIdentifier,
        team_id: signing.teamID,
      });
    }
    const after = processTable();
    requireCondition(JSON.stringify(descendantPIDs(after, spec.roots.map((root) => root.pid)))
      === JSON.stringify(pids), 'task process membership changed during collection');
    requireCondition(pids.every((pid) => after.get(pid) === before.get(pid)),
      'task process ancestry changed during collection');
    for (const [index, pid] of pids.entries()) {
      const finalIdentity = monitorJSON(
        monitorPath,
        'process-identity',
        pid,
        temporary,
        pids.length + index,
      );
      exactKeys(finalIdentity, ['pid', 'startIdentity'], `final process identity ${pid}`);
      requireCondition(finalIdentity.pid === pid
        && finalIdentity.startIdentity === identities.get(pid).start_identity,
      `task process ${pid} generation changed during collection`);
    }
    const rootByPID = new Map(spec.roots.map((root) => [root.pid, root]));
    for (const root of spec.roots) {
      const observed = identities.get(root.pid);
      requireCondition(observed.start_identity === root.start_identity
        && observed.code_signature_hash === root.code_signature_hash,
      `task root ${root.root_id} generation or code identity changed`);
    }
    const processes = pids.map((pid) => {
      const process = identities.get(pid);
      const parentPID = before.get(pid);
      const parent = identities.get(parentPID);
      return {
        pid: process.pid,
        start_identity: process.start_identity,
        parent_pid: rootByPID.has(pid) ? null : parentPID,
        parent_start_identity: rootByPID.has(pid) ? null : parent?.start_identity ?? null,
        executable_path: process.executable_path,
        executable_name: process.executable_name,
        executable_sha256: process.executable_sha256,
        code_signature_hash: process.code_signature_hash,
        signing_identifier: process.signing_identifier,
        team_id: process.team_id,
      };
    });
    requireCondition(processes.every((process) => process.parent_pid === null
      || process.parent_start_identity !== null), 'a task descendant parent escaped the collected tree');
    return writePrivateExclusive(outputPath, {
      version: 1,
      role: spec.role,
      host_uuid: spec.host_uuid,
      deployment_envelope_sha256: spec.deployment_envelope_sha256,
      epoch: spec.epoch,
      scope: 'task_owned_descendants',
      captured_at_milliseconds: Date.now(),
      collector_sha256: sha256(collectorBytes),
      complete: true,
      roots: spec.roots,
      processes,
    });
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}

function invokedAsScript() {
  return process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
}

if (invokedAsScript()) {
  try {
    if (process.argv[2] === '--self-test') {
      const fixture = new Map([[10, 1], [11, 10], [12, 11], [20, 1]]);
      requireCondition(JSON.stringify(descendantPIDs(fixture, [10])) === JSON.stringify([10, 11, 12]),
        'descendant self-test failed');
      process.stdout.write('{"version":1,"passed":true}\n');
    } else {
      const options = parseOptions(process.argv.slice(2), ['spec', 'monitor', 'output']);
      const result = collectProcessTree(options.spec, options.monitor, options.output);
      process.stdout.write(`${JSON.stringify({ output: options.output, sha256: result.sha256 })}\n`);
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
