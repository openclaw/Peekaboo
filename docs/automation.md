---
title: Automation
summary: 'Overview of Peekaboo UI automation targets, input primitives, app surfaces, recipes, and resilience tips.'
description: How to drive macOS UI with Peekaboo — click, type, press, scroll, drag, menus, dialogs, windows, Spaces.
read_when:
  - 'deciding which UI automation command or targeting mode to use'
  - 'documenting agent, MCP, or CLI behavior that mutates macOS UI'
---

# Automation

Peekaboo's automation surface is small but covers the whole macOS UI graph. Each command is documented separately under `commands/`; this page is the map.

## Targeting model

Every input command accepts one of three target shapes:

- **Element ID** — `--on <id>` from a fresh `peekaboo see` capture; preferred when available. Treat IDs as opaque strings and copy the exact value returned by the capture.
- **Label / role / app** — positional query text such as `peekaboo click "Send" --app Mail`; resolved via the AX tree.
- **Coordinates** — `--at 480,120`; target-relative when paired with `--app`, `--pid`, or `--window-*`, global otherwise. Add `--global` to force screen coordinates with a target.

Prefer IDs when you can capture them, labels when you can't, and coordinates only as a last resort. The agent and MCP tooling default to the first two.

Process and window selectors are fail-closed. Choose either `--app` or `--pid`, never both. Choose at most one of `--window-id`, `--window-title`, or `--window-index`; title and index require an app or PID owner. The same rules apply to MCP's `app`, `pid`, `window_id`, `window_title`, and `window_index` fields.

Reusable snapshots have producer-bound references: exactly `ps1_` plus 32 lowercase ASCII hexadecimal digits. The
producer generates the 128-bit random suffix and reserves the reference before it can store detection results,
screenshots, or other snapshot state. A store cannot claim an ID that was not created first. Treat the reference as an
opaque receipt and copy it exactly; legacy timestamp IDs are non-actionable and exist only for strict cache cleanup.

A command with a concrete snapshot reference resolves its unique live authenticated producer before the ordinary
daemon/app preference order. This keeps a snapshot and its in-memory state together even when several Peekaboo hosts
are available. Explicit routing is still authoritative: `--bridge-socket` checks only that Bridge host, while
`--no-remote` checks only the local process, and either refuses rather than rerouting when the selected boundary does
not own the reference.

## Delivery modes

Peekaboo has two input delivery modes:

- **Background** (default when a target process is known) uses exact semantic or typed delivery without activating the app. `type` and `paste` require `--app`, `--pid`, or supported snapshot process metadata. Raw `press` requires a fresh exact-window/snapshot receipt; app/PID-only and targetless forms refuse. Background click can retain its exact window/element target.
- **Foreground** focuses the target first, then sends normal/global input to the active key window or mouse focus. Add `--foreground` when an app ignores background input, when a text field only accepts key-window input, or when you want focus/Space switching to be part of the action.

When a field has no stable snapshot element ID, `type --at x,y --snapshot <id>` can resolve a writable text field at one pixel, set only its Accessibility focus, and type under a single exact-window background lane. It never presses or selects the hit element, activates the app, or splits the focus and keyboard units into independently retryable actions. Foreground modifier-click remains explicit: `click --on <id> --snapshot <id> --foreground --modifiers cmd,shift` restores only cursor/focus state that still matches Peekaboo's own last write, so concurrent user input wins.

Focus flags tune foreground focus behavior but do not silently change delivery mode. Add `--foreground` explicitly. `--no-auto-focus` also does not discard a background keyboard PID. Background element/query/coordinate clicks complete through Accessibility alone. Keyboard input and foreground synthetic pointer input require Event Synthesizing for the sender shown by `peekaboo permissions status`; request it with `peekaboo permissions request event-synthesizing`.

All CLI timing flags use the same grammar: bare numbers are milliseconds, and `ms`/`s` suffixes are accepted (`500`, `500ms`, `2s`, `1.5s`).

Pointer delivery is deliberately stricter. A targeted `scroll --on <id>` stays in the background and prefers the element's Accessibility scroll action. Opaque groups in a visible WebKit-linked app may use exact PID/window-routed wheel events from a fresh pixel snapshot; that route is retry-unsafe because macOS does not acknowledge the receiver's effect. It never falls back to the shared cursor. Targetless, smooth, or delayed wheel input requires `--foreground`. `move`, `drag`, and `click --long-press` manipulate shared physical pointer state, so they also require explicit `--foreground` consent. Their Space/focus modifiers are only valid with that foreground mode; there is no misleading `--no-auto-focus` escape hatch.

Multi-unit background input is prefix-aware. Once any scroll unit or semantic click has been accepted—or may have been accepted—Peekaboo stops instead of replaying the request through a fallback route. Canonical partial and indeterminate outcomes retain the accepted/possible unit count, stay retry-unsafe, and provide recovery or observation escalation. This also covers SwiftUI tab buttons whose `AXPress` returns before selection can be confirmed: Peekaboo reports the accepted press as indeterminate rather than issuing a second synthetic click.

