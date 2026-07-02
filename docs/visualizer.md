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
   - `VisualizationClient` builds a strongly typed `VisualizerEvent.Payload` (e.g., screenshot flash, click ripple).  
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
| `VisualizationClient` | `Core/PeekabooCore/Sources/PeekabooCore/Visualizer/VisualizationClient.swift` | Runs inside CLI/MCP processes, serializes payloads, persists them, and posts distributed notifications containing the event descriptor. |
| `VisualizerEventStore` | `Core/PeekabooCore/Sources/PeekabooCore/Visualizer/VisualizerEventStore.swift` | Owns the shared storage directory, defines the `VisualizerEvent` schema, and exposes helpers to persist, load, and clean up JSON envelopes. |
| `VisualizerEventReceiver` | `Apps/Mac/Peekaboo/Services/Visualizer/VisualizerEventReceiver.swift` | Lives in Peekaboo.app, listens for `boo.peekaboo.visualizer.event`, loads the referenced JSON, and forwards it to `VisualizerCoordinator`. |
| `VisualizerCoordinator` | `Apps/Mac/Peekaboo/Services/Visualizer/VisualizerCoordinator.swift` | Renders SwiftUI overlays (flashes, ripples, annotations, etc.) and honors user settings such as Reduce Motion. |

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

1. **Launch the UI** – Ensure Peekaboo.app is running (Poltergeist rebuilds it automatically). Confirm the log line `Visualizer event receiver registered`.
2. **Trigger an event** – Run a CLI command that emits visuals, e.g. `polter peekaboo see --mode screen --annotate --path /tmp/peekaboo-see.png`.
3. **Watch logs** – In tmux, run `./scripts/visualizer-logs.sh --last 30s --follow` to confirm both the client and receiver log the same event ID.
4. **Inspect storage** – Check the shared directory; files should appear momentarily and disappear after the mac app consumes them. A lingering file means the receiver failed to delete it (inspect logs for the error).
5. **Negative test** – Quit Peekaboo.app and rerun the CLI command. With `--verbose` or higher logging, the client should emit a single “Peekaboo.app is not running” debug line and skip event creation until the UI returns.
6. **Optional overrides** – Set `PEEKABOO_VISUALIZER_FORCE_APP=true` and re-run inside a headless harness to confirm the transport still works without the UI present (the files remain until you delete them).

## Visual Feedback Designs

### Screenshot Capture 📸
- **Effect**: Subtle camera flash animation
- **Style**: White semi-transparent overlay that quickly fades
- **Duration**: 200ms (quick flash)
- **Coverage**: Only the captured area flashes (not full screen)
- **Intensity**: 20% opacity peak to avoid irritation

### Click Actions 🎯
- **Single Click**: Blue ripple effect from click point
- **Double Click**: Purple double-ripple animation
- **Right Click**: Orange ripple with context menu hint
- **Duration**: 500ms expanding ripple
- **Extra**: Small "click" label appears briefly

### Typing Feedback ⌨️
- **Style**: Floating keyboard widget at bottom center
- **Effect**: Keys light up as typed
- **Special Keys**: Visual representation (⏎, ⇥, ⌫)
- **Position**: Semi-transparent, doesn't block content
- **Cadence**: Widget mirrors the actual `TypingCadence` (human vs. linear) and displays the live WPM/delay coming from `VisualizerEvent.typingFeedback`.
- **Duration**: Visible during typing + 500ms fade

### Scrolling 📜
- **Effect**: Directional arrows with motion blur
- **Style**: Animated arrows indicating scroll direction
- **Position**: At scroll location
- **Extra**: Scroll amount indicator (e.g., "3 lines")

### Mouse Movement 🖱️
- **Effect**: Glowing trail following mouse path
- **Style**: Fading particle trail
- **Color**: Soft blue glow
- **Duration**: Trail fades over 1 second

### Swipe/Drag Gestures 👆
- **Effect**: Animated path from start to end
- **Style**: Gradient line with directional arrow
- **Start/End**: Pulsing markers at endpoints
- **Duration**: Animation follows gesture speed

### Hotkeys ⌨️
- **Style**: Large key combination display
- **Position**: Center of screen
- **Format**: "⌘ + C", "⌃ + ⇧ + T"
- **Effect**: Keys appear with spring animation
- **Duration**: 1 second display + fade

### App Launch 🚀
- **Effect**: App icon bounces in from bottom
- **Style**: Icon + "Launching..." text
- **Animation**: Playful bounce effect
- **Duration**: Until app appears

### App Quit 🛑
- **Effect**: App icon shrinks and fades
- **Style**: Icon + "Quitting..." text
- **Animation**: Smooth scale down
- **Duration**: 500ms

### Window Operations 🪟
- **Move**: Dotted outline follows window
- **Resize**: Live dimension labels (e.g., "800×600")
- **Minimize**: Window shrinks to dock with trail
- **Close**: Red flash on window before close

### Menu Navigation 📋
- **Effect**: Sequential highlight of menu path
- **Style**: Blue glow on each menu item
- **Timing**: 200ms per menu level
- **Path**: Shows breadcrumb trail

