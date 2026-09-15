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
    if (metadata.name !== 'chrome-devtools-mcp' || metadata.version !== '1.9.0') {
      throw new Error('Peekaboo: unexpected Chrome DevTools MCP package');
    }
    const entry = join(root, 'build/src/bin/chrome-devtools-mcp.js');
    const target = pathToFileURL(join(root, 'build/src/ToolHandler.js')).href;
    const browserTarget = pathToFileURL(join(root, 'build/src/browser.js')).href;
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
              'fc6ae43cb8f6007eba4b0f269290ec8fea6db7670686d17967b4812d90d2cc10') {
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
              '17f861505810a9d25784fd71bf0592966f513c420b57a728b344280e97fe596c') {
            throw new Error('Peekaboo: unaudited Chrome DevTools MCP browser transport');
          }
          const before = 'const connectOptions = {';
          const after = "if (browser) throw new Error('Peekaboo: Chrome disconnected; reconnect explicitly');\\n" +
            before;
          return {...result, source: source.toString('utf8').replace(before, after)};
        }
        if (url !== target) return result;
        const source = Buffer.from(result.source);
        if (createHash('sha256').update(source).digest('hex') !==
            '49dd8d88257394e778573e3449af6e03fdc2fab73cc8370af26205aeecd8ab7d') {
          throw new Error('Peekaboo: unaudited Chrome DevTools MCP ToolHandler');
        }
        const before = 'devToolsData = await context.getDevToolsData(page);\\n' +
          '            pageUrl = context.getSelectedMcpPageUrl(page);';
        const after = 'if (ClearcutLogger.get()) {\\n' + before + '\\n            }';
        return {...result, source: source.toString('utf8').replace(before, after)};
      }
    `;
    register('data:text/javascript,' + encodeURIComponent(loader), {data: {target, browserTarget, transportTarget}});
    // Fail before starting the server (and before any browser connection) if the patch cannot load.
    await import(target);
    const {ensureBrowserConnected} = await import(browserTarget);
    const {McpServer} = await import(pathToFileURL(join(root, 'build/src/index.js')).href);
    const createServer = McpServer.from;
    McpServer.from = async function(args, options) {
      const server = await createServer.call(this, args, options);
      if (args.wsEndpoint) {
        let connection;
        server.server.registerTool('peekaboo_browser_connect', {
          description: 'Verify the exact persistent browser connection for the Peekaboo owner.',
          inputSchema: {},
        }, () => {
          // Cache failure too: no tool invocation may silently reopen Chrome's approval UI.
          connection ??= (async () => {
            const browser = await ensureBrowserConnected({wsEndpoint: args.wsEndpoint});
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
          return connection;
        });
      }
      return server;
    };
    process.argv = [process.execPath, entry, ...process.argv.slice(1)];
    await import(pathToFileURL(entry).href);
    """#
}
