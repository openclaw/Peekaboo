---
summary: 'Reference for Peekaboo daemon lifecycle, routing, sockets, and migration.'
read_when:
  - 'debugging reusable daemon startup, status, migration, or idle exit'
  - 'understanding CLI, GUI Bridge, and MCP runtime ownership'
---

# Peekaboo daemon

Peekaboo's reusable daemon keeps automation services, snapshots, window tracking, and browser MCP state warm across
separate CLI invocations. It runs from the same `peekaboo` binary and is managed with:

```bash
peekaboo daemon start
peekaboo daemon status
peekaboo daemon stop
```

## Runtime ownership

Each long-lived host has one distinct role and socket:

| Runtime | Socket | Lifecycle |
| --- | --- | --- |
| Reusable CLI daemon | `~/Library/Application Support/Peekaboo/daemon.sock` | Auto-started with idle exit, or manual until stopped. |
| Peekaboo.app Bridge | `~/Library/Application Support/Peekaboo/bridge.sock` | Owned by the GUI app and its TCC grants. |
| MCP server | stdio | Owned by the MCP client; no Bridge listener or published socket. |

Commands outside the exact-build preference below prefer the reusable daemon when it is healthy. If it is unavailable,
they use a healthy Peekaboo.app host with the required capability before auto-starting a daemon. If no remote host is
usable, the command falls back to process-local services when that operation permits it.

A command carrying a concrete `ps1_` snapshot reference bypasses that preference order. It uses the unique
authenticated producer across caller-local state and live daemon/GUI Bridge candidates, and refuses before dispatch
when no single host can prove ownership. Explicit `--bridge-socket` checks only that listener; `--no-remote` checks
only caller-local state. See [Bridge snapshot authority](bridge-host.md#snapshot-authority).

Implicit commands that require screen capture, inspect the AX tree, use browser MCP, or consume/invalidate snapshot
state first prefer the current CLI build's deterministic `daemon-<build>.sock`. They may auto-start that exact-build
daemon before considering an otherwise healthy Peekaboo.app host, because protocol compatibility alone does not make
build-sensitive in-memory state interchangeable. This preference does not apply to explicit Bridge paths, custom
daemon paths, application inventory or launch, or local-only execution.

The same build-scoped socket is the compatibility fallback when another build owns `daemon.sock` but lacks a required
capability. Native and Rosetta invocations of the same universal binary share it. Daemon status prefers the compatible
host and warns when another daemon also exists; explicit daemon start safely promotes a compatible auto fallback to
manual mode. After executable upgrades, implicit routing rediscovers compatible same-user fallback sockets and validates
their daemon identity before reuse. Explicit Bridge paths and custom daemon paths do not scan sibling sockets.

Explicit `--bridge-socket` or `PEEKABOO_BRIDGE_SOCKET` selects only that Bridge path and disables daemon auto-start.
`PEEKABOO_DAEMON_SOCKET` changes the reusable daemon path without becoming an explicit Bridge override.
`--no-remote` or `PEEKABOO_NO_REMOTE` forces local execution.

## Lifecycle modes

- **Auto**: launched on demand by a CLI command; exits after inactivity (default 300 seconds).
- **Manual**: launched by `peekaboo daemon start`; remains running until `peekaboo daemon stop`.

`PEEKABOO_DAEMON_IDLE_TIMEOUT_SECONDS` changes the auto idle timeout. Accepted requests count as activity, and shutdown
waits for accepted connections and operational services to drain.

Standalone `mcp` daemon mode is intentionally unavailable. `peekaboo mcp` owns its stdio lifecycle and uses only
process-local support such as window tracking.

## Socket ownership

Bridge listeners hold an exclusive lease beside their socket for the listener's full lifetime. Publication is atomic:
a host binds and secures a private temporary socket, then publishes it without replacing an owned path. Stale recovery
requires proof that no same-user process has the exact UNIX path open; a failed connection alone is not enough.

Shutdown removes a socket only when its filesystem identity still matches the listener that created it. Client
connect, read, and write operations are nonblocking and deadline-bound so abandoned connections cannot exhaust the
host.

## Legacy migration

Older daemons may still occupy Peekaboo.app's `bridge.sock`. Current daemon control detects the host kind before acting:

- Peekaboo.app is never mistaken for a daemon.
- Auto and manual daemons that advertise conditional stop migrate to `daemon.sock` while preserving lifecycle mode,
  polling interval, and idle timeout.
- Migration defers while requests are active.
- Older daemons without conditional stop remain on the legacy socket until they exit or are explicitly stopped.

## Status

`peekaboo daemon status --json` reports:

- PID, start time, lifecycle mode, and socket path
- Bridge protocol version, host kind, and advertised operations
- active requests, last activity, idle timeout, and idle deadline
- Screen Recording, Accessibility, and Event Synthesizing permissions
- snapshot count and last access
- tracked windows, AX observers, and poll interval; reconciliation retains only the exact bounds and owner PID needed for move-aware input
- browser MCP connection, tool count, and detected browsers

See [`peekaboo daemon`](commands/daemon.md) for command flags and [Bridge host](bridge-host.md) for transport and
security details.
