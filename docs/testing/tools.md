---
summary: 'Systematic Peekaboo tool verification plan using Playground and file logs'
read_when:
  - 'planning or executing the comprehensive tool regression pass'
  - 'picking up the Playground-based test assignment'
---

# Peekaboo Tool Playground Test Plan

## Assignment & Expectations
- Validate every native Peekaboo tool/CLI command (see the CLI command reference) against the Playground app so future automation runs have deterministic coverage.
- For each tool run, capture an OSLog transcript with `Apps/Playground/scripts/playground-log.sh --output <file>` so we have durable evidence that the action completed (e.g., `[Click]`, `[Scroll]` entries).
- Update this document every time you start/finish a tool, and log deeper repro notes or bugs under `Apps/Playground/PLAYGROUND_TEST.md` so the next person can keep going.
- Fix any issues you discover while executing the plan. If a fix is large, land it first, then rerun the affected tool plan and refresh the log artifacts.
- Rebuild the CLI before testing so you never test stale bits: `pnpm run build:cli`, then run `Apps/CLI/.build/debug/peekaboo <command>`.
  - For long runs, use tmux.

## Environment & Logging Setup
2. Launch Playground (`Apps/Playground/Playground.app` via Xcode or `open Apps/Playground/Playground.xcodeproj`). Keep it foregrounded on Space 1 to avoid focus surprises.
   - Prefer the dedicated fixture windows (menu `Fixtures`, shortcuts `⌘⌃1…⌘⌃8`) so each tool targets a stable window title (“Click Fixture”, “Dialog Fixture”, “Scroll Fixture”, etc.) instead of relying on TabView state.
3. Prepare a log root once per session:
   ```bash
   LOG_ROOT=${LOG_ROOT:-$PWD/.artifacts/playground-tools}
   mkdir -p "$LOG_ROOT"
   ```
4. Before you run any Peekaboo tool, arm a category-specific log capture so we can diff pre/post state:
   ```bash
   TOOL=Click   # e.g. Click/Text/Menu/Window/Scroll/Drag/Keyboard/Focus/Gesture/Control/App
   LOG_FILE="$LOG_ROOT/$(date +%Y%m%d-%H%M%S)-${TOOL,,}.log"
   ./Apps/Playground/scripts/playground-log.sh -c "$TOOL" --last 10m --all -o "$LOG_FILE"
   ```
   - **Note**: On some macOS 26 setups, unified logging may not retain `info` lines for long. When collecting evidence, prefer smaller windows (e.g. `--last 2m`) immediately after each action.
5. Keep the Playground UI on the matching view (ClickTestingView, TextInputView, etc.) and run `peekaboo see --app Playground` anytime you need a fresh snapshot ID for element targeting. Record the snapshot ID in your notes.
6. After executing the tool, append verification notes (log file path, snapshot ID, observed behavior) to the table below and add detailed findings to `Apps/Playground/PLAYGROUND_TEST.md`.

## Execution Loop
1. Pick a tool from the matrix (start with Interaction tools, then cover window/app utilities, then the remaining system/automation commands).
2. Review the tool doc under `docs/commands/<tool>.md` and skim the command implementation in `Apps/CLI/Sources/PeekabooCLI/Commands/**` so you understand its parameters and edge cases before running it.
3. Stage the Playground view + log capture as described above.
4. Run the suggested CLI smoke tests plus the extra edge cases listed per tool (invalid targets, timing edge cases, multi-step flows).
5. Confirm Playground reflects the action (UI changes + OSLog evidence). Capture screenshots if a regression needs a visual repro.
6. File and fix bugs immediately; rerun the plan for the affected tool to prove the fix.
7. Update the status column and include the log artifact path so the next person knows what already passed.

## Performance Checks
- Capture performance summaries whenever a tool feels “slow” (or after fixing perf regressions) so we have a hard baseline.
- Use `pnpm run benchmark:tools` to run a command repeatedly and write a `*-summary.json` alongside the per-run JSON payloads. The helper reads command timing fields such as `data.execution_time` or `data.executionTime` when available, falls back to wall time, and exits non-zero if a measured run fails:
  ```bash
  pnpm run benchmark:tools --name see-click-fixture --runs 10 --warmups 1 -- \
    see --app boo.peekaboo.playground.debug --mode window --window-title "Click Fixture" --json-output
  ```
- See [benchmarks.md](benchmarks.md) for the full local benchmarking workflow.
- Current reference baseline (2025-12-17, Click Fixture): `see` p95 ≈ 0.97s, `click` p95 ≈ 0.18s (`.artifacts/playground-tools/20251217-174822-perf-see-click-clickfixture-summary.json`).
- Additional baselines (2025-12-17):
  - Scroll Fixture (`scroll --on vertical-scroll`, 15 runs): wall p95 ≈ 0.30s, exec p95 ≈ 0.12s (`.artifacts/playground-tools/20251217-224849-scroll-vertical-scroll-fixture-summary.json`).
  - System menu list-all (3 runs): wall p95 ≈ 0.61s (`.artifacts/playground-tools/20251217-224944-menu-list-all-system-summary.json`).

## Tool Matrix

