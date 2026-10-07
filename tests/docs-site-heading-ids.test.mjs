import assert from 'node:assert/strict';
import test from 'node:test';
import { articleFromHTML, buildDocsFixture } from './docs-site-fixture.mjs';

test('repeated headings retain distinct permalink and TOC targets across blockquotes', (t) => {
  const html = buildDocsFixture(t, { 'index.md': [
    '# Fixture', '## Usage', '## Usage-1', '> ### Usage', '## Usage', '',
    '## 🐱', '## 🐱', ''
  ].join('\n') }).readPage();
  const headings = [...html.matchAll(/<h[1-4] id="([^"]+)"/g)].map((match) => match[1]);
  assert.deepEqual(headings, ['fixture', 'usage', 'usage-1', 'usage-2', 'usage-3', 'section', 'section-1']);
  assert.equal(new Set(headings).size, headings.length);
  const toc = html.match(/<nav class="toc"[\s\S]*?<\/nav>/)[0];
  for (const id of headings.slice(1)) {
    assert.ok(toc.includes(`href="#${id}"`), `missing unique TOC link: ${id}`);
  }
  assert.equal((html.match(/id="usage"/g) || []).length, 1);
});

test('duplicate suffixes do not steal a later natural heading anchor', (t) => {
  const html = buildDocsFixture(t, { 'index.md': '# Fixture\n## Usage\n> ## Usage\n## Usage-1\n## Other\n' }).readPage();
  const headings = [...html.matchAll(/<h[1-4] id="([^"]+)"/g)].map((match) => match[1]);
  assert.deepEqual(headings, ['fixture', 'usage', 'usage-2', 'usage-1', 'other']);
  assert.match(html, /<h2 id="usage-1">[^\n]*Usage-1<\/h2>/);
});

test('page-wide IDs include nested H1/H4 and preserve body links and escaped code', (t) => {
  const html = buildDocsFixture(t, { 'index.md': [
    '# Repeated', '# Repeated', '#### Repeated', '> ## Repeated', '>', '> > #### Repeated', '',
    '[Body link](#repeated)', '', '`<h2 id="repeated">literal</h2>`', '',
    '```html', '<h2 id="repeated">fenced</h2>', '```', '',
  ].join('\n') }).readPage();
  const article = articleFromHTML(html);
  const headings = [...article.matchAll(/<h([1-4]) id="([^"]+)">([\s\S]*?)<\/h\1>/g)];
  assert.deepEqual(headings.map(match => match[2]), ['repeated', 'repeated-1', 'repeated-2', 'repeated-3', 'repeated-4']);
  for (const [, level, id, body] of headings) {
    if (level !== '1') assert.ok(body.startsWith(`<a class="anchor" href="#${id}"`));
  }
  assert.match(article, /<a href="#repeated">Body link<\/a>/);
  assert.match(article, /<code>&lt;h2 id=&quot;repeated&quot;&gt;literal&lt;\/h2&gt;<\/code>/);
  assert.match(article, /&lt;h2 id=&quot;repeated&quot;&gt;fenced&lt;\/h2&gt;/);
});

test('emoji fallbacks do not steal later Section or Section-1 anchors', (t) => {
  const html = buildDocsFixture(t, { 'index.md': '# Fixture\n## 🐱\n> ## 🐱\n## Section\n## Section-1\n## 🐱\n' }).readPage();
  const ids = [...articleFromHTML(html).matchAll(/<h[1-4] id="([^"]*)">/g)].map(match => match[1]);
  assert.deepEqual(ids, ['fixture', 'section-2', 'section-3', 'section', 'section-1', 'section-4']);
});

test('a large repeated-heading page allocates the same ordered suffixes', (t) => {
  const count = 2000;
  const html = buildDocsFixture(t, { 'index.md': '# Fixture\n' + '## Repeated\n'.repeat(count) }).readPage();
  const ids = [...articleFromHTML(html).matchAll(/<h2 id="([^"]*)">/g)].map(match => match[1]);
  assert.deepEqual(ids, Array.from({ length: count }, (_, index) => index ? `repeated-${index}` : 'repeated'));
});
