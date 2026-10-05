import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const builder = fileURLToPath(new URL('../scripts/build-docs-site.mjs', import.meta.url));
for (const closed of [false, true]) {
  test(`fenced code survives ${closed ? 'an explicit closer' : 'the end of its document'}`, (t) => {
    const root = mkdtempSync(path.join(os.tmpdir(), 'peekaboo-docs-eof-'));
    t.after(() => rmSync(root, { recursive: true, force: true }));
    mkdirSync(path.join(root, 'docs'));
    writeFileSync(path.join(root, 'docs/index.md'), '# Fixture\n\n```bash\npeekaboo --help\n' + (closed ? '```\n' : ''));
    const result = spawnSync(process.execPath, [builder], { cwd: root, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    const html = readFileSync(path.join(root, '_site/index.html'), 'utf8');
    assert.match(html, /<pre><code class="language-bash">/);
    const code = html.match(/<pre><code[^>]*>([\s\S]*?)<\/code><\/pre>/)?.[1];
    assert.equal(code, '<span class="hl-cmd">peekaboo</span> <span class="hl-f">--help</span>' + (closed ? '' : '\n'));
  });
}

for (const closed of [false, true]) {
  test(`literal HTML stays code at ${closed ? 'an explicit closer' : 'document EOF'}`, (t) => {
    const root = mkdtempSync(path.join(os.tmpdir(), 'peekaboo-docs-eof-literal-'));
    t.after(() => rmSync(root, { recursive: true, force: true }));
    mkdirSync(path.join(root, 'docs'));
    const source = '<article title="example">A & B</article>';
    writeFileSync(path.join(root, 'docs/index.md'), '# Fixture\n\n```text\n' + source + (closed ? '\n```\n' : ''));
    const result = spawnSync(process.execPath, [builder], { cwd: root, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    const html = readFileSync(path.join(root, '_site/index.html'), 'utf8');
    const code = html.match(/<pre><code[^>]*>([\s\S]*?)<\/code><\/pre>/)?.[1];
    assert.equal(code, '&lt;article title=&quot;example&quot;&gt;A &amp; B&lt;/article&gt;');
  });
}
