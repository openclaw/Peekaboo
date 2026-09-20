import { strict as assert } from 'node:assert';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { copyFile, mkdir, mkdtemp, readFile, stat, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { PeekabooMCPWrapper } from '../peekaboo-mcp.js';

test('idle shutdown with exitIfIdle requests process.exit 0', () => {
  const wrapper = new PeekabooMCPWrapper({ binaryPath: '/bin/sh', initialDelayMs: 50, maxDelayMs: 50 });
  const exits = [];
  const originalExit = process.exit;
  process.exit = code => {
    exits.push(code);
  };
  try {
    wrapper.shutdown({ exitIfIdle: true });
  } finally {
    process.exit = originalExit;
  }
  assert.deepEqual(exits, [0]);
  assert.equal(wrapper.shuttingDown, true);
});

test('shutdown clears pending restart backoff', async () => {
  const root = await mkdtemp(join(tmpdir(), 'peekaboo-mcp-restart-'));
  const countPath = join(root, 'count');
  const binaryPath = join(root, 'peekaboo');
  await writeFile(
    binaryPath,
    `#!/bin/sh\ncount=$(cat "${countPath}" 2>/dev/null || echo 0)\nexpr "$count" + 1 > "${countPath}"\nexit 1\n`,
    { mode: 0o755 },
  );

  const wrapper = new PeekabooMCPWrapper({ binaryPath, initialDelayMs: 50, maxDelayMs: 50 });
  wrapper.start();
  await waitFor(async () => Number(await readFile(countPath, 'utf8')) === 1);
  await waitFor(() => wrapper.restartTimer !== null);

  wrapper.shutdown();
  await new Promise(resolve => setTimeout(resolve, 120));

  assert.equal(Number(await readFile(countPath, 'utf8')), 1);
  assert.equal(wrapper.restartTimer, null);
});

test('EACCES recovery chmods without shell expansion', async () => {
  const root = await mkdtemp(join(tmpdir(), 'peekaboo-mcp-eacces-'));
  const sideEffectPath = join(root, 'shell-expanded');
  const shellPath = join(root, 'shell-$(touch shell-expanded)');
  const binaryPath = join(shellPath, 'peekaboo');
  await mkdir(shellPath);
  await writeFile(binaryPath, '#!/bin/sh\nexit 0\n', { mode: 0o644 });

  const wrapper = new PeekabooMCPWrapper({ binaryPath, initialDelayMs: 1000 });
  const previousCwd = process.cwd();
  process.chdir(root);
  try {
    wrapper.start();
    await waitFor(async () => ((await stat(binaryPath)).mode & 0o111) !== 0);
    wrapper.shutdown();
  } finally {
    process.chdir(previousCwd);
  }

  await assert.rejects(stat(sideEffectPath));
});

test('SIGINT during crash backoff exits the wrapper process', async () => {
  const root = await mkdtemp(join(tmpdir(), 'peekaboo-mcp-sigint-'));
  const countPath = join(root, 'count');
  const binaryPath = join(root, 'peekaboo');
  const wrapperPath = join(root, 'peekaboo-mcp.js');
  await writeFile(
    binaryPath,
    `#!/bin/sh\ncount=$(cat "${countPath}" 2>/dev/null || echo 0)\nexpr "$count" + 1 > "${countPath}"\nexit 1\n`,
    { mode: 0o755 },
  );
  await copyFile(fileURLToPath(new URL('../peekaboo-mcp.js', import.meta.url)), wrapperPath);

  const child = spawn(process.execPath, [wrapperPath], {
    env: { ...process.env, PEEKABOO_MCP_WRAPPER: 'true' },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let stderr = '';
  child.stderr.on('data', chunk => { stderr += chunk; });

  await waitFor(async () => Number(await readFile(countPath, 'utf8')) === 1);
  await waitFor(() => /Server crashed/.test(stderr));

  child.kill('SIGINT');
  const [code, signal] = await once(child, 'exit');
  assert.equal(signal, null, stderr);
  assert.equal(code, 0, stderr);
  assert.equal(Number(await readFile(countPath, 'utf8')), 1);
});

test('symlink-preserved entrypoint still starts as main module', async () => {
  const root = await mkdtemp(join(tmpdir(), 'peekaboo-mcp-symlink-'));
  const packageDir = join(root, 'pkg');
  const binDir = join(root, 'bin');
  await mkdir(packageDir);
  await mkdir(binDir);

  const countPath = join(root, 'count');
  const binaryPath = join(packageDir, 'peekaboo');
  const wrapperTarget = join(packageDir, 'peekaboo-mcp.js');
  const wrapperPath = join(binDir, 'peekaboo-mcp');
  await writeFile(
    binaryPath,
    `#!/bin/sh\ncount=$(cat "${countPath}" 2>/dev/null || echo 0)\nexpr "$count" + 1 > "${countPath}"\nexit 0\n`,
    { mode: 0o755 },
  );
  await copyFile(fileURLToPath(new URL('../peekaboo-mcp.js', import.meta.url)), wrapperTarget);
  await symlink(wrapperTarget, wrapperPath);

  const child = spawn(process.execPath, ['--preserve-symlinks-main', wrapperPath], {
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let stderr = '';
  child.stderr.on('data', chunk => { stderr += chunk; });
  const [code] = await once(child, 'exit');

  assert.equal(code, 0, stderr);
  assert.equal(Number(await readFile(countPath, 'utf8')), 1);
});

async function waitFor(predicate) {
  const deadline = Date.now() + 2000;
  let lastError;
  while (Date.now() < deadline) {
    try {
      if (await predicate()) return;
    } catch (error) {
      lastError = error;
    }
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  if (lastError) throw lastError;
  throw new Error('timed out waiting for condition');
}
