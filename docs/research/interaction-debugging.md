---
summary: 'Track active interaction-layer bugs and reproduction steps'
read_when:
  - Debugging CLI interaction regressions
  - Triaging Peekaboo automation failures
---

# Interaction Debugging Notes

> **Historical record:** Commands and outputs are preserved as observed when these notes were written. See the
> [Peekaboo 4 migration guide](../v4-migration.md) for current CLI syntax.

> **Mission Reminder (Nov 12, 2025):** The mandate for this doc is to *continuously* exercise every Peekaboo CLI feature until automation covers everything a human can do on macOS. That means:
> - Systematically try every command/subcommand/flag combination (see/see, menu, dialog, window, list, type, drag, press, etc.) and capture regressions here.
> - Treat each bug as blocking mission readiness—fix it or write down why it’s pending.
> - Assume future user prompts can request any macOS action; keep tightening Peekaboo until every tool path (focus, screenshot, menu, dialog, shell, automation) is battle‑tested.
> - When in doubt, reopen TextEdit or another stock app, try to automate the workflow end-to-end via Peekaboo, and log the outcome below.

## Open interaction blockers (Nov 13, 2025)

| Area | Current status | Test coverage gap | Next action |
| --- | --- | --- | --- |
| Window geometry `new_bounds` | JSON echoes stale rectangles after consecutive `set-bounds` / `resize`. | Only single-move assertions in `WindowCommandTests`/`WindowCommandCLITests`; nothing exercises back-to-back mutations or width/height. | Add CLI test that performs two successive geometry changes and asserts the response matches the latest inputs; fix window service caching bug once reproduced. |
| Menu list/click stability | `menu list`/`menu click` still drop into `UNKNOWN_ERROR` / `NotFound` after long sessions or in Calculator. | `MenuDialogLocalHarnessTests` now cover TextEdit/Calculator happy paths *and* the `menuStressLoop` 45 s soak, but the stress loop still runs inline (no tmux) and can’t capture multi-minute drifts. | Move the stress runner into tmux so we can loop for minutes, collect logs/screenshots automatically, and keep probing Calculator/TextEdit until the stale window bug repros deterministically. |
| `dialog list` via polter | Fresh CLI works, but `polter peekaboo …` still ships the old binary and drops `--window-title`, so TextEdit’s Save sheet can’t be enumerated. | Harness now calls `polter peekaboo -- dialog list --app TextEdit --window-title Save` and asserts the binary timestamp is <10 min old, yet we still aren’t bouncing Poltergeist prior to runs. | Add a harness hook that restarts/rebuilds Poltergeist (or at least checks the build log) before running dialog tests, then port the workflow into tmux so unattended runs can flag stale binaries instantly. |
| Chrome/login flows | Certain login forms remain invisible to AX/OCR; Chrome location bubble exposes unlabeled buttons. | No tests mention these flows or Chrome permission dialogs. | Create deterministic WebKit test fixture that mimics the web DOM and Chrome permission bubble to drive OCR/AX fallbacks; prioritize image-based hit testing for “Allow/Don’t Allow”. |
| Mac app StatusBar build | `MenuDetailedMessageRow.swift`, `StatusBarController.swift`, `UnifiedActivityFeed.swift` still fail under Swift 6 logger rules. | `StatusBarControllerTests` only instantiate the controller; no logging/formatter assertions. | Add focused unit tests (or SwiftUI previews under test) that compile these files and verify logging helpers; then fix the offending interpolations so `./scripts/build-mac-debug.sh` goes green. |
| AXObserverManager drift | Xcode workspace pulls a stale AXorcist artifact missing `attachNotification`. | No tests reference `AXObserverManager`, so regressions surface only during mac builds. | Write a minimal test in AXorcist (or PeekabooCore) that instantiates `AXObserverManager`, calls `attachNotification`/`addObserver`, and assert callbacks fire, forcing the workspace to pick up current sources. |
| SpaceTool/SystemToolFormatter schema | Mac build still blocked after tool/schema rename; formatter still has literal newline separator. | Only metadata tests exist (`MCPSpecificToolTests`); they never instantiate SpaceTool or the formatter. | Add unit tests that feed `ServiceWindowInfo` through SpaceTool and ensure the JSON keys + formatter output align with the new schema; patch formatter to escape separators. |
| `--force` flag via polter | Wrapper swallows `--force`, `--timeout`, etc., unless user inserts an extra `--`. | No automated coverage for the polter shim. | Introduce integration test (or script) that launches `polter peekaboo -- dialog dismiss --force` and verifies the flag is honored; update docs and wrapper to emit a hard error when CLI flags are passed before the separator. |

## Unresolved Bugs & Test Coverage Tracker (Nov 13, 2025)

| Bug | Status | Existing tests | Required coverage / next steps |
| --- | --- | --- | --- |
| Menu list/click stability (TextEdit + Calculator) | Still reproducible after long sessions; Calculator click path throws `PeekabooCore.NotFoundError`. | `MenuServiceTests` (stub-only) + `MenuDialogLocalHarnessTests` (`textEditMenuFlow`, `calculatorMenuFlow`, `menuStressLoop`) | Move the new 45 s stress loop into tmux so it can run multi-minute soaks unattended, capture `peekaboo` logs on failure, and keep dumping JSON payloads for Calculator/TextEdit while we chase the stale-window bug. |
| Dialog list via polter | Always include the `--` separator; we still lack proof that `polter peekaboo -- dialog list --window-title …` hits the fresh binary and forwards arguments. | `DialogCommandTests`, `dialogDismissForce`, `MenuDialogLocalHarnessTests.textEditDialogListViaPolter` (with timestamp freshness checks) | Add a Poltergeist restart/build verification step (or log scrape) before the harness runs, then stash dialog screenshots/logs so stale binaries or thrown dialogs are obvious without manual repro. |
| Chrome/login hidden fields & permission bubble | Real Chrome sessions still expose no AX text fields; heuristics only verified via Playground fixtures. | `SeeCommandPlaygroundTests.hiddenFieldsAreDetected`, `ElementLabelResolverTests` | Build a deterministic WebKit/Playground scene that mirrors the secure-login flow plus the Chrome “Allow/Don’t Allow” bubble, then add a `RUN_LOCAL_TESTS` automation that drives Chrome directly and asserts `see` returns the promoted text fields. |
| Mac StatusBar SwiftUI build blockers | `MenuDetailedMessageRow.swift`, `StatusBarController.swift`, and `UnifiedActivityFeed.swift` continue to fail `./scripts/build-mac-debug.sh`. | `StatusBarControllerTests` only instantiate the controller—no coverage for the SwiftUI button style or logging helper. | Finish the Logger/API cleanup in those files and add snapshot/compilation tests (e.g., `StatusBarActionsTests`) so SwiftUI button styles conform to `ButtonStyle` and logging interpolations stay valid. |
| AXObserverManager drift | Workspace build still links against a stale AXorcist artifact missing `attachNotification`. | None | Add an AXorcist unit test (`AXObserverManagerTests`) that instantiates the manager, attaches notifications, and validates callbacks so both SwiftPM and the workspace must ingest the updated sources. |
| Finder window focus error classification | Fix now maps `FocusError` to `WINDOW_NOT_FOUND`, but there’s no regression test for Finder’s menubar-only state. | `FocusErrorMappingTests` (unit-only) | Add CLI-level coverage (stub service or automation harness) that simulates Finder with no renderable windows and asserts `window focus --app Finder` emits `WINDOW_NOT_FOUND` instead of `INTERNAL_SWIFT_ERROR`. |
| `SnapshotManager.storeScreenshot` guardrails | Copy/annotation guardrails remain untested. | None | Add tests that exercise relative paths, missing destination directories, and annotated captures so screenshot copying stays safe. |
| `list windows` empty-output warning | Formatter now emits a warning when no windows exist, but there’s no regression test to keep it working. | `WindowCommandCLITests` (happy-path only) | Add CLI tests asserting the warning + JSON payload appear when the window list is empty. |
| `clean --dry-run` validation | The command now emits `VALIDATION_ERROR`, yet no test ensures the mapping stays intact. | `CleanCommandTests` (success only) | Add a test that runs `clean --dry-run` without selectors and asserts `VALIDATION_ERROR` plus the guidance text. |
| Command help surface | Commander now intercepts `help`/`--help`, but we have no tests proving the new router behavior. | None | Add CLI tests for `polter peekaboo -- help window` and `polter peekaboo -- window --help` (stubbed) to ensure help text prints even when routed through Poltergeist. |

### Execution plan (Nov 13, 2025)
1. **Menu + dialog automation harness** — The `MenuDialogLocalHarnessTests` suite now launches TextEdit/Calculator via Poltergeist, runs `menuStressLoop` for 45 s, and exercises the TextEdit Save sheet end-to-end. Next step: move those loops into tmux so they can soak for minutes, capture logs/screenshots, and restart automatically on failure.
2. **Chrome/login fixture** — Once the harness lands, extend the Playground/WebKit scene to mirror the Chrome secure-login flow and permission bubble, then add integration coverage that drives Chrome directly.
3. **Mac build unblockers** — After the automation harness is in motion, fix the StatusBar SwiftUI files and add the missing AXObserverManager test so `./scripts/build-mac-debug.sh` goes green again. With the build stable, backfill the screenshot/help/clean/list-windows tests listed above.

