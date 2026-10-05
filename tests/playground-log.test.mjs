import assert from 'node:assert/strict';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { logScriptFixture, streamBeforeRelease, success } from './fixtures/log-script.mjs';

const script = process.env.PLAYGROUND_LOG_SCRIPT || fileURLToPath(new URL('../Apps/Playground/scripts/playground-log.sh', import.meta.url));
const fixture = (t) => logScriptFixture(t, script);
const subsystem = 'subsystem == "boo.peekaboo.playground"';
const header = (mode) => `\u001b[0;34mPeekaboo Playground Log Viewer\u001b[0m\nSubsystem: boo.peekaboo.playground\n${mode}\n---\n`;

test('literal predicates retain quotes, slashes, shell text and trailing newlines', (t) => {
  const f = fixture(t);
  const literal = 'can\'t "quote" \\path; $(touch accidental) `touch accidental`\n\n';
  const escaped = 'can\'t \\"quote\\" \\\\path; $(touch accidental) `touch accidental`\n\n';
  success(f.run(['--json', '--all', '--category', literal, '--search', literal, '--last', '10 m']));
  assert.deepEqual(f.args(), ['show', '--predicate', `${subsystem} AND category == "${escaped}" AND eventMessage CONTAINS[c] "${escaped}"`, '--info', '--last', '10 m', '--style', 'json']);
  assert.equal(existsSync(path.join(f.directory, 'accidental')), false);
});

test('historical debug and error queries use native severity flags', (t) => {
  const f = fixture(t);
  success(f.run(['--all', '--debug']));
  assert.deepEqual(f.args(), ['show', '--predicate', subsystem, '--debug', '--last', '5m']);
  success(f.run(['--all', '--errors']));
  assert.deepEqual(f.args(), ['show', '--predicate', `${subsystem} AND logType == "error"`, '--info', '--debug', '--last', '5m']);
});

test('follow uses stream with level and JSON arguments', (t) => {
  const f = fixture(t);
  success(f.run(['--follow', '--debug', '--json']));
  assert.deepEqual(f.args(), ['stream', '--predicate', subsystem, '--level', 'debug', '--style', 'json']);
});

const valueOptions = ['-n', '--lines', '-l', '--last', '-c', '--category', '-s', '--search', '-o', '--output'];
for (const option of valueOptions) {
  test(`missing value for ${option} refuses before reading logs`, (t) => {
    const f = fixture(t);
    const result = f.run([option]);
    assert.equal(result.error, undefined);
    assert.equal(result.signal, null);
    assert.equal(result.status, 2);
    assert.equal(result.stdout, '');
    assert.equal(result.stderr, `playground-log.sh: ${option} requires a value\n`);
    assert.deepEqual(f.args(), []);
    assert.deepEqual(f.sudoArgs(), []);
  });

  test(`supplied values for ${option} preserve parsing before help`, (t) => {
    const f = fixture(t);
    for (const value of ['fixture', '', '-literal']) {
      const result = f.run([option, value, '--help']);
      success(result);
      assert.match(result.stdout, /^Peekaboo Playground Log Viewer\nUsage:/);
      assert.deepEqual(f.args(), []);
      assert.deepEqual(f.sudoArgs(), []);
    }
  });
}

test('trailing missing value fails after valid options before log access', (t) => {
  const f = fixture(t);
  const result = f.run(['--debug', '--last', '5m', '--search', 'literal text', '--output']);
  assert.equal(result.error, undefined);
  assert.equal(result.signal, null);
  assert.equal(result.status, 2);
  assert.equal(result.stdout, '');
  assert.equal(result.stderr, 'playground-log.sh: --output requires a value\n');
  assert.deepEqual(f.args(), []);
});

for (const outputFile of [false, true]) {
  for (const all of [false, true]) {
    for (const fails of [false, true]) {
      test(`${fails ? 'failed' : 'successful'} query to ${outputFile ? 'file' : 'stdout'} with ${all ? 'all' : 'tail'}`, (t) => {
        const f = fixture(t);
        const output = path.join(f.directory, 'output with spaces; $(touch accidental).log');
        const result = f.run([...(all ? ['--all'] : ['--lines', '2']), ...(outputFile ? ['--output', output] : [])], { PBLOG_TEST_EXIT: fails ? '7' : '0' });
        assert.equal(result.error, undefined);
        assert.equal(result.signal, null);
        assert.equal(result.status, fails ? 7 : 0);
        assert.equal(result.stderr, '');
        const rows = all ? 'first\nsecond\nthird\n' : 'second\nthird\n';
        if (outputFile) {
          assert.equal(readFileSync(output, 'utf8'), rows);
          assert.equal(result.stdout, fails ? '' : `${all ? 'Logs' : 'Last 2 lines'} saved to: ${output}\n`);
        } else {
          assert.equal(result.stdout, header(`Time range: 5m\nLines: ${all ? 'all' : '2'}`) + rows);
        }
        assert.equal(existsSync(path.join(f.directory, 'accidental')), false);
      });
    }
  }
}

