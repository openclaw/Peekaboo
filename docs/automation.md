---
title: Automation
summary: 'Overview of Peekaboo UI automation targets, input primitives, app surfaces, recipes, and resilience tips.'
description: How to drive macOS UI with Peekaboo — click, type, scroll, drag, hotkeys, menus, dialogs, windows, Spaces.
read_when:
  - 'deciding which UI automation command or targeting mode to use'
  - 'documenting agent, MCP, or CLI behavior that mutates macOS UI'
---

# Automation

Peekaboo's automation surface is small but covers the whole macOS UI graph. Each command is documented separately under `commands/`; this page is the map.

## Targeting model

Every input command accepts one of three target shapes:

- **Element ID** — `--on <id>` or `--id <id>` from a fresh `peekaboo see` or `peekaboo inspect-ui` capture; preferred when available. Treat IDs as opaque strings and copy the exact value returned by the capture.
- **Label / role / app** — positional query text such as `peekaboo click "Send" --app Mail`; resolved via the AX tree.
- **Coordinates** — `--coords 480,120`; target-relative when paired with `--app`, `--pid`, or `--window-*`, global otherwise. Add `--global-coords` to force screen coordinates with a target.

Prefer IDs when you can capture them, labels when you can't, and coordinates only as a last resort. The agent and MCP tooling default to the first two.

## Delivery modes

Peekaboo has two input delivery modes:

- **Background** (default when a target process is known) posts process-targeted input without activating the app. Keyboard commands (`type`, `press`, `hotkey`, and `paste`) require `--app`, `--pid`, or supported snapshot process metadata. A window selector cannot safely identify the focused element inside a multi-window process, so keyboard window targeting requires `--foreground`. Background click can retain its exact window/element target.
- **Foreground** focuses the target first, then sends normal/global input to the active key window or mouse focus. Add `--foreground` when an app ignores background input, when a text field only accepts key-window input, or when you want focus/Space switching to be part of the action.

Focus flags tune foreground focus behavior but do not silently change delivery mode. Add `--foreground` explicitly. `--no-auto-focus` also does not discard a background keyboard PID. Background element/query/coordinate clicks complete through Accessibility alone. Keyboard input and foreground synthetic pointer input require Event Synthesizing for the sender shown by `peekaboo permissions status`; request it with `peekaboo permissions request-event-synthesizing`.

Pointer delivery is deliberately stricter. A targeted `scroll --on <id>` stays in the background and invokes only the element's Accessibility scroll action; it never falls back to the shared cursor. Targetless, smooth, or delayed wheel input requires `--foreground`. `move`, `drag`, and `swipe` always manipulate the shared physical cursor, so they also require explicit `--foreground` consent. Their Space/focus modifiers are only valid with that foreground mode; there is no misleading `--no-auto-focus` escape hatch.

Application menu list/click, dialog list, dialog button click, normal dialog dismissal, and window close also default to background Accessibility actions. Dialog list never focuses. Dialog keyboard/file flows, forced Escape dismissal, coordinate fallback, and window-close Cmd-W fallback require an explicit `--foreground` (or `foreground: true` in MCP) so these global actions cannot interrupt an unrelated foreground app by accident.

Observation follows the same background-first rule. `see`, `inspect-ui`, `image`, and `capture` do not focus targeted apps by default. Web-content focus recovery is opt-in with `see --web-focus`, `inspect-ui --web-focus`, or MCP `web_focus: true`; foreground image/live capture is opt-in with `--capture-focus foreground` or MCP `capture_focus: "foreground"`.

Examples:

```bash
# Background: target Safari without activating it
peekaboo hotkey cmd,l --app Safari
peekaboo type "github.com/openclaw/Peekaboo" --app Safari --return

# Foreground: activate/focus first for apps that require a key window
peekaboo hotkey cmd,l --app Safari --foreground --space-switch
peekaboo type "github.com/openclaw/Peekaboo" --app Safari --return --foreground
```

## Input primitives

| Command | Use it for |
| --- | --- |
| [click](commands/click.md) | mouse clicks, double/triple, right/middle, hold |
| [type](commands/type.md) | typing strings into targeted fields |
| [press](commands/press.md) | individual key presses (return, escape, arrows, etc.) |
| [hotkey](commands/hotkey.md) | shortcut combos, including background apps |
| [scroll](commands/scroll.md) | background AX scrolling on a target, or explicit foreground wheel input |
| [drag](commands/drag.md) | press, move, release — files, sliders, selections |
| [swipe](commands/swipe.md) | trackpad-style multi-finger gestures |
| [move](commands/move.md) | warp the mouse without clicking |
| [set-value](commands/set-value.md) | write to text fields without typing |
| [perform-action](commands/perform-action.md) | trigger any AX action (`AXPress`, `AXShowMenu`, …) |
| [sleep](commands/sleep.md) | wait between steps with deterministic timing |

For UX parity with humans (jitter, easing, dwell), see [human-mouse-move.md](human-mouse-move.md) and the input profiles in the command docs.

## Surfaces

| Surface | Command | Notes |
| --- | --- | --- |
| App lifecycle | [app](commands/app.md) | launch, quit, focus, hide |
| Windows | [window](commands/window.md) | move, resize, focus, minimize, fullscreen |
| Spaces & Stage Manager | [space](commands/space.md) | enumerate and switch Spaces |
| Menus | [menu](commands/menu.md) | walk app menus by path |
| Menu bar / status items | [menubar.md](commands/menubar.md) | extra-fiddly popovers |
| Dialogs | [dialog](commands/dialog.md) | sheets, alerts, save panels |
| Dock | [dock](commands/dock.md) | inspect/click dock items |
| Clipboard | [clipboard](commands/clipboard.md) | read/write pasteboard contents |
| Open files / URLs | [open](commands/open.md) | with focus controls |
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
peekaboo hotkey cmd+n
peekaboo type "Standup notes\n\n- Shipped Peekaboo docs\n- Reviewed PR #42\n"
peekaboo hotkey cmd+s
```

Three primitives, four lines. The agent does the same thing under the hood — it just plans the sequence for you.

## Resilience tips

- Always run [`peekaboo see`](commands/see.md) when an element is unreachable. The AX tree refreshes after focus changes; capture again if a click fails.
- Use [focus](focus.md) and [application-resolving](application-resolving.md) for tricky cases (multiple windows, helper apps, processes that hide on activation).
- Wrap risky sequences with `peekaboo sleep 0.2` — humans don't fire ten clicks in a single frame, and neither should you.
- Prefer background click, keyboard targeting, and targeted AX scrolling for routine app-specific input.
- Add `--foreground` only when an app needs a focused key window, Space switch, or foreground mouse event.

## Going further

- [Agent overview](commands/agent.md) — let Peekaboo plan input sequences from a goal.
- [MCP](MCP.md) — expose all of the above to Codex, Claude Code, and Cursor.
- [Architecture](ARCHITECTURE.md) — how the input pipeline routes through Bridge and Daemon.