Step 1 is officially in progress: `MenuDialogLocalHarnessTests` now runs TextEdit + Calculator menu flows and the TextEdit Save dialog via `polter peekaboo -- …` under `RUN_LOCAL_TESTS=true`, so we can build the tmux-backed stress suite on top of that foundation. Use `tmux new-session -- ./scripts/menu-dialog-soak.sh` (optionally override `MENU_DIALOG_SOAK_ITERATIONS`/`MENU_DIALOG_SOAK_FILTER`) to spin up the stress loop in tmux, keep logs under `/tmp/menu-dialog-soak/`, and avoid blocking the guardrail watchdog.

### Implementation roadmap
1. **Reproduce & test guardrails** – Land the regression tests outlined above (window geometry, real menu automation, polter argument forwarding, StatusBar logger compile tests, AXObserverManager, SpaceTool schema). These should fail today and document the gaps.
2. **Fix highest-impact blockers** – Prioritize menu/window/dialog reliability so secure login/Chrome scenarios unblock. Tackle polter flag forwarding and SnapshotManager caching while tests are red.
3. **Expand secure login/Chrome coverage** – Build a deterministic fixture (WebKit host or recorded session) so we can iterate on OCR/AX fallbacks without live credentials; add XCT/unittest coverage to prevent regressions once solved.
4. **Stabilize mac build** – Address StatusBar logger rewrites, AXObserverManager linkage, and SpaceTool formatter so `./scripts/build-mac-debug.sh` passes; keep the new tests in place to enforce it.
5. **Document progress** – Update this section as each issue lands (note fix date + test name) so future agents know which paths are safe.

## `see` command can’t finalize captures
- **Command**: `polter peekaboo -- see --app TextEdit --path /tmp/textedit-see.png --annotate --json-output`
- **Observed**: Logger reports a successful capture, saves `/tmp/textedit-see.png`, then throws `INTERNAL_SWIFT_ERROR` with message `The file “textedit-see.png” doesn’t exist.` The file *does* exist immediately after the failure (checked via `ls -l /tmp/textedit-see.png`).
- **Expected**: Command should return success (or at least surface a real capture error) once the screenshot is on disk.
- **Impact**: Blocks every downstream workflow that needs fresh UI element maps. Even `peekaboo see --app TextEdit` without `--path` fails with the same error, so agents can’t gather element IDs at all.
### Investigation log — Nov 11, 2025
- Replayed the capture pipeline inside `SeeCommand`: `saveScreenshot` writes to the requested path, after which we call `SnapshotManager.storeScreenshot` before any other snapshot persistence occurs.
- Traced `SnapshotManager.storeScreenshot` and found it copied the file into `.peekaboo/snapshots/<id>/raw.png` without ensuring the destination directory existed. The resulting `FileManager.copyItem` threw `NSCocoaErrorDomain Code=4 "The file “textedit-see.png” doesn’t exist."`, bubbling up as `INTERNAL_SWIFT_ERROR`.
### Resolution — Nov 12, 2025
- `SnapshotManager.storeScreenshot` now creates the per-snapshot directory before copying, standardizes the source URL, and reports a clearer file I/O error if the user-provided path truly disappears. `peekaboo see --path /tmp/foo.png --annotate --json-output` completes successfully and downstream element/snapshot storage works again.

## `see` now returns WINDOW_NOT_FOUND for Chrome despite saving screenshots
- **Command**: `polter peekaboo -- see --app "Google Chrome" --json-output`
- **Observed**: The capture pipeline runs, `peekaboo_see_1762952828.png` lands on the Desktop, but the CLI exits with `{ "code": "WINDOW_NOT_FOUND", "message": "App 'Google Chrome' is running but has no windows or dialogs" }`. Debug logs confirm ScreenCaptureKit grabbed the window (duration 171 ms) before the error fires.
- **Variant**: Adding `--window-title "New Tab"` now fails even earlier with `WINDOW_NOT_FOUND` while the window search logs “Found windows {count=6}” right before it bails—so the heuristic sees Chrome’s windows but insists none match.
- **Expected**: Once a screenshot is on disk, the command should return success and emit the snapshot/element list so agents can interact with secure login’s UI.
- **Impact**: secure login automation is stalled again—we can’t obtain element IDs or snapshot IDs even though Chrome’s window is visible and focusable.
- **Status — Nov 12, 2025 13:07**: Reproducible immediately after navigating to the login page; need to trace why `CaptureWindowWorkflow` thinks Chrome has zero windows while the capture step succeeds.
### Resolution — Nov 12, 2025 (evening)
- `ElementDetectionService` now calls `windowsWithTimeout()` when enumerating AX windows for the target application, ensuring we wait for Chrome’s helper processes to surface their windows before bailing. This removed the `WINDOW_NOT_FOUND` spurious error and the CLI now returns the normal snapshot payload (tested with `polter peekaboo -- see --app "Google Chrome" --json-output`).

## Screen capture fallback never reached legacy API
- **Command**: `polter peekaboo -- see --app "Google Chrome"` while ScreenCaptureKit returns `Failed to start stream due to audio/video capture failure`.
- **Observed**: The error surfaced immediately and the command aborted without ever trying the CGWindowList code path, even though `PEEKABOO_USE_MODERN_CAPTURE` is unset and legacy capture should be available.
- **Expected**: When ScreenCaptureKit flakes, the CLI should automatically retry with the legacy backend so automation keeps moving.
- **Impact**: Every `see` request in high-security workspaces fails outright, blocking screenshots, window metadata, and downstream menu/dialog commands.
### Resolution — Nov 12, 2025
- `ScreenCaptureFallbackRunner.shouldFallback` now retries with the legacy API for **any** modern failure (as long as a fallback API exists). Added inline logging so debuggers can find the correlation ID instantly.
- `ScreenCaptureServicePlanTests` now cover timeout errors, unknown errors, and the “all APIs failed” case so we don’t regress the fallback sequencing again.
- Result: `polter peekaboo -- see …` immediately switches to the legacy pipeline when ScreenCaptureKit raises the audio/video failure, and secure login automation proceeds with fresh snapshot IDs.

## CLI smoke tests — Nov 12, 2025 (afternoon)
- `polter peekaboo -- list apps --json-output`: Enumerated 50 running processes (9 with windows) in ~2 s, populated bundle IDs and window counts, and produced no warnings—list command output remains reliable for automation targeting.
- `polter peekaboo -- window list --app "Ghostty" --json-output`: Returned six entries (main terminal + helper overlays) with accurate bounds and PID metadata, confirming window enumeration still handles multi-process apps.
- `polter peekaboo -- space list --json-output`: Reported the single active Space (`id: 1`) without extra hints, so the space service responds even on single-desktop setups.
- `polter peekaboo -- dock list --json-output`: Listed 21 dock items (apps/folders/trash) with running state + bundle IDs, meaning dock inspection is healthy for downstream automation.


## `dialog` targeting drift (historical)
- The `dialog` CLI now shares the same first-class target flags as other interaction commands: `--app`/`--pid` plus optional `--window-title`/`--window-index` (instead of the older one-off `--window` flag).
- **Example**: `polter peekaboo -- dialog input --text "..." --app TextEdit --window-title "Save"`

## AXorcist logging broke every CLI build
- **Command**: `polter peekaboo -- type "Hello"` (or any other subcommand)
- **Observed**: Poltergeist failed the build instantly with `cannot convert value of type 'String' to expected argument type 'Logger.Message'` coming from `ElementSearch`/`AXObserverCenter`. Even a bare `swift build --package-path Apps/CLI` tripped on the same diagnostics, so no CLI binary could launch.
- **Expected**: Logger helper strings should compile cleanly; CLI builds should succeed without `--force`.
- **Impact**: All automation flows regressed—`polter peekaboo …` crashed before executing, preventing us from driving TextEdit or debugging dialog flows.
### Resolution — Nov 12, 2025
- Added a `Logging.Logger` convenience shim in `AXorcist/Sources/AXorcist/Logging/GlobalAXLogger.swift` so dynamic `String` messages are emitted as proper `Logger.Message` values.
- Updated `ElementSearch` logging helpers (`logSegments([String])`) and the `SearchVisitor` initializer to avoid illegal variadic splats and `let` reassignments.
- Fixed `AXObserverCenter`’s observer callback to call `center.logSegments/describePid` explicitly, preventing implicit `self` captures.
- Verified the end-to-end fix by running `swift build --package-path Apps/CLI` and `./scripts/poltergeist-wrapper.sh peekaboo -- type "Hello from CLI" --app TextEdit --json-output`, both of which now succeed without `--force`.

