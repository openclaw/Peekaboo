#!/usr/bin/env node
// Peekaboo MCP wrapper that restarts the Swift server on crash

import { spawn } from 'child_process';
import { chmodSync, existsSync, realpathSync, statSync } from 'fs';
import { fileURLToPath, pathToFileURL } from 'url';
import { dirname, join } from 'path';

const modulePath = realpathSync(fileURLToPath(import.meta.url));
const __dirname = dirname(modulePath);
const defaultBinaryPath = join(__dirname, 'peekaboo');

const MAX_RESTARTS = 5;
const RESTART_WINDOW_MS = 60_000;
const INITIAL_DELAY_MS = 1000;
const MAX_DELAY_MS = 30_000;

export class PeekabooMCPWrapper {
  constructor(options = {}) {
    this.binaryPath = options.binaryPath || defaultBinaryPath;
    this.initialDelayMs = options.initialDelayMs || INITIAL_DELAY_MS;
    this.maxDelayMs = options.maxDelayMs || MAX_DELAY_MS;
    this.restartTimestamps = [];
    this.delay = this.initialDelayMs;
    this.child = null;
    this.restartTimer = null;
    this.shuttingDown = false;
  }

  start() {
    if (this.shuttingDown) return;

    if (!existsSync(this.binaryPath)) {
      console.error(`[Peekaboo MCP] Binary not found at ${this.binaryPath}`);
      process.exit(1);
    }

    const now = Date.now();
    this.restartTimestamps = this.restartTimestamps.filter(ts => now - ts < RESTART_WINDOW_MS);
    if (this.restartTimestamps.length >= MAX_RESTARTS) {
      console.error(`[Peekaboo MCP] Aborting: restarted ${MAX_RESTARTS} times within a minute.`);
      process.exit(1);
    }

    console.error('[Peekaboo MCP] Starting Swift server...');
    this.child = spawn(this.binaryPath, ['mcp', 'serve'], {
      stdio: 'inherit',
      env: {
        ...process.env,
        PEEKABOO_MCP_WRAPPER: 'true'
      }
    });

    this.child.on('exit', (code, signal) => {
      this.child = null;
      if (this.shuttingDown) return process.exit(code || 0);

      if (code === 0 || signal === 'SIGINT' || signal === 'SIGTERM') {
        console.error('[Peekaboo MCP] Server exited cleanly');
        process.exit(code || 0);
      }

      this.handleCrash(code, signal);
    });

    this.child.on('error', (err) => {
      this.child = null;
      console.error('[Peekaboo MCP] Failed to launch:', err.message);
      if (err.code === 'EACCES') {
        try {
          const mode = statSync(this.binaryPath).mode;
          chmodSync(this.binaryPath, mode | 0o111);
          console.error('[Peekaboo MCP] Fixed executable bit, retrying...');
          this.handleCrash(1);
          return;
        } catch (_) {
          console.error('[Peekaboo MCP] Could not make binary executable.');
        }
      }
      this.handleCrash(err.code || 1);
    });
  }

  handleCrash(code, signal) {
    if (this.shuttingDown) return;

    console.error(`[Peekaboo MCP] Server crashed (code ${code}${signal ? `, signal ${signal}` : ''}).`);
    this.restartTimestamps.push(Date.now());
    this.clearRestartTimer();
    this.restartTimer = setTimeout(() => {
      this.restartTimer = null;
      if (this.shuttingDown) return;
      this.delay = Math.min(this.delay * 2, this.maxDelayMs);
      this.start();
    }, this.delay);
  }

  shutdown({ exitIfIdle = false } = {}) {
    this.shuttingDown = true;
    this.clearRestartTimer();
    if (this.child) {
      if (!this.child.killed) {
        this.child.kill('SIGTERM');
      }
      return;
    }
    if (exitIfIdle) {
      process.exit(0);
    }
  }

  clearRestartTimer() {
    if (this.restartTimer) {
      clearTimeout(this.restartTimer);
      this.restartTimer = null;
    }
  }
}

if (isMainModule()) {
  const wrapper = new PeekabooMCPWrapper();
  wrapper.start();

  process.on('SIGINT', () => {
    console.error('\n[Peekaboo MCP] SIGINT received, shutting down...');
    wrapper.shutdown({ exitIfIdle: true });
  });

  process.on('SIGTERM', () => {
    console.error('[Peekaboo MCP] SIGTERM received, shutting down...');
    wrapper.shutdown({ exitIfIdle: true });
  });

  process.on('uncaughtException', (err) => {
    console.error('[Peekaboo MCP] Uncaught exception:', err);
    wrapper.shutdown({ exitIfIdle: true });
  });

  process.on('unhandledRejection', (reason) => {
    console.error('[Peekaboo MCP] Unhandled rejection:', reason);
  });
}

function isMainModule() {
  const entry = process.argv[1];
  if (entry === undefined) return false;

  const entryUrl = pathToFileURL(entry).href;
  if (import.meta.url === entryUrl) return true;

  return pathToFileURL(realpathSync(modulePath)).href === pathToFileURL(realpathSync(entry)).href;
}
