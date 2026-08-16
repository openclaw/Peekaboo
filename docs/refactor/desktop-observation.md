---
summary: 'Grand refactor plan for unifying Peekaboo screenshot, AX detection, OCR, annotations, and desktop observation architecture.'
read_when:
  - 'planning major refactors to see, image, capture, or element detection'
  - 'changing screenshot performance, AX traversal, or capture target selection'
  - 'splitting ScreenCaptureService or ElementDetectionService'
  - 'moving CLI capture behavior into AutomationKit'
  - 'debugging app-window selection, Retina scale, or annotation output'
---

# Desktop Observation Refactor

> **Historical record:** Commands and outputs are preserved as observed when this document was written. See the
> [Peekaboo 4 migration guide](../v4-migration.md) for current CLI syntax.

## Thesis

Peekaboo should have one product-level answer to this question:

> What is visible on the desktop, where did it come from, what pixels represent it, and what can I do with it?

Today that answer is still spread across command code, MCP tools, capture services, element detection, menu-bar helpers, annotation renderers, and snapshot writers. The grand refactor is to make `DesktopObservationService.observe(_:)` the single behavioral pipeline for desktop inspection, then make CLI/MCP/agent tools thin adapters.

The desired shape is:

```text
CLI / MCP / agent request
  -> DesktopObservationRequest
  -> request-scoped DesktopStateSnapshot
  -> ObservationTargetResolver
  -> CapturePlan
  -> CaptureExecutor
  -> ElementObservationService
  -> ObservationOutputWriter
  -> DesktopObservationResult
  -> CLI / MCP / agent renderer
```

Command files should parse flags and render typed results. They should not rank windows, infer Retina scale, traverse AX, choose focus fallback behavior, build screenshot companion paths, or decide where snapshots live.

## Status: May 10, 2026

This plan is active and partially landed.

Landed:

