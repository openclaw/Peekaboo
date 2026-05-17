# Changelog

## [3.2.1] - Unreleased

### Fixed
- `peekaboo-mcp` now shuts down cleanly during restart backoff and repairs executable permissions without shelling out through an install path.
- `pnpm run peekaboo:dev` no longer depends on a hardcoded local checkout path.
- `peekaboo agent` now tells models to use the current tool schema instead of stale tool names and arguments. Thanks @vyctorbrzezowski for #139.
- AX element detection now honors traversal budgets and reports truncation when depth, count, or per-node child limits are reached. Thanks @vyctorbrzezowski for #140.
- `peekaboo agent` and MCP clients now have an `inspect_ui` tool for AX-only UI text/control inspection without capturing screenshots. Thanks @vyctorbrzezowski for #141.

## [3.2.0] - 2026-05-15

### Added
- `peekaboo click --focus-background` and the MCP `click` tool now support process-targeted background mouse delivery for apps identified by `--app`, `--pid`, or snapshot metadata.
- `peekaboo agent` now supports MiniMax M2.7 through Tachikoma's Anthropic-compatible provider path. Thanks @xiaofeiwa for #130.
- `peekaboo agent` now accepts `ollama/<model>` and `lmstudio/<model>` local model selections, including local-only provider defaults. Thanks @0x5845 for #137.

