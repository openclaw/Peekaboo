import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { delimiter } from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
import { devtoolsFixture } from '../tests/fixtures/devtools-websocket.mjs';

const swift = readFileSync(new URL('../Core/PeekabooCore/Sources/PeekabooAgentRuntime/Browser/BrowserMCPProviderBootstrap.swift', import.meta.url), 'utf8');
const bootstrap = swift.match(/static let source = #"""\n([\s\S]*?)\n    """#/)[1].replace(/^    /gm, '');
process.env.PATH = fileURLToPath(new URL('../node_modules/.bin', import.meta.url)) + delimiter + process.env.PATH;
await import('data:text/javascript,' + encodeURIComponent(bootstrap.split('process.argv =')[0]));
const { McpServer } = await import('../node_modules/chrome-devtools-mcp/build/src/index.js');
const { ensureBrowserConnected, closeBrowser } = await import('../node_modules/chrome-devtools-mcp/build/src/browser.js');
const { mcpOptions } = await import('../node_modules/chrome-devtools-mcp/build/src/config/mcp-options.js');
const defaults = Object.fromEntries(Object.entries(mcpOptions).map(([key, option]) => [key, option.default]));

// Exercise the real bundled Puppeteer against an approval-mode-shaped listener.
const fixture = await devtoolsFixture();
let server;
try {
  server = await McpServer.from({ ...defaults, usageStatistics: false, wsEndpoint: fixture.endpoint });
  const tool = server.server._registeredTools.peekaboo_browser_connect;
  assert.ok(tool, 'the provider must register the owner connection verifier');
  const result = await tool.handler({});
  assert.deepEqual(JSON.parse(result.content[0].text), {
    webSocketDebuggerUrl: fixture.endpoint, product: 'Chrome/152.0', protocolVersion: '1.3', userAgent: 'fixture',
  });
  const browser = await ensureBrowserConnected({ wsEndpoint: fixture.endpoint });
  assert.equal(await browser.version(), 'Chrome/152.0');
  assert.deepEqual(await tool.handler({}), result);
  assert.equal(fixture.attaches, 1, 'verification and ordinary provider operations must share one socket');
  assert.equal(fixture.requests, 0, 'approval-mode discovery must not require /json/version');
  const disconnected = once(browser, 'disconnected');
  fixture.drop();
  await disconnected;
  await assert.rejects(ensureBrowserConnected({ wsEndpoint: fixture.endpoint }), /reconnect explicitly/);
  assert.equal(fixture.attaches, 1, 'a disconnected provider must not ask Chrome for another approval');
} finally {
  await closeBrowser();
  await server?.close();
  await fixture.close();
}

const refusal = await devtoolsFixture({ refuse: true });
try {
  server = await McpServer.from({ ...defaults, usageStatistics: false, wsEndpoint: refusal.endpoint });
  const tool = server.server._registeredTools.peekaboo_browser_connect;
  const rejected = await tool.handler({});
  assert.equal(rejected.isError, true);
  assert.match(rejected.content[0].text, /403/);
  assert.deepEqual(await tool.handler({}), rejected);
  assert.equal(refusal.attaches, 1, 'a refused approval must remain one attempt');
} finally {
  await closeBrowser();
  await server?.close();
  await refusal.close();
}
const destination = await devtoolsFixture();
const redirect = await devtoolsFixture({ redirectURL: destination.endpoint });
try {
  server = await McpServer.from({ ...defaults, usageStatistics: false, wsEndpoint: redirect.endpoint });
  const result = await server.server._registeredTools.peekaboo_browser_connect.handler({});
  assert.equal(result.isError, true, 'a redirect must not be mistaken for the original browser identity');
  assert.equal(redirect.attaches, 1);
  assert.equal(destination.attaches, 0, 'never attach to a redirected browser');
} finally {
  await closeBrowser();
  await server?.close();
  await redirect.close();
  await destination.close();
}
console.log('test-browser-provider-connection: ok (single socket, no HTTP discovery, no reconnect or redirects, refusal retained)');
