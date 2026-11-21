/// Embedded in both the CLI and GUI host so npm-distributed providers receive the same audited patch.
enum BrowserMCPProviderBootstrap {
    /// Keep this executable source covered by scripts/test-chrome-devtools-mcp-contract.mjs.
    static let source = #"""
    import {readFileSync, realpathSync} from 'node:fs';
    import {delimiter, dirname, join} from 'node:path';
    import {pathToFileURL} from 'node:url';
    import {register} from 'node:module';

    const candidates = (process.env.PATH ?? '').split(delimiter);
    let root;
    for (const directory of candidates) {
      if (!directory.endsWith('/node_modules/.bin')) continue;
      try {
        root = dirname(realpathSync(join(directory, '../chrome-devtools-mcp/package.json')));
        break;
      } catch (error) {
        if (error.code !== 'ENOENT' && error.code !== 'ENOTDIR') throw error;
      }
    }
    if (!root) throw new Error('Peekaboo: pinned Chrome DevTools MCP package missing');
    const metadata = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
    if (metadata.name !== 'chrome-devtools-mcp' || metadata.version !== '1.13.0') {
      throw new Error('Peekaboo: unexpected Chrome DevTools MCP package');
    }
    // Ambient provider configuration must never change the owner's audited options or filesystem boundary.
    process.env.CHROME_DEVTOOLS_MCP_NO_CONFIG_DISCOVERY = '1';
    const modules = join(root, 'out/Default/gen/src');
    const entry = join(modules, 'bin/chrome-devtools-mcp.js');
    const target = pathToFileURL(join(modules, 'ToolHandler.js')).href;
    const browserTarget = pathToFileURL(join(modules, 'BrowserManager.js')).href;
    const transportTarget = pathToFileURL(join(modules, 'third_party/index.js')).href;
    const loader = `
      import {createHash} from 'node:crypto';
      let target, browserTarget, transportTarget;
      export function initialize(data) { ({target, browserTarget, transportTarget} = data); }
      function replaceOnce(source, before, after) {
        if (source.split(before).length !== 2) throw new Error('Peekaboo: audited provider patch target changed');
        return source.replace(before, after);
      }
      export async function load(url, context, nextLoad) {
        const result = await nextLoad(url, context);
        if (url === transportTarget) {
          const source = Buffer.from(result.source);
          if (createHash('sha256').update(source).digest('hex') !==
              'cc8c7a4ae5436cd0a4199e00f22527e6ff012397090e3122f429c9e1613477b4') {
            throw new Error('Peekaboo: unaudited Chrome DevTools MCP dependencies');
          }
          let patched = replaceOnce(source.toString('utf8'),
            'const ws2 = new wrapper_default(url2, [], {\\n            followRedirects: true,',
            'const ws2 = new wrapper_default(url2, [], {\\n            followRedirects: false,');
          patched = replaceOnce(patched, 'handshakeTimeout: options.handshakeTimeout,', 'handshakeTimeout: 60000,');
          return {...result, source: patched};
        }
        if (url === browserTarget) {
          const source = Buffer.from(result.source);
          if (createHash('sha256').update(source).digest('hex') !==
              '0bab07f29d0ac272c7ae0994b331863119470c4d58b24d36d50397fc1de07709') {
            throw new Error('Peekaboo: unaudited Chrome DevTools MCP browser transport');
          }
          const before = 'const connectOptions = {';
          const after = "if (this.#peekabooConnectionAttempted) throw new Error(" +
            "'Peekaboo: Chrome connection was already attempted; reconnect explicitly');\\n" +
            'this.#peekabooConnectionAttempted = true;\\n' +
            before;
          const patched = replaceOnce(source.toString('utf8'),
            '\\n    #browser;\\n', '\\n    #browser;\\n    #peekabooConnectionAttempted = false;\\n');
          return {...result, source: replaceOnce(patched, before, after)};
        }
        if (url !== target) return result;
        const source = Buffer.from(result.source);
        if (createHash('sha256').update(source).digest('hex') !==
            '0950de43850c6645815bdb5be99b560e1584cf8f6040694233678dfdca8f1dfa') {
          throw new Error('Peekaboo: unaudited Chrome DevTools MCP ToolHandler');
        }
        const before = 'const devToolsData = await context.getDevToolsData(page);\\n' +
          '        signal.throwIfAborted();\\n' +
          '        onTelemetryData(devToolsData, context.getSelectedMcpPageUrl(page));';
        const after = 'if (ClearcutLogger.get()) {\\n' + before + '\\n            }';
        return {...result, source: replaceOnce(source.toString('utf8'), before, after)};
      }
    `;
    register('data:text/javascript,' + encodeURIComponent(loader), {data: {target, browserTarget, transportTarget}});
    // Fail before starting the server (and before any browser connection) if the patch cannot load.
    await import(target);
    await import(browserTarget);
    const {McpServer} = await import(pathToFileURL(join(modules, 'index.js')).href);
    const createServer = McpServer.from;
    McpServer.from = async function(config, options) {
      const args = config.resolved;
      if (args.wsEndpoint && !options?.browserManager) {
        throw new Error('Peekaboo: provider browser owner missing');
      }
      const server = await createServer.call(this, config, options);
      if (args.wsEndpoint) {
        let connection;
        let browserConnection;
        const verifyConnection = async () => {
          // Cache failure too: no tool invocation may silently reopen Chrome's approval UI.
          connection ??= (async () => {
            const browser = await options.browserManager.ensureBrowser();
            browserConnection = browser;
            const session = await browser.target().createCDPSession();
            try {
              const version = await session.send('Browser.getVersion');
              return {content: [{type: 'text', text: JSON.stringify({
                webSocketDebuggerUrl: browser.wsEndpoint(), ...version,
              })}]};
            } finally {
              await session.detach();
            }
          })().catch(error => ({isError: true, content: [{type: 'text',
            text: 'Chrome connection failed: ' + String(error.cause?.message ?? error.message).slice(0, 512),
          }]}));
          const result = await connection;
          if (browserConnection && !browserConnection.connected) {
            return {isError: true, content: [{type: 'text',
              text: 'Chrome connection failed: Chrome disconnected; reconnect explicitly',
            }]};
          }
          return result;
        };
        server.server.registerTool('peekaboo_browser_connect', {
          description: 'Verify the exact persistent browser connection for the Peekaboo owner.',
          inputSchema: {},
        }, verifyConnection);
        // Preserve the provider's queued dispatch, schema checks, disabled-tool checks, and cancellation handling.
        const protocol = server.server.server;
        const dispatch = protocol._getRequestHandler('tools/call');
        if (typeof dispatch !== 'function') throw new Error('Peekaboo: provider tool dispatcher missing');
        protocol.setRequestHandler('tools/call', async (request, context) => {
          if (request.params.name !== 'peekaboo_browser_connect') return dispatch(request, context);
          context.mcpReq.signal.throwIfAborted();
          return protocol.projectCallToolResult(await verifyConnection(), undefined);
        });
      }
      return server;
    };
    process.argv = [process.execPath, entry, ...process.argv.slice(1)];
    await import(pathToFileURL(entry).href);
    """#
}
