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
By default, the MCP process owns its lifecycle and keeps support services process-local. An explicit
`--bridge-socket <path>` instead attaches MCP tools to that existing Bridge host and skips the embedded support daemon.
In both modes, MCP never publishes `daemon.sock`, `bridge.sock`, or another Bridge listener itself.

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
- `PEEKABOO_OLLAMA_BASE_URL` / `OLLAMA_BASE_URL`: native Ollama server base. The Peekaboo-specific variable wins,
  then the Ollama variable, config, and finally `http://localhost:11434`; do not append `/v1`.

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

The MCP `image` tool stores logical 1x captures by default. Pass `scale: "native"` or `retina: true` to request native display pixels. Set `max_dimension` to a positive integer to cap the longest output edge while preserving aspect ratio; inline `format: "data"` captures default to 1500 pixels when no cap is supplied.

### Capture coordinate context

The `image` and `see` tools include an additive, versioned `coordinate_context` object in response `_meta`. It describes how the delivered raster maps to Peekaboo's canonical top-left-origin global display coordinates, which are measured in logical points:

- `logical_bounds`: the capture rectangle in global logical points;
- `delivered_image_size`: the actual raster dimensions returned to the client, after any `max_dimension` resize;
- `native_scale`: the display's native pixel-to-point scale when known;
- `output_scale`: the delivered raster's effective pixel-to-point scale;
- `display` and `window`: the resolved capture identities when available;
- `reference_id`: the snapshot ID for `see` results, or `null` for standalone `image` results.

Consumers should check `version` before interpreting the object. Version `1` uses `logical_space: "global_display_points"` and `origin: "top_left"`. To convert an image-local pixel `(px, py)` to a global logical point, scale it against `delivered_image_size` and add the `logical_bounds` origin; do not assume a fixed Retina factor. The fields are additive, so clients that do not understand them can continue ignoring `_meta`.

The `click` tool accepts screenshot-relative coordinates when they are explicitly bound to a `see` snapshot. Pass `coordinate_space: "image_pixels"` for delivered-raster pixels or `coordinate_space: "normalized"` for values from 0 through 1, plus the snapshot's `reference_id` as `coordinate_reference`. Missing, stale, out-of-bounds, or moved-window references fail without dispatching a click. Bare `coords` retain their existing global logical-point meaning. Screen-wide references are not tied to an application process, so use `foreground: true` (or supply an explicit `pid` for background delivery).

```json
{
  "coords": "300,220",
  "coordinate_space": "image_pixels",
  "coordinate_reference": "snapshot-id-from-see",
  "foreground": true
}
```

## Troubleshooting

- Ensure Screen Recording + Accessibility permissions are granted (`peekaboo permissions status`).
- If the MCP client cannot connect, confirm you are launching Peekaboo with `mcp` or `mcp serve` and that the client is using stdio transport.
- Use absolute binary paths for local checkouts.
- Confirm the binary is executable (`chmod +x /path/to/peekaboo`).
- Set `PEEKABOO_LOG_LEVEL=debug` while diagnosing startup issues.
- Check Peekaboo logs with `./scripts/pblog.sh -f` from a source checkout.