## Agent `--model` flag lost its parser
- **Command**: `swift test --package-path Apps/CLI --filter DialogCommandTests`
- **Observed**: Build failed with `value of type 'AgentCommand' has no member 'parseModelString'` because the helper that normalizes model aliases was deleted. That broke the CLI tests and meant `peekaboo agent --model ...` no longer validated user input.
- **Expected**: Human-facing aliases like `gpt`, `gpt-5.5`, or `claude-opus-4.7` should downcase to the supported defaults (`gpt-5.5` or `claude-opus-4.7`) so both tests and the runtime can enforce safe model choices.
### Resolution — Nov 12, 2025
- Reintroduced `AgentCommand.parseModelString(_:)`, delegating to `LanguageModel.parse` and whitelisting the current GPT-5.x/Claude 4.x/Gemini families. GPT variants map to `.openai(.gpt55)`, Claude variants map to `.anthropic(.opus47)`, Gemini variants map to `.google(.gemini31ProPreview)`, and unsupported providers still return `nil`.
- `swift test --package-path Apps/CLI --filter DialogCommandTests` now builds again (the filter currently matches zero tests, but the previous compiler failure is gone), and the helper is ready for the rest of the CLI to consume when we re-enable the `--model` flag.

## Element formatter missing focus/list helpers broke every build
- **Command**: `polter peekaboo -- type "ping"` (any CLI entry point)
- **Observed**: Poltergeist builds errored with `value of type 'ElementToolFormatter' has no member 'formatFocusedElementResult'` plus `missing argument for parameter #2 in call` (Swift tried to call libc `truncate`). The formatter file had an extra closing brace, so the helper functions lived outside the class and the compiler couldn’t find them.
- **Impact**: CLI binary never compiled, so none of the interaction commands (menu, secure login automation, etc.) could run.
### Resolution — Nov 12, 2025
- Restored `formatResultSummary` to actually return strings, reimplemented `formatFocusedElementResult`, and moved the list helper methods back inside `ElementToolFormatter`.
- Added a shared numeric coercion helper so frame dictionaries that report `Double`s still print their coordinates, and disambiguated `truncate` by calling `self.truncate`.
- Focused element summaries now include the owning app/bundle, so agents can confirm where typing will land.

## `see` command exploded: `AnnotatedScreenshotRenderer` missing
- **Command**: `polter peekaboo -- see --app "Google Chrome" --json-output`
- **Observed**: Every run failed to build with `cannot find 'AnnotatedScreenshotRenderer' in scope` after the renderer struct was moved below the `SeeTool` definition.
- **Impact**: Without a working `see` build, no automation snapshot could even start, so the secure login flow was blocked at the very first step.
### Resolution — Nov 12, 2025
- Hoisted `AnnotatedScreenshotRenderer` above `SeeTool` so Swift sees it before use and removed the duplicate definition at the bottom of the file.

## `list windows` silently emits nothing
- **Command**: `polter peekaboo list windows --app TextEdit`
- **Observed**: Exit status 0 but no stdout/stderr, regardless of `--json-output` or `--verbose`.
- **Expected**: Either a formatted window list or an explicit “no windows found” message / JSON payload.
- **Impact**: Prevents automation flows from enumerating windows to obtain IDs; also makes debugging focus issues impossible because there’s no feedback.
### Investigation log — Nov 11, 2025
- `ListCommand.WindowsSubcommand` always calls `print(CLIFormatter.format(output))`, so the lack of output meant the formatter returned an empty string.
- `CLIFormatter.formatWindowList` explicitly returned `""` whenever the windows array was empty, wiping both the one-line summary and any hints/warnings, so the CLI rendered nothing.
### Resolution — Nov 12, 2025
- `CLIFormatter` now emits `⚠️ No windows found for <app>` when the window array is empty and adds a generic “No output available” fallback if every section is blank. The JSON path was already correct, so no change needed there.

## Window geometry commands report stale dimensions
- **Commands**:
  - `polter peekaboo window set-bounds --app TextEdit --window-title "Untitled 5.rtf" --x 100 --y 100 --width 600 --height 500 --json-output`
  - `polter peekaboo window resize --app TextEdit --window-title "Untitled 5.rtf" --width 700 --height 550 --json-output`
- **Observed**: Each command visibly moves/resizes the window, but the JSON payload’s `new_bounds` echoes the *previous* invocation. Example: after `set-bounds` to `(100,100,600,500)`, running again with `--x 400 --y 400 --width 800 --height 600` still reports `{x:100,y:100,width:600,height:500}` even though the window now sits at `(400,400,800,600)`. Likewise, `window resize` reported the rectangle applied by the prior `set-bounds` call instead of the requested 700×550 region.
- **Expected**: `new_bounds` should match the rectangle we just applied for both commands.
- **Impact**: Automation scripts can’t trust the CLI output to confirm state; retries or verification steps will mis-report success.
### Next steps
1. Inspect `WindowCommand.SetBoundsSubcommand` and `WindowCommand.ResizeSubcommand` (or the shared window service) so success responses include the freshly applied bounds instead of cached state.
2. Add CLI regression tests asserting `new_bounds` equals the requested rectangle for both `set-bounds` and `resize`.
### Resolution — Nov 13, 2025
- `window resize` / `window set-bounds` now re-query the window list after each mutation before formatting JSON, so `new_bounds` reflects the rectangle that actually landed on screen. The CLI logger records refetch failures instead of silently returning stale caches.
- Added hermetic tests (`windowSetBoundsReportsFreshBounds`, `windowResizeReportsFreshBounds`) that run the commands against stub window services and assert the reported `new_bounds` matches the requested coordinates, preventing future regressions.

## Window focus builds died due to raw `Logger` strings
- **Command**: `polter peekaboo -- click --on elem_153 --snapshot <id> --json-output`
- **Observed**: Poltergeist reported `WindowManagementService.swift:589:30: error: cannot convert value of type 'String' to expected argument type 'OSLogMessage'` whenever we ran any CLI command that touched windows. The new `Logger` API refuses runtime strings.
- **Impact**: Every automation attempt triggered a rebuild failure before the command ran, so the secure login login flow (and anything else) couldn’t even begin.
### Resolution — Nov 12, 2025
- Wrapped the dynamic summary in string interpolation (`self.logger.info("\(message, privacy: .public)")`) so OSLog receives a literal and the compiler is satisfied.

## `menu list` fails with "Could not find accessibility element for window ID"
- **Command**: `polter peekaboo menu list --app TextEdit --json-output`
- **Observed**: After exercising other window commands (focus/move/set-bounds), `menu list` now crashes with `UNKNOWN_ERROR` and `Could not find accessibility element for window ID 798`. Re-focusing the TextEdit window doesn’t help; every `menu list` attempt errors with the same stale window ID even though the app is frontmost.
- **Expected**: Menu enumeration should succeed once the window (or app) is focused.
- **Impact**: Menu automation is unusable in long sessions—agents can’t inspect menus after other window operations because the CLI clings to a dead AX window reference.
### Next steps
1. Investigate `MenuCommand` / `MenuService` to ensure they refresh the AX window reference each invocation instead of reusing stale IDs.
2. Add a stress test: run `window move`/`focus`/`list` repeatedly and ensure a subsequent `menu list` still works.
### Update — Nov 12, 2025 15:10
- Retested via `polter peekaboo -- menu list --app "Google Chrome" --json-output` and the command now succeeds (1,200+ menu entries, zero warnings). The renderable-window heuristic that skips sub-30 px helper windows appears to have fixed the stale-window regression; keeping this entry for a few more passes in case it resurfaces.

## `menu click` fails with same stale window ID
- **Command**: `polter peekaboo menu click --app TextEdit --path File,New --json-output`
- **Observed**: Immediately after the `menu list` failure above, `menu click` also returns `UNKNOWN_ERROR` with `Could not find accessibility element for window ID 798`. Opening a new TextEdit document (to spawn a fresh window ID) simply changes the failing ID to `838`, confirming the CLI is caching dead AX handles between calls.
- **Expected**: `menu click` should re-resolve the window each time.
- **Impact**: No menu automation works once the cached window ID drifts.
### Next steps
Same as above—refresh AX window references inside `MenuCommand` and add regression coverage for both list & click paths.
### Update — Nov 12, 2025 15:10
- Follow-up run (`polter peekaboo -- menu click --app "Google Chrome" --path "Chrome > About Google Chrome" --json-output`) returned success and triggered the expected About panel, so the click path is healthy again after the window-selection fixes.

## `menu click` still fails with NotFound after window refresh
- **Command**: `polter peekaboo menu click --app TextEdit --path File,New --json-output`
- **Observed**: After restarting TextEdit and getting `menu list` working again, `menu click` now fails with `PeekabooCore.NotFoundError` (no stale window ID, but menu path resolution still breaks). Even `TextEdit,Preferences` fails with the same code.
- **Expected**: Menu paths should resolve when `menu list` succeeds.
- **Impact**: Click automation can’t drive menus even when enumeration works.
### Next steps
Investigate `MenuService.clickMenuPath` once `menu list` is fixed; ensure both stack traces share the same AX lookup logic.

## `menu click` fails in Calculator too
- **Command**: `polter peekaboo menu click --app Calculator --path View,Scientific --json-output`
- **Observed**: Even after a fresh `menu list` succeeds, clicking `View > Scientific` fails with `PeekabooCore.NotFoundError error 1.` The issue isn’t TextEdit-specific—Calculator shows the same behavior.
- **Impact**: Menu automation is effectively unusable across apps.
- **Next steps**: Once the stale-window-id issue is fixed, verify the click path is resolving menu nodes correctly (and add integration coverage for at least one stock app such as Calculator).

