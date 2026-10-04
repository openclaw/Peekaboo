---
summary: 'Scroll targets in the background or explicitly synthesize foreground wheel input'
read_when:
  - 'panning long views or tables without dragging the scrollbar'
  - 'needing scroll result details (direction, ticks) for automation logs'
---

# `peekaboo scroll`

`scroll` uses native Accessibility by default, keeping the target app in the background and leaving the shared cursor untouched. It prefers the target's writable numeric scrollbar, then directional Accessibility actions. When a visible WKWebView/Tauri surface exposes only an opaque container, Peekaboo can instead route line-wheel events to the fresh snapshot's exact PID/window. Add `--foreground` for targetless, smooth, or delayed global wheel input.

## Key options
| Flag | Description |
| --- | --- |
| `--direction up|down|left|right` | Required. Case-insensitive and validated before execution. |
| `--amount <ticks>` | Number of scroll units (default `3`); native distance depends on the selected route below. Smooth mode multiplies this internally. |
| `--on <element-id>` | Scroll relative to a Peekaboo element from the current/most recent snapshot; mutually exclusive with `--at`. |
| `--at x,y` | Background point in logical coordinates relative to the explicitly captured window. Requires a concrete pixel-backed `--snapshot`; mutually exclusive with `--on`. |
| `--global` | Interpret `--at` as global display points. This changes coordinate basis only, not target ownership or delivery permission. |
| `--snapshot <id>` | Override the element snapshot; required explicitly for coordinates. |
| `--foreground` | Focus the target and allow synthetic wheel events at the physical pointer. Required without `--on` or `--at`; cannot be combined with `--at`. |
| `--delay <duration>` | Time between synthetic ticks (default `0`; bare values are milliseconds; nonzero requires `--foreground`). Valid long delays remain cancellable; cancelling a wait stops the remaining ticks. |
| `--smooth` | Use smaller synthetic increments; requires `--foreground`. |
| Target flags | `--app <name>`, `--pid <pid>`, `--window-id <id>`, `--window-title <title>`, `--window-index <n>`. Background mode uses these only to resolve/refresh the target; foreground mode focuses it first. |
| Foreground focus flags | `--space-switch`, `--bring-to-current-space`, timeout, and retry controls require `--foreground`. |

Amounts whose magnitude or smooth-mode tick count cannot be represented are rejected before focus or input.

