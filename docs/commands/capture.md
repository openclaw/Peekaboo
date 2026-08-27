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

The MCP `capture` tool exposes the live and video forms. Arbitrary child execution in `capture action` remains CLI-only. MCP arguments use snake_case names such as `duration_seconds`, `active_fps`, `threshold_percent`, `output_dir`, and `video_out`.

`capture live` is the only spelling for live capture.

## Common Outputs
- PNG frames (kept frames only)
- `contact.png` contact sheet
- `metadata.json` (`CaptureResult`) with stats, warnings, grid info, and source (live|video)
- `action.json` for `capture action`, with the action timeline/result, capture route and authenticated host identity, actual retained-frame engines, and hashes for every published artifact
- Optional MP4 (`--video-out`) built from kept frames

Each retained frame and contact sheet carries the SHA-256 of the exact PNG bytes written by the capture session.
Before success, Peekaboo revalidates those digests, complete PNG decoding, contact-sheet dimensions, and an exact
semantic round-trip of `metadata.json`. A child command cannot replace capture-owned files with merely nonempty data.

For diff-filtered captures, each retained frame's `changePercent` and `motionBoxes` compare it with the previous
retained frame, not with an internal sample that was dropped. This keeps heartbeat metadata truthful when a small
visible edit stayed below the motion threshold; the edit remains a heartbeat, but reports its nonzero retained delta.
Equal-size samples retain the configured threshold and cadence behavior. When the luma geometry changes after a window,
region, or display resize, Peekaboo treats the current frame as a 100% full-frame change because the old coordinates are
not comparable; that frame enters active sampling and its saved motion box covers the current frame.

For `capture video`, `metadata.json` and JSON stdout include `options.video` with the requested sampling/trim options plus the effective FPS used by the frame reader. `stats.decodeFailures` identifies the decode-failure subset of `stats.framesDropped`; ordinary diff drops remain in `framesDropped` without increasing `decodeFailures`. A bounded `videoDecodeFailure` warning retains the first and last decode errors when later samples still succeed.

Capture stats separate acquisition from retention and postprocessing. `samplingDurationMs` ends when the sampling loop
ends; `totalDurationMs` also includes video finalization and contact-sheet creation. `captureAttempts`, `framesSampled`,
`captureFailures`, and `framesDiffFiltered` explain where frames went. `sampledFps` measures valid samples over sampling
time, while `keptFps` measures retained frames over that same interval. `lowFps` compares live sampled cadence—not kept
frames—with the adaptive requested cadence, so aggressive diff filtering does not create a false warning. MCP projects
the same fields in snake_case.

For compatibility, old fields remain explicit aliases: `durationMs` means `totalDurationMs`, `fpsIdle` and `fpsActive`
mean the requested rates, `fpsEffective` means `keptFps`, and `framesDropped` is the aggregate of capture failures,
decode failures, and diff-filtered frames. New consumers should use the specific fields above.

## `capture live` flags
- Targeting: `--mode screen|window|frontmost|area`, `--screen-index`, `--app`, `--pid`, `--window-title`, `--window-index`, `--region x,y,width,height` (global coords). Window capture accepts either title or index, never both; one exact title wins over partial matches, and an ambiguous exact or partial title fails before capture starts. The selected window is frozen to its exact ID for the session.
- Focus: `--capture-focus background|foreground|auto`; background is the default, foreground explicitly activates the target, and auto is the legacy focus-if-needed mode.
- Cadence: `--duration` (<=`180s`; bare values are milliseconds), `--idle-fps`, `--active-fps`, `--threshold`, `--heartbeat`, `--quiet`
- Caps: `--max-frames` (default 800), `--max-mb`
- Diff/output: `--highlight-changes`, `--resolution-cap` (default 1440), `--diff-strategy fast|quality`, `--diff-budget`, `--video-out <path>`
- Paths: `--path <dir>` (default temp `capture-sessions/capture-<uuid>`), `--autoclean <duration>` (default `7200s`)

`--threshold` is a whole-frame percentage against the immediately preceding sample, not OCR or text sensitivity. It
controls immediate motion-frame retention and the switch to active FPS. A small localized text edit can stay below the
default and arrive in the next heartbeat keyframe; lower the threshold for that workload, or use `0` to keep every
valid sample.

Idle FPS must be finite and within `0.1...5`; active FPS must be finite and within `0.5...15`, and active must be
greater than or equal to idle. CLI live/action and MCP enforce the same policy and reject zero, negative, nonfinite,
out-of-range, or inverted rates before capture starts. When a frame enters or exits active mode, the next interval uses
the new mode immediately. Processing cost is deducted from that interval using a monotonic clock, and overruns do not
add another sleep or extend the session beyond its deadline.

