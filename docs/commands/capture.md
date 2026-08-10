---
summary: 'Capture live screens/windows or ingest video; adaptive frames + contact sheet'
read_when:
  - 'using peekaboo capture'
  - 'automating long-running visual captures'
---

# `peekaboo capture`

`capture` replaces `watch` as the unified long-running capture tool. It has three subcommands:

- `capture live` — adaptive PNG burst capture of screens/windows/regions with idle/active FPS, diff-based frame keeping, contact sheet, and metadata.
- `capture action` — start adaptive live capture, run a child command, keep post-roll, stop early, and validate output artifacts.
- `capture video` — ingest an existing video, sample frames (by FPS or interval), optionally skip diff filtering, and emit the same outputs.

The MCP server exposes the same primitive as the `capture` tool. MCP arguments use snake_case names such as `duration_seconds`, `active_fps`, `threshold_percent`, `output_dir`, and `video_out`.

`capture live` is the only spelling for live capture.

## Common Outputs
- PNG frames (kept frames only)
- `contact.png` contact sheet
- `metadata.json` (`CaptureResult`) with stats, warnings, grid info, and source (live|video)
- Optional MP4 (`--video-out`) built from kept frames

For `capture video`, `metadata.json` and JSON stdout include `options.video` with the requested sampling/trim options plus the effective FPS used by the frame reader.

## `capture live` flags
- Targeting: `--mode screen|window|frontmost|area`, `--screen-index`, `--app`, `--pid`, `--window-title`, `--window-index`, `--region x,y,width,height` (global coords)
- Focus: `--capture-focus background|foreground|auto`; background is the default, foreground explicitly activates the target, and auto is the legacy focus-if-needed mode.
- Cadence: `--duration` (<=`180s`; bare values are milliseconds), `--idle-fps`, `--active-fps`, `--threshold`, `--heartbeat`, `--quiet`
- Caps: `--max-frames` (default 800), `--max-mb`
- Diff/output: `--highlight-changes`, `--resolution-cap` (default 1440), `--diff-strategy fast|quality`, `--diff-budget`, `--video-out <path>`
- Paths: `--path <dir>` (default temp `capture-sessions/capture-<uuid>`), `--autoclean <duration>` (default `7200s`)

## `capture action` flags
- Targeting/focus/cadence/caps/output: same as `capture live`, except `--duration` is replaced by `--duration-limit` (default `60s`, max `180s`; bare values are milliseconds).
- Action timing: `--pre-roll` (default `250ms`), `--post-roll` (default `500ms`), `--action-timeout` (defaults to the remaining duration after roll time).
- Command: pass the child command after `--`, e.g. `peekaboo capture action -- echo smoke`. Commander also accepts `--command -- echo smoke`, but the `--` form is clearer for commands with their own flags.

The command exits non-zero if the child command exits non-zero, times out, or required capture artifacts are missing/empty. JSON output includes the child command exit code/stdout/stderr, the normal `CaptureResult`, and artifact validation details.

## `capture video` flags
- Required: `--input <video>` (positional `input` argument)
- Sampling: `--sample-fps <fps>` (default 2) XOR `--every <duration>`
- Trim: `--start <duration>`, `--end <duration>`
- Diff: `--no-diff` (keep all sampled frames); otherwise uses diff/keep logic
- Caps/output: `--max-frames`, `--max-mb`, `--resolution-cap` (default 1440), `--diff-strategy`, `--diff-budget`, `--video-out`
- Paths: `--path`, `--autoclean`

Validation: video source rejects targeting/focus/cadence flags; live rejects sampling/trim/no-diff. Video runs may keep a single frame when no motion is detected (emits a `noMotion` warning) instead of failing.

## Examples
```bash
# Live, change-aware capture of frontmost window for 45s
peekaboo capture live --duration 45s --idle-fps 1 --active-fps 8 --threshold 2.0

# Live, target specific screen, MP4 output
peekaboo capture live --mode screen --screen-index 1 --video-out /tmp/capture.mp4

# Live, record an explicit desktop region; --region also infers area mode
peekaboo capture live --region 100,120,640,360 --duration 10s

# Capture a command-driven flow with pre/post-roll and JSON proof
peekaboo capture action --duration-limit 10s --json -- ./test-flow.sh --smoke

# Video ingest, sample 2 fps, trim first 5s
peekaboo capture video /path/to/demo.mov --sample-fps 2 --start 5s --video-out /tmp/demo.mp4

# Video ingest, keep all sampled frames at 500ms interval (no diff filtering)
peekaboo capture video /path/to/demo.mov --every 500ms --no-diff
```

## Design notes
- Live defaults: max duration 180s, `--max-frames` 800, resolution cap 1440, diff strategy `fast` unless `--diff-strategy quality` is set.
- Action capture uses the same live sampler and can stop it early once the child command and post-roll complete.
- Background live capture of an exact PID/window reacquires a generation-pinned read lane for each frame. Unrelated app mutations can overlap, while a queued mutation for the captured process runs before the next frame. Screen, area, frontmost, unresolved, foreground, and focus-capable observations remain globally exclusive.
- Video ingest uses the same diff/keep logic as live; `--no-diff` keeps every sampled frame. When no motion is detected, you may end up with a single kept frame plus a `noMotion` warning.
- Core types: `CaptureScope/Options/Result` with a pluggable `CaptureFrameSource` (ScreenCapture for live, AVAssetReader for video). Optional MP4 is written by `VideoWriter` when `--video-out` is set.
- Quick smokes:
  - `peekaboo capture live --mode screen --duration 5s --active-fps 8 --threshold 0` → frames > 0, contact sheet exists.
  - `peekaboo capture video /path/demo.mov --sample-fps 2 --start 5s --video-out /tmp/demo.mp4` → ≥2 kept frames and MP4 written.

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- In SSH, LaunchAgent, Codex, and other background launchd sessions, prefer a Bridge host with Screen Recording.
  Legacy screen/area capture now rejects wallpaper-only or redacted false-success frames instead of writing them as
  valid output. Use `--no-remote --capture-engine cg` only when the caller is in the active Aqua session and has TCC.
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
