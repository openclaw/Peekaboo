---
summary: 'Target UI elements via peekaboo click'
read_when:
  - 'building deterministic element interactions after running `see`'
  - 'debugging focus/snapshot issues for click automation'
---

# `peekaboo click`

`click` is the primary interaction command. It accepts exactly one of an element ID, fuzzy text query, or literal coordinate target and then drives `AutomationServiceBridge.click`. Contradictory or whitespace-only target shapes fail before lookup, focus, or mutation. Background delivery is the default so target apps do not need to become frontmost; pass `--foreground` for focused foreground mouse behavior.

## Key options
| Flag | Description |
| --- | --- |
| `[query]` | Optional positional text query (case-insensitive substring match). |
| `--on <id>` | Target an opaque Peekaboo element ID copied exactly from current `see` or MCP `inspect_ui` output. |
| `--at x,y` | Click coordinates. With target flags, coordinates are relative to the resolved target window; without target flags, they are global screen coordinates. |
| `--global` | Treat `--at` as global screen coordinates even when target flags are supplied. |
| `--snapshot <id>` | Reuse a prior snapshot. A concrete ID must be `ps1_` plus 32 lowercase ASCII hexadecimal digits; element/query clicks otherwise default to the latest snapshot. Background coordinate clicks require an explicit reference from a fresh exact-window `see`. |
| Target flags | `--app <name>`, `--pid <pid>`, `--window-id <id>`, `--window-title <title>`, `--window-index <n>` — resolve the app/window that should receive the click. In background mode this does not focus the app; with `--foreground` it focuses before clicking. (`--window-title`/`--window-index` require `--app` or `--pid`; `--window-id` does not.) |
| `--wait-for <duration>` | Timeout while waiting for the element (default `5s`; bare values are milliseconds). |
| `--double` / `--triple` / `--right` / `--middle` | Select one alternate click kind. Background middle/triple delivery requires a fresh exact-window snapshot and uses native window-routed events; `--foreground` remains available for shared-pointer behavior. Click-kind flags are mutually exclusive. |
| `--long-press` | Send mouse-down, hold stationary for 1.2 seconds, then mouse-up. This shared-pointer gesture requires explicit `--foreground` and cannot be combined with another click-kind flag or `--focus-background`. |
| `--modifiers <keys>` | Hold a comma-separated set of `cmd`, `shift`, and `option` for one exact foreground click. Requires explicit `--foreground` and a non-`latest` screenshot snapshot; `fn`, Control/right contextual clicks, long press, focus overrides, and competing app/window selectors are refused. |
| `--foreground` | Focus target and send a foreground mouse click. Focus flags require this explicit mode. |
| Focus flags | `--no-auto-focus`, `--focus-timeout`, `--focus-retry-count`, `--space-switch`, `--bring-to-current-space` (foreground mode only; see `FocusCommandOptions`). |
| `--focus-background` | Legacy alias for the default background delivery. Use `--app`, `--pid`, `--window-id`, or a snapshot with process metadata. |

## Snapshot affinity

The process that performs `see` generates a 128-bit random `ps1_` reference and reserves it before storing the
snapshot contents. Stores cannot mint an unreserved reference. When `click --snapshot` receives a concrete reference,
Peekaboo asks the local process and authenticated live Bridge candidates who owns it, requires exactly one owner, and
routes there before considering the usual daemon/app preferences. A stopped producer, no owner, or multiple claimants
is a pre-dispatch refusal rather than permission to guess.

`--bridge-socket` and `--no-remote` stay authoritative. The former checks only the named authenticated Bridge host;
the latter checks only the current local process. If that selected execution boundary does not own the snapshot, the
click fails without rerouting. Old timestamp IDs are non-actionable and fail validation even when a legacy cache
directory still exists.

Bridge 1.34 negotiates producer ownership separately from targeted Accessibility-value click delivery. A current
client refuses an older 1.34 host that lacks producer-bound reference support before publishing a reusable snapshot.
The independent targeted-value capability permits the verified `AXFocused` write used for a focusable text field;
without it, the client does not request that fallback, while ordinary `AXPress` delivery remains available.