## `menu list` times out verifying Chrome
- **Command**: `polter peekaboo -- menu list --app "Google Chrome" --json-output`
- **Observed**: The command hangs for ~16 s and then fails with `Timeout while verifying focus for window ID 1528`. `window list --app "Google Chrome"` shows ID 1528 is a 642×22 toolbar shim (window index 7), yet the menu code keeps waiting for it to become the focused window instead of choosing the actual tab window (ID 1520).
- **Expected**: Menu tooling should apply the same “renderable window” heuristics as capture/focus (ignore windows with width/height < 10, alpha 0, or off-screen) before attempting to focus.
- **Impact**: All Chrome menu operations fail before producing output, so the secure login flow can’t drive menus (e.g., `Chrome > Hide Others`) at all.
- **Next steps**: Reuse `FocusUtilities`’ renderable-window logic (or share `ScreenCaptureService.firstRenderableWindowIndex`) in `MenuCommand` so helper/status windows never become the focus target.
### Resolution — Nov 12, 2025
- Updated `WindowIdentityInfo.isRenderable` to treat windows smaller than 50 px in either dimension as non-renderable, so focus/menu logic now skips Chrome’s 22 px toolbar shims. `menu list --app "Google Chrome" --json-output` completes again and returns the full menu tree.
- **Verification — Nov 12, 2025 15:10**: Re-ran the command on the latest build and confirmed it now finishes in <1 s, producing the entire menu hierarchy without timeouts.

## `dialog list` can’t find TextEdit’s sheet
- **Command**: `polter peekaboo -- dialog list --app TextEdit --json-output`
- **Observed**: Returns `NO_ACTIVE_DIALOG` even when a Save sheet is frontmost (spawned via `⌘S`). Supplying `--window-title "Save"` didn’t help at the time; the CLI immediately errored without debug logs.
- **Expected**: Once the app hint is provided, the dialog service should fall back to AX search/CG metadata (same as `dialog input`) and enumerate buttons/fields.
- **Impact**: Agents can’t inspect dialog contents before attempting clicks/inputs, so complex sheets remain blind spots.
- **Next steps**: Instrument `DialogService.resolveDialogElement` to log every fallback attempt, ensure `ensureDialogVisibility` respects the `app` hint, and add a regression test that opens TextEdit’s Save panel through native AX actions and runs `dialog list`.
- **Update — Nov 12, 2025 16:25**: Running a freshly built CLI (`swift run --package-path Apps/CLI peekaboo dialog list --app TextEdit --window-title Save --json-output`) returns the Save dialog metadata (buttons array contains “Save”). `polter peekaboo …` still used an old binary at the time, so we needed to bounce Poltergeist once the CLI changes landed.
- **Resolution — Nov 13, 2025**: The runner now enforces the `polter peekaboo -- …` separator and errors if CLI flags (like `--window-title` or `--force`) appear before it, so Poltergeist can’t swallow dialog options anymore. `DialogCommandTests` cover the `--window-title` JSON path, and the `dialogDismissForce` test keeps the forced-dismiss output verified in CI.
- **Investigation — Nov 12, 2025 16:10**: Plumbed `--app` hints through the CLI into `DialogService` and added window-identity fallbacks, but `AXFocusedApplication` still returns `nil` even after focusing TextEdit. Logs show repeated “No focused application found,” so the service needs an alternative path (e.g., resolve via `WindowManagementService`/`WindowIdentityService` without relying on the global AX focused app).

## Window focus reports INTERNAL_SWIFT_ERROR instead of WINDOW_NOT_FOUND
- **Command**: `polter peekaboo window focus --app Finder --json-output`
- **Observed**: When Finder’s dock tile has no “real” AX window, the command returns `{ code: "INTERNAL_SWIFT_ERROR", message: "Could not find accessibility element for window ID 91" }`.
- **Expected**: It should surface a structured `.WINDOW_NOT_FOUND` error (matching the rest of the CLI) so agents can fall back to `window list` or `app focus`.
- **Impact**: Automations have to pattern-match brittle strings to detect “window missing” vs. actual internal failures.
### Update — Nov 12, 2025 15:46
- `polter peekaboo -- window focus --app "Google Chrome" --json-output` now succeeds and reports the focused window title/bounds, so the focus pathway handles helper-rich apps again. Leaving the entry open until we add automated coverage for the Finder edge case described above.

## Help surface is unreachable
- Root help instructs users to run `peekaboo help <subcommand>` or `<subcommand> --help`, but:
  - `polter peekaboo help window` → `Error: Unknown command 'help'`
  - `polter peekaboo image --help` → `Error: Unknown option --help`
  - Even `polter peekaboo click --help` gets intercepted by `polter`’s own help instead of reaching Peekaboo.
- **Impact**: There is no discoverable way to read per-command usage/flags from the CLI, which leaves agents guessing (and documentation contradicting reality).
### Investigation log — Nov 11, 2025
- Commander only injected verbose/json/log-level flags; `help` wasn’t registered as a command and `--help`/`-h` were treated as unknown options, so the router rejected every attempt before `CommandHelpRenderer` could run.
### Resolution — Nov 12, 2025
- `CommanderRuntimeRouter` now strips the executable name, intercepts `help`, `--help`, and `-h` tokens, renders help for the requested path (or prints a root command table), and exits with `ExitCode.success`. Users can once again discover per-command signatures straight from the CLI.

### Next steps I'd suggest
1. Add regression tests for `SnapshotManager.storeScreenshot` that cover relative paths, missing directories, and annotated captures so the copy guardrails stay in place.
2. Backfill CLI integration coverage for `peekaboo window list` (text + JSON) to guarantee the warning footer appears when no windows are detected.
3. Extend `CommandHelpRenderer` output (and docs) with richer examples/subcommand tables so the new help plumbing doubles as user-facing reference material.

## `menu list` produces no output at all
- **Command**: `polter peekaboo menu list --app Finder --json-output`
- **Observed**: Command exits 0 but emits zero bytes (even when piping to a file). Adding `-v` prints a stray `1.7.3` and still no JSON/text.
- **Impact**: The entire menu-inspection surface is unusable—agents can’t enumerate menus to click, and scripts can’t consume JSON.
- **Hypothesis**: We successfully focus Finder and retrieve the AX menu structure, but `outputSuccessCodable` never fires because `MenuServiceBridge.listMenus` probably hits a runtime-only type that can’t be converted, short-circuiting before printing. Need to instrument `ListSubcommand` to confirm and add tests that assert JSON is printed.
### Additional findings — Nov 12, 2025
- `menu click` behaves the same (totally silent, exit 0). Because both subcommands share the same runtime plumbing, it’s likely that the Commander binder never injects runtime options into `MenuCommand` (so stdout is being swallowed or the program returns before printing). Since `menu list-all` does output correctly, the bug is isolated to `ListSubcommand`/`ClickSubcommand`.
- **Resolution — Nov 12, 2025**: `ApplicationResolvablePositional` used to override `var app` with `var app: String? { app }`, which immediately recursed and crashed every positional command (menu/app/window, etc.). The protocol now exposes a separate `positionalAppIdentifier` and the subcommands map their `app` argument to it, so the commands run normally (and emit JSON errors when Finder has no visible window instead of segfaulting).
- **Remaining gap (Nov 12, 2025)**: Even with the crash fixed, `menu list --app Finder` still fails with “No windows found” whenever Finder has only the menubar showing. We should allow menu enumeration without a target window (Finder’s menus exist even if no browser windows are open).
### Retest — Nov 13, 2025 00:03 GMT
- Closed every Finder window so only the menubar remained, then ran `polter peekaboo menu list --app Finder --json-output`.
- The command now returns the full menu structure (File/Edit/View/etc.), and the JSON payload matches Finder’s menus despite the lack of foreground windows.
- ✅ This confirms the Nov 12 focus fallbacks persisted; no additional action needed unless a future regression brings back the `WINDOW_NOT_FOUND` error.

## `menubar list` returns placeholder names
- **Command**: `polter peekaboo menubar list --json-output`
- **Observed**: Visible status items like Wi‑Fi or Focus are present, but most entries show `title: "Item-0"` / `description: "Item-0"`, which is meaningless.
- **Impact**: Agents can’t rely on human-friendly titles to choose items, so they can’t click menu extras deterministically.
- **Suggestion**: Surface either the accessibility label or the NSStatusItem’s button title instead of the placeholder, and include bundle identifiers for menu extras where possible.
### Status — Nov 13, 2025
- Menu extras are now merged with window-derived metadata first, so when CGWindow provides a real title (e.g., Wi‑Fi/Bluetooth) we keep it even if AX later reports `Item-#`.
- `MenuService` exposes the owning bundle, owner name, and identifier fields through `menubar list --json-output`, giving agents enough context to scope searches (`bundle_id: "com.apple.controlcenter"` makes it obvious which entries come from Control Center).
- Added `MenuServiceTests` covering the fallback-preference behavior plus a GUID regression (`humanReadableMenuIdentifier` + `makeDebugDisplayName`) so placeholder regressions are caught in CI (swift-testing target `MenuServiceTests`).
- AXorcist’s CF-type downcasts are now `unsafeDowncast`, so `swift test --package-path Core/PeekabooCore --filter MenuServiceTests` completes cleanly instead of dying in ValueUnwrapper/ValueParser.
- Control Center GUIDs now flow through a preference-backed lookup (`ControlCenterIdentifierLookup`) and the fallback merge prefers owner names whenever the raw title looks like a GUID/`Item-#`. The new debug-only helper `makeDebugDisplayName` lets tests poke the private formatter directly.
- When we can’t extract a friendly title (no identifier, placeholder raw title), the CLI now emits `Control Center #N` so list output remains deterministic and agents have a stable handle even before a better label is available. Those synthetic names are accepted by `menubar click` (e.g., `polter peekaboo menubar click "Control Center #3"` focuses the third status icon); the command’s result still surfaces the original description (`Menu bar item [3]: Control Center`).
- After restarting Poltergeist (`tmux` + `pnpm run poltergeist:haunt`) and letting it rebuild both targets, `polter peekaboo menubar list --json-output` reflects the new formatter in the running CLI (the `#N` suffixes show up immediately instead of the old GUIDs). This confirms the CLI picks up the formatter changes once the daemon rebuilds the targets.

