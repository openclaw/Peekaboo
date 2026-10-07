import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const builder = process.env.DOCS_SITE_BUILDER || fileURLToPath(new URL('../scripts/build-docs-site.mjs', import.meta.url));

export function buildDocsFixture(t, files) {
  const root = mkdtempSync(path.join(tmpdir(), 'peekaboo-docs-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const [relativePath, content] of Object.entries(files)) {
    const file = path.join(root, 'docs', relativePath);
    mkdirSync(path.dirname(file), { recursive: true });
    writeFileSync(file, content);
  }
  const result = spawnSync(process.execPath, [builder], { cwd: root, encoding: 'utf8', timeout: 10000 });
  assert.equal(result.error, undefined);
  assert.equal(result.signal, null);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return {
    diagnostics: result.stderr,
    readPage: (relativePath = 'index.html') => readFileSync(path.join(root, '_site', relativePath), 'utf8'),
  };
}

export function articleFromHTML(html) {
  const article = html.match(/<article class="doc">([\s\S]*?)<\/article>/)?.[1];
  assert.notEqual(article, undefined, 'Generated page must contain its documentation article');
  return article;
}
