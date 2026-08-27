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
peekaboo browser new-page --url https://example.com
peekaboo browser snapshot --page-id 2 --path /tmp/page.txt
```

Use `peekaboo browser --help` for the complete action-specific option set. Page-scoped automation should retain the returned page ID and pass `--page-id` on later calls so concurrent browser work cannot redirect it.

The CLI is background-only by default. Read and page actions reuse an existing exact browser connection and never
auto-connect. `connect` can surface Chrome's remote-debugging permission UI, so it is classified as a foreground
mutation and requires explicit `--foreground`. The same flag is required for `--bring-to-front` or a foreground new
page. If no exact live connection exists, default-mode actions fail before dispatch and ask you to connect explicitly.
In `--json` output, canonical action outcome, effect, retry safety, mutation-dispatch state, and exact desktop target
metadata are projected into the standard root CLI envelope. The original MCP metadata remains under `data.meta` for
tool-specific consumers.

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
Process-local persistent MCP and Agent callers receive opaque, session-owned page and element references instead of
these raw CLI compatibility values. Those references bind the exact provider child, cannot cross caller sessions, and
expire after a newer snapshot, navigation, disconnect, connection replacement, or session end. A durable CLI workflow
uses the same authority model through an authenticated Bridge 1.38 namespace.

## Durable Bridge namespaces

Create a namespace in an owner-private state file, then pass both that file and the exact issuing Bridge socket on every
invocation. The destination must be absent. Peekaboo creates a missing final parent directory with mode `0700`; an
existing parent must already be owned by the current user, mode `0700`, and free of extended ACLs. The created receipt
is a bounded regular file with mode `0600`.

```bash
NAMESPACE_FILE="$HOME/.peekaboo/browser-namespaces/work.json"
BRIDGE_SOCKET="$HOME/Library/Application Support/Peekaboo/daemon.sock"

peekaboo browser namespace-create \
  --namespace-file "$NAMESPACE_FILE" --bridge-socket "$BRIDGE_SOCKET"
peekaboo browser connect --channel stable --foreground \
  --namespace-file "$NAMESPACE_FILE" --bridge-socket "$BRIDGE_SOCKET"
peekaboo browser list-pages \
  --namespace-file "$NAMESPACE_FILE" --bridge-socket "$BRIDGE_SOCKET"
peekaboo browser bind-window --page-id bp1_... --pid 123 --window-id 456 \
  --namespace-file "$NAMESPACE_FILE" --bridge-socket "$BRIDGE_SOCKET"
peekaboo browser snapshot --page-id bp1_... \
  --namespace-file "$NAMESPACE_FILE" --bridge-socket "$BRIDGE_SOCKET"
peekaboo browser namespace-close \
  --namespace-file "$NAMESPACE_FILE" --bridge-socket "$BRIDGE_SOCKET"
```

`connect` and any operation that intentionally brings a page forward still require `--foreground`; page-targeted work
remains background by default. The opaque `bp1_`/`be1_` references never expose provider target IDs. The namespace
receipt is bound to one Bridge listener generation and principal, so another socket or a restarted listener refuses it
before provider dispatch. `namespace-close` removes the local receipt only after that exact host confirms closure.

Native `bind-window` requires a process-bound official Chrome channel connection. Explicit loopback URLs may be used
for unbound namespace actions but cannot claim native PID/window binding. Legacy browser commands without
`--namespace-file` retain their numeric page-ID compatibility path and cannot borrow namespace capabilities.

`browser upload-file` requires `--page-id`, a fresh file-input `--uid`, and an absolute `--path` to a current-user
regular file no larger than 100 MiB. Peekaboo never grants Chrome DevTools MCP unrestricted filesystem access. The daemon
copies the already-open source into its private browser-session temporary root, preserves only the source basename, and
retains that read-only copy until disconnect so delayed page reads and form submission remain valid. Symlinks,
directories, special files, traversal paths, ownership changes, and size or identity races fail before browser dispatch.
