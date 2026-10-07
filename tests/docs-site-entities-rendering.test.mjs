import assert from 'node:assert/strict';
import test from 'node:test';
import { buildDocsFixture } from './docs-site-fixture.mjs';

test('rendered headings and link parameters retain their original characters', (t) => {
  const html = buildDocsFixture(t, {
    'index.md': '# Fixture\n\n## Prompt & <output>\n\n[query](https://example.test/?q=one&format=json)\n\n## Control\n',
  }).readPage();
  assert.match(html, /class="toc-l2"[^>]*>Prompt &amp; &lt;output&gt;<\/a>/);
  assert.match(html, /href="https:\/\/example.test\/\?q=one&amp;format=json"/);
  assert.doesNotMatch(html, /q=one&amp;amp;format=json/);
});
