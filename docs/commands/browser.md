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
peekaboo browser connect --channel stable
peekaboo browser new-page --url https://example.com
peekaboo browser snapshot --page-id 2 --path /tmp/page.txt
```

Use `peekaboo browser --help` for the complete action-specific option set. Page-scoped automation should retain the returned page ID and pass `--page-id` on later calls so concurrent browser work cannot redirect it.