- `DesktopObservationRequest`, target, capture, detection, output, timeout, timing, diagnostic, and result models.
- `DesktopObservationService` facade in `PeekabooAutomationKit`.
- `ObservationTargetResolver` for core targets.
- Request-scoped `DesktopStateSnapshot` for target resolution and diagnostics.
- `ObservationOutputWriter` and `ObservationOutputPathResolver` for raw screenshot persistence, directory-aware output path planning, annotated companion-path planning, basic annotation rendering, and snapshot registration.
- Observation-backed paths for CLI `see`, CLI `image`, MCP `see`, and MCP `image`.
- Request-scoped capture engine preference through observation.
- Observation detection timeout enforcement.
- Central screen capture scale planning for logical 1x versus native Retina output.
- Direct `ElementDetectionService` timeout racing through `ElementDetectionTimeoutRunner`.
- AX traversal policy extraction into `AXTraversalPolicy`.
- AX tree cache state extraction into `ElementDetectionCache`.
- AX role/actionability/shortcut/attribute policy extraction into `ElementClassifier`.
- Batched AX descriptor reads and AX value coercion through `AXDescriptorReader`.
- Element grouping and metadata assembly through `ElementDetectionResultBuilder`.
- Sparse Chromium/Tauri web focus recovery through `WebFocusFallback`.
- Generic-group text-field recovery through `ElementTypeAdjuster`.
- Application menu-bar element collection through `MenuBarElementCollector`.
- Accessibility tree traversal through `AXTreeCollector`.
- Detection app/window fallback selection through `ElementDetectionWindowResolver`.
- Capture frame-source policy and display-local source-rectangle planning through `ScreenCapturePlanner`.
- Screen Recording enforcement through `ScreenCapturePermissionGate`.
- Logical 1x capture downscaling through `ScreenCaptureImageScaler`.
- ScreenCaptureKit frame-source internals now keep stream handler/session types in a focused companion while the frame source owns request orchestration.
- MCP image capture now separates tool entrypoint, capture orchestration, and request/format types into focused files.
- MCP list output now keeps parsing and formatting helpers in a focused companion file.
- MCP type tooling now keeps request/target types and response/action formatting in focused companions while `TypeTool` owns schema, validation, and execution flow.
- MCP move tooling now keeps coordinate parsing, target resolution/movement execution, response formatting, and request/result types in focused companions.
- Legacy area capture through the legacy capture operator.
- Dedicated ScreenCaptureKit and legacy capture operator files.
- Screen capture operation gating/metrics and capture execution orchestration are split out of the primary `ScreenCaptureService`.
- ScreenCaptureKit display/area capture, window capture, and shared frame-source support are split out of the primary operator.
- Watch capture lifecycle, loop/diff cadence, and frame/video persistence are split across focused session companions.
- Application window listing keeps service facade/output assembly separate from hybrid CGWindowList/AX enumeration policy.
- Capture models now keep image primitives, live session options, frame metadata, and session-result summaries in focused files.
- UI automation keeps service initialization, element/click delegation, typing, pointer/keyboard operations, focus/wait lookup, and search-policy limits in focused files.
- Space management keeps managed-display Space mapping helpers in a focused companion file.
- Legacy capture keeps window capture and screen/area capture paths in focused operator companions.
- Observation label placement keeps validation, scoring, debug rendering, and text-detection protocol glue in focused companions.
- Window management keeps construction, state operations, geometry operations, listing, target resolution, title search, and close-presence polling in focused files.
- Dialog service keeps construction/errors, public operations, button action resolution, element extraction, target resolution, classification, and file-dialog flows in focused files.
- Process command models keep enum cases, interaction parameters, system parameters, and output DTOs in focused files.
- Observation-backed CLI/MCP structured timings and diagnostics.
- `peekaboo image --json` includes per-file observation diagnostics with timing spans, state snapshot summaries, warnings, and resolved target metadata.
- Observation target selection for remaining CLI app-window filtering in `image`, live `capture`, and `window list`.
- Observation-backed menu-bar strip capture for CLI `image --app menubar` and MCP `image`.
- Observation-backed menu-bar popover window-list resolution and capture.
- MCP `see` uses observation-produced annotated screenshots and no longer carries its own annotation renderer.
- Observation-backed CLI `see` registers raw screenshots and detection results through observation output.
- CLI `see --annotate` uses observation output and the shared observation annotation renderer for observation-backed captures.
- Observation output reports artifact subspans for raw screenshot writes, annotation rendering, and snapshot registration.
- Desktop observation now has first-class OCR results, a `detection.ocr` timing span, OCR-only detection for `preferOCR`, and shared OCR-to-element mapping used by menu-bar helpers.
- Desktop observation now reports a total `desktop.observe` timing span after component capture, detection, OCR, and output spans.
- `peekaboo see --app menubar` now routes through the shared observation `.menubar` target while keeping tiny strip annotations disabled.
- ScreenCaptureKit area captures now use the single-shot frame source because fast-stream display sessions returned full-display frames for area source rectangles.
- `peekaboo see --mode area` now fails during command binding/target selection instead of silently entering the legacy capture bridge; area capture remains an `image`/service-level feature until `see` exposes rectangle inputs.
- CLI `see` no longer carries legacy window/frontmost capture fallback code; observation-backed targets now own those paths, and the remaining fallback handles only all-screen/multi capture plus menu-bar popover recovery.
- Commander binding now wires `see --capture-engine`, `image --capture-engine`, and `see --timeout-seconds` into the command structs that build observation requests.
- CLI `image --mode area --region x,y,width,height` now routes explicit desktop-region capture through observation-backed area targets.
- CLI `image --help` now advertises the full observation-backed mode set, including `multi` and `area`.
- CLI `capture live --region x,y,width,height` now infers area mode, `--mode area` is canonical, `region` remains an alias, and invalid mode/region inputs fail before capture starts.
- CLI `capture live|video --diff-strategy` now rejects unsupported values before capture starts instead of silently using `fast`.
- MCP `capture` now uses the same strict mode/region parsing, advertises PID targeting, and rejects invalid source/focus/diff inputs before capture starts.
- CLI `see --menubar` now tries observation-backed already-open popover capture and OCR before falling back to the legacy click-to-open flow.
- Popover-specific OCR selection now lives in observation via shared candidate-window, preferred-area, and AX-menu-frame matching helpers.
- Menu-bar popover click-to-open capture now lives behind the typed observation target option `openIfNeeded`.
- Menu-bar strip and popover observation diagnostics now share typed target-resolution metadata for source, bounds, hints, window IDs, and click-open fallbacks.
- `peekaboo menubar list` and `peekaboo list menubar` now share the same JSON payload and text list formatting.
- CLI `see` all-screens capture now uses the shared screen inventory instead of command-local ScreenCaptureKit display enumeration.
- `peekaboo image` builds desktop observation requests through a dedicated command-support adapter.
- `peekaboo see` builds desktop observation requests through a dedicated command-support adapter.
- `peekaboo see --mode screen --screen-index <n>` and screen analysis captures now route through desktop observation; all-screen capture remains on the legacy multi-file path until observation grows multi-artifact output.
- `peekaboo see --json` now reports an annotated screenshot path only when an annotated file actually exists.
- `peekaboo see` support types, output rendering, and screen helpers are split out of the primary command file.
- `peekaboo see` legacy capture/detection fallback now lives in a dedicated detection-pipeline adapter, putting the main command shell under the target size.
- `peekaboo image` capture orchestration, output models, analysis rendering, filename planning, and focus helpers are split out of the primary command file.
- `peekaboo app` launch, quit, and relaunch implementations now live in focused support files, leaving `AppCommand.swift` under the target size.
- `peekaboo menu` list output filtering, typed JSON conversion, and text rendering now share one command-support helper.
- `peekaboo menu` subcommands now share one error-output mapper for JSON error codes and stderr rendering.
- `peekaboo menu` click, click-extra, and list implementations now live in focused extension files, leaving `MenuCommand.swift` as registration and shared types.
- `peekaboo dialog` click, input, file, dismiss, and list implementations now live in focused extension files, leaving `DialogCommand.swift` as registration, bindings, and shared error handling.
- `peekaboo space` list, switch, and move-window implementations now live in focused extension files, leaving `SpaceCommand.swift` as registration, service wiring, and shared response types.
- `peekaboo dock` launch, right-click, visibility, and list implementations now live in focused extension files, leaving `DockCommand.swift` as registration, bindings, and shared error handling.
- `peekaboo daemon` start, stop, status, and run implementations now live in focused extension files, leaving `DaemonCommand.swift` as registration and shared daemon status support.
- `peekaboo click`, `type`, `move`, `scroll`, `drag`, `swipe`, `hotkey`, and `press` now use a shared interaction observation context for explicit/latest snapshot selection and focus snapshot policy.
- Element-targeted interaction commands now share one stale-snapshot refresh helper instead of maintaining command-local refresh loops.
- `peekaboo click`, `type`, `scroll`, `drag`, and `swipe` now centrally invalidate implicitly reused latest snapshots after successful UI mutations.
- Element-targeted actions now receive stale-window diagnostics when a snapshot window disappears or changes size.
- Element-targeted move, drag, swipe, click output, and scroll targeting now share the core moved-window point adjustment.
- Disk and in-memory snapshot stores now preserve typed detection window context so observation-backed snapshots keep bundle ID, PID, window ID, and bounds.
- App launch/switch, window mutation, hotkey, press, and paste commands now invalidate the implicit latest snapshot after UI changes.
- `peekaboo click --on/--id`, `click <query>`, `move --on/--id`, `move --to <query>`, `scroll --on`, `drag --from/--to`, and `swipe --from/--to` now refresh the implicit observation snapshot once when cached element targets are missing.
- `peekaboo scroll --smooth --json` now reports the actual smooth scroll tick count used by the automation service.
- `peekaboo scroll --on --json` now reports the same moved-window-adjusted target point used by the automation service.
- `peekaboo window focus --snapshot` now focuses the captured window context while preserving explicit snapshots during focus-cache invalidation.
- Element-targeted `click`, `move`, `scroll`, `drag`, and `swipe` JSON results now report target-point diagnostics with original snapshot point, resolved point, snapshot ID, and moved-window adjustment.
- `ElementDetectionService` now owns only detection/result building; snapshot persistence moved up to orchestration.
- Exact CoreGraphics window-ID metadata lookup now lives in `WindowCGInfoLookup`, keeping `WindowManagementService` focused on window operations and fallback orchestration.
- Shared `peekaboo window` target, display-name, action-result, and snapshot-invalidation helpers now live in `WindowCommand+Support`, leaving the primary command file focused on subcommand wiring.
- Watch capture frame diffing now lives in `WatchFrameDiffer`, keeping luma scaling, bounding-box extraction, and SSIM away from session orchestration.
- Watch capture artifact writing now lives in `WatchCaptureArtifactWriter`, keeping PNG encoding, contact sheets, resizing, and change highlighting away from session orchestration.
- Watch capture session filesystem duties now live in `WatchCaptureSessionStore`, keeping output directory setup, managed autoclean, and metadata JSON writing out of session orchestration.
- Watch capture region validation now lives in `WatchCaptureRegionValidator`, keeping visible-screen clamping and region warnings out of session orchestration.
- Watch capture result assembly now lives in `WatchCaptureResultBuilder`, keeping stats, options snapshots, no-motion warnings, and result metadata out of session orchestration.
- Watch capture frame acquisition now lives in `WatchCaptureFrameProvider`, keeping live/video source selection, region-target capture, and resolution capping out of session orchestration.
- Watch capture active/idle hysteresis now lives in `WatchCaptureActivityPolicy`; the unused private motion-interval accumulator was removed from session state.
- Window operation orchestration now stays in `WindowManagementService`; target resolution, title search, and close-presence polling moved into dedicated service extension files.
- `peekaboo window` response models and Commander binding/conformance wiring now live in `WindowCommand+Bindings`, leaving the primary command file closer to behavior-only subcommands.
- `peekaboo window close`, `minimize`, and `maximize` implementations now live in `WindowCommand+State`.
- `peekaboo window move`, `resize`, and `set-bounds` implementations now live in `WindowCommand+Geometry`.
- `peekaboo window focus` and `list` implementations now live in `WindowCommand+Focus` and `WindowCommand+List`, leaving `WindowCommand.swift` as the command shell.
- Interaction snapshot invalidation now lives in `InteractionObservationInvalidator`, leaving `InteractionObservationContext` focused on snapshot selection and refresh.
- Observation label placement geometry and candidate generation now live in `ObservationLabelPlacementGeometry`, leaving `ObservationLabelPlacer` focused on scoring/orchestration.
- Desktop observation target diagnostics and trace timing now live in focused helpers, leaving `DesktopObservationService` focused on the observe pipeline.
- `peekaboo move` result and movement-resolution types now live in `MoveCommand+Types`.
- `peekaboo move` Commander wiring and cursor movement parameter policy now live in focused support files.
- Drag destination-app/Dock AX lookup now lives in a focused CLI helper, `swipe` no longer carries stale platform imports, and `move --center` uses the shared screen service instead of command-local AppKit.
- `image --app` auto focus now skips forced activation when a renderable target window already exists, fixing SwiftPM GUI captures that timed out while activation never completed.
- Observation app-target resolution now fails with a typed window-not-found error when known windows exist but none are renderable/shareable, instead of falling back to generic app capture.
- MCP `image` and `see` now share one observation target parser, including screen, frontmost, menubar, PID/window-index, app/window-index, and app/window-title targets; MCP `image` also maps `scale: native` and `retina: true` to native capture scale.
- `peekaboo type` text escape processing and result DTOs now live in focused support files.
- Drag/swipe element-or-coordinate point resolution now uses `InteractionTargetPointResolver.elementOrCoordinateResolution`, and gesture result DTOs live in focused type files.
- `peekaboo click` validation/helpers and Commander wiring now live in focused support files.
- `peekaboo click` coordinate focus verification now uses the application service boundary instead of command-local `NSWorkspace` frontmost-app reads.
- `peekaboo app switch --to` activation and `--cycle` input now use shared service boundaries instead of command-local `NSWorkspace`/`CGEvent` calls.
- `peekaboo menu click/list` frontmost-app fallback now uses the application service boundary instead of command-local `NSWorkspace` reads.
- Command utility, menubar, open, and space command files no longer carry stale `AppKit` imports when only Foundation/CoreGraphics APIs are used.
- The menu-bar popover detector helper no longer depends on `AppKit` for CoreGraphics-only window metadata filtering.
- Smart capture now receives frontmost-app and screen-bounds state through shared application and screen service boundaries instead of direct `AppKit` calls.
- Smart capture image decoding, thumbnail resizing, and perceptual hashing now live in a focused image processor helper.
- Smart capture region screenshots now clamp to the display containing the action target instead of always using the primary display.
- Observation target menu-bar resolution and window-selection scoring now live in focused resolver extension files.
- Desktop observation target, request, and result DTOs now live in focused model files.
- `DesktopObservationService` now keeps `observe` as orchestration, with capture, detection/OCR, and output-writing plumbing in focused extension files.
- MCP `see` request, output, and summary support now live in a companion file, leaving the primary tool under the size target.
- `DragDestinationResolver` now resolves app and Trash destinations through application, window, and Dock services instead of direct CLI AX/AppKit access.
- MCP `see` annotation output now depends on `ObservationOutputWriter` instead of a tool-local AppKit renderer.
- MCP `image` saved-file output now comes from `ObservationOutputWriter` instead of tool-local image encoding/writes.
- CLI and MCP image output paths now share directory-aware planning, so `--path .`, trailing-slash paths, and existing directories receive generated filenames instead of hidden `..png` artifacts.
- CLI `image`, CLI `see`, and MCP target parsing now agree for explicit PID targets, including the documented `PID:<pid>` app identifier form; `image` also enforces title-over-index window selection before building its observation request.
- `capture live --window-title/--window-index` now resolves explicit selections to stable window IDs and the watch frame provider captures those IDs directly instead of letting app-window ordering pick a different surface.
- MCP `capture window_title/window_index` now uses the same stable-window-ID watch target shape instead of accepting `window_title` as a dead argument.
- CLI/MCP interaction target parsing now follows the observation convention that title beats index when both window selectors are present.
- Window management commands now route their mutation target through the same resolved target used for listing/refetching, including PID targets and title-over-index selection.
- `capture live` auto-mode resolution now treats `--window-index` as a window selector, matching app/PID/title selectors and MCP capture behavior.
- CLI `see` output paths now use the same directory-aware planning for primary screenshots and legacy multi-screen companion files.
- `capture live`, `capture video`, and MCP `capture` now share small path resolvers for home-directory expansion on output directories, video input paths, and video output paths.
- Clipboard and paste file IO now share a small `ClipboardPathResolver`, so CLI and MCP surfaces expand home-directory paths consistently before reading or writing files.
- `run` script/output paths and agent audio-file inputs now route through the shared path resolver before file IO.
- Script-level screenshot and clipboard file IO now route through shared path resolvers during process execution.
- AI image-file reads now use Cocoa home-directory expansion instead of replacing every literal `~` in the path.
- Shared file-service image writes now expand home-directory paths before creating output directories.
- CLI command utilities now keep error handling, output formatting, service bridge wrappers, cursor movement policy, and menu-bar list output in focused files instead of one shared grab-bag.
- `peekaboo agent` command orchestration now keeps terminal/chat rendering, session resume/listing, execution output, and model parsing in focused extension files.
- `AgentOutputDelegate` now keeps event handling separate from tool/result formatting helpers.
- Core configuration management now keeps loading/migration, JSONC/env parsing, credentials, typed accessors, persistence/default templates, and custom-provider HTTP checks in focused files.
- Bridge client request adapters now keep status, capture, interaction, window/app, menu/dock/dialog, snapshot, and socket transport responsibilities in focused files.
- Bridge protocol models now keep version/error metadata, operation policy, payload DTOs, and request/response envelopes in focused files.
- Dialog service cleanup removed stale duplicate file-dialog navigation, filename, save-verification, and key-mapping helpers from the main implementation file; the active file-dialog path stays in `DialogService+FileDialogs`.
- File-dialog handling now keeps orchestration, navigation/focus, filename entry, and save verification in focused service files.
- Dialog service internals now keep active-dialog resolution, dialog classification, and element extraction/typing helpers in focused service files.
- Dialog resolution now keeps application lookup, file-dialog recursion, visibility assists, and CoreGraphics window fallback in focused companions.
- Dock service internals now keep item listing/search, actions, visibility defaults commands, and AX lookup support in focused service files; Dock removal no longer pays an unused `defaults read` before running AppleScript.
- Hotkey service internals now keep key aliasing, chord validation, key-code lookup, and planner test hooks in a focused companion file.
- Script process execution now keeps capture commands, interaction commands, system commands, and generic parameter parsing in focused service files.
- Script process execution now keeps window and clipboard commands in focused companions, leaving system commands to app/menu/dock routing.
- MCP capture tooling now keeps argument normalization, request construction, path expansion, window resolution, and metadata output in focused companions.
- MCP dialog tooling now keeps input parsing and response formatting in focused companions while the primary tool owns service dispatch.
- MCP app tooling now keeps lifecycle, focus/switch, listing, and response formatting in focused companions while the primary action file owns dispatch.
- MCP drag tooling now keeps request parsing, point resolution, focus handling, and response formatting in focused companions while `DragTool` owns orchestration.
- MCP observation snapshots now live in a shared snapshot store file instead of being hidden inside `SeeTool`.
- Application service internals now keep app discovery, lifecycle/Spotlight launch lookup, and window enumeration in focused service files.
- UI automation orchestration now keeps delegated detection/click/typing/scroll/hotkey/gesture operations, focus/wait lookup, and search-policy limits in focused companion files; the primary file keeps initialization only.
- Visualizer coordination now keeps public animation entry points, input/display overlays, and system/display overlays in focused companion files instead of one large coordinator.
- Snapshot management now keeps storage paths, latest-snapshot lookup, element conversion, and cleanup helpers in `SnapshotManager+Helpers`.
- Agent service orchestration now keeps execution loops, stream delta processing, session lifecycle wrappers, toolset assembly, and MCP-to-agent tool adaptation in focused companion files; tool-call argument previews now have tested sensitive-value redaction.
- Bridge server request handling now keeps operation handlers and handshake/permission advertisement policy in focused companion files.
- CLI `image` and `see` now share capture-engine preference parsing and output-path resolution through observation command support instead of maintaining command-local variants.
- Command runtime daemon/remote selection now lives in focused socket, launch, capability, input-policy, service-factory, and host-resolver helpers instead of the primary runtime shell.
- Bridge server request handling now keeps service-domain handlers in a focused companion file, leaving the primary handler file as routing plus core/capture/automation/window operations.
- Remote service adapters now live in focused files instead of one aggregate service-provider implementation.
- `PeekabooServices` now keeps agent refresh/model selection and high-level automation helpers in focused companion files.
- `WindowToolFormatter` now keeps base dispatch, window/screen result rendering, and Spaces result rendering in focused files.
- Agent tool formatting now routes Dock, shell/wait, and clipboard tools through dedicated formatters, with menu/dialog rendering split into focused companion files.
- `UIAutomationToolFormatter` now keeps pointer and keyboard result rendering in focused companion files, and `move`/`drag`/`swipe` summaries use current pointer metadata instead of blank base summaries.
- `SpaceUtilities` now keeps private CGS API declarations, managed-display mapping, and public Space models/errors in focused files.
- Agent tool creation now keeps MCP schema conversion and ToolResponse bridging in focused helper files.
- UI automation protocol definitions now keep mouse profile, element-detection, and operation DTOs in focused model files.
- `TypeService` now keeps target resolution, typing cadence, and special-key synthesis in focused helper files; special-key synthesis now honors the documented `SpecialKey` raw values for keypad Enter, forward delete, caps lock, clear, and help.
- Gesture service internals now keep path generation and humanized mouse-movement synthesis in a focused companion while swipe/drag/move orchestration stays in the primary service.
- Snapshot management now keeps screenshot persistence, element lookup, and the JSON storage actor in focused support files while the primary manager owns lifecycle, listing, cleanup, and detection-result conversion.
- `peekaboo image` capture orchestration now keeps saved-file/path planning and app-focus policy in focused command-support files.
- `peekaboo capture live` now keeps scope resolution, option normalization, output rendering, focus policy, and Commander binding in focused command-support files.
- `peekaboo capture live` now applies the resolution cap consistently to live frames whose source images lack reusable color-space metadata.
- `peekaboo see --mode screen --json` now suppresses human screen-summary lines so stdout remains a single JSON document.
- Exact PID/window observations skip broad application inventory when WindowServer supplies a matching owner and live process-generation receipt; capture metadata then hydrates the bundle identity, while generationless hosts retain the read-only inventory fallback.
- Screen capture operations now keep ScreenCaptureKit permission probing inside the same serialized transaction as capture work; `peekaboo capture live` now honors `--capture-engine`, and live area capture defaults to the native `screencapture -R` path so it stays fast during concurrent `see` commands.
- Legacy window capture now tries the private ScreenCaptureKit window-ID lookup behind `screencapture -l <windowID>` before falling back to the system `screencapture` binary and public ScreenCaptureKit enumeration.
- Legacy window capture fallbacks now live in focused private-ScreenCaptureKit and system-screencapture operator companions; `LegacyScreenCaptureOperator+Support.swift` is back to shared scale/display/configuration helpers.
- Private ScreenCaptureKit window-ID lookup can be disabled globally at compile time with `PEEKABOO_DISABLE_PRIVATE_SCK_WINDOW_LOOKUP`, or per run with `PEEKABOO_DISABLE_PRIVATE_SCK_WINDOW_LOOKUP=1` / `PEEKABOO_USE_PRIVATE_SCK_WINDOW_LOOKUP=false`; disabled, quarantined, contended, or failed private lookup continues through the bounded system `screencapture` fallback. The legacy attempt never re-enters public ScreenCaptureKit after that isolated fallback fails.
- `InMemorySnapshotManager` now keeps lifecycle, screenshot access, pruning, and detection mapping in focused helper files; writes now enforce the LRU cap immediately and artifact cleanup also applies to pruned entries.
- Agent desktop context gathering now reads focused application/window state, cursor position, and recent apps through application/window/automation service boundaries instead of direct `NSWorkspace`/CoreGraphics event/window scans.
- MCP app cycling and move-center resolution now use injected automation/screen services instead of direct AXorcist/AppKit calls.
- Agent runtime visualizer bounds resolution now uses screen-service snapshots, and action verification PNG encoding uses ImageIO; `PeekabooAgentRuntime` no longer imports AppKit directly.
- CLI app quit/relaunch now use application-service lookup, termination, and running-state polling; command code no longer scans `NSWorkspace.runningApplications` for those paths.
- CLI visualizer smoke geometry now uses the injected screen service instead of `NSScreen.main`.
- Application service protocol models now avoid importing AppKit; platform activation policy is carried as a service enum.
- Scripted swipe default endpoints now use the injected screen service instead of `NSScreen.main`.
- Window list mapping now avoids AppKit for CoreGraphics and ScreenCaptureKit-only metadata caching.
- CLI move/scroll result telemetry now reads the current cursor position through the automation service boundary instead of direct CoreGraphics event calls.
- Menu extra handling now keeps public orchestration, open-menu state probing, WindowServer enumeration, AX fallback enumeration, and title cleanup in focused service files.
- `peekaboo config` custom-provider add/list/test/remove/model commands are split into focused provider files.
- MCP `WindowTool` action handlers now live in a focused companion file, and target validation uses the tool's normal argument-error path.
- MCP `AppTool` action handlers now live in a focused companion file, leaving the primary tool file as request parsing and dispatch.
- MCP `SpaceTool` action handlers now live in a focused companion file, leaving the primary tool file as schema, request parsing, and dispatch.
- MCP `DialogTool` input parsing and response formatting now live in focused companion files, leaving the primary tool to own schema, targeting, and service dispatch.
- `peekaboo list screens` implementation and screen payload models are split out of the primary list command file.
- `peekaboo list apps` and `peekaboo list windows` implementations are split out of the primary list command shell.
- `peekaboo clipboard` Commander binding and output DTOs are split from clipboard action logic.
- `peekaboo bridge status` diagnostics and report DTOs are split from the command UI shell.
- Commander runtime help rendering and theming are split from command resolution and alias routing.
- `peekaboo capture live` orchestration and `capture watch` alias wiring are split from the root capture command shell.
- `peekaboo capture video` is split out of the primary capture command file.
- `peekaboo agent permission` status and request flows are split into focused companion files.
- `peekaboo agent permission ...` now resolves as nested permission subcommands before the agent free-form task argument.
- Interactive `peekaboo agent --chat` TUI code now keeps chat shell, input/loader components, and event translation in focused files.

