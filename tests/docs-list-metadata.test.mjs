import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

function runListing(t, files) {
  const root = mkdtempSync(path.join(os.tmpdir(), 'peekaboo-docs-list-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(path.join(root, 'scripts'));
  mkdirSync(path.join(root, 'docs'));
  copyFileSync(process.env.DOCS_LIST_SCRIPT || new URL('../scripts/docs-list.mjs', import.meta.url), path.join(root, 'scripts/docs-list.mjs'));
  for (const [file, contents] of Object.entries(files)) writeFileSync(path.join(root, 'docs', file), contents);
  const result = spawnSync(process.execPath, [path.join(root, 'scripts/docs-list.mjs')], { encoding: 'utf8', timeout: 10000 });
  assert.equal(result.error, undefined);
  assert.equal(result.signal, null);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, '');
  return result.stdout;
}

const document = (summary, readWhen) => `---\nsummary: ${summary}\nread_when: ${readWhen}\n---\n# Fixture\n`;

test('documentation listing preserves apostrophes in JSON read_when entries', (t) => {
  const stdout = runListing(t, {
    'quoted.md': document('Quoted hints', JSON.stringify(["you can't connect", "read the 'quoted' hint"])),
    'legacy.md': document('Legacy hints', "['legacy string']"),
    'malformed.md': document('Invalid hints', '[bad input]'),
  });
  assert.ok(stdout.includes("Read when: you can't connect; read the 'quoted' hint"), stdout);
  assert.match(stdout, /Read when: legacy string/);
  assert.match(stdout, /malformed\.md - Invalid hints \[read_when inline array malformed\]/);
  assert.doesNotMatch(stdout, /quoted\.md[^\n]*malformed/);
});

test('JSON hint escapes and Unicode survive while nonstrings and blank hints are ignored', (t) => {
  const hints = [' quote "inside" ', 'path\\folder', '🐱 café', '', '  ', 42, null, false, { nested: 'ignore' }];
  const stdout = runListing(t, { 'hints.md': document('Escaped hints', JSON.stringify(hints)) });
  assert.ok(stdout.includes('hints.md - Escaped hints\n  Read when: quote "inside"; path\\folder; 🐱 café\n'), stdout);
  assert.doesNotMatch(stdout, /malformed|nested|\[object Object\]/);
});

test('empty inline arrays and multiline lists retain their existing meaning', (t) => {
  const stdout = runListing(t, {
    'empty.md': document('Empty hints', '[]'),
    'multiline.md': document('Multiline hints', '\n  - first condition\n  - second condition'),
  });
  assert.match(stdout, /empty\.md - Empty hints\nmultiline\.md - Multiline hints\n  Read when: first condition; second condition\n/);
  assert.doesNotMatch(stdout, /malformed/);
});

test('hosted and safe gates both execute the documentation-listing regressions', () => {
  const workflow = readFileSync(new URL('../.github/workflows/macos-ci.yml', import.meta.url), 'utf8');
  const packageJSON = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
  const step = workflow.split('      - name: Docs lint\n')[1]?.split('\n      - name:')[0];
  assert.ok(step?.includes('pnpm run test:docs\n'));
  assert.match(packageJSON.scripts['test:safe'], /pnpm run test:docs &&/);
  assert.match(packageJSON.scripts['test:safe'], /pnpm run test:log-scripts &&/);
  assert.equal(packageJSON.scripts['test:docs'], 'node --test tests/docs-list-metadata.test.mjs');
  for (const [, name] of packageJSON.scripts['test:safe'].matchAll(/\bpnpm run ([\w:-]+)/g)) {
    assert.ok(packageJSON.scripts[name], `Safe gate references a missing package script: ${name}`);
  }
});
