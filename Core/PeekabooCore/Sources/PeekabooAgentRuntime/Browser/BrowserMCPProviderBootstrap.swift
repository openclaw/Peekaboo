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
    const loader = `
      import {createHash} from 'node:crypto';
      let target;
      export function initialize(data) { target = data.target; }
      export async function load(url, context, nextLoad) {
        const result = await nextLoad(url, context);
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
    register('data:text/javascript,' + encodeURIComponent(loader), {data: {target}});
    // Fail before starting the server (and before any browser connection) if the patch cannot load.
    await import(target);
    process.argv = [process.execPath, entry, ...process.argv.slice(1)];
    await import(pathToFileURL(entry).href);
    """#
}
