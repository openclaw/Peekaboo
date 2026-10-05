import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

export function logScriptFixture(t, script) {
  const directory = mkdtempSync(path.join(tmpdir(), 'peekaboo-log-script-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const argsPath = path.join(directory, 'log-args');
  const sudoArgsPath = path.join(directory, 'sudo-args');
  writeFileSync(path.join(directory, 'log'), `#!/bin/bash
printf '%s\\0' "$@" > "$PBLOG_TEST_ARGS"
printf 'first\\nsecond\\nthird\\n'
exit "\${PBLOG_TEST_EXIT:-0}"
`, { mode: 0o755 });
  writeFileSync(path.join(directory, 'sudo'), `#!/bin/bash
printf '%s\\0' "$@" > "$PBLOG_TEST_SUDO_ARGS"
[[ "$1" == -n && "$2" == log ]] || exit 99
[[ "$PBLOG_TEST_SUDO_EXIT" == 0 ]] || exit "$PBLOG_TEST_SUDO_EXIT"
shift 2
exec log "$@"
`, { mode: 0o755 });
  const readArgs = (file) => existsSync(file) ? readFileSync(file, 'utf8').split('\0').slice(0, -1) : [];
  return {
    directory,
    args: () => readArgs(argsPath),
    sudoArgs: () => readArgs(sudoArgsPath),
    run: (args, environment = {}) => spawnSync('/bin/bash', [script, ...args], {
      cwd: directory,
      encoding: 'utf8',
      timeout: 3000,
      env: {
        ...process.env,
        PATH: `${directory}:${process.env.PATH}`,
        PBLOG_TEST_ARGS: argsPath,
        PBLOG_TEST_SUDO_ARGS: sudoArgsPath,
        PBLOG_TEST_EXIT: '0',
        PBLOG_TEST_SUDO_EXIT: '0',
        ...environment,
      },
    }),
  };
}

export function success(result) {
  assert.equal(result.error, undefined);
  assert.equal(result.signal, null);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, '');
}

export async function streamBeforeRelease(t, script, { outputFile, json }) {
  const f = logScriptFixture(t, script);
  const outputPath = path.join(f.directory, 'live.log');
  const event = json ? '{"event":"owned live event"}' : 'owned live event';
  writeFileSync(path.join(f.directory, 'log'), `#!/bin/bash
printf '%s\\n' '${event}'
IFS= read -r release
[[ "$release" == release ]] || exit 91
`, { mode: 0o755 });
  const child = spawn('/bin/bash', [script, '--follow', '--lines', '1', ...(json ? ['--json'] : []), ...(outputFile ? ['--output', outputPath] : [])], {
    cwd: f.directory, env: { ...process.env, PATH: `${f.directory}:${process.env.PATH}` },
    detached: true, stdio: ['pipe', 'pipe', 'pipe'],
  });
  let stdout = '', stderr = '', closed = false, released = false, observedBeforeRelease = false;
  const completion = new Promise((resolve) => {
    child.once('error', (error) => resolve({ error }));
    child.once('close', (code, signal) => { closed = true; resolve({ code, signal }); });
  });
  const killOwnedGroup = () => {
    if (closed || !Number.isInteger(child.pid)) return;
    try { process.kill(-child.pid, 'SIGKILL'); }
    catch (error) { if (error.code !== 'ESRCH') throw error; }
  };
  const release = (observed) => {
    if (released || closed) return;
    released = true;
    observedBeforeRelease = observed;
    child.stdin.end('release\n');
  };
  const readOutput = () => existsSync(outputPath) ? readFileSync(outputPath, 'utf8') : '';
  const observe = () => {
    if ((outputFile ? readOutput() : stdout).includes(`${event}\n`)) release(true);
  };
  child.stdin.on('error', () => {});
  child.stdout.on('data', (chunk) => { stdout += chunk; observe(); });
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  const poll = outputFile ? setInterval(observe, 10) : undefined;
  // Release an EOF-buffering pipeline on failure; this is not a latency assertion.
  const fallback = setTimeout(() => release(false), 3000);
  const deadline = setTimeout(killOwnedGroup, 5000);
  t.after(killOwnedGroup);
  let result;
  try { result = await completion; }
  finally { clearInterval(poll); clearTimeout(fallback); clearTimeout(deadline); killOwnedGroup(); }
  return { ...result, stdout, stderr, file: readOutput(), observedBeforeRelease, event, outputPath };
}
