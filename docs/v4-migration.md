---
title: Migrating to Peekaboo 4
summary: 'Complete old-to-new mapping for every command, flag, and tool removed or renamed in the v4 CLI redesign.'
description: What changed in Peekaboo 4 and what to use instead — commands, flags, MCP tools, JSON output.
read_when:
  - 'updating scripts, agents, or docs that used a Peekaboo 3 command or flag'
  - 'encountering an unknown-command or unknown-option error after upgrading'
---

# Migrating to Peekaboo 4

Peekaboo 4 assumes your automation runs in a shell: anything a stock macOS tool already
does well was removed, every operation has exactly one spelling, and familiar grammars
(xdotool chords, coreutils-style durations) replace bespoke ones. Full rationale:
`docs/v4-cli-plan.md`.

## Removed commands

| Peekaboo 3 | Peekaboo 4 |
|---|---|
| `peekaboo sleep 500` | `/bin/sleep 0.5` — or better, `peekaboo verify` to wait for an actual condition |
| `peekaboo open <target>` | `/usr/bin/open`, or `peekaboo app launch <app> --open <url-or-file> --wait-ready` |
| `peekaboo run script.peekaboo.json` | a shell script chaining `peekaboo` commands (the JSON step format is gone) |
| `peekaboo list apps\|windows\|screens\|menubar\|permissions` | `app list`, `window list`, `screen list`, `menubar list`, `permissions` |
| `peekaboo image …` | `see` (`--no-elements` for screenshot-only speed; `--format`, `--retina`, `--region`, `--mode multi` moved over) |
| `peekaboo inspect-ui …` | `see --tree [--no-screenshot] [--depth N]` |
| `peekaboo hotkey --keys cmd,c` | `press cmd+c` (xdotool `key` chord syntax) |
| `peekaboo swipe --from-coords a --to-coords b` | `drag --from x1,y1 --to x2,y2` (`--from`/`--to` accept element IDs or coordinates) |
| `peekaboo perform-action AXPress --on B7` | `action AXPress --on B7` |
| `peekaboo commander` | removed (internal diagnostics) |
| `peekaboo agent permission …` | `permissions …` |
| `peekaboo capture watch …` | `capture live …` |
| `peekaboo menu click-extra <item>` | `menubar click <item>` |
| `peekaboo menu list-all` | `menu list` for application menus plus `menubar list` for status items |

## Restructured commands

| Peekaboo 3 | Peekaboo 4 |
|---|---|
| `clipboard -a get` / positional actions / `load` | `clipboard get\|set\|clear\|save\|restore` (`load` = `set --file-path`) |
| `menubar <action> [item]` | `menubar list` / `menubar click <item>` |
| `config add-provider` etc. | `config provider add\|remove\|list\|test\|models` |
| `config set-credential`, `config add` | `config credential set` |
| `agent --resume [--resume-session ID]` | `agent resume [ID]` |
| `agent --list-sessions` | `agent sessions` |
| `agent --chat` | `agent chat` |
| `permissions request-screen-recording` etc. | `permissions request screen-recording\|accessibility\|event-synthesizing` |
| `app quit --app X` (only form) | positional works everywhere: `app quit X`, `app focus X` (new) |

## Renamed flags

| Peekaboo 3 | Peekaboo 4 |
|---|---|
| `--coords x,y` | `--at x,y` |
| `--global-coords` | `--global` |
| `--id <el>` (click/move) | `--on <el>` |
| `--timeout-seconds N` | `--timeout N[s\|ms]` (bare = ms) |
| `--focus-timeout-seconds` | `--focus-timeout` |
| `--restore-delay-ms` | `--restore-delay` |
| `--hold-duration` | `--hold` |
| `--image-path` | `--file-path` |
| `--app-target` | `--app` |
| `type --return/--escape/--delete/--tab` | `type "text"` then `press Return` / `press Escape` / … |

All duration flags accept `500`, `500ms`, or `2s`; bare numbers are milliseconds.
Modifier lists are comma-separated: `--modifiers cmd,shift`.

## New in 4

- `verify` — assert window/element predicates with timeout and stability sampling
  (ternary result; replaces sleep-polling). Exit 0 satisfied / 1 unsatisfied / 2 unknown.
- `tools describe <name>` — one tool's schema on demand.
- `app launch --wait-ready --open <target>`, `window restore`, `window` tool `list` action.
- JSON envelope: action commands report `effect: confirmed|partial|unverifiable|suspected_noop|refused`
  and errors carry `hint` with the actionable next step. (Phase 6)

## MCP / agent tool changes

- Removed tools: `list` (use `app`/`window` list actions), agent shims `list_apps`,
  `list_screens`, `launch_app`; `hotkey`/`swipe` merged into `press`/`drag`;
  `perform_action` renamed `action`. `image` and `inspect_ui` tools remain (cheap
  screenshot / AX-only reads).
- Clipboard tool params are snake_case (`file_path`, `data_base64`); `load` action gone.
- `sleep` remains MCP-only (MCP clients may lack a shell).

## Visualizer

Overlays were redesigned: an agent cursor with natural motion, an input HUD anchored to
the target window (nothing renders when the target is not visibly frontmost), subtle
click pulses, and thin-border capture indicators. Settings collapsed to three toggles.