## `capture action` flags
- Targeting/focus/cadence/caps/output: same as `capture live`, except `--duration` is replaced by `--duration-limit` (default `60s`, max `180s`; bare values are milliseconds).
- Action timing: `--pre-roll` (default `250ms`), `--post-roll` (default `500ms`), `--action-timeout` (defaults to the remaining duration after the startup gate, post-roll, and bounded process-group cleanup reserve).
- Command: pass the child command after `--`, e.g. `peekaboo capture action -- echo smoke`. This keeps child flags separate from Peekaboo options.

The command exits non-zero if the child command exits non-zero, times out, leaves a process-group descendant that Peekaboo cannot terminate, or required capture artifacts fail custody or semantic validation. JSON output includes the child command exit code/stdout/stderr, the normal `CaptureResult`, artifact validation details, the canonical `outcome`, and the SHA-256 receipt for `action.json`. Command success is cross-checked against the child, validation, and manifest receipt; effect/dispatch/retry fields are derived from the canonical outcome. A released child reports dispatched-unverified evidence rather than claiming a verified partial desktop change. Failures before focus or child release report a canonical refused, retry-safe, not-dispatched outcome.

The child starts after the requested pre-roll while capture remains active, and capture continues through the full
post-roll. Suspended spawn and process-generation attribution consume the action timeout before `SIGCONT`; Peekaboo
reports the effective timeout after the outer capture and cleanup deadline caps it. The pre-roll race does not join the
long-running session task. A live capture deadline can also end an in-flight frame attempt, so one slow or
cancellation-insensitive capture call cannot defer the action until after the requested session duration.

Peekaboo starts the process-group leader suspended, captures and revalidates its exact process generation, installs signal
forwarding, clears inherited termination-signal masks, restores default SIGINT/SIGTERM dispositions, and only then
releases command code. If generation evidence is unavailable, no child code runs. Blocking
leader observation runs outside Swift's cooperative executor so concurrent actions cannot starve cancellation or timeout
work. After the direct child exits Peekaboo gives remaining members a bounded TERM grace,
escalates to KILL, and verifies that the group is gone before post-roll completion, artifact validation, or manifest
publication. Startup, child timeout, TERM/KILL escalation, and descendant drain share the capture's one absolute
deadline; one blocking waiter owns escalation, and post-roll uses its recorded completion boundary so actor scheduling
does not create or discard capture time. No cleanup phase creates a fresh relative wait. A requested `--video-out` must be absent before the child can
run, and final publication still uses an exclusive no-replace operation to close the later race. `action.json` then binds
the command digest and argument count without persisting raw child arguments,
along with monotonic action offsets, separate focus/child receipts and their canonical aggregate when representable,
capture engines, selected execution route, an Apple-anchored signing identifier, trusted Team ID, live CDHash, source
commit, and exact process generation, plus the exact frame/contact/metadata/video bytes. `capture action` therefore
refuses raw, ad-hoc, unstamped, untrusted-team, or unsigned hosts instead of publishing incomplete provenance.
Retain the SHA-256 returned in CLI JSON with the manifest: the manifest is canonical and hash-bound to that result, but
it is not by itself an independently signed certification artifact.

The manifest records `containmentScope: process_group`. This lifecycle boundary covers the launched group, including
ordinary background children, but it is not a hostile-process sandbox. A command that deliberately calls `setsid` or
moves descendants into another process group has escaped that contract; do not use such a command when process
containment is part of the evidence requirement. Retaining and checking the returned manifest SHA-256 detects later
artifact or manifest rewrites.

## `capture video` flags
- Required: positional `<input>` video path
- Sampling: `--sample-fps <fps>` (default 2) XOR `--every <duration>`
- Trim: `--start <duration>`, `--end <duration>`
- Diff: `--no-diff` (keep all sampled frames); otherwise uses diff/keep logic
- Caps/output: `--max-frames`, `--max-mb`, `--resolution-cap` (default 1440), `--diff-strategy`, `--diff-budget`, `--video-out`
- Paths: `--path`, `--autoclean`

Validation: video source rejects targeting/focus/cadence flags; live rejects sampling/trim/no-diff. Video runs may keep a single valid frame when no motion is detected (emits a `noMotion` warning) instead of failing. A partial decode run remains successful but reports `decodeFailures` and `videoDecodeFailure`; it is not mislabeled as no motion when decode loss leaves only one valid frame.

