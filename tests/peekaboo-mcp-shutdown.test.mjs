import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { copyFile, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { PeekabooMCPWrapper } from '../peekaboo-mcp.js';

for (const [ignoreTermination, mainEntrypoint] of [[false, false], [true, false], [true, true]]) {
  test(`shutdown finishes when server ${ignoreTermination ? 'ignores' : 'accepts'} SIGTERM${mainEntrypoint ? ' through the default entrypoint' : ''}`, { timeout: 15_000 }, async () => {
    const root = await mkdtemp(join(tmpdir(), 'peekaboo-mcp-shutdown-'));
    const binaryPath = join(root, 'peekaboo');
    const readyPath = join(root, 'ready');
    const pidPath = join(root, 'pid');
    const wrapperURL = new URL('../peekaboo-mcp.js', import.meta.url).href;
    // The fixture expires independently so failed-wrapper cleanup never signals a saved PID.
    await writeFile(binaryPath, [
      `#!${process.execPath}`,
      "import {writeFileSync} from 'node:fs';",
      ignoreTermination ? "process.on('SIGTERM', () => {});" : '',
      `writeFileSync(${JSON.stringify(pidPath)}, String(process.pid));`,
      `writeFileSync(${JSON.stringify(readyPath)}, 'ready');`,
      'setTimeout(() => process.exit(86), 10_000);',
      '',
    ].join('\n'), { mode: 0o755 });
    const wrapperPath = join(root, 'peekaboo-mcp.mjs');
    if (mainEntrypoint) await copyFile(new URL(wrapperURL), wrapperPath);
    const args = mainEntrypoint ? [wrapperPath] : ['--input-type=module', '--eval', `
      import {PeekabooMCPWrapper} from ${JSON.stringify(wrapperURL)};
      import {existsSync} from 'node:fs';
      const wrapper = new PeekabooMCPWrapper({binaryPath: ${JSON.stringify(binaryPath)}, shutdownTimeoutMs: 80});
      wrapper.start();
      const ready = setInterval(() => {
        if (!existsSync(${JSON.stringify(readyPath)})) return;
        clearInterval(ready);
        wrapper.shutdown();
        wrapper.shutdown();
      }, 10);
    `];
    const child = spawn(process.execPath, args, { stdio: ['ignore', 'ignore', 'pipe'] });
    let diagnostics = '';
    child.stderr.on('data', chunk => { diagnostics += chunk; });
    const exit = once(child, 'exit');
    const closed = once(child, 'close');
    let timeout;
    try {
      if (mainEntrypoint) {
        await waitForReady(readyPath);
        child.kill('SIGTERM');
      }
      const started = performance.now();
      const result = await Promise.race([exit, new Promise(resolve => {
        timeout = setTimeout(() => resolve('timeout'), mainEntrypoint ? 8000 : 3000);
      })]);
      assert.notEqual(result, 'timeout', diagnostics);
      assert.equal(result[0], 0, diagnostics);
      if (mainEntrypoint) assert.ok(performance.now() - started >= 4500, 'default grace period was shortened');
      const serverPID = Number(await readFile(pidPath, 'utf8'));
      assert.throws(() => process.kill(serverPID, 0), {code: 'ESRCH'});
    } finally {
      clearTimeout(timeout);
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
      await closed;
      await rm(root, {recursive: true, force: true});
    }
  });
}

test('duplicate shutdown keeps one timer and cleanup cancels escalation', async () => {
  const wrapper = new PeekabooMCPWrapper({ shutdownTimeoutMs: 20 });
  const signals = [];
  wrapper.child = { killed: false, kill: signal => signals.push(signal) };
  try {
    wrapper.shutdown();
    const timer = wrapper.shutdownTimer;
    wrapper.shutdown();
    assert.equal(wrapper.shutdownTimer, timer);
    wrapper.clearShutdownTimer();
    await new Promise(resolve => setTimeout(resolve, 50));
    assert.equal(wrapper.shutdownTimer, null);
    assert.deepEqual(signals, ['SIGTERM']);
  } finally {
    wrapper.clearShutdownTimer();
  }
});

async function waitForReady(path) {
  const deadline = performance.now() + 3000;
  while (performance.now() < deadline) {
    try {
      if (await readFile(path, 'utf8') === 'ready') return;
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  throw new Error('server fixture did not become ready');
}
