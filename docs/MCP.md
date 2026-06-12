---
summary: 'Review Model Context Protocol (MCP) in Peekaboo guidance'
read_when:
  - 'planning work related to model context protocol (mcp) in peekaboo'
  - 'debugging or extending features described here'
---

# Model Context Protocol (MCP) in Peekaboo

This document explains how Peekaboo exposes its automation tools as an MCP server and how to install it in MCP clients.

## Overview

Peekaboo runs as an MCP server over stdio, exposing its native tools (image, see, click, etc.) to external MCP clients such as Codex, Claude Code, or Cursor.
Peekaboo no longer hosts or manages external MCP servers; configure your MCP client to launch `peekaboo mcp` directly.

Action-oriented UI tools include:

- `click`, `scroll`, `type`, `hotkey` for the common interaction surface.
- `set_value` for direct accessibility value mutation on settable fields and controls.
- `perform_action` for invoking a named accessibility action such as `AXPress`, `AXShowMenu`, or `AXIncrement`.

Call `see` first and pass element IDs through these tools when possible. Element-targeted calls preserve action-first routing; coordinate calls always use the synthetic path.
The same action tools are available to CLI users as `peekaboo set-value` and `peekaboo perform-action`.
`set_value` and `perform_action` are exposed only when their resolved input strategy enables action invocation
(`actionFirst` or `actionOnly`). They are hidden under `synthFirst` or `synthOnly`, because these operations do not
have a synthetic-input equivalent.

Supported transports:

- **stdio**: supported and default.
- **http / sse**: recognized flags, but server transports are not implemented yet.

## Install in MCP clients

Most MCP clients can launch Peekaboo through either the npm package or a local binary.

Use npm when you want the published release:

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

Use a local binary when developing Peekaboo or testing a checkout:

```json
{
  "mcpServers": {
    "peekaboo": {
      "command": "/path/to/peekaboo",
      "args": ["mcp"]
    }
  }
}
```

If your client supports environment variables, add provider and logging settings under `env`:

```json
{
  "mcpServers": {
    "peekaboo": {
      "command": "npx",
      "args": ["-y", "@steipete/peekaboo", "mcp"],
      "env": {
        "PEEKABOO_AI_PROVIDERS": "openai/gpt-5.5,anthropic/claude-opus-4-8",
        "PEEKABOO_LOG_LEVEL": "info"
      }
    }
  }
}
```

Common environment variables:

- `PEEKABOO_AI_PROVIDERS`: comma-separated provider list.
- `PEEKABOO_LOG_LEVEL`: `debug`, `info`, `warn`, or `error`.
- `OPENAI_API_KEY`: OpenAI API key for GPT models.
- `ANTHROPIC_API_KEY`: Anthropic API key for Claude models.
- `X_AI_API_KEY` or `XAI_API_KEY`: xAI API key for Grok models.
- `PEEKABOO_OLLAMA_BASE_URL`: Ollama server URL, defaults to `http://localhost:11434`.

## Verify client setup

Run the server manually first:

```
peekaboo mcp
```

Then restart your MCP client and ask it to list available tools or take a screenshot. Peekaboo should expose the same native tools that `peekaboo tools` reports.

## CLI usage

Show help:

```
peekaboo mcp --help
```

Start the server (defaults to stdio):

```
peekaboo mcp
```

Explicit transport:

```
peekaboo mcp serve --transport stdio
```

## Observation Targets

The MCP `image` and `see` tools share target parsing with the desktop observation pipeline:

- omit `app_target`, pass `screen`, or pass `screen:N` for display capture;
- pass `frontmost` for the current foreground app window;
- pass `menubar` for menu-bar capture;
- pass `PID:1234`, `PID:1234:2`, `App Name`, `App Name:2`, or `App Name:Window Title` for app/window capture.

The MCP `image` tool stores logical 1x captures by default. Pass `scale: "native"` or `retina: true` to request native display pixels.

## Troubleshooting

- Ensure Screen Recording + Accessibility permissions are granted (`peekaboo permissions status`).
- If the MCP client cannot connect, confirm you are launching Peekaboo with `mcp` or `mcp serve` and that the client is using stdio transport.
- Use absolute binary paths for local checkouts.
- Confirm the binary is executable (`chmod +x /path/to/peekaboo`).
- Set `PEEKABOO_LOG_LEVEL=debug` while diagnosing startup issues.
- Check Peekaboo logs with `./scripts/pblog.sh -f` from a source checkout.
