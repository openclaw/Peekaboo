---
summary: 'Send xdotool-style keyboard chords via peekaboo press'
read_when:
  - 'navigating dialogs with arrow/tab/return patterns'
  - 'sending a receipt-pinned background or explicitly foreground raw key sequence'
---

# `peekaboo press`

`press` sends raw xdotool `key`-style chords such as `cmd+c`, `cmd+shift+t`, and `Return`. Multiple positional chords form a sequence. Raw keys require either `--foreground` or an exact window/snapshot receipt that proves the focused destination before native background delivery.

## Key options
| Flag | Description |
| --- | --- |
| `[chords…]` | Chords in xdotool syntax. Modifiers are `cmd`/`command`, `shift`, `option`/`alt`, `ctrl`/`control`, and `fn`; the non-modifier key comes last. |
| `--count <n>` | Repeat the entire key sequence `n` times (default `1`). |
| `--delay <duration>` | Delay between key presses (default `100ms`; bare values are milliseconds). |
| `--hold <duration>` | Hold duration for synthesized keys (default `50ms`; bare values are milliseconds). Semantic AX/menu actions do not hold keys. |
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
- A delivered background chord may change focus, open a window, or dismiss its receiver. It returns
  `dispatched_unverified` without requiring unchanged focus afterward. Destination drift before key-down still
  stops delivery, and key-up cleanup checks the original process generation before each release. A later chord
  needs its own valid destination proof.
- Repetition multiplies the sequence client-side—e.g., `press tab return --count 3 --foreground` becomes six actions—so you get predictable ordering.
- Results include the literal key list, total presses, repeat count, delivery mode, optional target PID, and elapsed time in both text and JSON modes.
- Native generation-pinned `press --json` results also retain the provider's `target_identity` and `target_receipt`, including the lossless decimal process generation. They identify the planned destination, not a confirmed chord effect. Legacy providers and unpinned/global delivery can omit them; the CLI does not reconstruct receipts from descriptive PID/window fields.
- The `--hold` flag is passed to the hotkey service for each key press.
- Action-first menu shortcut lookup requires explicit modifier and enabled metadata; native read failures stop without guessing a command or replaying it through keyboard events. Known unsupported shortcuts retain the selected strategy's normal fallback. Menu traversal reads only `AXChildren`, avoiding unrelated accessibility-container probes while preserving first-match order and the existing node budget.
- Exact-window hotkeys never invoke app-wide menu actions. Action policies may use a supported focused-field Cmd+A selection; otherwise `actionOnly` refuses with `operation_unsupported` before menu or keyboard dispatch, while `actionFirst` falls back to receipt-pinned events. Explicit process-scoped action policies retain their menu route. A surrounding rich-paste operation may already have changed the clipboard; its cleanup and retry-unsafe outcome remain separate from this zero-input refusal.
- Foreground chords clear their synthetic modifier flags on the terminal key-up, including cancellation cleanup. An interrupted chord that already dispatched input remains indeterminate and retry-unsafe; observe before retrying.
- Default background Cmd+A retains focused-field Accessibility selection, now in the action route. Its built-in preference falls directly back to events when selection is unsupported, without adding app-wide menu semantics. Explicit `synthFirst` and `synthOnly` never attempt AX selection or menus; explicit action policies try focused selection before their permitted fallback. Before writing, exact-window delivery validates the retained AX receiver against the window and optional focused-element receipt; changed or unreadable identity refuses without dispatch or keyboard replay. An accepted selection reports `accessibility_value`, one dispatched unit, and `dispatched_unverified`, not a confirmed effect. Exact-window receipts admit that value route only for Cmd+A. Ambiguous AX selection errors stop without replay, and failed post-action validation retains the accepted action's delivery mechanism.
- Bridge receipt signing recognizes the same Cmd+A selection route for process-scoped and exact-window requests, preserving accepted one-write results and truthful indeterminate failures. Other chords cannot claim this value route. Receipt-validation errors retain their concrete cause and both build labels; differing CLI/app labels alone do not establish that the host is stale.
- **SDK policy distinction:** service defaults (`UIInputPolicy.currentBehavior` and application defaults without overrides) preserve the focused-selection preference. A concrete `UIInputPolicy()` or `UIInputPolicy(defaultStrategy: .synthFirst)` and old resolved policy JSON without that preference honor their declared synthetic strategy instead. Foreground and unrelated hotkeys are unchanged.
- **Known limitation:** AX selection and menu actions are semantic operations, not held keys. Use an explicit synthetic strategy when a physical hold is required; distinguishing omitted and explicit `--hold` intent for action policies remains separate work. Older hosts that label selection `accessibility_action` still return an indeterminate exact-window receipt; observe before retrying and update the host. MCP retains its separate confirmed-effect requirement for unverified dispatch.

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