Current status:

- Capture-service cleanup is mostly complete; `ScreenCaptureService.swift` is under the 500-line target and frontmost-app lookup is behind `ScreenCaptureApplicationResolver`.
- CLI sources no longer import `AXorcist` or `ScreenCaptureKit`; remaining AppKit use is app-management, visualizer demo state, screen inventory, or command helper behavior outside the capture pipeline.
- Observation resolver extensions no longer own broad CoreGraphics window-list scans. Menu-bar and exact-window metadata lookup now route through focused catalog helpers.
- Optional module extraction after boundaries are stable.

Current size pressure:

```text
ScreenCaptureService.swift: 213 lines
ScreenCaptureService+Captures.swift: 210 lines
ScreenCaptureService+Operations.swift: 92 lines
ScreenCaptureService+Support.swift: 19 lines
ScreenCaptureScaleResolver.swift: 115 lines
ScreenCaptureEngineSupport.swift: 207 lines
ScreenCaptureApplicationResolver.swift: 75 lines
ScreenCaptureKitCaptureGate.swift: 195 lines
ScreenCaptureKitOperator.swift: 73 lines
ScreenCaptureKitOperator+Display.swift: 113 lines
ScreenCaptureKitOperator+Window.swift: 296 lines
ScreenCaptureKitOperator+Support.swift: 67 lines
LegacyScreenCaptureOperator.swift: 11 lines
LegacyScreenCaptureOperator+Window.swift: 279 lines
LegacyScreenCaptureOperator+ScreenArea.swift: 129 lines
LegacyScreenCaptureOperator+Support.swift: 226 lines
WatchCaptureSession.swift: 166 lines
WatchCaptureSession+Loop.swift: 253 lines
WatchCaptureSession+Saving.swift: 90 lines
WatchCaptureArtifactWriter.swift: 150 lines
WatchFrameDiffer.swift: 250 lines
WatchCaptureSessionStore.swift: 49 lines
WatchCaptureRegionValidator.swift: 31 lines
WatchCaptureResultBuilder.swift: 96 lines
WatchCaptureFrameProvider.swift: 97 lines
WatchCaptureActivityPolicy.swift: 18 lines
WindowManagementService.swift: 65 lines
WindowManagementService+StateOperations.swift: 190 lines
WindowManagementService+GeometryOperations.swift: 69 lines
WindowManagementService+Listing.swift: 41 lines
WindowManagementService+Resolution.swift: 197 lines
WindowManagementService+Search.swift: 158 lines
WindowManagementService+Presence.swift: 57 lines
WindowCGInfoLookup.swift: 91 lines
DesktopObservationService.swift: 97 lines
DesktopObservationService+Capture.swift: 142 lines
DesktopObservationService+Detection.swift: 176 lines
DesktopObservationService+Output.swift: 20 lines
DesktopObservationModels.swift: 15 lines
DesktopObservationTargetModels.swift: 191 lines
DesktopObservationRequestModels.swift: 120 lines
DesktopObservationResultModels.swift: 120 lines
DesktopObservationDiagnosticsBuilder.swift: 97 lines
DesktopObservationTraceRecorder.swift: 33 lines
ElementDetectionService.swift: 199 lines
ObservationTargetResolver.swift: 168 lines
ObservationTargetResolver+MenuBar.swift: 131 lines
ObservationTargetResolver+WindowSelection.swift: 119 lines
ObservationWindowMetadataCatalog.swift: 87 lines
ObservationLabelPlacer.swift: 258 lines
ObservationLabelPlacer+Filtering.swift: 73 lines
ObservationLabelPlacer+Scoring.swift: 61 lines
ObservationLabelPlacer+Debug.swift: 33 lines
ObservationLabelPlacementTextDetecting.swift: 9 lines
ObservationLabelPlacementGeometry.swift: 174 lines
WindowCommand.swift: 66 lines
WindowCommand+Bindings.swift: 187 lines
WindowCommand+Focus.swift: 253 lines
WindowCommand+Geometry.swift: 328 lines
WindowCommand+List.swift: 149 lines
WindowCommand+Support.swift: 189 lines
WindowCommand+State.swift: 250 lines
SeeCommand.swift: 308 lines
SeeCommand+CapturePipeline.swift: 221 lines
SeeCommand+DetectionPipeline.swift: 160 lines
SeeCommand+Output.swift: 204 lines
SeeCommand+Types.swift: 204 lines
SeeCommand+Screens.swift: 146 lines
SeeCommand+ObservationRequest.swift: 140 lines
PermissionCommand.swift: 32 lines
PermissionCommand+Status.swift: 120 lines
PermissionCommand+Requests.swift: 353 lines
ListCommand.swift: 211 lines
ListCommand+Apps.swift: 81 lines
ListCommand+Windows.swift: 187 lines
ListCommand+Screens.swift: 173 lines
ClipboardCommand.swift: 394 lines
ClipboardCommand+Commander.swift: 43 lines
ClipboardCommand+Types.swift: 17 lines
BridgeCommand.swift: 140 lines
BridgeCommand+Diagnostics.swift: 115 lines
BridgeCommand+Models.swift: 193 lines
CaptureCommand.swift: 20 lines
CaptureCommand+Live.swift: 378 lines
CaptureCommand+Video.swift: 207 lines
CaptureCommand+WatchAlias.swift: 28 lines
CaptureCommand+CommanderMetadata.swift: 87 lines
Capture.swift: 67 lines
CaptureSessionOptions.swift: 90 lines
CaptureFrameModels.swift: 138 lines
CaptureSessionResult.swift: 165 lines
ConfigurationManager.swift: 140 lines
ConfigurationManager+Parsing.swift: 220 lines
ConfigurationManager+Credentials.swift: 98 lines
ConfigurationManager+Accessors.swift: 202 lines
ConfigurationManager+Persistence.swift: 74 lines
ConfigurationManager+CustomProviders.swift: 249 lines
PeekabooBridgeClient.swift: 85 lines
PeekabooBridgeClient+Status.swift: 53 lines
PeekabooBridgeClient+Capture.swift: 101 lines
PeekabooBridgeClient+Interaction.swift: 101 lines
PeekabooBridgeClient+WindowsApplications.swift: 157 lines
PeekabooBridgeClient+MenusDockDialogs.swift: 228 lines
PeekabooBridgeClient+Snapshots.swift: 91 lines
PeekabooBridgeClient+Transport.swift: 162 lines
PeekabooBridgeModels.swift: 254 lines
PeekabooBridgeOperation+Policy.swift: 121 lines
PeekabooBridgePayloads.swift: 332 lines
PeekabooBridgeRequestResponse.swift: 192 lines
CaptureTool.swift: 122 lines
CaptureTool+Arguments.swift: 91 lines
CaptureTool+Request.swift: 231 lines
CaptureTool+Paths.swift: 19 lines
CaptureTool+Meta.swift: 20 lines
CaptureTool+WindowResolution.swift: 91 lines
DialogTool.swift: 236 lines
DialogTool+Inputs.swift: 127 lines
DialogTool+Formatting.swift: 83 lines
AppTool.swift: 105 lines
AppTool+Actions.swift: 408 lines
DialogService.swift: 78 lines
DialogService+Operations.swift: 215 lines
DialogService+ButtonActions.swift: 155 lines
DialogService+Elements.swift: 224 lines
DialogService+Resolution.swift: 218 lines
DialogService+ApplicationLookup.swift: 22 lines
DialogService+FileDialogResolution.swift: 40 lines
DialogService+Visibility.swift: 115 lines
DialogService+CGWindowResolution.swift: 45 lines
DialogService+Classification.swift: 96 lines
DialogService+FileDialogs.swift: 177 lines
DialogService+FileDialogVerification.swift: 302 lines
DialogService+FileDialogNavigation.swift: 224 lines
DialogService+FileDialogFilename.swift: 94 lines
ProcessService.swift: 224 lines
ProcessService+CaptureCommands.swift: 119 lines
ProcessService+InteractionCommands.swift: 287 lines
ProcessService+SystemCommands.swift: 129 lines
ProcessService+WindowCommands.swift: 138 lines
ProcessService+ClipboardCommands.swift: 127 lines
ProcessService+ParameterParsing.swift: 197 lines
ProcessCommandTypes.swift: 59 lines
ProcessCommandInteractionParameters.swift: 161 lines
ProcessCommandSystemParameters.swift: 147 lines
ProcessCommandOutputTypes.swift: 71 lines
ApplicationService.swift: 72 lines
ApplicationService+Discovery.swift: 246 lines
ApplicationService+Lifecycle.swift: 385 lines
ApplicationService+WindowListing.swift: 197 lines
ApplicationWindowEnumerationContext.swift: 278 lines
ApplicationServiceWindowsWorkaround.swift: 198 lines
UIAutomationService.swift: 139 lines
UIAutomationService+Operations.swift: 175 lines
UIAutomationService+TypingOperations.swift: 135 lines
UIAutomationService+PointerKeyboardOperations.swift: 122 lines
UIAutomationService+ElementLookup.swift: 307 lines
UIAutomationSearchPolicy.swift: 21 lines
VisualizerCoordinator.swift: 204 lines
VisualizerCoordinator+AnimationAPI.swift: 200 lines
VisualizerCoordinator+InputDisplays.swift: 286 lines
VisualizerCoordinator+SystemDisplays.swift: 277 lines
SnapshotManager.swift: 394 lines
SnapshotManager+Helpers.swift: 264 lines
PeekabooAgentService.swift: 336 lines
PeekabooAgentService+Execution.swift: 219 lines
PeekabooAgentService+SessionLifecycle.swift: 140 lines
PeekabooAgentService+Toolset.swift: 198 lines
PeekabooBridgeServer.swift: 202 lines
PeekabooBridgeServer+Handlers.swift: 241 lines
PeekabooBridgeServer+Handshake.swift: 157 lines
PeekabooBridgeServer+ServiceHandlers.swift: 232 lines
RemotePeekabooServices.swift: 94 lines
RemoteScreenCaptureService.swift: 69 lines
RemoteUIAutomationService.swift: 185 lines
RemoteWindowManagementService.swift: 52 lines
RemoteMenuService.swift: 60 lines
RemoteDockService.swift: 52 lines
RemoteDialogService.swift: 65 lines
RemoteSnapshotManager.swift: 91 lines
RemoteApplicationService.swift: 79 lines
PeekabooServices.swift: 404 lines
PeekabooServices+Agent.swift: 138 lines
PeekabooServices+Automation.swift: 136 lines
WindowToolFormatter.swift: 128 lines
WindowToolFormatter+WindowResults.swift: 379 lines
WindowToolFormatter+SpaceResults.swift: 129 lines
SpaceUtilities.swift: 372 lines
SpaceManagementService+DisplayMapping.swift: 73 lines
SpaceCGSPrivateAPI.swift: 121 lines
SpaceModels.swift: 68 lines
SpaceTool.swift: 196 lines
SpaceTool+Handlers.swift: 260 lines
PeekabooAgentService+Tools.swift: 267 lines
PeekabooAgentService+ToolSchema.swift: 92 lines
AgentToolMCPBridge.swift: 93 lines
ObservationOutputPathResolver.swift: 56 lines
UIAutomationServiceProtocol.swift: 155 lines
MouseMovementProfile.swift: 67 lines
ElementDetectionModels.swift: 205 lines
UIAutomationOperationModels.swift: 188 lines
TypeService.swift: 181 lines
TypeService+TargetResolution.swift: 118 lines
TypeService+TypingCadence.swift: 163 lines
TypeService+SpecialKeys.swift: 90 lines
InMemorySnapshotManager.swift: 61 lines
InMemorySnapshotManager+Lifecycle.swift: 120 lines
InMemorySnapshotManager+Screenshots.swift: 85 lines
InMemorySnapshotManager+Pruning.swift: 43 lines
InMemorySnapshotManager+DetectionMapping.swift: 216 lines
MenuService+Extras.swift: 296 lines
MenuService+MenuExtraState.swift: 256 lines
MenuService+MenuExtraWindows.swift: 274 lines
MenuService+MenuExtraAccessibility.swift: 367 lines
MenuService+MenuExtraSupport.swift: 281 lines
DockService.swift: 65 lines
DockService+Actions.swift: 159 lines
DockService+Items.swift: 150 lines
DockService+Support.swift: 43 lines
DockService+Visibility.swift: 78 lines
CommanderRuntimeRouter.swift: 240 lines
CommanderRuntimeRouter+Help.swift: 192 lines
AgentChatUI.swift: 340 lines
AgentChatUI+Components.swift: 85 lines
AgentChatEventDelegate.swift: 175 lines
ImageCommand.swift: 192 lines
ImageCommand+CapturePipeline.swift: 386 lines
ImageCommand+Output.swift: 102 lines
ImageCommand+ObservationRequest.swift: 56 lines
InteractionObservationContext.swift: 284 lines
InteractionObservationInvalidator.swift: 91 lines
InteractionTargetPointResolver.swift: 227 lines
ClickCommand.swift: 312 lines
ClickCommand+CommanderMetadata.swift: 92 lines
ClickCommand+Validation.swift: 79 lines
ClickCommand+FocusVerification.swift: 148 lines
ClickCommand+Output.swift: 30 lines
TypeCommand.swift: 337 lines
TypeCommand+TextProcessing.swift: 60 lines
TypeCommand+Types.swift: 11 lines
MoveCommand.swift: 322 lines
MoveCommand+CommanderMetadata.swift: 134 lines
MoveCommand+Movement.swift: 58 lines
MoveCommand+Types.swift: 59 lines
ScrollCommand.swift: 240 lines
DragCommand.swift: 295 lines
DragCommand+Types.swift: 15 lines
DragDestinationResolver.swift: 65 lines
SwipeCommand.swift: 295 lines
SwipeCommand+Types.swift: 15 lines
HotkeyCommand.swift: 272 lines
PressCommand.swift: 231 lines
```