## `window focus` reports INTERNAL_SWIFT_ERROR instead of WINDOW_NOT_FOUND
- **Command**: `polter peekaboo window focus --app Finder --json-output`
- **Observed**: When Finder’s dock tile has no “real” AX window, the command returns `{ code: "INTERNAL_SWIFT_ERROR", message: "Could not find accessibility element for window ID 91" }`.
- **Expected**: It should surface a structured `.WINDOW_NOT_FOUND` error (matching the rest of the CLI) so agents can fall back to `window list` or `app focus`.
- **Impact**: Automations have to pattern-match brittle strings to detect “window missing” vs. actual internal failures.

## `agent --list-sessions` used to crash due to eager MCP init
- **Command**: `polter peekaboo agent --list-sessions --json-output`
- **Observed (before fix)**: Launching the CLI triggered the Peekaboo SwiftUI app to start, which then broke inside `NSHostingView` layout (SIGTRAP). The root cause was that we bootstrapped Tachikoma MCP (spawning the GUI) even when the user only wanted metadata.
- **Resolution — Nov 12, 2025**: The CLI now handles `--list-sessions` before touching MCP/logging setup, so it queries the agent service without launching the app or requiring credentials. Repeat runs return JSON instantly.

## `clean --dry-run` returned INTERNAL_SWIFT_ERROR on validation failure
- **Command**: `polter peekaboo clean --dry-run --json-output`
- **Observed**: Leaving out `--all-snapshots/--snapshot/--older-than` produced `{ "success": false, "code": "INTERNAL_SWIFT_ERROR" }` even though it’s a user mistake.
- **Resolution — Nov 12, 2025**: CleanCommand now throws `ValidationError` and emits `VALIDATION_ERROR` in JSON (matching the CLI guidelines). Added regression tests would still be useful.

## `menu list` fails when the target app only provides a menubar
- **Command**: `polter peekaboo menu list --app Finder --json-output`
- **Observed**: Command exited with `UNKNOWN_ERROR` and message `No windows found for application 'Finder'`, even though Finder’s menus are accessible through the menubar.
- **Expected**: Menu enumeration should succeed whenever an application exposes a menu bar, regardless of whether it has an open document window.
- **Impact**: Finder and similar background apps remain unreachable by `peekaboo menu`, leaving menu automation helpless for those targets.
### Investigation log — Nov 12, 2025
- `MenuCommand` called `ensureFocused` with the default focus options, which in turn invoked `FocusManagementService.findBestWindow`. Finder’s menubar-only state triggered `FocusError.noWindowsFound`, so the command threw before reaching `MenuServiceBridge.listMenus`.
- The helper was always configured with auto-focus enabled, so every menu subcommand ran the same path.
### Resolution — Nov 12, 2025
- Added `ensureFocusIgnoringMissingWindows` in `MenuCommand` so menu operations log and skip focus when `FocusError.noWindowsFound` occurs.
- `menu list`/`menu click` now work for Finder even when no document windows exist; the command output continues once the focus guard silently falls through.

## `menubar list` shows generic titles like Item-0 instead of real labels
- **Command**: `polter peekaboo menubar list`
- **Observed**: Most entries had `title: "Item-0"` (and similar placeholders) even though the corresponding icons have descriptive accessibility labels.
- **Expected**: Use the accessibility tree title/help strings so the JSON/text output names items properly (e.g., Wi-Fi, Control Center, Bluetooth).
- **Impact**: Agents cannot target status items reliably because the CLI output never exposes their real names.
### Investigation log — Nov 12, 2025
- `MenuService.listMenuExtras` appended the window-based heuristics first, then only added accessibility-discovered extras if their positions didn’t collide. The heuristic window entries had `AXWindowOwnerName` values such as `Item-0`, so those entries dominated the JSON output.
- We needed a deterministic, testable merge strategy rather than relying on whichever source ran first.
- Ice’s menu manager taught us to pair bundle IDs with names when labeling extras, so we could swap the fallback data for accessibility strings like “Wi-Fi”, “Focus”, and “Control Center” when they share a position.
### Resolution — Nov 12, 2025
- Reordered `listMenuExtras` to prioritize accessible extras and introduced `MenuService.mergeMenuExtras` to deduplicate by position before appending fallback windows.
- Added `MenuServiceTests` to verify the merge logic keeps accessibility titles (Wi-Fi, Control Center) and only adds fallback entries when new positions appear.
- `MenuExtraInfo` now stores the raw title, bundle, and owner metadata so the CLI can map `com.apple.controlcenter` → “Control Center”, `com.apple.Siri` → “Siri”, etc., and we skip duplicates whenever a new entry overlaps an already-rendered location.

## `menubar list` now includes raw metadata
- **Command**: `polter peekaboo menubar list --json-output`
- **Observed**: Beyond the friendly display string, downstream automation needed the raw bundle/title/owner info for analytics and status item indexing.
- **Resolution — Nov 12, 2025**: `MenuBarItemInfo` now exposes `rawTitle`, `bundleIdentifier`, and `ownerName`, and the JSON schema includes `raw_title`, `bundle_id`, `owner_name` so callers can schedule more precise actions.

## `menu list --json-output` now also reports owner name
- **Command**: `polter peekaboo menu list --json-output`
- **Observed**: Scripts needed a consistent `owner_name` for the targeted app, not just the app title and bundle ID.
- **Resolution — Nov 12, 2025**: The JSON response now returns `owner_name` (set to the resolved application name) alongside `bundle_id`, mirroring the menubar metadata so downstream consumers can use the same schema for both commands.

## Menu structure now carries owner metadata in every node
- **Motivation**: Future tooling may need bundle/owner context even for submenu entries, not just the root app. Adding it to `Menu`/`MenuItem` makes the JSON tree richer without extra API calls.
- **Resolution — Nov 12, 2025**: `Menu` and `MenuItem` structs now expose `bundle_id`/`owner_name`, and the CLI JSON output includes them for every node (the menu command now ships `bundle_id`/`owner_name` alongside `title` for menus and items). Services still populate those fields from the resolved `ServiceApplicationInfo`, so even deeply nested menu entries keep the same owner metadata.

## `window focus` reports INTERNAL_SWIFT_ERROR instead of WINDOW_NOT_FOUND
- **Command**: `polter peekaboo window focus --app Finder --json-output`
- **Observed**: `FocusSubcommand` returned `{ "code": "INTERNAL_SWIFT_ERROR", "message": "Could not find accessibility element for window ID 91" }` when the window could not be focused.
- **Expected**: The CLI should surface `WINDOW_NOT_FOUND` so scripts can detect a missing window and respond (e.g., open a new document).
- **Impact**: Automation flows must parse brittle error strings instead of relying on structured error codes, making retry logic fragile.
### Investigation log — Nov 12, 2025
- `ensureFocused` bubbled up `FocusError.axElementNotFound`, but `ErrorHandlingCommand` only mapped `PeekabooError` and `CaptureError` to structured codes; `FocusError` defaulted to `INTERNAL_SWIFT_ERROR`.
- We needed an explicit mapping from every `FocusError` case to the proper CLI error code.
### Resolution — Nov 12, 2025
- `ErrorHandlingCommand.mapErrorToCode` now intercepts `FocusError` and defers to `errorCode(for:)`, ensuring `WINDOW_NOT_FOUND`, `APP_NOT_FOUND`, or `TIMEOUT` as appropriate.
- Added `FocusErrorMappingTests` to lock in the mapping (including `axElementNotFound` → `WINDOW_NOT_FOUND` and `focusVerificationTimeout` → `TIMEOUT`).

## `type` silently succeeds without a focused field
- **Command**: `polter peekaboo type "Hello"` (no `--app`, no active snapshot)
- **Observed**: CLI prints `✅ Typing completed`, but no characters arrive in TextEdit because nothing ensured the insertion point was active.
- **Expected**: Typing should still be possible for advanced users who deliberately inject keystrokes, but the CLI should warn when it cannot guarantee focus.
### Resolution — Nov 12, 2025
- `TypeCommand` now keeps “blind typing” available yet logs a warning when neither `--app` nor `--snapshot` is supplied under auto-focus. Users still get their keystrokes, but the CLI explicitly suggests running `peekaboo see` or specifying `--app` first so the experience is less confusing.