### Vision & Capture
| Tool | Playground coverage | Log focus | Sample CLI entry point | Status | Latest log |
| --- | --- | --- | --- | --- | --- |
| `see` | Prefer fixture windows (“Click Fixture”, “Scroll Fixture”, etc.) | Capture snapshot metadata via CLI output + optional Playground logs for follow-on actions | `peekaboo see --app Playground --mode window --window-title "Click Fixture"` | Verified – `--window-title` now resolves against ScreenCaptureKit windows and element detection is pinned to the captured `CGWindowID` | `.artifacts/playground-tools/20251217-153107-see-click-for-move.json` |
| `image` | Playground window (full or element-specific) | Use `Image` artifacts; note timestamp in `LOG_FILE` | `peekaboo image window --app Playground --output /tmp/playground-window.png` | Verified – window + screen captures succeed after capture fallback fix | `.artifacts/playground-tools/20251116-082109-image-window-playground.json`, `.artifacts/playground-tools/20251116-082125-image-screen0.json` |
| `capture` | `capture live` against Playground (5–10s) + `capture video` ingest smoke | Verify artifacts (`metadata.json`, `contact.png`, frames) + optional MP4 (`--video-out`) | `peekaboo capture live --mode window --app Playground --duration 5 --threshold 0 --json-output` | Verified – live writes contact sheet + metadata; video ingest + `--video-out` covered | `.artifacts/playground-tools/20251217-133751-capture-live.json`, `.artifacts/playground-tools/20251217-180155-capture-video.json`, `.artifacts/playground-tools/20251217-184010-capture-live-videoout.json`, `.artifacts/playground-tools/20251217-184010-capture-video-videoout.json` |
| `list` | Validate `apps`, `windows`, `screens`, `menubar`, `permissions` while Playground is running | `playground-log` optional (`Window` for focus changes) | `peekaboo list windows --app Playground` etc. | Verified – apps/windows/screens/menubar/permissions captured 2025-11-16 | `.artifacts/playground-tools/20251116-142111-list-apps.json`, `.artifacts/playground-tools/20251116-142111-list-windows-playground.json`, `.artifacts/playground-tools/20251116-142122-list-screens.json`, `.artifacts/playground-tools/20251116-142122-list-menubar.json`, `.artifacts/playground-tools/20251116-142122-list-permissions.json` |
| `tools` | Compare CLI output against ToolRegistry | No Playground log required; attach output to notes | `peekaboo tools > $LOG_ROOT/tools.txt` | Verified – native tool listing captured 2025-12-19 | `.artifacts/playground-tools/20251219-001215-tools.txt` |
| `run` | Execute scripted multi-step flows against Playground fixtures | Logs depend on embedded commands | `peekaboo run docs/testing/fixtures/playground-smoke.peekaboo.json` | Verified – smoke script drives Text Fixture and `type` resolves `basic-text-field` deterministically | `.artifacts/playground-tools/20251217-221643-run-playground-smoke.json`, `.artifacts/playground-tools/20251217-221643-run-playground-smoke-text.log` |
| `sleep` | Inserted between Playground actions | Observe timestamps in log file | `peekaboo sleep 1500` | Verified – manual timing around CLI pause | `python wrapper measuring peekaboo sleep 2000` |
| `clean` | Snapshot cache after `see` runs | Inspect `~/.peekaboo/snapshots` & ensure Playground unaffected | `peekaboo clean --snapshot <id>` | Verified – removed snapshot 5408D893… and confirmed re-run reports none | `.peekaboo/snapshots/5408D893-E9CF-4A79-9B9B-D025BF9C80BE (deleted)` |
| `clipboard` | Clipboard smoke (text/file/image + save/restore) | Verify readback + binary export + restore user clipboard | `peekaboo clipboard --action set --image-path assets/peekaboo.png --json-output` | Verified – CLI set/get (file+image) and cross-invocation save/restore (2025-12-17) | `.artifacts/playground-tools/20251217-192349-clipboard-get-image.json` |
| `config` | Validate config commands while Playground idle | N/A | `peekaboo config show` | Verified – show/validate outputs captured 2025-11-16 | `.artifacts/playground-tools/20251116-051200-config-show-effective.json` |
| `permissions` | Ensure status/grant flow works with Playground | `playground-log` `App` category (should log when permissions toggled) | `peekaboo permissions status` | Verified – Screen Recording & Accessibility granted | `.artifacts/playground-tools/20251116-051000-permissions-status.json` |
| `learn` | Dump agent guide | N/A | `peekaboo learn > $LOG_ROOT/learn.txt` | Verified – latest dump saved 2025-11-16 | `.artifacts/playground-tools/20251116-051300-learn.txt` |
| `bridge` | Bridge host connectivity (local vs Peekaboo.app/Clawdbot) | N/A | `peekaboo bridge status --json-output` | Verified – local selection + unauthorized host responses are now structured (no EOF) | `.artifacts/playground-tools/20251217-133751-bridge-status.json` |

### Interaction Tools
| Tool | Playground surface | Log category | Sample CLI | Status | Latest log |
| --- | --- | --- | --- | --- | --- |
| `click` | Click Fixture window | `Click` | `peekaboo click "Single Click" --app boo.peekaboo.playground.debug --snapshot <id>` | Verified – Click Fixture E2E incl. double/right/context menu (2025-12-18) | `.artifacts/playground-tools/20251218-004335-click.log`, `.artifacts/playground-tools/20251218-004335-menu.log` |
| `type` | Text Fixture window | `Text` + `Focus` | `peekaboo type "Hello Playground" --clear --snapshot <id>` | Verified – Text Fixture E2E + text-field focusing (2025-12-18) | `.artifacts/playground-tools/20251218-001923-text.log` |
| `press` | Keyboard Fixture window | `Keyboard` | `peekaboo press return --snapshot <id>` | Verified – keypresses + repeats logged (2025-12-17) | `.artifacts/playground-tools/20251217-152138-keyboard.log` |
| `hotkey` | Playground menu shortcuts | `Keyboard` & `Menu` | `peekaboo hotkey --keys "cmd,1"` | Verified – digit hotkeys (2025-12-17) | `.artifacts/playground-tools/20251217-152100-menu.log` |
| `scroll` | Scroll Fixture window | `Scroll` | `peekaboo scroll --direction down --amount 8 --on vertical-scroll --snapshot <id>` | Verified – scroll offsets logged (2025-12-18) | `.artifacts/playground-tools/20251218-012323-scroll.log` |
| `swipe` | Scroll Fixture gesture area | `Gesture` | `peekaboo swipe --from-coords <x,y> --to-coords <x,y>` | Verified – swipe direction + distance logged (2025-12-18), plus long-press hold | `.artifacts/playground-tools/20251218-012323-gesture.log` |
| `drag` | Drag Fixture window | `Drag` | `peekaboo drag --from <elem> --to <elem> --snapshot <id>` | Verified – item dropped into zone (2025-12-18) | `.artifacts/playground-tools/20251218-002005-drag.log` |
| `move` | Click Fixture mouse probe | `Control` | `peekaboo move --on <elem> --snapshot <id> --smooth` | Verified – cursor movement emits deterministic probe logs (2025-12-17) | `.artifacts/playground-tools/20251217-153107-control.log` |

### Windows, Menus, Apps
| Tool | Playground validation target | Log category | Sample CLI | Status | Latest log |
| --- | --- | --- | --- | --- | --- |
| `window` | Window Fixture window + `list windows` bounds | `Window` | `peekaboo window move --app boo.peekaboo.playground.debug --window-title "Window Fixture"` | Verified – focus/move/resize + minimize/maximize covered (2025-12-17) | `.artifacts/playground-tools/20251217-183242-window.log` |
| `space` | macOS Spaces while Playground anchored on Space 1 | `Space` | `peekaboo space list --detailed` | Verified – list/switch/move now emit `[Space]` logs (instr. added 2025-11-16) | `.artifacts/playground-tools/20251116-205548-space.log` |
| `menu` | Playground “Test Menu” | `Menu` | `peekaboo menu click --app boo.peekaboo.playground.debug --path "Test Menu>Submenu>Nested Action A"` | Verified – nested menu click logged (2025-12-18) | `.artifacts/playground-tools/20251218-002308-menu.log` |
| `menubar` | macOS menu extras (Wi-Fi, Clock) plus Playground status icons | `Menu` (system) | `peekaboo menubar list --json-output` | Verified – list + click captured; logs via Control Center predicate | `.artifacts/playground-tools/20251116-053932-menubar.log` |
| `app` | Launch/quit/focus Playground + helper apps (TextEdit) | `App` + `Focus` | `peekaboo app list --include-hidden --json-output` | Verified – Playground app list/switch/hide/launch captured 2025-11-16 | `.artifacts/playground-tools/20251116-195420-app.log` |
| `open` | Open Playground fixtures/documents | `App`/`Focus` | `peekaboo open Apps/Playground/README.md --app TextEdit --json-output` | Verified – TextEdit + browser + no-focus covered 2025-11-16 | `.artifacts/playground-tools/20251116-200220-open.log` |
| `dock` | Dock item interactions w/ Playground icon | `App` + `Window` | `peekaboo dock list --json-output` | Verified – right-click + menu selection now captured with `[Dock]` logs | `.artifacts/playground-tools/20251116-205850-dock.log` |
| `dialog` | Dialogs tab (Save/Open panels + alerts w/ text field) | `Dialog` | `peekaboo dialog list --app Playground` | Verified – use Playground’s built-in dialog fixtures (no TextEdit required) | `.artifacts/playground-tools/20251116-054316-dialog.log` |
| `visualizer` | Visual feedback overlays while Playground is visible | Visual confirmation (overlays render) + JSON dispatch report | `peekaboo visualizer --json-output` | Verified – dispatch report + manual overlay check | `.artifacts/playground-tools/20251217-204548-visualizer.json` |

