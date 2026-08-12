---
summary: 'Send xdotool-style keyboard chords via peekaboo press'
read_when:
  - 'navigating dialogs with arrow/tab/return patterns'
  - 'sending an explicitly foreground raw key sequence with deterministic timing'
---

# `peekaboo press`

`press` sends raw xdotool `key`-style chords such as `cmd+c`, `cmd+shift+t`, and `Return`. Multiple positional chords form a sequence. Raw keys cannot certify semantic intent or effect on a shared desktop, so `--foreground` is required. For background automation, use a semantic `action`, `menu`, `window`, `app`, or `dialog` command with an exact target.

## Key options
| Flag | Description |
| --- | --- |
| `[chords…]` | Chords in xdotool syntax. Modifiers are `cmd`/`command`, `shift`, `option`/`alt`, `ctrl`/`control`, and `fn`; the non-modifier key comes last. |
| `--count <n>` | Repeat the entire key sequence `n` times (default `1`). |
| `--delay <duration>` | Delay between key presses (default `100ms`; bare values are milliseconds). |
| `--hold <duration>` | Hold duration per key (default `50ms`; bare values are milliseconds). |
| `--snapshot <id>` | Optional snapshot ID used for validation/focus (no implicit “latest snapshot” lookup). |
| Target flags | `--app <name>`, `--pid <pid>`, or window selectors identify what to focus before foreground dispatch. |
| `--foreground` | Required. Focus a supplied target or intentionally send foreground/global key presses. |
| Focus flags | Foreground focus controls; same `FocusCommandOptions` bundle as `click`/`type`. |

## Delivery mode
- **Background omission is fail-closed.** Without `--foreground`, `press` returns `effect: refused`, `mutation_dispatched: false`, and `retry_safe: true`. Supplying an app, PID, window, or snapshot does not turn a raw chord into certifiable background intent.
- **Foreground** (`--foreground`) focuses a supplied target first and sends normal/global key presses. A dispatched chord remains `effect: unverifiable`; run a fresh observation before continuing.
- Prefer named Accessibility actions and dedicated menu/window/app/dialog operations in background workflows. Peekaboo's internal receipt-pinned keyboard transport remains available to typed composite operations, but public raw `press` does not expose it as successful intent.

## Implementation notes
- Bare keys include Return, Tab, Escape, Delete/Forward Delete, arrows, navigation keys, F1-F12, letters/digits, Space, and standard punctuation. Comma- and space-delimited chord syntax is rejected.
- Every background raw chord is rejected before dispatch, including app/PID/snapshot and window-targeted forms.
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
```

## Troubleshooting
- Verify Screen Recording, Accessibility, and Event Synthesizing permissions (`peekaboo permissions status`).
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- If you see `SNAPSHOT_NOT_FOUND`, regenerate the snapshot with `peekaboo see`.
- Re-run with `--json` or `--verbose` to surface detailed errors.