## Implementation notes
- If you pass `--on` without a snapshot, the command automatically looks up `services.snapshots.getMostRecentSnapshot()` so you rarely need to wire IDs manually.
- A concrete `--snapshot <id>` is authoritative and never triggers an observation refresh or a new capture. Omitted, blank, `latest`, `most-recent`, and `most_recent` references may refresh missing elements and therefore can require a capture-capable host.
- Remote background element scroll requires Bridge protocol 1.35 and the service-derived `requestPinnedExactWindowScrollReceipt` capability. Older or capability-missing hosts refuse before scroll dispatch.
- Coordinate scroll additionally requires protocol 1.43 and service-derived `backgroundCoordinateScroll` support. Its point must lie inside the capture-owned exact window. AX-only snapshots, nonfinite points, mismatched references, and coordinate-plus-foreground requests refuse before input; there is no global-input downgrade.
- The semantic coordinate selector uses a PID-scoped hit-test and a bounded hit/ancestor walk to the nearest proven scroll owner. It does not search arbitrary descendants or siblings. Once selected, an unsupported axis, disabled target, or accepted/ambiguous mutation never triggers a search for another ancestor. Existing numeric-scrollbar/page-action priority remains unchanged.
- Coordinate scrolling uses only the selected bar itself or the selected owner's explicit `AXHorizontalScrollBar` / `AXVerticalScrollBar` associations before its page actions. It never searches descendants for a bar, so a nested or sibling scroller cannot become the AX receiver after hit testing.
- If a canonical scroll result requires fresh observation, or no canonical outcome is available, the used snapshot remains readable but cannot drive another mutation. Re-run `peekaboo see`; replaying the old ID returns `SNAPSHOT_STALE` before dispatch.
- Background scrolling first uses an owned axis-matching `AXScrollBar` with a writable finite numeric value and valid range. Axis matching uses a recognized `AXOrientation` first, otherwise finite positive non-square bounds; an unknown axis never preempts a page action. Each requested unit uses the bar's positive finite `AXValueIncrement`, or one tenth of its range when none is usable, clamped to the range; the combined value update counts as one native mutation. A nested scroll area's bar is never borrowed. Missing or nonfinite value readback remains dispatched-unverified, not a confirmed change.
- Numeric-first routing also applies when the target's page actions work: those targets now move by scrollbar increments instead of viewport pages for the same `--amount`. The numeric calculation is unchanged, but its new priority can change travel distance. Observe the resulting viewport rather than assuming the former page distance.
- If no numeric route is available, or its write is definitively rejected as unsupported before any mutation is accepted, directional page actions and then scrollbar increment/decrement actions remain available. A stale or permission-denied target still stops; an accepted or ambiguous value write never falls through to another route.
- If a group, web area, or scroll area still cannot scroll through Accessibility, a pixel-backed exact-window snapshot may use native PID-routed wheel events only for an eligible visible native app. Peekaboo revalidates the captured process generation, window ID, bounds, and point around every tick; it never activates the app, moves the cursor, or falls back to a desktop-global event. The captured element's midpoint must be inside the exact window; out-of-window geometry is not clamped or replaced with another control's bounds.
- Coordinate scroll can use its pixel-backed exact-window authority independently when the application-root hit test reports `notImplemented` or `noValue`, or verified ancestry reaches the captured window without an exposed semantic owner. This only enables the existing visible native-WebKit wheel route; it does not invent an AX receiver or make arbitrary opaque apps eligible. Native lookup failures, unreadable ancestry, positive PID/window/bounds conflicts, and a change between semantic and pixel-only routing refuse before dispatch. No system-wide or undocumented window-root hit-test fallback is used.
- Eligible coordinate wheel delivery retains the requested point rather than substituting an element midpoint. It adds no pointer primer and makes no claim that the intended nested scroller consumed the events; verify which region moved with a fresh observation. Pixel-only delivery omits AX element-role metadata instead of guessing it.
- Transport selection uses application metadata without reading the app executable. Only otherwise eligible native wheel targets receive one bounded executable-prefix probe for a WebKit import, or exact `com.apple.Safari` with `/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari`. This recognizes Safari's indirect framework linkage without recursively inspecting libraries; classification is not cached across operations and does not prove receiver consumption.
- Fallback is available only before the first native scroll unit is accepted. If a multi-page Accessibility, scroll-bar, value, or exact-window route stops after a definite prefix, Peekaboo reports retry-unsafe `partial` with the exact accepted-unit count and side-effect recovery guidance; an ambiguous in-flight unit reports retry-unsafe `indeterminate` and requires fresh observation. Another route never replays the full requested amount.
- A target with no supported background route returns a typed `refused` / `operation_unsupported` result with no dispatched input, safe retry metadata and its validated exact target. This remains a no-dispatch refusal through Bridge, not an indeterminate mutation. Observe a fresh scrollable control or eligible WebKit content target; the refusal never enables foreground input automatically.
- Wheel-route resolution, bounds, permission, or event-preparation failures before the first posted tick retain typed retry-safe no-dispatch outcomes through Bridge. Stale geometry remains `SNAPSHOT_STALE`; observe a fresh in-window target. Failures after an accepted prefix, completed dispatch, or already-uncertain delivery keep their retry-unsafe outcomes.
- macOS does not acknowledge receiver consumption for PID-routed wheel events. A successful routed dispatch therefore reports `effect: "unverifiable"`, `retry_safe: false`, and requires a fresh observation before another scroll. Hidden apps, AX-only snapshots, Electron/Chromium/Catalyst apps, stale receipts, and changed bounds keep the existing pre-dispatch refusal.
- Foreground mode verifies focus when a target exists, then uses synthetic wheel events. Focus failure aborts before pointer dispatch.
- JSON output reports target diagnostics for element scrolls and the current pointer position for explicit foreground targetless scrolls. When a snapshot carries a complete exact receipt, `targetReceipt` repeats its snapshot ID, PID, decimal process-generation identity, window ID, and bounds so callers can audit the dispatched destination.
- MCP background scroll errors retain the service's reported `target_receipt` when an unconfirmed result becomes an error. Missing receipts are not inferred from the request snapshot, and foreground global input is not attributed to a window; outcome, retry safety, and snapshot invalidation are unchanged.
- `ScrollRequest` is handed directly to `AutomationServiceBridge.scroll`, so the CLI benefits from the same smooth/step semantics the agent runtime sees.

## Examples
```bash
# Scroll down five ticks wherever the pointer currently sits
peekaboo scroll --direction down --amount 5 --foreground

# Scroll the element labeled "table_orders" using the latest snapshot
peekaboo scroll --direction up --amount 2 --on table_orders

# Under capture-owner contention, create an exact classic receipt once and scroll without another capture
SNAPSHOT_ID=$(peekaboo see --pid 123 --window-id 456 --capture-engine classic --json | jq -r '.data.snapshot_id')
peekaboo scroll --direction down --on table_orders --snapshot "$SNAPSHOT_ID"

# Scroll at logical point 200,150 relative to the captured window
peekaboo scroll --direction down --at 200,150 --snapshot "$SNAPSHOT_ID"

# Or name a global display point inside that same exact window
peekaboo scroll --direction right --at 900,450 --global --snapshot "$SNAPSHOT_ID"

# Smooth horizontal pan after intentionally focusing Keynote
peekaboo scroll --direction right --smooth --app Keynote --foreground --space-switch
```

## MCP coordinates

MCP `scroll` accepts `coords: "x,y"` instead of `on`. As with MCP `click`, its default is global display points,
not the CLI's window-relative basis. `coordinate_space` can be `global_display_points`, `image_pixels`, or
`normalized`; the latter two require `coordinate_reference` from `see` and map through the delivered image's
scale and ROI. A supplied `snapshot` must match that reference. Coordinates always require an explicit fresh
pixel-backed exact-window reference and cannot be combined with `foreground`, smooth input, or a nonzero delay.

## Troubleshooting
- Background element scroll needs Accessibility. The exact-window WebKit wheel route and foreground wheel input also need Event Synthesizing on the selected execution host (`peekaboo permissions status`).
- If an omitted/latest snapshot needs refresh while another process owns ScreenCaptureKit, run an exact `peekaboo see --capture-engine classic`, then retry `scroll` with the returned concrete `--snapshot` ID. `scroll` itself does not accept `--capture-engine` because an explicit receipt performs no capture.
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
