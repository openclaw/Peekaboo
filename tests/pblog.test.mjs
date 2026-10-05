import assert from 'node:assert/strict';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { logScriptFixture, streamBeforeRelease, success } from './fixtures/log-script.mjs';

const script = process.env.PBLOG_SCRIPT || fileURLToPath(new URL('../scripts/pblog.sh', import.meta.url));

function fixture(t) {
  return logScriptFixture(t, script);
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
  const expected = ['show', '--predicate', 'subsystem == "boo.test" AND logType == "error"', '--info', '--debug', '--last', '5m'];
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

for (const outputFile of [false, true]) {
  for (const all of [false, true]) {
    for (const privateMode of [false, true]) {
      test(`log failure survives ${outputFile ? 'file' : 'stdout'} / ${all ? 'all' : 'tail'} / ${privateMode ? 'private' : 'normal'}`, (t) => {
        const f = fixture(t);
        const output = path.join(f.directory, 'failed.log');
        const args = [...(all ? ['--all'] : ['--lines', '2']), ...(outputFile ? ['--output', output] : []), ...(privateMode ? ['--private'] : [])];
        const result = f.run(args, { PBLOG_TEST_EXIT: '7' });
        assert.equal(result.error, undefined);
        assert.equal(result.signal, null);
        assert.equal(result.status, 7);
        assert.equal(result.stderr, '');
        assert.equal(outputFile ? readFileSync(output, 'utf8') : result.stdout, all ? 'first\nsecond\nthird\n' : 'second\nthird\n');
      });
    }
    test(`mock sudo refusal survives ${outputFile ? 'file' : 'stdout'} / ${all ? 'all' : 'tail'}`, (t) => {
      const f = fixture(t);
      const result = f.run(['--private', ...(all ? ['--all'] : ['--lines', '2']), ...(outputFile ? ['--output', path.join(f.directory, 'denied.log')] : [])], { PBLOG_TEST_SUDO_EXIT: '9' });
      assert.equal(result.error, undefined);
      assert.equal(result.signal, null);
      assert.equal(result.status, 9);
      assert.deepEqual(f.args(), []);
      assert.equal(result.stdout, '');
    });
  }
}

test('output redirection and tail failures remain failures', (t) => {
  const f = fixture(t);
  for (const args of [['--output', path.join(f.directory, 'log', 'not-a-directory')], ['--lines', 'not-a-count']]) {
    const result = f.run(args);
    assert.equal(result.error, undefined);
    assert.equal(result.signal, null);
    assert.notEqual(result.status, 0);
    assert.notEqual(result.stderr, '');
  }
});

const valueOptions = ['-n', '--lines', '-l', '--last', '-c', '--category', '-s', '--search', '-o', '--output', '--subsystem'];
for (const option of valueOptions) {
  test(`missing value for ${option}`, (t) => {
    const f = fixture(t);
    const result = f.run([option]);
    assert.equal(result.error, undefined, 'The parser must terminate before the subprocess timeout');
    assert.equal(result.signal, null);
    assert.equal(result.status, 2);
    assert.equal(result.stdout, '');
    assert.equal(result.stderr, `${option} requires a value\n`);
    assert.deepEqual(f.args(), []);
    assert.deepEqual(f.sudoArgs(), []);
  });

  test(`supplied values for ${option} preserve parsing before help`, (t) => {
    const f = fixture(t);
    for (const value of ['fixture', '', '-literal']) {
      const result = f.run([option, value, '--help']);
      success(result);
      assert.match(result.stdout, /^Usage: pblog.sh/);
      assert.deepEqual(f.args(), []);
      assert.deepEqual(f.sudoArgs(), []);
    }
  });
}

test('a trailing missing value fails after preceding valid options, before private log access', (t) => {
  const f = fixture(t);
  const result = f.run(['--private', '--debug', '--last', '5m', '--search', 'literal text', '--output']);
  assert.equal(result.error, undefined);
  assert.equal(result.signal, null);
  assert.equal(result.status, 2);
  assert.equal(result.stdout, '');
  assert.equal(result.stderr, '--output requires a value\n');
  assert.deepEqual(f.args(), []);
  assert.deepEqual(f.sudoArgs(), []);
});

for (const outputFile of [false, true]) {
  test(`JSON output retains its complete frame in ${outputFile ? 'a file' : 'stdout'}`, (t) => {
    const f = fixture(t);
    const json = JSON.stringify(Array.from({ length: 60 }, (_, index) => ({ index })), null, 2) + '\n';
    writeFileSync(path.join(f.directory, 'log'), `#!/bin/bash\ncat <<'JSON'\n${json}JSON\n`, { mode: 0o755 });
    const output = path.join(f.directory, 'structured.json');
    const result = f.run(['--json', ...(outputFile ? ['--output', output] : [])]);
    success(result);
    assert.equal(outputFile ? readFileSync(output, 'utf8') : result.stdout, json);
    assert.deepEqual(JSON.parse(outputFile ? readFileSync(output, 'utf8') : result.stdout), JSON.parse(json));
  });
}

for (const outputFile of [false, true]) {
  for (const json of [false, true]) {
    test(`follow forwards ${json ? 'JSON' : 'text'} to ${outputFile ? 'a file' : 'stdout'} before releasing the producer`, async (t) => {
      const result = await streamBeforeRelease(t, script, { outputFile, json });
      assert.equal(result.error, undefined);
      assert.equal(result.signal, null);
      assert.equal(result.code, 0, result.stderr);
      assert.equal(result.stderr, '');
      assert.equal(result.observedBeforeRelease, true, 'Event was withheld until the test released its producer');
      assert.equal(outputFile ? result.file : result.stdout, `${result.event}\n`);
      if (outputFile) assert.equal(result.stdout, '');
    });
  }
}
