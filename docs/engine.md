---
summary: "Capture engine selector (ScreenCaptureKit vs CGWindowList) and how to control it."
read_when:
  - "changing capture behavior or debugging SC vs CG fallbacks"
  - "adding new commands that trigger screenshots"
---

# Capture Engine Selection

Peekaboo supports two capture backends:
- **modern**: ScreenCaptureKit (SCStream/SCScreenshotManager)
- **classic**: CGWindowListCreateImage (legacy)

## How selection works
- Default: **auto** (classic/CoreGraphics first, then modern ScreenCaptureKit if allowed).
- Environment:
  - `PEEKABOO_CAPTURE_ENGINE=auto|modern|sckit|classic|cg` (preferred)
  - Back-compat: `PEEKABOO_USE_MODERN_CAPTURE=true|false|modern-only|legacy`
- CLI flags (set the env for this invocation):
  - `peekaboo capture live --capture-engine auto|modern|sckit|classic|cg`
  - `peekaboo see --no-elements --capture-engine ...`
  - `peekaboo see --capture-engine ...`

`see --capture-engine` selects the backend on the same Bridge host that normal runtime routing chooses; it does not
silently move capture or TCC ownership into the CLI process. If no compatible Bridge host is available, the command
fails before caller-local capture. Add `--no-remote` only when caller-local execution is intentional and that process
is known to own Screen Recording in the active Aqua session. Other capture commands remain caller-local until their
remote protocols explicitly carry the engine preference.

Aliases:
- modern: `modern`, `sckit`, `sc`, `sck`
- classic: `classic`, `cg`, `legacy`
- auto: `auto`

## Current policy (May 2026)
- Default: `auto` = try CGWindowList/CoreGraphics first, fallback to ScreenCaptureKit if CG fails.
- Window `auto` capture treats an abandoned, quarantined, or contended in-process ScreenCaptureKit call as a fallback signal and tries the bounded `/usr/sbin/screencapture` path in an isolated child process. The child is terminated and reaped on timeout, so fallback cannot hang indefinitely. `modern` remains strict and reports the ScreenCaptureKit failure instead of silently changing engines.
- You can force SC-only via env `PEEKABOO_DISABLE_CGWINDOWLIST=1`.
- You can force classic/CG via `--capture-engine classic|cg` or `PEEKABOO_CAPTURE_ENGINE=classic`.

## Logging & telemetry
- ScreenCaptureService logs which engine was attempted and when fallback occurs.
- Consider adding env `PEEKABOO_DISABLE_CGWINDOWLIST` if you want to dogfood pure SC.

## When to use which
- Prefer **auto** for regular commands. Use **modern** for explicit ScreenCaptureKit regression checks.
- For reproducible capture failures, log the selected engine and fallback path before forcing an engine globally.
