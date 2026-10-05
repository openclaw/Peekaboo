import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const builder = fileURLToPath(new URL('../scripts/build-docs-site.mjs', import.meta.url));
test('repeated headings retain distinct permalink and TOC targets across blockquotes', (t) => {
  const root = mkdtempSync(path.join(os.tmpdir(), 'peekaboo-heading-ids-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(path.join(root, 'docs'));
  writeFileSync(path.join(root, 'docs', 'index.md'), [
    '# Fixture', '## Usage', '## Usage-1', '> ### Usage', '## Usage', '',
    '## 🐱', '## 🐱', ''
  ].join('\n'));
  const result = spawnSync(process.execPath, [builder], { cwd: root, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  const html = readFileSync(path.join(root, '_site', 'index.html'), 'utf8');
  const headings = [...html.matchAll(/<h[1-4] id="([^"]+)"/g)].map((match) => match[1]);
  assert.deepEqual(headings, ['fixture', 'usage', 'usage-1', 'usage-2', 'usage-3', 'section', 'section-1']);
  assert.equal(new Set(headings).size, headings.length);
  const toc = html.match(/<nav class="toc"[\s\S]*?<\/nav>/)[0];
  for (const id of headings.slice(1)) {
    assert.ok(toc.includes(`href="#${id}"`), `missing unique TOC link: ${id}`);
  }
  assert.equal((html.match(/id="usage"/g) || []).length, 1);
});
