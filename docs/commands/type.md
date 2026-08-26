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
| `--at x,y` | Atomically focus one pixel in the exact captured window and type without activating it. Requires an explicit non-`latest` screenshot snapshot and cannot be combined with target selectors or `--foreground`. |
| `--coordinate-space <space>` | Interpret `--at` as `global_display_points` (default), `image_pixels`, or `normalized` coordinates from that snapshot. |
| `--delay <duration>` | Time between synthetic keystrokes (default `0`; bare values are milliseconds). |
| `--wpm <80-220>` | Enable human-typing cadence at the chosen words per minute. |
| `--profile <linear|human>` | Switch between linear (default, honors `--delay`) and human (honors `--wpm`). |
| `--clear` | Clear before typing. Background targets prefer one AXValue replacement; keyboard fallback uses Cmd+A, Delete. |
| Target flags | `--app <name>`, `--pid <pid>`, or an exact window selector for background input. |
| `--foreground` | Focus a supplied target or intentionally send foreground/global keyboard input. |
| Focus flags | Foreground focus controls (`--no-auto-focus`, `--space-switch`, etc.). |

## Delivery modes
- **Background** is the default when Peekaboo can resolve a target from flags or snapshot metadata. Exact window/snapshot routes pin the process generation, window ID/bounds, and focused element without activating the app. App/PID routes upgrade when one eligible window exists and refuse when several are eligible.
- **Background-only Agent/MCP** requires an explicit fresh exact non-dialog `snapshot`. It refuses implicit-latest,
  targetless, app/PID/window-only, and snapshot-plus-selector requests before dispatch.
- **Pixel-focus background typing** (`--at`) derives one exact process/window/bounds target from the named screenshot snapshot. Its focus-only Accessibility write and all keyboard units share one process lane and one receipt; target drift before any unit is retry-safe, while a completed focus write or typed prefix is retry-unsafe and requires a fresh observation. The focus prelude never presses a button or selects a row.
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
  own `AXFocused` attribute and the application's exact internal key window before every keyboard unit. Process
  relaunch, window/bounds drift, sibling focus, a different internal key window, or an unreadable focus attribute
  stops delivery instead of widening to application or foreground focus.
- Default profile is `linear`, using no inter-key delay for fast deterministic input. Passing `--wpm` opts into human cadence; `--profile human` uses 140 WPM when `--wpm` is omitted.
- Background delivery prefers Accessibility value and selection edits for writable focused text controls. Unsupported or rejected AX routes fall back to process-targeted CoreGraphics keyboard events, which require Event Synthesizing access. Apps that accept neither background route may still need `--foreground`.
- Printable event fallback carries Unicode instead of physical US key positions, so the requested characters remain stable across active keyboard layouts.
- Background app/PID delivery is pinned to the process generation resolved before dispatch. Peekaboo revalidates the receipt before every character or special action, stops on target exit/relaunch, and reports partial delivery as retry-unsafe. Requests containing non-empty text, clear, or an editable focused-text key require Bridge protocol 1.36 plus `compositeTypeDelivery`, because those actions may use AXValue delivery; event-only special keys retain their earlier compatibility floor.
- Event injection is not evidence that the receiver changed. A native `dispatched_unverified` result is returned as
  non-success and requires a fresh observation; `typedText`, `totalCharacters`, and `keyPresses` claim completed work
  only when the typing effect is a confirmed change. `confirmed_no_change` and missing outcomes are also non-success.
  Exact-window `--clear` followed only by printable literal text can confirm when a generation-bound, readable,
  non-secure AX value changes from its private pre-dispatch value to the exact requested value during a short bounded
  settlement window; field contents never enter the result. Pixel-focus typing applies the same private readback after
  its focus write; confirmed focus alone never confirms the typing leaf. Parent windows with attached sheets are refused;
  a sheet with its own exact window receipt remains eligible. An already-equal value remains unverifiable. Requested
  actions remain available for diagnosis.
  For other plain fields where replacement semantics are acceptable, prefer
  `set-value`: it verifies the AX value readback without exposing field contents in the result. Secure fields, special
  keys, IME-dependent input, and controls without readable values remain intentionally unverifiable.
- JSON output reports confirmed `totalCharacters`, `keyPresses`, `specialKeyPresses`, delivery mode, optional target PID/window ID, and elapsed time; this matches what the agent logs when executing scripted steps. Legacy providers that omit the special-key count retain the former derived fallback.
- `keyPresses` counts all actual keyboard events, `specialKeyPresses` counts only events emitted for special-key and clear actions, and canonical `dispatched_unit_count` counts every accepted mutation. Direct background text insertion, editable selection/deletion keys, and clear use `accessibility_value` with zero key presses when AX succeeds. Event fallback counts the posted key events; a request that uses both mechanisms reports `composite`. Keyboard-clear fallback remains two key presses, two special-key presses, and two dispatches.

## Examples
```bash
# Capture one exact text window, replace its field, and require a confirmed change
SNAPSHOT_ID=$(peekaboo see --pid 123 --window-id 456 --json | jq -r '.data.snapshot_id')
peekaboo type "status report ready" --snapshot "$SNAPSHOT_ID" --clear

# Intentionally dispatch foreground typing, then observe; this remains non-success without readback
peekaboo type "status report ready" --app TextEdit --foreground

# Cadence options also require follow-up observation unless the exact replacement shape above applies
peekaboo type "status report ready" --app TextEdit --wpm 140
peekaboo type "fast" --app TextEdit --profile linear --delay 10ms

# Pixel-focus dispatch stays retry-unsafe and requires fresh observation
peekaboo type "hello" --at 320,180 --coordinate-space image_pixels --snapshot "$SNAPSHOT_ID"
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`). Background typing also requires Event Synthesizing access for the sending process; request it with `peekaboo permissions request event-synthesizing`.
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- If you see `SNAPSHOT_NOT_FOUND`, regenerate the snapshot with `peekaboo see`.
- Re-run with `--json` or `--verbose` to surface detailed errors.
