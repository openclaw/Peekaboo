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

- **Element ID** — `--id E12` (from `peekaboo see`); the most reliable.
- **Label / role / app** — positional query text such as `peekaboo click "Send" --app Mail`; resolved via the AX tree.
- **Coordinates** — `--coords 480,120`; target-relative when paired with `--app`, `--pid`, or `--window-*`, global otherwise. Add `--global-coords` to force screen coordinates with a target.

Prefer IDs when you can capture them, labels when you can't, and coordinates only as a last resort. The agent and MCP tooling default to the first two.

## Input primitives

| Command | Use it for |
| --- | --- |
| [click](commands/click.md) | mouse clicks, double/triple, right/middle, hold |
| [type](commands/type.md) | typing strings into focused fields |
| [press](commands/press.md) | individual key presses (return, escape, arrows, etc.) |
| [hotkey](commands/hotkey.md) | shortcut combos, including background apps |
| [scroll](commands/scroll.md) | wheel scrolling at a point or on a target |
| [drag](commands/drag.md) | press, move, release — files, sliders, selections |
| [swipe](commands/swipe.md) | trackpad-style multi-finger gestures |
| [move](commands/move.md) | warp the mouse without clicking |
| [set-value](commands/set-value.md) | write to text fields without typing |
| [perform-action](commands/perform-action.md) | trigger any AX action (`AXPress`, `AXShowMenu`, …) |
| [sleep](commands/sleep.md) | wait between steps with deterministic timing |

For UX parity with humans (jitter, easing, dwell), see [human-typing.md](human-typing.md) and [human-mouse-move.md](human-mouse-move.md).

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
peekaboo see --app Safari --annotate --path safari.png

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
- `peekaboo click` defaults to background delivery; add `--foreground` before click-then-type flows that need keyboard focus.
- Prefer [`hotkey --focus-background`](commands/hotkey.md) when you need to drive an app without stealing focus from the user.

## Going further

- [Agent overview](commands/agent.md) — let Peekaboo plan input sequences from a goal.
- [MCP](MCP.md) — expose all of the above to Codex, Claude Code, and Cursor.
- [Architecture](ARCHITECTURE.md) — how the input pipeline routes through Bridge and Daemon.
