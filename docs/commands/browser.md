---
summary: 'Control Chrome page content via peekaboo browser'
read_when:
  - 'automating Chrome DOM content through the browser MCP bridge'
  - 'inspecting browser console, network, screenshots, or traces'
---

# `peekaboo browser`

`browser` is the CLI wrapper around Peekaboo's browser MCP tool. It handles page-level Chrome operations such as connection status, navigation, snapshots, element actions, console/network inspection, screenshots, and performance traces. Use native Peekaboo commands for browser chrome, macOS dialogs, menus, and windows.

The action is positional and defaults to `status`.

```bash
peekaboo browser status --json
peekaboo browser connect --channel stable --foreground
peekaboo browser connect --browser-url http://127.0.0.1:9222 --foreground
peekaboo browser new-page --url https://example.com --foreground
peekaboo browser snapshot --page-id 2 --path /tmp/page.txt --foreground
```

Use `peekaboo browser --help` for the complete action-specific option set. Page-scoped automation should retain the returned page ID and pass `--page-id` on later calls so concurrent browser work cannot redirect it.

The CLI is background-only by default. Chrome DevTools MCP 1.6.0's bundled Puppeteer grants browser user activation to
every page evaluation, including evaluation used internally for page titles, stable-DOM waits, snapshots, and element
geometry. Default mode therefore exposes only source-audited routes that cannot enter that evaluation path. Page
discovery, snapshots, navigation, waits, element interaction, and arbitrary script evaluation refuse before provider
I/O unless the caller passes `--foreground`; accepted calls report `browser_protocol` / `foreground` delivery even if
the page remains visually behind another app. Exact positive-ID network lookup, page screenshot without an element,
console listing, emulation, Lighthouse, performance trace operations, and heap capture retain background routes.
Those source-audited calls report `browser_protocol` / `background` delivery.
All default calls require an existing exact browser connection receipt and never ambiently auto-connect. With explicit
`--foreground`, only standalone CLI page actions may auto-connect when no receipt exists. Persistent MCP, Agent, and
Bridge-scoped page actions never ambiently auto-connect.
Use explicit `connect` for a foreground-authorized child, or transfer an exact signed handoff into a background
Bridge-scoped MCP child. `connect` can surface Chrome's remote-debugging permission UI, so it is classified as a
foreground mutation and requires explicit `--foreground`. The same flag is required for `--bring-to-front` or a
foreground new page. If no exact live connection exists, default-mode actions fail before dispatch and ask you to
connect explicitly.
In `--json` output, canonical action outcome, effect, retry safety, mutation-dispatch state, and exact desktop target
metadata are projected into the standard root CLI envelope. The original MCP metadata remains under `data.meta` for
tool-specific consumers.

If a status request times out or its transport fails, connection state, tool count, and Chrome discovery are unknown,
not a confirmed disconnection or absence. Output marks `status_observation=indeterminate` and uses JSON `null` for
`connected`, `tool_count`, `browser_count`, and `channels`. Any retained exact connection fields identify only the
last confirmed connection. A failed status observation does not explain or resolve an earlier uncertain action.
If connect may have dispatched but cannot supply trustworthy target attribution, it remains indeterminate and unsafe
to retry; its bounded original failure diagnostic accompanies the attribution error without creating a target receipt.

`dom-click --page-id <id> --uid <uid> --foreground` invokes one synthetic `element.click()` through the pinned
provider's `evaluate_script` route. It avoids CDP/Puppeteer pointer input, but evaluation still grants browser user
activation: background mode refuses before provider I/O and authorized calls report foreground delivery. It is not
background-safe and does not guarantee Chrome will remain behind another app.

This is not a trusted pointer click: it does not move the pointer, hit-test, or send a pointer-down/up sequence.
Disabled controls can do nothing, and handlers requiring trusted input may not react. `double` and `include_snapshot`
do not apply. A successful script return means only that the invocation returned, not that a handler ran, navigation
completed, or the intended effect occurred. Observe the intended page before deciding whether to retry.
The CLI retains its existing numeric page ID and snapshot-local UID compatibility boundary; this action does not add
durable cross-invocation capabilities. Persistent MCP/Agent callers use the caller-owned references described below.

Browser state is owned by one current-build reusable daemon across CLI invocations. Channel connection requires exactly
one running official Google-signed Chrome process (Team ID `EQHXZ8M8AV`). Peekaboo pins the signed channel identifier,
Team ID, and CDHash to its PID generation, safely reads that channel's standard `DevToolsActivePort`, proves its unique
loopback listener belongs to the detected PID/process generation, keeps the exact WebSocket pending through Chrome's
approval prompt, verifies it with CDP `Browser.getVersion`, rechecks signer and listener ownership, and gives Chrome DevTools MCP
only that same WebSocket identity. When more than one process shares a channel, use `--browser-url` with one loopback
DevTools HTTP endpoint. That explicit URL is also the compatibility path for custom or non-Google-signed debuggable
browsers and does not claim native channel signer authority. Connection output includes the combined process and
DevTools identity receipt. If the daemon, Chrome generation, signer, listening socket, or endpoint changes, later calls
fail and require an explicit reconnect.

Browser `type` and `press-key` require `--uid` from a fresh snapshot. Peekaboo focuses that exact page element and sends
the keyboard operation as one daemon-owned sequence rather than inheriting whichever control another caller focused.
Persistent MCP and Agent callers, including Bridge-routed Agents, receive opaque, session-owned page and element
references instead of these raw CLI compatibility values. Those references bind the exact provider child and cannot
cross caller sessions. A newer snapshot or navigation expires the affected page's element references. Closing a page
expires that page's namespace; disconnect, connection replacement, or session end expires the complete caller
namespace. A current Bridge host also supports caller-scoped opaque-reference MCP sessions through an explicit
authenticated handoff. First run
`peekaboo browser connect --foreground --bridge-socket <socket> --handoff-file <absolute-private-path>` to connect the exact
browser and atomically write its signed one-shot receipt. Then start
`peekaboo mcp serve --bridge-socket <same-socket> --browser-handoff <same-path>`. The Bridge validates the caller, listener
generation, exact target receipt, claim, and provider epoch before creating a separate scoped child; status, execution,
disconnect, and end stay bound to that namespace, and no request can fall back to the Bridge's root browser connection.
Older or incompatible hosts refuse the handoff before MCP serving begins.

The handoff path requires a current-user-owned parent directory with mode `0700` and a current-user-owned regular,
single-link receipt with mode `0600`. Both must have zero extended ACLs and zero extended attributes, including OS
provenance; symlink paths are refused. `mkdir -m 700` establishes the necessary parent mode but is not sufficient:
newly created directories and files can carry OS metadata, and mode changes do not remove it. Diagnostics distinguish
detected attributes, detected ACLs, and inspection failures, naming the parent or receipt without reading or printing
attribute values. This is diagnostic guidance, not compatibility with metadata-producing environments. An unsafe
parent is refused before connect runtime construction; an unsafe newly created receipt fails publication and triggers
the existing reserved-target disconnect. MCP receipt loading fails before runtime construction, with no fallback.

`browser upload-file` requires `--page-id`, a fresh file-input `--uid`, and an absolute `--path` to a current-user
regular file no larger than 100 MiB. Peekaboo never grants Chrome DevTools MCP unrestricted filesystem access. The daemon
copies the already-open source into its private browser-session temporary root, preserves only the source basename, and
retains that read-only copy until disconnect so delayed page reads and form submission remain valid. Symlinks,
directories, special files, traversal paths, ownership changes, and size or identity races fail before browser dispatch.