### Automation & Integrations
| Tool | Playground coverage | Log category | Sample CLI | Status | Latest log |
| --- | --- | --- | --- | --- | --- |
| `agent` | Run natural-language tasks scoped to Playground (“click the single button”) | Captures whichever sub-tools fire (`Click`, `Text`, etc.) | `peekaboo agent "Say hi" --max-steps 1` | Verified – GPT-5.1 runs logged 2025-11-17 (see notes re: tool count bug) | `.artifacts/playground-tools/20251117-011345-agent.log` |
| `mcp` | Verify MCP server can enumerate tools via stdio | `MCP` | `MCPORTER list peekaboo-local --stdio "$PEEKABOO_BIN mcp" --timeout 20` | Verified – MCP tools list captured (2025-12-19) | `.artifacts/playground-tools/20251219-001200-mcp-list.log` |

> **Status Legend:** `Not started` = no logs yet, `In progress` = partial run logged, `Blocked` = awaiting fix, `Verified` = passing with log path recorded.

## Per-Tool Test Recipes
The following subsections spell out the concrete steps, required Playground surface, and expected log artifacts for each tool. Check these off (and bump the status above) as you progress.

### Vision & Capture

#### `see`
- **View**: Any (start with ClickTestingView to guarantee clear elements).
- **Steps**:
  1. Bring Playground to front (`peekaboo app switch --to Playground`).
  2. `peekaboo see --app Playground --output "$LOG_ROOT/see-playground.png"`.
  3. Record snapshot ID printed to stdout, verify `~/.peekaboo/snapshots/<id>/map.json` references Playground elements (`single-click-button`, etc.).
- **Log capture**: Optional `Click` capture if you immediately chain interactions with the new snapshot; otherwise store the PNG + snapshot metadata path.
- **Pass criteria**: Snapshot folder exists, UI map contains Playground identifiers, CLI exits 0.
- **2025-11-16 verification**: Re-enabled the ScreenCaptureKit path inside `Core/PeekabooCore/Sources/PeekabooAutomation/Services/Capture/ScreenCaptureService.swift` so the modern API runs before falling back to CGWindowList. `peekaboo see --app Playground --json-output --path .artifacts/playground-tools/20251116-082056-see-playground.png` now succeeds (snapshot `5B5A2C09-4F4C-4893-B096-C7B4EB38E614`) and drops `.artifacts/playground-tools/20251116-082056-see-playground.{json,png}`.
- **2025-12-17 rerun**: `pnpm run peekaboo -- see --app Playground --path .artifacts/playground-tools/20251217-132837-see-playground.png --json-output > .artifacts/playground-tools/20251217-132837-see-playground.json` succeeded (Peekaboo `main/842434be-dirty`).
#### `image`
- **View**: Keep Playground on ScrollTestingView to capture dynamic content.
- **Steps**:
  1. `peekaboo image window --app Playground --output "$LOG_ROOT/image-playground.png"`.
  2. Repeat with `--screen main --bounds 100,100,800,600` to cover coordinate cropping.
- **2025-11-16 verification**: After restoring the ScreenCaptureKit → CGWindowList fallback order, both window and screen captures succeed. Saved `.artifacts/playground-tools/20251116-082109-image-window-playground.{json,png}` and `.artifacts/playground-tools/20251116-082125-image-screen0.{json,png}`; CLI debug logs still note tiny background windows but the primary Playground window captures at 1200×852.

#### `capture`
- **View**: Any; keep Playground frontmost so the window is captureable.
- **Steps**:
  1. `peekaboo capture live --mode window --app Playground --duration 5 --threshold 0 --json-output > "$LOG_ROOT/capture-live.json"`.
  2. Confirm the JSON points at the expected output directory (kept frames + `contact.png` + `metadata.json`).
  3. Optional: repeat with `--highlight-changes` to ensure highlight rendering doesn’t crash.
- **Video ingest add-on**:
  1. Generate a deterministic motion video: `ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=960x540:rate=30 -t 2 /tmp/peekaboo-capture-src.mp4`.
  2. Run: `peekaboo capture video /tmp/peekaboo-capture-src.mp4 --sample-fps 4 --no-diff --json-output > "$LOG_ROOT/capture-video.json"`.
  3. Confirm `framesKept` ≥ 2 and the output directory contains `keep-*.png`, `contact.png`, and `metadata.json`.
- **MP4 add-on**:
  1. Re-run either live or video ingest with `--video-out /tmp/peekaboo-capture.mp4`.
  2. Confirm the JSON includes `videoOut` and the MP4 exists and is non-empty.
- **Pass criteria**: ≥1 kept frame, `metadata.json` exists, and the run exits 0 (a `noMotion` warning is acceptable for static inputs).
- **Schema check**: Cross-check capture metadata fields in `docs/commands/capture.md` against the JSON payload.
- **2025-12-18 run**:
  - Live window capture (Playground) completed successfully and respects short durations again (no longer stalls ~10s on the ScreenCaptureKit→CG fallback path): `.artifacts/playground-tools/20251218-024517-capture-live-window-fast.json` and `.artifacts/playground-tools/20251218-024517-capture-live-window-fast/`.
  - Video ingest (synthetic `ffmpeg testsrc2`, `--sample-fps 4 --no-diff`) produced 9 kept frames + contact sheet: `.artifacts/playground-tools/20251218-022826-capture-video.json` and `.artifacts/playground-tools/20251218-022826-capture-video/`.

#### `list`
- **Scenarios**: `list apps`, `list windows --app Playground`, `list screens`, `list menubar`, `list permissions`.
- **Steps**:
  1. With Playground running, execute each subcommand and ensure Playground appears with expected bundle ID/window title.
  2. For `list windows`, compare returned bounds vs. WindowTestingView readout.
  3. For `list menubar`, capture the result and cross-check with actual status items.
