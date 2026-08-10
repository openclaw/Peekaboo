---
summary: 'Index of Peekaboo CLI command docs'
read_when:
  - 'browsing available Peekaboo CLI commands'
  - 'linking to specific command docs'
---

# Command docs index

Core automation
- `agent.md` — run the autonomous agent loop.
- `app.md` — launch/quit/focus apps.
- `window.md` — move/resize/focus windows.
- `menu.md`, `menubar.md` — drive app menus and status items.
- `click.md`, `move.md`, `scroll.md`, `drag.md`, `press.md`, `type.md`, `set-value.md`, `action.md` — input primitives.
- `see.md`, `capture.md` — screenshots, annotated UI maps, AX trees, and capture sessions.

System & config
- `config.md`, `permissions.md`, `bridge.md`, `daemon.md`, `tools.md`, `clean.md`, `learn.md`, `screen.md`.
- `completions.md` — install shell-native completions for zsh, bash, and fish.
- MCP helpers: `mcp.md`.
- Clipboard: `clipboard.md`.

Reference tips
- Each command page lists flags, examples, and troubleshooting. For common pitfalls (permissions, focus, window targeting), see the “Common troubleshooting” section below.

## Common troubleshooting
- **Background/foreground issues** — input commands use background delivery when they can resolve a target process. Element/query clicks can use Accessibility actions; grant Event Synthesizing for keyboard input, coordinates, and click fallback, or pass `--foreground` and ensure the target app/window is focused.
- **Element not found** — run `peekaboo see --annotate` to verify AX labels/roles; fall back to coordinates with `--coords` when needed.
- **Permission errors** — re-run `peekaboo permissions grant` and restart affected apps if dialogs persist.
- **Slow or flaky automation** — add `--quiet-ms`/`--heartbeat-sec` for capture/live commands; for input commands use `--delay` where available or `/bin/sleep` between shell invocations.
