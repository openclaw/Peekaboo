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
    if (metadata.name !== 'chrome-devtools-mcp' || metadata.version !== '1.10.1') {
      throw new Error('Peekaboo: unexpected Chrome DevTools MCP package');
    }
    const entry = join(root, 'build/src/bin/chrome-devtools-mcp.js');
    const target = pathToFileURL(join(root, 'build/src/ToolHandler.js')).href;
    const browserTarget = pathToFileURL(join(root, 'build/src/BrowserManager.js')).href;
    const transportTarget = pathToFileURL(join(root, 'build/src/third_party/index.js')).href;
    const loader = `
      import {createHash} from 'node:crypto';
      let target, browserTarget, transportTarget;
      export function initialize(data) { ({target, browserTarget, transportTarget} = data); }
      export async function load(url, context, nextLoad) {
        const result = await nextLoad(url, context);
        if (url === transportTarget) {
          const source = Buffer.from(result.source);
          if (createHash('sha256').update(source).digest('hex') !==
              'c988e0684584b75e87ae04b768c4f8ae7064401afe5187ec0d4878b2c6833f12') {
            throw new Error('Peekaboo: unaudited Chrome DevTools MCP dependencies');
          }
          const before = 'const ws = new WebSocket$1(url, [], {\\n                followRedirects: true,';
          const after = 'const ws = new WebSocket$1(url, [], {\\n' +
            '                followRedirects: false, handshakeTimeout: 60000,';
          return {...result, source: source.toString('utf8').replace(before, after)};
        }
        if (url === browserTarget) {
          const source = Buffer.from(result.source);
          if (createHash('sha256').update(source).digest('hex') !==
              'e8ad9ae18a6836a0e56771afbf453b4b9ea1d384b4b0db9fccca04300a9fa222') {
            throw new Error('Peekaboo: unaudited Chrome DevTools MCP browser transport');
          }
          const before = 'const connectOptions = {';
          const after = "if (this.#peekabooConnectionAttempted) throw new Error(" +
            "'Peekaboo: Chrome connection was already attempted; reconnect explicitly');\\n" +
            'this.#peekabooConnectionAttempted = true;\\n' +
            before;
          return {...result, source: source.toString('utf8')
            .replace('#browser;', '#browser;\\n    #peekabooConnectionAttempted = false;')
            .replace(before, after)};
        }
        if (url !== target) return result;
        const source = Buffer.from(result.source);
        if (createHash('sha256').update(source).digest('hex') !==
            'c2b1000dabc7c3bebba97561402e5496d0317a48c893e8eae0582a8293f948ff') {
          throw new Error('Peekaboo: unaudited Chrome DevTools MCP ToolHandler');
        }
        const before = 'devToolsData = await context.getDevToolsData(page);\\n' +
          '                pageUrl = context.getSelectedMcpPageUrl(page);';
        const after = 'if (ClearcutLogger.get()) {\\n' + before + '\\n            }';
        return {...result, source: source.toString('utf8').replace(before, after)};
      }
    `;
    register('data:text/javascript,' + encodeURIComponent(loader), {data: {target, browserTarget, transportTarget}});
    // Fail before starting the server (and before any browser connection) if the patch cannot load.
    await import(target);
    await import(browserTarget);
    const {McpServer} = await import(pathToFileURL(join(root, 'build/src/index.js')).href);
    const createServer = McpServer.from;
    McpServer.from = async function(args, options) {
      if (args.wsEndpoint && !options?.browserManager) {
        throw new Error('Peekaboo: provider browser owner missing');
      }
      const server = await createServer.call(this, args, options);
      if (args.wsEndpoint) {
        let connection;
        let browserConnection;
        server.server.registerTool('peekaboo_browser_connect', {
          description: 'Verify the exact persistent browser connection for the Peekaboo owner.',
          inputSchema: {},
        }, async () => {
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
        });
      }
      return server;
    };
    process.argv = [process.execPath, entry, ...process.argv.slice(1)];
    await import(pathToFileURL(entry).href);
    """#
}