- **Logs**: Use `playground-log` `Window` category when forcing focus changes to validate `app switch` interplay.
#### `tools`
- **Steps**:
  1. `peekaboo tools > "$LOG_ROOT/tools.txt"`.
  2. Compare entries to the Interaction/Window commands listed here; flag gaps.
- **Verification**: Output includes click/type/etc. with descriptions.

#### `run`
- **Setup**: Create a sample `.peekaboo.json` (store under `docs/testing/fixtures/` once defined) that performs `see`, `click`, `type`, and `scroll`.
- **Steps**:
  1. Start `Keyboard`, `Click`, and `Text` log captures.
  2. `peekaboo run docs/testing/fixtures/playground-smoke.peekaboo.json --output "$LOG_ROOT/run-playground.json" --json-output`.
  3. Confirm each embedded step produced matching log entries (the script opens the Text Fixture window via `⌘⌃2` before running `see`/`click`/`type`).
- **No-fail-fast add-on**:
  1. Run `peekaboo run docs/testing/fixtures/playground-no-fail-fast.peekaboo.json --no-fail-fast --json-output > "$LOG_ROOT/run-no-fail-fast.json"`.
  2. Verify the JSON is a *single* payload (no double-printed JSON) and reports `success=false` with `failedSteps=1`.
  3. Confirm the Playground Click log includes a `Single click` entry even though the script intentionally includes a failing step first.
- **Notes**: Update fixture when tools change to keep coverage aligned.
- **2025-12-17 run**: Updated `docs/testing/fixtures/playground-smoke.peekaboo.json` to open the Text Fixture window (hotkey `⌘⌃2`) and reran successfully: `.artifacts/playground-tools/20251217-173849-run-playground-smoke.json` plus matching OSLog evidence in `.artifacts/playground-tools/20251217-173849-run-playground-smoke-{keyboard,click,text}.log`.

#### `sleep`
- **Steps**:
  1. Run `date +%s` then `peekaboo sleep 2000` within tmux.
  2. Immediately issue a `click` command and ensure the log timestamps show ≥2s gap.
- **Verification**: Playground log lines prove no action fired during sleep window.
- **2025-11-16 run**: Measured via `python - <<'PY' ... subprocess.run(["pnpm","run","peekaboo","--","sleep","2000"]) ...` → actual pause ≈2.24 s (CLI printed `✅ Paused for 2.0s`). No Playground interaction necessary.

#### `clean`
- **Steps**:
  1. Generate two snapshots via `see`.
  2. `peekaboo clean --older-than 1m` and confirm only newest snapshot remains.
  3. Attempt to interact using purged snapshot ID and assert command fails with helpful error.
- **Artifacts**: Directory listing before/after.
- **2025-11-16 run**: Created snapshots `5408D893-…` and `129101F5-…` via back-to-back `see` captures (artifacts saved under `.artifacts/playground-tools/*clean-see*.png`). Ran `peekaboo clean --snapshot 5408D893-…` (freed 453 KB), verified folder removal (`ls ~/.peekaboo/snapshots`). Re-running the same clean command returned “No snapshots to clean”, confirming deletion.
- **2025-12-17 rerun**: Using a cleaned snapshot now yields `SNAPSHOT_NOT_FOUND` for snapshot-scoped commands (instead of `ELEMENT_NOT_FOUND`), which is much clearer for end-to-end scripts.
  - Snapshot + clean: `.artifacts/playground-tools/20251217-201134-see-for-snapshot-missing.json`, `.artifacts/playground-tools/20251217-201134-clean-snapshot.json`
  - Command failures:
    - `.artifacts/playground-tools/20251217-201134-click-snapshot-missing.json`
    - `.artifacts/playground-tools/20251217-201134-move-snapshot-missing.json`
    - `.artifacts/playground-tools/20251217-201134-scroll-snapshot-missing.json`
    - `.artifacts/playground-tools/20251217-202239-snapshot-missing-drag.json`
    - `.artifacts/playground-tools/20251217-202239-snapshot-missing-swipe.json`
    - `.artifacts/playground-tools/20251217-202239-snapshot-missing-type.json`
    - `.artifacts/playground-tools/20251217-202239-snapshot-missing-hotkey.json`
    - `.artifacts/playground-tools/20251217-202239-snapshot-missing-press.json`

#### `clipboard`
- **Steps**:
  1. Scripted smoke: `peekaboo run docs/testing/fixtures/clipboard-smoke.peekaboo.json --json-output > "$LOG_ROOT/clipboard-smoke.json"`.
  2. Cross-invocation save/restore: `peekaboo clipboard --action save --slot original`, then `--action clear`, then `--action restore --slot original`.
  3. File payload: `peekaboo clipboard --action set --file-path /tmp/peekaboo-clipboard-smoke.txt --json-output`.
  4. Image payload + export: `peekaboo clipboard --action set --image-path assets/peekaboo.png --also-text "Peekaboo clipboard image smoke" --json-output`, then `peekaboo clipboard --action get --prefer public.png --output /tmp/peekaboo-clipboard-out.png --json-output`.
- **Pass criteria**: Script succeeds and clipboard is restored.
- **2025-12-17 CLI evidence**: `.artifacts/playground-tools/20251217-192349-clipboard-{save-original,set-file,get-file-text,set-image,get-image,restore-original}.json` plus exported `/tmp/peekaboo-clipboard-out.png`.

#### `config`
- **Focus**: `config show`, `config validate`, `config models-provider`.
- **Steps**:
  1. Snapshot `~/.peekaboo/config.json` (read-only).
  2. Run `peekaboo config validate --verbose`.
  3. Document provider list for later cross-check.
- **Notes**: No Playground tie-in; just ensure CLI stability.
- **2025-11-16 run**: `peekaboo config show --effective --json-output > .artifacts/playground-tools/20251116-051200-config-show-effective.json` plus `peekaboo config validate` both succeeded; output confirms OpenAI key set + default save path. No edits performed.

#### `permissions`
- **Steps**:
  1. `peekaboo permissions status` to confirm Accessibility/Screen Recording show Granted.
  2. If a permission is missing, follow docs/permissions.md to re-grant and note the steps.
  3. Capture console output.
- **2025-11-16 run**: `peekaboo permissions status --json-output > .artifacts/playground-tools/20251116-051000-permissions-status.json` returned both Screen Recording and Accessibility as granted (matching expectations); no Playground interaction required.

#### `learn`
- **Steps**: `peekaboo learn > "$LOG_ROOT/learn-latest.txt"`; record commit hash displayed at top.
- **2025-11-16 run**: Saved `.artifacts/playground-tools/20251116-051300-learn.txt` for reference; includes commit metadata from peekaboo binary.

#### `bridge`
- **Steps**:
  1. `peekaboo bridge status` and confirm it reports local execution vs. a remote host (Peekaboo.app / Clawdbot).
  2. `peekaboo bridge status --verbose --json-output > "$LOG_ROOT/bridge-status.json"` and sanity-check the selected host + probed sockets.
  3. Repeat with `--no-remote` to confirm local-only mode is explicit and stable.
