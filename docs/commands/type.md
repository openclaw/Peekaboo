---
summary: 'Enter text through targeted Accessibility or keyboard delivery'
read_when:
  - 'sending text or key chords into a targeted app or element'
  - 'needing predictable background typing cadence during UI automation'
---

# `peekaboo type`

`type` sends text through the automation service. Direct CLI background delivery is the default and accepts an
explicit app, PID, exact window, or snapshot whose metadata identifies a process. Default background-only Agent/MCP
calls are stricter: they require an explicit fresh exact non-dialog snapshot, and an optional element ID must come from
that snapshot. Use `press` for standalone keys or chords.

Background Accessibility typing waits for each value write and supported cursor update to settle on the same
native field before computing the next edit. A write that was accepted but cannot be verified stops typing
with an indeterminate outcome; Peekaboo does not replay it as another write or keyboard events.
After every asynchronous preflight, the final write rechecks the application's current focused native receiver
and exact keyboard window. Losing focus before the first write refuses safely; losing it after an accepted
text edit stops before selection or further input, retaining the retry-unsafe accepted prefix.
Value confirmation checks the same receiver again after fetching its value; focus or window drift cannot be
confirmed using the earlier receiver metadata.
Text edits and cursor changes also recheck their source text and selection immediately before mutation. If either
changes during asynchronous preflight, the unit stops without recomputing or replaying it. These checks do not make
macOS Accessibility reads and writes an atomic transaction.
The original selection stays bound while a value write settles. A changed selection stops the follow-up cursor
write unless the requested range is already present, including when it settles during selection preflight;
in that case no selection write is sent, and subsequent input continues from the verified range.
Focused-text edits preserve exact Unicode storage; canonically equivalent text is not an automatic no-op.
Cancellation prevents starting keyboard fallback or another stroke; an already-started stroke still finishes its
key-up cleanup, and any accepted prefix remains unsafe to replay.

## Key options
| Flag | Description |
| --- | --- |
| `[text]` | Optional positional string; supports escape sequences like `\n` (Return) and `\t` (Tab). |
| `--snapshot <id>` | Target a specific snapshot. Background-only Agent/MCP requires an explicit fresh exact non-dialog ID and does not infer `latest`. |
| `--at x,y` | Atomically focus one pixel in the exact captured window and type without activating it. Requires an explicit non-`latest` screenshot snapshot and cannot be combined with target selectors or `--foreground`. |
| `--coordinate-space <space>` | Interpret `--at` as `global_display_points` (default), `image_pixels`, or `normalized` coordinates from that snapshot. |
| `--delay <duration>` | Time between synthetic keystrokes (default `0`; bare values are milliseconds). Valid long delays remain cancellable; cancelling a wait stops the remaining input. |
| `--wpm <80-220>` | Enable human-typing cadence at the chosen words per minute. |
| `--profile <linear|human>` | Switch between linear (default, honors `--delay`) and human (honors `--wpm`). |
| `--clear` | Clear before typing. Native background targets prefer one AXValue replacement; web fields and keyboard fallback use Cmd+A, Delete. |
| `--input-strategy <strategy>` | Override typing delivery: `actionFirst` (background default), `actionOnly`, `synthFirst`, or `synthOnly`. Per-call overrides execute locally. |
| `--accept-dispatched` | CLI only: also return exit 0 for accepted but unverified dispatch. Keeps the unverified outcome, zero confirmed counts, and observe-before-retry warning. Default remains confirmed change only. |
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
- Foreground special-key events explicitly clear inherited modifier flags on both key-down and key-up. Their existing keycodes and unverified delivery semantics are unchanged.
- Exact window selectors and fresh exact-window snapshots preserve PID generation, window ID/bounds, and focused-element identity through dispatch. Stale or ambiguous receipts fail before typing.
- Focused web controls may expose their exact owner through the native `AXWindow` link instead of a direct window ID; both paths retain the same exact-window checks.
- Ordinary snapshot-backed CLI and MCP typing reserve the snapshot before focus or input. A pending mutation or a prior outcome requiring fresh observation refuses further typing, including `--accept-dispatched`; read-only inspection of that snapshot remains available. Pixel-focus typing retains its single service-owned reservation.
- A fresh exact-window `see` records focus from a uniquely focused captured element. When ancestor groups also
  report `AXFocused=true`, a complete observation can disambiguate only if the application's native focused reference
  stays stable across traversal, uniquely matches a genuinely focused captured node, and proves the same process/window.
  Cached trees, a first editable-field guess, and application-level focus from another window are never accepted;
  partial or truncated captures cannot use this additional corroboration. Input still revalidates the live receiver.
  To focus a known field without activating the app, use its fresh element ID with background `click`, run `see`
  again, then type with the new snapshot.
- Exact background delivery strictly validates the initial focused-element frame. Subsequent units and text
  completion allow that same uniquely identified element to reflow: role and identifier (or title when no identifier
  exists) must still match, its center must remain inside the captured window, and `AXFocused` and the application's
  exact internal key window must still agree. This applies to both Accessibility edits and keyboard events. Process
  relaunch, window/bounds drift, sibling or ambiguous focus, a different internal key window, or an unreadable focus
  attribute stops delivery with retry-unsafe prefix evidence after any input was emitted.
- Receipt-pinned Accessibility text, clear, and editing-key writes retain the native receiver selected by that unit's
  focus validation. A different or unreadable final receiver refuses before mutation or keyboard fallback, even when
  it exposes the same role and identifier; the retained receiver can still reflow under continuation validation.
- A delivered trailing special key may intentionally change focus, so it returns dispatched-unverified without an
  unchanged-focus check afterward. Any remaining input still requires the same receiver's continuation proof.
