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
one running browser process. When more than one process shares a channel, use `--browser-url` with one loopback DevTools
HTTP endpoint. Connection output includes the exact PID/process generation or DevTools browser identity receipt. If the
daemon, Chrome generation, or endpoint changes, later calls fail and require an explicit reconnect.

Browser `type` and `press-key` require `--uid` from a fresh snapshot. Peekaboo focuses that exact page element and sends
the keyboard operation as one daemon-owned sequence rather than inheriting whichever control another caller focused.

`browser upload-file` requires `--page-id`, a fresh file-input `--uid`, and an absolute `--path` to a current-user
regular file no larger than 100 MiB. Peekaboo never grants Chrome DevTools MCP unrestricted filesystem access. The daemon
copies the already-open source into its private browser-session temporary root, preserves only the source basename, and
retains that read-only copy until disconnect so delayed page reads and form submission remain valid. Symlinks,
directories, special files, traversal paths, ownership changes, and size or identity races fail before browser dispatch.
