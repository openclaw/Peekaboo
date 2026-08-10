---
summary: 'Send xdotool-style keyboard chords via peekaboo press'
read_when:
  - 'navigating dialogs with arrow/tab/return patterns'
  - 'debugging scripted background key sequences that need deterministic timing'
---

# `peekaboo press`

`press` sends xdotool `key`-style chords such as `cmd+c`, `cmd+shift+t`, and `Return`. Multiple positional chords form a sequence. Background process-targeted delivery is the default when Peekaboo can resolve a target process; pass `--foreground` for focused/global input.

## Key options
| Flag | Description |
| --- | --- |
| `[chords…]` | Chords in xdotool syntax. Modifiers are `cmd`/`command`, `shift`, `option`/`alt`, `ctrl`/`control`, and `fn`; the non-modifier key comes last. |
| `--count <n>` | Repeat the entire key sequence `n` times (default `1`). |
| `--delay <duration>` | Delay between key presses (default `100ms`; bare values are milliseconds). |
| `--hold <duration>` | Hold duration per key (default `50ms`; bare values are milliseconds). |
| `--snapshot <id>` | Optional snapshot ID used for validation/focus (no implicit “latest snapshot” lookup). |
| Target flags | `--app <name>` or `--pid <pid>` for process-targeted background input. Window selectors require `--foreground`. |
| `--foreground` | Focus a supplied target or intentionally send foreground/global key presses. |
| Focus flags | Foreground focus controls; same `FocusCommandOptions` bundle as `click`/`type`. |

## Delivery modes
- **Background** is the default when Peekaboo can resolve a target process from target flags or snapshot metadata. It sends the key sequence to that process without activating the app.
- **Foreground** (`--foreground`) focuses the target first and sends normal/global key presses. Use it for dialogs, menus, or apps that only respond from the focused key window.
- If no target process or snapshot can be resolved, `press` fails before sending input. Add `--foreground` only when global delivery is intentional.

## Implementation notes
- Bare keys include Return, Tab, Escape, Delete/Forward Delete, arrows, navigation keys, F1-F12, letters/digits, Space, and standard punctuation. Comma- and space-delimited chord syntax is rejected.
- Window selectors are rejected in background mode because process-targeted events cannot prove which window owns the process's focused element.
- Repetition multiplies the sequence client-side—e.g., `press tab return --count 3` becomes six actions—so you get predictable ordering.
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

# Send Return to TextEdit without bringing it forward
peekaboo press return --app TextEdit

# Reopen a browser tab
peekaboo press cmd+shift+t --app Safari
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`). Background key presses also require Event Synthesizing access for the sending process; request it with `peekaboo permissions request event-synthesizing`.
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- If you see `SNAPSHOT_NOT_FOUND`, regenerate the snapshot with `peekaboo see`.
- Re-run with `--json` or `--verbose` to surface detailed errors.
