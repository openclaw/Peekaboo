import assert from 'node:assert/strict';
import test from 'node:test';

import { decodeRenderedEntities, renderedHeadingText } from '../scripts/docs-site-toc.mjs';
import { buildDocsFixture } from './docs-site-fixture.mjs';

test('heading text ignores quoted tag delimiters', () => {
  const heading = '<a class="anchor" href="#x">#</a><a href="https://example.test/?q=>">visible</a>';
  assert.equal(renderedHeadingText(heading), 'visible');
});

test('docs TOC structurally extracts renderer-owned heading text', (t) => {
  const html = buildDocsFixture(t, { 'index.md': [
    '# Fixture',
    '',
    '## **Bold** _emphasis_ [link](https://example.com) `code`',
    '',
    '### Literal <tag> & text',
    ''
  ].join('\n') }).readPage();
  assert.match(html, /<nav class="toc"/);
  assert.match(html, /<a class="toc-l2"[^>]*>Bold emphasis link code<\/a>/);
  assert.match(html, /<a class="toc-l3"[^>]*>Literal &lt;tag&gt; &amp; text<\/a>/);
  assert.doesNotMatch(html, /<a class="toc-l[23]"[^>]*>#/);
});

test('heading text decodes renderer escapes once after stripping tags', () => {
  assert.equal(renderedHeadingText('<code>&lt;value&gt; &amp; &quot;quoted&quot; &#39;text&#39;</code>'),
    '<value> & "quoted" \'text\'');
  assert.equal(renderedHeadingText('<strong>&amp;lt;script&amp;gt;</strong>'), '&lt;script&gt;');
});

test('rendered markdown preserves ampersands in link query arguments', (t) => {
  const html = buildDocsFixture(t, { 'index.md': '# Links\n\n[query](https://example.test/search?q=one&format=json)\n' }).readPage();
  assert.match(html, /href="https:\/\/example.test\/search\?q=one&amp;format=json"/);
  assert.doesNotMatch(html, /href="https:\/\/example.test\/search\?q=one&amp;amp;format=json"/);
  const href = html.match(/<a href="([^"]+)">query<\/a>/)?.[1];
  assert.ok(href);
  assert.deepEqual([...new URL(decodeRenderedEntities(href)).searchParams], [['q', 'one'], ['format', 'json']]);
});

test('link destinations preserve literal entities and quotes without exposing markup', (t) => {
  const targets = [
    ['entities', 'https://example.test/?q=&amp;&format=&lt;tag&gt;'],
    ['quotes', 'https://example.test/?q="quoted"<value>&x=\'single\''],
    ['relative', 'other.md?q=one&format=json#section'],
    ['fragment', 'other.md#section?literal=a&b=c#tail'],
  ];
  const built = buildDocsFixture(t, {
    'index.md': '# Links\n\n' + targets.map(([label, href]) => `[${label}](${href})`).join('\n\n'),
    'other.md': '# Other\n\n## Section\n',
  });
  const html = built.readPage();
  for (const [label, original] of targets) {
    const href = html.match(new RegExp(`<a href="([^"]+)">${label}</a>`))?.[1];
    assert.ok(href, label);
    assert.equal(decodeRenderedEntities(href), original.replace('other.md', 'other.html'));
    assert.doesNotMatch(href, /[<>"']/);
  }
  assert.match(html, /q=&amp;amp;&amp;format=&amp;lt;tag&amp;gt;/);
  assert.match(html, /q=&quot;quoted&quot;&lt;value&gt;&amp;x=&#39;single&#39;/);
  assert.match(html, /other\.html\?q=one&amp;format=json#section/);
  assert.ok(!built.diagnostics.includes('other.html?q=one&format=json#section ->'), 'Query parameters must not become part of a filesystem path');
});
