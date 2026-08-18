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

- `click`, `scroll`, `type`, `press`, and `drag` for the common interaction surface.
- `set_value` for direct accessibility value mutation on settable fields and controls.
- `action` for invoking a named accessibility action such as `AXPress`, `AXShowMenu`, or `AXIncrement`.

Inventory is exposed on the nouns: use `app` with `action: "list"` for running applications and `window` with
`action: "list"` plus `app` for window IDs, bounds, and off-screen state. The former generic `list` tool and its
duplicate `server_status` view are not exposed. `menu` supports only application-menu `list` and `click` actions;
status items use the dedicated menubar surface. MCP retains `sleep` because an MCP client may not have shell access.

Call `see` first and pass actionable element IDs through these tools when possible. Element-targeted calls preserve action-first routing; coordinate calls always use the synthetic path. OCR-only text is semantic evidence, not an element-action target.
The same action tools are available to CLI users as `peekaboo set-value` and `peekaboo action`.
`set_value` and `action` are exposed only when their resolved input strategy enables action invocation
(`actionFirst` or `actionOnly`). They are hidden under `synthFirst` or `synthOnly`, because these operations do not
have a synthetic-input equivalent.

Supported transports:

- **stdio**: supported and default.
- **http / sse**: recognized flags, but server transports are not implemented yet.

Peekaboo validates numeric arguments before a tool or mutation lane runs. Fields published as `integer` accept exact
whole values (including whole-number JSON doubles and integer strings) but reject fractional, non-finite, and
out-of-range values. Fields published as `number` must be finite. Rejections report `mutation_dispatched: false` and
`retry_safe: true`; an invalid optional value is never treated as omitted or replaced by a default.

The stdio server reserves stdout exclusively for newline-delimited JSON-RPC messages. Tools never stream raw payload
bytes onto that channel. In particular, MCP `clipboard` rejects `outputPath: "-"`; omit `outputPath` for UTF-8 text or
provide a filesystem path for binary clipboard data. The separate CLI `clipboard get --output -` contract is unchanged.

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
        "PEEKABOO_AI_PROVIDERS": "openai/gpt-5.6,anthropic/claude-opus-5",
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

`image` is the cheap screenshot-only tool and accepts `app_target`, `path`, and `format` naming shared with the
observation surface. Use `see` when element detection and snapshot IDs are required. The `press` tool accepts either
`keys: ["cmd+c", "Return"]` for a chord sequence or `key: "c"` plus `modifiers: ["cmd"]` for one chord.

The `see` tool accepts an exact CoreGraphics `window_id` by itself or with an `app_target` naming the owning
application or PID. `inspect_ui` requires that application/PID owner hint. Peekaboo resolves and generation-pins the
real owner before using the ID. Do not combine `window_id` with a window title or index suffix in `app_target`; choose
one window selector so stale inputs cannot redirect work to a sibling window from the same process. `window_id` is a
positive 32-bit integer; strings, fractional numbers, zero, negative values, and out-of-range values fail before
capture or Accessibility traversal begins.

Every successful MCP `see` response includes the selected raw or annotated screenshot as inline image content. When
multiple calls intentionally share the same `path`, each response still returns pixels owned by its own capture; the
path remains the caller-requested publication destination and therefore contains whichever concurrent write finishes
last.

Set `ocr: true` on `see` to add text recognized locally by Apple Vision on the selected runtime host to the
Accessibility map. OCR is additive, never replaces accessible controls, preserves incomplete-AX warnings and exact
capture receipts, and does not use a provider or network upload. Remote OCR requires a Bridge host advertising
`desktopObservationOCR`; MCP refuses an incapable host before sending the dynamic observation request. Update and
relaunch that host, or use a caller-local MCP runtime when local OCR is intentional. OCR rows include confidence and
global logical bounds, are marked non-actionable, and are refused by element interaction tools. If a deliberate pixel
action is necessary, use explicit coordinates bound to the exact `snapshot`/`coordinate_reference` returned by `see`.

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
- `viewport`: present for ROI results, with the full source window, requested/delivered crop rectangles, global crop
  bounds, and uncropped source raster size.

Consumers should check `version` before interpreting the object. Version `1` uses `logical_space: "global_display_points"` and `origin: "top_left"`. To convert an image-local pixel `(px, py)` to a global logical point, scale it against `delivered_image_size` and add the `logical_bounds` origin; do not assume a fixed Retina factor. The fields are additive, so clients that do not understand them can continue ignoring `_meta`.

### Exact-window ROI

MCP `see` accepts `roi: "x,y,width,height"` in top-left-origin, window-local logical points. ROI requires an exact
`window_id` and must create a fresh snapshot, so omit `snapshot`. Peekaboo captures and inspects the generation-pinned
full window, then returns only the pixel-aligned crop. AX/OCR results are filtered to intersecting elements, and
response element frames are clipped and translated into ROI-local logical coordinates. The stored snapshot retains
global frames for element-ID actions.

The response's `coordinate_context.viewport.source_logical_bounds` remains the full window receipt used for freshness
and dispatch validation; `logical_bounds` describes only the delivered crop. `click` with `coordinate_space:
"image_pixels"` or `"normalized"` maps through the crop while still rejecting moved, resized, missing, reused, or
owner-changed windows before dispatch. Reusing the snapshot for a later full-window observation replaces the ROI
mapping and clears stale annotation state.

`image` intentionally has no ROI argument: screenshot-only calls do not create the fresh snapshot/reference binding
required for safe follow-up background coordinates. Use `see` for a crop that will drive automation.

