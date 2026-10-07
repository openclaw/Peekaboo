import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const docsSiteSources = ['build-docs-site.mjs', 'docs-site-assets.mjs', 'docs-site-toc.mjs'];

test('docs site sources contain no literal NUL bytes', () => {
  // Literal NULs make review tooling treat diffs as binary; spell them as \u0000 escapes.
  for (const name of docsSiteSources) {
    const source = readFileSync(new URL(`../scripts/${name}`, import.meta.url));
    assert.equal(source.indexOf(0), -1, `scripts/${name} contains a literal NUL byte`);
  }
});
