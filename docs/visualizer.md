---
summary: 'Peekaboo visual feedback architecture, animation catalog, and diagnostics'
read_when:
  - Designing or debugging visualizer animations
  - Touching visual feedback settings or transport code
  - Investigating CLI → app visual feedback issues
---

# Peekaboo Visual Feedback System

## Overview

The Peekaboo Visual Feedback System provides delightful, informative visual indicators for all agent actions. When the Peekaboo.app is running, CLI and MCP operations automatically get enhanced with animations and visual cues that help users understand what the agent is doing.

## Architecture

### Core Design
- **Integration**: Built directly into Peekaboo.app
- **Communication**: Distributed notifications (`boo.peekaboo.visualizer.event`) + shared JSON envelopes written by `VisualizationClient`
- **Storage**: Events live in `~/Library/Application Support/PeekabooShared/VisualizerEvents` (override with `PEEKABOO_VISUALIZER_STORAGE`)
- **Fallback**: CLI/MCP work normally without visual feedback if the app isn't running (events are simply dropped)
- **Performance**: GPU-accelerated SwiftUI animations with minimal overhead

### Communication Internals
1. **Event creation (CLI/MCP side)**  
   - `VisualizationClient` builds a strongly typed `VisualizerEvent.Payload` (e.g., screenshot flash, click feedback).
   - The payload is persisted via `VisualizerEventStore.persist(_:)`, which writes `<uuid>.json` to the shared VisualizerEvents directory and logs the exact path (look for `[VisualizerEventStore][VisualizerSmoke] persisted event …` in CLI output when debugging).  
   - Immediately afterwards the client posts `DistributedNotificationCenter.default().post(name: .visualizerEventDispatched, object: "<uuid>|<kind>")`. No `userInfo` data is used so the bridge remains sandbox friendly.
2. **Notification delivery**  
   - Any listener (Peekaboo.app, smoke harnesses, or debugging scripts) can subscribe to `boo.peekaboo.visualizer.event`.  
   - If Peekaboo.app isn’t running, the distributed notification goes nowhere and the JSON simply ages out (cleanup removes stale files after ~10 minutes).
3. **Mac app reception**  
   - `VisualizerEventReceiver` runs inside Peekaboo.app. It logs registration at launch (`Visualizer event receiver registered …`), listens for the distributed notification, parses the `<uuid>|<kind>` descriptor, and loads the referenced JSON via `VisualizerEventStore.loadEvent(id:)`.  
   - After successfully handing the payload off to `VisualizerCoordinator`, the receiver deletes the JSON (failed deletes are surfaced as `VisualizerEventReceiver: failed to delete event …` in the logs).  
   - Cleanup safeguards: the CLI schedules periodic `VisualizerEventStore.cleanup(olderThan:)` calls so abandoned files disappear. For debugging you can set `PEEKABOO_VISUALIZER_DISABLE_CLEANUP=true` to keep files on disk until the mac app consumes them.

### Communication Flow
```
MCP Server → peekaboo CLI → VisualizerEventStore → Distributed Notification → Peekaboo.app → Visual Feedback
                                ↓
                        (no app running)
                                ↓
                        Event file cleaned, CLI logs warning
```

## Components & Responsibilities

| Component | Location | Role |
| --- | --- | --- |
| `VisualizationClient` | `Core/PeekabooVisualizer/Sources/PeekabooVisualizer/Visualizer/VisualizationClient.swift` | Runs inside CLI/MCP processes, serializes payloads, persists them, and posts distributed notifications containing the event descriptor. |
| `VisualizerEventStore` | `Core/PeekabooVisualizer/Sources/PeekabooVisualizer/Visualizer/VisualizerEventStore.swift` | Owns the shared storage directory, defines the `VisualizerEvent` schema, and exposes helpers to persist, load, and clean up JSON envelopes. |
| `VisualizerEventReceiver` | `Core/PeekabooVisualizer/Sources/PeekabooVisualizer/Renderer/VisualizerEventReceiver.swift` | Hosted by Peekaboo.app, listens for `boo.peekaboo.visualizer.event`, loads the referenced JSON, and forwards it to `VisualizerCoordinator`. |
| `VisualizerCoordinator` | `Core/PeekabooVisualizer/Sources/PeekabooVisualizer/Renderer/VisualizerCoordinator.swift` | Renders SwiftUI overlays (cursor feedback, HUD chips, swipe paths, annotations) and honors user settings such as animation speed and per-action toggles. |
| `VisualizerDesign` | `Core/PeekabooVisualizer/Sources/PeekabooVisualizer/Views/VisualizerDesign.swift` | The shared "Ghost HUD" design language: theme tokens, motion curves, HUD chip container, keycaps, and glyph badges every animation composes from. |