## Dialog commands ignore macOS Open/Save panels
- **Command**: `polter peekaboo dialog click --button "New Document"`
- **Observed**: `No active dialog window found` even while an `NSOpenPanel` sheet is frontmost (TextEdit’s “New Document / Open” panel).
- **Expected**: Dialog service should treat `NSOpenPanel`/`NSSavePanel` sheets as dialogs so button clicks and file selection work.
### Resolution — Nov 12, 2025
- `DialogService` now inspects `AXFocusedWindow`, recurses through `AXSheets`, checks `AXIdentifier` for `NSOpenPanel`/`NSSavePanel`, and matches titles like “Open”, “Save”, “Export”, or “Import”. Both `dialog list` and `dialog click` successfully locate the TextEdit open panel.

## Mac build blocked by outdated logging APIs
- **Context**: Swift 6.2 tightened `Logger` usage so interpolations must be literal `OSLogMessage` strings. PeekabooServices, ScrollService, and the visualizer receiver still used legacy `Logger.Message` concatenations, producing errors like `'Logger' is ambiguous` and “argument must be a string interpolation” during `./scripts/build-mac-debug.sh`.
- **Resolution — Nov 12, 2025**: Reworked those sites to log with inline interpolations (or `OSLogMessage` where needed) and removed privacy specifiers from plain `String` helpers. With the rewrites the mac target links successfully again.

## SpaceTool used legacy window schema
- **Command**: building the `space` MCP tool inside `PeekabooCore`
- **Observed**: Compilation failed (`ServiceWindowInfo` has no member `window_id/window_title`) because the tool still referenced the older CLI `WindowInfo` structure.
- **Impact**: macOS builds failed before we could run any CLI automation.
- **Resolution — Nov 12, 2025**: Updated `SpaceTool` to accept the new `ServiceWindowInfo`, convert the integer ID to `UInt32`, and emit the camelCase fields when describing move results. The space MCP command now compiles alongside the CLI again.

## `list screens` broke CLI builds after UnifiedToolOutput migration
- **Command**: `polter peekaboo list screens --json-output` (or any CLI build invoking `ListCommand`)
- **Observed**: Swift compiler error `Highlight has no member HighlightKind` because the new `UnifiedToolOutput` nests `HighlightKind` one level higher. The CLI still referenced the legacy type alias, so Poltergeist marked the `peekaboo` target failed and no CLI commands could run.
- **Resolution — Nov 12, 2025**: Pointed the summary builder at the new `.primary` enum case (instead of the deleted `Highlight.HighlightKind`), restoring the CLI build and allowing screen listings again.
- **Verification — Nov 12, 2025**: `polter peekaboo -- list screens --json-output` now returns the expected JSON payload (session `LISTSCREENS-20251112T1300Z`) without triggering a rebuild.

## `list apps` reports zero windows for every process
- **Command**: `polter peekaboo -- list apps --json-output`
- **Observed**: Every application’s `windowCount` is reported as `0`, and the summary shows `appsWithWindows: 0` / `totalWindows: 0` even though Chrome, Finder, etc., have visible windows (confirmed via `list windows --app "Google Chrome"` which reports 22 windows). This regression appeared right after the UnifiedToolOutput refactor.
- **Expected**: `list apps` should include accurate per-application window counts so agents can pick an app with open windows.
- **Impact**: Automation must issue a slow `list windows` call per bundle just to discover if anything is on screen, adding seconds to workflows like the secure login login flow.
- **Resolution — Nov 12, 2025**: `ApplicationService` now counts windows per process (AX first, falling back to CG-renderable windows) before returning `ServiceApplicationInfo`, so the CLI reports accurate numbers. Verified via `polter peekaboo -- list apps --json-output` (run at 13:25) which listed 7 apps with 22 total windows instead of all zeros.

## `dock hide` never returns
- **Command**: `polter peekaboo dock hide`
- **Observed**: Command times out after ~10 s because the AppleScript call to System Events waits for automation approval.
- **Expected**: Dock hide/show should complete quickly without extra permissions.
### Resolution — Nov 12, 2025
- DockService now toggles `com.apple.dock autohide` via `defaults` and restarts the Dock process instead of driving System Events. We also skip the write entirely if the Dock is already in the requested state, so `dock hide`/`dock show` finish in <1 s.

## Dialog commands need faster feedback
- **Command**: `polter peekaboo dialog list --json-output` (no `--app` hint)
- **Observed**: Even with the Open panel visible, the CLI spent ~8s enumerating every running app before returning.
- **Expected**: A user-supplied application hint should skip the global crawl and focus the dialog faster.
### Resolution — Nov 12, 2025
- Added `--app <Application>` to every dialog subcommand (`click/input/file/dismiss/list`). When provided, the CLI focuses that app (and optional window title) before calling DialogService, so the service immediately inspects the correct AX tree. Dialog commands still work without the hint, but now advanced users can cut the worst-case search time down to ~1s.

## Regression coverage for dialog CLI
- **Command**: `swift test --filter DialogCommandTests`
- **Observed**: The existing dialog tests only checked help output, leaving JSON regressions undetected.
- **Expected**: Unit tests should validate the CLI’s JSON payloads without requiring TextEdit to be open.
### Resolution — Nov 12, 2025
- `StubDialogService` can now return canned `DialogElements`/`DialogActionResult` and record button clicks. New harness tests exercise `dialog list --json-output` and `dialog click --json-output` against the stub so the serializer and runner stay verified without manual GUI setup.

## `window focus` keeps targeting Chrome’s zero-size windows
- **Command**: `polter peekaboo -- window focus --app "Google Chrome" --json-output`
- **Observed**: Focus automation always returns `WINDOW_NOT_FOUND` even when Chrome has visible tabs. `window list` shows 13 entries, but the first several windows have zero width/height (IDs `0`, `1`, `951`, `950`, …). `window focus` keeps picking those phantom windows (even when `--window-index 4` is provided), then fails while looking up accessibility metadata for window ID `949`.
- **Expected**: The focus service should skip “non-renderable” windows (layer != 0, alpha == 0, width/height < 10) and land on the first real tab—exactly what the new `ScreenCaptureService` heuristics already do.
- **Impact**: Agents can’t reliably bring Chrome forward before typing, so hotkeys like `cmd+l` end up in Ghostty or another terminal and URL navigation derails immediately.
- **Next step**: Reuse the renderable-window heuristics from `ScreenCaptureService` inside `FocusManagementService.findBestWindow` so we never return ID `0` for Chrome/Safari helper windows.
- **Resolution — Nov 12, 2025**: `WindowManagementService` now selects the first renderable AX window (bounds ≥50 px, non-minimized, layer 0) before focusing, and `WindowIdentityService` falls back to AX-only enumeration when Screen Recording is missing. `window focus --app "Google Chrome"` returns the real tab window again, and the command succeeds without needing `--window-index`.

## `menu click` still throws APP_NOT_FOUND unless `--no-auto-focus` is set
- **Command**: `polter peekaboo -- menu click --app "TextEdit" --path "File > Open…" --json-output`
- **Observed**: After the new focus fallbacks landed, every menu subcommand now fails with `APP_NOT_FOUND`/`Failed to activate application: Application failed to activate`. `ensureFocused` skips the AX-based window focus (because `FocusManagementService` still bails on window ID lookups) and ends up calling `PeekabooServices().applications.activateApplication`, which returns `.operationError` even though TextEdit is already running. The error is rethrown before `MenuServiceBridge` ever attempts the click.
- **Impact**: Menu automation regressed to 0 % success—agents have to add `--no-auto-focus` and manually run `window focus` before every menu command, otherwise secure login’s Chrome menus are unreachable.
- **Workaround — Nov 12, 2025**: `polter peekaboo -- window focus --app <App>` followed by `menu … --no-auto-focus` works because it bypasses the failing activation path.
- **Resolution — Nov 12, 2025 (afternoon)**: `ApplicationService.activateApplication` no longer throws when `NSRunningApplication.activate` returns false, so the focus cascade doesn’t abort menu commands. Default `menu click/list` now succeed again without `--no-auto-focus`.

## Hidden login form is invisible to Peekaboo
- **Command sequence** (all via Peekaboo CLI):
  1. `polter peekaboo -- app launch "Google Chrome" --wait-until-ready`
  2. `polter peekaboo -- hotkey --keys "cmd,l"` → `type "<login URL>" --return`
  3. `polter peekaboo -- see --app "Google Chrome" --json-output` (snapshot `38D6B591-…`)
  4. `polter peekaboo -- click --snapshot 38D6B591-… --id elem_138` (`Sign In With Email`)
  5. `polter peekaboo -- type "<test email>"`, `--tab`, `type "<test password>"`, `type --return`
