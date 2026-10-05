import assert from 'node:assert/strict';
import test from 'node:test';
import { articleFromHTML, buildDocsFixture } from './docs-site-fixture.mjs';

const lines = ['---', 'title: Metadata title', 'description: Published description', '---', '# Body heading', '', 'Body instructions.', ''];
for (const [name, content] of [
  ['LF', lines.join('\n')],
  ['CRLF', lines.join('\r\n')],
  ['mixed', lines.map((line, index) => line + (index % 2 ? '\r\n' : '\n')).join('')],
]) {
  test(`docs builder extracts front matter with ${name} line endings`, (t) => {
    const html = buildDocsFixture(t, { 'index.md': content }).readPage();
    assert.match(html, /<title>Metadata title — Peekaboo<\/title>/);
    assert.match(html, /name="description" content="Published description"/);
    const article = articleFromHTML(html);
    assert.match(article, /Body instructions\./);
    assert.doesNotMatch(article, /title: Metadata title|description: Published description/);
});
}

test('CRLF without front matter keeps ordinary article content', (t) => {
  const html = buildDocsFixture(t, { 'index.md': '# Body heading\r\n\r\nBody instructions.\r\n' }).readPage();
  assert.match(html, /<title>Body heading — Peekaboo<\/title>/);
  assert.match(articleFromHTML(html), /Body instructions\./);
});

test('CRLF closing delimiter at EOF still supplies metadata without body leakage', (t) => {
  const html = buildDocsFixture(t, { 'index.md': lines.slice(0, 4).join('\r\n') }).readPage();
  assert.match(html, /<title>Metadata title — Peekaboo<\/title>/);
  assert.match(html, /name="description" content="Published description"/);
  assert.equal(articleFromHTML(html).trim(), '');
});
