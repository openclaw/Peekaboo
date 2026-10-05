import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

for (const argument of [undefined, '--client-name=fixture', 'missing-script.js']) {
  test(`eval consumer imports wrapper with argument ${argument ?? '(none)'}`, () => {
    const wrapperURL = new URL('../peekaboo-mcp.js', import.meta.url).href;
    const result = spawnSync(process.execPath, ['--input-type=module', '--eval',
      `const {PeekabooMCPWrapper} = await import(${JSON.stringify(wrapperURL)}); console.log(typeof PeekabooMCPWrapper);`,
      ...(argument === undefined ? [] : ['--', argument])], {encoding: 'utf8', timeout: 2000});
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), 'function');
    assert.doesNotMatch(result.stderr, /Starting Swift server/);
  });
}
