---
summary: 'Inject keystrokes via peekaboo type'
read_when:
  - 'sending text or key chords into a targeted app or element'
  - 'needing predictable background typing cadence during UI automation'
---

# `peekaboo type`

`type` sends text through the automation service. Direct CLI background delivery is the default and accepts an
explicit app, PID, exact window, or snapshot whose metadata identifies a process. Default background-only Agent/MCP
calls are stricter: they require an explicit fresh exact non-dialog snapshot, and an optional element ID must come from
that snapshot. Use `press` for standalone keys or chords.

## Key options
| Flag | Description |
| --- | --- |
| `[text]` | Optional positional string; supports escape sequences like `\n` (Return) and `\t` (Tab). |
| `--snapshot <id>` | Target a specific snapshot. Background-only Agent/MCP requires an explicit fresh exact non-dialog ID and does not infer `latest`. |
| `--delay <duration>` | Time between synthetic keystrokes (default `0`; bare values are milliseconds). |
| `--wpm <80-220>` | Enable human-typing cadence at the chosen words per minute. |
| `--profile <linear|human>` | Switch between linear (default, honors `--delay`) and human (honors `--wpm`). |
| `--clear` | Issue Cmd+A, Delete before typing any new text. |
| Target flags | `--app <name>`, `--pid <pid>`, or an exact window selector for background input. |
| `--foreground` | Focus a supplied target or intentionally send foreground/global keyboard input. |
| Focus flags | Foreground focus controls (`--no-auto-focus`, `--space-switch`, etc.). |

## Delivery modes
- **Background** is the default when Peekaboo can resolve a target from flags or snapshot metadata. Exact window/snapshot routes pin the process generation, window ID/bounds, and focused element without activating the app. App/PID routes upgrade when one eligible window exists and refuse when several are eligible.
- **Background-only Agent/MCP** requires an explicit fresh exact non-dialog `snapshot`. It refuses implicit-latest,
  targetless, app/PID/window-only, and snapshot-plus-selector requests before dispatch.
- **Foreground** (`--foreground`) focuses the target first and sends normal/global keyboard input. Use it for apps or fields that only accept text in the focused key window, or when focus changes are desired.
- If no target process can be resolved, `type` fails before sending input. Add `--foreground` only when global delivery is intentional.

## Implementation notes
- Text may be omitted only when `--clear` is used. Chain a following `press` command for Return, Tab, Escape, or Delete.
- Escape handling splits literal text and key presses: `"Hello\nWorld"` becomes `text("Hello"), key(.return), text("World")`, so newlines don’t require separate flags.
- Exact window selectors and fresh exact-window snapshots preserve PID generation, window ID/bounds, and focused-element identity through dispatch. Stale or ambiguous receipts fail before typing.
- A fresh exact-window `see` records focus only when exactly one element in that window explicitly reports
  `AXFocused=true`. Cached trees, a first editable-field guess, and application-level focus from another window are
  never accepted. To focus a known field without activating the app, use its fresh element ID with background
  `click`, run `see` again, then type with the new snapshot.
- Exact background delivery re-resolves that same role/frame/identifier under the captured window and verifies its
  own `AXFocused` attribute before every keyboard unit. Process relaunch, window/bounds drift, sibling focus, or an
  unreadable focus attribute stops delivery instead of widening to application or foreground focus.
- Default profile is `linear`, using no inter-key delay for fast deterministic input. Passing `--wpm` opts into human cadence; `--profile human` uses 140 WPM when `--wpm` is omitted.
- Background delivery uses process-targeted CoreGraphics keyboard events and requires Event Synthesizing access. Apps that only accept typing in a focused key window may still need `--foreground`.
- Printable background text is carried as Unicode instead of physical US key positions, so the requested characters remain stable across active keyboard layouts.
- Background app/PID delivery is pinned to the process generation resolved before dispatch. Peekaboo revalidates the receipt before every character or special action, stops on target exit/relaunch, and reports partial delivery as retry-unsafe. Exact-window remote delivery requires Bridge protocol 1.24.
- JSON output reports `totalCharacters`, `keyPresses`, delivery mode, optional target PID/window ID, and elapsed time; this matches what the agent logs when executing scripted steps.

## Examples
```bash
# Type text and press Return afterwards
peekaboo type "open ~/Downloads\n" --app "Terminal"

# Force foreground typing when an app ignores background keyboard events
peekaboo type "status report ready" --app TextEdit --foreground

# Clear the field and type a username in the background, then explicitly focus for raw navigation keys
peekaboo type alice@example.com --app Safari --clear
peekaboo press Tab Tab Return --app Safari --foreground

# Opt into human typing at 140 WPM
peekaboo type "status report ready" --app TextEdit --wpm 140

# Linear profile with fixed 10ms delay
peekaboo type "fast" --app TextEdit --profile linear --delay 10ms
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`). Background typing also requires Event Synthesizing access for the sending process; request it with `peekaboo permissions request event-synthesizing`.
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- If you see `SNAPSHOT_NOT_FOUND`, regenerate the snapshot with `peekaboo see`.
- Re-run with `--json` or `--verbose` to surface detailed errors.
