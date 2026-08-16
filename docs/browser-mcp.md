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

The CLI exposes the safer request-carried equivalent:

```bash
peekaboo browser connect --browser-url http://127.0.0.1:9222 --foreground --json
```

Only loopback HTTP endpoints are accepted. Peekaboo resolves `/json/version`, pins the returned browser WebSocket
identity, probes `list_pages` before reporting connected, and revalidates that identity before every later tool call.
When multiple Chrome processes share one channel, channel-only connection refuses and requires this exact endpoint.

The tool can expose page content, cookies/session-backed data visible to the page, console messages, network requests, screenshots, and traces to the active agent/MCP client. Do not enable it for browser profiles containing sensitive data unless that exposure is acceptable.

Browser uploads are host-owned. Peekaboo gives each Chrome DevTools MCP child one private owner-only temporary root and
does not pass `--allowUnrestrictedPaths`. Every mapped or raw `upload_file` call is intercepted before dispatch: the
source must be an absolute, current-user-owned regular file no larger than 100 MiB, opened without following a final
symlink, and copied from that checked descriptor into a read-only transfer directory under the child root. The copy is
kept for the exact browser session because Chrome can read an attached file after the upload tool returns; it is removed
only after the MCP child terminates on disconnect, connection loss, endpoint drift, or cancellation. External upload
authorization remains the caller's responsibility.

## Persistence

Browser MCP state is owned by `BrowserMCPService` through `BrowserMCPSessionManager`.

- In a local MCP process, the browser tool uses the `BrowserMCPService` from `MCPToolContext`. Public MCP and
  standalone Browser contexts default to background-only and require an existing live exact connection receipt;
  they never auto-connect implicitly.
- In daemon-backed mode, `RemotePeekabooServices` forwards browser status/connect/execute calls over the Bridge socket.
- The daemon owns the `chrome-devtools-mcp` child process and per-page snapshot UID state.
- Separate CLI invocations require the same current-build reusable daemon. Peekaboo.app and older Bridge hosts are not
  eligible for browser session routing because they cannot attest the exact persistent connection receipt.
- Channel `--auto-connect` and isolated-profile children remain available for unbound and protocol 1.28 browser calls,
  but they are not eligible for protocol 1.29 receipt-bound execution because the MCP child cannot yet attest which
  browser it actually selected.
- Child-process loss, PID reuse, endpoint restart, or an attempted retarget fails closed with reconnect guidance. Peekaboo
  never silently rediscovers another same-channel profile.
- Receipt-bound execution requires an explicit CLI or environment DevTools URL, resolves it to a complete WebSocket
  browser identity, and compares that identity inside the browser execution gate before the first call. Protocol 1.29
  signs the full explicit endpoint receipt; it never infers the MCP child's attachment from ambient Chrome processes.
  Multi-call responses retain exact completed and dispatched-or-accepted counts;
  a later failure returns a typed retry-unsafe outcome so callers resume only after observation, never by replaying the
  whole batch.
- Active upload cancellation terminates the exact MCP child before deleting its private transfer root; an operation ID
  prevents delayed cancellation cleanup from terminating a newer browser session.
- Peekaboo enables Chrome DevTools MCP's page-ID routing. Every page-scoped action requires `page_id` and is
  routed directly to that page instead of relying on the process-global selected page. The upstream MCP server
  serializes calls with its FIFO tool mutex, so concurrent agents cannot redirect one another between selection
  and execution.
- Separate `peekaboo mcp serve` stdio sessions reuse one browser connection only when each server is explicitly routed
  to the same reusable daemon Bridge socket. A process-local MCP server has its own browser state.

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

`type` and `press_key` also require a fresh snapshot `uid`. Peekaboo holds one browser execution gate while it
focuses that exact uid and sends the keyboard operation; concurrent page work cannot interleave between those leaves.

## Examples

CLI:

```bash
peekaboo browser status --json
peekaboo browser connect --channel stable --foreground
peekaboo browser connect --browser-url http://127.0.0.1:9222 --foreground
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

The MCP server is background-only and refuses that `connect` request before dispatch. To share a connection, route
both the explicit foreground CLI connection and the MCP server to the same reusable daemon:

```bash
peekaboo daemon start
peekaboo browser connect --channel stable --foreground \
  --bridge-socket "$HOME/Library/Application Support/Peekaboo/daemon.sock"
peekaboo mcp serve \
  --bridge-socket "$HOME/Library/Application Support/Peekaboo/daemon.sock"
```

A default process-local `peekaboo mcp serve` cannot reuse browser state created by a separate CLI process.

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
