import assert from 'node:assert/strict';
import test from 'node:test';
import { articleFromHTML, buildDocsFixture } from './docs-site-fixture.mjs';

function render(t, markdown) {
  return articleFromHTML(buildDocsFixture(t, { 'index.md': `# Fixture\n\n${markdown}` }).readPage());
}

test('markdown images render as images', (t) => {
  const article = render(t, [
    '![Peekaboo banner](assets/peekaboo.png)',
    '',
    '[![CI](https://img.example/ci.svg "status")](https://example.invalid/actions)',
    '',
    '`![not](an-image.png)`',
    '',
  ].join('\n'));
  assert.match(article, /<p><img src="assets\/peekaboo.png" alt="Peekaboo banner"><\/p>/);
  assert.match(article, /<a href="https:\/\/example\.invalid\/actions"><img src="https:\/\/img\.example\/ci\.svg" alt="CI"><\/a>/);
  assert.match(article, /<code>!\[not\]\(an-image\.png\)<\/code>/);
  assert.doesNotMatch(article, /<img[^>]+title=/);
  assert.doesNotMatch(article, /!\[Peekaboo|<a[^>]*>Peekaboo banner<\/a>|<a[^>]*>CI<\/a>/);
});

test('image alt text restores inline-code stash contents before escaping', (t) => {
  const article = render(t, '![Open `file` and `"other"`](assets/peekaboo.png)');
  assert.match(article, /alt="Open `file` and `&quot;other&quot;`"/);
  assert.doesNotMatch(article, /\u0000/);
});