## Delivery modes
- **Background** is the default when Peekaboo can resolve a target process from target flags or snapshot metadata. Single clicks prefer accessibility actions and never activate or focus the app: element/query clicks invoke the matching AX action on the cached element; coordinate clicks hit-test the AX element at the point (`AXUIElementCopyElementAtPosition`), then press the actionable hit, descendant, or ancestor. Pressability is checked with the Accessibility actions API, so SwiftUI buttons that expose no action attribute are still pressed.
- Background right-, double-, middle-, and triple-clicks can use native PID/window-routed CGEvents. Middle-click emits one `otherMouseDown`/`otherMouseUp` center-button pair; triple-click emits three left-button pairs with click states 1, 2, and 3. Each sequence starts with a target-window pointer primer, so canonical outcomes report three dispatched units for middle-click and seven for triple-click. Every event carries screen and window-local coordinates, exact PID/window routing fields, and a process-generation receipt revalidated before every event. The route never warps the physical cursor, activates an app, or falls back to desktop-global injection. Because macOS does not acknowledge application-level handling of these events, JSON reports `verified: false` and `effect: "unverifiable"` after a complete dispatch. Missing, moved, wrong-layer, out-of-bounds, wrong-owner, or generation-changed targets are refused. If the route changes after mouse-down, Peekaboo noncancellably releases mouse-up only to the original live process generation before reporting the click effect as indeterminate; a recycled PID is never targeted for cleanup.
- Cancellation before routed dispatch remains an ordinary cancellation. Once any routed click event has been emitted, cancellation returns a retry-unsafe indeterminate error with the known emitted-unit count; observe the target before deciding whether to retry.
- Background clicks fail with an actionable error instead of guessing. A single left click with no pressable AX element and any routed pointer click without an exact provable window fail before unsafe fallback and suggest `--foreground` where appropriate.
- Background `--app` selectors must exactly match an application name or bundle ID; `--pid` remains the most explicit process selector. Fuzzy text is still supported for the element query itself, but a partial application name is refused before click dispatch.
- A background single click on an explicitly selected focusable text field uses the field's writable `AXFocused`
  attribute. Success is confirmed only after the same PID/window/role/frame/identifier reports `AXFocused=true` and
  the exact process-generation/window/bounds receipt still matches; it never activates the app or falls back to a
  shared-pointer click.
- A background `AXPress` that does not complete within the delivery grace period is a failure, not success. Generic layout/web containers are never accepted as press targets even if an app advertises `AXPress` on them.
- Process-targeted element clicks carry the resolved app's process-generation receipt through Bridge and native dispatch. A recycled PID is refused before mutation; generation drift after dispatch is reported as retry-unsafe and requires a fresh observation. Remote process-only delivery requires Bridge protocol 1.22 or newer; exact-window receipts keep their existing protocol contract.
- **Foreground** (`--foreground`) focuses the target first (via `ensureFocused`, hopping Spaces if needed) and then synthesizes a real mouse click at the resolved screen point — element and query targets are resolved to their adjusted center and clicked with genuine mouse events, so double, triple, right, and middle semantics match hardware clicks. If the target app is still not frontmost after the focus step, the command fails rather than clicking into whichever app is in front.
- Modifier-click (`--modifiers ... --foreground`) is one atomic shared-desktop operation. Peekaboo preflights the snapshot's exact process generation, window ID, bounds, and point before focusing; posts one prebuilt modifier-bearing HID mouse sequence without changing shared keyboard state; waits until its mouse-up sequence reaches the session; then restores the prior cursor only if it still owns the click position and restores prior focus only if its target remains frontmost. Newer user or application state wins those compare-and-swap checks and is reported as `preserved_newer_state` instead of being overwritten. Control/right contextual clicks are refused because restoring the prior foreground would dismiss their result.
- Long press (`--long-press --foreground`) uses the foreground path and emits a stationary mouse-down/1.2-second hold/mouse-up sequence. Peekaboo rejects the gesture before focus or pointer dispatch when `--foreground` is absent. It does not synthesize drag or micro-move events, because those can cancel native long-press recognizers.
- Background coordinate clicks require `--snapshot` from a fresh exact-window `see`. The captured PID, window ID, process generation, and bounds are matched against any `--app`/`--pid`/window selector and revalidated immediately before dispatch. PID-only/app-only coordinates, empty snapshots, same-ID replacement windows, and moved bounds are refused before mutation. Without a capture reference, use explicit `--foreground` global coordinates.
- Right-click (`--right`) issues `AXShowMenu` without waiting for the context menu to close: a successfully opened menu runs a nested tracking runloop in the target app, so the command reports success once the menu is up instead of timing out behind it.

