# Playground Tool Test Log

## 2026-05-07

### Live verification after desktop-observation refactor
- **Setup**:
  - Built the Playground with `swift build --package-path Apps/Playground`.
  - Confirmed permissions with `./Apps/CLI/.build/debug/peekaboo permissions status --json`.
  - Targeted only the owned Playground app (`boo.peekaboo.playground.debug`).
- **Capture / observation**:
  - `./Apps/CLI/.build/debug/peekaboo list windows --app boo.peekaboo.playground.debug --json`
  - `./Apps/CLI/.build/debug/peekaboo image --app boo.peekaboo.playground.debug --window-title "Click Fixture" --path .artifacts/live-verify/current/click-fixture.png --json`
  - `./Apps/CLI/.build/debug/peekaboo see --app boo.peekaboo.playground.debug --window-title "Click Fixture" --json`
  - Result: window enumeration, image capture, and AX detection succeeded. The host screen currently reports `scaleFactor: 1`, so `--retina` and native `screencapture -l` both produced `1200x832` for the Click Fixture; this machine cannot reproduce a 2x Retina delta.
- **Interactions verified through Playground OSLog**:
  - Click: `peekaboo click --snapshot <id> --on elem_7 --app boo.peekaboo.playground.debug --json` logged `Single click on 'Single Click' button`.
  - Type/press/hotkey: click `basic-text-field`, `peekaboo type "peekaboo typed 123" --clear`, `peekaboo press return`, then `peekaboo hotkey --keys "cmd,a"` and type again. Logs confirmed text changes and submit.
  - Scroll: `peekaboo scroll --direction down --amount 6 --snapshot <id> --on elem_6` logged a vertical offset change.
  - Move: `peekaboo move --snapshot <id> --on elem_30 --duration 200 --steps 8` logged `Mouse entered probe area` and `Mouse moved over probe area`.
  - Drag: `peekaboo drag --from elem_8 --to elem_21 --snapshot <id> --duration 500 --steps 20` logged Item A dragging, hover over zones, and drop in zone3.
  - Swipe: `peekaboo swipe --from elem_112 --to elem_116 --snapshot <id> --duration 500 --steps 18` logged `Swipe right`.
  - Dialog: opened the Dialog Fixture with `peekaboo hotkey --keys "cmd,ctrl,8"`, clicked `Show Alert`, `peekaboo dialog list --app boo.peekaboo.playground.debug --json`, then `peekaboo dialog click --button OK --app boo.peekaboo.playground.debug --json`. Logs confirmed alert dismissal.
  - Clipboard: `peekaboo clipboard save --slot codex-live-verify`, set/get/verify text, then `restore` returned the prior clipboard payload.
- **Performance sample**:
  - `Apps/Playground/scripts/peekaboo-perf.sh --name list-windows-playground --runs 8 --log-root .artifacts/live-verify/perf --bin ./Apps/CLI/.build/debug/peekaboo -- list windows --app boo.peekaboo.playground.debug --json-output`: mean wall `0.232s`, p95 `0.275s`, no failures.
  - `Apps/Playground/scripts/peekaboo-perf.sh --name see-click-fixture --runs 6 --log-root .artifacts/live-verify/perf --bin ./Apps/CLI/.build/debug/peekaboo -- see --app boo.peekaboo.playground.debug --window-title "Click Fixture" --json-output`: mean wall `1.165s`, p95 `1.254s`, no failures.
  - `Apps/Playground/scripts/peekaboo-perf.sh --name image-click-fixture --runs 6 --log-root .artifacts/live-verify/perf --bin ./Apps/CLI/.build/debug/peekaboo -- image --app boo.peekaboo.playground.debug --window-title "Click Fixture" --path .artifacts/live-verify/perf/image-click-fixture.png --json-output`: mean wall `1.257s`, p95 `1.403s`, no failures.
- **Notes**:
  - `move --duration` is milliseconds; `--duration 0.2` correctly fails as an integer parse error, while `--duration 200` succeeds.
  - Concurrent `see`/`image` samples stayed green after the shared desktop-observation process gate fix.

## 2025-11-16

### ✅ `see` command – initial Playground capture failure (resolved)
- **Command**: `polter peekaboo -- see --app Playground --path .artifacts/playground-tools/20251116-074900-see.png --json-output`
- **Artifacts**: `.artifacts/playground-tools/20251116-074900-see.json`
- **Result**: This was failing on 2025-11-16 with `INTERNAL_SWIFT_ERROR` (“Failed to start stream due to audio/video capture failure”) when only a 64×64 stub window was visible (see `.artifacts/playground-tools/20251116-075220-window-list-playground.json`).
- **Resolution**: The ScreenCaptureKit fallback fix below restored reliable captures; keep this section as historical context.

### ✅ `see` command – ScreenCaptureKit fallback restored
- **Command**: `polter peekaboo -- see --app Playground --json-output --path .artifacts/playground-tools/20251116-082056-see-playground.png`
- **Artifacts**: `.artifacts/playground-tools/20251116-082056-see-playground.{json,png}`
- **Result**: Successfully recorded snapshot `5B5A2C09-4F4C-4893-B096-C7B4EB38E614` (301 UI elements). Screenshot shows ClickTestingView at full size; CLI debug logs still mention helper windows that are filtered out.
- **Notes**: Fix involved re-enabling the ScreenCaptureKit window path in `Core/PeekabooCore/Sources/PeekabooAutomation/Services/Capture/ScreenCaptureService.swift` so CGWindowList becomes the fallback instead of the primary path. Audio/video capture failures have not reproduced since the change.

### ✅ `image` command – Window + screen captures
- **Command(s)**:
  - `polter peekaboo -- image --app Playground --mode window --path .artifacts/playground-tools/20251116-045847-image-window-playground.png`
  - `polter peekaboo -- image --mode screen --screen-index 0 --path .artifacts/playground-tools/20251116-045900-image-screen0.png`
- **Artifacts**: `.artifacts/playground-tools/20251116-045847-image-window-playground.png`, `.artifacts/playground-tools/20251116-045900-image-screen0.png`
- **Verification**: Window capture shows ClickTestingView controls with sharp text; screen capture shows the entire desktop including Playground window on Space 1. CLI output confirms saved paths; no analyzer prompt used.
- **Notes**: Captures completed in <1s each; no focus issues observed while Playground remained frontmost.

### ✅ `image` command – window + screen capture after fallback fix
- **Command(s)**:
  - `polter peekaboo -- image window --app Playground --json-output --path .artifacts/playground-tools/20251116-082109-image-window-playground.png`
  - `polter peekaboo -- image screen --screen-index 0 --json-output --path .artifacts/playground-tools/20251116-082125-image-screen0.png`
- **Artifacts**: `.artifacts/playground-tools/20251116-082109-image-window-playground.{json,png}`, `.artifacts/playground-tools/20251116-082125-image-screen0.{json,png}`
- **Verification**: Both commands succeed after the ScreenCaptureKit-first change; debug logs report the helper “window too small” entries but the main Playground window captures at 1200×852 and the screen snapshot matches desktop state.
- **Notes**: These runs double-confirm that the capture fix benefits `image` as well as `see`; Playground logs contain `[Window] image window Playground` + `[Window] image screen frontmost` from `AutomationEventLogger`.

### ✅ `scroll` command – ScrollTestingView vertical + horizontal (with `--on` targets)
- **Setup**: Hotkeyed to the Scroll & Gesture tab (`polter peekaboo -- hotkey --keys "cmd,option,4"`), then captured `.artifacts/playground-tools/20251116-194615-see-scrolltab.json` (snapshot `649EB632-ED4B-4935-9F1F-1866BB763804`).
- **Commands**:
  1. `polter peekaboo -- scroll --direction down --amount 6 --on vertical-scroll --snapshot 649EB632-… --json-output > .artifacts/playground-tools/20251116-194652-scroll-vertical.json`
  2. `polter peekaboo -- scroll --direction right --amount 4 --on horizontal-scroll --snapshot 649EB632-… --json-output > .artifacts/playground-tools/20251116-194708-scroll-horizontal.json`
  3. `./Apps/Playground/scripts/playground-log.sh -c Scroll --last 10m --all -o .artifacts/playground-tools/20251116-194730-scroll.log`