- **Unauthorized host behavior**:
  - If a remote host rejects the CLI due to TeamID allowlisting, the host should reply with `unauthorizedClient` (not close the socket/EOF).
  - This is regression-covered by `Apps/CLI/Tests/CoreCLITests/PeekabooBridgeHostUnauthorizedResponseTests.swift` (landed 2025-12-18).
- **Pass criteria**: Clear host selection output and no crashes.
- **2025-12-18 run**:
  - Remote sockets were probed but both candidates returned `internalError` (“Bridge host returned no response”), so the CLI selected `source=local` as expected.
  - Note: this typically indicates an older Peekaboo/Clawdbot host build. Hosts built from `main` after 2025-12-18 should respond with a structured `unauthorizedClient` error instead.
  - Evidence: `.artifacts/playground-tools/20251218-022612-bridge-status.json`, `.artifacts/playground-tools/20251218-022612-bridge-status-verbose.json`, `.artifacts/playground-tools/20251218-022612-bridge-status-no-remote.json`.

### Interaction Tools

#### `click`
- **View**: ClickTestingView.
- **Log capture**: `./Apps/Playground/scripts/playground-log.sh -c Click --last 10m --all -o "$LOG_ROOT/click-$(date +%s).log"`.
- **Test cases**:
  1. Query-based click: `peekaboo click "Single Click"` (expect `Click` log + counter increment).
  2. ID-based click: copy the opaque ID from current `see` output, then run `peekaboo click --on "$ELEMENT_ID" --snapshot <id>` targeting `single-click-button`.
  3. Coordinate click: `peekaboo click --coords 400,400 --foreground` hitting the nested area.
  4. Coordinate validation: `peekaboo click --coords , --json-output` should fail with `VALIDATION_ERROR` (no crash).
  5. Error path: attempt to click disabled button and confirm descriptive `elementNotFound` guidance.
- **Verification**: Playground counter increments, log file shows `[Click] Single click...` entries.
- **2025-11-16 run**:
  - Captured Click logs to `.artifacts/playground-tools/20251116-051025-click.log`.
  - Generated fresh snapshot `263F8CD6-E809-4AC6-A7B3-604704095011` via `see` (`.artifacts/playground-tools/20251116-051120-click-see.{json,png}`).
  - `peekaboo click "Single Click" --snapshot <legacy snapshot>` succeeded but targeted Ghostty (click hit terminal input); highlighting importance of focusing Playground first.
  - `peekaboo app switch --to Playground` followed by `peekaboo click --on elem_6 --snapshot 263F8CD6-...` successfully hit the “View Logs” button (Playground log recorded the click).
  - Coordinate click `--coords 600,500` succeeded (see log); attempting `--on elem_disabled` produced expected `elementNotFound` error.
  - Element IDs are opaque and unstable; always copy the exact ID from current `see` output.
- **2025-12-17 Controls Fixture add-on**:
  - Open “Controls Fixture” via `⌘⌃3`, then drive checkboxes + segmented control by clicking snapshot IDs (`--on elem_…`) captured from `see`.
  - **Important**: ControlsView is scrollable; after any `scroll`, re-run `see` before clicking elements further down (otherwise snapshot coordinates can be stale).
  - Evidence: `.artifacts/playground-tools/20251217-230454-control.log` plus `.artifacts/playground-tools/20251217-230454-see-controls-top.json` and `.artifacts/playground-tools/20251217-230454-see-controls-progress.json`.

#### `type`
- **View**: TextInputView.
- **Log capture**: `Text` + `Focus` categories.
- **Test cases**:
  1. `peekaboo type "Hello Playground" --query "Basic"` to fill the basic field.
  2. Use `--clear` then `--append` flows to verify editing.
  3. Tab-step typing with `--tabs 2` into the secure field.
  4. Unicode input (emoji) to ensure no crash.
- **Verification**: Field contents update, log shows `[Text] Basic field changed` entries.
- **2025-11-16 run**:
  - Logged `.artifacts/playground-tools/20251116-051202-text.log`.
  - Focused field via `peekaboo click "Focus Basic Field" --snapshot 263F8CD6-…` (snapshot from `.artifacts/playground-tools/20251116-051120-click-see.json`).
  - `peekaboo type "Hello Playground" --clear --snapshot 263F8CD6-…` updated the Basic Text Field (log shows “Basic text changed …”).
  - `peekaboo type --tab 1 --snapshot 263F8CD6-…` advanced focus to the Number field, followed by `peekaboo type "42" --snapshot 263F8CD6-…`.
  - Validation error confirmed via `peekaboo type "bad" --profile warp` (proper error message).
  - Note: prefer `--app`, `--pid`, `--window-id`, or `--snapshot` so `type` can use background delivery; use helper buttons and `click` to set field focus when a view requires it. Legacy `--on` / `--query` flags no longer exist.

#### `press`
- **View**: KeyboardView “Key Press Detection” field (Keyboard tab).
- **Test cases**:
  1. `peekaboo press return --snapshot <id>` after focusing the detection text field.
  2. `peekaboo press up --count 3 --snapshot <id>` to ensure repeated presses log individually.
  3. Invalid key handling (`peekaboo press foo`) should error.
- **2025-11-16 verification**:
  - Switched to the Keyboard tab via `peekaboo hotkey --keys "cmd,option,7"`, captured `.artifacts/playground-tools/20251116-090141-see-keyboardtab.{json,png}` (snapshot `C106D508-930C-4996-A4F4-A50E2E0BA91A`), and focused the “Press keys here…” field with a coordinate click (`--coords 760,300`).
  - `peekaboo press return --snapshot C106D508-…` and `peekaboo press up --count 3 --snapshot C106D508-…` produced `[boo.peekaboo.playground:Keyboard] Key pressed: …` entries in `.artifacts/playground-tools/20251116-090455-keyboard.log`.
  - `peekaboo press foo` reports `Unknown key: 'foo'. Run 'peekaboo press --help' for available keys.` confirming validation and documenting the negative path.

#### `hotkey`
- **View**: KeyboardView hotkey demo or main window (use `cmd+shift+l` to open log viewer).
- **Test cases**:
  1. `peekaboo hotkey cmd,shift,l` should toggle the “Clear All Logs” command (log viewer clears entries).
  2. `peekaboo hotkey cmd,1` to trigger Test Menu action; watch `Menu` logs.
  3. Negative test: provide invalid chord order to ensure validation message.
- **Verification**: Playground `Keyboard` log file shows the keystrokes fired.
- **2025-11-16 run**:
  - Logs stored at `.artifacts/playground-tools/20251116-051654-keyboard-hotkey.log` (contains entries for `L` and `1` corresponding to the combos).
  - `peekaboo hotkey --keys "cmd,shift,l" --snapshot 11227301-05DE-4540-8BE7-617F99A74156` (clears logs via shortcut).
  - `peekaboo hotkey --keys "cmd,1" --snapshot …` switches Playground tabs.
  - `peekaboo hotkey --keys "foo,bar"` correctly fails with `Unknown key: 'foo'`.

