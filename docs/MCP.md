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

The `see` and `inspect_ui` tools additionally accept an exact CoreGraphics `window_id` when `app_target` names the
owning application or PID. Peekaboo verifies that ownership before using the ID. Do not combine `window_id` with a
window title or index suffix in `app_target`; choose one window selector so stale inputs cannot redirect work to a
sibling window from the same process. `window_id` is a positive 32-bit integer; strings, fractional numbers, zero,
negative values, and out-of-range values fail before capture or Accessibility traversal begins.

Every successful MCP `see` response includes the selected raw or annotated screenshot as inline image content. When
multiple calls intentionally share the same `path`, each response still returns pixels owned by its own capture; the
path remains the caller-requested publication destination and therefore contains whichever concurrent write finishes
last.

Observation and capture do not activate a target by default. `see` and `inspect_ui` only perform the focus-changing `AXWebArea` retry when `web_focus: true` is supplied. `image` and live `capture` use `capture_focus: "background"` by default; pass `capture_focus: "foreground"` when activating the target is intentional. The legacy `auto` value remains accepted for focus-if-needed compatibility.

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

The `click` tool accepts screenshot-relative coordinates when they are explicitly bound to a `see` snapshot. Pass `coordinate_space: "image_pixels"` for delivered-raster pixels or `coordinate_space: "normalized"` for values from 0 through 1, plus the snapshot's `reference_id` as `coordinate_reference`. Missing, empty, stale, out-of-bounds, moved-window, owner-changed, or process-generation-changed references fail before automation. Every background coordinate click requires a nonempty exact-window capture reference; a bare PID/app plus global coordinates is ambiguous and is refused. Validation errors include `mutation_dispatched: false` and `retry_safe: true`, and do not invalidate snapshots as mutations. Explicit foreground global coordinates remain snapshot-free.

Background right- and double-clicks use exact PID/window-routed native events without activating the app or moving the physical cursor. Every event revalidates the window owner, process generation, and bounds. Since macOS provides no application-level acknowledgment for routed pointer events, successful dispatch responses include `verified: false` and `effect: "unverifiable"`; an unprovable or changed route is refused rather than redirected through the desktop-global event tap.

The MCP `paste` tool also keeps window selectors exact in background mode. With `window_id`, `window_title`, or
`window_index`, it resolves one window and carries that window's ID, owner PID, and bounds into the atomic keyboard
dispatch; it never degrades the request to process-only delivery that could reach a sibling window. Direct text
revalidates the exact focused destination throughout typing and never touches the clipboard. If process-targeted or
exact-window direct text fails or is cancelled after dispatch begins, a prefix may already have been inserted;
Peekaboo returns `paste_outcome: "indeterminate"`, `partial_text_possible: true`, `retry_safe: false`,
`clipboard_mutated: false`, and `requires_fresh_observation: true`, with `characters_typed: null` rather than guessing
the delivered prefix length when the input receipt cannot provide one. When the receipt does contain an emitted-unit
count, `characters_typed` reports that lower bound. Rich/binary and current-clipboard payloads require the same
exact-window capability before clipboard mutation or Cmd+V dispatch, then return the normal retry-unsafe
may-have-pasted result because macOS does not acknowledge receiver consumption.

Pointer tools use an explicit interruption policy. `scroll` is background-safe only when `on` identifies an Accessibility-scrollable element; it never falls back to the shared cursor. Set `foreground: true` for targetless, smooth, or delayed scrolling. `move`, `drag`, and `swipe` always manipulate the shared physical cursor, require `foreground: true`, and abort if a requested target cannot be focused. MCP schemas intentionally omit background/auto-focus fields for those global pointer tools.

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
