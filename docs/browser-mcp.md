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

Peekaboo attaches to an already-running Chrome profile. It requires:

1. Chrome 144 or newer.
2. Chrome running locally.
3. Remote debugging enabled at `chrome://inspect/#remote-debugging`.
4. User approval in Chrome's remote debugging permission prompt.

Peekaboo recognizes running channels by exact Chrome bundle identifier, so app-owned helper or XPC service names cannot
be mistaken for another browser process. Native channel mode also requires the live process to satisfy Google's
Apple-anchored code-signing requirement for Team ID `EQHXZ8M8AV`. Peekaboo pins its exact signed channel identifier,
Team ID, and CDHash to the PID generation before opening the approval-gated WebSocket, then requires the same identity
after `Browser.getVersion` and around every later listener revalidation. Peekaboo does not approve the prompt
automatically. Once Chrome publishes
`DevToolsActivePort`, channel connect reads that owner-controlled file without following symlinks, proves that its one
exact loopback listener belongs to the detected Chrome PID and process generation, and opens the exact published
WebSocket. That native connection remains
pending while Chrome shows its approval prompt, has a bounded 60-second wait, sends CDP `Browser.getVersion`, and then
revalidates the process-owned listener. Peekaboo then closes the native probe and passes its exact WebSocket URL identity
as `--wsEndpoint` to Chrome DevTools MCP; the separately owned MCP child opens the second and final WebSocket used for
execution. A new explicit foreground channel connect therefore creates exactly two legitimate WebSocket connections,
and Chrome may show one approval dialog for each. Once the child is connected, status, repeated connect, and browser
execution revalidate the active-port file, kernel listener, PID generation, and bundle without opening another native
WebSocket or prompting again. Peekaboo never uses legacy HTTP discovery for channel mode or asks the MCP child to
rediscover an ambient browser.

## Privacy defaults

Peekaboo starts Chrome DevTools MCP with:

```bash
npx -y chrome-devtools-mcp@1.6.0 \
  --wsEndpoint=ws://127.0.0.1:<port>/devtools/browser/<id> \
  --experimentalPageIdRouting \
  --experimentalStructuredContent \
  --no-usage-statistics \
  --no-performance-crux
```

Peekaboo pins the verified Chrome DevTools MCP version because direct page-ID routing and the structured response data
used to mint opaque page/element capabilities are experimental upstream contracts. Upgrade the pin only after its
page-scoped schemas, structured response surfaces, and routing behavior have been revalidated.

For deterministic legacy CLI tests or custom Chrome endpoints:

- `PEEKABOO_BROWSER_MCP_ISOLATED=1` lets the standalone browser CLI launch a temporary Chrome profile. Authenticated
  MCP and Agent capability sessions reject this mode before provider startup because the child does not expose a
  browser identity that Peekaboo can bind to caller-owned opaque references.
- `PEEKABOO_BROWSER_MCP_HEADLESS=1` makes that launched browser headless.
- `PEEKABOO_BROWSER_MCP_BROWSER_URL=http://127.0.0.1:9222` connects to an explicit debuggable Chrome endpoint instead of auto-connect.

The CLI exposes the safer request-carried equivalent:

```bash
peekaboo browser connect --browser-url http://127.0.0.1:9222 --foreground --json
```

Only loopback HTTP endpoints are accepted. This explicit-URL mode resolves `/json/version`, pins the returned browser WebSocket
identity, probes `list_pages` before reporting connected, and revalidates that identity before every later tool call.
It is the compatibility path for custom or non-Google-signed debuggable browsers; unlike native channel discovery, it
does not claim a Google code-signing identity or process-bound channel receipt.
When multiple Chrome processes share one channel, channel-only connection refuses and requires this exact endpoint.
Channel discovery reads only the standard current-user profile for the chosen Chrome channel; a headless or custom
profile cannot substitute an arbitrary authority file for a detected GUI browser.

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
  they never auto-connect implicitly. The pinned provider grants browser user activation to every Puppeteer page
  evaluation, including internal page-title, stable-DOM, snapshot, and element-geometry work. Background contexts
  therefore expose only source-audited routes that cannot reach that path and refuse the rest before provider I/O.
