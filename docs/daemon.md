---
summary: 'Plan for a headless Peekaboo daemon with live window tracking and MCP integration'
read_when:
  - 'planning or implementing the Peekaboo daemon lifecycle'
  - 'adding live window tracking or daemon status reporting'
  - 'wiring MCP to run in daemon mode'
---

# Peekaboo Daemon

## Goals
- Provide a headless daemon with explicit lifecycle commands:
  - `peekaboo daemon start`
  - `peekaboo daemon stop`
  - `peekaboo daemon status`
- When running as MCP (`peekaboo mcp`), automatically enter daemon mode:
  - In-memory snapshot store
  - Live window tracking
  - Enhanced observability
- Improve accuracy and speed via cached state + event-driven updates.
- Keep stateful MCP-backed services, such as Chrome DevTools MCP, warm across separate `peekaboo` invocations.

## Non-goals (initially)
- No GUI or menu bar UI for the daemon.
- No launchd agent/daemon integration.
- No external network listeners beyond MCP’s stdio transport (HTTP/SSE still out of scope).

## User Experience
### Commands
- `peekaboo daemon start`
  - Starts a headless daemon **from the same `peekaboo` binary** (on-demand).
  - Ensures bridge socket is up and window tracking is active.
- `peekaboo daemon stop`
  - Gracefully shuts down the daemon.
  - Cleans up observers and sockets.
- `peekaboo daemon status`
  - Reports:
    - Running state + PID
    - Bridge socket path + handshake
    - Activity state + idle timeout/deadline for auto-started daemons
    - Permissions (Screen Recording, Accessibility)
    - Snapshot cache stats (count, last access)
    - Window tracker stats (tracked windows, last event timestamp)
    - MCP mode indicator (if daemon was launched by MCP)

### Output format
- Human-readable by default, `--json` supported (same style as `bridge status`).

## Architecture
### High-level
```
CLI (peekaboo) ─┐
                ├── Daemon Controller ──> Headless Daemon Host
MCP (stdio)  ───┘                             │
                                              ├─ PeekabooServices (InMemorySnapshotManager)
                                              ├─ WindowTrackerService (AX + CG fallback)
                                              ├─ Bridge Host (socket)
                                              └─ Observability / Metrics
```

### New components
- **PeekabooDaemon**
  - Owns a long-lived `PeekabooServices(snapshotManager: InMemorySnapshotManager())`.
  - Starts Bridge host listener and WindowTrackerService.
  - Exposes stop/status and browser MCP operations over the local Bridge socket.

- **WindowTrackerService** (new service, likely in `PeekabooAutomationKit`)
  - Uses AX notifications (`AXWindowCreated`, `AXWindowMoved`, `AXWindowResized`, etc.).
  - Maintains an in-memory registry keyed by `CGWindowID` + AX identifier.
  - Periodic CGWindowList diff for resilience (apps that don’t emit AX events).

- **SnapshotInvalidation** (new logic in snapshot manager or automation layer)
  - When a tracked window moves/resizes, mark snapshot stale or update bounds.
  - On interaction, re-verify window position before clicking/typing.

### Auto daemon routing
- Automation-oriented CLI commands prefer the default Peekaboo daemon socket.
- The reusable daemon owns `~/Library/Application Support/Peekaboo/daemon.sock`; it never shares
  Peekaboo.app's `bridge.sock`.
- If no reusable daemon is running, normal commands use a healthy Peekaboo.app GUI host before auto-starting a daemon,
  preserving existing app-held TCC grants.
- On upgrade, daemon control detects a still-running legacy auto or manual daemon on `bridge.sock`. Daemons that
  advertise conditional stop migrate to the dedicated listener while preserving lifecycle mode, poll interval, and
  auto idle timeout.
- Migration defers while the daemon has active requests. Older daemons without conditional stop remain on the legacy
  socket until they exit or are explicitly stopped, avoiding a status-to-stop race. Daemon stop drains accepted
  connections before shutting down operational services.
- If no default daemon is reachable, command runtime starts `peekaboo daemon run --mode auto` and reconnects.
- Auto daemons track Bridge request activity and shut down after an idle timeout (default 300 seconds).
- `peekaboo list apps`, `peekaboo app list`, `--no-remote`, `PEEKABOO_NO_REMOTE`, explicit input strategy overrides, and explicit capture engine overrides keep commands local.
- `PEEKABOO_DAEMON_SOCKET` changes only the auto-start daemon socket; `PEEKABOO_BRIDGE_SOCKET` remains an explicit Bridge override and disables auto-start.
- Bridge protocol 1.5 lets `image`/`see` run desktop observation inside the daemon. The daemon writes screenshot files locally and returns paths, timings, diagnostics, and optional element data without serializing screenshot bytes through Bridge JSON.
- Runtime routing is split across focused helpers: socket resolution, daemon launch policy, bridge capability policy, input override detection, local service construction, and host resolution. Keep new routing exceptions in those helpers instead of growing `CommandRuntime`.

## Placement
- Single entry point: `peekaboo` runs in **daemon mode** when requested.
- On-demand only; no launchd agent.

## Status/Observability Fields
- `daemon.running` (bool)
- `daemon.pid`
- `daemon.startedAt`
- `daemon.mode` (auto|manual|mcp)
- `bridge.socketPath`
- `bridge.handshake` (hostKind, ops, version)
- `permissions.screenRecording`
- `permissions.accessibility`
- `snapshots.count`
- `snapshots.lastAccessedAt`
- `tracker.trackedWindows`
- `tracker.lastEventAt`
- `tracker.axObservers`
- `tracker.cgPollIntervalMs`
- `browser.connected`
- `browser.toolCount`
- `browser.detectedBrowsers`
- `activity.activeRequests`
- `activity.lastActivityAt`
- `activity.idleTimeoutSeconds`
- `activity.idleExitAt`

## Implementation Phases
1) **Daemon scaffolding**
   - Create headless executable target.
   - Add `peekaboo daemon start|stop|status` commands.
   - Implement local control channel (Unix socket or pidfile + health probe).

2) **Daemon mode services**
   - Add `DaemonServices` initializer using InMemorySnapshotManager.
   - Ensure Bridge host runs inside daemon.

3) **WindowTrackerService**
   - AX observer subscriptions + CGWindowList polling fallback.
   - Registry API: list tracked windows, last event, etc.

4) **Snapshot invalidation + focus verification**
   - Integrate with click/type/focus paths.
   - Prefer re-verify bounds when window moved.

5) **MCP integration**
   - `peekaboo mcp serve` routes stateful browser calls to the daemon when a Bridge host is available.
   - The daemon owns Chrome DevTools MCP process lifetime, selected page state, and snapshot UID state.

6) **Telemetry + tests**
   - Unit tests for tracker diffing.
   - CLI status snapshot tests.
   - MCP server smoke test in daemon mode.

## Build/Run
- CLI:
  - `pnpm run build:cli`
- Daemon (headless target):
  - `pnpm run build:swift` (add a dedicated script if needed)
- Status:
  - `peekaboo daemon status --json`

## Open Questions
- Should daemon auto-install a launchd agent, or only run on-demand?
- Do we want `peekaboo mcp` to spawn a separate daemon or just run in-process (current plan)?
- How aggressive should CGWindowList polling be when AX notifications are quiet?
