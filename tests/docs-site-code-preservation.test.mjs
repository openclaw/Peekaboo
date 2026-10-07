import assert from 'node:assert/strict';
import test from 'node:test';
import { buildDocsFixture } from './docs-site-fixture.mjs';

function renderCode(t, language, source) {
  const html = buildDocsFixture(t, {
    'index.md': `# Fixture\n\n\`\`\`${language}\n${source}\n\`\`\`\n`,
  }).readPage();
  const code = html.match(/<pre><code[^>]*>([\s\S]*?)<\/code><\/pre>/)?.[1];
  assert.ok(code !== undefined, 'missing rendered code block');
  // Remove only exact span wrappers that this renderer owns. Literal source
  // markup remains escaped until these wrappers have been removed.
  let text = code.replaceAll('</span>', '');
  for (const cls of ['hl-s', 'hl-c', 'hl-p', 'hl-f', 'hl-cmd', 'hl-n', 'hl-k', 'hl-m', 'hl-t']) {
    text = text.replaceAll(`<span class="${cls}">`, '');
  }
  const copyable = text.replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
  assert.equal(copyable, source);
  return code;
}

test('syntax highlighting preserves private-use characters in valid shell paths and YAML keys', (t) => {
  renderCode(t, 'bash', 'cat \ue000report\uf8ff.txt --lines 12');
  renderCode(t, 'yaml', '\ue000key\uf8ff: value');
});

test('syntax highlighting preserves blocks with more than 6400 highlighted tokens', (t) => {
  const source = JSON.stringify(Array.from({ length: 7000 }, (_, index) => `value-${index}`));
  const html = renderCode(t, 'json', source);
  assert.equal((html.match(/class="hl-s"/g) || []).length, 7000);
});

test('source text and existing highlighting survive ordered pattern passes', (t) => {
  const shell = renderCode(t, 'bash', 'peekaboo --app "Finder" 42 # npm <example>');
  assert.match(shell, /class="hl-cmd">peekaboo/);
  assert.match(shell, /class="hl-f">--app/);
  assert.match(shell, /class="hl-s">&quot;Finder&quot;/);
  assert.match(shell, /class="hl-n">42/);
  assert.match(shell, /class="hl-c"> # npm &lt;example&gt;/);
  renderCode(t, 'bash', 'echo "<span class=\'hl-s\'>literal & text</span>"');
  renderCode(t, 'bash', 'echo "# literal" # comment with "quoted" content');
  renderCode(t, 'js', 'const value = "npm 12"; // git --flag');
  renderCode(t, 'swift', 'let value = "quoted <text>" // 42');
  renderCode(t, 'json', '{"name":"<example>","count":42,"enabled":true}');
});