- **Observed**:
  - Every `see` snapshot (`38D6B591-…`, `810AA6D6-…`, `021107B0-…`, `9ADE4207-…`) reports **zero** `AXTextField` nodes. The UI map only contains `AXGroup`/`AXUnknown` entries with empty labels, so neither `click --id` nor text queries can reach the email/password inputs.
  - OCR of the captured screenshots (e.g. `~/Desktop/Screenshots/peekaboo_see_1762929688.png`) only shows the 1Password prompt plus “Return to this browser to keep using secure login. Log in.” There is no detectable “Email” copy in the bitmap, explaining why the automation never finds a field to focus.
  - Attempting scripted fallbacks—typing JavaScript into devtools and `javascript:(...)` URLs via Peekaboo—still leaves the page untouched because `document.querySelector('input[type="email"]')` returns `null` in this environment.
- **Impact**: We can open Chrome, navigate to the hosted login form, and click “Sign In With Email”, but we can’t populate the fields or detect success, so the requested automation remains blocked.
- **Ideas**:
  1. Detect when `see` only finds opaque `AXGroup` nodes and fall back to image-based hit-testing or WebKit’s accessibility snapshot.
2. Auto-dismiss the 1Password overlay (which currently steals focus) before capturing so the underlying form becomes visible.
3. If secure login truly relies on passwordless links, document that flow and teach Peekaboo how to parse the follow-up dialog so agents can continue.
- **Progress — Nov 13, 2025**: `ElementDetectionService` now promotes editable `AXGroup`s (or ones whose role description mentions “text field”) to `textField` results. This gives us a fighting chance once secure login’s web view actually exposes editable descendants, and the same heuristics help other hybrid UIs that wrap inputs inside groups.
- **Progress — Nov 13, 2025 (late)**: Playground now ships a deterministic “Hidden Web-style Text Fields” fixture (see `HiddenFieldsView`) and `SeeCommandPlaygroundTests.hiddenFieldsAreDetected` (run with `RUN_LOCAL_TESTS=true`) verifies `peekaboo see --app Playground --json-output` keeps returning those promoted `.textField` entries. Next: script the Chrome permission bubble the same way.
- **Retest — Nov 14, 2025 02:34 UTC**: `polter peekaboo -- see --app "Google Chrome" --json-output --path /tmp/secure-login.png` (snapshot `A3CF1910-FE78-4420-9527-BD7FDC874E90`) still reports zero `textField` roles even though 204 elements are detected overall; screenshot + UI map stored under `~/.peekaboo/snapshots/A3CF1910-FE78-4420-9527-BD7FDC874E90/`. No observable email/password inputs yet, so we remain blocked on real-world reproduction despite the Playground coverage.
- **Retest — Nov 14, 2025 03:05 UTC (vercel.com/login)**: Same result against a different login flow (`polter peekaboo -- see --app "Google Chrome" --json-output --path /tmp/vercel-login.png`) where we typed `https://vercel.com/login` via `type --app "Google Chrome" … --return`. Session `B4355B11-417A-43AF-BA25-AEB3B8837388` contains 648 UI nodes but zero `textField` roles, confirming the gap isn’t limited to the earlier customer-specific site.
- **Retest — Nov 14, 2025 03:10 UTC (github.com/login)**: Repeated the workflow against GitHub’s login page (`type --app "Google Chrome" "https://github.com/login" --return` + `see --json-output --path /tmp/github-login.png`, snapshot `E8390C6E-7D29-4021-9364-4A46936F8E19`). Result: 204 elements detected, none with `role == "textField"`, even though Accessibility Inspector reports both the username and password inputs with `AXTextField/AXSecureTextField`. The heuristics still miss real-world text fields despite the Playground fixture success.
- **Retest — Nov 14, 2025 03:25–03:33 UTC (stripe.com/login + instagram.com/login)**: Stripe auto-focused its email field, so `BF63D068-7A2D-4D6B-A910-42777FCE85D7` shows the expected `AXTextField` entries (email + password). Instagram initially returned only the omnibox field, but once we scripted a `click --coords 1500,600` before running `see`, snapshot `EDEED86F-8CCF-429B-A7FE-BC8FCBE4CA5B` surfaced three `AXTextField` nodes (username, password, URL bar). Conclusion: some flows only expose their embedded login form to AX after focus enters the iframe. That focus-changing fallback is now opt-in with `--web-focus`; prefer the browser MCP DOM when available.
- **Status — Nov 12, 2025**: Repeated scroll attempts (`peekaboo scroll --snapshot … --direction down --amount 8`) do not reveal any additional accessibility nodes; every capture still lacks text fields, so we remain blocked on discovering a tabbable input.
- **Update — Nov 12, 2025 (evening)**: Quitting `1Password` removes the save-login modal, but the secure login web app still displays “Return to this browser to keep using secure login. Log in.” with no text fields or form controls exposed through AX (or visible via OCR). The flow appears to require a magic-link email that we can’t access, so we remain blocked on entering the provided password.

- `SeeCommandPlaygroundTests.hiddenFieldsAreDetected` also asserts that the Playground “Permission Bubble Simulation” fixture exposes “Allow”/“Don’t Allow” button labels, so the fallback heuristics are exercised in automation.
- `ElementLabelResolverTests` keep the heuristic locked in—if we ever regress to the old “button” placeholder (or lose the child-text fallback), CI will fail.

## `app launch` leaves already-running apps in the background
- **Command**: `polter peekaboo -- app launch "Google Chrome" --wait-until-ready`
- **Observed**: When Chrome is already running, macOS simply returns the existing `NSRunningApplication` and the CLI exits after printing “Launched Google Chrome (PID: …)”, but the browser never comes to the foreground. The next `type` command ends up in Terminal (or whatever was previously focused), which is exactly what happened during the secure-login reproduction above.
- **Expected**: Launching (or re-launching) an app through the CLI should focus it by default so follow-up commands interact with the intended window. Advanced users should be able to opt-out when they truly need a background launch.
- **Resolution — Nov 14, 2025**: `app launch` now activates the returned `NSRunningApplication` unless the new `--no-focus` flag is supplied. The helper calls `app.activate(options: [])` even if the process is already running, so existing Chrome/Safari sessions jump to the front before the CLI prints success. Commander binding tests cover the new flag, and a warning is logged only if AppKit refuses the activation request.
- **Next steps**: Update the CLI docs/help text with an example that highlights `--no-focus`, and keep nudging agents to pass `--app` to `type` so blind typing warnings stay rare. Work with the automation harness to ensure future secure-login runs always start with an explicit `app launch` + `type --app "Google Chrome"` combo.

## `dialog` commands log focus errors even when they succeed
- **Command**: `polter peekaboo dialog list --app TextEdit --json-output`
- **Observed**: The command completes and returns dialog metadata, but logs `Dialog focus hint failed for TextEdit … Failed to perform focus window`.
- **Expected**: When the dialog actions succeed, the command shouldn’t emit scary warnings—especially during `dialog click`/`dialog list` where the sheet is clearly frontmost.
- **Impact**: Noise in verbose logs makes it hard to spot real failures and may spook agents watching stderr.
- **Next step**: Treat `FocusError.windowNotFound` as informational for sheet-attached dialogs, or skip the hint entirely when the dialog window is already resolved via AX.
- **Resolution — Nov 12, 2025**: The focus hint now silently skips logging when the only failure is `FocusError.windowNotFound`, so successful dialog runs no longer spam stderr. The hint still logs other focus failures for real debugging.
- **Update — Nov 12, 2025 (afternoon)**: Also suppress `PeekabooError.operationError` results so the “Failed to perform focus window” noise disappears. Confirmed with `polter peekaboo dialog list --app TextEdit --json-output --force` and `dialog click --app TextEdit --button Cancel --json-output --force`; both now return empty `debug_logs`.

