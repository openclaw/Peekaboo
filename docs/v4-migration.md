---
title: Migrating to Peekaboo 4
summary: 'Complete old-to-new mapping for every command, flag, and tool removed or renamed in the v4 CLI redesign.'
description: What changes in the upcoming Peekaboo 4 release and what to use instead — commands, flags, MCP tools, JSON output.
read_when:
  - 'updating scripts, agents, or docs that used a Peekaboo 3 command or flag'
  - 'encountering an unknown-command or unknown-option error after upgrading'
---

# Migrating to Peekaboo 4

Peekaboo 4 is not published yet; this guide describes the current source-tree contract
for the upcoming release. Peekaboo 4 assumes your automation runs in a shell: anything
a stock macOS tool already does well was removed, every operation has exactly one
spelling, and familiar grammars (xdotool chords, coreutils-style durations) replace
bespoke ones. Full rationale: `docs/v4-cli-plan.md`.

## Removed commands

| Peekaboo 3 | Peekaboo 4 |
|---|---|
| `peekaboo sleep 500` | `/bin/sleep 0.5` — or better, `peekaboo verify` to wait for an actual condition |
| `peekaboo open <target>` | `/usr/bin/open`, or `peekaboo app launch <app> --open <url-or-file> --wait-ready` |
| `peekaboo run script.peekaboo.json` | a shell script chaining `peekaboo` commands (the JSON step format is gone) |
| `peekaboo list apps\|windows\|screens\|menubar\|permissions` | `app list`, `window list`, `screen list`, `menubar list`, `permissions` |
| `peekaboo image …` | `see` (`--no-elements` for screenshot-only speed; `--format`, `--retina`, `--region`, `--mode multi` moved over) |
| `peekaboo inspect-ui …` | `see --tree [--no-screenshot] [--depth N]` |
| `peekaboo hotkey --keys cmd,c` | `press cmd+c --foreground`, or `press cmd+c --snapshot <fresh-exact-snapshot>` for receipt-pinned background delivery |
| `peekaboo swipe --from-coords a --to-coords b` | `drag --from x1,y1 --to x2,y2` (`--from`/`--to` accept element IDs or coordinates) |
| `peekaboo perform-action AXPress --on B7` | `action AXPress --on B7` |
| `peekaboo commander` | removed (internal diagnostics) |
| `peekaboo agent permission …` | `permissions …` |
| `peekaboo capture watch …` | `capture live …` |
| `peekaboo menu click-extra <item>` | `menubar click <item> --foreground` |
| `peekaboo menu list-all` | `menu list` for application menus plus `menubar list` for status items |

## Restructured commands

| Peekaboo 3 | Peekaboo 4 |
|---|---|
| `clipboard --action <verb>` / `clipboard -a <verb>` / positional actions | `clipboard get\|set\|clear\|save\|restore` |
| `clipboard load <path>` | `clipboard set --file-path <path>` |
| `menubar <action> [item]` | `menubar list` / `menubar click <item> --foreground` |
| `config add-provider` | `config provider add` |
| `config remove-provider` | `config provider remove` |
| `config list-providers` | `config provider list` |
| `config test-provider` | `config provider test` |
| `config models-provider` | `config provider models` |
| `config set-credential`, `config add` | `config credential set` |
| `agent --resume` | `agent resume` |
| `agent --resume-session ID` | `agent resume ID` |
| `agent --list-sessions` | `agent sessions` |
| `agent --chat` | `agent chat` |
| `permissions request-screen-recording` | `permissions request screen-recording` |
| `permissions request-accessibility` | `permissions request accessibility` |
| `permissions request-event-synthesizing` | `permissions request event-synthesizing` |
| `app quit --app X` (only form) | positional works everywhere: `app quit X`, `app focus X` (new) |

## Renamed and removed flags

| Peekaboo 3 | Peekaboo 4 |
|---|---|
| `--app-target` | `--app` |
| `--autoclean-minutes` | `--autoclean` |
| `--coords x,y` | `--at x,y` |
| `--delay-ms` | `--delay` |
| `--diff-budget-ms` | `--diff-budget` |
| `--end-ms` | `--end` |
| `--every-ms` | `--every` |
| `--focus-timeout-seconds` | `--focus-timeout` |
| `--from-coords` | `--from` |
| `--global-coords` | `--global` |
| `--heartbeat-sec` | `--heartbeat` |
| `--hold-duration` | `--hold` |
| `--id <el>` (click/move) | `--on <el>` |
| `--idle-timeout-seconds` | `--idle-timeout` |
| `--image-path` | `--file-path` |
| `--keys` | positional xdotool chord syntax, for example `peekaboo press cmd+c --foreground` |
| `--label` | positional query text or `--on` |
| `--max-depth` | `--depth` |
| `--poll-interval-ms` | `--poll-interval` |
| `--post-roll-ms` | `--post-roll` |
| `--pre-roll-ms` | `--pre-roll` |
| `--quiet-ms` | `--quiet` |
| `--repeat` | `--count` |
| `--restore-delay-ms` | `--restore-delay` |
| `--start-ms` | `--start` |
| `--ticks` | `--amount` |
| `--timeout-seconds N` | `--timeout N[s\|ms]` (bare = ms) |
| `--to-coords` | `--to` |
| `--wait-seconds` | `--wait` |
| `type --return/--escape/--delete/--tab` | `type "text"` then `press Return --snapshot <fresh-exact-snapshot>`, or use `press Return --foreground` with explicit consent |

All duration flags accept `500`, `500ms`, or `2s`; bare numbers are milliseconds.
Modifier lists are comma-separated: `--modifiers cmd,shift`.

## New in 4

- `verify` — assert window/element predicates with timeout and stability sampling
  (ternary result; replaces sleep-polling). Exit 0 satisfied / 1 unsatisfied / 2 unknown.
- `tools describe <name>` — one tool's schema on demand.
- `app launch --wait-ready --open <target>`, `window restore`, `window` tool `list` action.
- JSON envelope: after an action request has been parsed and classified, its result reports
  `effect: confirmed|partial|unverifiable|suspected_noop|refused` and errors carry `hint`
  with the actionable next step. Pre-dispatch argument parse/bind failures for recognized
  action commands report `effect: refused`; read-only failures omit `effect`. (Phase 6)

## MCP / agent tool changes

- Removed tools: `list` (use `app`/`window` list actions), agent shims `list_apps`,
  `list_screens`, `launch_app`; `hotkey`/`swipe` merged into `press`/`drag`;
  `perform_action` renamed `action`. `image` and `inspect_ui` tools remain (cheap
  screenshot / AX-only reads).
- Clipboard tool params are snake_case (`file_path`, `data_base64`); `load` action gone.
- `sleep` remains MCP-only (MCP clients may lack a shell).

## Visualizer

Overlays were redesigned around three feedback categories: an agent cursor with natural
motion and subtle click pulses, an input HUD, and thin-border capture indicators. All
targeted background input stays overlay-free even when the target window is visible or
frontmost; only untargeted or explicitly foreground input may show the cursor or HUD.
Peekaboo.app keeps a visualizer master switch and playback controls around the three
category switches; those categories are not the entire settings surface.
