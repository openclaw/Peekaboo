import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const script = fileURLToPath(new URL('../Apps/Playground/scripts/playground-log.sh', import.meta.url));
function fixture(t) {
  const directory = mkdtempSync(path.join(tmpdir(), 'peekaboo-playground-logs-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const argsFile = path.join(directory, 'arguments');
  writeFileSync(path.join(directory, 'log'), `#!/bin/bash
printf '%s\\0' "$@" > "$OWNED_LOG_ARGS"
printf 'first\\nsecond\\nthird\\n'
exit "\${OWNED_LOG_EXIT:-0}"
`, { mode: 0o755 });
  return {
    directory,
    arguments: () => readFileSync(argsFile, 'utf8').split('\0').slice(0, -1),
    run: (args, exit = '0') => spawnSync('/bin/bash', [script, ...args], {
      cwd: directory, encoding: 'utf8', timeout: 2000,
      env: { ...process.env, PATH: `${directory}:${process.env.PATH}`, OWNED_LOG_ARGS: argsFile, OWNED_LOG_EXIT: exit }
    })
  };
}
test('predicate values and timing stay literal argv', (t) => {
  const f = fixture(t);
  const value = `can't "quote" \\path with spaces`;
  const result = f.run(['--json', '--all', '--category', value, '--search', value, '--last', '10 m']);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, '');
  const escaped = value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  assert.deepEqual(f.arguments(), ['show', '--predicate', `subsystem == "boo.peekaboo.playground" AND category == "${escaped}" AND eventMessage CONTAINS[c] "${escaped}"`, '--info', '--last', '10 m', '--style', 'json']);
});
for (const flag of ['--lines', '--last', '--category', '--search', '--output']) {
  test(`${flag} without a value fails promptly`, (t) => {
    const result = fixture(t).run([flag]);
    assert.equal(result.error, undefined);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /requires a value/);
  });
}
test('failed log query remains nonzero through the formatting pipeline', (t) => {
  const result = fixture(t).run([], '7');
  assert.equal(result.status, 7);
});