- In Bridge-backed MCP mode, an explicit `--browser-handoff <absolute-private-path>` plus one exact `--bridge-socket`
  opens an authenticated caller-scoped transport. A foreground `peekaboo browser connect --handoff-file` on that same
  socket first writes the canonical signed receipt. The Bridge consumes it once, validates the caller, listener/host
  generation, exact target receipt, claim, and provider epoch, then creates a distinct scoped Chrome DevTools MCP child.
  Scoped status, execution, disconnect, and terminal end all carry the opaque session ID. Status returns the provider
  epoch, and execution re-presents that epoch with the exact connection receipt; the remote client remints page and
  element references for its caller and never falls back to the root connection.
- The selected runtime host owns the `chrome-devtools-mcp` child process and per-page snapshot UID state.
- Separate legacy CLI invocations require the same current-build reusable daemon. Bridge-scoped handoff instead
  requires a current host advertising authenticated browser-session bootstrap/control; older hosts reject it before
  the MCP server starts.
- Native channel connections and explicit loopback URLs both resolve to an exact WebSocket and are eligible for
  receipt-bound execution. Isolated-profile children remain unbound because the child does not report a pinnable
  browser identity.
- Child-process loss, PID reuse, endpoint restart, or an attempted retarget fails closed with reconnect guidance. Peekaboo
  never silently rediscovers another same-channel profile.
- Receipt-bound execution resolves a complete WebSocket browser identity and compares that identity inside the browser
  execution gate before the first call. Channel receipts additionally carry the owning PID, process generation, and
  exact Chrome bundle identity. Bridge protocol 1.34 and the `nativeBrowserConnectionBinding` capability gate this
  combined process-and-DevTools contract; downgraded hosts may still use an explicit loopback `browser_url` but cannot
  perform channel discovery or accept a process-bound browser receipt.
  Calls that can reach provider evaluation require explicit foreground authority and report browser-protocol foreground
  delivery even when Chrome remains visually behind another app. Multi-call responses retain exact completed and
  dispatched-or-accepted counts;
  a later failure returns a typed retry-unsafe outcome so callers resume only after observation, never by replaying the
  whole batch.
- Active upload cancellation terminates the exact MCP child before deleting its private transfer root; an operation ID
  prevents delayed cancellation cleanup from terminating a newer browser session.
- Peekaboo enables Chrome DevTools MCP's page-ID routing. Every page-scoped action requires `page_id` and is
  routed directly to that page instead of relying on the process-global selected page. The upstream MCP server
  serializes calls with its FIFO tool mutex, so concurrent agents cannot redirect one another between selection
  and execution.
- Persistent MCP and Agent sessions, including authenticated Bridge-scoped sessions, never receive Chrome's
  process-local page integers or snapshot-local UIDs as mutation authority. `list_pages` and `new_page` project opaque
  caller-owned page references, and browser snapshots project
  opaque element references bound to the exact connection, MCP child epoch, backend page, navigation generation, and provider node,
  frame, loader, or navigation identity when Chrome supplies it. A newer snapshot invalidates prior element refs;
  navigation, disconnect, connection replacement, and MCP-session teardown invalidate their complete subordinate
  namespace. Before element dispatch, the same provider gate takes a fresh snapshot and proves every provider UID is
  still present in the current document. References copied into another caller session fail before Chrome dispatch.
- Independently authenticated process-local browser sessions own separate Chrome DevTools MCP children and FIFO
  execution/mutation gates, so one blocked session does not stall another while calls within each session remain
  ordered. Peekaboo reserves the canonical process/DevTools target before permission-bearing provider setup; two
  sessions therefore cannot even transiently connect or probe the same exact target. Authenticated sessions refuse
  isolated-profile children before provider startup because their intentionally receiptless browser identity cannot
  support caller-owned opaque references. Launch a separate headless Chrome and connect through its exact loopback
  `browser_url` when a non-GUI browser is required. Foreground-capable
  browser setup/activation remains on the shared desktop lane, and failed snapshot invalidation is kept in one ordered
  cross-session ledger that every browser and desktop mutation must drain before dispatch. Bridge-backed sessions use
  the authenticated browser-session namespace: each claim owns its provider child, exact target receipt, provider
  epoch, opaque-reference namespace, and cleanup lifecycle. Ambiguous opens retry only with the same claim and payload;
  ambiguous end cleanup retains the exact handle until confirmed, while wrong-owner or host-generation failures become
  terminal without unsafe replay.
