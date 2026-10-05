import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

test('documentation listing preserves apostrophes in JSON read_when entries', (t) => {
  const root = mkdtempSync(path.join(os.tmpdir(), 'peekaboo-docs-list-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(path.join(root, 'scripts'));
  mkdirSync(path.join(root, 'docs'));
  copyFileSync(new URL('../scripts/docs-list.mjs', import.meta.url), path.join(root, 'scripts/docs-list.mjs'));
  writeFileSync(path.join(root, 'docs/quoted.md'),
    '---\nsummary: Quoted hints\nread_when: ["you can\'t connect", "read the \'quoted\' hint"]\n---\n# Quoted\n');
  writeFileSync(path.join(root, 'docs/legacy.md'),
    "---\nsummary: Legacy hints\nread_when: ['legacy string']\n---\n# Legacy\n");
  writeFileSync(path.join(root, 'docs/malformed.md'),
    '---\nsummary: Invalid hints\nread_when: [bad input]\n---\n# Invalid\n');
  const result = spawnSync(process.execPath, [path.join(root, 'scripts/docs-list.mjs')], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.stdout.includes("Read when: you can't connect; read the 'quoted' hint"), result.stdout);
  assert.match(result.stdout, /Read when: legacy string/);
  assert.match(result.stdout, /malformed\.md - Invalid hints \[read_when inline array malformed\]/);
  assert.doesNotMatch(result.stdout, /quoted\.md[^\n]*malformed/);
});
