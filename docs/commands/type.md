---
summary: 'Inject keystrokes via peekaboo type'
read_when:
  - 'sending text or key chords into the focused element'
  - 'needing predictable focus + typing delays during UI automation'
---

# `peekaboo type`

`type` sends text, special keys, or a mix of both through the automation service. It reuses the latest snapshot (or the one you pass) to figure out which app/window should receive input, then pushes a `TypeActionsRequest` that mirrors what the agent runtime does.

## Key options
| Flag | Description |
| --- | --- |
| `[text]` | Optional positional string; supports escape sequences like `\n` (Return) and `\t` (Tab). |
| `--snapshot <id>` | Target a specific snapshot; otherwise the most recent snapshot ID is used if available. |
| `--delay <ms>` | Milliseconds between synthetic keystrokes (default `2`). |
| `--wpm <80-220>` | Enable human-typing cadence at the chosen words per minute. |
| `--profile <human|linear>` | Switch between human (default, honors `--wpm`) and linear (honors `--delay`). |
| `--clear` | Issue Cmd+A, Delete before typing any new text. |
| `--return`, `--tab <count>`, `--escape`, `--delete` | Append those keypresses after (or without) the text payload. |
| Target flags | `--app <name>`, `--pid <pid>`, `--window-id <id>`, `--window-title <title>`, `--window-index <n>` — focus a specific app/window before typing. (`--window-title`/`--window-index` require `--app` or `--pid`; `--window-id` does not.) |
| Focus flags | Foreground focus controls (`--no-auto-focus`, `--space-switch`, etc.). |

## Implementation notes
- You can omit the text entirely and rely on the key flags (e.g., just `--tab 2 --return`). Validation only requires *some* action to be specified.
- Escape handling splits literal text and key presses: `"Hello\nWorld"` becomes `text("Hello"), key(.return), text("World")`, so newlines don’t require separate flags.
- Without a snapshot or target flags, the command logs a warning that typing will be “blind” because it cannot confirm focus.
- Default profile is `human`, which uses `--wpm` (or 140 WPM if omitted). Switch to `--profile linear` when you need deterministic millisecond spacing via `--delay`.
- Every run calls `ensureFocused` with the merged focus options before dispatching actions, so you automatically get Space switching / retries when needed.
- JSON output reports `totalCharacters`, `keyPresses`, and elapsed time; this matches what the agent logs when executing scripted steps.

## Examples
```bash
# Type text and press Return afterwards
peekaboo type "open ~/Downloads\n" --app "Terminal"

# Clear the current field, type a username, tab twice, then hit Return
peekaboo type alice@example.com --clear --tab 2 --return

# Send only control keys during a form walk
peekaboo type --tab 1 --tab 1 --return

# Human typing at 140 WPM
peekaboo type "status report ready" --wpm 140

# Linear profile with fixed 10ms delay
peekaboo type "fast" --profile linear --delay 10
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- If you see `SNAPSHOT_NOT_FOUND`, regenerate the snapshot with `peekaboo see` (or omit `--snapshot` to use the most recent one).
- Re-run with `--json` or `--verbose` to surface detailed errors.
