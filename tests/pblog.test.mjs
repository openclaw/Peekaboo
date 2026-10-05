import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const script = process.env.PBLOG_SCRIPT || fileURLToPath(new URL('../scripts/pblog.sh', import.meta.url));

function fixture(t) {
  const directory = mkdtempSync(path.join(tmpdir(), 'peekaboo-pblog-'));
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
        ...environment,
      },
    }),
  };
}

function success(result) {
  assert.equal(result.error, undefined);
  assert.equal(result.signal, null);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, '');
}

test('literal predicates retain apostrophes, quotes, slashes, shell text and trailing newlines', (t) => {
  const f = fixture(t);
  const literal = 'can\'t "quote" \\path; $(touch accidental) `touch accidental`\n\n';
  const escaped = 'can\'t \\"quote\\" \\\\path; $(touch accidental) `touch accidental`\n\n';
  success(f.run(['--all', '--subsystem', literal, '--category', literal, '--search', literal, '--last', '10 m', '--json']));
  assert.deepEqual(f.args(), ['show', '--predicate', `subsystem == "${escaped}" AND category == "${escaped}" AND eventMessage CONTAINS[c] "${escaped}"`, '--info', '--last', '10 m', '--style', 'json']);
  assert.equal(existsSync(path.join(f.directory, 'accidental')), false);
});

test('historical debug and error queries preserve flags and mock-only sudo', (t) => {
  const f = fixture(t);
  success(f.run(['--all', '--debug', '--subsystem', 'boo.test']));
  assert.deepEqual(f.args(), ['show', '--predicate', 'subsystem == "boo.test"', '--debug', '--last', '5m']);
  success(f.run(['--private', '--all', '--errors', '--subsystem', 'boo.test']));
  const expected = ['show', '--predicate', 'subsystem == "boo.test" AND eventType == "error"', '--info', '--debug', '--last', '5m'];
  assert.deepEqual(f.args(), expected);
  assert.deepEqual(f.sudoArgs(), ['-n', 'log', ...expected]);
});

test('follow uses stream with level and JSON arguments', (t) => {
  const f = fixture(t);
  success(f.run(['--follow', '--all', '--debug', '--subsystem', 'boo.test', '--json']));
  assert.deepEqual(f.args(), ['stream', '--predicate', 'subsystem == "boo.test"', '--level', 'debug', '--style', 'json']);
});

for (const outputFile of [false, true]) {
  for (const all of [false, true]) {
    test(`output ${outputFile ? 'file' : 'stdout'} with ${all ? 'all rows' : 'tail limit'}`, (t) => {
      const f = fixture(t);
      const output = path.join(f.directory, 'output with spaces; $(touch accidental).log');
      const result = f.run([...(all ? ['--all'] : ['--lines', '2']), ...(outputFile ? ['--output', output] : [])]);
      success(result);
      assert.equal(outputFile ? readFileSync(output, 'utf8') : result.stdout, all ? 'first\nsecond\nthird\n' : 'second\nthird\n');
      if (outputFile) assert.equal(result.stdout, '');
      assert.equal(existsSync(path.join(f.directory, 'accidental')), false);
    });
  }
}

test('unpiped log exit status is preserved', (t) => {
  const result = fixture(t).run(['--all'], { PBLOG_TEST_EXIT: '7' });
  assert.equal(result.error, undefined);
  assert.equal(result.signal, null);
  assert.equal(result.status, 7);
});

for (const outputFile of [false, true]) {
  test(`JSON output retains its complete frame in ${outputFile ? 'a file' : 'stdout'}`, (t) => {
    const f = fixture(t);
    const json = JSON.stringify(Array.from({ length: 60 }, (_, index) => ({ index })), null, 2) + '\n';
    writeFileSync(path.join(f.directory, 'log'), `#!/bin/bash\ncat <<'JSON'\n${json}JSON\n`, { mode: 0o755 });
    const output = path.join(f.directory, 'structured.json');
    const result = f.run(['--json', ...(outputFile ? ['--output', output] : [])]);
    success(result);
    assert.deepEqual(JSON.parse(outputFile ? readFileSync(output, 'utf8') : result.stdout), JSON.parse(json));
  });
}

test('follow emits an event before the long-lived log child exits', async (t) => {
  const f = fixture(t);
  writeFileSync(path.join(f.directory, 'log'), '#!/bin/bash\nprintf "owned live event\\n"\nsleep 2\n', { mode: 0o755 });
  const child = spawn('/bin/bash', [script, '--follow'], {
    cwd: f.directory, env: { ...process.env, PATH: `${f.directory}:${process.env.PATH}` },
    stdio: ['ignore', 'pipe', 'ignore']
  });
  const started = Date.now();
  let output = '';
  let firstEventMs;
  child.stdout.on('data', (chunk) => {
    output += chunk;
    if (output.includes('owned live event') && firstEventMs === undefined) firstEventMs = Date.now() - started;
  });
  const status = await new Promise((resolve, reject) => { child.on('exit', resolve); child.on('error', reject); });
  assert.equal(status, 0);
  assert.ok(firstEventMs < 1500, `event was withheld until ${firstEventMs}ms`);
});
