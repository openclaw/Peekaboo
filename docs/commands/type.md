---
summary: 'Inject keystrokes via peekaboo type'
read_when:
  - 'sending text or key chords into a targeted app or element'
  - 'needing predictable background typing cadence during UI automation'
---

# `peekaboo type`

`type` sends text, special keys, or a mix of both through the automation service. Background delivery is the default and requires an explicit app, PID, or snapshot whose metadata identifies a process. Pass `--foreground` for intentional input at the current keyboard focus.

## Key options
| Flag | Description |
| --- | --- |
| `[text]` | Optional positional string; supports escape sequences like `\n` (Return) and `\t` (Tab). |
| `--snapshot <id>` | Target a specific snapshot (or pass `latest` explicitly). |
| `--delay <ms>` | Milliseconds between synthetic keystrokes (default `0`). |
| `--wpm <80-220>` | Enable human-typing cadence at the chosen words per minute. |
| `--profile <linear|human>` | Switch between linear (default, honors `--delay`) and human (honors `--wpm`). |
| `--clear` | Issue Cmd+A, Delete before typing any new text. |
| `--return`, `--tab <count>`, `--escape`, `--delete` | Append those keypresses after (or without) the text payload. |
| Target flags | `--app <name>` or `--pid <pid>` for process-targeted background input. Window selectors require `--foreground`. |
| `--foreground` | Focus a supplied target or intentionally send foreground/global keyboard input. |
| Focus flags | Foreground focus controls (`--no-auto-focus`, `--space-switch`, etc.). |

## Delivery modes
- **Background** is the default when Peekaboo can resolve a target process from target flags or snapshot metadata. It sends process-targeted keyboard events without activating the target app.
- **Foreground** (`--foreground`) focuses the target first and sends normal/global keyboard input. Use it for apps or fields that only accept text in the focused key window, or when focus changes are desired.
- If no target process can be resolved, `type` fails before sending input. Add `--foreground` only when global delivery is intentional.

## Implementation notes
- You can omit the text entirely and rely on the key flags (e.g., just `--tab 2 --return`). Validation only requires *some* action to be specified.
- Escape handling splits literal text and key presses: `"Hello\nWorld"` becomes `text("Hello"), key(.return), text("World")`, so newlines don’t require separate flags.
- Window selectors are rejected in background mode because process-targeted events cannot prove which window owns the process's focused element. Use `--foreground` to focus that window first.
- Default profile is `linear`, using no inter-key delay for fast deterministic input. Passing `--wpm` opts into human cadence; `--profile human` uses 140 WPM when `--wpm` is omitted.
- Background delivery uses process-targeted CoreGraphics keyboard events and requires Event Synthesizing access. Apps that only accept typing in a focused key window may still need `--foreground`.
- JSON output reports `totalCharacters`, `keyPresses`, delivery mode, optional target PID, and elapsed time; this matches what the agent logs when executing scripted steps.

## Examples
```bash
# Type text and press Return afterwards
peekaboo type "open ~/Downloads\n" --app "Terminal"

# Force foreground typing when an app ignores background keyboard events
peekaboo type "status report ready" --app TextEdit --foreground

# Clear the current field, type a username, tab twice, then hit Return
peekaboo type alice@example.com --app Safari --clear --tab 2 --return

# Send only control keys during a form walk
peekaboo type --tab 1 --tab 1 --return --app Safari

# Opt into human typing at 140 WPM
peekaboo type "status report ready" --app TextEdit --wpm 140

# Linear profile with fixed 10ms delay
peekaboo type "fast" --app TextEdit --profile linear --delay 10
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`). Background typing also requires Event Synthesizing access for the sending process; request it with `peekaboo permissions request-event-synthesizing`.
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- If you see `SNAPSHOT_NOT_FOUND`, regenerate the snapshot with `peekaboo see`.
- Re-run with `--json` or `--verbose` to surface detailed errors.