- On the selected runtime host, each browser-enabled `peekaboo mcp serve` session, or server consuming an explicit
  browser handoff, owns and tears down its own browser child. Without an authenticated
  Bridge handoff, the background-only default starts disconnected and cannot bootstrap browser control. To authorize
  setup for that exact server-owned child,
  start `peekaboo mcp serve --allow-foreground` and invoke its `browser` `connect` action; user-activating page operations
  require the same explicit server authority and use the resulting caller-owned connection. This scoped connection must use a native Chrome channel or an exact loopback
  `browser_url`; isolated mode is reserved for legacy standalone CLI sessions. With a Bridge handoff, the background
  server instead starts bound to the transferred exact connection and does not expose `connect`.

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
  reject `page_id`. UID-bearing raw schemas are resolved only at their audited positions, including
  `evaluate_script.args`, form elements, and third-party singleton `{ "uid": ... }` parameters; unrelated domain
  fields named `uid` remain data. Raw page-list and snapshot responses receive the same opaque projection. Snapshot
  file output is refused in capability sessions because the provider artifact would contain unprojected UIDs. Error,
  non-snapshot success, content-item metadata/resources, status-prefixed, structured-message, fallback-page-note, and
  upload responses project their provider-owned fields too, without rewriting page titles, script values, or other
  domain data. Provider page/UID tokens and private staging paths therefore never become caller authority or
  diagnostics. Provider error payloads are reduced to a safe generic diagnostic while retaining Peekaboo's canonical
  outcome metadata, because arbitrary error objects cannot distinguish provider identifiers from domain data.
  Text-only snapshots never mint element capabilities: without a structured snapshot, page-controlled
  multiline accessibility text makes line-leading `uid=` rows fundamentally ambiguous, so Peekaboo fails closed.
  `trigger_extension_action` is audited but blocked because upstream still resolves its
  shared selected page internally; Peekaboo will not forward it until upstream supports explicit `pageId` routing.
  Unknown raw tool names fail closed until the routing contract is audited and updated.
  Background schemas advertise only raw routes with a request-provable no-user-activation variant. Any route that can
  reach Puppeteer evaluation—including `evaluate_script`, page-list formatting, snapshots, waits, or element work—is
  hidden and refused before provider entry. Use explicit CLI `--foreground`, MCP `--allow-foreground`, or Agent
  `--allow-foreground` authority when those operations are intended.

In a foreground-authorized MCP or Agent session, start page work with `list_pages` or `new_page`, retain the returned opaque page reference, and include it
as `page_id` in every later page-scoped action. Retain element references only from the newest snapshot for that page.
The standalone CLI continues to expose the provider page integer because each CLI invocation is an explicit
compatibility boundary rather than a persistent caller capability namespace. `select_page` and `new_page` can keep the
page visually behind other apps, but remain foreground-authority operations because their provider response formatting
grants browser user activation. Use `bring_to_front: true` or `background: false` only when visible foreground
interaction is intentional.

`type` and `press_key` also require an opaque element reference from the newest snapshot as `uid`. Peekaboo holds one browser execution gate while it
focuses that exact uid and sends the keyboard operation; concurrent page work cannot interleave between those leaves.

## Examples

CLI:

```bash
peekaboo browser status --json
peekaboo browser connect --channel stable --foreground
peekaboo browser connect --browser-url http://127.0.0.1:9222 --foreground
peekaboo browser new-page --url https://example.com --foreground
peekaboo browser navigate --page-id 2 --url https://example.com/docs --foreground
peekaboo browser snapshot --page-id 2 --path /tmp/page.txt --foreground
peekaboo browser network --page-id 2 --request-id 7 --json
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
{ "action": "snapshot", "page_id": "bp1_<opaque>" }
```

```json
{ "action": "fill", "page_id": "bp1_<opaque>", "uid": "be1_<opaque>", "value": "peter@example.com", "include_snapshot": true }
```

```json
{ "action": "network", "page_id": "bp1_<opaque>", "page_size": 20, "resource_types": ["xhr", "fetch"] }
```

```json
{ "action": "performance_trace", "page_id": "bp1_<opaque>", "trace_action": "start", "reload": true, "auto_stop": true }
```
