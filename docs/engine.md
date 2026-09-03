---
summary: "Capture engine selector (ScreenCaptureKit vs CGWindowList) and how to control it."
read_when:
  - "changing capture behavior or debugging SC vs CG fallbacks"
  - "adding new commands that trigger screenshots"
---

# Capture Engine Selection

Peekaboo supports two capture backends:
- **modern**: bounded ScreenCaptureKit `SCScreenshotManager` calls
- **classic**: CoreGraphics or an isolated system screenshot helper (no in-process SCK)

## How selection works
- Default: **auto** (classic/CoreGraphics first, then modern ScreenCaptureKit if allowed).
- Environment:
  - `PEEKABOO_CAPTURE_ENGINE=auto|modern|sckit|classic|cg` (preferred)
  - Back-compat: `PEEKABOO_USE_MODERN_CAPTURE=true|false|modern-only|legacy`
- CLI flags (select the backend for this invocation):
  - `peekaboo capture live --capture-engine auto|modern|sckit|classic|cg`
  - `peekaboo see --no-elements --capture-engine ...`
  - `peekaboo see --capture-engine ...`

`see --capture-engine` selects the backend on the same Bridge host that normal runtime routing chooses; it does not
silently move capture or TCC ownership into the CLI process. If no compatible Bridge host is available, the command
fails before caller-local capture. Add `--no-remote` only when caller-local execution is intentional and that process
is known to own Screen Recording in the active Aqua session. Other capture commands remain caller-local until their
remote protocols explicitly carry the engine preference.

Remote `modern` and `classic` selections require a host that advertises
`desktopObservationCaptureEngine`; older hosts are refused before the observation request is sent rather than silently
running `auto`. The `auto` value retains backward-compatible observation semantics. Transported `see` preferences stay
inside the individual request and never become a reusable daemon's inherited process environment, so one explicit
`modern` request cannot make later `auto` requests modern-only.

## ScreenCaptureKit process ownership

macOS can strand a second process's ScreenCaptureKit screenshot request after another live process has used SCK, even
when no capture is in flight. Peekaboo therefore gives the first process that explicitly preclaims caller-local modern
capture or enters a real SCK API a per-user, process-lifetime owner lease. Later remote `modern` requests prefer the
compatible Bridge host whose PID, process generation, and signed build match that lease.
Every claim scans and refuses owner-unaware live processes, including processes discovered after the current generation
acquired the canonical lease.

Current hosts advertise implemented ownership enforcement separately from their observed preparation readiness.
`screenCaptureKitOwnershipEnforcement` proves the service contract; optional `screenCaptureKitReadiness` reports
preparation success, a blocker, or an unavailable check. Preparation never claims ownership, and every actual SCK entry
still scans and claims independently. Blocked preparation retains the original typed failure and known blocker
PID, generation, executable, socket, and build evidence. A potential uncoordinated host is not proof of actual SCK use.

Explicit `classic`/`cg` uses `classicCaptureWithoutScreenCaptureKit` plus capture-engine transport to stay on the selected
socket even when SCK preparation failed or its readiness report is missing. It retains permission evidence, enabled
operation, target freshness, and receipt checks. Default/`auto` and explicit `modern` refuse a current host's blocked or
unavailable readiness with that host and blocker context; they do not substitute classic. Unblocked auto behavior is
unchanged. Older hosts carrying `screenCaptureKitProcessOwnership` retain their established compatibility contract.
Hosts with neither applicable proof fail closed; engine transport or a version label alone is insufficient.

CLI JSON errors expose available typed ownership evidence as `error.screen_capture_kit_ownership_diagnostic`, with
`CAPTURE_FAILED` as the error code. This optional field includes the selected host and original blockers independently
of action metadata, including for ordinary `see --json` preflight failures. Its absence supplies no ownership evidence.
A blocked SCK entry does not imply that an earlier desktop mutation was absent or safe to repeat; any existing action
outcome and retry-safety receipt remain authoritative.

`--no-remote --capture-engine modern` explicitly requests caller-local ownership. If another Peekaboo process owns
SCK, the command refuses before constructing local capture services or calling the framework. Retry without
`--no-remote` to use a compatible host for that exact owner generation, or explicitly request
`--capture-engine classic` on a host that proves the classic contract. Peekaboo never silently changes an explicit `modern` request to classic. Explicit classic
does not probe or claim in-process ScreenCaptureKit. Because the CoreGraphics permission preflight is not authoritative
for rebuilt CLI binaries, a false preflight must be corroborated by readable protected metadata from a foreign visible
WindowServer window before classic dispatches; otherwise it refuses before a wallpaper-only capture can be accepted.
`auto` does not claim in the caller during routing; it follows an existing owner when present and otherwise claims only
if its selected host actually reaches an SCK permission, lookup, or screenshot operation. Modern captures intentionally
avoid persistent `SCStream` sessions: an owner-unaware process can start after a stream begins, so a service-lifetime
stream cannot preserve strict cross-process ownership. Each bounded framework dispatch rechecks ownership immediately
before entry. This is a cooperative rolling-upgrade guard, not process exclusion: an old binary can still launch during
an in-flight 3–5 second framework callback. Bounded calls cap that exposure and the next dispatch refuses it instead of
leaving a stream active for the service lifetime.

An explicit `--bridge-socket` is authoritative and never reroutes. For `modern`, that socket must be served by the exact
owner PID/process generation and signed build; otherwise Peekaboo refuses before dispatch and tells the caller to change
or remove the explicit socket. Classic remains a process-isolated, in-process-SCK-free recovery path.

