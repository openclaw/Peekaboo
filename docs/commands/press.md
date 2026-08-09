---
summary: 'Send special keys or sequences via peekaboo press'
read_when:
  - 'navigating dialogs with arrow/tab/return patterns'
  - 'debugging scripted background key sequences that need deterministic timing'
---

# `peekaboo press`

`press` fires individual `SpecialKey` values (Return, Tab, arrows, F-keys, etc.) in sequence through the hotkey service. Background process-targeted delivery is the default when Peekaboo can resolve a target process; pass `--foreground` for focused/global key presses.

## Key options
| Flag | Description |
| --- | --- |
| `[keys…]` | Positional list of keys (`return`, `tab`, `up`, `f1`, `forward_delete`, …). Validation rejects unknown tokens. |
| `--count <n>` | Repeat the entire key sequence `n` times (default `1`). |
| `--delay <ms>` | Delay between key presses (default `100`). |
| `--hold <ms>` | Hold duration per key (default `50`). |
| `--snapshot <id>` | Optional snapshot ID used for validation/focus (no implicit “latest snapshot” lookup). |
| Target flags | `--app <name>` or `--pid <pid>` for process-targeted background input. Window selectors require `--foreground`. |
| `--foreground` | Focus a supplied target or intentionally send foreground/global key presses. |
| Focus flags | Foreground focus controls; same `FocusCommandOptions` bundle as `click`/`type`. |

## Delivery modes
- **Background** is the default when Peekaboo can resolve a target process from target flags or snapshot metadata. It sends the key sequence to that process without activating the app.
- **Foreground** (`--foreground`) focuses the target first and sends normal/global key presses. Use it for dialogs, menus, or apps that only respond from the focused key window.
- If no target process or snapshot can be resolved, `press` fails before sending input. Add `--foreground` only when global delivery is intentional.

## Implementation notes
- Keys are lowercased and mapped to `SpecialKey`; the command fails fast with a helpful message if a token isn’t recognized.
- Window selectors are rejected in background mode because process-targeted events cannot prove which window owns the process's focused element.
- Repetition multiplies the sequence client-side—e.g., `press tab return --count 3` becomes six actions—so you get predictable ordering.
- Results include the literal key list, total presses, repeat count, delivery mode, optional target PID, and elapsed time in both text and JSON modes.
- The `--hold` flag is passed to the hotkey service for each key press.

## Examples
```bash
# Equivalent to hitting Return once
peekaboo press return --foreground

# Tab through a menu twice, then confirm
peekaboo press tab tab return --foreground

# Walk a dialog down three rows with headroom between repetitions
peekaboo press down --count 3 --delay 200 --foreground

# Send Return to TextEdit without bringing it forward
peekaboo press return --app TextEdit
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`). Background key presses also require Event Synthesizing access for the sending process; request it with `peekaboo permissions request event-synthesizing`.
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- If you see `SNAPSHOT_NOT_FOUND`, regenerate the snapshot with `peekaboo see`.
- Re-run with `--json` or `--verbose` to surface detailed errors.