- **Artifacts**: The two CLI JSON blobs above confirm success, and the Playground log shows the paired `[Scroll] direction=down` / `[Scroll] direction=right` entries emitted by `AutomationEventLogger`.
- **Notes**: Playground now exposes `vertical-scroll` / `horizontal-scroll` identifiers (via `ScrollAccessibilityConfigurator` + `AXScrollTargetOverlay`) and the snapshot cache preserves them, so `scroll --on …` works without pointer-relative fallbacks.

### ✅ `drag` command – DragDropView covered via element IDs
- **Setup**:
  - Added `PlaygroundTabRouter` as an environment object plus a header “Go to Drag & Drop” control so the UI mirrors the underlying tab selection.
  - `see` output always includes the “Drag & Drop” tab radio button (elem_79). Running `polter peekaboo -- click --snapshot <see-id> --on elem_79` reliably switches the TabView to DragDropView, yielding IDs such as `elem_15` (“Item A”) and `elem_24` (“Drop here”).
- **Commands**:
  1. `polter peekaboo -- click --snapshot BBF9D6B9-26CB-4370-8460-6C8188E7466C --on elem_79`
  2. `polter peekaboo -- drag --snapshot BBF9D6B9-26CB-4370-8460-6C8188E7466C --from elem_15 --to elem_24 --duration 800 --steps 40`
  3. `polter peekaboo -- drag --snapshot BBF9D6B9-26CB-4370-8460-6C8188E7466C --from elem_17 --to elem_26 --duration 900 --steps 45 --json-output`
- **Artifacts**:
  - `.artifacts/playground-tools/20251116-085142-see-afterclick-elem79.{json,png}` (Drag tab `see` output with identifiers)
  - `.artifacts/playground-tools/20251116-085233-drag.log` (Playground + CLI Drag OSLog entries)
  - `.artifacts/playground-tools/20251116-085346-drag-elem17.json` (CLI drag result with coords/profile)
- **Verification**: Playground log shows “Started dragging: Item A”, “Hovering over zone1”, and “Item dropped… zone1” for the first run, and the CLI JSON confirms the second run’s coordinates/profile. Post-drag screenshots display Item A/B inside their target drop zones. Coordinate-only drags remain as a fallback, but the default regression loop now uses element IDs + snapshot IDs for determinism.

### ✅ `list` command suite – apps/windows/screens/menubar/permissions
- **Command(s)**: captured `list apps`, `list windows --app Playground`, `list screens`, `list menubar`, `list permissions` (all with `--json-output`)
- **Artifacts**:
  - `.artifacts/playground-tools/20251116-045915-list-apps.json`
  - `.artifacts/playground-tools/20251116-045919-list-windows-playground.json`
  - `.artifacts/playground-tools/20251116-045931-list-screens.json`
  - `.artifacts/playground-tools/20251116-045933-list-menubar.json`
  - `.artifacts/playground-tools/20251116-045936-list-permissions.json`
- **Verification**: Playground identified as bundle `boo.peekaboo.mac.debug` with six windows; menubar payload includes Wi-Fi and Clock items; permissions report Accessibility + Screen Recording both granted.
- **Notes**: Each command completed <3s. No additional log capture necessary; JSON artifacts are sufficient evidence.

### ✅ `tools` command – native catalog
- **Command(s)**:
  - `polter peekaboo -- tools --json-output > .artifacts/playground-tools/20251219-001215-tools.json`
- **Verification**: JSON enumerates all built-in tools referenced in docs; tool count matches the MCP server catalog.
- **Notes**: No Playground interaction needed; artifacts captured for comparison when new tools land.

### ✅ `clipboard` command – file/image set/get + cross-invocation save/restore
- **Fixes validated (2025-12-17)**:
  - Commander binder now maps `--file-path`/`--image-path`/`--data-base64`/`--also-text` correctly for `peekaboo clipboard`.
  - `clipboard save/restore` now persists across separate CLI invocations in local mode by storing the slot in a dedicated named pasteboard; `restore` clears the slot afterward.
- **Commands**:
  1. `polter peekaboo -- clipboard save --slot original --json`
  2. `polter peekaboo -- clipboard set --file-path /tmp/peekaboo-clipboard-smoke.txt --json`
  3. `polter peekaboo -- clipboard set --file-path assets/peekaboo.png --also-text "Peekaboo clipboard image smoke" --json`
  4. `polter peekaboo -- clipboard get --prefer public.png --output /tmp/peekaboo-clipboard-out.png --json`
  5. `polter peekaboo -- clipboard restore --slot original --json`
- **Artifacts**: `.artifacts/playground-tools/20251217-192349-clipboard-{save-original,set-file,get-file-text,set-image,get-image,restore-original}.json`
- **Result**: Exported `/tmp/peekaboo-clipboard-out.png` is non-empty, and the final restore returns the user clipboard to its pre-test state.

### ✅ `run` command – playground-smoke script
- **Script**: `docs/testing/fixtures/playground-smoke.peekaboo.json` (focus Playground → open Text Fixture via `⌘⌃2` → `see` frontmost → click "Focus Basic Field" → type "Playground smoke")
- **Command**: `polter peekaboo -- run docs/testing/fixtures/playground-smoke.peekaboo.json --output .artifacts/playground-tools/20251217-173849-run-playground-smoke.json --json-output`
- **Artifacts**:
  - `.artifacts/playground-tools/20251217-173849-run-playground-smoke.json`
  - `.artifacts/playground-tools/run-script-see.png`
  - `.artifacts/playground-tools/20251217-173849-run-playground-smoke-{keyboard,click,text}.log`
- **Verification**: Execution report shows 6/6 steps succeeded; the fixture hotkey removes TabView flakiness and the Playground logs confirm the click + text update.
- **Notes**: Script parameters use the flat JSON form documented by `peekaboo run` (for example, `{"app":"Playground","foreground":false}`). Legacy `generic._0` wrappers still decode for compatibility.

### ✅ `sleep` command – timing verification
- **Command**: `python - <<'PY' … subprocess.run(["pnpm","run","peekaboo","--","sleep","2000"]) …` (see shell history)
- **Result**: CLI reported `✅ Paused for 2.0s`; wrapper measured ≈2.24 s wall-clock, matching expectation.
- **Notes**: No Playground interaction required; documented timing in `docs/testing/tools.md` under the `sleep` recipe.

### ✅ `clean` command – snapshot pruning
- **Commands**:
  1. `polter peekaboo -- see --app Playground --path .artifacts/playground-tools/20251116-0506-clean-see1.png --annotate --json-output` → snapshot `5408D893-E9CF-4A79-9B9B-D025BF9C80BE`
  2. `polter peekaboo -- see --app Playground --path .artifacts/playground-tools/20251116-0506-clean-see2.png --annotate --json-output` → snapshot `129101F5-26C9-4A25-A6CB-AE84039CAB04`
  3. `polter peekaboo -- clean --snapshot 5408D893-E9CF-4A79-9B9B-D025BF9C80BE`
  4. `polter peekaboo -- clean --snapshot 5408D893-E9CF-4A79-9B9B-D025BF9C80BE` (expect 0 removals)
- **Verification**: First clean freed 453 KB and removed the snapshot directory; second clean confirmed nothing left to delete. As of 2025-12-17, snapshot-scoped commands now return `SNAPSHOT_NOT_FOUND` after cleanup (instead of a misleading `ELEMENT_NOT_FOUND`).
- **Artifacts**: `.artifacts/playground-tools/20251116-050631-clean-see1{,_annotated}.png`, `.artifacts/playground-tools/20251116-050649-clean-see2{,_annotated}.png`, and CLI outputs in shell history.
  - Regression artifacts:
    - `.artifacts/playground-tools/20251217-201134-click-snapshot-missing.json`
    - `.artifacts/playground-tools/20251217-201134-move-snapshot-missing.json`
    - `.artifacts/playground-tools/20251217-201134-scroll-snapshot-missing.json`
    - `.artifacts/playground-tools/20251217-202239-snapshot-missing-drag.json`
    - `.artifacts/playground-tools/20251217-202239-snapshot-missing-swipe.json`
    - `.artifacts/playground-tools/20251217-202239-snapshot-missing-type.json`
    - `.artifacts/playground-tools/20251217-202239-snapshot-missing-hotkey.json`
    - `.artifacts/playground-tools/20251217-202239-snapshot-missing-press.json`

