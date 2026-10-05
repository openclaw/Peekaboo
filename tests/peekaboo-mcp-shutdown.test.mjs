import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

for (const ignoreTermination of [false, true]) {
  test(`shutdown finishes when server ${ignoreTermination ? 'ignores' : 'accepts'} SIGTERM`, async () => {
    const root = await mkdtemp(join(tmpdir(), 'peekaboo-mcp-shutdown-'));
    const binaryPath = join(root, 'peekaboo');
    const readyPath = join(root, 'ready');
    const pidPath = join(root, 'pid');
    const wrapperURL = new URL('../peekaboo-mcp.js', import.meta.url).href;
    await writeFile(binaryPath, `#!${process.execPath}\nimport {writeFileSync} from 'node:fs';\n${ignoreTermination ? "process.on('SIGTERM', () => {});" : ''}\nwriteFileSync(${JSON.stringify(pidPath)}, String(process.pid));\nwriteFileSync(${JSON.stringify(readyPath)}, 'ready');\nsetInterval(() => {}, 1000);\n`, {mode: 0o755});
    const child = spawn(process.execPath, ['--input-type=module', '--eval', `
      import {PeekabooMCPWrapper} from ${JSON.stringify(wrapperURL)};
      import {existsSync} from 'node:fs';
      const wrapper = new PeekabooMCPWrapper({binaryPath: ${JSON.stringify(binaryPath)}, shutdownTimeoutMs: 80});
      wrapper.start();
      const ready = setInterval(() => {
        if (!existsSync(${JSON.stringify(readyPath)})) return;
        clearInterval(ready);
        wrapper.shutdown();
      }, 10);
    `], {stdio: ['ignore', 'ignore', 'pipe']});
    let diagnostics = '';
    child.stderr.on('data', chunk => { diagnostics += chunk; });
    const exit = once(child, 'exit');
    let timeout;
    try {
      const result = await Promise.race([exit, new Promise(resolve => { timeout = setTimeout(() => resolve('timeout'), 1200); })]);
      assert.notEqual(result, 'timeout', diagnostics);
      assert.equal(result[0], 0, diagnostics);
      const serverPID = Number(await readFile(pidPath, 'utf8'));
      assert.throws(() => process.kill(serverPID, 0), {code: 'ESRCH'});
    } finally {
      clearTimeout(timeout);
      try { process.kill(Number(await readFile(pidPath, 'utf8')), 'SIGKILL'); } catch {}
      child.kill('SIGKILL');
      await exit;
      await rm(root, {recursive: true, force: true});
    }
  });
}
