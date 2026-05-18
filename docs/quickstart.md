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
```

`grant` opens System Settings to the right pane. You need **Screen Recording** (required) and **Accessibility** (recommended). Re-run `permissions status` until both are green. Background hotkeys also need **Event Synthesizing** — see [permissions.md](permissions.md).

## 2. Take a screenshot

```bash
# whole screen -> ./screen.png
peekaboo image --mode screen --path screen.png

# only the focused window
peekaboo image --mode frontmost --path focused.png

# a specific app's frontmost window
peekaboo image --app Safari --path safari.png
```

The output is a regular PNG. Add `--format jpeg --quality 85` for smaller files. See [commands/image.md](commands/image.md) for every flag.

## 3. Inspect the UI

`see` returns a structured map of clickable elements with stable IDs:

```bash
peekaboo see --app Safari --json | jq '.elements[0:3]'
```

Add `--annotate` to write a labelled PNG you can eyeball:

```bash
peekaboo see --app Safari --annotate --path safari.png
```

Each element has `id`, `role`, `label`, `frame`, and `actions`. Pass an `id` to other commands to act on it.

## 4. Click and type

```bash
peekaboo click "Address and search bar" --app Safari
peekaboo type "github.com/openclaw/Peekaboo" --return
```

Coordinates also work: `peekaboo click --coords 480,120`. With app/window target flags, click coordinates are target-window-relative; add `--global-coords` for screen coordinates. See [automation.md](automation.md) for the full input vocabulary.

## 5. Run an agent

The agent picks tools, plans, and executes — give it a goal in natural language:

```bash
peekaboo agent "Open Safari, go to github.com, and search for Peekaboo"
```

Watch the visualizer overlay as it works. Pause/resume with `peekaboo agent --resume <session-id>`. See [commands/agent.md](commands/agent.md) for provider switching and session management.

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