### ✅ `permissions` command – status snapshot
- **Command**: `polter peekaboo -- permissions status --json-output > .artifacts/playground-tools/20251116-051000-permissions-status.json`
- **Verification**: JSON shows Screen Recording (required) + Accessibility (optional) both granted; no remedial steps needed.
- **Notes**: No Playground UI change expected; just keep the artifact for future reference.

### ✅ `config` command – show/validate
- **Commands**:
  - `polter peekaboo -- config show --effective --json-output > .artifacts/playground-tools/20251116-051200-config-show-effective.json`
  - `polter peekaboo -- config validate`
- **Verification**: Config reports OpenAI key present (masked), providers list `anthropic/claude-sonnet-4-5-20250929` + `ollama/llava:latest`, defaults/logging sections intact. Validation succeeded with all sections checked.
- **Notes**: No Playground interaction required.

### ✅ `learn` command – agent guide dump
- **Command**: `polter peekaboo -- learn > .artifacts/playground-tools/20251116-051300-learn.txt`
- **Verification**: File contains the full agent prompt, tool catalog, and commit metadata matching current build; no runtime errors.
- **Notes**: Useful baseline for future diffs when system prompt changes.

### ✅ `click` command – Playground targeting
- **Preparation**: Logged clicks via `.artifacts/playground-tools/20251116-051025-click.log`; captured fresh snapshot `263F8CD6-E809-4AC6-A7B3-604704095011` (`.artifacts/playground-tools/20251116-051120-click-see.{json,png}`) after focusing Playground.
- **Commands**:
  1. `polter peekaboo -- click "Single Click" --snapshot BE9FF9B6-…` (hit Ghostty due to focus loss) → reminder to focus Playground first.
  2. `polter peekaboo -- app switch --to Playground`
  3. `polter peekaboo -- click --on elem_6 --snapshot 263F8CD6-…` (clicked View Logs button)
  4. `polter peekaboo -- click --coords 600,500 --snapshot 263F8CD6-…`
  5. `polter peekaboo -- click --on elem_disabled --snapshot 263F8CD6-…` (expected elementNotFound error)
- **Verification**: Playground log file shows the clicks (e.g., `[Click] single click on _SystemTextFieldFieldEditor ...`); disabled-ID click produced the expected error prompt.
- **Notes**: Legacy `B1` IDs no longer match; rely on `elem_*` IDs from current `see` output. Always re-focus Playground before coordinate clicks to avoid hitting other apps.

### ✅ `type` command – TextInputView coverage
- **Logs**: `.artifacts/playground-tools/20251116-051202-text.log`
- **Snapshot**: `263F8CD6-E809-4AC6-A7B3-604704095011` from `.artifacts/playground-tools/20251116-051120-click-see.json`
- **Commands**:
  1. `polter peekaboo -- click "Focus Basic Field" --snapshot 263F8CD6-…`
  2. `polter peekaboo -- type "Hello Playground" --clear --snapshot 263F8CD6-…`
  3. `polter peekaboo -- type --tab 1 --snapshot 263F8CD6-…`
  4. `polter peekaboo -- type "42" --snapshot 263F8CD6-…`
  5. `polter peekaboo -- type "bad" --profile warp` (validation error)
- **Verification**: Logs show “Basic text changed…” and numeric field entries; tab-only command shifted focus before typing digits. Validation rejected invalid profile value as expected.
- **Notes**: Type command relies on focused element; helper button keeps tests deterministic.

### ✅ `press` command – key sequence testing
- **Logs**: `.artifacts/playground-tools/20251116-090455-keyboard.log`
- **Snapshot**: `C106D508-930C-4996-A4F4-A50E2E0BA91A` (`.artifacts/playground-tools/20251116-090141-see-keyboardtab.{json,png}`)
- **Commands**:
  1. `polter peekaboo -- click "Focus Basic Field" --snapshot 11227301-…`
  2. `polter peekaboo -- press return --snapshot 11227301-…`
  3. `polter peekaboo -- press up --count 3 --snapshot 11227301-…`
  4. `polter peekaboo -- press foo` (now errors with `Unknown key: 'foo'`)
- **Verification**: Return + arrow presses show up in Playground logs (Key pressed: Return / Up Arrow). Invalid tokens now fail fast thanks to a validation call at runtime; continue watching for any other unmapped keys.

### ✅ `menu` command – top-level and nested items
- **Logs**: `.artifacts/playground-tools/20251116-195020-menu.log`
- **Artifacts**:
  - `.artifacts/playground-tools/20251116-195020-menu-click-action.json`
  - `.artifacts/playground-tools/20251116-195024-menu-click-submenu.json`
  - `.artifacts/playground-tools/20251116-195022-menu-click-disabled.json`
- **Commands**:
  1. `polter peekaboo -- menu click --path "Test Menu>Test Action 1" --app Playground`
  2. `polter peekaboo -- menu click --path "Test Menu>Submenu>Nested Action A" --app Playground`
  3. `polter peekaboo -- menu click --path "Test Menu>Disabled Action" --app Playground`
- **Findings**: Enabled items fire and log `[Menu] Test Action…` entries, while the disabled command exits with `INTERACTION_FAILED` (“Menu item is disabled: Test Menu > Disabled Action”), matching expectations. Context menus remain future work (menu click currently targets menu-bar entries only).

### ✅ `hotkey` command – modifier combos
- **Logs**: `.artifacts/playground-tools/20251116-051654-keyboard-hotkey.log`
- **Snapshot**: `11227301-05DE-4540-8BE7-617F99A74156`
- **Commands**:
  1. `polter peekaboo -- hotkey --keys "cmd,shift,l" --snapshot 11227301-...`
  2. `polter peekaboo -- hotkey --keys "cmd,1" --snapshot 11227301-...`
  3. `polter peekaboo -- hotkey --keys "foo,bar"`
- **Verification**: Keyboard logs show the expected characters (L/1) with timestamps matching the commands. Invalid combo correctly errors with `Unknown key: 'foo'`.

### ✅ `scroll` command – offsets + `--on` identifiers (resolved)
- **Resolved on 2025-12-17**: Use the Scroll Fixture window + `scroll --on vertical-scroll|horizontal-scroll`; the Scroll log records content offsets.
- **Notes**:
  - Nested targets exist as `nested-inner-scroll` and `nested-outer-scroll`; the CLI logs show the `target=...` field when you exercise them.
  - The Playground now logs nested inner/outer content offsets as well (rebuild Playground from latest sources to pick up the new `Nested … scroll offset` log lines).
- **2025-12-18 rerun**:
  - Found + fixed a real-world focus failure: `see` snapshots can have `windowID=null`, which previously caused auto-focus to no-op (so scroll/click could land in other frontmost apps even when you passed `--app Playground`).
  - After the fix, re-verified Scroll Fixture E2E by intentionally bringing Ghostty frontmost, then driving the fixture solely via snapshot IDs and scroll targets.
- **Artifacts**:
  - `.artifacts/playground-tools/20251218-012323-scroll.log`

