---
summary: 'Browser tool design and Chrome DevTools MCP permission flow'
read_when:
  - 'working on browser automation'
  - 'debugging Chrome DevTools MCP integration'
  - 'deciding whether to use Peekaboo native tools or browser page tools'
---

# Browser Tool (Chrome DevTools MCP)

Peekaboo exposes a native `browser` tool that brokers Chrome DevTools MCP. Agents call it through MCP, and scripts can use the dedicated `peekaboo browser` CLI wrapper. Use it for Chrome page content:

- DOM/accessibility snapshots
- page-level click/fill/type/navigation
- console and network inspection
- page screenshots
- performance traces

Use Peekaboo native tools for macOS UI, browser chrome, menus, dialogs, permissions, window management, and non-browser apps.

## Permission flow

Chrome DevTools MCP `--auto-connect` attaches to an already-running Chrome profile. It requires:

1. Chrome 144 or newer.
2. Chrome running locally.
3. Remote debugging enabled at `chrome://inspect/#remote-debugging`.
4. User approval in Chrome's remote debugging permission prompt.

Peekaboo does not approve that prompt automatically. The browser tool reports instructions when it is disconnected or when connection fails.

## Privacy defaults

Peekaboo starts Chrome DevTools MCP with:

```bash
npx -y chrome-devtools-mcp@1.6.0 \
  --auto-connect \
  --channel=<stable|beta|dev|canary> \
  --experimentalPageIdRouting \
  --no-usage-statistics \
  --no-performance-crux
```

Peekaboo pins the verified Chrome DevTools MCP version because direct page-ID routing is an experimental upstream
contract. Upgrade the pin only after its page-scoped tool schemas and routing behavior have been revalidated.

For deterministic local tests or custom Chrome endpoints:

- `PEEKABOO_BROWSER_MCP_ISOLATED=1` lets Chrome DevTools MCP launch a temporary Chrome profile.
- `PEEKABOO_BROWSER_MCP_HEADLESS=1` makes that launched browser headless.
- `PEEKABOO_BROWSER_MCP_BROWSER_URL=http://127.0.0.1:9222` connects to an explicit debuggable Chrome endpoint instead of auto-connect.

The tool can expose page content, cookies/session-backed data visible to the page, console messages, network requests, screenshots, and traces to the active agent/MCP client. Do not enable it for browser profiles containing sensitive data unless that exposure is acceptable.

## Persistence

Browser MCP state is owned by `BrowserMCPService` through `BrowserMCPSessionManager`.

- In a local MCP process, the browser tool uses the `BrowserMCPService` from `MCPToolContext`.
- In daemon-backed mode, `RemotePeekabooServices` forwards browser status/connect/execute calls over the Bridge socket.
- The daemon owns the `chrome-devtools-mcp` child process and per-page snapshot UID state.
- Browser page actions auto-connect through the same session manager. If a call names a different Chrome channel than the active session, the manager reconnects to that channel before forwarding the action.
- Peekaboo enables Chrome DevTools MCP's page-ID routing. Every page-scoped action requires `page_id` and is
  routed directly to that page instead of relying on the process-global selected page. The upstream MCP server
  serializes calls with its FIFO tool mutex, so concurrent agents cannot redirect one another between selection
  and execution.
- This lets separate `peekaboo mcp serve` stdio sessions reuse the same browser connection.

Use `peekaboo daemon status` to see browser connection state, tool count, and detected Chrome channels.

## Actions

Common actions:

- `status`
- `connect`
- `disconnect`
- `list_pages`
- `select_page`
- `new_page`
- `navigate`
- `wait_for`
- `snapshot`
- `click`
- `fill`
- `type`
- `press_key`
- `console`
- `network`
- `screenshot`
- `performance_trace`

Advanced escape hatch:

- `call` with `mcp_tool` and `mcp_args_json` forwards a raw tool from the audited, pinned Chrome DevTools MCP
  v1.6.0 catalog. Page-targeted raw tools require the wrapper's top-level `page_id`; Peekaboo validates and injects
  it as upstream `pageId`, overriding any nested value in `mcp_args_json`. Truly global tools such as `list_pages`
  do not require `page_id`. `trigger_extension_action` is audited but blocked because upstream still resolves its
  shared selected page internally; Peekaboo will not forward it until upstream supports explicit `pageId` routing.
  Unknown raw tool names fail closed until the routing contract is audited and updated.

Start page work with `list_pages` or `new_page`, retain the returned page ID, and include it in every later
page-scoped action. `select_page` and `new_page` stay in the background by default. Use `bring_to_front: true` or
`background: false` only when foreground interaction is intentional.

## Examples

CLI:

```bash
peekaboo browser status --json
peekaboo browser connect --channel stable
peekaboo browser new-page --url https://example.com
peekaboo browser navigate --page-id 2 --url https://example.com/docs
peekaboo browser snapshot --page-id 2 --path /tmp/page.txt
peekaboo browser network --page-id 2 --resource-type xhr --page-size 20 --json
```

MCP JSON:

```json
{ "action": "status" }
```

```json
{ "action": "connect", "channel": "stable" }
```

```json
{ "action": "snapshot", "page_id": 2 }
```

```json
{ "action": "fill", "page_id": 2, "uid": "1_7", "value": "peter@example.com", "include_snapshot": true }
```

```json
{ "action": "network", "page_id": 2, "page_size": 20, "resource_types": ["xhr", "fetch"] }
```

```json
{ "action": "performance_trace", "page_id": 2, "trace_action": "start", "reload": true, "auto_stop": true }
```
