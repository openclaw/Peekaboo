---
summary: 'Run Peekaboo as an MCP server via peekaboo mcp'
read_when:
  - 'exposing Peekaboo as an MCP server'
  - 'debugging MCP server startup or transport options'
---

# `peekaboo mcp`

`mcp` runs Peekaboo as a Model Context Protocol server. `peekaboo mcp` defaults to `serve`, so you can launch the server without specifying a subcommand.

## Subcommands
| Name | Purpose | Key options |
| --- | --- | --- |
| `serve` | Run Peekaboo’s MCP server over stdio. | `--transport stdio` (default); `--allow-foreground` explicitly authorizes foreground/global UI for this server process; global `--bridge-socket <path>` attaches to an existing Bridge host. HTTP/SSE names and `--port` are reserved for future support and currently fail with an actionable error. |

## Implementation notes
- `serve` instantiates `PeekabooMCPServer` and maps the transport string to `PeekabooCore.TransportType`. Stdio is the default for Claude Code integrations.
- Public MCP servers are background-only by default. Foreground actions, shared desktop input, browser connection setup,
  and ambient browser auto-connect fail before dispatch unless a human starts that server process with
  `--allow-foreground`. This explicit authority never exposes Shell, and a nested Agent remains background-only.
  Without that authority, establish an exact browser connection separately with `peekaboo browser connect --foreground`;
  MCP browser calls can then reuse its signed live receipt.
- Direct-text `paste` is admitted only with an exact generation-pinned app/PID/window authorization and a canonical
  background result. Targetless, foreground, current-clipboard, and binary paste are refused before dispatch. The
  nested `agent` tool likewise retains immutable background-only authority and never exposes Shell.
- HTTP/SSE server transports are reserved but not implemented. Selecting either fails before daemon startup and emits a structured error in JSON mode.
- The MCP process owns its stdio lifecycle and never hosts a Bridge listener. Support stays process-local by default;
  an explicit `--bridge-socket <path>` uses that existing Bridge host and skips the embedded daemon.
- An explicit `--bridge-socket` binds caller-side capture preflight and every later request to that socket's
  authenticated process generation; unrelated auxiliary sockets cannot freeze the MCP session. The selected host still
  must advertise process ownership, then enforces the canonical process-lifetime ScreenCaptureKit lease at every SCK
  leaf by scanning all same-user potential Peekaboo processes. Reentry refuses owner-unaware processes discovered later.
  Modern refusal remains a signed `CAPTURE_FAILED` / `runtime_incompatible`, retry-safe, not-dispatched result instead
  of being rewritten as a target-attribution error. `see` can use `capture_engine: "classic"` without entering
  ScreenCaptureKit. Caller-local MCP keeps the broader startup scan because it has no external Bridge generation to own
  capture.
- The native tool catalog includes bounded `capture` for live screen/window/region recording or video ingest. It writes retained frames, `contact.png`, `metadata.json`, and optional MP4 output. Frame/contact metadata carries capture-session-authored SHA-256 custody, projected as `artifact_sha256`, and success revalidates those bytes plus semantic metadata. Use tool allow/deny filters when exposing MCP to untrusted clients.
- UI automation tools include action-first additions: `set_value` directly mutates a settable accessibility value, and `action` invokes a named accessibility action on an element from `see`.
- `verify_state` replaces fixed sleeps with bounded native polling. It resolves an app or PID to one exact window, evaluates 1–8 AND predicates for window existence/bounds or exact AX element existence/value/enabled/selected state every 100 ms, and reports `satisfied`, `unsatisfied`, or conservative `unknown` after at most 10 seconds. Explicit PIDs and app-name selectors are pinned to the first resolved PID/process-start generation for the whole invocation; relaunch, PID reuse, and selector drift are `unknown`. Exact-window ownership is rechecked on every sample and before an optional screenshot, whose capture metadata must confirm the same PID and window ID. A directly read value matching a unique exact AX identifier can satisfy an `element_value` predicate when unrelated AX siblings are unreadable; missing, mismatched, non-identifier, or ambiguous partial-tree evidence remains `unknown`. A WindowServer miss is corroborated with a complete app-scoped window inventory before Peekaboo reports absence, preserving minimized AX windows. Ownership ambiguity, partial enumeration, or identity changes are `unknown`. It never focuses or replays actions.
- `click` preserves element IDs and queries when forwarding to automation, so action-first policy can use accessibility actions before synthetic fallback.

## Examples
```bash
# Start the Peekaboo MCP server (defaults to stdio)
peekaboo mcp

# Explicit transport selection
peekaboo mcp serve --transport stdio

# Route MCP tools through an existing Bridge host
peekaboo mcp serve --bridge-socket "$HOME/Library/Application Support/Peekaboo/bridge.sock"
```

The `see` tool publishes a closed `capture_engine` choice: `auto` (default), `modern`, or `classic`. `classic` is the
request-local no-ScreenCaptureKit recovery path and remains bound to the same selected Bridge host.

An MCP client can wait for stable native state without interrupting the user:

```json
{
  "app": "TextEdit",
  "predicates": [
    {
      "kind": "element_value",
      "selector": { "identifier": "document-content" },
      "expected_value": "Ready"
    },
    { "kind": "window_exists", "expected": true }
  ],
  "stable_samples": 2,
  "timeout_ms": 5000
}
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