## Implementation notes
- Result application labels reuse the application/window and snapshot metadata already bound for dispatch. Point diagnostics are prepared before dispatch and retained for output; formatting does not refetch snapshots, enumerate, or re-resolve applications after clicking. Missing names use the bound PID, window ID, or `Unknown`, and never borrow an unrelated frontmost app. Presentation does not change the canonical action outcome or target receipt.
- Validation requires exactly one targeting strategy (`[query]`, `--on`, or `--at`) and parses coordinate strings into doubles. Target-relative coordinate clicks fail if the point is outside the resolved window.
- When no `--snapshot` is provided, element/query clicks may use the most recent snapshot. Foreground global coordinates remain snapshot-free. Background coordinates never infer ownership at dispatch time: they resolve through the explicit capture snapshot and pass its exact receipt through the automation/Bridge boundary.
- A result with `requires_fresh_observation: true`, or a host that cannot return a canonical outcome, consumes that snapshot for mutation. Reusing its ID for another click, action, value change, or targeted scroll returns `SNAPSHOT_STALE` before dispatch; run `peekaboo see` and use the new ID. Read-only inspection of the old snapshot remains available for diagnostics.
- Background element/query clicks re-resolve cached elements in the target process and exact snapshot window, then invoke their AX action; when the element cannot be re-resolved, the adjusted snapshot point is hit-tested and the AX element found there is pressed. Mismatched process/window selectors and unverifiable window snapshots are rejected. Run `peekaboo see` first when you need fresh element IDs or target metadata.
- Foreground element-based clicks call `AutomationServiceBridge.waitForElement` with the supplied timeout so you don’t have to insert manual sleeps. Helpful hints are printed when timeouts expire.
- `--foreground` enforces focus just before the click by `ensureFocused`; it will hop Spaces if necessary unless you pass `--no-auto-focus`. The element's screen point is then clicked with real synthetic mouse events, and the command verifies the target app is frontmost before dispatching so the click cannot land in another app.
- Background AX clicks require Accessibility permission; routed background right/double/middle/triple clicks also require Event Synthesizing permission. Protocol 1.30 plus the `statelessClickVariants` host capability is required before middle/triple payloads are encoded, so protocol 1.29 and capability-missing hosts are refused before dispatch. Exact-window pinning rejects vanished/reused windows and points outside current bounds before native dispatch.
- JSON output reports `clickedElement`, `clickType`, input coordinates, resolved screen coordinates, coordinate space, target window metadata, wait time, execution time, `verified`/`effect` for routed pointer delivery, and `targetPoint` diagnostics. Element/query `targetPoint` includes the original snapshot midpoint, the final resolved point, the snapshot ID, and whether a moved-window adjustment was applied.

## Examples
```bash
# Click the "Send" button using an ID copied from current `see` output
peekaboo click --on "$ELEMENT_ID"

# Fuzzy search + extra wait for a slow dialog using foreground delivery
peekaboo click "Allow" --foreground --wait-for 8s --space-switch

# Resolve one exact window and capture a fresh coordinate reference
peekaboo window list --app Safari --json
peekaboo see --window-id "$WINDOW_ID" --no-elements --json

# Issue a background right-click in that exact window without moving the cursor
peekaboo click --window-id "$WINDOW_ID" --snapshot "$SNAPSHOT_ID" --at 420,180 --right

# Issue exact-window background middle and triple clicks without moving the cursor
peekaboo click --window-id "$WINDOW_ID" --snapshot "$SNAPSHOT_ID" --at 420,180 --middle
peekaboo click --window-id "$WINDOW_ID" --snapshot "$SNAPSHOT_ID" --at 420,180 --triple

# Trigger a SwiftUI long-press gesture
peekaboo click --window-id "$WINDOW_ID" --snapshot "$SNAPSHOT_ID" --at 640,420 --long-press --foreground

# Command-shift-click one captured element, then restore only state Peekaboo still owns
peekaboo click --on "$ELEMENT_ID" --snapshot "$SNAPSHOT_ID" --foreground --modifiers cmd,shift

# Click 20,40 inside the freshly captured window
peekaboo click --window-id "$WINDOW_ID" --snapshot "$SNAPSHOT_ID" --at 20,40

# Force global screen coordinates while still focusing a target first
peekaboo click --window-id "$WINDOW_ID" --snapshot "$SNAPSHOT_ID" --at 1024,88 --global --foreground

# Click captured Safari coordinates without activating Safari
peekaboo see --window-id "$WINDOW_ID" --no-elements --json
peekaboo click --window-id "$WINDOW_ID" --snapshot "$SNAPSHOT_ID" --at 420,180

# Browser fallback when web content has no actionable accessibility descendants
peekaboo screen list --json
peekaboo window list --app "Google Chrome" --json
peekaboo see --window-id "$WINDOW_ID" --no-elements --json
peekaboo click --window-id "$WINDOW_ID" --snapshot "$SNAPSHOT_ID" --at 420,180 \
  --foreground --input-strategy synthOnly
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- If you see `SNAPSHOT_NOT_FOUND`, regenerate the snapshot with `peekaboo see` (or omit `--snapshot` to use the most recent one). Cleaned/expired snapshots cannot be reused.
- If an explicit socket or local-only run reports that it does not own the snapshot, repeat `see` on that same host or
  remove the routing override and let Peekaboo find the unique live producer. It will not silently cross an explicit
  host boundary.
- If you see `SNAPSHOT_STALE` after an unverified or indeterminate action, do not replay the old snapshot. Observe again and use the new snapshot ID.
- Re-run with `--json` or `--verbose` to surface detailed errors.
- Chromium browsers can expose menus plus generic web-area/layout containers while omitting actionable web-content descendants from `see --annotate`. This is a browser accessibility limitation, not proof that the page is empty. Use `screen list` and `window list` to map the intended display/window, then use `--foreground --input-strategy synthOnly` with window-relative coordinates. For already-focused browser automation, targetless `--global` is also valid.