Application menu list/click, dialog list, dialog button click, normal dialog dismissal, window close, and exact minimized-window restore also default to background Accessibility actions. Restore changes only the retained window's `AXMinimized` state. Dialog list never focuses. Dialog keyboard/file flows, forced Escape dismissal, coordinate fallback, and window-close Cmd-W fallback require an explicit `--foreground` (or `foreground: true` in MCP) so these global actions cannot interrupt an unrelated foreground app by accident.

Observation follows the same background-first rule. `see` and `capture` do not focus targeted apps by default. Web-content focus recovery is opt-in with `see --web-focus` or MCP `web_focus: true`; live-capture foreground focus remains explicit.

At Bridge protocol 1.34, producer-bound snapshot ownership and targeted Accessibility-value delivery are independent
client/host capabilities. A current client requires the ownership capability before a remote producer can publish a
reusable snapshot; an older 1.34 host is not treated as capable from its version alone. The targeted-value capability
separately gates the verified `AXFocused` write used when a background click focuses a text field. Ordinary `AXPress`
does not depend on that value-delivery capability.

Bridge protocol 1.37 separately gates generation-bound element mutations. `action` and `set-value` require the host to
attest one snapshot process generation, resolve the final AX element from that process, and return the same canonical
target with the outcome. Older hosts and receiptless sessions are rejected before dispatch, and current hosts omit
these operations unless their provider can return canonical generation-bound outcomes.

Examples:

```bash
# Background: use semantic controls without activating Safari
peekaboo click "Address and search bar" --app Safari --window-id 12345
peekaboo type "github.com/openclaw/Peekaboo" --app Safari --window-id 12345

# Exact-window raw chords can stay background; app-only chords require foreground consent
peekaboo press cmd+l --window-id 12345
peekaboo press cmd+l --app Safari --foreground --space-switch
peekaboo type "github.com/openclaw/Peekaboo" --app Safari --foreground && peekaboo press Return --app Safari --foreground
```

## Input primitives

| Command | Use it for |
| --- | --- |
| [click](commands/click.md) | mouse clicks, double/triple, right/middle, hold |
| [type](commands/type.md) | typing strings into targeted fields |
| [press](commands/press.md) | exact-window background or explicit-foreground raw keys/chords |
| [scroll](commands/scroll.md) | background AX/exact-window scrolling on a target, or explicit foreground wheel input |
| [drag](commands/drag.md) | press, move, release — files, sliders, selections |
| [move](commands/move.md) | warp the mouse without clicking |
| [set-value](commands/set-value.md) | write to text fields without typing |
| [action](commands/action.md) | trigger any AX action (`AXPress`, `AXShowMenu`, …) |

For UX parity with humans (jitter, easing, dwell), see [human-mouse-move.md](human-mouse-move.md) and the input profiles in the command docs.

## Surfaces

| Surface | Command | Notes |
| --- | --- | --- |
| App lifecycle and opening files/URLs | [app](commands/app.md) | launch, quit, focus, hide, `launch --open` |
| Windows | [window](commands/window.md) | move, resize, focus, minimize, fullscreen |
| Spaces & Stage Manager | [space](commands/space.md) | enumerate and switch Spaces |
| Menus | [menu](commands/menu.md) | walk app menus by path |
| Menu bar / status items | [menubar.md](commands/menubar.md) | extra-fiddly popovers |
| Dialogs | [dialog](commands/dialog.md) | sheets, alerts, save panels |
| Dock | [dock](commands/dock.md) | inspect/click dock items |
| Clipboard | [clipboard](commands/clipboard.md) | read/write pasteboard contents |
| Visual feedback | [visualizer](visualizer.md) | overlay so a human can follow what the agent is doing |

## Recipe: click a button by label

```bash
# 1. Inspect first to find a stable label.
peekaboo see --app Safari --annotate --path /tmp/safari.png

# 2. Click it.
peekaboo click "Reload" --app Safari
```

## Recipe: a small flow

```bash
peekaboo window focus --app "Notes"
peekaboo press cmd+n --foreground
peekaboo type "Standup notes\n\n- Shipped Peekaboo docs\n- Reviewed PR #42\n"
peekaboo press cmd+s --foreground
```

Three primitives, four lines. The agent does the same thing under the hood — it just plans the sequence for you.

## Resilience tips

- Always run [`peekaboo see`](commands/see.md) when an element is unreachable. The AX tree refreshes after focus changes; capture again if a click fails.
- Use [focus](focus.md) and [application-resolving](application-resolving.md) for tricky cases (multiple windows, helper apps, processes that hide on activation).
- Use `/bin/sleep` between shell-composed actions when a target genuinely needs settling time.
- Prefer background click, semantic text/value actions, menus, and targeted background scrolling for routine app-specific input.
- Add `--foreground` only when an app needs a focused key window, Space switch, or foreground mouse event.

## Going further

- [Agent overview](commands/agent.md) — let Peekaboo plan input sequences from a goal.
- [MCP](MCP.md) — expose all of the above to Codex, Claude Code, and Cursor.
- [Architecture](ARCHITECTURE.md) — how the input pipeline routes through Bridge and Daemon.