Current command-boundary audit:

- CLI command sources no longer import `ScreenCaptureKit`.
- `see` all-screens capture no longer enumerates `SCShareableContent` directly.
- AI/Core capture command sources no longer import `AppKit`; `see`, `image`, `list`, and menu-bar geometry now use shared screen/application services for screen inventory and app identity checks.
- `SeeCommand+MenuBarCandidates.swift` uses the shared observation menu-bar window catalog instead of command-local `CGWindowListCopyWindowInfo`.
- Menu-bar click verification uses the shared observation window catalog instead of command-local `CGWindowListCopyWindowInfo`.

Near-term rule: command code may mention `CGWindowID` as a user-facing identifier, but must not enumerate windows, displays, or ScreenCaptureKit objects directly.

## Grand Execution Plan

This is the full refactor sequence. Keep every phase shippable: one coherent behavior boundary, one changelog entry, targeted tests, then the broad gate.

### Phase 1: Freeze Semantics

Purpose: prevent CLI, MCP, and agent tools from drifting while code moves.

Deliverables:

- one table of target precedence for `screen`, `frontmost`, `app`, `pid`, `window-title`, `window-index`, `window-id`, `area`, `menubar`, and `menubarPopover`;
- parity tests proving `image` and `see` construct equivalent observation targets for equivalent flags;
- parity tests proving CLI and MCP request mapping agree;
- diagnostics fixtures for skipped helper/offscreen/minimized windows;
- docs for native Retina versus logical 1x behavior.

Exit criteria:

- behavior changes require updating tests first;
- any legacy fallback path emits typed diagnostics explaining why observation did not handle it.

### Phase 2: Observation Owns Desktop State

Purpose: make one request-scoped inventory feed resolution, capture, detection, diagnostics, and interactions.

Deliverables:

- `DesktopStateSnapshot` is the only source for target resolution inside observation;
- `ObservationTargetResolver` owns all app/window ranking and menubar target resolution;
- window/application identity structs are used in observation results, snapshot metadata, CLI JSON, and MCP metadata;
- command-level window ranking, app matching, display enumeration, and menu-bar window polling are deleted;
- request-local cache invalidation rules are encoded near the snapshot builder.

Exit criteria:

- `image --app X` and `see --app X` choose the same window from the same ranked candidates;
- `image --window-id N` and `see --window-id N` report the same identity fields;
- commands cannot enumerate windows or displays directly.

### Phase 3: Capture Becomes Plan Plus Operators

Purpose: separate policy from macOS capture calls.

Deliverables:

- `ScreenCapturePlanner` is the only place deciding engine, scale, fallback eligibility, and source rectangles;
- `ScreenCaptureService` is a facade over permission gate, planner, operators, scaler, and metadata builder;
- operators contain platform calls only: ScreenCaptureKit, legacy CG capture, and future `screencapture` fallback if adopted;
- capture metadata always includes requested scale, native scale, output scale, final pixel size, engine, fallback reason, and permission timing;
- all pure capture decisions have tests without Screen Recording permission.

Exit criteria:

- `ScreenCaptureService.swift` stays under 500 lines;
- no command imports `ScreenCaptureKit`, `AppKit`, `NSScreen`, or `NSWorkspace` for capture behavior;
- live Retina checks are recorded against `screencapture -l <windowID> -o -x` on hardware that demonstrates native 2x output.

### Phase 4: Detection Becomes Policy Plus Readers

Purpose: make AX traversal fast, cancellable, and understandable.

Deliverables:

- `ElementDetectionService` orchestrates only;
- traversal, descriptor reads, classification, result assembly, window fallback, web focus fallback, menu-bar elements, and cache state remain in dedicated collaborators;
- direct detection callers use racing timeouts and cancellation;
- sparse web fallback is triggered by explicit policy, not by incidental missing labels;
- rich native windows never pay for web-content focus fallback.

Exit criteria:

- detection cannot hang indefinitely;
- window-targeted `see` does not traverse all app windows;
- `ElementDetectionService.swift` stays under 500 lines with policy tested outside the facade.

### Phase 5: Output And Snapshot Side Effects Are Central

Purpose: make all screenshot-derived artifacts predictable.

Deliverables:

- `ObservationOutputWriter` owns raw screenshot, annotated screenshot, OCR artifact, and snapshot registration side effects;
- CLI/MCP renderers only render existing typed result fields;
- output span names are stable and covered by tests;
- annotation rendering uses one shared coordinate model.

Exit criteria:

- `see --annotate` and MCP `see` produce the same companion path policy;
- snapshot metadata always references the resolved target identity and capture bounds;
- output writing never prints directly.

### Phase 6: Interactions Consume Observation

Purpose: make `see -> click/type/scroll` fast and explainable.

Deliverables:

- `ObservationSnapshotStore` facade over the current snapshot manager;
- action commands accept fresh observation context or snapshot ID;
- missing/stale element IDs can observe-if-needed or fail with target/window diagnostics;
- click/type/scroll/drag/swipe invalidate implicitly reused latest snapshots after mutations;
- hotkey/press/focus invalidation policy is explicit once they consume fresh observation context;
- stale snapshot failures identify the previous and current window identity;
- element target points share one snapshot-window movement adjustment path;
- action results include target-point and stale-snapshot diagnostics.

Exit criteria:

- repeated `see -> click -> type` avoids avoidable AX rescans;
- stale snapshot failures identify the previous and current window identity;
- action commands do not duplicate target resolution policy.

### Phase 7: Command Surface Cleanup

Purpose: make CLI/MCP files thin adapters.

Deliverables:

- `SeeCommand.swift` below 400 lines;
- `ImageCommand.swift` below 400 lines;
- command-support adapters for observation request mapping and result rendering;
- no CLI command imports `AXorcist` unless it directly implements an action that must touch AX handles;
- no CLI command imports platform capture frameworks;
- command docs updated for diagnostics and timings.

Exit criteria:

- command files parse flags, call services, render typed results, and little else;
- each helper file has one reason to change and stays under about 500 lines.

### Phase 8: Module Extraction

Purpose: split packages after boundaries are stable.

Order:

1. `PeekabooObservation`
2. `PeekabooCapture`
3. `PeekabooElementDetection`
4. optional CLI command-support package

Exit criteria:

- extraction is mostly moving files and access modifiers;
- package boundaries do not force semantic rewrites;
- broad gate and live E2E still pass after each extraction.

## Non-Negotiable Invariants

- Equivalent targets resolve the same way in CLI and MCP.
- `image --app X` and `see --app X` choose the same app window.
- `image --window-id N` and `see --window-id N` report the same window identity.
- `--window-id` beats title, title beats index, index beats automatic selection.
- Automatic app-window selection skips helper/offscreen/minimized windows when a renderable alternative exists.
- Automatic app-window selection prefers visible titled windows, then larger renderable area, then stable CoreGraphics ordering.
- `--retina` means native display scale; non-retina capture means logical 1x only where explicitly requested.
- Capture engine forcing never silently falls back to another engine.
- Screen Recording permission is checked once per capture operation.
- `image` never instantiates or runs element detection.
- A window-targeted `see` never traverses all app windows when a direct window context is available.
- Rich native AX trees skip Chromium/Tauri web focus fallback.
- Sparse Chromium/Tauri AX trees can still trigger web focus fallback.
- Request caches may reuse expensive enumeration inside one observation call; persistent caches must not hold live windows/elements.
- Output writing can create files and snapshots, but output formatting stays in CLI/MCP layers.
- Timings are structured spans, not prose logs that tests or benchmarks scrape.

## Target Architecture

### Public Facade

```swift
@MainActor
public protocol DesktopObservationServiceProtocol {
    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult
}

@MainActor
public final class DesktopObservationService: DesktopObservationServiceProtocol {
    public func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult
}
```

`DesktopObservationService` owns:

- request-scoped desktop inventory;
- target resolution;
- capture planning;
- capture execution;
- optional element detection;
- optional OCR;
- optional annotation rendering;
- optional snapshot registration;
- structured timings;
- typed diagnostics;
- capture/detection timeout policy.

It does not own:

- Commander option declarations;
- MCP wire wording;
- CLI text or JSON rendering;
- AI provider calls that depend on Tachikoma;
- long-lived automation action orchestration.

### Request Model

```swift
public struct DesktopObservationRequest: Sendable, Equatable {
    public var target: DesktopObservationTargetRequest
    public var capture: DesktopCaptureOptions
    public var detection: DesktopDetectionOptions
    public var output: DesktopObservationOutputOptions
    public var timeout: DesktopObservationTimeouts
}
```

Target requests:

```swift
public enum DesktopObservationTargetRequest: Sendable, Equatable {
    case screen(index: Int?)
    case allScreens
    case frontmost
    case app(identifier: String, window: WindowSelection?)
    case pid(Int32, window: WindowSelection?)
    case windowID(CGWindowID)
    case area(CGRect)
    case menubar
    case menubarPopover(hints: [String])
}

public enum WindowSelection: Sendable, Equatable {
    case automatic
    case index(Int)
    case title(String)
    case id(CGWindowID)
}
```

Capture options:

```swift
public struct DesktopCaptureOptions: Sendable, Equatable {
    public var engine: CaptureEnginePreference
    public var scale: CaptureScalePreference
    public var focus: CaptureFocus
    public var visualizerMode: CaptureVisualizerMode
    public var includeMenuBar: Bool
}
```

Detection options:

```swift
public struct DesktopDetectionOptions: Sendable, Equatable {
    public var mode: DetectionMode
    public var allowWebFocusFallback: Bool
    public var includeMenuBarElements: Bool
    public var preferOCR: Bool
    public var traversalBudget: AXTraversalBudget
}

public enum DetectionMode: Sendable, Equatable {
    case none
    case accessibility
    case accessibilityAndOCR
}
```

Output options:

```swift
public struct DesktopObservationOutputOptions: Sendable, Equatable {
    public var path: String?
    public var format: ImageFormat
    public var saveRawScreenshot: Bool
    public var saveAnnotatedScreenshot: Bool
    public var saveSnapshot: Bool
    public var snapshotID: String?
}
```

Result:

```swift
public struct DesktopObservationResult: Sendable {
    public var target: ResolvedObservationTarget
    public var capture: CaptureResult
    public var elements: ElementDetectionResult?
    public var ocr: OCRResult?
    public var files: DesktopObservationFiles
    public var timings: ObservationTimings
    public var diagnostics: DesktopObservationDiagnostics
}
```

### Identity Model

Every frontend should use the same identity vocabulary.

```swift
public struct ApplicationIdentity: Sendable, Codable, Equatable, Hashable {
    public var processID: pid_t
    public var bundleIdentifier: String?
    public var name: String
    public var path: String?
}

public struct WindowIdentity: Sendable, Codable, Equatable, Hashable {
    public var windowID: CGWindowID?
    public var index: Int?
    public var ownerPID: pid_t?
    public var ownerName: String?
    public var title: String
    public var bounds: CGRect
    public var layer: Int
    public var alpha: Double
    public var isOnScreen: Bool
}
```

These identities must flow through:

- `list windows`;
- `image --app`;
- `image --window-id`;
- `see --app`;
- `see --window-id`;
- MCP `image`;
- MCP `see`;
- snapshot metadata;
- annotation metadata;
- interaction diagnostics.

### Request-Scoped Desktop State

Broad observation should build one request-scoped desktop inventory and pass it through the pipeline. An exact PID/window request may instead bind directly to matching WindowServer owner-generation metadata, then require the capture receipt to confirm and hydrate that same target; if generation evidence is unavailable, it falls back to the read-only inventory path.

```swift
public struct DesktopStateSnapshot: Sendable {
    public var capturedAt: Date
    public var displays: [DisplayIdentity]
    public var runningApplications: [ApplicationIdentity]
    public var windows: [WindowIdentity]
    public var frontmostApplication: ApplicationIdentity?
    public var frontmostWindow: WindowIdentity?
}
```

Cache tiers:

```text
request cache: always allowed, discarded after one observation
short TTL cache: allowed after benchmarks prove it helps
persistent cache: static metadata only, never live windows/elements/pixels
```

Initial TTL guidance:

```text
window inventory: 150-300 ms
frontmost app/window: no TTL unless measured safe
AX element tree: 250-500 ms, keyed by pid + windowID + focus epoch
OCR output: no cache initially
screenshot pixels: no cache
```

AX cache invalidation triggers:

- target PID or window ID changed;
- window bounds changed;
- frontmost app changed;
- click/type/scroll/drag/swipe/hotkey/press/focus executed;
- focus fallback executed;
- detection options changed;
- timeout/cancellation occurred before traversal completed.

The cache stores immutable detection outputs, not live `AXUIElement` handles.

## Internal Collaborators

### `ObservationTargetResolver`

Owns:

- app name, bundle ID, and PID lookup;
- `frontmost`;
- `windowID`;
- window title/index selection;
- largest visible fallback;
- menubar strip;
- menubar popover windows;
- offscreen/minimized/helper filtering;
- diagnostics for skipped candidates.

Migrates behavior out of:

- `ImageCommand`;
- `SeeCommand`;
- MCP `SeeTool` and `ImageTool`;
- `WindowFilterHelper`;
- command-level CoreGraphics helpers.

### `ScreenCapturePlanner`

Owns pure capture policy:

- engine choice;
- forced-engine behavior;
- fallback eligibility;
- focus policy;
- display-local source rectangle planning;
- scale source and output scale;
- expected pixel dimensions when knowable.

Planner tests must not need Screen Recording permission.

### Capture Operators

Execution types own platform calls only:

- `ScreenCaptureKitOperator`;
- `LegacyScreenCaptureOperator`;
- `ScreenCaptureFallbackRunner`;
- `ScreenCapturePermissionGate`;
- `ScreenCaptureImageScaler`;
- `CaptureImageWriter`.

Hard rule: `ScreenCaptureService` remains the public facade, but should become mostly orchestration.

### `ElementObservationService`

Thin observation adapter over detection.

Owns:

- whether detection runs;
- `WindowContext` handoff;
- detection timeout budget;
- `allowWebFocusFallback`;
- menu-bar element inclusion;
- OCR preference handoff.

It should not re-resolve app/window target identity from scratch.

### Element Detection Internals

`ElementDetectionService` remains the facade, backed by:

- `AXTreeCollector`: traversal only;
- `AXTraversalPolicy`: depth, child count, skip rules, sparse-tree thresholds;
- `AXDescriptorReader`: batched attributes and actions;
- `ElementClassifier`: role, label, type, enabled, actionable, shortcut policy;
- `WebFocusFallback`: Chromium/Tauri sparse-tree focus recovery;
- `ElementTypeAdjuster`: post-classification corrections;
- `MenuBarElementCollector`: app menu-bar elements;
- `ElementDetectionWindowResolver`: fallback AX root/window selection;
- `ElementDetectionCache`: immutable detection caches and invalidation;
- `ElementDetectionResultBuilder`: grouping, metadata, warnings, snapshot result assembly.

### `ObservationOutputWriter`

Owns file and artifact side effects:

- raw screenshot path selection;
- format conversion;
- annotated screenshot path selection;
- annotated screenshot rendering;
- OCR artifact path selection;
- snapshot ID/path registration;
- output write warnings.

It does not print.

Required span names:

```text
state.snapshot
target.resolve
capture.window
capture.frontmost
capture.screen
capture.area
detection.ax
detection.ocr
output.write
output.raw.write
snapshot.write
annotation.render
desktop.observe
```

## Refactor Tracks

### Track A: Observation Is The Product Surface

Goal: every desktop inspection frontend constructs `DesktopObservationRequest` and receives `DesktopObservationResult`.

Remaining work:

- delete command-level capture/detection bridge code once all supported targets are observation-backed.
- move remaining legacy command helpers into observation or the future interaction pipeline.

Done when:

- `see`, `image`, MCP `see`, and MCP `image` have no independent target-resolution behavior;
- command code only maps flags and renders output;
- unsupported targets fail explicitly instead of silently taking legacy paths.

### Track B: Capture Is Plan Plus Operators

Goal: `ScreenCaptureService` is a facade over pure planning plus small execution operators.

Remaining work:

- audit `ScreenCaptureService.swift` for residual policy;
- extract any remaining output-writing or target-selection policy;
- keep `screencapture -l <windowID>` as the behavioral reference for native window capture where macOS permits it;
- keep native/logical scale decisions reportable through `CaptureMetadata.diagnostics`;
- keep command imports free of ScreenCaptureKit/AppKit capture details.

Done when:

