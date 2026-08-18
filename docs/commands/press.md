---
summary: 'Send xdotool-style keyboard chords via peekaboo press'
read_when:
  - 'navigating dialogs with arrow/tab/return patterns'
  - 'sending a receipt-pinned background or explicitly foreground raw key sequence'
---

# `peekaboo press`

`press` sends raw xdotool `key`-style chords such as `cmd+c`, `cmd+shift+t`, and `Return`. Multiple positional chords form a sequence. Raw keys require either `--foreground` or an exact window/snapshot receipt whose focused element stays unchanged through native background dispatch.

## Key options
| Flag | Description |
| --- | --- |
| `[chords…]` | Chords in xdotool syntax. Modifiers are `cmd`/`command`, `shift`, `option`/`alt`, `ctrl`/`control`, and `fn`; the non-modifier key comes last. |
| `--count <n>` | Repeat the entire key sequence `n` times (default `1`). |
| `--delay <duration>` | Delay between key presses (default `100ms`; bare values are milliseconds). |
| `--hold <duration>` | Hold duration per key (default `50ms`; bare values are milliseconds). |
| `--snapshot <id>` | Optional snapshot ID used for validation/focus (no implicit “latest snapshot” lookup). |
| Target flags | An exact window selector enables receipt-pinned background press; app/PID-only targeting still requires `--foreground`. |
| `--foreground` | Focus a supplied target or intentionally send foreground/global key presses. |
| Focus flags | Foreground focus controls; same `FocusCommandOptions` bundle as `click`/`type`. |

## Delivery mode
- **Exact background** accepts only a fresh exact-window selector or snapshot. Peekaboo pins process generation, window ID/bounds, and focused-element identity; missing, ambiguous, or stale receipts refuse before dispatch. App/PID-only and targetless forms retain the canonical retry-safe refusal.
- **Background-only Agent/MCP** accepts only an explicit fresh exact non-dialog snapshot. Window-selector-only and
  implicit-latest forms are also refused by that stricter policy.
- **Foreground** (`--foreground`) focuses a supplied target first and sends normal/global key presses. A dispatched chord remains `effect: unverifiable`; run a fresh observation before continuing.
- Prefer named Accessibility actions and dedicated menu/window/app/dialog operations in background workflows. Exact-window `press` exposes the receipt-pinned transport but still reports its semantic effect honestly.

## Implementation notes
- Bare keys include Return, Tab, Escape, Delete/Forward Delete, arrows, navigation keys, F1-F12, letters/digits, Space, and standard punctuation. Comma- and space-delimited chord syntax is rejected.
- Background raw chords never collapse an exact selector to process delivery and never silently foreground. Exact-window remote delivery requires Bridge protocol 1.24.
- Repetition multiplies the sequence client-side—e.g., `press tab return --count 3 --foreground` becomes six actions—so you get predictable ordering.
- Results include the literal key list, total presses, repeat count, delivery mode, optional target PID, and elapsed time in both text and JSON modes.
- The `--hold` flag is passed to the hotkey service for each key press.

## Examples
```bash
# Equivalent to hitting Return once
peekaboo press return --foreground

# Tab through a menu twice, then confirm
peekaboo press Tab Tab Return --foreground

# Walk a dialog down three rows with headroom between repetitions
peekaboo press down --count 3 --delay 200ms --foreground

# Send Return after explicitly focusing TextEdit
peekaboo press return --app TextEdit --foreground

# Reopen a browser tab with explicit foreground consent
peekaboo press cmd+shift+t --app Safari --foreground

# Send a chord to one already-focused exact window without activating it
peekaboo press cmd+l --window-id 12345

# Use the only background form exposed to Agent/MCP policy
peekaboo press cmd+l --snapshot "$FRESH_EXACT_NON_DIALOG_SNAPSHOT"
```

## Troubleshooting
- Verify Screen Recording, Accessibility, and Event Synthesizing permissions (`peekaboo permissions status`).
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- If you see `SNAPSHOT_NOT_FOUND`, regenerate the snapshot with `peekaboo see`.
- Re-run with `--json` or `--verbose` to surface detailed errors.