ROI requires Bridge protocol 1.21. CLI host selection and MCP remote dispatch reject older hosts before sending the
request, so a pre-1.21 host cannot ignore the crop or acknowledge only part of the snapshot. After dispatch, the
client also decodes the quarantined raster and checks its real pixel dimensions against the crop receipt before
publishing files or the snapshot. A compatible host must enable desktop observation plus the snapshot-publication
operations used to finalize the validated result.

The `click` tool accepts exactly one target shape: `on`, `query`, or `coords`. Its published schema requires every
background `coords` call to include either `snapshot` or `coordinate_reference`; a PID alone is only a consistency
check and never replaces the receipt. Both fields must be nonempty and identify a fresh exact-window `see` capture.
Pass `coordinate_space: "image_pixels"` for delivered-raster pixels or `coordinate_space: "normalized"` for values
from 0 through 1, plus the snapshot's `reference_id` as `coordinate_reference`. Missing, empty, stale, out-of-bounds,
moved-window, owner-changed, or process-generation-changed references fail before automation. Validation errors include
`mutation_dispatched: false` and `retry_safe: true`, and do not invalidate snapshots as mutations. Foreground global
coordinates remain snapshot-free only with explicit `foreground: true` (or the deprecated `background: false` inverse
alias); either reference opts into capture-context and live-target validation even when `coordinate_space` is omitted.

The `double`, `triple`, `right`, and `middle` click booleans are mutually exclusive; conflicts are rejected before snapshot lookup or dispatch. Background right-, double-, middle-, and triple-clicks use exact PID/window-routed native events without activating the app or moving the physical cursor. Middle/triple require a fresh exact-window snapshot, Event Synthesizing permission, Bridge protocol 1.30, and the `statelessClickVariants` capability; older hosts are refused before the request is encoded. Every event revalidates the normal-layer window owner, process generation, bounds, and point. Since macOS provides no application-level acknowledgment for routed pointer events, successful dispatch responses include `verified: false` and `effect: "unverifiable"`; canonical metadata retains `click_type`, exact target identity/receipt, and three dispatched units for middle or seven for triple. An unprovable or changed route is refused rather than redirected through the desktop-global event tap.

Default background-only MCP/Agent `type` requires an explicit fresh exact non-dialog snapshot receipt; an optional
element ID must come from that snapshot. Snapshot typing cannot include competing app, PID, or window selectors;
implicit-latest, selector-only, and targetless forms are refused before dispatch. Direct CLI and explicitly
foreground-capable runtimes retain their documented process-targeted typing routes.

Background-only raw `press` likewise requires an explicit fresh exact non-dialog snapshot. App/PID-only,
window-selector-only, targetless, and foreground forms are refused by policy before dispatch. The exact target and
focused element are revalidated for every chord, but macOS does not acknowledge semantic effect; observe that target
again before another mutation. Direct CLI callers may also use its documented exact-window selector form.

Process-targeted MCP `paste` and element `click` calls retain one application process-generation receipt instead of
relying on a reusable numeric PID. Paste validates before each emitted unit and clicks validate around dispatch. MCP
and Agent foreground-capable or embedded runtimes require Bridge protocol 1.22 for process-only typed routes; default
background MCP/Agent never selects that route. Older hosts are rejected before input rather than being allowed to
ignore the receipt.

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

Pointer tools use an explicit interruption policy. `scroll` is background-safe only when `on` identifies an Accessibility-scrollable element or a pixel-backed opaque group in a fresh exact-window snapshot of a visible WebKit-linked app. The latter uses PID-routed wheel events, reports an unverifiable retry-unsafe effect, and refuses Electron/Chromium/Catalyst or stale targets instead of falling back to the shared cursor. Set `foreground: true` for targetless, smooth, or delayed scrolling. `move` and `drag` always manipulate the shared physical cursor, require `foreground: true`, and abort if a requested target cannot be focused. MCP schemas intentionally omit background/auto-focus fields for those global pointer tools.

Background process mutations resolve application selectors through the complete mutation inventory before rewriting them to a generation-pinned PID. Exact case-insensitive names, exact bundle IDs, and explicit PIDs are accepted; fuzzy partial application names are refused before the tool leaf runs. Read-only application/window discovery keeps its fuzzy compatibility behavior.

MCP `menu` foreground click and list plan one exact application/window authority before focus. Path and named clicks carry that PID and process generation through dispatch, while foreground listing rejects a returned menu tree whose owner generation changed. If menu access fails after focus, the response retains the focus outcome and exact window receipt. Background menu listing remains read-only and keeps fuzzy selector compatibility.

```json
{
  "coords": "300,220",
  "coordinate_space": "image_pixels",
  "coordinate_reference": "snapshot-id-from-exact-window-see"
}
```

Use the shared physical pointer only with explicit foreground consent:

```json
{
  "coords": "300,220",
  "foreground": true
}
```

## Troubleshooting

- Ensure Screen Recording + Accessibility permissions are granted (`peekaboo permissions status`).
- The `permissions` tool reads one complete snapshot from the selected execution host. Missing Screen Recording or
  Accessibility is a tool failure; missing Event Synthesizing remains a structured limitation for background keyboard
  and foreground synthetic pointer actions rather than a global failure.
- If the MCP client cannot connect, confirm you are launching Peekaboo with `mcp` or `mcp serve` and that the client is using stdio transport.
- Use absolute binary paths for local checkouts.
- Confirm the binary is executable (`chmod +x /path/to/peekaboo`).
- Set `PEEKABOO_LOG_LEVEL=debug` while diagnosing startup issues.
- Check Peekaboo logs with `./scripts/pblog.sh -f` from a source checkout.