#### `scroll`
- **View**: ScrollTestingView vertical/horizontal sections (switch using `peekaboo hotkey --keys "cmd,option,4"` to trigger the new Test Menu shortcut).
- **Test cases**:
  1. `peekaboo scroll --direction down --amount 6 --snapshot <id>` for vertical movement.
  2. `peekaboo scroll --direction right --amount 4 --smooth --snapshot <id>` for horizontal smooth scrolling.
  3. `peekaboo scroll --direction down --amount 6 --on vertical-scroll --snapshot <id>` and `... --direction right --amount 4 --on horizontal-scroll --snapshot <id>` to prove the new identifiers work end-to-end.
  4. Nested scroll targeting: `--on nested-inner-scroll` and `--on nested-outer-scroll` (Scroll Fixture “Nested Scroll Views” section).
- **2025-11-16 verification**:
  - Captured snapshot `.artifacts/playground-tools/20251116-194615-see-scrolltab.json` (snapshot `649EB632-ED4B-4935-9F1F-1866BB763804`) and re-ran both `scroll` commands with `--on vertical-scroll` and `--on horizontal-scroll`. The CLI outputs live at `.artifacts/playground-tools/20251116-194652-scroll-vertical.json` and `.artifacts/playground-tools/20251116-194708-scroll-horizontal.json` (both ✅ now that the Playground view exposes identifiers and the ScrollService snapshot cache preserves them).
  - Added `.artifacts/playground-tools/20251116-194730-scroll.log` via `./Apps/Playground/scripts/playground-log.sh -c Scroll --last 10m --all -o …`; it shows the `[Scroll] direction=down` and `[Scroll] direction=right` events emitted by AutomationEventLogger.
- **2025-12-17 rerun**:
  - Re-validated Scroll Fixture window-scoped scrolling (vertical/horizontal + nested target commands) with `.artifacts/playground-tools/20251217-222958-scroll.log`.
- **2025-12-18 rerun**:
  - Verified Scroll Fixture again, but this time with **another app frontmost** (Ghostty) to prove auto-focus uses snapshot metadata reliably even when `see` snapshots do **not** include `windowID`.
  - Evidence:
    - `.artifacts/playground-tools/20251218-012323-scroll.log` (Scroll offsets + nested inner/outer offsets logged by Playground).
    - `.artifacts/playground-tools/20251218-012323-click-scroll-{top,middle,bottom}.json` (Clicking fixture buttons via snapshot IDs).
    - `.artifacts/playground-tools/20251218-012323-scroll-{vertical-down,vertical-up,horizontal-right,horizontal-left,nested-outer-down,nested-inner-down}.json` (CLI evidence per scroll variant).

#### `swipe`
- **View**: Gesture Testing area.
- **Test cases**:
  1. `peekaboo swipe --from-coords 1100,520 --to-coords 700,520 --duration 600`.
  2. `peekaboo swipe --from-coords 850,600 --to-coords 850,350 --duration 800 --profile human`.
  3. Negative test: `peekaboo swipe … --right-button` should error.
- **2025-11-16 verification**:
  - Used snapshot `DBFDD053-4513-4603-B7C3-9170E7386BA7` (see `.artifacts/playground-tools/20251116-085714-see-scrolltab.{json,png}`) to keep the tab selection stable.
  - Horizontal and vertical commands above completed successfully; Playground log `.artifacts/playground-tools/20251116-090041-gesture.log` shows `[boo.peekaboo.playground:Gesture]` entries with exact coordinates, profiles, and step counts.
  - `peekaboo swipe --from-coords 900,520 --to-coords 700,520 --right-button` returns `Right-button swipe is not currently supported…`, matching expectations.
- **2025-12-18 rerun**:
  - Verified swipe-direction logging + long-press detection on the Scroll Fixture gesture tiles.
  - Evidence: `.artifacts/playground-tools/20251218-012323-gesture.log` plus `.artifacts/playground-tools/20251218-012323-swipe-right.json` and `.artifacts/playground-tools/20251218-012323-long-press.json`.

#### `drag`
- **View**: DragDropView (tab is hidden on launch—run `peekaboo click --snapshot <id> --on elem_79` right after `see` to activate the “Drag & Drop” tab radio button).
- **Test cases**:
  1. Drag Item A (`elem_15`) into drop zone 1 (`elem_24`) via `--from/--to`.
  2. Drag Item B (`elem_17`) into drop zone 2 (`elem_26`) and capture JSON output for artifacting.
  3. (Optional) Drag the reorderable list rows (`elem_37`…`elem_57`) once additional coverage is needed.
- **2025-11-16 verification**:
  - A reusable `PlaygroundTabRouter` + header “Go to Drag & Drop” control keep the TabView state predictable, and more importantly `elem_79` now works deterministically—clicking it flips the TabView so subsequent `see` runs expose DragDropView element IDs (see `.artifacts/playground-tools/20251116-085142-see-afterclick-elem79.{json,png}` with snapshot `BBF9D6B9-26CB-4370-8460-6C8188E7466C`).
  - `peekaboo drag --snapshot BBF9D6B9-26CB-4370-8460-6C8188E7466C --from elem_15 --to elem_24 --duration 800 --steps 40` succeeded; Playground log `.artifacts/playground-tools/20251116-085233-drag.log` shows “Started dragging: Item A”, “Hovering over zone1”, and “Item dropped… zone1”, plus the CLI-side `[boo.peekaboo.playground:Drag] drag from=…` entry.
  - Captured a second run with JSON output (`.artifacts/playground-tools/20251116-085346-drag-elem17.json`) dragging Item B to zone2 so we have structured metadata (coords, duration, profile) for regression diffs.
  - We still keep the older coordinate-only recipe around as a fallback, but the default regression loop is now: **focus Playground → `see` → `click --on elem_79` → `drag --snapshot … --from elem_XX --to elem_YY` → archive the Drag log + CLI JSON.**
- **2025-12-17 Controls Fixture add-on**:
  - Slider adjustment works via `drag` when you compute a `--to-coords` inside the slider’s frame using the snapshot JSON.
  - Evidence: `.artifacts/playground-tools/20251217-230454-drag-slider.json` and the corresponding `[Control] Slider moved …` lines in `.artifacts/playground-tools/20251217-230454-control.log`.

#### `move`
- **View**: ClickTestingView (target nested button) or ScrollTestingView.
- **Test cases**:
  1. `peekaboo move 600,600` for instant pointer relocation.
  2. Smooth query-based move: `peekaboo move --to "Focus Basic Field" --snapshot <id> --smooth`.
  3. `peekaboo move --center --duration 300 --steps 15`.
  4. `peekaboo move --coords 600,600` (alias coverage).
  5. Negative test: `peekaboo move 1,2 --center` should error (conflicting targets).