- scale, engine, fallback, and permission behavior have pure tests;
- `ScreenCaptureService.swift` is under about 500 lines;
- `ScreenCaptureService+Support.swift` is split by responsibility and no single capture helper file exceeds about 500 lines;
- watch/session capture has a dedicated follow-up plan before `WatchCaptureSession.swift` is split, because it is long-lived streaming behavior rather than single-shot observation;
- no command imports `ScreenCaptureKit`;
- `image --retina` and non-retina output can be reasoned about without live display capture.

### Track C: Element Detection Is Policy Plus Readers

Goal: `ElementDetectionService` facade contains orchestration, not a hidden mega-algorithm.

Remaining work:

- finish moving fallback thresholds into `AXTraversalPolicy`;
- audit direct detection callers for real timeout/cancellation;
- ensure rich native trees skip web focus fallback;
- ensure sparse Chromium/Tauri trees can still trigger fallback;
- isolate any remaining snapshot write behavior from detection;
- reduce service file size and tighten collaborator tests.

Done when:

- `ElementDetectionService.swift` is under about 500 lines;
- traversal policy has pure unit coverage;
- descriptor reader/classifier/result builder are independently testable;
- direct detection callers cannot hang forever.

### Track D: Interactions Reuse Observation

Goal: click/type/scroll/drag/swipe/hotkey/press reuse observation state when available and invalidate it when they mutate UI.

Future work:

- create an `ObservationSnapshotStore` facade over current snapshot manager behavior;
- extend the shared interaction observation context to focus commands and fresh observation results;
- add observe-if-needed behavior for stale or missing element IDs;
- add target-point diagnostics for click/move without a full desktop scan;
- add explicit cache invalidation after click/type/scroll/drag/swipe/hotkey/press/focus.

Done when:

- `see -> click -> type` avoids avoidable full AX traversals;
- stale element failures explain stale snapshot/window identity;
- action commands invalidate only affected observation cache entries.

### Track E: Module Extraction Last

Goal: split packages only after behavior boundaries are boring.

Order:

1. `PeekabooObservation`
2. `PeekabooCapture`
3. `PeekabooElementDetection`
4. optional CLI command-support package

Do not extract modules while command, capture, and detection code still disagree about target semantics.

## Ship Groups

Each group should be shippable. Update this section after each commit lands.

### Group 1: Finish Observation Artifacts

Purpose: make observation own screenshot-derived artifacts.

Work:

- done: render annotated screenshots in `ObservationOutputWriter`;
- done: route MCP annotated screenshots through observation first;
- done: move CLI rich annotation placement into AutomationKit through `ObservationAnnotationRenderer`;
- done: add output spans for `output.raw.write`, `annotation.render`, and `snapshot.write`;
- done: add tests for raw+annotated output files and snapshot registration.

Gate:

```bash
swift test --package-path Core/PeekabooAutomationKit --filter DesktopObservationServiceTests
swift test --package-path Core/PeekabooCore --filter MCPToolExecutionTests
swift test --package-path Apps/CLI -Xswiftc -DPEEKABOO_SKIP_AUTOMATION --filter SeeCommandAnnotationTests
pnpm run test:safe
```

Manual checks:

```bash
peekaboo see --window-id <id> --annotate --path /tmp/see.png --json-output
sips -g pixelWidth -g pixelHeight /tmp/see.png /tmp/see_annotated.png
```

### Group 2: Menubar Observation Closure

Purpose: make menubar capture/OCR/click-open behavior one observation sub-pipeline.

Work:

- done: move generic OCR timing/output and OCR-to-element conversion into observation;
- done: route already-open `see --menubar` popovers through observation OCR before legacy fallback;
- done: move popover-specific OCR selection into observation;
- done: move popover click-to-open preflight behind a typed option;
- done: ensure `.menubar` and `.menubarPopover(hints:)` share diagnostics;
- done: keep menu-extra listing behavior consistent with `list menubar`.

Gate:

```bash
swift test --package-path Core/PeekabooAutomationKit --filter DesktopObservationServiceTests
pnpm run test:safe
```

Manual checks:

```bash
peekaboo see --menubar --json-output --verbose
peekaboo see --app menubar --path /tmp/menubar.png --json-output
```

### Group 3: Capture Service Cleanup

Purpose: finish the plan/operator split and remove residual command capture policy.

Work:

- done: remove command-local ScreenCaptureKit display enumeration from `see` all-screens capture;
- done: verify CLI sources no longer import `ScreenCaptureKit`;
- done: remove capture-facing command `AppKit`, `NSScreen`, `NSWorkspace`, and `NSRunningApplication` dependencies from AI/Core command sources;
- done: split `ScreenCaptureService+Support.swift` into focused scale, engine fallback, app resolving, and ScreenCaptureKit gate helpers;
- done: add `CaptureMetadata.diagnostics` for requested scale, native scale, output scale, final pixel size, engine, and fallback reason;
- done: cover forced engine resolution and fallback diagnostics in pure tests;
- done: migrate remaining `see` menu-bar candidate `CGWindowListCopyWindowInfo` work behind the shared observation window catalog;
- done: route menu-bar click verification window polling through the shared observation window catalog;
- done: move frontmost-application capture lookup behind the shared capture application resolver;
- done: remove stale `AXorcist` and `ScreenCaptureKit` imports from CLI command files;
- done: route menu-bar popover target resolution through the shared observation window catalog;
- done: route exact `--window-id` observation metadata through `ObservationWindowMetadataCatalog`;
- keep `ScreenCaptureService.swift` under target size and split support files that exceed it.

Recommended order:

1. Done: run live `sips` checks and compare against `screencapture -l <windowID> -o -x`.
2. Done: extract observation request mapping out of large `image` and `see` command files.

Live check, May 7, 2026:

```bash
./Apps/CLI/.build/debug/peekaboo list windows --app Ghostty --json-output
./Apps/CLI/.build/debug/peekaboo image --window-id 7565 --path /tmp/peekaboo-live-no-retina.png --json-output
./Apps/CLI/.build/debug/peekaboo image --window-id 7565 --retina --path /tmp/peekaboo-live-retina.png --json-output
screencapture -l 7565 -o -x /tmp/peekaboo-live-native.png
sips -g pixelWidth -g pixelHeight /tmp/peekaboo-live-no-retina.png /tmp/peekaboo-live-retina.png /tmp/peekaboo-live-native.png
```

Result on the current host: all three files were `802x1250`, so this machine/session does not reproduce a Retina 2x delta. `image --app Ghostty` selected the real `802x1250` titled window `Peekaboo` instead of the visible `3008x30` auxiliary strip windows, matching the intended #113 app-window behavior.

Gate:

```bash
swift test --package-path Core/PeekabooCore --filter ScreenCaptureService
swift test --package-path Core/PeekabooCore --filter CaptureEngineResolverTests
pnpm run test:safe
```
```

Manual Retina check:

```bash
peekaboo see --window-id <id> --path /tmp/no-retina.png --json-output
peekaboo see --window-id <id> --retina --path /tmp/retina.png --json-output
sips -g pixelWidth -g pixelHeight /tmp/no-retina.png /tmp/retina.png
```

### Group 4: Detection Service Cleanup

Purpose: finish isolating AX traversal, fallback, and result policy.

Work:

- done: move remaining sparse-tree thresholds into `AXTraversalPolicy`;
- done: remove snapshot/file-writing behavior from `ElementDetectionService`;
- done: add cancellation tests for direct detection timeout calls;
- done: add unit tests for rich-tree versus sparse-web fallback;
- done: keep `ElementDetectionService` under target size.

Gate:

```bash
swift test --package-path Core/PeekabooAutomationKit --filter ElementDetectionServiceTests
swift test --package-path Core/PeekabooAutomationKit --filter ElementDetectionTraversalPolicyTests
pnpm run test:safe
```

### Group 5: Interaction Integration

Purpose: make action commands consume observation state and invalidate caches.

Work:

- done: define shared explicit/latest snapshot selection and focus snapshot policy in `InteractionObservationContext`;
- done: teach click/type/move/scroll/drag/swipe/hotkey/press to resolve snapshot context through the shared helper;
- done: centralize stale-snapshot refresh loops for element-targeted interaction commands;
- done: centralize post-action invalidation for implicitly reused latest snapshots after click/type/scroll/drag/swipe;
- done: define stale-window diagnostics for disappeared or resized snapshot windows;
- done: centralize moved-window target-point adjustment for click/type/move/scroll/drag/swipe element paths;
- done: preserve typed detection window context in disk and in-memory snapshot stores;
- done: invalidate implicit latest snapshots after app launch/switch, window focus/geometry, hotkey, press, and paste changes;
- done: refresh implicit observation snapshot once for `click --on/--id`, `click <query>`, `move --on/--id`, `move --to <query>`, `scroll --on`, `drag --from/--to`, and `swipe --from/--to` when cached element targets are missing;
- done: broaden observe-if-needed from element IDs to implicit latest query targets while keeping no-snapshot query actions on their direct AX path;
- done: align smooth scroll result telemetry with the automation service tick configuration;
- done: share moved-window target-point resolution with scroll result rendering;
- done: teach `window focus` to accept explicit snapshot window context;
- done: preserve explicit snapshots while invalidating implicit latest state after focus commands;
- done: add target-point diagnostics.

Gate:

```bash
swift test --package-path Apps/CLI -Xswiftc -DPEEKABOO_SKIP_AUTOMATION --filter ClickCommandTests
swift test --package-path Apps/CLI -Xswiftc -DPEEKABOO_SKIP_AUTOMATION --filter TypeCommandTests
pnpm run test:safe
```

Manual checks:

```bash
peekaboo see --app TextEdit --json-output --path /tmp/textedit.png
peekaboo click --snapshot <snapshot-id> --on <element-id> --json-output
peekaboo type "observation smoke test" --snapshot <snapshot-id> --json-output
```

### Group 6: Command and Module Cleanup

Purpose: make CLI/MCP boring and prepare package extraction.

Work:

- done: deleted obsolete bridge helper stubs and the command-local `ScreenCaptureBridge` shim;
- started: move request mapping into small command-support adapters (`ImageCommand+ObservationRequest.swift`, `SeeCommand+ObservationRequest.swift`);
- started: split large `see` support into focused files (`SeeCommand+Types.swift`, `SeeCommand+Output.swift`, `SeeCommand+Screens.swift`);
- done: move the remaining legacy capture/detection fallback body out of `SeeCommand.swift` into `SeeCommand+DetectionPipeline.swift`;
- done: split `ImageCommand.swift` request mapping, output rendering, analysis, and local fallback code until the command shell is under target size;
- done: split drag destination-app/Dock lookup out of `DragCommand.swift` and remove stale platform imports from `swipe`/`move`;
- done: route `DragDestinationResolver` through service boundaries and remove direct CLI AX/AppKit destination probing;
- done: archive stale refactor notes behind the current refactor index;
- done: update command docs for changed diagnostics/timings;
- done: split interaction target-point diagnostics out of `InteractionObservationContext.swift`;
- done: split `ClickCommand` focus verification and output models out of the command shell;
- only then consider module extraction.

Gate:

```bash
pnpm run format
pnpm run lint
pnpm run test:safe
```

Acceptance:

- `SeeCommand.swift` under about 400 lines;
- `ImageCommand.swift` under about 400 lines;
- CLI sources do not import `AXorcist` or `ScreenCaptureKit`;
- CLI and MCP share observation request mapping.

## Testing Strategy

### Pure Tests

Add or keep tests for:

- target resolver ranking;
- offscreen/minimized/helper filtering;
- largest visible window fallback;
- `windowID` precedence;
- `--retina` to native scale mapping;
- logical 1x scale planning;
- forced engine behavior;
- no fallback when engine is forced;
- detection mode selection;
- web focus fallback policy;
- output path planning;
- annotation rendering path;
- structured span emission.

### Stubbed Integration Tests

Use fake services for:

- app/window inventory;
- capture output;
- element detection;
- OCR;
- output writing.

Verify:

- `see` requests detection;
- `image` does not request detection;
- MCP `see` and CLI `see` map equivalent targets;
- MCP `image` and CLI `image` map equivalent targets;
- menubar capture sets OCR preference;
- annotation requests create annotation output;
- timeout settings flow to capture/detection.

### Live E2E

Run only when Screen Recording and Accessibility are granted.

```bash
peekaboo permissions status --json-output
peekaboo window list --app TextEdit --json-output
peekaboo see --window-id <id> --path /tmp/textedit.png --json-output
peekaboo see --window-id <id> --retina --path /tmp/textedit-retina.png --json-output
peekaboo see --window-id <id> --annotate --path /tmp/textedit-see.png --json-output --verbose
peekaboo see --app "Google Chrome" --json-output --verbose
peekaboo see --app "Peekaboo Inspector" --json-output --verbose
```

Record:

- wall time;
- `desktop.observe`;
- `target.resolve`;
- capture span;
- detection span;
- OCR/annotation spans if used;
- element count;
- interactable count;
- target window ID/title;
- screenshot dimensions.

Live verification, May 7, 2026:

```bash
./Apps/CLI/.build/debug/peekaboo permissions status --json --no-remote
./Apps/CLI/.build/debug/peekaboo list windows --app TextEdit --json --no-remote
./Apps/CLI/.build/debug/peekaboo list windows --app "Google Chrome" --json --no-remote
./Apps/CLI/.build/debug/peekaboo list windows --app PeekabooInspector --json --no-remote
./Apps/CLI/.build/debug/peekaboo image --window-id 13441 --path .artifacts/live-e2e/2026-05-07T1118Z/textedit-window.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo image --app TextEdit --path .artifacts/live-e2e/2026-05-07T1118Z/textedit-app-fixed.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo image --window-id 12438 --path .artifacts/live-e2e/2026-05-07T1118Z/chrome-window.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo image --app "Google Chrome" --path .artifacts/live-e2e/2026-05-07T1118Z/chrome-app-fixed.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo image --window-id 13665 --path .artifacts/live-e2e/2026-05-07T1118Z/inspector-window.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo image --app PeekabooInspector --path .artifacts/live-e2e/2026-05-07T1118Z/inspector-app-fixed.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo see --window-id 13441 --path .artifacts/live-e2e/2026-05-07T1118Z/textedit-see-window.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo see --app TextEdit --path .artifacts/live-e2e/2026-05-07T1118Z/textedit-see-app.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo see --window-id 12438 --path .artifacts/live-e2e/2026-05-07T1118Z/chrome-see-window.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo see --app "Google Chrome" --path .artifacts/live-e2e/2026-05-07T1118Z/chrome-see-app.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo see --window-id 13665 --path .artifacts/live-e2e/2026-05-07T1118Z/inspector-see-window.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo see --app PeekabooInspector --path .artifacts/live-e2e/2026-05-07T1118Z/inspector-see-app.png --json --no-remote
```

Results:

- permissions granted: Screen Recording, Accessibility, Event Synthesizing;
- display scale: 1x, so Retina 2x behavior remains not reproducible on this host;
- TextEdit `--app` and `--window-id` captured the same `656x422` window; app image wall time improved from `0.72s` to `0.57s`;
- Chrome `--app` and `--window-id` captured the same `1672x1297` window; app image wall time improved from `0.75s` to `0.55s`;
- PeekabooInspector `image --window-id 13665` captured `450x732` in `0.39s`; before the fix, `image --app PeekabooInspector` timed out after `3.30s`, and after the fix it captured the same `450x732` window in `0.57s`;
- `see --app` and `see --window-id` succeeded for TextEdit, Chrome, and PeekabooInspector with matching screenshot dimensions; Inspector `see --app` recorded `84` elements, `74` interactables, and desktop observation spans `state.snapshot=93ms`, `target.resolve=30ms`, `capture.window=155ms`, `detection.ax=129ms`.

Live verification after smart-capture service cleanup, May 7, 2026:

```bash
pnpm run format
pnpm run lint
pnpm run test:safe
./Apps/CLI/.build/debug/peekaboo permissions status --json
./Apps/CLI/.build/debug/peekaboo list apps --json
./Apps/CLI/.build/debug/peekaboo list screens --json
./Apps/CLI/.build/debug/peekaboo list windows --app Finder --json
./Apps/CLI/.build/debug/peekaboo image --mode screen --path /tmp/peekaboo-live-screen.png --json
./Apps/CLI/.build/debug/peekaboo see --app frontmost --path /tmp/peekaboo-live-see-frontmost.png --annotate --json
./Apps/CLI/.build/debug/peekaboo click --coords 500,1000 --no-auto-focus --json
./Apps/CLI/.build/debug/peekaboo move --coords 520,1000 --json
./Apps/CLI/.build/debug/peekaboo see --app TextEdit --path /tmp/peekaboo-live-textedit-before.png --annotate --json
./Apps/CLI/.build/debug/peekaboo click --on elem_2 --snapshot 1ACF34FD-8EA8-4419-B0FA-73689AA4936B --app TextEdit --json
./Apps/CLI/.build/debug/peekaboo type PEEKABOO_LIVE_TYPE_1778155880 --clear --app TextEdit --delay 0 --profile linear --json
./Apps/CLI/.build/debug/peekaboo image --app TextEdit --path /tmp/peekaboo-live-textedit-after.png --json
./Apps/CLI/.build/debug/peekaboo image --app "Google Chrome" --path /tmp/peekaboo-live-chrome-app.png --json
./Apps/CLI/.build/debug/peekaboo image --window-id 12438 --path /tmp/peekaboo-live-chrome-window.png --json
./Apps/CLI/.build/debug/peekaboo see --app "Google Chrome" --path /tmp/peekaboo-live-chrome-see.png --annotate --json
```

Results:

- `pnpm run test:safe` passed `343` tests in `53` suites; `pnpm run lint` found `0` violations;
- permissions granted: Screen Recording, Accessibility, Event Synthesizing;
- `list apps` wall time `0.23s`, `list screens` `0.12s`, `list windows --app Finder` `0.18s`, `list menubar` `0.19s`, `tools` `0.10s`;
- screen capture wrote a nonblank `3008x1632` PNG in `0.54s`; observation capture span `323ms`, output raw write `1.5ms`;
- `see --app frontmost --annotate` on Ghostty produced `241` interactables in `1.09s`; spans included `capture.window=166ms`, `detection.ax=290ms`, `annotation.render=216ms`;
- coordinate `click` and `move` on the already-frontmost Ghostty window succeeded without hitting destructive controls; JSON execution times were `54ms` and `37ms`;
- controlled TextEdit fixture `see` found `393` elements and `301` interactables in `1.06s`; element click targeted `elem_2`, `type --clear` entered `PEEKABOO_LIVE_TYPE_1778155880`, and visual verification confirmed the marker in the captured `656x422` TextEdit image;
- Chrome `image --app` and `image --window-id 12438` both captured the same real `1672x1297` browser window rather than auxiliary `3008x30` or `1x1` windows; app image wall time `0.55s`, window-id wall time `0.83s`;
- Chrome `see --app --annotate` produced `59` elements and `54` interactables in `1.02s`; spans included `capture.window=191ms`, `detection.ax=97ms`, `annotation.render=269ms`;
- screenshots were inspected with local image vision; no blank captures observed.

CLI JSON envelope sweep, May 7, 2026:

```bash
./Apps/CLI/.build/debug/peekaboo permissions status --json
./Apps/CLI/.build/debug/peekaboo list apps --json
./Apps/CLI/.build/debug/peekaboo list screens --json
./Apps/CLI/.build/debug/peekaboo list menubar --json
./Apps/CLI/.build/debug/peekaboo list windows --app Finder --json
./Apps/CLI/.build/debug/peekaboo dock list --json
./Apps/CLI/.build/debug/peekaboo dialog list --json
./Apps/CLI/.build/debug/peekaboo space list --json
./Apps/CLI/.build/debug/peekaboo window list --app Finder --json
./Apps/CLI/.build/debug/peekaboo tools --json
./Apps/CLI/.build/debug/peekaboo commander --json
./Apps/CLI/.build/debug/peekaboo sleep 1 --json
./Apps/CLI/.build/debug/peekaboo image --app frontmost --path /tmp/peekaboo-sweep-frontmost.png --json
./Apps/CLI/.build/debug/peekaboo see --app frontmost --path /tmp/peekaboo-sweep-see.png --json
```

Results:

- `list apps`, `list screens`, and `list windows --app Finder` now use the standard top-level `success/data/debug_logs` envelope instead of the old `data/metadata/summary` shape;
- the documented experimental `commander` diagnostics command is registered again and returns command metadata inside the standard JSON envelope;
- read-only command wall times were `115-235ms` on this host, except `dialog list` returned the expected structured no-dialog error in `164ms`;
- `image --app frontmost` captured successfully in `565ms`; `see --app frontmost` captured and detected successfully in `847ms`.

Live verification after service split cleanup, May 7, 2026:

```bash
./Apps/CLI/.build/debug/peekaboo permissions status --json --no-remote
./Apps/CLI/.build/debug/peekaboo list apps --json --no-remote
./Apps/CLI/.build/debug/peekaboo list screens --json --no-remote
./Apps/CLI/.build/debug/peekaboo list windows --app TextEdit --json --no-remote
./Apps/CLI/.build/debug/peekaboo list windows --app "Google Chrome" --json --no-remote
./Apps/CLI/.build/debug/peekaboo image --window-id 13441 --path .artifacts/live-e2e/2026-05-07T174032Z/textedit-window.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo image --app TextEdit --path .artifacts/live-e2e/2026-05-07T174032Z/textedit-app.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo image --window-id 13441 --retina --path .artifacts/live-e2e/2026-05-07T174032Z/textedit-retina.png --json --no-remote
screencapture -l 13441 -o -x .artifacts/live-e2e/2026-05-07T174032Z/textedit-native.png
./Apps/CLI/.build/debug/peekaboo see --window-id 13441 --path .artifacts/live-e2e/2026-05-07T174032Z/textedit-see-window.png --annotate --json --no-remote
./Apps/CLI/.build/debug/peekaboo see --app TextEdit --path .artifacts/live-e2e/2026-05-07T174032Z/textedit-see-app.png --annotate --json --no-remote
./Apps/CLI/.build/debug/peekaboo image --window-id 13977 --path .artifacts/live-e2e/2026-05-07T174032Z/chrome-window.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo image --app "Google Chrome" --path .artifacts/live-e2e/2026-05-07T174032Z/chrome-app.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo image --window-id 13977 --retina --path .artifacts/live-e2e/2026-05-07T174032Z/chrome-retina.png --json --no-remote
screencapture -l 13977 -o -x .artifacts/live-e2e/2026-05-07T174032Z/chrome-native.png
./Apps/CLI/.build/debug/peekaboo see --window-id 13977 --path .artifacts/live-e2e/2026-05-07T174032Z/chrome-see-window.png --annotate --json --no-remote
./Apps/CLI/.build/debug/peekaboo see --app "Google Chrome" --path .artifacts/live-e2e/2026-05-07T174032Z/chrome-see-app.png --annotate --json --no-remote
./Apps/CLI/.build/debug/peekaboo click --coords 536,293 --no-auto-focus --json --no-remote
./Apps/CLI/.build/debug/peekaboo type PEEKABOO_E2E_174150 --clear --app TextEdit --delay 0 --profile linear --json --no-remote
./Apps/CLI/.build/debug/peekaboo image --window-id 13983 --path .artifacts/live-e2e/2026-05-07T174032Z/textedit-controlled-after.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo see --window-id 13983 --path .artifacts/live-e2e/2026-05-07T174032Z/textedit-controlled-see-after.png --annotate --json --no-remote
```

Results:

- permissions granted and standard JSON envelopes returned for permissions, apps, and screens;
- TextEdit `image --window-id` completed in `0.43s`; `image --app` selected the same real `656x422` titled window in `0.53s`;
- TextEdit `--retina` and native `screencapture -l` both produced `656x422` on this 1x host, so the flag path still matches native capture dimensions here;
- TextEdit `see --window-id` completed in `0.48s` with spans `capture.window=163ms`, `detection.ax=64ms`, `annotation.render=22ms`; `see --app` completed in `0.62s` against the same window ID;
- Chrome `image --window-id` completed in `0.39s`; `image --app` selected the same real `1672x1297` titled browser window in `0.63s`, not the auxiliary `3008x30` or `1x1` helper windows;
- Chrome `--retina` and native `screencapture -l` both produced `1672x1297` on this 1x host;
- Chrome `see --window-id` completed in `1.56s` with `546` elements and `436` interactables; `see --app` completed in `1.66s` against the same window ID with `547` elements and `436` interactables;
- controlled TextEdit interaction used a temp document under the artifact directory, clicked inside the document in `0.16s`, typed `PEEKABOO_E2E_174150` in `0.55s`, and recaptured the marker in a `656x422` screenshot;
- follow-up `see` on the controlled TextEdit window completed in `0.93s`, found the marker in JSON, and reported `395` elements / `303` interactables;
- screenshots were inspected with local image vision: TextEdit marker visible, Chrome annotated screenshot nonblank with labels aligned to visible UI.
- `peekaboo image --app TextEdit --path . --json` was run from `/tmp/peekaboo-path-dot.51XoMS` and wrote `TextEdit_2026-05-07T17:53:30Z.png` inside that directory, verifying the directory-like output path fix.
- `peekaboo see --app TextEdit --path . --json` was run from `/tmp/peekaboo-see-path-dot.ZPHsAQ` and wrote `peekaboo_see_1778176668.png` inside that directory in `0.89s`, verifying the same policy for `see`.

Live verification after path/span cleanup, May 7, 2026:

```bash
./Apps/CLI/.build/debug/peekaboo permissions status --json --no-remote
./Apps/CLI/.build/debug/peekaboo list apps --json --no-remote
./Apps/CLI/.build/debug/peekaboo list screens --json --no-remote
./Apps/CLI/.build/debug/peekaboo list windows --app TextEdit --json --no-remote
./Apps/CLI/.build/debug/peekaboo list windows --app "Google Chrome" --json --no-remote
./Apps/CLI/.build/debug/peekaboo image --app frontmost --path "$TMPDIR/frontmost.png" --json --no-remote
./Apps/CLI/.build/debug/peekaboo image --app TextEdit --path "$TMPDIR/textedit.png" --json --no-remote
./Apps/CLI/.build/debug/peekaboo image --app "Google Chrome" --path "$TMPDIR/chrome.png" --json --no-remote
./Apps/CLI/.build/debug/peekaboo see --app TextEdit --path "$TMPDIR/textedit-see.png" --json --no-remote
./Apps/CLI/.build/debug/peekaboo see --app "Google Chrome" --path "$TMPDIR/chrome-see.png" --json --no-remote
./Apps/CLI/.build/debug/peekaboo see --app TextEdit --path /tmp/peekaboo-span-check.png --json --no-remote
```

Results:

- permissions granted: Screen Recording, Accessibility, Event Synthesizing;
- display scale: 1x, so Retina 2x behavior remains hardware-limited on this host;
- read-only command wall times stayed fast: `permissions status` `0.132s`, `list apps` `0.230s`, `list screens` `0.130s`, TextEdit windows `0.199s`, Chrome windows `0.218s`;
- app image wall times: frontmost `0.684s`, TextEdit `0.567s`, Chrome `0.600s`;
- `see --app TextEdit` completed in `0.930s` with `396` elements / `303` interactables and a `656x422` screenshot;
- `see --app "Google Chrome"` completed in `0.703s` with `126` elements / `121` interactables and a `1672x1297` screenshot;
- frontmost TextEdit `see` after the span cleanup completed in `0.93s` wall / `0.815s` JSON execution time with `396` elements and `303` interactables; spans included `state.snapshot=104.9ms`, `target.resolve=55.4ms`, `capture.window=164.1ms`, `detection.ax=379.5ms`, `output.write=5.1ms`, `output.raw.write=0.5ms`, `snapshot.write=4.6ms`, and total `desktop.observe=813.3ms`.

Live verification after private ScreenCaptureKit fallback controls, May 7, 2026:

```bash
swift build --package-path Apps/CLI
swift build --package-path Apps/CLI -Xswiftc -DPEEKABOO_DISABLE_PRIVATE_SCK_WINDOW_LOOKUP
swift build --package-path Apps/CLI
./Apps/CLI/.build/debug/peekaboo image --window-id 13441 --retina --path .artifacts/live-e2e/2026-05-07T221125Z-fallback-switch/text-private-on.png --json --no-remote
PEEKABOO_DISABLE_PRIVATE_SCK_WINDOW_LOOKUP=1 ./Apps/CLI/.build/debug/peekaboo image --window-id 13441 --retina --path .artifacts/live-e2e/2026-05-07T221125Z-fallback-switch/text-private-off.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo image --app TextEdit --path .artifacts/live-e2e/2026-05-07T221125Z-fallback-switch/text-app.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo see --app TextEdit --path .artifacts/live-e2e/2026-05-07T221125Z-fallback-switch/text-see.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo image --window-id 13977 --retina --path .artifacts/live-e2e/2026-05-07T221125Z-fallback-switch/chrome-private-on.png --json --no-remote
PEEKABOO_USE_PRIVATE_SCK_WINDOW_LOOKUP=false ./Apps/CLI/.build/debug/peekaboo image --window-id 13977 --retina --path .artifacts/live-e2e/2026-05-07T221125Z-fallback-switch/chrome-private-off.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo image --app "Google Chrome" --path .artifacts/live-e2e/2026-05-07T221125Z-fallback-switch/chrome-app.png --json --no-remote
./Apps/CLI/.build/debug/peekaboo see --app "Google Chrome" --path .artifacts/live-e2e/2026-05-07T221125Z-fallback-switch/chrome-see.png --json --no-remote
screencapture -l 13441 -o -x .artifacts/live-e2e/2026-05-07T221125Z-fallback-switch/text-native.png
screencapture -l 13977 -o -x .artifacts/live-e2e/2026-05-07T221125Z-fallback-switch/chrome-native.png
./Apps/CLI/.build/debug/peekaboo capture live --mode area --region 100,100,320,220 --capture-engine cg --duration 2 --max-frames 4 --path .artifacts/live-e2e/2026-05-07T221125Z-fallback-switch/concurrent/live --json --no-remote &
./Apps/CLI/.build/debug/peekaboo see --app TextEdit --capture-engine modern --path .artifacts/live-e2e/2026-05-07T221125Z-fallback-switch/concurrent/text-modern-see.png --json --no-remote
```

Results:

- normal and `-DPEEKABOO_DISABLE_PRIVATE_SCK_WINDOW_LOOKUP` CLI builds both completed successfully;
- runtime private lookup enabled and disabled both captured nonblank TextEdit and Chrome window-ID screenshots in `0.41-0.42s`;
- `PEEKABOO_DISABLE_PRIVATE_SCK_WINDOW_LOOKUP=1` and `PEEKABOO_USE_PRIVATE_SCK_WINDOW_LOOKUP=false` both continued through the fallback ladder instead of failing capture;
- TextEdit `image --app` selected the `656x422` titled document window instead of the visible `3008x30` auxiliary strips; Chrome `image --app` selected the `1672x1297` titled browser window instead of helper windows;
- TextEdit and Chrome `--retina` captures matched native `screencapture -l` dimensions on this 1x host: `656x422` and `1672x1297`;
- `see --app TextEdit` completed in `0.60s` wall / `0.493s` JSON execution time; `see --app "Google Chrome"` completed in `1.03s` wall / `0.926s` JSON execution time;
- concurrent `capture live --capture-engine cg --mode area` and `see --capture-engine modern` completed without deadlock; live capture took `2.40s`, overlapping `see` took `0.67s`, and both produced nonblank artifacts.

### Performance Budgets

Budgets are manual benchmark targets, not flaky unit-test thresholds.

Warm local desktop targets:

```text
permissions status: <100 ms
list windows --app: <250 ms
image --window-id: <500 ms
image --app: <700 ms
see --window-id, native AX tree: <1500 ms
see --app, native AX tree: <1800 ms
see sparse Chromium/Tauri with focus fallback: <2500 ms
```

Treat these as bugs:

- `image` runs element detection;
- local commands probe bridge or remote endpoints by default;
- permission checks happen twice;
- fallback focus runs after a rich native tree;
- command runtime spends meaningful time formatting JSON compared with capture/detection;
- window-targeted detection traverses the entire app when a window context exists.

## Risk Areas

### Retina Scale

`image --retina` must produce native pixels on Retina displays. Keep pure planner tests and live `sips` checks. Do not infer Retina behavior from output-path code.

### Tauri/Electron/Chromium

These apps often expose many helper windows and sometimes sparse AX trees. Automatic target selection should choose the main visible window; sparse-tree fallback should run only when the native tree is actually sparse.

### Menubar Popovers

Menubar popovers mix click-to-open behavior, window-list capture, AX, OCR, and area fallback. Keep it as a typed observation sub-pipeline with explicit diagnostics.

### Bridge/Remote

Do not force bridge APIs to accept the full observation request until local behavior is stable. Keep request mapping parity tests so remote observation can be added later without drift.

### Snapshot Compatibility

Preserve snapshot behavior unless deliberately migrated:

- same snapshot JSON shape where possible;
- stable element IDs for equivalent captures where possible;
- annotated screenshot paths stored consistently;
- stale snapshot failures explain target/window identity.

## Whole-Refactor Acceptance

- `DesktopObservationService.observe(_:)` is the only behavioral path for `see`, `image`, MCP `see`, and MCP `image`.
- `SeeCommand.swift` is under about 400 lines.
- `ImageCommand.swift` is under about 400 lines.
- `ScreenCaptureService.swift` is under about 500 lines.
- `ElementDetectionService.swift` is under about 500 lines.
- CLI sources no longer import `AXorcist` or `ScreenCaptureKit`.
- `image --app X` and `see --app X` choose the same app window.
- `image --window-id N` and `see --window-id N` report the same window identity.
- `--retina` produces native display scale where macOS allows it.
- Structured timings are available in CLI JSON and MCP metadata.
- No duplicated Screen Recording preflight.
- No default bridge probe for local read-only commands.
- No app-root AX traversal for a window capture.
- Rich native AX trees skip web focus fallback.
- Sparse web AX trees can still use web focus fallback.
- Observation output owns raw screenshot, annotation, OCR artifact, and snapshot side effects.
- Interaction commands can reuse observation state or explain why they cannot.
- `pnpm run format`, `pnpm run lint`, and `pnpm run test:safe` pass.
- Targeted Core observation, capture, and element detection tests pass.
- Live TextEdit, Chrome, and Peekaboo Inspector E2E runs are recorded with screenshots and timings.

## Changelog Discipline

For each shipped group:

- add a concise `CHANGELOG.md` entry;
- mention user-visible behavior changes such as target selection, Retina scale, diagnostics, or timings;
- mention contributor fixes when the group closes a GitHub issue or PR thread;
- keep internal-only extraction notes short unless they change performance or behavior.

## Open Questions

- Should observation become a bridge endpoint after local CLI/MCP behavior is stable?
- Should AI image analysis become an observation enhancement, or stay above AutomationKit because it depends on Tachikoma?
- Should `CaptureTarget` be fully replaced by `DesktopObservationTargetRequest`, or wrapped during module extraction?
- Should OCR move into AutomationKit now, or wait until annotation and snapshot output are fully centralized?
- Should annotation use one rich renderer everywhere, or keep a simple Core renderer in AutomationKit plus a richer CLI renderer until dependencies are untangled?