Live and video sessions require at least one valid image. Peekaboo fails before contact-sheet or metadata creation with `CAPTURE_NO_VALID_FRAMES` and the bounded capture/decode cause; cancellation, permanent capture failures, and file/video-writer errors keep their original error instead. Retry metadata follows actual dispatch: a read-only capture reports `mutation_dispatched: false` and `retry_safe: true`, while a released `capture action` child reports `mutation_dispatched: true`, `effect: unverifiable`, and `retry_safe: false`. A separately confirmed foreground-focus leaf remains visible in the composed outcome without turning the child's effect into a verified change.

An explicit `--path` may reuse an existing directory only when it contains no prior capture-owned `contact.png`, `metadata.json`, `action.json`, or `keep-*.png` artifacts. Choose a new directory when rerunning a capture instead of silently reusing stale output.

## Examples
```bash
# Live, change-aware capture of frontmost window for 45s
peekaboo capture live --duration 45s --idle-fps 1 --active-fps 8 --threshold 2.0

# Live, target specific screen, MP4 output
peekaboo capture live --mode screen --screen-index 1 --video-out /tmp/capture.mp4

# Live, record an explicit desktop region; --region also infers area mode
peekaboo capture live --region 100,120,640,360 --duration 10s

# Capture a command-driven flow with a hash-bound result, action manifest, and MP4
peekaboo capture action --duration-limit 10s --path /tmp/action-capture \
  --video-out /tmp/action.mp4 --json -- ./test-flow.sh --smoke

# Re-ingest the exact action MP4 with the positional video input
peekaboo capture video /tmp/action.mp4 --every 500ms --no-diff \
  --path /tmp/action-video-ingest --json

# Video ingest, sample 2 fps, trim first 5s
peekaboo capture video /path/to/demo.mov --sample-fps 2 --start 5s --video-out /tmp/demo.mp4

# Video ingest, keep all sampled frames at 500ms interval (no diff filtering)
peekaboo capture video /path/to/demo.mov --every 500ms --no-diff
```

## Design notes
- Live defaults: max duration 180s, `--max-frames` 800, resolution cap 1440, diff strategy `fast` unless `--diff-strategy quality` is set.
- Action capture uses the same live sampler and stops it after the child command and post-roll complete; pre-roll,
  child execution, and post-roll are all represented in the retained frame timeline.
- Background live capture of an exact PID/window reacquires a generation-pinned read lane for each frame. Unrelated app mutations can overlap, while a queued mutation for the captured process runs before the next frame. Screen, area, frontmost, unresolved, foreground, and focus-capable observations remain globally exclusive.
- Video ingest uses the same diff/keep logic as live; `--no-diff` keeps every sampled frame. `--max-frames` also bounds video sample attempts, 32 consecutive decode failures stop sampling early, and each decode has a five-second deadline that cancels pending generator work. Negative/zero sampling values and trim offsets are rejected, trim end is exclusive and capped to the asset duration, and the resolution cap must be positive and finite. When no motion is detected without capture/decode loss, you may end up with a single kept frame plus a `noMotion` warning. Undecodable samples remain bounded warnings when later samples succeed; if every admitted sample is invalid, the command fails instead of returning an empty contact sheet.
- MP4 output is transactional with session success: writer, frame, contact-sheet, metadata, or cancellation failures cancel the writer and remove its incomplete output. If removal itself fails, Peekaboo reports that cleanup failure alongside the primary capture error instead of silently leaving a corrupt artifact. Contact-sheet creation fails if any advertised source frame is unreadable instead of emitting blank cells with false sampled indexes.
- Core types: `CaptureScope/Options/Result` with a pluggable `CaptureFrameSource` (ScreenCapture for live, asynchronous AVAssetImageGenerator sampling for video). Optional MP4 is written by `VideoWriter` when `--video-out` is set.
- Quick smokes:
  - `peekaboo capture live --mode screen --duration 5s --active-fps 8 --threshold 0` → frames > 0, contact sheet exists.
  - `peekaboo capture video /path/demo.mov --sample-fps 2 --start 5s --video-out /tmp/demo.mp4` → ≥2 kept frames and MP4 written.

## Troubleshooting
- `capture video` reads local media and does not require Screen Recording, Accessibility, a Bridge host, or ScreenCaptureKit ownership. Permission and host troubleshooting below applies only to `capture live` and `capture action`.
- For live/action capture, verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- In SSH, LaunchAgent, Codex, and other background launchd sessions, prefer a Bridge host with Screen Recording.
  Legacy screen/area capture now rejects wallpaper-only or redacted false-success frames instead of writing them as
  valid output. Use `--no-remote --capture-engine cg` only when the caller is in the active Aqua session and has TCC.
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