- **2025-11-16 verification**:
  - Commands above rerun with snapshot `DBFDD053-4513-4603-B7C3-9170E7386BA7`; CLI outputs saved implicitly (no JSON mode). Pointer jumps succeeded (`move 600,600`, `move --center`).
  - `move --to "Focus Basic Field" --snapshot ... --smooth` works with snapshot-based targeting; repeated runs confirm the lookup is stable.
  - Focus logger still doesn’t capture these events (`playground-log -c Focus` remains empty), so we rely on CLI output for evidence until instrumentation is added.
- **2025-12-17 re-verification**:
  - `--coords` is now accepted (Commander metadata updated) and treated as an alias for the positional coordinates.
  - Conflicting targets now fail at runtime (MoveCommand explicitly runs `validate()` before executing).
  - Playground evidence loop using Click Fixture probe:
    - Snapshot: `.artifacts/playground-tools/20251217-194922-see-click-fixture.json`
    - CLI: `.artifacts/playground-tools/20251217-194947-move-coords-probe.json`
    - Playground logs: `.artifacts/playground-tools/20251217-195012-move-out-control.log` (contains `Mouse entered probe area` / `Mouse exited probe area`).

### Windows, Menus, Apps

#### `window`
- **View**: WindowTestingView (or any app with a movable window; Playground itself works for focus/move/resize).
- **Test cases**:
  1. `peekaboo window focus --app Playground`.
  2. `peekaboo window move --app Playground -x 100 -y 100`.
  3. `peekaboo window resize --app Playground --width 900 --height 600`.
  4. `peekaboo window set-bounds --app Playground --x 200 --y 200 --width 1100 --height 700`.
  5. `peekaboo window list --app Playground --json-output`.
- **2025-11-16 verification**:
  - Commands rerun with Playground as the target: `.artifacts/playground-tools/20251116-194858-window-list-playground.json`, `...-window-move-playground.json`, `...-window-resize-playground.json`, `...-window-setbounds-playground.json`, and `...-window-focus-playground.json` capture each CLI invocation.
  - Window log `.artifacts/playground-tools/20251116-194900-window.log` shows `[Window] focus`, `move`, `resize`, and `set_bounds` entries with updated bounds, confirming instrumentation now covers the Playground window itself.
- **2025-12-18 regression fix**:
  - `window list` no longer returns duplicate entries for the same `window_id` (which previously happened for Playground’s fixture windows, confusing scripts that key off `window_id`).
  - Evidence: `.artifacts/playground-tools/20251218-022217-window-list-playground-dedup.json` (no duplicate `window_id` values).

#### `space`
- **Scenario**: Single Space (current setup). Need additional Space to test multi-space behavior.
- **Test cases**:
  1. `peekaboo space list --detailed --json-output`.
  2. `peekaboo space switch --to 1` (happy path) and expect error for `--to 2` when only one Space exists.
  3. `peekaboo space move-window --app Playground --window-index 0 --to 1 --follow`.
- **2025-11-16 run**:
  - Latest artifacts: `.artifacts/playground-tools/20251116-205527-space-list.json`, `...205532-space-list-detailed.json`, `...205536-space-switch-1.json`, `...205541-space-move-window.json`, plus `...195602-space-switch-2.json` for the expected validation error.
  - AutomationEventLogger now emits `[Space]` entries (list count + actions) captured via `.artifacts/playground-tools/20251116-205548-space.log`.
  - Still only one desktop (Space IDs 1-1), so the `--to 2` path continues to produce `VALIDATION_ERROR (Available: 1-1)` as designed.

#### `menu`
- **View**: Playground’s “Test Menu” items (standard menu bar). Context menus on the `right-click-area` still require `click` rather than `menu` because `menu click` doesn’t accept coordinate targets yet.
- **Test cases**:
  1. `peekaboo menu click --app Playground --path "Test Menu>Test Action 1"`.
  2. `peekaboo menu click --app Playground --path "Test Menu>Submenu>Nested Action A"`.
  3. Disabled menu handling: `peekaboo menu click --app Playground --path "Test Menu>Disabled Action"` should fail with a descriptive error.
- **2025-11-16 verification**:
  - Re-ran the command set; artifacts include `.artifacts/playground-tools/20251116-195020-menu-click-action.json`, `...195024-menu-click-submenu.json`, and `...195022-menu-click-disabled.json` (the last exits with `INTERACTION_FAILED` and message `Menu item is disabled: ...`).
  - Playground Menu log `.artifacts/playground-tools/20251116-195020-menu.log` now shows each click (`Test Action 1`, `Submenu > Nested Action A`, and the disabled error), proving `AutomationEventLogger` coverage.
  - Context menu coverage is verified via `click --right` on the Click Fixture: `.artifacts/playground-tools/20251217-165443-context-menu.log` contains `Context menu: Action 1/2/Delete` entries emitted by Playground.
- **2025-12-18 re-verification**:
  - Confirmed a “real world” nested menu path with spaces (`Fixtures > Open Window Fixture`) opens the expected window.
  - Evidence: `.artifacts/playground-tools/20251218-021541-menu-open-windowfixture.json` + `.artifacts/playground-tools/20251218-021541-window.log` (Window became key for “Window Fixture”).

#### `menubar`
- **Target**: macOS status items (Wi-Fi, Battery) or custom extras.
- **Test cases**:
  1. `peekaboo menubar list --json-output > .artifacts/playground-tools/20251116-141824-menubar-list.json`.
  2. `peekaboo menubar click "Wi-Fi"` (or `--index 9`) and close Control Center manually afterward.
  3. `peekaboo menubar click --index 2` to exercise Control Center by index.
- **2025-11-16 run**: Commands above succeeded; no dedicated Playground log yet (menu bar actions don’t flow through the app logger). The new list artifact reflects the current order, and the CLI output confirms the clicked items (Wi-Fi and Control Center).

#### `app`
- **Scenarios**:
  1. `peekaboo app list --include-hidden --json-output > $LOG_ROOT/app-list.json`
  2. `peekaboo app switch --to Playground`
  3. `peekaboo app hide --app Playground` / `peekaboo app unhide --app Playground`
  4. `peekaboo app launch "TextEdit" --json-output` followed by `peekaboo app quit --app TextEdit --json-output`
- **2025-11-16 verification**:
  - Re-ran the flow: `.artifacts/playground-tools/20251116-195420-app-list.json`, `...195421-app-switch.json`, `...195422-app-hide.json`, `...195423-app-unhide.json`, `...195424-app-launch-textedit.json`, and `...195425-app-quit-textedit.json` capture the CLI outputs.
  - App log `.artifacts/playground-tools/20251116-195420-app.log` shows the matching `[App] list`, `switch`, `hide`, `unhide`, `launch`, and `quit` entries with bundle IDs + PIDs.

#### `open`
- **Tests**:
  1. `peekaboo open Apps/Playground/README.md --app TextEdit --json-output > .artifacts/playground-tools/20251116-091415-open-readme-textedit.json`.
  2. `peekaboo open https://example.com --json-output > .artifacts/playground-tools/20251116-091422-open-example.json`.
  3. `peekaboo open Apps/Playground/README.md --app TextEdit --no-focus --json-output > .artifacts/playground-tools/20251116-091435-open-readme-textedit-nofocus.json`.