## Smoke Testing

- Run `peekaboo visualizer` (new CLI command) to fire every animation in sequence. This is the fastest way to confirm Peekaboo.app is rendering flashes, HUDs, window/app/menu highlights, dialog overlays, and the element-detection visuals. Use it before releases or whenever you tweak visualizer code.
- Still keep the manual Visualizer Test view handy for ad-hoc previews or stress tests; the smoke command is intentionally short and non-interactive.

## Transport Storage & Format

- **Directory**: `~/Library/Application Support/PeekabooShared/VisualizerEvents`. Override with `PEEKABOO_VISUALIZER_STORAGE=/custom/path`. When sandboxing the app, set `PEEKABOO_VISUALIZER_APP_GROUP=com.example.group` so the store lives inside the App Group container.
- **File name**: `<UUID>.json`. Each payload is written atomically so the receiver never reads partial data.
- **Schema**: `VisualizerEvent` encodes `{ id, createdAt, payload }`. Payload is a `Codable` enum covering every animation type; any `Data` (screenshots, thumbnails) is base64-encoded by `JSONEncoder`.
- **Lifetime**: Clients schedule `VisualizerEventStore.cleanup(olderThan:)` sweeps so abandoned files disappear after roughly 10 minutes. For deep debugging, `PEEKABOO_VISUALIZER_DISABLE_CLEANUP=true` keeps envelopes on disk until manually removed.

### Environment Flags