- Default profile is `linear`, using no inter-key delay for fast deterministic input. Passing `--wpm` opts into human cadence; `--profile human` uses 140 WPM when `--wpm` is omitted.
- The built-in background typing policy is `actionFirst`: background delivery tries Accessibility value and selection edits for writable focused text controls, then process-targeted keyboard events only when the edit is unsupported. `actionOnly` never emits keyboard events, including for clear and event-only keys such as Return or Tab. Explicit `synthFirst` and `synthOnly` bypass AX value and selection edits. Per-app typing policy is resolved once from the target process, never from the foreground app.
- Under `actionFirst`, controls beneath a proven `AXWebArea` use process-targeted keyboard events before any AX value or selection write, including clear and editable special keys; web controls can accept AX writes without applying them. `actionOnly` refuses these edits instead of emitting keys. The focused-text Cmd+A optimization uses the same gate and never writes a selection into a proven web control; its existing hotkey strategy and hold-duration behavior are unchanged. Before an AX edit is selected, a bounded parent walk must establish the route and recheck the same focused AX receiver; an unproven route refuses that unit before input. Route classification follows retained/exact receiver validation and does not replace process-generation or per-unit focus checks.
- Local native Accessibility edits do not require Event Synthesizing access; local keyboard delivery checks that permission only when needed. Bridge-hosted targeted typing still requires Post Event permission at admission, even when a native edit would suffice. Accepted or uncertain AX writes never fall back to keyboard input, and accepted events never retry through AX. A failed later unit retains any accepted prefix as retry-unsafe. Apps that accept neither background route may still need `--foreground`.
- Pixel-focus typing retains its explicitly requested AX focus prelude under every typing strategy; `synthOnly` controls text/value/selection delivery, not that separate focus operation. The focus write is composed with any later typing failure.
- The legacy SDK `type(text:target:clearExisting:typingDelay:snapshotId:)` retains its shipped `synthFirst` default and synthetic focus/clear/type behavior; default calls do not probe AX replacement eligibility. Explicit global, type, or per-app strategies still apply. When an action strategy is explicitly selected, one AX replacement is eligible only with `clearExisting: true`, zero `typingDelay`, and a fresh check proving the named target is the current keyboard receiver; cached focus or a frontmost app/window alone is insufficient. Positive delay or a successfully read focus mismatch lets `actionFirst` use the existing synthetic path; `actionOnly` refuses before dispatch. Unreadable or uncertain focus stops without input or fallback under either action strategy. The SDK's nil-target keyboard fallback and CLI foreground action-array delivery are unchanged.
- Legacy SDK AX replacement also requires bounded, same-process ancestry proving a non-web receiver. A proven `AXWebArea` descendant uses the existing keyboard route under `actionFirst` and refuses under `actionOnly`, before any value write. Unreadable, ambiguous, or incomplete ancestry stops without input or fallback. AX value readback alone does not establish page input-event behavior; this typing-only eligibility rule does not change explicit `set-value` semantics.
- Printable event fallback carries Unicode instead of physical US key positions and clears inherited modifier flags, so the requested literal text remains independent of active keyboard layouts and held user modifiers. This does not change foreground keyboard hold/release behavior.
- Background app/PID delivery is pinned to the process generation resolved before dispatch. Peekaboo revalidates the receipt before every character or special action, stops on target exit/relaunch, and reports partial delivery as retry-unsafe. Requests containing non-empty text, clear, or an editable focused-text key require Bridge protocol 1.36 plus `compositeTypeDelivery`, because those actions may use AXValue delivery; event-only special keys retain their earlier compatibility floor.
- Event injection is not evidence that the receiver changed. By default, a native `dispatched_unverified` result is
  non-success and requires a fresh observation. Standalone CLI callers can opt into `--accept-dispatched` to return
  exit 0 and `success: true` for this state, like `press` and `click`, without claiming the text arrived. The outcome
  still reports `effect: unverifiable`, `retry_safe: false`, and `requires_fresh_observation: true`; confirmed counters
  remain zero and `typedText` is omitted. This flag does not change foreground consent or Agent/MCP acceptance.
  Missing, refused, partial, indeterminate, suspected-no-op, and confirmed-no-change results remain non-success.
  `typedText`, `totalCharacters`, and `keyPresses` claim completed work
  only when the typing effect is a confirmed change. `confirmed_no_change` and missing outcomes are also non-success.
  Exact-window `--clear` followed only by printable literal text can confirm when a generation-bound, readable,
  non-secure AX value changes from its private pre-dispatch value to the exact requested value during a short bounded
  settlement window. Readback retains the pre-dispatch native receiver and permits that same field to reflow without
  selecting a replacement by label or position; field contents never enter the result. Pixel-focus typing applies the same private readback after
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

# Accept dispatch for a script that performs its own follow-up observation
peekaboo type "status report ready" --app TextEdit --foreground --accept-dispatched --json

# Cadence options also require follow-up observation unless the exact replacement shape above applies
peekaboo type "status report ready" --app TextEdit --wpm 140
peekaboo type "fast" --app TextEdit --profile linear --delay 10ms

# Pixel-focus dispatch stays retry-unsafe and requires fresh observation
peekaboo type "hello" --at 320,180 --coordinate-space image_pixels --snapshot "$SNAPSHOT_ID"
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`). Keyboard-event delivery and Bridge-hosted targeted typing also require Event Synthesizing access for the sending process; local native Accessibility edits do not. Request it when needed with `peekaboo permissions request event-synthesizing`.
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- If you see `SNAPSHOT_NOT_FOUND`, regenerate the snapshot with `peekaboo see`.
- Re-run with `--json` or `--verbose` to surface detailed errors.