### ✅ `bridge` command – unauthorized host responses are structured (no EOF)
- **Problem**: When a Bridge host rejected the CLI (TeamID allowlist), the host could close the socket without replying; the CLI surfaced this as `internalError` / “Bridge host returned no response”.
- **Fix (2025-12-18)**: `PeekabooBridgeHost` now reads the request and replies with a JSON `PeekabooBridgeResponse.error` (`unauthorizedClient`) before closing. This avoids EOF ambiguity and makes `peekaboo bridge status` errors actionable.
- **Regression test**: `Apps/CLI/Tests/CoreCLITests/PeekabooBridgeHostUnauthorizedResponseTests.swift`.
  - `.artifacts/playground-tools/20251218-012323-click-scroll-bottom.json`, `.artifacts/playground-tools/20251218-012323-click-scroll-top.json`, `.artifacts/playground-tools/20251218-012323-click-scroll-middle.json`
  - `.artifacts/playground-tools/20251218-012323-scroll-vertical-down.json`, `.artifacts/playground-tools/20251218-012323-scroll-horizontal-right.json`

### ✅ `swipe` command – gesture logs (resolved)
- **Resolved on 2025-12-17**: GestureArea now logs swipe direction + distance for deterministic verification.
- **2025-12-18 rerun**: Verified swipe-right plus long-press hold using the Scroll Fixture gesture tiles.
- **Artifacts**: `.artifacts/playground-tools/20251218-012323-gesture.log`, `.artifacts/playground-tools/20251218-012323-swipe-right.json`, `.artifacts/playground-tools/20251218-012323-long-press.json`

## 2025-12-18

### ✅ `click --coords` invalid input crash (fixed)
- **Repro**: `polter peekaboo -- click --coords , --json-output` crashed with `Fatal error: Index out of range` in `ClickCommand.run(using:)` when coordinate parsing ran without validation.
- **Fix**: `ClickCommand.run(using:)` now calls `validate()` up front and uses `parseCoordinates` with a guarded error instead of force-unwrapping.
- **Regression**: `Apps/CLI/Tests/CoreCLITests/ClickCommandCoordsCrashRegressionTests.swift` asserts the command returns `EXIT_FAILURE` (no crash).

### ✅ `window list` duplicate window IDs (fixed)
- **Issue**: `polter peekaboo -- window list --app Playground --json-output` could include duplicate entries for the same `window_id` (especially with multiple fixture windows open), which made scripts unstable.
- **Fix**: `ObservationTargetResolver` now deduplicates windows by `windowID` after applying standard renderability filters.
- **Evidence**: `.artifacts/playground-tools/20251218-022217-window-list-playground-dedup.json` (no duplicate `window_id` values).

### ✅ `menu click` (Fixtures window open)
- **Goal**: Verify `peekaboo menu click` works against realistic nested menu paths with spaces, not just the synthetic “Test Menu”.
- **Command**: `polter peekaboo -- menu click --app Playground --path "Fixtures > Open Window Fixture" --json-output`.
- **Verification**: Playground Window log shows a “Window became key” entry for “Window Fixture”.
- **Artifacts**: `.artifacts/playground-tools/20251218-021541-menu-open-windowfixture.json`, `.artifacts/playground-tools/20251218-021541-window.log`.

### ✅ `capture` command (live + video ingest)
- **Live (window)**: `polter peekaboo -- capture live --mode window --app Playground --duration 1 --threshold 0 --path .artifacts/.../capture-live-window-fast --json-output`
  - **Artifacts**: `.artifacts/playground-tools/20251218-024517-capture-live-window-fast.json`, `.artifacts/playground-tools/20251218-024517-capture-live-window-fast/` (kept frames + `contact.png` + `metadata.json`).
  - **Notes**: Capturing by app/window no longer stalls ~10s; the run now respects short `--duration` values again.
- **Video ingest**: Generated `/tmp/peekaboo-capture-src.mp4` (ffmpeg testsrc2), then ran `polter peekaboo -- capture video /tmp/peekaboo-capture-src.mp4 --sample-fps 4 --no-diff --path .artifacts/.../capture-video --json-output`.
  - **Artifacts**: `.artifacts/playground-tools/20251218-022826-capture-video.json`, `.artifacts/playground-tools/20251218-022826-capture-video/` (9 frames + contact sheet).

### ✅ Controls Fixture – “bottom controls” recipes
- **Discrete slider**: coordinate-click the left/right ends of the `discrete-slider` frame to jump `1…5` and verify `[Control] Discrete slider changed` logs.
- **Stepper**: coordinate-click the top/bottom halves of the `stepper-control` frame to increment/decrement and verify `[Control] Stepper …` logs.
- **Date picker**: coordinate-click the up/down arrow buttons nearest the `date-picker` control (often `elem_53` / `elem_54`) to flip the day and verify `[Control] Date changed` logs.
- **Color picker**: open the `Colors` window from `color-picker`, then adjust the first `slider` in that window (coordinate-click near the right edge) to force a new color and verify `[Control] Color changed` logs.
- **Note**: Capture `Control` logs immediately (e.g. `playground-log.sh -c Control --last 2m --all -o ...`) as `info` lines can rotate out quickly on some machines.

### ✅ `drag` command – element-based drag/drop (resolved)
- **Resolved on 2025-12-17**: Drag Fixture exposes stable identifiers and logs drop outcomes.
- **Artifacts**: `.artifacts/playground-tools/20251217-152934-drag.log`

### ✅ `move` command – cursor probe logs (resolved)
- **Resolved on 2025-12-17**: Click Fixture includes a dedicated mouse probe so `move` can be verified via OSLog (not just CLI output).
- **Artifacts**: `.artifacts/playground-tools/20251217-153107-control.log`

## 2025-12-17

### ✅ Repo sync
- Pulled main + submodules to `origin/main` (all HTTPS). Resolved previous `project.pbxproj` conflict already landed.
- AXorcist digit hotkeys fix was rebased onto submodule `main` (local commit `0f43484…`), so `peekaboo hotkey --keys "cmd,1"` works.

### ✅ `see` window targeting + element detection scoping
- **Problem**: `see --mode window --window-title …` could capture the correct window but still return elements from a different window (Playground fixtures all looked like TextInputView).
- **Fix**: Propagate the captured `windowInfo.windowID` into `WindowContext`, and have element detection resolve the AX window by `CGWindowID` first.
- **Artifacts**: `.artifacts/playground-tools/20251217-153107-see-click-for-move.json` (Click Fixture returns click controls like “Single Click”, not TextInputView elements).

### ✅ Fixture windows (avoid TabView flakiness)
- Added a `Fixtures` menu with `⌘⌃1…⌘⌃8` shortcuts opening dedicated windows (“Click Fixture”, “Dialog Fixture”, “Text Fixture”, …).
- This makes window-title targeting deterministic and keeps snapshots stable for tool tests.

### ✅ `scroll` evidence logging (Playground)
- **Bug**: ScrollTestingView’s offset logger was measuring the ScrollView container (always 0,0), so scroll actions looked like no-ops.
- **Fix**: Measure the *content* offset inside the scroll view’s coordinate space.
- **Artifacts**: `.artifacts/playground-tools/20251217-222958-scroll.log` shows `Vertical scroll offset … y=-…` after `peekaboo scroll`.

### ✅ `move` evidence logging (Playground)
- Added a “Mouse Movement” probe to Click Fixture that logs `Control` events when the cursor enters/moves over the probe.
- **Artifacts**:
  - Snapshot: `.artifacts/playground-tools/20251217-153107-see-click-for-move.json`
  - Logs:
    - `.artifacts/playground-tools/20251217-153107-control.log`
    - `.artifacts/playground-tools/20251217-195012-move-out-control.log` (synthetic `peekaboo move` reliably triggers `Mouse entered probe area` / `Mouse exited probe area`; `Mouse moved over probe area` may require real mouse-moved events).

### ✅ E2E re-verifications (Playground)
- `click`: `.artifacts/playground-tools/20251217-152024-click.log` contains `Single click on 'Single Click' button`.
- `type`: `.artifacts/playground-tools/20251217-152047-text.log` contains `Basic text changed …`.
- `controls` (Controls Fixture): `.artifacts/playground-tools/20251217-230454-control.log` contains `Checkbox … toggled`, `Segmented control changed …`, `Slider moved …`, and `Progress set to 75%`.
  - Note: ControlsView is scrollable; after any `scroll`, re-run `see` before clicking elements further down (use `.artifacts/playground-tools/20251217-230454-see-controls-progress.json` as the post-scroll snapshot for progress buttons).
