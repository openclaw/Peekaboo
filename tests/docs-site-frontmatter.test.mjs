import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const builder = fileURLToPath(new URL('../scripts/build-docs-site.mjs', import.meta.url));
for (const [name, newline] of [['LF', '\n'], ['CRLF', '\r\n']]) {
  test(`docs builder extracts front matter with ${name} line endings`, (t) => {
    const root = mkdtempSync(path.join(os.tmpdir(), 'peekaboo-frontmatter-'));
    t.after(() => rmSync(root, { recursive: true, force: true }));
    mkdirSync(path.join(root, 'docs'));
    writeFileSync(path.join(root, 'docs', 'index.md'), [
      '---', 'title: Metadata title', 'description: Published description', '---',
      '# Body heading', '', 'Body instructions.', ''
    ].join(newline));
    const result = spawnSync(process.execPath, [builder], { cwd: root, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    const html = readFileSync(path.join(root, '_site', 'index.html'), 'utf8');
    assert.match(html, /<title>Metadata title — Peekaboo<\/title>/);
    assert.match(html, /name="description" content="Published description"/);
    const article = html.match(/<article class="doc">([\s\S]*?)<\/article>/)[1];
    assert.match(article, /Body instructions\./);
    assert.doesNotMatch(article, /title: Metadata title|description: Published description/);
  });
}
