---
summary: 'Index of Peekaboo CLI command docs'
read_when:
  - 'browsing available Peekaboo CLI commands'
  - 'linking to specific command docs'
---

# Command docs index

Core automation
- `agent.md` — run the autonomous agent loop.
- `app.md` — launch/quit/focus apps and list running processes with `app list`.
- `window.md` — list/move/resize/focus windows with `window list` and its sibling actions.
- `menu.md`, `menubar.md` — drive app menus and status items.
- `click.md`, `move.md`, `scroll.md`, `drag.md`, `press.md`, `type.md`, `set-value.md`, `action.md` — input primitives.
- `see.md`, `capture.md` — screenshot-only `see --no-elements`, AX-only `see --tree --no-screenshot`, annotated UI maps, and capture sessions.

System & config
- `config.md`, `permissions.md`, `bridge.md`, `daemon.md`, `tools.md`, `clean.md`, `learn.md`, `screen.md` (`screen list`).
- `completions.md` — install shell-native completions for zsh, bash, and fish.
- MCP helpers: `mcp.md`.
- Clipboard: `clipboard.md`.

Reference tips
- Each command page lists flags, examples, and troubleshooting. For common pitfalls (permissions, focus, window targeting), see the “Common troubleshooting” section below.

## Common troubleshooting
- **Background/foreground issues** — input commands use background delivery when they can resolve a target process. Element/query clicks can use Accessibility actions; grant Event Synthesizing for keyboard input, coordinates, and click fallback, or pass `--foreground` and ensure the target app/window is focused.
- **Element not found** — run `peekaboo see --annotate` to verify AX labels/roles. Background coordinate clicks require a fresh exact-window snapshot plus `--window-id`; use `--foreground` only for intentional shared-pointer fallback.
- **Permission errors** — re-run `peekaboo permissions grant` and restart affected apps if dialogs persist.
- **Slow or flaky automation** — tune `--quiet`/`--heartbeat` for capture/live commands; for input commands use `--delay` where available or `/bin/sleep` between shell invocations.