- `PEEKABOO_VISUAL_FEEDBACK=false` – disable the client entirely (no files, no notifications).
- `PEEKABOO_VISUAL_SCREENSHOTS=false` – skip screenshot flash events but allow the rest.
- `PEEKABOO_VISUAL_ELEMENT_BOXES=true|false` – opt in to (or force off) the per-element bounding boxes during `see`; they default to off and the env var beats `visualizer.elementDetectionEnabled` in `config.json`.
- `PEEKABOO_VISUALIZER_MASK_TYPED_TEXT=true` – always mask typed characters as bullets. By default the typing HUD shows the text verbatim (that's the point of the caption); secure text fields are detected and masked automatically before the event is persisted.
- `PEEKABOO_VISUALIZER_STDOUT=true|false` – force VisualizationClient logs to stderr regardless of bundle context.
- `PEEKABOO_VISUALIZER_STORAGE=/path` – override the shared directory.
- `PEEKABOO_VISUALIZER_APP_GROUP=<group>` – resolve storage inside an App Group container.
- `PEEKABOO_VISUALIZER_FORCE_APP=true` – force “mac-app context” so headless harnesses (e.g., VisualizerSmoke) can emit events without launching Peekaboo.app.
- `PEEKABOO_VISUALIZER_DISABLE_CLEANUP=true` – keep envelopes on disk for forensic analysis.

Peekaboo.app still respects user-facing toggles via `PeekabooSettings`; the coordinator checks those before animating.

## Logging & Diagnostics

- **CLI / services**: `VisualizationClient` logs to the `boo.peekaboo.core` subsystem. Tail with `./scripts/visualizer-logs.sh --stream` (run inside tmux per AGENTS.md) to watch dispatch attempts and cleanup activity.
- **Mac app**: `VisualizerEventReceiver` and `VisualizerCoordinator` log under `boo.peekaboo.mac`. Look for “Visualizer event receiver registered…” followed by “Processing visualizer event …”.
- **File inspection**: `ls ~/Library/Application\\ Support/PeekabooShared/VisualizerEvents` shows outstanding events. A growing list means the mac app hasn’t consumed them (maybe it isn’t running or failed to decode the JSON).
- **Manual cleanup**: When you need a clean slate, run `rm ~/Library/Application\\ Support/PeekabooShared/VisualizerEvents/*.json`; both sides recreate the folder automatically.
- **Smoke harness**: The `VisualizerSmoke` helper (used in CI) forces `PEEKABOO_VISUALIZER_FORCE_APP=true`, emits known payloads, and asserts that the JSON lands in the shared directory—handy when debugging the transport without the full CLI.

## Failure Modes & Fixes

| Symptom | Likely Cause | How to Fix |
| --- | --- | --- |
| CLI debug logs “Peekaboo.app is not running…” and visuals stop | UI isn’t launched (intended best-effort behavior) | Start Peekaboo.app or its login item; visuals resume automatically. |
| JSON files accumulate but the app never animates | App missing permissions or `VisualizerEventReceiver` never started | Relaunch the app, grant Screen Recording/Accessibility, and confirm logs show receiver registration. |
| `VisualizerEventStore` throws file I/O errors | Shared directory missing or unwritable | Make sure the parent path exists and is writable, or set `PEEKABOO_VISUALIZER_STORAGE` to a directory with proper permissions. |
| Annotated screenshot payload fails to decode | File deleted before the app could read it (cleanup ran too soon) | Disable cleanup temporarily with `PEEKABOO_VISUALIZER_DISABLE_CLEANUP=true` or increase the cleanup interval while debugging. |
| CLI debug logs mention `DistributedNotificationCenter` sandbox issues | Sender is sandboxed and tried to include `userInfo` | Keep using the `<uuid>|<kind>` object format and load payloads from disk; never rely on `userInfo`. |

## Smoke Test Checklist

1. **Launch the UI** – Ensure Peekaboo.app is running (rebuild with `./scripts/build-mac-debug.sh` after changes). Confirm the log line `Visualizer event receiver registered`.
2. **Trigger an event** – Run a CLI command that emits visuals, e.g. `peekaboo see --mode screen --annotate --path /tmp/peekaboo-see.png`.
3. **Watch logs** – In tmux, run `./scripts/visualizer-logs.sh --last 30s --follow` to confirm both the client and receiver log the same event ID.
4. **Inspect storage** – Check the shared directory; files should appear momentarily and disappear after the mac app consumes them. A lingering file means the receiver failed to delete it (inspect logs for the error).
5. **Negative test** – Quit Peekaboo.app and rerun the CLI command. With `--verbose` or higher logging, the client should emit a single “Peekaboo.app is not running” debug line and skip event creation until the UI returns.
6. **Optional overrides** – Set `PEEKABOO_VISUALIZER_FORCE_APP=true` and re-run inside a headless harness to confirm the transport still works without the UI present (the files remain until you delete them).

## Visual Feedback Designs — the "Ghost HUD" language

All animations share one design system (`VisualizerDesign.swift`): a single violet accent (`VisualizerTheme.accent`, cyan secondary for gradients, red strictly for destructive operations), dark translucent HUD chips with hairline strokes, and a common motion vocabulary (`VisualizerMotion.pop/settle/enter/exit/glide`). Crisp cursor glyphs, restrained trails, chevrons, and keycaps keep the feedback readable without particle bursts or rainbow per-action colors.

### Screenshot Capture 📸
- **Effect**: Viewfinder corner brackets snap onto the captured region while a white veil flashes once
- **Intensity**: Veil peaks at 18% opacity scaled by the user's effect-intensity setting
- **Coverage**: Only the captured area, not the full screen
- **Easter egg**: Every 100th screenshot floats a 👻 up through the frame

### Click Actions 🖱️
- **Single Click**: A small macOS-style cursor glides to the point, presses once, and emits a subtle ring at its hotspot
- **Double Click**: The cursor presses twice with a ring for each press
- **Right Click**: The same cursor press uses the blue secondary accent
- **No labels**: The cursor motion communicates the action; there is no "Click" text

### Typing Feedback ⌨️
- **Style**: A caption pill at bottom center streams the typed text verbatim with a blinking caret
- **Privacy**: Typing into a secure text field (`AXSecureTextField`) masks the caption as bullets before the event is persisted or shown. Detection samples the actual delivery focus immediately before every non-empty text segment, so focus-changing sequences such as Tab → password → Return cannot expose the middle segment; background typing scopes the sample to its target process, and `PEEKABOO_VISUALIZER_MASK_TYPED_TEXT=true` masks everything for privacy-sensitive setups
- **Special Keys**: Rendered inline as accent glyphs (⏎, ⇥, ⌫, ⎋)
- **Cadence**: Reveal speed derives from the incoming `TypingCadence` (human WPM or fixed delay)
- **Coalescing**: Consecutive type commands crossfade through a single caption slot instead of stacking pills

### Scrolling 📜
- **Effect**: A compact circular chip at the scroll point with three chevrons flowing along the scroll direction
- **Extra**: A small "×N" tag beneath the chip when scrolling more than one unit

### Mouse Movement 🖱️
- **Effect**: A small macOS-style cursor glides from start to destination with a restrained tapered gradient trail
- **Landing**: The cursor tip arriving at the destination is the signal; no separate landing ring is drawn

### Swipe/Drag Gestures 👆
- **Effect**: The same comet vocabulary with a thicker stroke (button held)
- **Endpoints**: A press ring marks touch-down; a release ring plus a direction chevron marks touch-up

### Hotkeys ⌨️
- **Style**: macOS-style keycaps (symbol plus caption, e.g. ⌘ command) in a HUD chip at screen center
- **Effect**: Keys press down in sequence with an accent highlight, hold the chord, then release together

### App Launch / Quit 🚀
- **Style**: A HUD toast with the app icon, name, and a status line ("Launching" / "Quitting") with a colored status dot
- **Launch**: Icon springs in with a one-shot glow sweep (green status dot)
- **Quit**: Icon desaturates and sinks while the toast slips away (red status dot)

### Window Operations 🪟
- **Style**: The window outline plus a glyph badge naming the operation; accent color, red only for close
- **Close**: Outline contracts and fades. **Minimize**: outline squashes toward the bottom. **Maximize/Focus**: outline expands with a glow pulse. **Move**: outline lifts and settles. **Resize/SetBounds**: corner brackets pulse inward

### Menu Navigation 📋
- **Effect**: The menu path renders as a breadcrumb chip ("File ▸ New ▸ Project"); segments illuminate in traversal order
- **States**: Active segment gets an accent fill, visited segments stay bright, pending segments dim

### Dialog Interactions 💬
- **Effect**: The target element gets an accent outline with a glyph badge naming the action
- **Text entry**: A blinking caret at the field's leading edge; click actions pulse once

### Space Switching 🚪
- **Effect**: A macOS-style Spaces indicator chip: one dot per desktop, the active dot hops to the destination, and a "Desktop N" label updates with a direction arrow

### Element Detection (See) 👁️
- **Default**: OFF — a box per detected control clutters the screen. Opt in via the "Element Detection Boxes" toggle in Peekaboo.app settings, `"visualizer": {"elementDetectionEnabled": true}` in `~/.peekaboo/config.json`, or `PEEKABOO_VISUAL_ELEMENT_BOXES=true` (env wins over config). The gate is sender-side: `SeeTool`/`VisualizationClient` skip emitting the event unless one of those opts in (mirroring `PEEKABOO_VISUAL_SCREENSHOTS`); the receiver renders whatever it is handed once Visual Feedback is on. The app toggle writes the same config key — and a long-running CLI/MCP process re-reads `config.json` when its modification date changes — so one switch governs both processes without a restart.
- **Effect**: Every detected element gets an accent outline sized exactly to the control, with its opaque ID in a small HUD tag above
- **Coordinates**: Element rects in the payload are AppKit screen coordinates. Senders convert global Accessibility bounds through `VisualizerScreenGeometry`, flipping once against `NSScreen.screens[0]` (the primary display); logical point sizes are preserved, so Retina scale is never multiplied into overlay geometry
- **Rendering**: One overlay window per screen holds every highlight (`ElementOverlaySheetView`); degenerate and screen-filling container rects are dropped and the count is capped at 120, preferring the smallest rects
- **Animation**: Pop in with slight scale, fade out at the end; a refreshed detection retires every prior per-screen sheet before drawing the new set, including screens that now have no elements
- **Duration**: 2 seconds (scaled) before fade

### Verbosity: throttles and replace slots

Agents fire actions in bursts, so the coordinator coalesces:

- **Throttles** (`VisualizerCoordinator.FeedbackThrottle`): screenshot flash ≥ 1.2s apart, scroll chips ≥ 0.3s, mouse cursor trails ≥ 0.4s and only for moves ≥ 80pt, element sheets ≥ 1.0s, watch HUD ≥ 1.0s. Throttled events report success without drawing.
- **Replace slots** (`VisualizerCoordinator.OverlaySlot`): typing caption, hotkey chip, menu breadcrumb, Space indicator, app toast, watch HUD, annotated screenshot, and per-screen element sheets each keep at most one live overlay — a new event fades the previous one out in 0.12s and takes its place.

## Implementation Details

### Notification Bridge

- `VisualizationClient` encodes strongly typed `VisualizerEvent.Payload` values (screenshot flash, click feedback, annotated screenshot, etc.) and writes each event to `<UUID>.json` inside the shared VisualizerEvents directory.
- After persisting the payload, the client posts `DistributedNotificationCenter.default().post(name: .visualizerEventDispatched, object: "<uuid>|<kind>")`. No `userInfo` is attached so the API remains sandbox-safe.
- `VisualizerEventReceiver` (in Peekaboo.app) listens for that notification name, loads the referenced JSON via `VisualizerEventStore.loadEvent(id:)`, calls the appropriate method on `VisualizerCoordinator`, and then deletes the file. If the app isn’t running, nothing consumes the event—exactly the desired “best effort” semantics.
- Both sides periodically call `VisualizerEventStore.cleanup(olderThan:)` so abandoned files (e.g., when the app never launched) are removed automatically.

### Storage Layout

- **Directory**: `~/Library/Application Support/PeekabooShared/VisualizerEvents`
- **Overrides**:
  - `PEEKABOO_VISUALIZER_STORAGE=/custom/path` – force a different directory (great for tests)
  - `PEEKABOO_VISUALIZER_APP_GROUP=com.example.group` – resolve the store inside an App Group container
- **Format**: JSON with ISO8601 timestamps, base64 `Data` blobs, and strongly typed enums (`ClickType`, `ScrollDirection`, `WindowOperation`, etc.)

### SwiftUI Animation Components

Located in `Core/PeekabooVisualizer/Sources/PeekabooVisualizer/Views/`:
- `VisualizerDesign.swift` - Shared theme, motion curves, HUD chip, keycap, corner brackets, glyph badge
- `ScreenshotFlashView.swift` - Viewfinder brackets + shutter veil
- `CursorGlyphView.swift` - Shared macOS-style cursor shape and rendering
- `ClickAnimationView.swift` - Cursor glide, press, and hotspot ring
- `TypeAnimationView.swift` - Streaming caption pill
- `ScrollAnimationView.swift` - Flowing chevron chip
- `MouseTrailView.swift` - Cursor travel with a subtle trail (window-local coordinates)
- `SwipePathView.swift` - Drag comet with press/release rings (window-local coordinates)
- `HotkeyOverlayView.swift` - Keycap chord display
- ... (one file per animation type)

Overlay invariants worth knowing when adding animations:
- Automation, Accessibility, Core Graphics, and capture geometry enters the visualizer in global display coordinates with an upper-left primary-display origin. `VisualizerAutomationFeedbackClient` and `SeeTool` convert it exactly once through `VisualizerScreenGeometry`; everything downstream uses global AppKit coordinates with a lower-left origin. Both spaces use logical points.
- The flip axis is the primary/menu-bar display (`NSScreen.screens[0]`), not `NSScreen.main`, which follows keyboard focus and can change during automation.
- `AnimationOverlayManager` wraps every animation in a flexible container so fixed-size views center on the overlay window; without it they pin to the top-leading corner and misalign by the window padding.
- Every overlay window is inflated by a 40pt chrome margin so chip shadows and glows fade out instead of clipping at the window edge. Views that fill the window and use window-local coordinates (cursor trails, swipe paths, capture flash, element sheets) pass `chromeMargin: 0` and provide their own breathing room.
- Point-based views (mouse trail, swipe) receive window-local SwiftUI coordinates. `VisualizerCoordinator.windowLocalPoint(_:in:)` / `windowLocalRect(_:in:)` convert AppKit screen geometry (bottom-left origin) into flipped view coordinates.
- Overlays that should never stack pass a `replaceKey`; the manager crossfades the previous window of the same key.

### Integration Points

1. **Agent Tools**: Each tool in `UIAutomationTools.swift` calls visualizer
2. **Overlay Manager**: Extended to handle animation layers
3. **Window Management**: Reuses existing overlay window system
4. **Performance**: Animations auto-cleanup after completion

## Configuration

### Environment Variables
```bash
PEEKABOO_VISUAL_FEEDBACK=false            # Disable all visual feedback
PEEKABOO_VISUAL_SCREENSHOTS=false         # Disable just screenshot flash
PEEKABOO_VISUAL_ELEMENT_BOXES=true        # Opt in to per-element bounding boxes during `see` (off by default)
PEEKABOO_VISUALIZER_STDOUT=true           # Force VisualizationClient logs to stderr/stdout
PEEKABOO_VISUALIZER_STORAGE=/tmp/events   # Override the shared events directory
PEEKABOO_VISUALIZER_APP_GROUP=group.boo   # Resolve storage inside an App Group container
PEEKABOO_VISUALIZER_DISABLE_CLEANUP=true  # Keep JSON envelopes for forensic debugging (off by default)
PEEKABOO_VISUALIZER_FORCE_APP=true        # Pretend the CLI is running inside the mac app bundle (forces in-app behavior)
```

### Debugging Tips
- **Verify storage alignment**: the CLI and Peekaboo.app must point to the same `VisualizerEvents` directory. When testing, set `PEEKABOO_VISUALIZER_STORAGE=/tmp/visevents` for *both* processes so the mac app can load the JSON the CLI just wrote.
- **Disable cleanup temporarily**: `PEEKABOO_VISUALIZER_DISABLE_CLEANUP=true` keeps envelopes on disk until you inspect or replay them. Handy when the UI isn’t consuming events yet.
- **Listen to notifications**: A tiny Swift script that subscribes to `boo.peekaboo.visualizer.event` prints descriptors (`<uuid>|<kind>`) and proves the distributed notification is firing.
- **Inspect payloads**: Every persisted file logs its path (`[VisualizerEventStore][process] persisted event …`). Use `cat`/`jq` to view the JSON and even re-post it via `DistributedNotificationCenter`.
- **Mac-side breadcrumbs**: `VisualizerEventReceiver` logs when it registers, receives a descriptor, executes, and deletes the event. Tail with  
  `log stream --style compact --predicate 'process == "Peekaboo" && (composedMessage CONTAINS "Visualizer" || subsystem == "boo.peekaboo.mac")'`.
- **Replay events**: If a notification failed, re-trigger it with  
  `swift -e 'DistributedNotificationCenter.default().post(name: Notification.Name("boo.peekaboo.visualizer.event"), object: "UUID|screenshotFlash")'`.
- **Watch cleanup**: `VisualizerEventStore.cleanup` deletes envelopes older than ~10 minutes. Disable it (env var above) or inspect files quickly before they disappear.

### User Preferences (in Peekaboo.app)
- Toggle visual feedback on/off
- Adjust animation speed
- Control effect intensity
- Per-action toggles

## Fun Details 🎉

### Screenshot Flash
- **Easter Egg**: Every 100th screenshot shows a tiny 👻 ghost in the flash
- **Sound**: Optional subtle camera shutter sound
- **Customization**: Users can adjust flash intensity

### Click Animations
- **Variety**: The cursor presses once for a single click, twice for a double-click, and uses blue hotspot rings for a right-click
- **Precision**: The cursor tip is the hotspot and lands exactly on the click point

### Typing Caption
- **Content over chrome**: Shows the actual text being typed rather than a fake keyboard
- **Cadence-aware**: Uses the incoming `TypingCadence` to pace the character stream (human WPM or fixed delay).

### App Launch
- **Personality**: Each app can have custom launch animation
- **Sounds**: Optional playful sound effects
- **Progress**: Show actual launch progress if available

## Performance Considerations

1. **Lazy Loading**: Animations load on-demand
2. **GPU Acceleration**: All animations use Metal
3. **Memory Management**: Views removed after animation
4. **Battery Friendly**: Reduced effects on battery power
5. **Accessibility**: Respects "Reduce Motion" setting

## Security & Privacy

1. **No Screenshots**: Visual feedback doesn't capture screen content
2. **Local Only**: No data leaves the machine
3. **Permission Reuse**: Uses Peekaboo.app's existing permissions
4. **Sandboxed**: Runs within app sandbox

## Future Enhancements

1. **Themes**: User-created visual themes
2. **Sounds**: Optional sound effects
3. **Recording**: Save visual feedback as video
4. **Sharing**: Export automation demos with visuals
5. **AI Feedback**: Show agent's "thinking" visually

## Summary

The visual feedback system transforms Peekaboo agent operations from invisible automation into an engaging, understandable experience. By showing users exactly what the agent sees and does, we build trust and make automation accessible to everyone.

The playful touches (like the screenshot flash) add personality while remaining professional and non-intrusive. The system is designed to delight power users while helping newcomers understand automation.

Most importantly, it's completely optional - the CLI and MCP continue to work perfectly without it, making visual feedback a progressive enhancement rather than a requirement.

## Implementation Checklist

### Phase 1: Foundation (Notification Bridge)

#### Event Store & Transport
- [x] Create `VisualizerEventStore.swift` in PeekabooCore
- [x] Persist events as JSON (with base64 `Data`) inside `~/Library/Application Support/PeekabooShared/VisualizerEvents`
- [x] Provide cleanup helpers and environment overrides (`PEEKABOO_VISUALIZER_STORAGE`, `PEEKABOO_VISUALIZER_APP_GROUP`)

#### Client Dispatch
- [x] Update `VisualizationClient` to emit `VisualizerEvent.Payload` values instead of XPC RPCs
- [x] Post distributed notifications (`boo.peekaboo.visualizer.event`) containing `<uuid>|<kind>`
- [x] Respect `PEEKABOO_VISUAL_FEEDBACK`, `PEEKABOO_VISUAL_SCREENSHOTS`, and `PEEKABOO_VISUALIZER_STDOUT`

#### App Receiver
- [x] Add `VisualizerEventReceiver` inside Peekaboo.app
- [x] Load events via `VisualizerEventStore`, forward to `VisualizerCoordinator`, then delete consumed files
- [x] Periodically clean stale events so the shared directory stays small

#### Overlay Window Enhancement
- [ ] Extend `OverlayManager.swift`
  - [ ] Add animation layer management
  - [ ] Create animation queue system
  - [ ] Add cleanup timers for animations
  - [ ] Support multiple concurrent animations
- [ ] Create `VisualizerOverlayWindow.swift`
  - [ ] Configure for animation display
  - [ ] Set proper window level
  - [ ] Handle multi-screen setups
  - [ ] Add debug mode for testing

### Phase 2–4: Animation Components (shipped as the Ghost HUD redesign)

All per-action views exist in `Core/PeekabooVisualizer/Sources/PeekabooVisualizer/Views/` and compose the shared design system in `VisualizerDesign.swift`:

- [x] `ScreenshotFlashView` — viewfinder brackets, shutter veil, 👻 easter egg (every 100th)
- [x] `CursorGlyphView` — crisp macOS-style arrow with a top-leading hotspot
- [x] `ClickAnimationView` — cursor glide with single/double/right-button press feedback
- [x] `TypeAnimationView` — streaming caption pill with cadence-derived pacing
- [x] `ScrollAnimationView` — flowing chevron chip with amount tag
- [x] `MouseTrailView` — cursor travel with a subtle tapered trail (window-local coordinates)
- [x] `SwipePathView` — drag comet with press/release rings
- [x] `HotkeyOverlayView` — keycap chord with sequenced presses
- [x] `AppLifecycleView` — launch/quit toast with status dot
- [x] `WindowOperationView` — outline motion per operation, corner brackets for resize
- [x] `MenuNavigationView` — breadcrumb with sequential illumination
- [x] `DialogInteractionView` — element outline, glyph badge, caret for text entry
- [x] `SpaceTransitionView` — Spaces dot indicator with hopping active dot

### Phase 5: Integration

#### Tool Integration
- [ ] Update `UIAutomationTools.swift`
  - [ ] Add visualizer calls to click tool
  - [ ] Add visualizer calls to type tool
  - [ ] Add visualizer calls to scroll tool
  - [ ] Add visualizer calls to swipe tool
- [ ] Update `VisionTools.swift`
  - [ ] Add screenshot flash to see command
  - [ ] Add element highlight animations
- [ ] Update `ApplicationTools.swift`
  - [ ] Add app launch/quit animations
- [ ] Update `WindowManagementTools.swift`
  - [ ] Add window operation animations
- [ ] Update `MenuTools.swift`
  - [ ] Add menu navigation highlights
- [ ] Update `DialogTools.swift`
  - [ ] Add dialog interaction feedback

#### Configuration System
- [ ] Add environment variable support
  - [x] `PEEKABOO_VISUAL_FEEDBACK`
  - [x] `PEEKABOO_VISUAL_SCREENSHOTS`
  - [x] `PEEKABOO_VISUALIZER_STDOUT`
  - [x] `PEEKABOO_VISUALIZER_STORAGE`
  - [x] `PEEKABOO_VISUALIZER_APP_GROUP`
  - [ ] Per-action toggles
- [ ] Add app preferences UI
  - [ ] Master on/off toggle
  - [ ] Animation speed slider
  - [ ] Effect intensity controls
  - [ ] Per-action checkboxes

### Phase 6: Performance & Polish

#### Optimization
- [ ] Profile animation performance
  - [ ] GPU usage monitoring
  - [ ] Memory leak detection
  - [ ] Frame rate analysis
- [ ] Implement animation pooling
- [ ] Add battery-saving mode
- [ ] Respect "Reduce Motion" setting

#### Testing
- [ ] Integration tests for the distributed event bridge
- [ ] Animation timing tests
- [ ] Multi-screen testing
- [ ] Performance benchmarks
- [ ] Accessibility testing

#### Documentation
- [ ] API documentation for `VisualizerEvent` schema
- [ ] Animation customization guide
- [ ] Troubleshooting guide
- [ ] Video demos of all animations

### Phase 7: Fun Features

#### Easter Eggs
- [x] Screenshot ghost emoji (every 100th)
- [ ] Special animations for specific apps
- [ ] Achievement system

#### Sound Effects (Optional)
- [ ] Camera shutter for screenshots
- [ ] Click sounds
- [ ] Typing sounds
- [ ] Success/failure sounds

#### Advanced Features
- [ ] Animation recording system
- [ ] Custom theme editor
- [ ] Animation export for demos
- [ ] AI "thinking" visualization

### Phase 8: Release

#### Final Testing
- [ ] Full integration test suite
- [ ] Beta testing with users
- [ ] Performance validation
- [ ] Security review

#### Documentation
- [ ] Update README.md
- [ ] Create tutorial videos
- [ ] Write blog post
- [ ] Update website

#### Distribution
- [ ] Ensure visualizer works with MCP
- [ ] Test npm package integration
- [ ] Verify CLI fallback behavior
- [ ] Release notes

## Success Criteria

- [ ] All agent actions have visual feedback
- [ ] Zero performance impact when disabled
- [ ] < 5% CPU usage during animations
- [ ] Works on all macOS versions (15.0+)
- [ ] Graceful fallback without Peekaboo.app
- [ ] Delightful user experience
- [ ] Professional appearance
- [ ] Fun but not distracting
