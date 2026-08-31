---
summary: 'Start, stop, and inspect the headless Peekaboo daemon'
read_when:
  - 'managing the Peekaboo daemon lifecycle'
  - 'checking daemon health, permissions, or tracker status'
---

# peekaboo daemon

Manage the on-demand headless daemon that keeps Peekaboo state warm, tracks windows live, and serves bridge requests.

The default listener is `~/Library/Application Support/Peekaboo/daemon.sock`, separate from Peekaboo.app's
`bridge.sock`.

After upgrading from a version that used `bridge.sock` for the daemon, default `status`, `start`, and `stop`
commands detect that legacy daemon by its daemon status. Peekaboo.app is never treated as a daemon.

Normal automation commands migrate legacy auto or manual daemons that advertise atomic conditional stop. The daemon
keeps its prior lifecycle mode, poll interval, and auto idle timeout, so a manually started daemon remains manual after
migration. MCP sessions remain process-owned and are never migrated.
When `bridge.sock` belongs to a healthy Peekaboo.app GUI host instead, commands outside the exact-build preference keep
using that app-held TCC context and start the reusable daemon only if the app host is unavailable or lacks the required
capability. Implicit commands that require screen capture, inspect the AX tree, use browser MCP, or consume/invalidate
snapshot state first prefer the current CLI build's deterministic `daemon-<build>.sock` and may auto-start it before
considering the GUI host. Explicit Bridge paths, custom daemon paths, application inventory or launch, and local-only
execution bypass that preference.
Automatic migration defers while operational requests are active and keeps using the legacy daemon for that invocation.
Older daemons without conditional stop remain on `bridge.sock` until they exit or are explicitly stopped. Explicit
`daemon start` asks the user to stop those older daemons first, and asks for a retry when supported daemons are busy.
If an incompatible daemon already owns `daemon.sock`, automation uses a build-scoped fallback. Default `status` reports
the compatible fallback and warns about the additional daemon; `start` promotes an idle, safely stoppable fallback from
auto to persistent manual mode on the same socket.

Concrete `ps1_` snapshot references are not routed by these daemon preferences. Peekaboo selects the one authenticated
local, daemon, or GUI Bridge producer that claims the reference and refuses before dispatch if ownership is missing or
ambiguous. Explicit socket and local-only options remain strict; see
[Bridge snapshot authority](../bridge-host.md#snapshot-authority).

## Commands

### Start
```
peekaboo daemon start
```
Options:
- `--bridge-socket <path>` override the default daemon socket path.
- `--poll-interval <duration>` window tracker poll interval (default `1s`; bare values are milliseconds).
- `--wait <duration>` how long to wait for startup (default `3s`).

### Status
```
peekaboo daemon status
```
Shows:
- running state + PID
- bridge socket + host kind
- activity state (active requests, last activity, idle timeout/deadline)
- permissions (screen recording / accessibility / event synthesizing)
- snapshot cache summary
- window tracker stats (tracked windows, last event, polling)
- cached browser MCP state (`observation: "indeterminate"`; human output says `State: unconfirmed`)

Health returns without waiting for browser discovery or connection validation. Cached values, including an initially
empty browser list, do not confirm current browser absence; use `peekaboo browser status` for a fresh observation.
Missing/refused sockets retain successful `running: false` output. Probe timeouts, authorization failures, and lost or
invalid replies instead fail nonzero with `success: false` in JSON. Start and stop also refuse unresolved target probes;
a healthy GUI Bridge is never stopped as a daemon. Stop keeps the existing shutdown deadline and read-only retry/PID
checks, and does not report successful cleanup while endpoint state remains unknown.

### Stop
```
peekaboo daemon stop
```
Options:
- `--bridge-socket <path>` override the default daemon socket path.
- `--wait <duration>` how long to wait for shutdown (default `12s`, above the Bridge request deadline).

## Notes
- Normal automation commands auto-start the daemon in `auto` mode when the selected reusable socket is unavailable;
  exact-build routing for the command categories above can select `daemon-<build>.sock` before the default socket or
  GUI host.
- Auto-started daemons exit after an idle timeout (default 300 seconds), while explicit `peekaboo daemon start` remains manual and stays up until stopped.
- The daemon uses an in-memory snapshot store for speed.
- Set `PEEKABOO_DAEMON_IDLE_TIMEOUT_SECONDS` to tune the auto-start idle timeout.
- Set `PEEKABOO_DAEMON_SOCKET` to override the auto-start daemon socket for testing.
- For local development with unsigned binaries, set `PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS=1`.
