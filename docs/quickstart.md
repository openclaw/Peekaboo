---
title: Quickstart
summary: 'First-run walkthrough for permissions, capture, see, click, type, agent mode, and MCP setup.'
description: First capture, first click, first agent run with Peekaboo. Five minutes from install to working automation.
read_when:
  - 'validating a fresh Peekaboo install'
  - 'showing users the shortest path from install to working automation'
---

# Quickstart

This page assumes you've already followed [install.md](install.md). If `peekaboo --version` prints a version, you're ready.

## 1. Grant permissions

```bash
peekaboo permissions status
peekaboo permissions grant
peekaboo permissions request screen-recording
```

`grant` opens System Settings to the right pane. You need **Screen Recording** and **Accessibility**; both are required. Re-run `permissions status` until both are green. Background keyboard input and foreground synthetic pointer tools need **Event Synthesizing**; it is an action-specific grant rather than a global requirement. Background element/query/coordinate clicks use Accessibility. See [permissions.md](permissions.md).

## 2. Take a screenshot

```bash
# whole screen -> ./screen.png
peekaboo see --no-elements --mode screen --path screen.png

# only the focused window
peekaboo see --no-elements --mode frontmost --path focused.png

# a specific app's frontmost window
peekaboo see --no-elements --app Safari --path safari.png
```

The output is a regular PNG. Add `--format jpg` for JPEG output. See [commands/see.md](commands/see.md) for every flag.

If you are running from SSH, a LaunchAgent, Codex, or another background launchd session, use a Peekaboo Bridge
host with Screen Recording permission. `--capture-engine` keeps that selected host; caller-local overrides require
`--no-remote` and are for debugging because they can produce wallpaper-only screenshots in background sessions.

Normal CLI automation uses a healthy reusable daemon, then a capable Peekaboo.app Bridge host, and otherwise starts
the daemon on demand. `peekaboo bridge status --verbose` shows the selected runtime.

## 3. Inspect the UI

`see` returns a structured map of clickable elements with fresh IDs:

```bash
peekaboo see --app Safari --json --path /tmp/safari-see.png | jq '.data.ui_elements[0:3]'
```

Add `--annotate` to write a labelled PNG you can eyeball:

```bash
peekaboo see --app Safari --annotate --path /tmp/safari.png
```

Each element has `id`, `role`, `label`, `frame`, and `actions`. Pass an `id` to other commands to act on it.

## 4. Click and type

```bash
peekaboo click "Address and search bar" --app Safari
peekaboo type "github.com/openclaw/Peekaboo" --app Safari
peekaboo press Return --app Safari --foreground
```

Coordinate clicks need a fresh capture receipt and an exact target in the default background mode. First run
`peekaboo window list --app Safari --json`, copy the intended `window_id`, and capture that exact window:

```bash
CAPTURE=$(peekaboo see --window-id "$WINDOW_ID" --no-elements --json)
SNAPSHOT_ID=$(printf '%s' "$CAPTURE" | jq -r '.data.snapshot_id')
peekaboo click --window-id "$WINDOW_ID" --snapshot "$SNAPSHOT_ID" --at 480,120
```

The point is relative to the captured window. Add `--global` for screen coordinates, or add `--foreground` only when
the target app requires focused synthetic input. See [automation.md](automation.md) for the full input vocabulary.

Targeted click and type use background delivery by default, so Safari can receive them without becoming frontmost. Raw
`press` can stay background with a fresh exact-window/snapshot receipt; app/PID-only or targetless chords require
explicit `--foreground`. Prefer semantic actions for background confirmation when one exists.

Targeted `scroll --on <id>` is background-safe through Accessibility or, for a fresh exact-window pixel snapshot of a visible WebKit surface, PID-routed wheel events. The latter reports an unverifiable effect and must be observed before retry. Targetless/smooth scroll, `move`, and `drag` use the shared physical cursor and require explicit `--foreground`.

## 5. Run an agent

The agent picks tools, plans, and executes — give it a goal in natural language:

```bash
peekaboo agent "Open Safari, go to github.com, and search for Peekaboo" --allow-foreground
```

Cold-launching Safari needs the explicit foreground opt-in shown above. Default background work against already-running
targets stays overlay-free so Peekaboo does not interrupt the foreground desktop. Run
`peekaboo visualizer` when you explicitly want to exercise the overlay catalog. Continue a saved run with
`peekaboo agent resume <session-id>`. See [commands/agent.md](commands/agent.md) for provider switching and session management.

## 6. (Optional) Wire up MCP

Want Codex, Claude Code, or Cursor to drive Peekaboo? Drop this into your MCP client config:

```json
{
  "mcpServers": {
    "peekaboo": {
      "command": "npx",
      "args": ["-y", "@steipete/peekaboo", "mcp"]
    }
  }
}
```

Full setup, including environment variables and provider keys, is in [MCP.md](MCP.md).

## What next?

- [Automation overview](automation.md) — every input primitive, when to use which.
- [Agent](commands/agent.md) — providers, sessions, tools.
- [MCP](MCP.md) — expose Peekaboo to any MCP client.
- [Configuration](configuration.md) — env vars, profiles, credentials.
