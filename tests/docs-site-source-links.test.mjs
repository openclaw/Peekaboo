import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { buildDocsFixture } from './docs-site-fixture.mjs';

const blob = 'https://github.com/openclaw/Peekaboo/blob/main/';

test('repository source links open on GitHub instead of leaving the docs site', (t) => {
  const built = buildDocsFixture(t, {
    'platform-support.md': readFileSync(new URL('../docs/platform-support.md', import.meta.url), 'utf8'),
    'ARCHITECTURE.md': readFileSync(new URL('../docs/ARCHITECTURE.md', import.meta.url), 'utf8'),
  });
  const expected = {
    'platform-support.html': [
      'Apps/CLI/Package.swift',
      'Apps/Mac/Peekaboo.xcodeproj/project.pbxproj',
      'Package.swift',
      'package.json',
    ],
    'ARCHITECTURE.html': [
      'Core/PeekabooCore/Sources/PeekabooAgentRuntime/Support/PeekabooServiceProviding.swift',
    ],
  };
  for (const [page, paths] of Object.entries(expected)) {
    const html = built.readPage(page);
    for (const repoPath of paths) {
      assert.match(html, new RegExp(`href="${blob}${repoPath}"`));
    }
    assert.doesNotMatch(html, /href="\.\.\//);
  }
});