New CLI and app processes publish a private PID/process-generation/build receipt and retain its file lock for their
lifetime. Before every SCK leaf, Peekaboo scans exact same-user Peekaboo and companion host entry points plus the known
Peekaboo, Claude, and Clawdbot Bridge sockets. Ordinary Claude Code, renderer, crash-reporting, audio, and model helpers
are not hosts. A matching live host without a valid current receipt blocks SCK because its coordination cannot be
proven, including a renamed official binary or long-running `agent`/`capture live` process. This observation does not
establish whether that process has used SCK or which build first implemented ownership. Unlocked stale receipts
are safely removed from a dedicated private marker directory; repeated scans reuse PID, process-generation, executable,
and signature inspection results while revalidating the executable path.

The owner lease and capability marker retain `flock` descriptors for process lifetime. Their opens atomically include
`O_CLOEXEC` and, under the existing Swift 6.4 compiler/SDK gate, `O_CLOFORK`. An inherited descriptor could keep the
parent's lease locked after the parent exits; unlocking the shared `flock` in a child would also unlock the parent's
lease. Atomic close-on-fork protects even the interval between opening a descriptor and storing it in the registry.

SDK flag availability does not establish runtime support for querying or setting descriptor flags. On the checked
macOS 26.6.2 (25G83) runtime, built with Xcode 27 / Swift 6.4, both `open` and `openat` with `O_CLOFORK` close the
descriptor in the fork child, while `F_GETFD` omits `FD_CLOFORK` and `F_SETFD` cannot set or clear its semantics despite
returning success. Tests therefore check actual child `EBADF`, parent inode/lock retention, and strict `FD_CLOEXEC`
reporting; a missing query bit never excuses inheritance. The runtime introduction of `FD_CLOFORK` query/set support
has not been established, and no macOS 27 runtime was tested. Builds using older compiler/SDK combinations that omit
`O_CLOFORK` retain close-on-exec only: there is no implemented atfork cleanup or pre-exec fork-safety guarantee.

Long-running Agent and MCP modes remain available for non-capture tools when they discover a pre-lease Bridge. Peekaboo
keeps that runtime local and records a process-lifetime SCK blocker instead of failing startup or routing capture to the
old host. A later SCK leaf refuses before framework dispatch. The blocker is intentionally irreversible for that Agent
or MCP process: after every old host is updated or stopped, restart the long-running process before retrying SCK. This
closes transient PID lookup, multiple-old-host, and same-socket restart races.

Removing the warm stream makes full-display Watch and `capture live` cadence capture-latency-bound. Restore that
performance only through an owner-affine cache or a disposable helper-process stream with a bounded lifetime and exact
cleanup receipt; do not reintroduce persistent pixels or an in-process service-lifetime stream.

Aliases:
- modern: `modern`, `sckit`, `sc`, `sck`
- classic: `classic`, `cg`, `legacy`
- auto: `auto`

## Current policy (August 2026)
- Default: `auto` = try CGWindowList/CoreGraphics first, fallback to ScreenCaptureKit if CG fails.
- Window `auto` capture may use the bounded `/usr/sbin/screencapture` helper only after a terminal, fallback-safe private lookup failure. Cancellation, timeout, or a quarantined ScreenCaptureKit call is never crossed with another capture backend; Peekaboo refuses until that exact framework call completes. The helper is terminated and reaped on its own timeout. `modern` remains strict and never silently changes engines.
- You can force SC-only via env `PEEKABOO_DISABLE_CGWINDOWLIST=1`.
- You can force classic/CG via `--capture-engine classic|cg` or `PEEKABOO_CAPTURE_ENGINE=classic`.

## Logging & telemetry
- ScreenCaptureService logs which engine was attempted and when fallback occurs.
- Exact-window ScreenCaptureKit observations include `window_plan_cache=miss|hit|rebuilt` and a process-local
  `window_plan_cache_generation` in the `capture.window` observation span. The Bridge host identity identifies the owning
  process; the plan generation is meaningful only inside that exact owner process.
- Consider adding env `PEEKABOO_DISABLE_CGWINDOWLIST` if you want to dogfood pure SC.

## Exact-window warm plans

The modern exact-`window_id` path retains at most 32 screenshot plans for two seconds inside each
`ScreenCaptureKitOperator`. A plan contains only an `SCContentFilter`, screenshot configuration, expected pixel size,
and immutable receipt/topology/scale evidence. It contains no `SCStream`, captured pixels, or cached result metadata.
The process owner is rechecked at every ScreenCaptureKit leaf even on a cache hit.

Before and after capture, Peekaboo validates the exact window owner generation, bounds, layer, visibility, sharing
state, active-display logical and physical topology, rotation, mirroring, and scale. Known drift evicts and rebuilds
once. Unavailable evidence bypasses the cache for one fresh capture. Cancellation, timeout, permission, and quarantine
failures are evicted and returned unchanged; they never trigger an internal cache retry or backend fallback.

The cache belongs to the selected owner host. Separate caller-local CLI processes cannot share it, and a replacement
host starts again at generation 1. `classic` never touches the cache. A successful `auto` CoreGraphics capture does not
touch it; only an allowed ScreenCaptureKit attempt uses the warm-plan path.

## When to use which
- Prefer **auto** for regular commands. Use **modern** for explicit ScreenCaptureKit regression checks.
- For reproducible capture failures, log the selected engine and fallback path before forcing an engine globally.