- **2025-11-16 verification**: Latest run captured `.artifacts/playground-tools/20251116-200220-open.log` with the three `[Open]` entries (TextEdit focus, browser focus, TextEdit `--no-focus`), alongside the corresponding CLI JSON artifacts.

#### `dock`
- **Tests**:
  1. `peekaboo dock list --json-output` (artifact `.artifacts/playground-tools/20251116-200750-dock-list.json`).
  2. `peekaboo dock launch Playground`.
  3. `peekaboo dock hide` / `peekaboo dock show`.
  4. `peekaboo dock right-click --app Finder --select "New Finder Window"` (JSON artifact `.artifacts/playground-tools/20251116-205828-dock-right-click.json`).
- **2025-11-16 verification**:
  - `[Dock]` logger entries captured via `.artifacts/playground-tools/20251116-205850-dock.log` show `list`, `launch Playground`, `hide`, `show`, and the Finder right-click with `selection=New Finder Window`.
  - Context menu selection works once Finder is present in the Dock; if the menu doesn’t surface, re-run after focusing the Dock. No additional code changes required.

#### `dialog`
- **Scenario**: Use Playground’s Dialogs tab to spawn deterministic Save/Open panels and alerts.
- **Steps to spawn dialogs**:
  1. Launch Playground and switch to the Dialogs tab (Header button “Go to Dialogs”).
  2. Click “Show Save Panel” (or “Show Save Panel (Overwrite /tmp)” to exercise Replace flows). Use “Show Save Panel (TextEdit-like)” to add a file-format accessory view + tags field closer to real-world apps.
  3. Optional: Click “Show Alert (Text Field)” to exercise `dialog input` against a sheet-local text field.
- **Tests**:
  1. `peekaboo dialog list --app Playground --json-output > .artifacts/playground-tools/<timestamp>-dialog-list.json`.
  2. `peekaboo dialog click --button "Cancel" --app Playground --json-output > .artifacts/playground-tools/<timestamp>-dialog-click-cancel.json`.
  3. (Alert w/ text field) `peekaboo dialog input --app Playground --index 0 --text "NAME0" --clear --json-output > .artifacts/playground-tools/<timestamp>-dialog-input.json`.
  4. (Save panel) `peekaboo dialog file --app Playground --path /tmp --name playground-dialog-out.txt --ensure-expanded --select default --json-output > .artifacts/playground-tools/<timestamp>-dialog-file-save.json`.
- **Verification notes**:
  - Prefer Playground’s Dialogs tab over TextEdit for repeatable coverage (no “dirty document” preconditions).
  - Capture a Playground log excerpt for each run (category `Dialog`) so the result is verifiable without screenshots.

#### `visualizer`
- **Setup**: Ensure `Peekaboo.app` is running (visual feedback host) and keep Playground visible so you can quickly spot overlays.
- **Steps**:
  1. `peekaboo visualizer --json-output > .artifacts/playground-tools/<timestamp>-visualizer.json`
  2. Visually confirm you see (in order): screenshot flash, capture HUD, cursor click, typing overlay, scroll indicator, cursor movement trail, swipe path, hotkey HUD, window move overlay, app launch/quit animation, menu breadcrumb, dialog highlight, space switch indicator, and element detection overlay.
- **Pass criteria**: No CLI errors, the JSON report shows every step `dispatched=true`, and the full overlay sequence renders end-to-end.
- **2025-12-18 run**:
  - JSON reports all 15 steps `dispatched=true` (manual “eyes on overlay” still required for full pass criteria).
  - Evidence: `.artifacts/playground-tools/20251218-022612-visualizer.json`.

### Automation & Integrations

#### `agent`
- **Scope**: Playground-specific instructions to exercise multiple tools automatically.
- **Tests**:
  1. `peekaboo agent --model gpt-5.5 --list-sessions --json-output > .artifacts/playground-tools/20251117-010912-agent-list.json`.
  2. `peekaboo agent "Say hi to the Playground app." --model gpt-5.5 --max-steps 2 --json-output > .artifacts/playground-tools/20251117-010919-agent-hi.json`.
  3. `peekaboo agent "Switch to Playground and press the Single Click button once." --model gpt-5.5 --max-steps 4 --json-output > .artifacts/playground-tools/20251117-010935-agent-single-click.json`.
  4. For long interactive runs, use tmux: `tmux new-session -- bash -lc 'peekaboo agent "Click the Single Click button in Playground." --model gpt-5.5 --max-steps 6 --no-cache | tee .artifacts/playground-tools/20251117-011500-agent-single-click.log'`.
  5. Spot-check metadata: `peekaboo agent "Say hi to Playground again." --model gpt-5.5 --max-steps 2 --json-output > .artifacts/playground-tools/20251117-012655-agent-hi.json`.
- **2025-11-17 run**:
  - GPT-5.5 executes happily; Playground `[Agent]` log is captured in `.artifacts/playground-tools/20251117-011345-agent.log`.
  - Non-tmux invocations can time out; move anything beyond quick dry-runs into `tmux ...` so long runs complete.
  - Manual verification: observed the agent perform `see` + `click` against the Playground “Single Click” button (tmux transcript stored in `.artifacts/playground-tools/20251117-011500-agent-single-click.log`).
  - JSON mode now reports the correct `toolCallCount` (see `.artifacts/playground-tools/20251117-012655-agent-hi.json` which shows `toolCallCount: 1` for the `done` tool).

#### `mcp`
- **Steps**:
  1. `MCPORTER list peekaboo-local --stdio "$PEEKABOO_BIN mcp" --timeout 20 --schema > .artifacts/playground-tools/20251219-001230-mcp-list.json`.
  2. `MCPORTER call peekaboo-local.permissions --stdio "$PEEKABOO_BIN mcp" --timeout 15 > .artifacts/playground-tools/20251219-001245-mcp-call-permissions.json`.
  3. Capture the OSLog stream with `./Apps/Playground/scripts/playground-log.sh -c MCP --last 15m --all -o .artifacts/playground-tools/20251219-001255-mcp.log`.
- **2025-12-19 verification**:
  - `MCPORTER list` returns the native Peekaboo tool catalog via stdio.
  - `permissions` call returns the expected `Screen Recording` + `Accessibility` statuses.
  - Playground `[MCP]` log records the server requests for later regression diffs.

## Reporting & Follow-Up
- Record every executed test case (command, arguments, snapshot ID, log file path, outcome) in `Apps/Playground/PLAYGROUND_TEST.md`.
- When a bug is fixed, update this doc’s table row to `Verified` and link to the log artifact plus commit hash.
- If a tool is blocked (e.g., Swift compiler crash), set status to `Blocked`, explain the reason inline, and add a TODO referencing the GitHub issue/Swift crash log.
- Keep this plan synchronized with any changes under `docs/commands/`—when new tools land, add rows + recipes immediately so coverage never regresses.
