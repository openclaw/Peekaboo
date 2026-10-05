import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

test('normal macOS CI and safe tests share the complete docs-site regression gate', () => {
  const workflow = readFileSync(new URL('../.github/workflows/macos-ci.yml', import.meta.url), 'utf8');
  const packageJSON = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
  const docsStep = workflow.split('      - name: Docs lint\n')[1]?.split('\n      - name:')[0];
  assert.ok(docsStep);
  assert.match(docsStep, /pnpm run test:docs-site/);
  assert.doesNotMatch(docsStep, /node --test tests\/docs-site-toc\.test\.mjs/);
  assert.equal(packageJSON.scripts['test:docs-site'], 'node --test tests/docs-site-*.test.mjs');
  assert.match(packageJSON.scripts['test:safe'], /pnpm run test:docs-site/);
});