- `press`: `.artifacts/playground-tools/20251217-152138-keyboard.log` contains `Key pressed … (Up Arrow)`.
- `hotkey`: `.artifacts/playground-tools/20251217-152100-menu.log` contains `Test Action 1 clicked`.
- `swipe`: `.artifacts/playground-tools/20251217-152843-gesture.log` contains `Swipe … Distance: …px`.
- `drag`: `.artifacts/playground-tools/20251217-152934-drag.log` contains `Item dropped - Item A dropped in zone1`.
- `menu`: `.artifacts/playground-tools/20251217-153302-menu.log` contains `Submenu > Nested Action A clicked`.

### ✅ `visualizer` command – JSON dispatch report (new)
- **Problem**: `peekaboo visualizer --json-output` previously exited 0 with no output.
- **Fix**: Visualizer command now emits a JSON step report (and fails if any step wasn’t dispatched).
- **Artifact**: `.artifacts/playground-tools/20251217-204548-visualizer.json` (15/15 steps `dispatched=true`).

### ✅ Context menu (right-click) – `click --right`
- **Setup**: Open Click Fixture (`Fixtures → Open Click Fixture`, shortcut `⌘⌃1`).
- **Commands**:
  1. `peekaboo click --right "Right Click Me" --snapshot <id>`
  2. `peekaboo click "Context Action 1"` / `"Context Action 2"` / `"Delete"`
- **Artifacts**:
  - Snapshot: `.artifacts/playground-tools/20251217-165443-see-click-fixture.json`
  - Log: `.artifacts/playground-tools/20251217-165443-context-menu.log`
- **Result**: OSLog contains `Context menu: Action 1/2/Delete` entries under the `Menu` category.

### ✅ `window close` – verified on Window Fixture
- **Setup**: Open Window Fixture (`⌘⌃5`), then run `peekaboo window close --app boo.peekaboo.playground.debug --window-title "Window Fixture"`.
- **Artifacts**:
  - Before/after: `.artifacts/playground-tools/20251217-165256-windows-before.json`, `.artifacts/playground-tools/20251217-165256-windows-after.json`
  - Close output: `.artifacts/playground-tools/20251217-165256-window-close.json`
- **Result**: Window Fixture disappears from `peekaboo list windows` after the close action.

### 📈 Quick perf notes
- Recent `see` runs are ~0.7–0.8s for Click Fixture on this machine (7-run sample: `.artifacts/playground-tools/20251217-165555-perf-see-click-fixture-summary.json`, mean `0.757s`, p95 `0.789s`).
- **Findings**: Focus log now records entries (both from Playground UI and the CLI move command). The CLI entry still shows `<private>` in Console, so add more descriptive strings if we need richer auditing.

### ✅ `capture video` – static inputs keep 1 frame (no longer fails)
- **Commands**:
  1. Generate a static sample: `ffmpeg -f lavfi -i color=c=black:s=640x360:d=2 -pix_fmt yuv420p /tmp/peekaboo-static.mp4`
  2. `peekaboo capture video /tmp/peekaboo-static.mp4 --sample-fps 2 --json-output`
- **Artifacts**:
  - Motion sample (no diff): `.artifacts/playground-tools/20251217-180155-capture-video.json`
  - Static sample (diff on): `.artifacts/playground-tools/20251217-181430-capture-video-static.json`
- **Result**: Static sample exits 0 with `framesKept=1` and warning `noMotion` (“No motion detected; only key frames captured”).

### ✅ `capture` – MP4 output via `--video-out`
- **Commands**:
  1. `peekaboo capture live --mode window --app boo.peekaboo.playground.debug --window-title "Click Fixture" --duration 3 --active-fps 8 --threshold 0 --video-out /tmp/peekaboo-capture-live.mp4 --json-output`
  2. `peekaboo capture video /tmp/peekaboo-capture-src.mp4 --sample-fps 6 --no-diff --video-out /tmp/peekaboo-capture-video.mp4 --json-output`
- **Artifacts**:
  - Live: `.artifacts/playground-tools/20251217-184010-capture-live-videoout.json`
  - Video ingest: `.artifacts/playground-tools/20251217-184010-capture-video-videoout.json`
- **Result**: Both runs write non-empty MP4 files and the JSON payload includes `videoOut`.

### ✅ `run --no-fail-fast` – continues after a failing step (single JSON payload)
- **Command**: `peekaboo run docs/testing/fixtures/playground-no-fail-fast.peekaboo.json --no-fail-fast --json-output`
- **Artifacts**:
  - Run output: `.artifacts/playground-tools/20251217-184554-run-no-fail-fast.json`
  - Click log: `.artifacts/playground-tools/20251217-184554-run-no-fail-fast-click.log`
- **Result**: The run exits non-zero with `success=false`, but still executes the final `click_single` step (Click log contains `Single click`).

### ✅ `window` – minimize + maximize on Window Fixture
- **Setup**: Open Window Fixture (`⌘⌃5`).
- **Commands**:
  1. `peekaboo window minimize --app boo.peekaboo.playground.debug --window-title "Window Fixture" --json-output`
  2. `peekaboo window focus --app boo.peekaboo.playground.debug --window-title "Window Fixture" --json-output` (restore)
  3. `peekaboo window maximize --app boo.peekaboo.playground.debug --window-title "Window Fixture" --json-output`
- **Artifacts**:
  - `.artifacts/playground-tools/20251217-183242-window.log`
  - `.artifacts/playground-tools/20251217-183242-window-minimize.json`, `.artifacts/playground-tools/20251217-183242-window-focus-unminimize.json`, `.artifacts/playground-tools/20251217-183242-window-maximize.json`

### ✅ `window` command – Playground window coverage
- **Logs**: `.artifacts/playground-tools/20251116-194900-window.log`
- **Artifacts**:
  - `.artifacts/playground-tools/20251116-194858-window-list-playground.json`
  - `.artifacts/playground-tools/20251116-194858-window-move-playground.json`
  - `.artifacts/playground-tools/20251116-194859-window-resize-playground.json`
  - `.artifacts/playground-tools/20251116-194859-window-setbounds-playground.json`
  - `.artifacts/playground-tools/20251116-194900-window-focus-playground.json`
- **Commands**:
  1. `polter peekaboo -- window list --app Playground --json-output`
  2. `polter peekaboo -- window move --app Playground --x 220 --y 180 --json-output`
  3. `polter peekaboo -- window resize --app Playground --width 1100 --height 820 --json-output`
  4. `polter peekaboo -- window set-bounds --app Playground --x 120 --y 120 --width 1200 --height 860 --json-output`
  5. `polter peekaboo -- window focus --app Playground --json-output`
- **Findings**: The `Window` log now records every Playground-focused action (`focus`, `move`, `resize`, `set_bounds`) with the new bounds, so the regression plan can rely on Playground alone instead of the earlier TextEdit stand-in.

### ✅ `app` command – Playground-focused flows
- **Logs**: `.artifacts/playground-tools/20251116-195420-app.log`
- **Artifacts**: `.artifacts/playground-tools/20251116-195420-app-list.json`, `.artifacts/playground-tools/20251116-195421-app-switch.json`, `.artifacts/playground-tools/20251116-195422-app-hide.json`, `.artifacts/playground-tools/20251116-195423-app-unhide.json`, `.artifacts/playground-tools/20251116-195424-app-launch-textedit.json`, `.artifacts/playground-tools/20251116-195425-app-quit-textedit.json`
- **Commands**:
  1. `polter peekaboo -- app list --include-hidden --json-output`
  2. `polter peekaboo -- app switch --to Playground`
  3. `polter peekaboo -- app hide --app Playground` / `app unhide --app Playground --activate`
  4. `polter peekaboo -- app launch "TextEdit" --json-output`
  5. `polter peekaboo -- app quit --app TextEdit --json-output`
- **Findings**: App log now shows the full sequence (list, switch, hide, unhide, launch, quit) with bundle IDs/PIDs, so the regression plan can rely on Playground itself without helper apps.