## Dialog commands silently return `NO_ACTIVE_DIALOG`
- **Command**: `polter peekaboo -- dialog list --app TextEdit --json-output`
- **Observed**: Even with TextEdit’s Open panel up (launched via ⌘O), the CLI exits with `PeekabooCore.DialogError error 1` (`NO_ACTIVE_DIALOG`). There’s no hint about which heuristics failed, so it looks like nothing was attempted.
- **Expected**: When no dialog is present we should either auto-focus the target window and retry, or at least print guidance (“Open panel not detected; run \`peekaboo window focus\` first”) instead of a bare error code.
- **Impact**: Agents can’t enumerate or interact with dialogs—the command just errors out even when a system Open/Save sheet is on screen.
- **Next steps**: Add better diagnostics (log the last window IDs checked, screenshot path, etc.) and ensure `DialogService` is looking at the correct window hierarchy before returning `NO_ACTIVE_DIALOG`.
- **Status — Nov 12, 2025**: Retested via `polter peekaboo dialog list --app TextEdit --json-output --force` and the no-target variant `dialog list --json-output --force`; both return the Open sheet metadata cleanly (buttons, text field, role) so the `NO_ACTIVE_DIALOG` condition is no longer reproducible for this flow.

## Visualizer logging regression broke mac builds (Nov 12, 2025)
- **Command**: `./scripts/build-mac-debug.sh`
- **Observed**: Swift 6.2 flagged dozens of `implicit use of 'self'` errors plus `cannot convert value of type 'String' to expected argument type 'OSLogMessage'` across `Apps/Mac/Peekaboo/Services/Visualizer/VisualizerCoordinator.swift` and `VisualizerEventReceiver.swift`. The new Visualizer files leaned on temporary string variables and unlabeled closures, so Xcode refused to compile the mac target.
- **Expected**: Visualizer should build cleanly so the mac app stays shippable.
- **Resolution — Nov 12, 2025**: Prefixed every property/method reference with `self`, moved the animation queue closures to explicitly capture `self`, and replaced raw string variables with logger interpolations (`self.logger.info("\(message, privacy: .public)")`). `VisualizerEventReceiver` now logs errors via direct interpolation instead of concatenating `OSLogMessage`s, so both ScreenCaptureKit and legacy capture paths compile again.

## AXorcist action handlers drifted from real APIs (Nov 12, 2025)
- **Command**: `./scripts/build-mac-debug.sh`
- **Observed**: `AXorcist/Sources/AXorcist/Core (AXorcist+ActionHandlers.swift)` failed with “value of type 'AXorcist' has no member 'locateElement'” plus type mismatches because the helper extension used a `private extension` (hiding methods from the rest of the file) and assumed `PerformActionCommand.action` was an `AXActionNames` enum instead of a `String`.
- **Expected**: AXorcist’s perform-action and set-focused-value handlers should compile under Swift 6 and drive element lookups directly.
- **Resolution — Nov 12, 2025**: Rewrote the handlers to call `findTargetElement` just like the query commands, switched validation/execute helpers to take raw `String` action names, and removed the `Result<Element, AXResponse>` helper that tried to use `AXResponse` as `Error`. Action logging now consistently uses `ValueFormatOption.smart`, so AXorcist builds again.

## Session title generator mis-parsed provider list (Nov 12, 2025)
- **Command**: `./scripts/build-mac-debug.sh`
- **Observed**: `Apps/Mac/Peekaboo/Services/SessionTitleGenerator.swift` expected `ConfigurationManager.getAIProviders()` to return `[String]`, so Swift complained about “cannot convert value of type 'String' to expected argument type '[String]'`.
- **Resolution — Nov 12, 2025**: Split the comma-separated provider string into lowercase tokens before passing them into the model-selection helper. The generator now compiles inside the mac target.

## Mac app build still blocked on StatusBar SwiftUI files (Nov 12, 2025)
- **Command**: `./scripts/build-mac-debug.sh`
- **Observed**: After fixing Visualizer, AXorcist, Permissions logging, and SessionTitleGenerator, Xcode now dies later with `MenuDetailedMessageRow.swift`, `StatusBarController.swift`, and `UnifiedActivityFeed.swift`. The errors mirror the earlier logger issues (concatenating `OSLogMessage`s and mismatched tool-type parameters), so the mac build still exits 65 even though the rest of the tree compiles.
- **Next steps**: Audit the StatusBar files for lingering `Logger` misuse and type mismatches (e.g., feed `PeekabooChatView` real `[AgentTool]?` arrays). Once those files match Swift 6’s stricter logging APIs, rerun `./scripts/build-mac-debug.sh` to confirm `Peekaboo.app` builds.

## AXObserverManager helpers missing during mac build (Nov 12, 2025)
- **Command**: `./scripts/build-mac-debug.sh`
- **Observed**: `SwiftCompile ... AXObserverManager.swift` still crashes with `value of type 'AXObserverManager' has no member 'attachNotification'` even though the helpers exist. Local `swift build --package-path AXorcist` succeeds, so the failure is specific to the Xcode workspace build.
- **Hypothesis**: The mac app’s build graph seems to use a stale SwiftPM artifact or a parallel copy of AXorcist that wasn’t updated when we rewrote the helpers. Nuking `.build/DerivedData` and rebuilding didn’t help; Xcode still reports the missing methods while the standalone package compiles fine.
- **Next steps**:
  1. Inspect the generated `AXorcist.SwiftFileList`/`axPackage.build` inside `.build/DerivedData` to see which copy of `AXObserverManager.swift` the workspace references.
  2. If the workspace vendored an older checkout, re-point the dependency to the in-tree `AXorcist` path or refresh the workspace’s SwiftPM pins.
  3. As a fallback, move the helper logic entirely inline inside `addObserver` so even the stale copy compiles.

## SpaceTool + formatter fallout blocking mac build (Nov 12, 2025)
- **Command**: `./scripts/build-mac-debug.sh`
- **Observed**: After fixing the AX observer + UI formatters, the build now fails deeper in PeekabooCore: `SpaceTool.swift` was still written against the pre-renamed `WindowInfo` fields (`title`, `windowID`) and helper methods defined outside the struct, so Swift 6 complained about missing members and actor isolation. Cleaning that up surfaced the next blocker: `SystemToolFormatter.swift` still had a literal newline in `parts.joined(separator: "\n")` that Swift sees as an unterminated string. Once that’s fixed, the build should advance to whatever is next in the queue.
- **Impact**: macOS target can’t link yet, so we still can’t run `peekaboo-mac` nor smoke test the CLI end-to-end inside the app bundle.
- **Next steps**:
  1. Finish porting `SpaceTool` to the new `WindowInfo` schema (done: helper methods now live inside a `private extension`, using `window_title` / `window_id`).
  2. Replace the newline separator in `SystemToolFormatter` with an escaped literal (`"\n"`) so Swift’s parser doesn’t choke.
  3. Re-run `./scripts/build-mac-debug.sh` to discover the next blocker in the chain.
### Resolution — Nov 13, 2025
- `SpaceTool` now depends on a `SpaceManaging` abstraction, letting tests inject a fake CGS service while production keeps using `SpaceManagementService`. Its move-window paths re-query `ServiceWindowInfo` so metadata returns `window_title`, `window_id`, `target_space_number`, etc., matching the new schema.
- Added `SpaceToolMoveWindowTests` (CLI test target) that run the tool under stubbed `PeekabooServices` and assert both metadata and CGS calls for `--to_current` and `--follow` flows, so regressions surface in CI before mac builds break again.

## `menu click` rejected nested paths when passed via --item
- **Command**: `polter peekaboo menu click --app Finder --item "View > Show View Options"`
- **Observed**: The CLI treated the entire string as a flat menu title, so Finder returned `MENU_ITEM_NOT_FOUND` even though the user clearly provided a nested path. Only `--path` worked, which tripped up agents/autoscripts that default to `--item`.
- **Impact**: Any automation that copied menu paths directly (with `>` separators) silently failed unless engineers rewrote the command by hand.
- **Resolution — Nov 13, 2025**: `menu click` now normalizes inputs: if `--item` contains `>`, it’s transparently treated as a path and logged (info-level) so users see `Interpreting --item value as menu path: …`. JSON output includes the same log via debug entries. Regression covered by `MenuCommandSelectionNormalizationTests` in `Apps/CLI/Tests/CoreCLITests/MenuCommandTests.swift`.

## `dialog list` pretended success when no dialog was present
- **Command**: `polter peekaboo dialog list --app TextEdit --json-output` with no sheet open.
- **Observed**: The CLI returned `{ role: "AXWindow", title: "" }` and reported success, so automations had to manually inspect the payload (which was empty) to realize nothing was on screen.
- **Impact**: Scripts built guardrails around the command, defeating the point of having structured error codes (`NO_ACTIVE_DIALOG`). The MCP dialog tool inherited the same silent-success behavior, confusing agents that depend on Peekaboo’s diagnostics.
- **Resolution — Nov 13, 2025**: `DialogService.listDialogElements` now inspects the resolved AX window: if the role/subrole pair looks like a normal window and there are no dialog-specific controls (buttons/text fields/accessory controls), it throws `DialogError.noActiveDialog`. The CLI propagates that error as `NO_ACTIVE_DIALOG`, matching the rest of the dialog command family.
- **Tests**: `DialogServiceTests.testListDialogElements` now expects the method to throw when no dialog is showing, so future regressions get caught immediately.

## `--force` flag swallowed by polter wrapper
- **Command**: `polter peekaboo dialog dismiss --app TextEdit --force --json-output`
- **Observed**: Poltergeist treated `--force` as its own “run stale build” flag, so the peekaboo CLI never saw it. The command proceeded as a non-force dismiss, searched for buttons, and failed with `{ code: "UNKNOWN_ERROR", message: "No dismiss button found in dialog." }`, which made it look like the dialog API was broken.
- **Impact**: Any CLI option that overlaps with polter’s global flags (`--force`, `--timeout`, etc.) silently disappears unless users remember to insert `--` between polter arguments and CLI arguments. This catches even experienced engineers during quick smoke tests.
- **Reminder (Nov 13, 2025)**: When running peekaboo via polter and you need CLI flags that begin with `-`/`--`, pass them after a double dash:
  - `polter peekaboo -- dialog dismiss --force ...`
  - `polter peekaboo -- menu click --item "View > Show View Options"`
  This pushes everything after `--` directly to the CLI binary, preserving flags exactly.
### Resolution — Nov 13, 2025
- Always include the separator: `./scripts/poltergeist-wrapper.sh peekaboo -- dialog dismiss --force` so Poltergeist doesn’t swallow dialog options.
- Added `DialogCommandTests.dialogDismissForce` to verify the CLI path handles `--force` (and reports the `escape` method) whenever the flag reaches us. Together, the guard + test prevent future regressions in both tooling and CLI behavior.
