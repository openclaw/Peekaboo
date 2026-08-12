---
summary: 'Index of Peekaboo CLI command docs'
read_when:
  - 'browsing available Peekaboo CLI commands'
  - 'linking to specific command docs'
---

# Command docs index

All 33 current root commands have one page here:

- Core: [`bridge`](bridge.md), [`capture`](capture.md), [`clean`](clean.md), [`completions`](completions.md), [`config`](config.md), [`daemon`](daemon.md), [`learn`](learn.md), [`permissions`](permissions.md), [`screen`](screen.md), [`tools`](tools.md).
- Interaction: [`action`](action.md), [`click`](click.md), [`drag`](drag.md), [`move`](move.md), [`paste`](paste.md), [`press`](press.md), [`scroll`](scroll.md), [`set-value`](set-value.md), [`type`](type.md).
- System: [`app`](app.md), [`clipboard`](clipboard.md), [`dialog`](dialog.md), [`dock`](dock.md), [`menu`](menu.md), [`menubar`](menubar.md), [`space`](space.md), [`visualizer`](visualizer.md), [`window`](window.md).
- Vision, AI, and MCP: [`see`](see.md), [`verify`](verify.md), [`agent`](agent.md), [`browser`](browser.md), [`mcp`](mcp.md).

Reference tips
- Each command page lists flags, examples, and troubleshooting. For common pitfalls (permissions, focus, window targeting), see the “Common troubleshooting” section below.

## Common troubleshooting
- **Background/foreground issues** — input commands use background delivery when they can resolve a target process. Element/query clicks can use Accessibility actions. Grant Event Synthesizing for synthetic keyboard/pointer input; `--foreground` only opts into intentional shared input and does not bypass that permission.
- **Element not found** — run `peekaboo see --annotate` to verify AX labels/roles. Background coordinate clicks require a fresh exact-window snapshot plus `--window-id`; use `--foreground` only for intentional shared-pointer fallback.
- **Permission errors** — re-run `peekaboo permissions grant` and restart affected apps if dialogs persist.
- **Slow or flaky automation** — tune `--quiet`/`--heartbeat` for capture/live commands; for input commands use `--delay` where available or `/bin/sleep` between shell invocations.