### ✅ `space` command – Space logger instrumentation
- **Logs**: `.artifacts/playground-tools/20251116-205548-space.log`
- **Artifacts**:
  - `.artifacts/playground-tools/20251116-205527-space-list.json`
  - `.artifacts/playground-tools/20251116-205532-space-list-detailed.json`
  - `.artifacts/playground-tools/20251116-205536-space-switch-1.json`
  - `.artifacts/playground-tools/20251116-205541-space-move-window.json`
  - `.artifacts/playground-tools/20251116-195602-space-switch-2.json` (expected `VALIDATION_ERROR`)
- **Commands**:
  1. `polter peekaboo -- space list --json-output`
  2. `polter peekaboo -- space list --detailed --json-output`
  3. `polter peekaboo -- space switch --to 1 --json-output` (success) and `--to 2` (expected failure)
  4. `polter peekaboo -- space move-window --app Playground --window-index 0 --to 1 --follow --json-output`
- **Findings**: AutomationEventLogger now emits `[Space]` entries for list, switch, and move-window actions; `playground-log.sh -c Space` returns the new log confirming instrumentation landed. We still only have one desktop, so the Space 2 attempt continues to surface `VALIDATION_ERROR (Available: 1-1)` as designed.

### ✅ `menubar` command – Wi-Fi + Control Center
- **Artifacts**: `.artifacts/playground-tools/20251116-141824-menubar-list.json`
- **Commands**:
  1. `polter peekaboo -- menubar list --json-output`
  2. `polter peekaboo -- menubar click "Wi-Fi" --foreground`
  3. `polter peekaboo -- menubar click --index 2 --foreground`
- **Notes**: CLI output confirms the clicked items (Wi-Fi by title, Control Center by index). Still no dedicated menubar logger—`playground-log.sh -c Menu` remains empty for these operations, so rely on CLI artifacts for evidence.



### ✅ `dock` command – Dock launch/hide/show/right-click
- **Logs**: `.artifacts/playground-tools/20251116-205850-dock.log`
- **Artifacts**:
  - `.artifacts/playground-tools/20251116-200750-dock-list.json`
  - `.artifacts/playground-tools/20251116-200751-dock-launch.json`
  - `.artifacts/playground-tools/20251116-200752-dock-hide.json`
  - `.artifacts/playground-tools/20251116-200753-dock-show.json`
  - `.artifacts/playground-tools/20251116-205828-dock-right-click.json`
- **Commands**:
  1. `polter peekaboo -- dock list --json-output`
  2. `polter peekaboo -- dock launch Playground`
  3. `polter peekaboo -- dock hide` / `polter peekaboo -- dock show`
  4. `polter peekaboo -- dock right-click --app Finder --select "New Finder Window"`
- **Findings**: The Dock logger now captures list/launch/hide/show plus the Finder right-click with `selection=New Finder Window`, so the tool is fully verified. If right-click ever fails, focus the Dock (move cursor to the bottom) and rerun; Finder must be visible in the Dock for menu lookup to succeed.

### ✅ `dialog` command – TextEdit Save sheet
- **Logs**: `.artifacts/playground-tools/20251116-080435-dialog.log`
- **Artifacts**: `.artifacts/playground-tools/20251116-080430-dialog-list.json`
- **Commands**:
  1. `polter peekaboo -- dialog list --app TextEdit --json-output`
  2. `polter peekaboo -- dialog click --button "Cancel" --app TextEdit`
- **Outcome**: After launching TextEdit, creating a new document, running `see` for the snapshot, and sending `cmd+s`, both `dialog list` and `dialog click` succeed and emit `[Dialog]` log entries for evidence.

### ✅ `agent` command – GPT-5.1 flows
- **Logs**: `.artifacts/playground-tools/20251117-011345-agent.log`, `.artifacts/playground-tools/20251117-011500-agent-single-click.log`
- **Artifacts**:
  - `.artifacts/playground-tools/20251117-010912-agent-list.json`
  - `.artifacts/playground-tools/20251117-010919-agent-hi.json`
  - `.artifacts/playground-tools/20251117-010935-agent-single-click.json`
  - `.artifacts/playground-tools/20251117-011314-agent-single-click.json`
  - `.artifacts/playground-tools/20251117-012655-agent-hi.json`
- **Commands**:
  1. `polter peekaboo -- agent --model gpt-5.5 --list-sessions --json-output`
  2. `polter peekaboo -- agent "Say hi to the Playground app." --model gpt-5.5 --max-steps 2 --json-output`
  3. `polter peekaboo -- agent "Switch to Playground and press the Single Click button once." --model gpt-5.5 --max-steps 4 --json-output`
  4. Long run via tmux for full tool coverage:
     ```
     tmux new-session -- bash -lc 'pnpm run peekaboo -- agent "Click the Single Click button in Playground." --model gpt-5.5 --max-steps 6 --no-cache | tee .artifacts/playground-tools/20251117-011500-agent-single-click.log'
     ```
- **Findings**:
  - GPT-5.1 works end-to-end; the tmux transcript shows `see`, `app`, and two `click` calls completing with `Task completed ... ⚒ 6 tools`.
  - JSON output now reports the correct tool count (see `.artifacts/playground-tools/20251117-012655-agent-hi.json`, which shows `toolCallCount: 1` for the `done` tool). Use that artifact to confirm the regression is fixed.
  - Non-trivial agent runs can time out; always invoke those through `tmux …` so they can finish, then collect the artifacts/logs afterward.

### ✅ `mcp` command – stdio server smoke
- **Logs**: `.artifacts/playground-tools/20251219-001255-mcp.log`
- **Artifacts**: `.artifacts/playground-tools/20251219-001230-mcp-list.json`, `.artifacts/playground-tools/20251219-001245-mcp-call-permissions.json`
- **Commands**:
  1. `MCPORTER list peekaboo-local --stdio "$PEEKABOO_BIN mcp" --timeout 20 --schema > .artifacts/playground-tools/20251219-001230-mcp-list.json`
  2. `MCPORTER call peekaboo-local.permissions --stdio "$PEEKABOO_BIN mcp" --timeout 15 > .artifacts/playground-tools/20251219-001245-mcp-call-permissions.json`
  3. `./Apps/Playground/scripts/playground-log.sh -c MCP --last 15m --all -o .artifacts/playground-tools/20251219-001255-mcp.log`
- **Findings**: MCPORTER successfully enumerates tools and executes a basic `permissions` call over stdio; Playground `[MCP]` log captures the interaction for regression evidence.

### ✅ `dialog` command – TextEdit Save sheet
- **Commands**:
  1. `polter peekaboo -- app launch TextEdit`
  2. `polter peekaboo -- menu click --path "File>New" --app TextEdit`
  3. `SESSION=$(polter peekaboo -- see --app TextEdit --json-output | jq -r '.data.snapshot_id')`
  4. `polter peekaboo -- hotkey --keys "cmd,s" --snapshot $SESSION`
  5. `polter peekaboo -- dialog list --app TextEdit --json-output > .artifacts/playground-tools/20251116-054316-dialog-list.json`
  6. `polter peekaboo -- dialog click --button "Cancel" --app TextEdit`
- **Verification**: `dialog list` returns Save sheet metadata (buttons Cancel/Save, AXSheet role). Playground log remains empty, but JSON artifact confirms the dialog.
- **Notes**: ScrollTestingView still doesn’t surface `vertical-scroll` / `horizontal-scroll` IDs in the UI map, so `--on` remains unavailable. Use pointer-relative scrolls until those identifiers are exposed.

### ✅ `swipe` command – Gesture area coverage
- **Setup**: Stayed on the Scroll & Gestures tab/snapshot from the scroll run (`DBFDD053-4513-4603-B7C3-9170E7386BA7`, artifacts `.artifacts/playground-tools/20251116-085714-see-scrolltab.{json,png}`).
- **Commands**:
  1. `polter peekaboo -- swipe --from-coords 1100,520 --to-coords 700,520 --duration 600`
  2. `polter peekaboo -- swipe --from-coords 850,600 --to-coords 850,350 --duration 800 --profile human`
  3. `polter peekaboo -- swipe --from-coords 900,520 --to-coords 700,520 --right-button` (expected failure)
