import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

const guide = readFileSync(new URL('../docs/integrations/subprocess.md', import.meta.url), 'utf8');
const snippets = [...guide.matchAll(/```javascript\n([\s\S]*?)\n```/g)].map((match) => match[1]);
assert.equal(snippets.length, 2, 'exercise every JavaScript example in the guide');
const loadSnippet = (source) => import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const { createPeekabooRunner } = await loadSnippet(snippets[0]);
const { replaceField } = await loadSnippet(snippets[1]);

function fixture(t, scenario = 'normal') {
  const directory = mkdtempSync(join(tmpdir(), 'peekaboo-subprocess-guide-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const executable = join(directory, 'inert peekaboo.mjs');
  const log = join(directory, 'calls.jsonl');
  writeFileSync(executable, `#!${process.execPath}
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
const log = ${JSON.stringify(log)};
const scenario = ${JSON.stringify(scenario)};
const args = process.argv.slice(2);
appendFileSync(log, JSON.stringify(args) + '\\n');
const calls = readFileSync(log, 'utf8').trim().split('\\n').map(JSON.parse);
let response = { success: true, data: { args } };
let exitCode = 0;
if (args[0] === 'failure' || args[0] === 'exit-zero-failure' ||
    (scenario === 'click-failure' && args[0] === 'click') ||
    (scenario === 'type-failure' && args[0] === 'type')) {
  response = {
    success: false,
    error: { code: 'AGENT_ERROR', message: 'Synthetic partial execution',
      mutation_dispatched: true, retry_safe: false },
    data: { maxSteps: 1, executionTrace: { entries: [{ disposition: 'executed/failed' }] } },
  };
  exitCode = args[0] === 'exit-zero-failure' ? 0 : 1;
  writeFileSync(2, 'supplemental diagnostic '.repeat(200));
} else if (args[0] === 'nonzero-success') {
  exitCode = 7;
} else if (args[0] === 'see') {
  const observation = calls.filter((call) => call[0] === 'see').length;
  const element = { id: 'opaque-field-' + observation, identifier: 'report' };
  response.data = {
    snapshot_id: 'ps1_' + String(observation).padStart(32, '0'),
    snapshot_reusable: scenario !== 'partial',
    mutation_targeting_available: scenario !== 'partial',
    ui_elements: scenario === 'ambiguous' ? [element, element] : [element],
    focused_element: { identifier: scenario === 'wrong-focus' ? 'other' : 'report' },
  };
}
if (args[0] === 'wait') {
  setTimeout(() => process.exit(0), 60_000);
} else {
  const output = args[0] === 'invalid' ? 'not JSON' :
    args[0] === 'overflow' ? 'x'.repeat(16_384) : JSON.stringify(response);
  writeFileSync(1, output);
  process.exit(exitCode);
}
`, { mode: 0o700 });
  return {
    directory,
    executable,
    calls: () => existsSync(log) ? readFileSync(log, 'utf8').trim().split('\n').map(JSON.parse) : [],
  };
}

test('subprocess runner preserves literal argv, Unicode, host paths, and command ordering', async (t) => {
  const stub = fixture(t);
  const marker = join(stub.directory, 'must-not-exist');
  const text = `--foreground 雪 🦞 "quoted" 'single' $HOME $(touch ${marker}); | &`;
  const socket = join(stub.directory, 'host with spaces.sock');
  const run = createPeekabooRunner(stub.executable, { bridgeSocket: socket });
  const response = await run(['type'], ['--snapshot', 'ps1_' + 'a'.repeat(32), '--', text]);
  assert.deepEqual(response.data.args, [
    'type', '--json', '--bridge-socket', socket, '--snapshot', 'ps1_' + 'a'.repeat(32), '--', text,
  ]);
  assert.equal(existsSync(marker), false);
  assert.equal(stub.calls().length, 1);

  const inventory = await run(['window', 'list'], ['--app', 'My App']);
  assert.deepEqual(inventory.data.args, ['window', 'list', '--json', '--bridge-socket', socket, '--app', 'My App']);
  assert.throws(() => createPeekabooRunner('peekaboo'), /absolute/);
});

for (const command of ['failure', 'exit-zero-failure']) {
  test(`subprocess runner retains structured stdout failure for ${command} without replay`, async (t) => {
    const stub = fixture(t);
    await assert.rejects(createPeekabooRunner(stub.executable)([command]), (error) => {
      assert.equal(error.response.success, false);
      assert.equal(error.response.error.code, 'AGENT_ERROR');
      assert.equal(error.response.error.mutation_dispatched, true);
      assert.equal(error.response.error.retry_safe, false);
      assert.deepEqual(error.response.data.executionTrace.entries, [{ disposition: 'executed/failed' }]);
      assert.equal(error.process.exitCode, command === 'failure' ? 1 : 0);
      assert.equal(error.stderr.length, 2048);
      return true;
    });
    assert.equal(stub.calls().length, 1);
  });
}

test('subprocess runner rejects nonzero success envelopes and malformed output', async (t) => {
  const stub = fixture(t);
  const run = createPeekabooRunner(stub.executable);
  await assert.rejects(run(['nonzero-success']), (error) => {
    assert.equal(error.response.success, true);
    assert.equal(error.process.exitCode, 7);
    return true;
  });
  await assert.rejects(run(['invalid']), (error) => {
    assert.equal(error.response, undefined);
    assert.equal(error.process.exitCode, 0);
    return true;
  });
  assert.deepEqual(stub.calls().map((call) => call[0]), ['nonzero-success', 'invalid']);
});

test('subprocess runner refuses bounded-output, timeout, and launch failures without retry', async (t) => {
  const stub = fixture(t);
  await assert.rejects(createPeekabooRunner(stub.executable, { maxBuffer: 512 })(['overflow']), (error) => {
    assert.equal(error.process.code, 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER');
    assert.equal(error.response, undefined);
    return true;
  });
  await assert.rejects(createPeekabooRunner(stub.executable, { timeoutMs: 1000 })(['wait']), (error) => {
    assert.equal(error.process.killed, true);
    assert.equal(error.process.signal, 'SIGTERM');
    return true;
  });
  assert.deepEqual(stub.calls().map((call) => call[0]), ['overflow', 'wait']);
  await assert.rejects(createPeekabooRunner(join(stub.directory, 'missing'))(['see']), (error) => {
    assert.equal(error.process.code, 'ENOENT');
    assert.equal(error.response, undefined);
    return true;
  });
});

const fieldTask = { app: 'Synthetic App', windowId: 42, fieldIdentifier: 'report', text: '--literal \\n 雪 🦞' };

test('field example validates required text and identifier before invoking a command', async (t) => {
  const stub = fixture(t);
  const run = createPeekabooRunner(stub.executable);
  for (const invalid of [{ fieldIdentifier: '' }, { fieldIdentifier: undefined }, { text: undefined }]) {
    await assert.rejects(replaceField(run, { ...fieldTask, ...invalid }), /identifier and replacement text/);
  }
  assert.deepEqual(stub.calls(), []);
});

test('field example uses fresh producer references and literal positional typing', async (t) => {
  const stub = fixture(t);
  const final = await replaceField(createPeekabooRunner(stub.executable), fieldTask);
  const calls = stub.calls();
  assert.deepEqual(calls.map((call) => call[0]), ['see', 'click', 'see', 'type', 'see']);
  const snapshot = (call) => call[call.indexOf('--snapshot') + 1];
  assert.equal(snapshot(calls[1]), 'ps1_' + '1'.padStart(32, '0'));
  assert.equal(snapshot(calls[3]), 'ps1_' + '2'.padStart(32, '0'));
  assert.equal(final.data.snapshot_id, 'ps1_' + '3'.padStart(32, '0'));
  assert.deepEqual(calls[3].slice(-2), ['--', fieldTask.text.replaceAll('\\', '\\\\')]);
  assert.ok(calls.filter((call) => call[0] === 'see').every((call) => call.includes('--no-screenshot')));
  assert.ok(calls.every((call) => !call.includes('--foreground') && !call.includes('--no-remote')));
});

for (const [scenario, expected] of [
  ['partial', ['see']],
  ['ambiguous', ['see']],
  ['click-failure', ['see', 'click']],
  ['wrong-focus', ['see', 'click', 'see']],
  ['type-failure', ['see', 'click', 'see', 'type']],
]) {
  test(`field example stops at ${scenario} without another mutation`, async (t) => {
    const stub = fixture(t, scenario);
    await assert.rejects(replaceField(createPeekabooRunner(stub.executable), fieldTask));
    assert.deepEqual(stub.calls().map((call) => call[0]), expected);
  });
}