### Dialog Interactions 💬
- **Effect**: Highlight dialog elements
- **Buttons**: Pulse when clicked
- **Text Fields**: Glow when focused
- **Style**: Attention-grabbing but not intrusive

### Space Switching 🚪
- **Effect**: Slide transition indicator
- **Style**: Arrow showing direction
- **Preview**: Mini preview of destination space
- **Duration**: Matches system animation

### Element Detection (See) 👁️
- **Effect**: All detected elements briefly highlight
- **Style**: Colored overlays labeled with opaque element IDs
- **Animation**: Fade in with slight scale
- **Duration**: 2 seconds before fade

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

Located in `/Apps/Mac/Peekaboo/Features/Visualizer/`:
- `ScreenshotFlashView.swift` - Camera flash effect
- `ClickAnimationView.swift` - Ripple effects
- `TypeAnimationView.swift` - Keyboard visualization
- `ScrollAnimationView.swift` - Scroll indicators
- `MouseTrailView.swift` - Mouse movement trails
- `HotkeyDisplayView.swift` - Key combination display
- ... (one file per animation type)

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
- **Variety**: Different click patterns for different UI elements
- **Physics**: Ripples interact with screen edges
- **Trails**: Fast clicks create comet-like trails

### Typing Widget
- **Themes**: Multiple keyboard themes (classic, modern, ghostly)
- **Effects**: Keys have satisfying press animations
- **Cadence-aware**: Uses the incoming `TypingCadence` to scale animation speed and display real WPM (linear profiles convert delay to WPM).

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

### Phase 2: Core Animation Components

#### Screenshot Flash Animation
- [ ] Create `ScreenshotFlashView.swift`
  - [ ] Implement 200ms flash animation
  - [ ] Add 20% opacity peak
  - [ ] Support custom flash regions
  - [ ] Add ghost emoji easter egg (every 100th)
- [ ] Integrate with screenshot service
  - [ ] Hook into `see` command
  - [ ] Hook into `image` command
  - [ ] Add configuration checks

#### Click Animations
- [ ] Create `ClickAnimationView.swift`
  - [ ] Single click (blue ripple)
  - [ ] Double click (purple double-ripple)
  - [ ] Right click (orange ripple)
  - [ ] Add click type labels
- [ ] Create physics system for ripples
  - [ ] Edge bounce effects
  - [ ] Ripple interference patterns
  - [ ] Trail effects for rapid clicks

#### Typing Feedback
- [ ] Create `TypeAnimationView.swift`
  - [ ] Floating keyboard widget
  - [ ] Key press animations
  - [ ] Special key representations
  - [ ] WPM counter
- [ ] Create keyboard themes
  - [ ] Classic theme
  - [ ] Modern theme
  - [ ] Ghostly theme
- [ ] Handle different keyboard layouts

#### Scroll Animations
- [ ] Create `ScrollAnimationView.swift`
  - [ ] Directional arrows
  - [ ] Motion blur effects
  - [ ] Scroll amount indicators
  - [ ] Smooth vs discrete scroll

### Phase 3: Advanced Animations

#### Mouse Movement
- [ ] Create `MouseTrailView.swift`
  - [ ] Particle trail system
  - [ ] Fading glow effect
  - [ ] Performance optimization
  - [ ] Trail customization

#### Swipe/Drag
- [ ] Create `SwipeAnimationView.swift`
  - [ ] Path drawing animation
  - [ ] Gradient effects
  - [ ] Start/end markers
  - [ ] Variable speed support

#### Hotkey Display
- [ ] Create `HotkeyDisplayView.swift`
  - [ ] Key combination formatting
  - [ ] Spring animations
  - [ ] Symbol rendering (⌘, ⌃, ⇧)
  - [ ] Multi-key sequences

#### App Lifecycle
- [ ] Create `AppLaunchAnimationView.swift`
  - [ ] Icon bounce effect
  - [ ] Progress indication
  - [ ] Custom per-app animations
- [ ] Create `AppQuitAnimationView.swift`
  - [ ] Shrink and fade effect
  - [ ] Status text display

### Phase 4: Window & System Animations

#### Window Operations
- [ ] Create `WindowOperationView.swift`
  - [ ] Move operation (dotted outline)
  - [ ] Resize operation (dimension labels)
  - [ ] Minimize animation (trail to dock)
  - [ ] Close animation (red flash)

#### Menu Navigation
- [ ] Create `MenuHighlightView.swift`
  - [ ] Sequential item highlighting
  - [ ] Breadcrumb trail
  - [ ] Timing coordination
  - [ ] Submenu support

#### Dialog Interactions
- [ ] Create `DialogFeedbackView.swift`
  - [ ] Button pulse effects
  - [ ] Text field glow
  - [ ] Focus indicators
  - [ ] Selection highlights

#### Space Switching
- [ ] Create `SpaceTransitionView.swift`
  - [ ] Slide indicators
  - [ ] Direction arrows
  - [ ] Mini space previews
  - [ ] Transition timing

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
- [ ] Screenshot ghost emoji (every 100th)
- [ ] Special animations for specific apps
- [ ] Hidden keyboard themes
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