- **Artifacts**: `.artifacts/playground-tools/20251116-090041-gesture.log` contains both successful swipes with direction/profile metadata; the negative command prints `Right-button swipe is not currently supported…` in the CLI output for documentation.
- **Notes**: Gesture logging is now wired via `AutomationEventLogger`, so future swipes should always leave `[Gesture]` entries without additional instrumentation.

### ✅ `press` command – Keyboard detection
- **Setup**: Switched to Keyboard tab via `polter peekaboo -- hotkey --keys "cmd,option,7"`, then ran `see` to capture `.artifacts/playground-tools/20251116-090141-see-keyboardtab.{json,png}` (snapshot `C106D508-930C-4996-A4F4-A50E2E0BA91A`). Focused the “Press keys here…” field with `polter peekaboo -- click --snapshot … --coords 760,300`.
- **Commands**:
  1. `polter peekaboo -- press return --snapshot C106D508-…`
  2. `polter peekaboo -- press up --count 3 --snapshot C106D508-…`
  3. `polter peekaboo -- press foo` (expected error)
- **Artifacts**: `.artifacts/playground-tools/20251116-090455-keyboard.log` shows the Return and repeated Up Arrow events (plus the earlier tab-switch log). The invalid command prints `Unknown key: 'foo'…`.
- **Notes**: The keyboard log proves the `press` command triggers the in-app detection view; negative test documents the current error surface for unsupported keys.

### ✅ `menu` command – Test Menu actions + disabled item
- **Setup**: With Playground frontmost, listed the menu hierarchy via `polter peekaboo -- menu list --app Playground --json-output > .artifacts/playground-tools/20251116-090600-menu-playground.json` to confirm Test Menu items exist.
- **Commands**:
  1. `polter peekaboo -- menu click --app Playground --path "Test Menu>Test Action 1"`
  2. `polter peekaboo -- menu click --app Playground --path "Test Menu>Submenu>Nested Action A"`
  3. `polter peekaboo -- menu click --app Playground --path "Test Menu>Disabled Action"` (expected failure)
- **Artifacts**: `.artifacts/playground-tools/20251116-090512-menu.log` contains the `[Menu]` log entries for the successful clicks. The failure case saved as `.artifacts/playground-tools/20251116-090509-menu-click-disabled.json` with `INTERACTION_FAILED` and the “Menu item is disabled…” message.
- **Notes**: `menu click` currently targets menu-bar items only; context menus in ClickTestingView still need `click`/`rightClick` coverage outside of the `menu` command.
- **Notes**: `menu click` currently targets menu-bar items only; context menus in ClickTestingView still need `click`/`rightClick` coverage outside of the `menu` command.

### ✅ `app` command – list/switch/hide/launch coverage
- **Setup**: With Playground active, ran `polter peekaboo -- app list --include-hidden --json-output > .artifacts/playground-tools/20251116-090750-app-list.json` and captured the app log (`.artifacts/playground-tools/20251116-090840-app.log`) via `playground-log.sh -c App`.
- **Commands**:
  1. `polter peekaboo -- app switch --to Playground`
  2. `polter peekaboo -- app hide --app Playground` / `polter peekaboo -- app unhide --app Playground`
  3. `polter peekaboo -- app launch "TextEdit" --json-output > .artifacts/playground-tools/20251116-090831-app-launch-textedit.json`
  4. `polter peekaboo -- app quit --app TextEdit --json-output > .artifacts/playground-tools/20251116-090837-app-quit-textedit.json`
- **Result**: All commands succeeded; `.artifacts/playground-tools/20251116-090840-app.log` shows `list`, `switch`, `hide`, `unhide`, `launch`, and `quit` entries with bundle IDs and PIDs. No anomalies observed—`hide` does not auto-activate afterward (matching CLI messaging).
- **Result**: All commands succeeded; `.artifacts/playground-tools/20251116-090840-app.log` shows `list`, `switch`, `hide`, `unhide`, `launch`, and `quit` entries with bundle IDs and PIDs. No anomalies observed—`hide` does not auto-activate afterward (matching CLI messaging).

### ✅ `dock` command – right-click + menu selection (resolved)
- **Logs**: `.artifacts/playground-tools/20251116-205850-dock.log`
- **Artifacts**: `.artifacts/playground-tools/20251116-200750-dock-list.json`, `.artifacts/playground-tools/20251116-200752-dock-launch.json`, `.artifacts/playground-tools/20251116-200753-dock-hide.json`, `.artifacts/playground-tools/20251116-200753-dock-show.json`, `.artifacts/playground-tools/20251116-205828-dock-right-click.json`
- **Commands**:
  1. `polter peekaboo -- dock list --json-output`
  2. `polter peekaboo -- dock launch Playground`
  3. `polter peekaboo -- dock hide` / `dock show`
  4. `polter peekaboo -- dock right-click --app Finder --select "New Finder Window" --json-output`
- **Notes**: If right-click targeting flakes, move the cursor to the Dock first and retry; Finder must be present in the Dock for menu lookup to succeed.

### ✅ `open` command – TextEdit + browser targets
- **Commands**:
  1. `polter peekaboo -- open Apps/Playground/README.md --app TextEdit --json-output > .artifacts/playground-tools/20251116-200220-open-readme-textedit.json`
  2. `polter peekaboo -- open https://example.com --json-output > .artifacts/playground-tools/20251116-200222-open-example.json`
  3. `polter peekaboo -- open Apps/Playground/README.md --app TextEdit --no-focus --json-output > .artifacts/playground-tools/20251116-200224-open-readme-textedit-nofocus.json`
- **Verification**: `.artifacts/playground-tools/20251116-200220-open.log` shows the corresponding `[Open]` entries (TextEdit focused, Chrome focused, TextEdit focused=false). After the tests, `polter peekaboo -- app quit --app TextEdit` cleaned up the extra window.

### ✅ `space` command – list/switch/move-window
- **Commands**:
  1. `polter peekaboo -- space list --detailed --json-output > .artifacts/playground-tools/20251116-091557-space-list.json`
  2. `polter peekaboo -- space switch --to 1`
  3. `polter peekaboo -- space switch --to 2 --json-output > .artifacts/playground-tools/20251116-091602-space-switch-2.json` (expected failure; only one space exists)
  4. `polter peekaboo -- space move-window --app Playground --to 1 --follow`
- **Result**: All commands behaved as expected—Space enumerations still report a single desktop and the Space 2 attempt returns `VALIDATION_ERROR`. A dedicated Space logger now emits `[Space]` entries; see `.artifacts/playground-tools/20251116-205548-space.log` for evidence.

### ✅ `agent` command – list + sample tasks
- **Commands**:
  1. `polter peekaboo -- agent sessions --json > .artifacts/playground-tools/20251116-091814-agent-list.json`
  2. `polter peekaboo -- agent "Say hi" --max-steps 1 --json-output > .artifacts/playground-tools/20251116-091820-agent-hi.json`
  3. `polter peekaboo -- agent "Summarize the Playground UI" --dry-run --max-steps 2 --json-output > .artifacts/playground-tools/20251116-091831-agent-toolbar.json`
- **Verification**: `.artifacts/playground-tools/20251116-091839-agent.log` shows `[Agent]` entries for both tasks (model, duration, dry-run flag). Outputs confirm the CLI returns structured responses and respects `--dry-run` / `--max-steps`.

### ✅ `move` command – coordinates, targets, center
- **Commands**:
  1. `polter peekaboo -- move 600,600`
  2. `polter peekaboo -- move --to "Focus Basic Field" --snapshot DBFDD053-4513-4603-B7C3-9170E7386BA7 --smooth`
  3. `polter peekaboo -- move --center --duration 300 --steps 15`
  4. `polter peekaboo -- move --coords 600,600`
  5. Negative test: `polter peekaboo -- move 1,2 --center` (should error: conflicting targets)
