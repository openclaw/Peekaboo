import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { renderedHeadingText } from '../scripts/docs-site-toc.mjs';

const projectRoot = fileURLToPath(new URL('..', import.meta.url));

test('heading text ignores quoted tag delimiters', () => {
  const heading = '<a class="anchor" href="#x">#</a><a href="https://example.test/?q=>">visible</a>';
  assert.equal(renderedHeadingText(heading), 'visible');
});

test('docs TOC structurally extracts renderer-owned heading text', (t) => {
  const fixtureRoot = mkdtempSync(path.join(os.tmpdir(), 'peekaboo-docs-toc-'));
  t.after(() => rmSync(fixtureRoot, { recursive: true, force: true }));
  mkdirSync(path.join(fixtureRoot, 'docs'), { recursive: true });
  writeFileSync(path.join(fixtureRoot, 'docs', 'index.md'), [
    '# Fixture',
    '',
    '## **Bold** _emphasis_ [link](https://example.com) `code`',
    '',
    '### Literal <tag> & text',
    ''
  ].join('\n'));

  const result = spawnSync(process.execPath, [path.join(projectRoot, 'scripts', 'build-docs-site.mjs')], {
    cwd: fixtureRoot,
    encoding: 'utf8'
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);

  const html = readFileSync(path.join(fixtureRoot, '_site', 'index.html'), 'utf8');
  assert.match(html, /<nav class="toc"/);
  assert.match(html, /<a class="toc-l2"[^>]*>Bold emphasis link code<\/a>/);
  assert.match(html, /<a class="toc-l3"[^>]*>Literal &amp;lt;tag&amp;gt; &amp;amp; text<\/a>/);
  assert.doesNotMatch(html, /<a class="toc-l[23]"[^>]*>#/);
});