test('redirection and tail errors never print a save confirmation', (t) => {
  const f = fixture(t);
  const badOutput = path.join(f.directory, 'log', 'not-a-directory');
  for (const args of [
    ['--output', badOutput], ['--all', '--output', badOutput],
    ['--lines', 'not-a-count'], ['--lines', 'not-a-count', '--output', path.join(f.directory, 'bad-tail.log')],
  ]) {
    const result = f.run(args);
    assert.equal(result.error, undefined);
    assert.equal(result.signal, null);
    assert.notEqual(result.status, 0);
    assert.notEqual(result.stderr, '');
    assert.doesNotMatch(result.stdout, /saved to:/);
  }
});

test('category colors preserve log-body backslash escapes and echo flags', (t) => {
  const f = fixture(t);
  const colors = { Click: '0;34', Text: '0;32', Menu: '0;35', Window: '1;33', Scroll: '0;36', Space: '0;36', Drag: '0;31', Keyboard: '1;33', Focus: '0;34', Gesture: '0;31', Control: '0;32', App: '0;35', MCP: '0;36' };
  const rows = Object.entries(colors).map(([category, color]) => {
    const line = `[${category}] literal \\c \\n \\033[31m`;
    return { line, formatted: `\u001b[${color}m${line}\u001b[0m` };
  });
  for (const line of ['-n', 'plain \\c \\n']) rows.push({ line, formatted: line });
  writeFileSync(path.join(f.directory, 'log'), `#!/bin/bash\ncat <<'ROWS'\n${rows.map(row => row.line).join('\n')}\nROWS\n`, { mode: 0o755 });
  const result = f.run(['--all']);
  success(result);
  assert.equal(result.stdout, header('Time range: 5m\nLines: all') + rows.map(row => row.formatted).join('\n') + '\n');
});

test('category listing remains available without a log query', (t) => {
  const f = fixture(t);
  const result = f.run(['--categories']);
  success(result);
  assert.match(result.stdout, /^Available log categories for Peekaboo Playground:/);
  for (const category of ['Click', 'Text', 'Space', 'MCP']) assert.ok(result.stdout.includes(category));
  assert.deepEqual(f.args(), []);
});

for (const outputFile of [false, true]) {
  test(`JSON frame exceeding 50 lines survives ${outputFile ? 'file' : 'stdout'} output`, (t) => {
    const f = fixture(t);
    const json = JSON.stringify(Array.from({ length: 60 }, (_, index) => ({ index })), null, 2) + '\n';
    writeFileSync(path.join(f.directory, 'log'), `#!/bin/bash\ncat <<'JSON'\n${json}JSON\n`, { mode: 0o755 });
    const output = path.join(f.directory, 'structured.json');
    const result = f.run(['--json', ...(outputFile ? ['--output', output] : [])]);
    success(result);
    assert.equal(outputFile ? readFileSync(output, 'utf8') : result.stdout, json);
    if (outputFile) assert.equal(result.stdout, `Logs saved to: ${output}\n`);
  });

  for (const json of [false, true]) {
    test(`follow forwards ${json ? 'JSON' : 'text'} to ${outputFile ? 'file' : 'stdout'} before releasing the producer`, async (t) => {
      const result = await streamBeforeRelease(t, script, { outputFile, json });
      assert.equal(result.error, undefined);
      assert.equal(result.signal, null);
      assert.equal(result.code, 0, result.stderr);
      assert.equal(result.stderr, '');
      assert.equal(result.observedBeforeRelease, true, 'Event was withheld until the producer was released');
      if (outputFile) {
        assert.equal(result.file, `${result.event}\n`);
        assert.equal(result.stdout, `Logs saved to: ${result.outputPath}\n`);
      } else {
        assert.equal(result.stdout, (json ? '' : header('Mode: streaming (no line limit)')) + `${result.event}\n`);
      }
    });
  }
}