- **Result**: Moves succeed and `--coords` is accepted as an alias for the positional coordinates; conflicting targets now fail with `VALIDATION_ERROR` (fixed in `MoveCommand` + Commander metadata).
- **Notes**: `playground-log -c Focus` remains empty during these runs; prefer the Click Fixture probe + `playground-log -c Control` for durable move evidence.

### ✅ `mcp` command – stdio server smoke
- **Commands**:
  1. `MCPORTER list peekaboo-local --stdio "$PEEKABOO_BIN mcp" --timeout 20 --schema > .artifacts/playground-tools/20251219-001230-mcp-list.json`
  2. `MCPORTER call peekaboo-local.permissions --stdio "$PEEKABOO_BIN mcp" --timeout 15 > .artifacts/playground-tools/20251219-001245-mcp-call-permissions.json`
  3. `./Apps/Playground/scripts/playground-log.sh -c MCP --last 15m --all -o .artifacts/playground-tools/20251219-001255-mcp.log`
- **Result**:
  - MCPORTER enumerates the Peekaboo MCP tool catalog over stdio.
  - The `permissions` tool responds with expected Screen Recording + Accessibility status.
- **Notes**: Keep the MCP log capture alongside the JSON artifacts so future runs can diff tool schemas and request logs.

### ✅ `dialog` command – TextEdit Save sheet
- **Setup**:
  1. `polter peekaboo -- app launch TextEdit --wait-until-ready --json-output > .artifacts/playground-tools/20251116-091212-textedit-launch.json`
  2. `polter peekaboo -- menu click --path "File>New" --app TextEdit`
  3. Type at least one character so TextEdit becomes “dirty” (otherwise `cmd+s` may no-op): `polter peekaboo -- type "Peekaboo" --app TextEdit`
  4. `polter peekaboo -- see --app TextEdit --json-output --path .artifacts/playground-tools/20251116-091229-see-textedit.png` (snapshot `0485162B-6D02-4A72-9818-48C79452AEAC`)
  5. `polter peekaboo -- hotkey --keys "cmd,s" --snapshot 0485162B-…`
- **Commands**:
  1. `polter peekaboo -- dialog list --app TextEdit --json-output > .artifacts/playground-tools/20251116-091255-dialog-list.json`
  2. `polter peekaboo -- dialog click --button "Cancel" --app TextEdit --json-output > .artifacts/playground-tools/20251116-091259-dialog-click-cancel.json`
  3. `polter peekaboo -- dialog input --app TextEdit --index 0 --text "NAME0" --clear --json-output`
  4. `polter peekaboo -- dialog file --app TextEdit --select "Cancel" --json-output`
- **Artifacts**: `.artifacts/playground-tools/20251116-091306-dialog.log` shows `[Dialog] action=list` and `action=click button='Cancel'` entries. JSON artifacts include the full dialog metadata and confirm the click result.
- **Notes**: Re-run the `hotkey --keys "cmd,s"` step whenever the dialog is dismissed so future dialog tests have a live window to interact with.
 - **2025-12-17 follow-up**:
   - `dialog input` no longer fails with “Action is not supported” on Save-sheet text fields, and `dialog file --select Cancel` reliably dismisses Save sheets that expose neither a useful title nor `AXIdentifier` (detected via canonical buttons + re-resolving before click): `.artifacts/playground-tools/20251217-215657-dialog-input-then-file-cancel.json`.

### ✅ `run` command – Playground smoke fixture (`see`/`click`/`type`)
- **Command**: `polter peekaboo -- run docs/testing/fixtures/playground-smoke.peekaboo.json --json-output > .artifacts/playground-tools/<timestamp>-run-playground-smoke.json`
- **Artifacts (2025-12-17)**:
  - `.artifacts/playground-tools/20251217-221643-run-playground-smoke.json`
  - `.artifacts/playground-tools/20251217-221643-run-playground-smoke-click.log`
  - `.artifacts/playground-tools/20251217-221643-run-playground-smoke-text.log`
- **Verification**: The Text log includes `Basic text changed … To: 'Playground smoke'`, proving the script targeted `basic-text-field` (not the numeric-only field).

## 2025-12-18

### ✅ Identifier-based query resolution (regression fix)
- **Problem**: Internal `waitForElement(.query)` matching ignored accessibility identifiers, so commands that rely on identifier-based targeting could intermittently fail or hit the wrong element.
- **Fix**: `UIAutomationService.findElementInSession` now resolves query targets via `ClickService.resolveTargetElement(query:in:)`, so identifiers participate in matching consistently.
- **Playground verification** (Controls Fixture):
  1. `polter peekaboo -- see --app boo.peekaboo.playground.debug --mode window --window-title "Controls Fixture" --json-output > .artifacts/playground-tools/20251217-234640-see-controls.json`
  2. `polter peekaboo -- click "checkbox-1" --snapshot <id>`
  3. `polter peekaboo -- click "checkbox-2" --snapshot <id>`
  4. `./Apps/Playground/scripts/playground-log.sh -c Control --last 5m --all -o .artifacts/playground-tools/20251217-234640-controls-control.log`
- **Result**: Control log contains `Checkbox 1 toggled` + `Checkbox 2 toggled` (identifier targeting).

### ✅ `click` → `type` chain on SwiftUI text inputs (focus nudge)
- **Problem**: `click` on SwiftUI text inputs could land slightly outside the editable region, so the FieldEditor never focused and subsequent `type` produced no UI change.
- **Fix**: `ClickService` now detects when the expected element didn’t receive focus and retries a small set of deterministic y-offset clicks to “nudge” focus into the text field editor.
- **Verification** (Text Fixture):
  1. `polter peekaboo -- see --app boo.peekaboo.playground.debug --mode window --window-title "Text Fixture" --json-output > .artifacts/playground-tools/20251218-001923-see-text.json`
  2. `polter peekaboo -- click "basic-text-field" --snapshot <id> --json-output > .artifacts/playground-tools/20251218-001923-click-basic-text-field.json`
  3. `polter peekaboo -- type "Hello" --clear --snapshot <id> --json-output > .artifacts/playground-tools/20251218-001923-type-hello.json`
  4. `./Apps/Playground/scripts/playground-log.sh -c Text --last 5m --all -o .artifacts/playground-tools/20251218-001923-text.log`
- **Result**: Text log contains `Basic text changed - From: '' To: 'Hello'`.

### ✅ `scroll` command – vertical/horizontal + nested scroll offsets (fixture rebuild)
- **Update**: Rebuilt Playground so nested scroll views also emit offset logs (inner + outer).
- **Verification**: `.artifacts/playground-tools/20251217-234921-scroll.log` contains `Vertical scroll offset …`, `Horizontal scroll offset …`, plus `Nested inner scroll offset …` and `Nested outer scroll offset …`.

### ✅ Gesture + menu + drag re-verification (fresh artifacts)
- **Swipe**: `.artifacts/playground-tools/20251218-002229-gesture.log` logs `Swipe … Distance: …px`.
- **Menu**: `.artifacts/playground-tools/20251218-002308-menu.log` logs `Test Action 1 clicked` and `Submenu > Nested Action A clicked`.
- **Drag**: `.artifacts/playground-tools/20251218-002005-drag.log` logs `Item dropped … zone1`.

### ✅ `click --double` now triggers SwiftUI double-tap gestures (AXorcist fix)
- **Problem**: `click --double` previously posted only one down/up pair with `clickState=2`, which registers as a single click in SwiftUI (and never triggers `onTapGesture(count: 2)`).
- **Fix**: AXorcist `Element.clickAt(... clickCount: 2)` now emits two down/up pairs with sequential click states (1 then 2), within the system double-click interval.
- **Verification** (Click Fixture “Double Click Me”):
  - `.artifacts/playground-tools/20251218-004335-click.log` contains `Double-click detected on area`.
  - `.artifacts/playground-tools/20251218-004335-menu.log` contains `Context menu: Action 1` (right-click + context menu still works after the multi-click change).
