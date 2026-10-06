import assert from 'node:assert/strict';
import { once } from 'node:events';
import { readFileSync } from 'node:fs';
import { delimiter } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { devtoolsFixture } from './fixtures/devtools-websocket.mjs';

const swift = readFileSync(new URL('../Core/PeekabooCore/Sources/PeekabooAgentRuntime/Browser/BrowserMCPProviderBootstrap.swift', import.meta.url), 'utf8');
const bootstrap = swift.match(/static let source = #"""\n([\s\S]*?)\n    """#/)[1].replace(/^    /gm, '');
process.env.PATH = fileURLToPath(new URL('../node_modules/.bin', import.meta.url)) + delimiter + process.env.PATH;
await import('data:text/javascript,' + encodeURIComponent(bootstrap.split('process.argv =')[0]));
const { McpServer } = await import('../node_modules/chrome-devtools-mcp/build/src/index.js');
const { BrowserManager } = await import('../node_modules/chrome-devtools-mcp/build/src/BrowserManager.js');
const { mcpOptions } = await import('../node_modules/chrome-devtools-mcp/build/src/config/mcp-options.js');
const defaults = Object.fromEntries(Object.entries(mcpOptions).map(([key, option]) => [key, option.default]));

async function provider(endpoint) {
  const args = { ...defaults, usageStatistics: false, wsEndpoint: endpoint };
  const manager = new BrowserManager(args);
  const server = await McpServer.from(args, {browserManager: manager});
  return {manager, server, verify: server.server._registeredTools.peekaboo_browser_connect.handler};
}

test('ordinary provider calls retain the initial approval refusal', {timeout: 15_000}, async () => {
  const fixture = await devtoolsFixture({refuse: true});
  let server;
  try {
    const owner = await provider(fixture.endpoint);
    server = owner.server;
    const {verify} = owner;
    const result = await verify({});
    assert.equal(result.isError, true);
    assert.match(result.content[0].text, /403/);
    assert.equal((await server.server._registeredTools.list_pages.handler({})).isError, true);
    assert.equal((await server.server._registeredTools.list_pages.handler({})).isError, true);
    const concurrent = await Promise.all([
      server.server._registeredTools.list_pages.handler({}),
      server.server._registeredTools.list_pages.handler({}),
    ]);
    assert.ok(concurrent.every(result => result.isError));
    assert.equal(fixture.attaches, 1, 'ordinary calls must not reopen approval after the verifier failed');
    assert.deepEqual(await verify({}), result);
  } finally {
    await server?.close();
    await fixture.close();
  }
});

test('connection verification stops reporting success after the socket disconnects', {timeout: 15_000}, async () => {
  const fixture = await devtoolsFixture();
  let server;
  try {
    const owner = await provider(fixture.endpoint);
    server = owner.server;
    const {manager, verify} = owner;
    const verified = await verify({});
    assert.equal(verified.isError, undefined);
    assert.deepEqual(await verify({}), verified);
    const browser = await manager.ensureBrowser();
    const disconnected = once(browser, 'disconnected');
    fixture.drop();
    await disconnected;
    const stale = await verify({});
    assert.equal(stale.isError, true, 'a cached version is not proof of a live persistent connection');
    assert.match(stale.content[0].text, /disconnected/);
    assert.deepEqual(await verify({}), stale);
    assert.equal(fixture.attaches, 1, 'stale verification must not reconnect');
  } finally {
    await server?.close();
    await fixture.close();
  }
});