### Fixed
- Ollama vision model IDs such as `qwen2.5vl:3b` now stay intact through Tachikoma model parsing instead of falling back to `llama3.3` (#16).
- `peekaboo agent` now initializes with Gemini-only or MiniMax-only credentials instead of falling back to an unavailable OpenAI/Anthropic default. Thanks @lonexreb for #133.
- Window captures now retry transient `SCScreenshotManager` failures before reporting a minimized/off-screen/Space hint. Thanks @lonexreb for #135.
- The macOS app now keeps one status item/controller across app state reconnects and removes the status item on teardown, avoiding duplicate or ghost menu bar icons. Thanks @lonexreb for #134.
- Release automation now verifies CLI, npm, macOS app, checksum, appcast, and uploaded GitHub assets before publish.
- `peekaboo type --json` now separates requested text from executed key actions, making escaped special keys such as `\n` visible to agents without losing backwards-compatible `typedText`.
- `peekaboo permissions status --all-sources` now compares Bridge and local TCC permission state side by side, so daemon grants are no longer confused with CLI grants.
- `peekaboo mcp serve --transport ...` now rejects invalid transport names instead of silently starting stdio mode.
- `peekaboo paste --app ...` now fails before mutating the clipboard when the requested app cannot be found.
- `peekaboo agent` no longer sends stale Anthropic extended-thinking options to Claude Opus 4.7 and now exits with failure when agent execution fails.
- Command timeout JSON now reports the intended timeout error instead of occasionally surfacing cancellation as an unknown error.
- Refreshed CLI docs and quickstart examples to use current flags such as `image --path`, `click --coords`, `type --return`, `press --count`, and `scroll --amount`.

### Performance
- Debug CLI startup no longer spawns `git config` on every launch when build-staleness checking is disabled, cutting startup-heavy command latency by more than 30% in local testing.

## [3.1.2] - 2026-05-11

### Fixed
- Release automation now writes artifacts under `build/release` so clean release builds no longer embed `-dirty` in CLI version metadata.

## [3.1.1] - 2026-05-11

### Added
- `peekaboo image --path -` now writes a single captured image to stdout for shell pipelines.
- The npm package now allows Intel Macs when shipping the universal CLI binary.

### Fixed
- Agent tool schemas now preserve MCP `anyOf`/`oneOf` parameters so Gemini no longer rejects `peekaboo agent` requests with orphan `required` entries. Thanks @bcharleson for #125.
- The macOS app release script now fails if the packaged app is missing its main executable and preserves the AppleEvents entitlement when re-signing.
- `peekaboo see --capture-engine cg` now keeps frontmost/window captures on the CoreGraphics path instead of falling through to `SCScreenshotManager`.

## [3.1.0] - 2026-05-10

### Changed
- Refreshed the agent model catalog through Tachikoma: defaults now use GPT-5.5, Claude Opus 4.7, Gemini 3.1, latest Mistral, and Grok 4.3, while stale GPT-4.x/GPT-5.1/GPT-5.2, Claude 3.x, and old Grok IDs are rejected.
- Consolidated MCP installation docs into the main MCP page and removed stale standalone Claude Desktop and MCP best-practices pages from the docs site.
- Added docs-site agent metadata, social preview assets, and security discovery files, with GitHub links moved to the OpenClaw-owned repository. Thanks @williamclay8 for #115.
- Release automation now builds and uploads the signed, notarized Peekaboo.app zip by default, updates Sparkle appcast metadata, and accepts one-line App Store Connect API keys for notarization.
- Refined the macOS Settings window, menu bar popover header, and Playground chrome with denser native layout, clearer controls, and less debug noise.
- Fixed the macOS app's invisible settings helper window and refreshed the app icon artwork so Dock no longer shows a stray blank window or white icon backing.
- CLI automation commands now prefer a warm on-demand daemon for bursty use and route desktop observation through the daemon when supported, avoiding repeated process/service startup and large screenshot payloads over the Bridge socket.

### Performance
- Daemon-backed `peekaboo image`/MCP image calls now write screenshots inside the daemon and return lightweight metadata, making warm screenshot calls substantially faster and preventing large-image Bridge timeouts.
- Capture engine `auto` now tries CoreGraphics before ScreenCaptureKit for faster repeated screenshot calls while preserving explicit ScreenCaptureKit selection through `--capture-engine modern`.

## [3.0.0] - 2026-05-09

### Highlights
- Native action-first automation is now the default path for supported UI controls, with synthetic input as a fallback. This makes element clicks, text entry, scrolling, value setting, and accessibility actions more reliable across real macOS apps.
- Screenshot and UI detection flows now share the desktop observation pipeline across CLI and MCP, including structured diagnostics, timing spans, resolved target metadata, OCR, annotation output, and snapshot registration.
- Window, app, menu bar, Dock, dialog, Space, clipboard, run, and capture commands now use shared service boundaries and consistent JSON envelopes, making automation output easier to script and debug.
- Element-targeted interactions now preserve snapshot window context, refresh stale implicit snapshots once, and report target-point diagnostics, so follow-up clicks and gestures keep working after windows move or refresh.
- Capture and detection performance improved substantially: local read-only commands avoid bridge probes by default, app/window selection has faster paths, ScreenCaptureKit work is gated under concurrency, and `see` avoids redundant AX traversal/probes.
- CLI usability is better: shell completions, public kebab-case help placeholders, directory-aware output paths, home-directory path expansion, clear validation failures, and stricter unexpected-argument handling.
- Peekaboo.app release, Sparkle update, Homebrew sync, and generated docs-site automation are now wired into the release flow.
- Major v3 internals were split into focused files across CLI, Core services, MCP tools, bridge transport, agent runtime, capture, observation, UI automation, and visualizer code so future fixes are smaller and easier to review.

### Added
- Expanded the repo-local `peekaboo` skill with UIAX/action vs synthetic input testing workflows, Calculator smoke tests, and validation commands.
- Peekaboo Inspector now surfaces AX descriptions and keyboard shortcuts, making description-only controls easier to inspect and search.
- `peekaboo see --json` now includes element bounds in each `ui_elements` entry again.
- Added `DesktopObservationService` and the desktop observation refactor plan as the shared path toward unified screenshot capture, target resolution, timings, and optional AX detection.
- Added an observation output writer so desktop observation requests can save raw screenshots and report output paths through the shared result.
- Routed `peekaboo image` screenshot persistence through the shared desktop observation output writer.
- Routed observation-backed `peekaboo see` captures through shared observation output and AX detection in one request.
- Honored per-command capture engine preferences in observation-backed `peekaboo image` and `peekaboo see` captures.
- Enforced the desktop observation detection timeout budget and return the standard detection timeout error.
- Centralized automatic app-window ranking in desktop observation so screenshot commands prefer normal titled windows over auxiliary capture surfaces.
- Centralized screen capture scale planning so logical 1x versus native Retina output uses the same tested policy across ScreenCaptureKit and legacy capture paths.
- Added `AXTraversalPolicy` as the first extracted element-detection policy collaborator.
- Added `ElementDetectionCache` as the dedicated short-lived AX tree cache used by element detection.
- Added `ElementClassifier` for tested AX role mapping, actionability policy, and element attribute assembly.
- Added `AXDescriptorReader` for tested batched accessibility descriptor reads and AX value coercion.
- Added `ElementDetectionResultBuilder` for tested element grouping and detection metadata assembly.
- Added `WebFocusFallback` for the Chromium/Tauri sparse accessibility tree recovery path.
- Added `ElementTypeAdjuster` for tested generic-group text-field recovery policy.
- Added `MenuBarElementCollector` for application menu-bar detection elements.
- Added `AXTreeCollector` for isolated accessibility tree traversal and element assembly.
- Added `ElementDetectionWindowResolver` for application/window fallback selection used by detection.
- Added `ScreenCapturePlanner` for tested capture frame-source policy and display-local source rectangle planning.
- Added `ScreenCapturePermissionGate` as the single capture permission enforcement point.
- Added `ScreenCaptureImageScaler` for shared logical-1x downscaling in capture output paths.
- Moved legacy area capture behind the legacy capture operator and removed stale facade helpers.
- Split ScreenCaptureKit and legacy capture operators out of the screen capture facade.
- Added request-scoped desktop state snapshots for observation target resolution and diagnostics.
- Exposed structured desktop observation timings and diagnostics in CLI and MCP outputs.
- `peekaboo image --json` now includes per-capture desktop observation diagnostics, including timing spans, warnings, state snapshots, and resolved target metadata.
- Moved remaining CLI app-window filtering for image, live capture, and window listing into observation target selection.
- Routed image/MCP menu bar strip captures through desktop observation target resolution.
- Added observation-backed menu bar popover window resolution and capture.
- Centralized CLI/MCP annotated screenshot companion-path planning in the observation output writer.
- Observation-backed MCP `see` annotations now render through the shared observation output writer, removing the MCP-local AppKit renderer fallback.
- Observation-backed CLI `see` captures now register raw screenshots and detection snapshots through the shared observation output writer.
- CLI `see --annotate` now uses the shared observation annotation renderer for observation-backed captures, with the smart label placer moved out of command code.
- Observation timings now include artifact subspans for raw screenshot writes, annotation rendering, and snapshot registration.
- Desktop observation JSON diagnostics now include a total `desktop.observe` timing span for end-to-end duration.
- Added first-class OCR results to desktop observation, with shared OCR-to-element mapping for observation and menu-bar helpers.
- `peekaboo see --menubar` now tries the desktop observation pipeline for already-open menu bar popovers before falling back to the legacy click-to-open path.
- `peekaboo see --app menubar` now uses the shared desktop observation menu-bar target instead of command-local area capture.
- `peekaboo see --mode area` now fails during command binding instead of entering the legacy capture bridge and failing later.
- `peekaboo see` no longer carries legacy window/frontmost capture fallback code; those targets now fail during observation target mapping if invalid.
- `peekaboo see --capture-engine`, `peekaboo image --capture-engine`, and `peekaboo see --timeout-seconds` now bind through the Commander CLI path instead of being ignored.
- `peekaboo image --mode area --region x,y,width,height` now captures explicit desktop regions through desktop observation.
- `peekaboo image --help` now lists the supported `multi` and `area` capture modes instead of the stale mode set.
- `peekaboo capture live --region x,y,width,height` now infers area mode, `--mode area` is the canonical name, invalid modes fail clearly, and zero-sized regions are rejected.
- `peekaboo capture live|video --diff-strategy` now rejects unsupported values instead of silently falling back to `fast`.
- MCP `capture` now matches the CLI's area-mode parsing, advertises PID targeting, and rejects invalid source/mode/focus/diff inputs instead of silently falling back to defaults.
- Menu bar popover OCR selection now lives in the shared desktop observation layer, including candidate-window, preferred-area, and AX-menu-frame matching.
- Menu bar popover click-to-open capture now runs through desktop observation via a typed `openIfNeeded` target option instead of command-local click fallback code.
- Desktop observation diagnostics now report shared target resolution metadata for menu bar strip and popover captures, including source, bounds, hints, and click-open fallback status.
- `peekaboo menubar list` now uses the same `data.items/count` JSON envelope and text list formatting as `peekaboo list menubar`.
- CLI `see` screen capture now uses the shared screen inventory instead of command-local ScreenCaptureKit display enumeration.
- CLI `see`, `image`, and `list` capture paths now avoid command-local AppKit screen/application queries and use shared services for screen inventory and app identity checks.
- Screen capture support internals are now split into focused scale, engine fallback, application resolving, and ScreenCaptureKit gate helpers.
- Screen capture orchestration now keeps public protocol witnesses in `ScreenCaptureService`, with operation gating/metrics and capture execution paths split into focused companions.
- ScreenCaptureKit capture execution now separates display/area capture, window capture, and shared frame-source support into focused operator companions.
- Watch capture sessions now separate lifecycle/result assembly from capture-loop cadence/diffing and frame/video persistence helpers.
- Application window listing now isolates hybrid CGWindowList/AX enumeration policy in a dedicated context object.
- Capture models now separate image primitives, live session options, frame metadata, and session-result summaries into focused files.
- UI automation now keeps focus lookup, wait/search logic, typing, pointer/keyboard operations, and search-policy limits in focused service files.
- Space management now keeps managed-display Space mapping helpers out of the private-CGS service file.
- Legacy capture now keeps window capture and screen/area capture paths in focused operator companions.
- Observation label placement now keeps validation, scoring, debug rendering, and text-detection protocol glue in focused companions.
- Window management now keeps state, geometry, listing, target resolution, title search, and presence polling in focused companions.
- Dialog service now keeps public operations and button resolution/action helpers out of the construction/error file.
- Process command models now keep enum cases, interaction parameters, system parameters, and output DTOs in focused files.
- Capture metadata now includes diagnostics for requested scale, native scale, output scale, final pixel size, selected engine, and fallback reason.
- ScreenCaptureKit frame-source internals now keep stream handler/session types in a focused companion while the frame source owns request orchestration.
- MCP image capture now separates tool entrypoint, capture orchestration, and request/format types into focused files.
- MCP list output now keeps parsing and formatting helpers in a focused companion file.
- MCP type tooling now keeps request/target types and response/action formatting in focused companions while `TypeTool` owns schema, validation, and execution flow.
- MCP move tooling now keeps coordinate parsing, target resolution/movement execution, response formatting, and request/result types in focused companions.
- Gesture service path generation now lives in a focused companion, leaving swipe/drag/move orchestration separate from humanized mouse-path synthesis.
- Snapshot management now keeps screenshot persistence, element lookup, and the JSON storage actor in focused support files.
- `peekaboo image` capture orchestration now keeps saved-file/path planning and app-focus policy in focused command-support files.
- `peekaboo capture live` now keeps scope resolution, option normalization, output rendering, focus policy, and Commander binding in focused command-support files.
- `peekaboo capture live` now applies the resolution cap consistently to live frames whose source images lack reusable color-space metadata.
- `peekaboo see --mode screen --json` now emits parseable JSON without human screen-summary lines.
- Screen capture operations now serialize ScreenCaptureKit permission probing with capture work, `peekaboo capture live` now honors `--capture-engine`, and live area capture defaults to the native `screencapture -R` path so it stays fast during concurrent `see` commands.
- CLI `see --menubar` popover candidate discovery now uses the shared desktop observation window catalog instead of command-local window-list parsing.
- Menu-bar click verification now uses the shared desktop observation window catalog instead of command-local CoreGraphics window-list polling.
- Exact `--window-id` observation metadata now resolves through a dedicated window metadata catalog instead of doing CoreGraphics lookup inside target-resolution orchestration.
- `peekaboo image` now builds desktop observation requests through a dedicated command-support adapter.
- `peekaboo image` capture orchestration, output models, filename planning, and focus helpers are now split out of the main command file.
- `peekaboo see` now builds desktop observation requests through a dedicated command-support adapter.
- `peekaboo see --mode screen --screen-index <n>` and screen analysis captures now use the shared desktop observation pipeline while all-screen capture keeps the legacy multi-file behavior.
- MCP `see` request/output and summary support now live outside the primary tool file.
- `peekaboo see` command support types, output rendering, and screen capture helpers are now split out of the main command file.
- `peekaboo see` legacy capture/detection fallback is now isolated in a dedicated command-support pipeline.
- `peekaboo app` launch, quit, and relaunch implementations now live in focused support files, leaving the primary command file as a smaller command shell.
- `peekaboo menu` list output filtering, typed JSON conversion, and text rendering now share one command-support helper.
- `peekaboo menu` subcommands now share one error-output mapper for JSON error codes and stderr rendering.
- `peekaboo menu` click, click-extra, and list implementations now live in focused extension files, leaving the primary command file as registration and shared types.
- Menu extra handling now keeps public orchestration, open-menu state probing, WindowServer enumeration, AX fallback enumeration, and title cleanup in focused service files.
- `peekaboo dialog` click, input, file, dismiss, and list implementations now live in focused extension files, leaving the primary command file as registration, bindings, and shared error handling.
- Dialog service internals now keep active-dialog resolution, dialog classification, and element extraction/typing helpers in focused service files.
- Dialog resolution now keeps application lookup, file-dialog recursion, visibility assists, and CoreGraphics window fallback in focused companions.
- Dock service internals now keep item listing/search, actions, visibility defaults commands, and AX lookup support in focused service files; Dock removal also avoids an unused defaults read and passes the app name to AppleScript as an argument.
- Hotkey service internals now keep key aliasing, chord validation, key-code lookup, and planner test hooks in a focused companion file.
- Script process execution now keeps capture commands, interaction commands, system commands, and generic parameter parsing in focused service files.
- Script process execution now keeps window and clipboard script commands in focused companions instead of the mixed system-command file.
- MCP capture tooling now keeps argument normalization, request construction, path expansion, window resolution, and metadata output in focused companions.
- MCP dialog tooling now keeps input parsing and response formatting in focused companions while the primary tool owns service dispatch.
- MCP app tooling now keeps lifecycle, focus/switch, listing, and response formatting in focused companions while the primary action file owns dispatch.
- MCP drag tooling now keeps request parsing, point resolution, focus handling, and response formatting in focused companions while `DragTool` owns orchestration.
- MCP observation snapshots now live in a shared snapshot store file instead of being hidden inside `SeeTool`.
- Application service internals now keep app discovery, lifecycle/Spotlight launch lookup, and window enumeration in focused service files.
- UI automation orchestration now keeps detection, click, typing, scroll, hotkey, and gesture operations in a focused companion file while the primary service owns initialization and AX wait/search behavior.
- Visualizer coordination now keeps public animation entry points, input/display overlays, and system/display overlays in focused companion files instead of one large coordinator.
- Snapshot management now keeps storage paths, latest-snapshot lookup, element conversion, and cleanup helpers in a focused companion file.
- Agent service orchestration now keeps execution loops, stream delta processing, session lifecycle wrappers, toolset assembly, and MCP-to-agent tool adaptation in focused companion files.
- Agent tool-call event previews now use a tested redaction helper for sensitive argument fields and inline token patterns before sending UI events.
- Bridge server request handling now keeps operation handlers and handshake/permission advertisement policy in focused companion files.
- Bridge server request handling now keeps service-domain handlers in a focused companion file, leaving the primary handler file as routing plus core/capture/automation/window operations.
- Remote service adapters now live in focused files instead of one aggregate service-provider implementation.
- Core service registry now keeps agent refresh/model selection and high-level automation helpers in focused companion files.
- Window tool formatting now keeps base dispatch, window/screen result rendering, and Spaces result rendering in focused files.
- Menu/dialog tool formatting now keeps menu and dialog result rendering in focused companion files instead of carrying unused system/dock helpers.
- UI automation tool formatting now keeps pointer and keyboard result rendering in focused companion files.
- Agent summaries for `move`, `drag`, and `swipe` now include pointer result metadata instead of falling back to an empty completion summary.
- Agent desktop context gathering now reads focused app/window state, cursor position, and recent apps through shared service boundaries instead of direct `NSWorkspace`/CoreGraphics event/window scans.
- MCP app cycling and move-center resolution now use injected automation/screen services instead of direct AXorcist/AppKit calls.
- CLI move/scroll result telemetry now reads the current cursor position through the automation service boundary instead of direct CoreGraphics event calls.
- Agent runtime visualizer bounds resolution and verification image encoding no longer import AppKit; screen geometry now flows through the shared screen service and PNG encoding uses ImageIO.
- CLI app quit/relaunch now resolve, terminate, and poll app state through the application service boundary instead of direct `NSWorkspace` process scans.
- CLI visualizer smoke geometry now uses the injected screen service instead of reading `NSScreen` directly.
- Application service protocol models no longer import AppKit.
- Scripted swipe defaults now resolve the primary screen through the screen service instead of reading `NSScreen.main` directly.
- Window list mapping no longer imports AppKit for CoreGraphics and ScreenCaptureKit-only metadata caching.
- Space management utilities now isolate private CGS API declarations and public Space models from service orchestration.
- Agent tool creation now keeps MCP schema conversion and ToolResponse bridging in focused helper files.
- UI automation protocol definitions now keep mouse profile, element-detection, and operation DTOs in focused model files.
- Type actions now synthesize `enter`, `forward_delete`, `caps_lock`, `clear`, and `help` with their documented key codes instead of collapsing or rejecting them.
- Type service internals now keep target resolution, typing cadence, and special-key synthesis in focused helper files.
- In-memory snapshots now enforce the configured LRU limit immediately after writes and delete pruned artifacts when cleanup is enabled.
- In-memory snapshot management now keeps lifecycle, screenshot access, pruning, and detection mapping in focused helper files.
- `peekaboo space` list, switch, and move-window implementations now live in focused extension files, leaving the primary command file as registration, service wiring, and shared response types.
- `peekaboo dock` launch, right-click, visibility, and list implementations now live in focused extension files, leaving the primary command file as registration, bindings, and shared error handling.
- `peekaboo daemon` start, stop, status, and run implementations now live in focused extension files, leaving the primary command file as registration and shared daemon status support.
- `peekaboo click`, `type`, `move`, `scroll`, `drag`, `swipe`, `hotkey`, and `press` now share one interaction observation context for explicit/latest snapshot selection and focus snapshot policy.
- Element-targeted interaction commands now share one stale-snapshot refresh helper instead of duplicating per-command refresh loops.
- MCP `window` action handlers now live in a focused companion file, and missing window targets return the direct validation error instead of a generic action failure.
- MCP `app` action handlers now live in a focused companion file, leaving the primary tool file as request parsing and dispatch.
- MCP `space` action handlers now live in a focused companion file, leaving the primary tool file as schema, request parsing, and dispatch.
- Legacy window capture fallbacks now live in focused private-ScreenCaptureKit and system-screencapture operator companions instead of the shared capture support file.
- Private ScreenCaptureKit window-ID lookup now has explicit controls: compile with `PEEKABOO_DISABLE_PRIVATE_SCK_WINDOW_LOOKUP` or set `PEEKABOO_DISABLE_PRIVATE_SCK_WINDOW_LOOKUP=1`; `PEEKABOO_USE_PRIVATE_SCK_WINDOW_LOOKUP=false` also opts out for one run.
- `peekaboo click`, `type`, `scroll`, `drag`, and `swipe` now invalidate implicitly reused latest snapshots after successful UI mutations so later commands do not silently target stale UI.
- `peekaboo hotkey --focus-background` can now send process-targeted hotkeys without activating the target app, with bridge permission support and docs. Thanks @prateek for [#112](https://github.com/steipete/Peekaboo/pull/112)!
- `peekaboo completions` now emits zsh, bash, and fish completion scripts generated from Commander metadata. Thanks @jkker for [#96](https://github.com/steipete/Peekaboo/pull/96)!
- Added subprocess/OpenClaw integration docs for local capture workarounds when the bridge host owns macOS permissions. Thanks @hnshah for [#97](https://github.com/steipete/Peekaboo/pull/97)!
- Added a thin `peekaboo-cli` agent skill that points agents at live CLI help and canonical command docs. Thanks @terryso for [#98](https://github.com/steipete/Peekaboo/pull/98)!
- Release automation now dispatches the centralized Homebrew tap updater and waits for the matching tap workflow run. Thanks @dinakars777 for [#110](https://github.com/steipete/Peekaboo/pull/110)!

### Changed
- The docs site now publishes generated documentation pages at the site root and writes the sitemap from the generated page set.

### Fixed
- Commander-backed CLI commands without positional arguments now reject unexpected trailing tokens instead of silently ignoring them.
- Snapshot-backed UIAX actions now preserve app/window context when rehydrating snapshots, so `actionOnly` element clicks resolve in the captured app instead of the frontmost app.
- `peekaboo click` now accepts the shared `--input-strategy` runtime override so action-only and synth-only paths can be tested directly.
- `peekaboo click --input-strategy actionOnly` now focuses editable text controls via `AXFocused` when they do not expose `AXPress`, matching Computer Use-style element targeting more closely.
- `peekaboo click --right` now falls back to a synthetic right-click when `AXShowMenu` cannot complete on the target element.
- `peekaboo clean --dry-run` now previews the documented default cleanup scope instead of requiring an explicit cleanup target.
- `peekaboo run` scripts now create parent directories for legacy `see` step output paths before writing screenshots.
- `peekaboo dialog file` now has `--timeout-seconds` and returns a `TIMEOUT` JSON error instead of hanging indefinitely on wedged save/open panels.
- `peekaboo dialog list` now has `--timeout-seconds` and returns structured JSON instead of hanging or crashing when Accessibility stalls while searching for dialogs.
- `peekaboo list windows --pid` now works without also requiring `--app`, matching the command help and `window list --pid`.
- `peekaboo app hide <app>` and `peekaboo app unhide <app>` now accept the positional app form shown by the CLI examples, while keeping `--app`.
- Snapshot-backed interactions now tolerate tiny macOS window-size jitter instead of failing as stale when a window drifts by only a few pixels between `see` and the follow-up action.
- `peekaboo set-value` now reports unsupported direct value writes as `INVALID_INPUT` with the target element named instead of surfacing an internal Swift error.
- `peekaboo config add-provider --dry-run` and `remove-provider --dry-run` now preserve the config file when invoked through the Commander CLI path.
- `peekaboo config add` now exits nonzero when credential validation fails or times out, matching its JSON `success: false` response.
- Explicit stale snapshots now report the JSON error code `SNAPSHOT_STALE` instead of falling through to `UNKNOWN_ERROR`.
- Bridge transport timeouts now report the JSON error code `TIMEOUT` instead of `INTERNAL_SWIFT_ERROR`.
- `peekaboo see --json` now emits a single structured error response for capture and detection failures instead of occasionally printing two JSON objects.
- `peekaboo type --text`, `peekaboo press --key`, and `peekaboo set-value --value` now work as aliases for their positional arguments.
- Peekaboo.app no longer crashes at launch on macOS 26 when the hidden Settings helper window is created.
- `peekaboo hotkey` now accepts plus-separated shortcuts such as `cmd+s`, matching common CLI shorthand and the help text while still supporting comma and space separators.
- `peekaboo type` is more reliable in VM and headless launch paths because printable ASCII input now uses physical key events instead of Unicode-only events.
- SwiftPM debug builds now skip SwiftUI preview macros when building from Command Line Tools without full Xcode preview plugin support.
- AutomationKit no longer exposes AXorcist action-input, synthetic-input, automation-element, or window-handle implementation types through public Peekaboo service APIs.
- Legacy window capture now uses the private ScreenCaptureKit window-ID lookup behind `/usr/sbin/screencapture -l` before falling back to the system `screencapture` binary and public ScreenCaptureKit enumeration.
- `peekaboo image --path .` and MCP image captures with directory-like paths now save a generated filename inside the directory instead of creating hidden `..png` artifacts.
- `peekaboo see --path .` now uses the same directory-aware output policy for observation and legacy screen companion paths.
- `peekaboo capture live --path ~/...`, `peekaboo capture ... --video-out ~/...`, `peekaboo capture video --path ~/...`, `peekaboo capture video ~/...`, and MCP `capture` path inputs now expand home-directory paths consistently with the rest of the CLI.
- `peekaboo clipboard`, `peekaboo paste`, and MCP clipboard/paste file paths now expand `~/...` before reading or writing files.
- `peekaboo run` script/output paths and `peekaboo agent --audio-file ~/...` now expand home-directory paths before file IO.
- `.peekaboo.json` script `see` screenshot paths and clipboard file/output paths now expand `~/...` during process execution.
- AI image-file analysis now expands only leading home-directory tildes instead of rewriting literal `~` characters inside filenames.
- The shared file image writer now expands `~/...` before saving screenshots/images.
- ScreenCaptureKit area captures now use single-shot capture so source rectangles such as the menu-bar strip save the requested region instead of a full-display frame.
- CLI bundle metadata and the bundled Homebrew formula now advertise the macOS 15 minimum that v3.0.0-beta2+ already requires.
- The bundled Homebrew formula now matches the published v3.0.0-beta4 CLI artifact checksum.
- `peekaboo agent permission ...` now resolves the documented permission subcommands instead of treating `permission` as an agent task.
- `peekaboo move --on` now targets UI elements correctly.
- `peekaboo window` subcommands now accept `--window-id` without requiring a redundant app target.
- `peekaboo press --hold` now honors the requested hold duration.
- `peekaboo app launch --no-focus` now also suppresses activation when launching without `--open` targets.
- `peekaboo clipboard` now accepts the action positionally, so `peekaboo clipboard get --json` matches the documented CLI shape while `--action` remains available as an alias.
- CLI help now uses public kebab-case placeholders from argument and option spellings, e.g. `<script-path>`, `--file-path <file-path>`, and `--action <action>` instead of internal Swift binding names.
- Agent tool formatting now routes Dock, shell/wait, and clipboard tools through their dedicated formatters instead of the generic menu/dialog formatter.
- CLI command utilities were split into focused error-handling, output-formatting, service-bridge, cursor-movement, and menu-bar output files.
- `peekaboo agent` command code was split into focused terminal, session, execution, and model parsing extensions to keep the command shell smaller.
- `peekaboo agent` output formatting helpers now live outside the event delegate so streaming and tool event handling stay focused.
- Core configuration loading now keeps parsing, credentials, typed accessors, persistence/default templates, and custom-provider management in focused companion files.
- Bridge client adapters now keep status, capture, interaction, window/app, menu/dock/dialog, snapshot, and socket transport code in focused files.
- Bridge protocol models now keep operation policy, payload DTOs, and request/response envelopes in focused files.
- Dialog service no longer carries stale duplicate file-dialog navigation, filename, save-verification, and key-mapping helpers in its main implementation file.
- File-dialog handling now keeps orchestration, navigation/focus, filename entry, and save verification in focused service files.
- `peekaboo config` custom-provider management commands now live in a focused companion file instead of the add-provider implementation file.
- `peekaboo list screens` implementation and screen payload models now live outside the primary list command file.
- `peekaboo list apps` and `peekaboo list windows` now live in focused companion files instead of the primary list command shell.
- `peekaboo clipboard` Commander binding and JSON payload types now live outside the action implementation file.
- `peekaboo bridge status` diagnostics and JSON report models now live outside the command UI file.
- Commander runtime help rendering and theming now live outside the command resolution router.
- `peekaboo capture live` orchestration and the hidden `capture watch` alias now live outside the root capture command file.
- `peekaboo capture video` now lives in its own command file, leaving live capture and the watch alias in the primary capture command file.
- `peekaboo agent permission` status and request flows now live in focused companion files instead of one oversized command implementation.
- `peekaboo agent permission ...` now resolves as nested permission subcommands before the agent free-form task argument.
- Interactive agent chat UI, input components, and event translation now live in focused companion files instead of one oversized TUI implementation.
- `peekaboo clipboard get --json` now includes the exact clipboard text/base64 payload, and `--output -` no longer mixes raw clipboard output with JSON.
- `peekaboo capture video --sample-fps` now reports the effective video sampling options in JSON metadata.
- JSON output is more consistent across the CLI: `tools`, `list permissions`, config commands, and Commander parse errors now emit parseable structured envelopes with `debug_logs` where applicable.
- `peekaboo list apps`, `list screens`, and `list windows --json` now emit the same standard top-level `success/data/debug_logs` envelope as sibling CLI commands.
- `peekaboo see --json` now leaves `screenshot_annotated` empty when no annotated image was created instead of aliasing the raw screenshot path.
- The experimental `peekaboo commander` diagnostics command is registered again and emits standard JSON diagnostics with `--json`.
- MCP `image` now returns a structured tool error when Screen Recording permission is missing instead of surfacing an internal server error.
- `peekaboo see --mode screen --annotate` now consistently skips annotation generation instead of reporting or attempting a disabled full-screen annotation.
- MCP `image` and `see` now route app/PID/frontmost targets through the desktop observation resolver, so multi-window apps use the same visible-window selection as the CLI.
- MCP `image` saved screenshots now use the shared desktop observation output writer instead of tool-local image persistence.
- MCP `analyze` now honors configured AI providers and per-call `provider_config` model overrides instead of hardcoding the default OpenAI model.
- `peekaboo see --annotate` now aligns labels using captured window bounds instead of guessing from the first detected element.
- Window capture on macOS 26 now resolves native Retina scale from the backing display before falling back to ScreenCaptureKit display ratios.
- `peekaboo image --app ... --window-title/--window-index` now captures the resolved window by stable window ID, avoiding mismatches between listed window indexes and ScreenCaptureKit window ordering.
- `peekaboo image --app ...` now prefers titled app windows over untitled helper windows, avoiding blank or auxiliary-window captures in multi-window Chromium-style apps.
- `peekaboo image --window-title ... --window-index ...` now applies title-over-index precedence when building the observation request, and `image`/`see` now map explicit `PID:<pid>` app identifiers to PID observation targets like MCP.
- `peekaboo capture live --window-title/--window-index` now resolves explicit app-window selections to stable window IDs before the watch capture loop starts.
- MCP `capture` now honors `window_title`, resolves explicit title/index window selections to stable window IDs, and rejects ambiguous `window_index` without an app or PID.
- Element-targeted CLI and MCP interaction commands now apply title-over-index precedence when both window selectors are provided.
- Window management commands now use one resolver for listing, refetching, and mutating windows, so `--pid` targets and title/index precedence stay consistent across close/minimize/maximize/move/resize/focus.
- `peekaboo capture live --window-index ...` now selects window mode during auto-mode resolution instead of falling through to a frontmost capture.
- `peekaboo image --app ...` now reports `WINDOW_NOT_FOUND` when all known app windows are hidden or non-shareable instead of falling back to a generic app capture.
- `peekaboo image --window-id ...` now reports the resolved window identity instead of leaking ScreenCaptureKit's internal helper-window ordering into `window_index`.
- Direct element detection callers now use a real racing timeout instead of creating an unobserved timeout task.
- Element-targeted actions now fail with snapshot window identity when a cached target window disappeared or changed size, instead of silently clicking stale coordinates.
- Element-targeted move, drag, swipe, click output, and scroll targeting now share the same moved-window point adjustment as click/type execution.
- Snapshot storage now preserves typed detection window context, including bundle ID, PID, window ID, and bounds, so observation-backed actions can adjust moved-window targets reliably.
- App launch/switch, window mutation, hotkey, press, and paste commands now invalidate the implicit latest snapshot after UI changes so follow-up actions do not reuse stale UI.
- `peekaboo click --on/--id`, `click <query>`, `move --on/--id`, `move --to <query>`, `scroll --on`, `drag --from/--to`, and `swipe --from/--to` now refresh the implicit observation snapshot once when cached element targets are missing, avoiding stale latest-snapshot timeouts without overriding explicit `--snapshot`.
- `peekaboo scroll --smooth --json` now reports the actual smooth scroll tick count used by the automation service (`amount * 10`) instead of the stale `amount * 3` estimate.
- `peekaboo scroll --on --json` now reports the moved-window-adjusted target point, matching the point used by the automation service.
- `peekaboo window focus --snapshot` can now focus the window captured by a snapshot, and explicit snapshots are preserved when focus changes invalidate implicit latest state.
- `peekaboo window focus --snapshot` now refreshes reported window details from the snapshot's stored window identity instead of warning about a missing command-line target.
- Element-targeted `click`, `move`, `scroll`, `drag`, and `swipe` JSON results now include target-point diagnostics showing the original snapshot point, resolved point, snapshot ID, and moved-window adjustment.
- Archived stale runtime/visualizer refactor notes behind the current refactor index and documented element target-point diagnostics in the command guides.
- Removed the obsolete command-local `ScreenCaptureBridge` shim from `peekaboo see`; fallback capture paths now call the typed capture service directly.
- Split interaction target-point resolution into a focused command support file.
- Split `ClickCommand` focus verification and output models into focused support files.
- Split shared `peekaboo window` target, display-name, action-result, and snapshot-invalidation helpers into a focused support file.
- Split watch-capture frame diffing, luma scaling, bounding-box extraction, and SSIM calculation into a pure `WatchFrameDiffer`.
- Split watch-capture PNG writing, contact sheet generation, image loading, resizing, and change highlighting into `WatchCaptureArtifactWriter`.
- Split watch-capture output directory creation, managed autoclean, and metadata JSON writing into `WatchCaptureSessionStore`.
- Split watch-capture region validation and visible-screen clamping into `WatchCaptureRegionValidator`.
- Split watch-capture result metadata, stats, options snapshots, and no-motion warnings into `WatchCaptureResultBuilder`.
- Split watch-capture live/video frame acquisition, region-target capture, and resolution capping into `WatchCaptureFrameProvider`.
- Split watch-capture active/idle hysteresis policy into `WatchCaptureActivityPolicy` and removed the unused private motion-interval accumulator.
- Split `WindowManagementService` target resolution, title search, and close-presence polling into focused extension files.
- Split `peekaboo window` response models and Commander binding/conformance wiring into a focused command binding file.
- Split `peekaboo window close`, `minimize`, and `maximize` implementations into a focused state-action file.
- Split `peekaboo window move`, `resize`, and `set-bounds` implementations into a focused geometry-action file.
- Split `peekaboo window focus` and `list` implementations into focused command files, leaving the main window command as a thin shell.
- Split interaction snapshot invalidation into a focused shared helper, keeping observation resolution separate from mutation cleanup.
- Split observation label placement geometry and candidate generation into a focused helper, keeping label scoring/orchestration smaller.
- Split desktop observation target diagnostics and timing trace recording out of `DesktopObservationService`.
- Split `peekaboo move` result and movement-resolution types into a focused types file.
- Split `peekaboo move` Commander wiring and cursor movement parameter policy into focused support files.
- Split drag destination-app/Dock AX lookup into a focused CLI helper, removed stale platform imports from `swipe`, and made `move --center` use the shared screen service instead of querying AppKit in the command shell.
- Made `peekaboo image --app` skip auto-focus when a renderable target window is already visible, fixing SwiftPM GUI app captures that timed out during activation and shaving app capture wall time in live TextEdit/Chrome checks.
- Shared MCP `image`/`see` target parsing so `screen:N`, `frontmost`, `menubar`, `PID:1234:2`, `App:2`, and `App:Title` map through the same observation resolver; MCP `image` also now accepts `scale: native`/`retina: true` for native pixel captures.
- Split `peekaboo type` text escape processing and result DTOs into focused support files.
- Shared drag/swipe element-or-coordinate point resolution through the common interaction target resolver and split gesture result DTOs into focused support files.
- Split `peekaboo click` validation/helpers and Commander wiring into focused support files.
- Routed `peekaboo click` coordinate focus verification through the application service boundary instead of command-local `NSWorkspace` frontmost-app reads.
- Routed `peekaboo app switch --to` activation and `--cycle` input through shared service boundaries instead of command-local `NSWorkspace`/`CGEvent` calls.
- Routed `peekaboo menu click/list` frontmost-app fallback through the application service boundary instead of command-local `NSWorkspace` reads.
- Removed stale `AppKit` imports from command utility, menubar, open, and space command files where only Foundation/CoreGraphics APIs are used.
- Removed the stale `AppKit` dependency from the menu-bar popover detector helper.
- Routed smart capture frontmost-app and screen-bounds lookups through shared application and screen service boundaries.
- Split smart capture image decoding, thumbnail resizing, and perceptual hashing into a focused image processor helper.
- Fixed smart capture region screenshots to clamp to the display containing the action target instead of always using the primary display.
- Split observation target menu-bar resolution and window-selection scoring into focused resolver extension files.
- Split desktop observation target, request, and result DTOs into focused model files.
- Split `DesktopObservationService` capture, detection/OCR, and output-writing plumbing into focused extension files.
- Split frontmost-application capture lookup behind the shared capture application resolver so `ScreenCaptureService` no longer owns AppKit app identity conversion.
- Removed stale `AXorcist` imports from CLI command files by routing app hide/unhide and accessibility permission prompting through shared services.
- Routed menu-bar popover target resolution through the shared observation window catalog instead of a resolver-local CoreGraphics window-list query.
- Routed drag `--to-app` destination lookup through application, window, and Dock services instead of direct CLI AX/AppKit queries.
- `peekaboo window focus --help` no longer advertises stale Space flag names or the interaction-only `--no-auto-focus` flag.
- Split exact CoreGraphics window-ID metadata lookup out of `WindowManagementService` so the window service stays closer to orchestration.
- `ElementDetectionService` now returns detection results without writing snapshots itself; snapshot persistence is owned by the automation/observation orchestration layers.
- `peekaboo image --capture-engine` is now wired into Commander metadata, so the documented capture-engine selector is accepted by live CLI parsing.
- Concurrent ScreenCaptureKit screenshot requests now queue through an in-process and cross-process capture gate instead of racing into continuation leaks or transient TCC-denied failures.
- Concurrent `peekaboo see` calls now queue the local screenshot/detection pipeline across processes, avoiding ReplayKit/ScreenCaptureKit continuation hangs under parallel usage.
- Bridge-sourced permission checks now explain when Screen Recording is missing on the selected host app and document the `--no-remote --capture-engine cg` subprocess workaround.
- Peekaboo.app now signs with the AppleEvents automation entitlement so macOS can prompt for Automation permission.
- OpenAI GPT-5 / Responses API paths now resolve OAuth credentials through Tachikoma instead of requiring `OPENAI_API_KEY`, while docs clarify the remaining OpenAI scope limitation.
- Custom OpenAI-compatible and Anthropic-compatible AI providers now forward configured proxy headers during generation and streaming.
- `see --analyze` / image analysis now convert GLM vision model 0-1000 normalized bounding boxes into screenshot pixel coordinates before returning results.
- `image --analyze` now honors configured custom AI providers such as `local-proxy/model` instead of falling back to built-in defaults. Thanks @381181295 for [#99](https://github.com/steipete/Peekaboo/pull/99)!
- Browser focus verification now tolerates stale AX handles by re-resolving windows after activation and checking the topmost renderable CG window. Thanks @ZVNC28 for [#103](https://github.com/steipete/Peekaboo/pull/103)!
- `peekaboo image --app` and `peekaboo see --app/--pid/--window-id` now share the desktop observation target resolver, so helper/offscreen windows are ranked consistently across capture and detection.
- ScreenCaptureKit screenshot calls now fail with a bounded timeout if the underlying framework leaks a continuation, instead of hanging the CLI indefinitely.
- `peekaboo image` and `peekaboo see` now share the same desktop-observation process gate, while ScreenCaptureKit callers avoid redundant outer timeouts, preventing transient TCC failures and continuation-misuse warnings under concurrent CLI use.

### Performance
- Menu bar listing is faster by avoiding redundant accessibility work.
- Exact window-ID metadata refreshes now use a CoreGraphics lookup before falling back to all-app AX enumeration, making already-known window focus/list refreshes substantially faster.
- Dialog discovery and visualizer dispatch now fail fast when their target UI is unavailable instead of waiting through slow default paths.
- `peekaboo tools` and read-only `peekaboo list` inventory commands now default to local execution instead of probing bridge sockets first, shaving roughly 30-35ms from warm catalog/window-list calls when no bridge is in use. Pass `--bridge-socket` to target a bridge explicitly.
- `peekaboo image --app` avoids redundant application/window-count lookups during screenshot setup and skips auto-focus work when the target app is already frontmost.
- `peekaboo image --app` now uses a CoreGraphics-only window selection fast path before falling back to full AX-enriched window enumeration, reducing warm Playground screenshot capture from about 350ms to 290ms.
- `peekaboo image` now defaults to local capture instead of probing bridge sockets first, reducing default warm app screenshot calls from about 330ms to 290ms when no bridge is in use. Pass `--bridge-socket` to target a bridge explicitly.
- `peekaboo see` now defaults to local execution instead of probing bridge sockets first, cutting warm Playground screenshot-plus-AX calls from about 844ms to 759ms when no bridge is in use. Pass `--bridge-socket` to target a bridge explicitly.
- `peekaboo image` skips a redundant CLI-side screen-recording preflight and relies on the capture service's permission check, shaving about 8ms from warm one-shot app screenshots.
- `peekaboo see --app` avoids re-focusing the target window when Accessibility already reports the captured window as focused.
- `peekaboo see` avoids recursive AX child-text lookups for elements whose labels cannot use them, reducing Playground element detection from about 201ms to 134ms in local testing.
- `peekaboo see` batches per-element Accessibility descriptor reads and avoids action/editability probes when the role already determines behavior, reducing local Playground element detection from about 205ms to 176ms.
- `peekaboo see` limits expensive AX action and keyboard-shortcut probes to roles that can use them, reducing Playground element detection from about 286ms to roughly 180-190ms in local testing.
- `peekaboo see` skips a redundant CLI-side screen-recording preflight and relies on the capture service's permission check, shaving a fixed TCC probe from screenshot-plus-AX runs.
- `peekaboo see` now keeps AX traversal scoped to the captured window and skips web-content focus probing once a rich native AX tree is already visible, avoiding sibling-window elements and cutting native Playground detection from about 220ms to 130ms.
- `peekaboo see --app Playground` now runs through the observation facade in about 0.50s locally, with capture and AX detection spans reported separately.

### Community
- Added PeekabooWin to the README community projects list. Thanks @FelixKruger!

## [3.0.0-beta4] - 2026-04-28

### Added
- Root SwiftPM package to expose PeekabooBridge and automation modules for host apps.

### Changed
- Bumped submodule dependencies to tagged releases (AXorcist v0.1.2, Commander v0.2.2, Swiftdansi 0.2.1, Tachikoma v0.2.0, TauTUI v0.1.6).
- Version metadata updated to 3.0.0-beta4 for CLI/macOS app artifacts.

### Fixed
- Test runs now stay hermetic after MCP Swift SDK 0.11 updates by pinning the latest Tachikoma bridge/resource conversions and preventing provider test helpers from consuming live API keys.
- macOS settings now surface Google/Gemini and Grok providers with canonical provider hydration and manual key overrides.
- MCP `list` / `see` text output now surfaces hidden apps, bundle paths, and richer element metadata; thanks @metahacker for [#93](https://github.com/steipete/Peekaboo/pull/93).
- MCP tool descriptions and server-status output now share centralized version/banner metadata; thanks @0xble for [#85](https://github.com/steipete/Peekaboo/pull/85).
- Agent tool responses now handle current MCP resource/resource-link content shapes; thanks @huntharo for [#95](https://github.com/steipete/Peekaboo/pull/95).
- CLI credential writes now honor Peekaboo’s config/profile directory consistently; thanks @0xble for [#82](https://github.com/steipete/Peekaboo/pull/82).
- macOS settings hydration no longer persists config-backed values while loading; thanks @0xble for [#86](https://github.com/steipete/Peekaboo/pull/86).
- CLI agent runtime now prefers local execution by default; thanks @0xble for [#83](https://github.com/steipete/Peekaboo/pull/83).
- Remote `peekaboo see` element detection now uses the command timeout instead of the bridge client's shorter socket default; thanks @0xble for [#89](https://github.com/steipete/Peekaboo/pull/89).
- Screen recording permission checks are more reliable, and MCP Swift SDK compatibility is restored; thanks @romanr for [#94](https://github.com/steipete/Peekaboo/pull/94).
- Coordinate clicks now fail fast when the requested target app is not actually frontmost after focus; thanks @shawny011717 for [#91](https://github.com/steipete/Peekaboo/pull/91).
- Permissions docs now point to the real `peekaboo permissions status|grant` commands; thanks @Undertone0809 for [#68](https://github.com/steipete/Peekaboo/pull/68).

## [3.0.0-beta3] - 2025-12-29

### Highlights
- Headless daemon + window tracking: `peekaboo daemon start|stop|status`, MCP auto-daemon mode, in-memory snapshots, and move-aware click/type adjustments.
- Menu bar automation overhaul: CGWindow + AX fallback for menu extras (including Trimmy), `menubar click --verify` + `menu click-extra --verify` with popover/focus/OCR checks, and `see --menubar` popover capture via window list + OCR.
- Screen/area capture pipeline now uses a persistent ScreenCaptureKit fast stream (frame-age + wait timing logs) with single-shot fallback for windows.

### Added
- `peekaboo clipboard --verify` reads back clipboard writes; text writes now publish both `public.plain-text` and `.string` across CLI, MCP tools, paste, and scripts.
- `peekaboo dock launch --verify`, `peekaboo window focus --verify`, and `peekaboo app switch --verify` add lightweight post-action checks.
- `peekaboo app list` now supports `--include-hidden` and `--include-background`.
- Release artifacts now ship a universal macOS CLI binary (arm64 + x86_64).

### Changed
- AX element detection now caches per-window traversals for ~1.5s to reduce repeated `see` thrash; window list mapping is now centralized and cached to cut CG/SC re-queries.
- Menu bar popover selection now prefers owner-name matches and X-position hints; owner-PID filtering relaxes when app hints do not match any candidate.
- Menu bar screenshot captures now use the real menu bar height derived from each screen’s visible frame.
- `peekaboo see --menubar` now attempts an OCR area fallback after auto-clicking a menu extra even when open-menu AX state is missing.

### Fixed
- Menu bar extras now combine CGWindow data with AX fallbacks to surface third-party items like Trimmy, and clicks target the owning window for reliability.
- Menu bar extras now hydrate missing owner PIDs from running app metadata to improve open-menu detection.
- Menu bar open-menu probing now returns AX menu frames over the bridge to support popover captures.
- Menu bar verification now detects focused-window changes when a menu bar app opens a settings window.
- Menu bar click verification now detects popovers in both top-left and bottom-left coordinate systems.
- Menu bar click verification now requires OCR text to include the target title/owner name when falling back to OCR (set `PEEKABOO_MENUBAR_OCR_VERIFY=0` to disable).
- Menu bar popover OCR area/frame fallbacks now validate against app hints before accepting a capture.

## [3.0.0-beta2] - 2025-12-19

### Highlights
- **Socket-based Peekaboo Bridge**: privileged automation runs in a long-lived **bridge host** (Peekaboo.app, or another signed host like Clawdbot.app) and the CLI connects over a UNIX socket (replacing the v3.0.0-beta1 XPC helper model).
- **Snapshots replace sessions**: snapshots live in memory by default, are scoped **per target bundle ID**, and are reused automatically for follow-up actions (agent-friendly; fewer IDs to plumb around).
- **MCP server-only**: Peekaboo still runs as an MCP server for Claude Desktop/Cursor/etc, but no longer hosts/manages external MCP servers.
- **Reliability upgrades for “single action” automation**: hard wall-clock timeouts and bounded AX traversal to prevent hangs.
- **Visualizer extracted + stabilized**: overlay UI lives in `PeekabooVisualizer`, with improved preview timings and less clipping.

### Breaking
- Removed the v3.0.0-beta1 XPC helper pathway; remote execution now uses the **Peekaboo Bridge** socket host model.
- Renamed automation “sessions” → “snapshots” across CLI output, cache/paths, and APIs.
- Removed external MCP client support (`peekaboo mcp add/list/test/call/enable/disable` removed); `peekaboo mcp` now defaults to `serve`, and `mcpClients` configuration is no longer supported.
- CLI builds now target **macOS 15+**.

### Added
- `peekaboo paste`: set clipboard content, paste (Cmd+V), then restore the prior clipboard (text, files/images, base64 payloads).
- Deterministic window targeting via `--window-id` to avoid title/index ambiguity.
- `peekaboo bridge status` diagnostics for host selection/handshake/security; plus runtime controls `--bridge-socket` and `--no-remote`.
- Bridge security: caller validation via **code signature TeamID allowlist** (and optional bundle allowlist), with a **debug-only** same-UID escape hatch (`PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS=1`).
- `peekaboo hotkey` accepts the key combo as a positional argument (in addition to `--keys`) for quick one-liners like `peekaboo hotkey "cmd,shift,t"`.
- `peekaboo learn` renders its guide as ANSI-styled markdown on rich terminals, while still emitting plain markdown when piped.
- Agent providers now include `gemini-3-flash`, expanding the out-of-the-box model catalog for `peekaboo agent`.
- Agent streaming loop now injects `DESKTOP_STATE` (focused app/window title, cursor position, and clipboard preview when the `clipboard` tool is enabled) as untrusted, delimited context to improve situational awareness.
- Peekaboo’s macOS app now surfaces About/Updates inside Settings (Sparkle update checks when signed/bundled).

### Changed
- Bridge host discovery order is now: **Peekaboo.app → Clawdbot.app → local in-process** (no auto-launch).
- Capture defaults favor the classic engine for speed/reliability, with explicit capture-engine flags when you need SCKit behavior.
- Agent defaults now prefer Claude Opus 4.5 when available, with improved streaming output for supported providers.
- OpenAI model aliases now map to the latest GPT-5.1 variants for `peekaboo agent`.

### Fixed
- ScreenCaptureKit window capture no longer returns black frames for GPU-rendered windows (notably iOS Simulator), and display-bound crops now use display-local `sourceRect` coordinates on secondary monitors.
- `peekaboo see` is now bounded for “single action” use (10s wall-clock timeout without `--analyze`), and timeouts surface as `TIMEOUT` exit codes instead of silent hangs.
- Dialog file automation is more reliable: can force “Show Details” (`--ensure-expanded`) and verifies the saved path when possible.
- `peekaboo dialog` subcommands now expose the full interaction targeting + focus options (Commander parity).
- App resolution now prioritizes exact name matches over bundleID-contains matches, preventing `--app Safari` from accidentally matching helper processes with “Safari” in their bundle ID.
- UI element detection enforces conservative traversal limits (depth/node/child caps) plus a detection deadline, making runaway AX trees safe.
- Listing apps via a bridge no longer risks timing out: window counts now use CGWindowList instead of per-app AX enumeration.
- Visualizer previews now respect their full duration before fading out; overlays no longer disappear in ~0.3s regardless of requested timing.
- `peekaboo image`: infer output encoding from `--path` extension when `--format` is omitted, and reject conflicting `--format` vs `--path` extension values.
- `peekaboo image --analyze`: Ollama vision models are now supported.
- `peekaboo click --coords` no longer crashes on invalid input; invalid coordinates now fail with a structured validation error.
- Auto-focus no longer no-ops when a snapshot is missing a `windowID`, preventing follow-up actions from landing in the wrong frontmost app.
- `peekaboo window list` no longer returns duplicate entries for the same window.
- `peekaboo capture live` avoids window-index mismatches that could attach to the wrong window when multiple candidates are present.
- Bridge hosts that reject the CLI now reply with a structured `unauthorizedClient` error response instead of closing the socket (EOF), and the CLI error message includes actionable guidance for older hosts.

## [3.0.0-beta1] - 2025-11-25

### Added
- Tool allow/deny filters now log when a tool is hidden, including whether the rule came from environment variables or config, and tests cover the messaging.
- `peekaboo image --retina` captures at native HiDPI scale (2x on Retina) with scale-aware bounds in the capture pipeline, plus docs and tests to lock in the behavior.
- Peekaboo now inherits Tachikoma’s Azure OpenAI provider and refreshed model catalog (GPT‑5.1 family as default, updated Grok/Gemini 2.5 IDs), and the `tk-config` helper is exposed through the provider config flow for easier credential setup.
- Full GUI automation commands—`see`, `click`, `type`, `press`, `scroll`, `hotkey`, and `swipe`—now ship in the CLI with multi-screen capture so you can identify elements on any display and act on them without leaving the terminal.
- Natural-language AI agent flows (`peekaboo agent "…"` or simply `peekaboo "…"`) let you describe multi-step tasks in prose; the agent chains native tools, emits verbose traces, and supports low-level hotkeys when you need to fall back to precise control.
- Dedicated window management, multi-screen, and Spaces commands (`window`, `space`) give you scripted control over closing, moving, resizing, and re-homing macOS apps, including presets like left/right halves and cross-display moves.
- Menu tooling now enumerates every application menu plus system menu extras, enabling zero-click discovery of keyboard shortcuts and scripted menu activation via `menu list`, `menu list-all`, `menu click`, and `menu click-extra`.
- Automation snapshots remember the most recent `see` run automatically, but you can also pin explicit snapshot IDs and run `.peekaboo.json` scripts via `peekaboo run` to reproduce complex workflows with one command.
- Rounded out the CLI command surface so every capture, interaction, and maintenance workflow is first-class: `image`, `list`, `tools`, `config`, `permissions`, `learn`, `run`, `sleep`, and `clean` cover capture/config glue, while `window`, `app`, `dock`, `dialog`, `space`, `menu`, and `menubar` provide window, app, and UI chrome management alongside the previously mentioned automation commands.
- `peekaboo see --json` now includes `description`, `role_description`, and `help` fields for every `ui_elements[]` entry so toolbar icons (like the Wingman extension) and other AX-only descriptions can be located without blind coordinate clicks.
- GPT-5.1, GPT-5.1 Mini, and GPT-5.1 Nano are now fully supported across the CLI, macOS app, and MCP bridge. `peekaboo agent` defaults to `gpt-5.1`, the app’s AI settings expose the new variants, and all MCP tool banners reflect the upgraded default.

### Integrations
- Peekaboo runs as both an MCP server and client: it still exposes its native tools to Claude/Cursor, but v3 now ships the Chrome DevTools MCP by default and lets you add or toggle external MCP servers (`peekaboo mcp list/add/test/enable/disable`), so the agent can mix native Mac automation with remote browser, GitHub, or filesystem tools in a single session.

### Developer Workflow
- Added `pnpm` shortcuts for common Swift workflows (`pnpm build`, `pnpm build:cli:release`, `pnpm build:polter`, `pnpm test`, `pnpm test:automation`, `pnpm test:all`, `pnpm lint`, `pnpm format`) so command names match what ships in release docs and both humans and agents rely on the same entry points.
- Automation test suites now launch the freshly built `.build/debug/peekaboo` binary via `CLITestEnvironment.peekabooBinaryURL()` and suppress negative parsing noise, making CI logs far easier to scan.
- Documented the safe vs. automation tagging convention and the new command shorthands inside `docs/swift-testing-playbook.md`, so contributors know exactly which suites to run before tagging.
- `AudioInputService` now relies on Swift observation (`@Observable`) plus structured `Task.sleep` polling instead of Combine timers, keeping v3’s audio capture aligned with Swift 6.2’s concurrency expectations.
- CLI `tools` output now uses `OrderedDictionary`, guaranteeing the same ordering every time you list tools or dump JSON so copy/paste instructions in the README stay accurate.
- Removed the Gemini CLI reusable workflow from CI to eliminate an external check that was blocking pull requests when no Gemini credentials are configured.

### Changed
- Provider configuration now prefers environment overrides while still loading stored credentials, matching the latest Tachikoma behavior and keeping CI/config files in sync.
- Commands invoked without arguments (for example `peekaboo agent` or `peekaboo see`) now print their detailed help, including argument/flag tables and curated usage examples, so it is obvious why input is required.
- CLI help output now hides compatibility aliases such as `--jsonOutput` while still documenting the primary short/long names (`-j`, `--json`), matching the new alias metadata exported by the Commander submodule.

### Fixed
- `peekaboo capture video` positional input now binds correctly through Commander, preventing “missing input” runtime errors; binder and parsing tests cover the regression.
- Menubar automation uses a bundled LSUIElement helper before CGS fallbacks, improving detection of menu extras on macOS 26+.
- Agent MCP tools (see/click/drag/type/scroll) default to the latest `see` session when none is pinned, so follow-up actions work without re-running `see`.
- MCP Responses image payloads are normalized (URL/base64) to align with the schema; manual testing guidance updated.
- Restored Playground target build on macOS 15 so local examples compile again.
- `peekaboo capture video --sample-fps` now reports frame timestamps from the video timeline (not session wall-clock), fixing bunched `t=XXms` outputs and aligning `metadata.json`; regression test added.
- `peekaboo capture video` now advertises and binds its required input video file in Commander help/registry, preventing missing-input crashes; binder and program-resolution tests cover the regression.
- Anthropic OAuth token exchange now uses standards-compliant form encoding, fixing 400 responses during `peekaboo config login anthropic`; regression test added.
- `peekaboo see --analyze` now honors `aiProviders.providers` when choosing the default model instead of always defaulting to OpenAI; coverage added for configured defaults.
- Added more coverage to ensure AI provider precedence honors provider lists, Anthropic-only keys, and empty/default fallbacks.
- Visualizer “Peekaboo.app is not running” notice now only appears with verbose logging, keeping default runs quieter.
- Visualizer console output is now suppressed unless verbose-level logging is explicitly requested (or forced via `PEEKABOO_VISUALIZER_STDOUT`), preventing non-verbose runs from emitting visualizer chatter.

## [2.0.3] - 2025-07-03

### Fixed
- Fixed `--version` output to include "Peekaboo" prefix for Homebrew formula compatibility
- Now outputs "Peekaboo 2.0.3" instead of just "2.0.3"

## [2.0.2] - 2025-07-03

### Fixed
- Actually fixed compatibility with macOS Sequoia 26 by ensuring LC_UUID load command is generated during linking
- The v2.0.1 fix was incomplete - the binary was still missing LC_UUID
- Verified both x86_64 and arm64 architectures now contain proper LC_UUID load commands

## [2.0.1] - 2025-07-03

### Fixed
- Fixed compatibility with macOS Sequoia 26 (pre-release) by preserving LC_UUID load command during binary stripping

## [2.0.0] - 2025-07-03

### 🎉 Major Features

#### Standalone AI Analysis in CLI
- **Added native AI analysis capability directly to Swift CLI** - analyze images without the MCP server
- Support for multiple AI providers: OpenAI GPT-4 Vision and local Ollama models
- Automatic provider selection and fallback mechanisms
- Perfect for automation, scripts, and CI/CD pipelines
- Example: `peekaboo analyze screenshot.png "What error is shown?"`

#### Configuration File System
- **Added comprehensive JSONC (JSON with Comments) configuration file support**
- Location: `~/.config/peekaboo/config.json`
- Features:
  - Persistent settings across terminal sessions
  - Environment variable expansion using `${VAR_NAME}` syntax
  - Comments support for better documentation
  - Tilde expansion for home directory paths
- New `config` subcommand with init, show, edit, and validate operations
- Configuration precedence: CLI args > env vars > config file > defaults

### 🚀 Improvements

#### Enhanced CLI Experience
- **Completely redesigned help system following Unix conventions**
  - Examples shown first for better discoverability
  - Clear SYNOPSIS sections
  - Common workflows documented
  - Exit status codes for scripting
- **Added standalone CLI build script** (`scripts/build-cli-standalone.sh`)
  - Build without npm/Node.js dependencies
  - System-wide installation support with `--install` flag

#### Code Quality
- Added comprehensive test coverage for AI analysis functionality
- Fixed all SwiftLint violations
- Improved error handling and user feedback
- Better code organization and maintainability

### 📝 Documentation

- Added configuration file documentation to README
- Expanded CLI usage examples
- Documented AI analysis capabilities
- Added example scripts and automation workflows
- Removed outdated tool-description.md

### 🔧 Technical Changes

- Migrated from direct environment variable usage to ConfigurationManager
- Implemented proper JSONC parser with comment stripping
- Added thread-safe configuration loading
- Improved Swift-TypeScript interoperability

### 💥 Breaking Changes

- Version bump to 2.0 reflects the significant expansion from MCP-only to dual CLI/MCP tool
- Configuration file takes precedence over some environment variables (but maintains backward compatibility)

### 🐛 Bug Fixes

- Fixed ArgumentParser command structure for proper subcommand execution
- Resolved configuration loading race conditions
- Fixed help text display issues

### ⬆️ Dependencies

- Swift ArgumentParser 1.5.1
- Maintained all existing npm dependencies

## [1.1.0] - Previous Release

- Initial MCP server implementation
- Basic screenshot capture functionality
- Window and application listing
- Integration with Claude Desktop and Cursor IDE
