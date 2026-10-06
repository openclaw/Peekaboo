import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { delimiter } from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { devtoolsFixture } from '../tests/fixtures/devtools-websocket.mjs';

const swift = readFileSync(new URL('../Core/PeekabooCore/Sources/PeekabooAgentRuntime/Browser/BrowserMCPProviderBootstrap.swift', import.meta.url), 'utf8');
const bootstrap = swift.match(/static let source = #"""\n([\s\S]*?)\n    """#/)[1].replace(/^    /gm, '');
process.env.PATH = fileURLToPath(new URL('../node_modules/.bin', import.meta.url)) + delimiter + process.env.PATH;
await import('data:text/javascript,' + encodeURIComponent(bootstrap.split('process.argv =')[0]));
const { McpServer } = await import('../node_modules/chrome-devtools-mcp/build/src/index.js');
const { BrowserManager } = await import('../node_modules/chrome-devtools-mcp/build/src/BrowserManager.js');
const { mcpOptions } = await import('../node_modules/chrome-devtools-mcp/build/src/config/mcp-options.js');
const defaults = Object.fromEntries(Object.entries(mcpOptions).map(([key, option]) => [key, option.default]));

// Exercise the real bundled Puppeteer against an approval-mode-shaped listener.
const fixture = await devtoolsFixture();
let server;
let browserManager;
async function createServer(endpoint) {
  const args = { ...defaults, usageStatistics: false, wsEndpoint: endpoint };
  browserManager = new BrowserManager(args);
  return McpServer.from(args, { browserManager });
}
try {
  server = await createServer(fixture.endpoint);
  const tool = server.server._registeredTools.peekaboo_browser_connect;
  assert.ok(tool, 'the provider must register the owner connection verifier');
  const result = await tool.handler({});
  assert.deepEqual(JSON.parse(result.content[0].text), {
    webSocketDebuggerUrl: fixture.endpoint, product: 'Chrome/152.0', protocolVersion: '1.3', userAgent: 'fixture',
  });
  const browser = await browserManager.ensureBrowser();
  assert.equal(await browser.version(), 'Chrome/152.0');
  assert.deepEqual(await tool.handler({}), result);
  assert.equal(fixture.attaches, 1, 'verification and ordinary provider operations must share one socket');
  assert.equal(fixture.requests, 0, 'approval-mode discovery must not require /json/version');
  const disconnected = once(browser, 'disconnected');
  fixture.drop();
  await disconnected;
  await assert.rejects(browserManager.ensureBrowser(), /reconnect explicitly/);
  assert.equal(fixture.attaches, 1, 'a disconnected provider must not ask Chrome for another approval');
} finally {
  await server?.close();
  await fixture.close();
}

const refusal = await devtoolsFixture({ refuse: true });
try {
  server = await createServer(refusal.endpoint);
  const tool = server.server._registeredTools.peekaboo_browser_connect;
  const rejected = await tool.handler({});
  assert.equal(rejected.isError, true);
  assert.match(rejected.content[0].text, /403/);
  assert.deepEqual(await tool.handler({}), rejected);
  assert.equal(refusal.attaches, 1, 'a refused approval must remain one attempt');
} finally {
  await server?.close();
  await refusal.close();
}
const destination = await devtoolsFixture();
const redirect = await devtoolsFixture({ redirectURL: destination.endpoint });
try {
  server = await createServer(redirect.endpoint);
  const result = await server.server._registeredTools.peekaboo_browser_connect.handler({});
  assert.equal(result.isError, true, 'a redirect must not be mistaken for the original browser identity');
  assert.equal(redirect.attaches, 1);
  assert.equal(destination.attaches, 0, 'never attach to a redirected browser');
} finally {
  await server?.close();
  await redirect.close();
  await destination.close();
}
// Cross the actual stdio boundary too: the provider now bundles MCP SDK 2.
const stdioFixture = await devtoolsFixture();
const child = spawn(process.execPath, ['--input-type=module', '--eval', bootstrap, '--',
  '--wsEndpoint', stdioFixture.endpoint, '--no-usage-statistics', '--pageIdRouting',
  '--experimentalStructuredContent', '--no-performance-crux'], { stdio: ['pipe', 'pipe', 'pipe'] });
const lines = createInterface({ input: child.stdout });
const pending = new Map();
let nextId = 0;
let diagnostics = '';
child.stderr.on('data', chunk => { diagnostics = (diagnostics + chunk).slice(-4096); });
lines.on('line', line => {
  const response = JSON.parse(line);
  pending.get(response.id)?.(response);
});
async function request(method, params) {
  const id = ++nextId;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`Provider did not answer ${method}: ${diagnostics}`));
    }, 15_000);
    pending.set(id, response => {
      clearTimeout(timer);
      pending.delete(id);
      if (response.error) reject(new Error(JSON.stringify(response.error)));
      else resolve(response.result);
    });
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
}
try {
  const initialized = await request('initialize', {
    protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'peekaboo-contract', version: '1.0.0' },
  });
  assert.equal(initialized.serverInfo.version, '1.10.1');
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  const catalog = await request('tools/list', {});
  assert.ok(catalog.tools.some(tool => tool.name === 'peekaboo_browser_connect'));
  assert.ok(catalog.tools.some(tool => tool.name === 'take_snapshot' && tool.inputSchema.required.includes('pageId')));
  const result = await request('tools/call', { name: 'peekaboo_browser_connect', arguments: {} });
  assert.equal(result.isError, undefined);
  assert.equal(JSON.parse(result.content[0].text).webSocketDebuggerUrl, stdioFixture.endpoint);
  assert.deepEqual(await request('tools/call', { name: 'peekaboo_browser_connect', arguments: {} }), result);
  assert.equal(stdioFixture.attaches, 1, 'the full launcher must retain one provider connection');
  assert.equal(stdioFixture.requests, 0);
} finally {
  lines.close();
  const exited = child.exitCode === null && child.signalCode === null ? once(child, 'exit') : Promise.resolve();
  child.kill('SIGKILL');
  await exited;
  await stdioFixture.close();
}
console.log('test-browser-provider-connection: ok (single socket, no HTTP discovery, no reconnect or redirects, refusal retained, MCP stdio)');

// Keep provider lifecycle regressions in the existing safe-suite and macOS CI entrypoint.
await import('../tests/browser-provider-lifecycle.test.mjs');
