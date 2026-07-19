---
summary: "Describe Peekaboo Bridge host architecture (socket-based TCC broker)"
read_when:
  - "embedding Peekaboo automation into another macOS app"
  - "debugging remote execution for Peekaboo CLI"
  - "auditing auth/security for privileged automation surfaces"
---

# Peekaboo Bridge Host

Peekaboo Bridge is a **socket-based** broker for permission-bound operations (Screen Recording, Accessibility, AppleScript). It lets a CLI (or other client process) drive automation via a host app that already has the necessary TCC grants.

This replaces the previous XPC-based helper approach.

## Hosts and discovery

Normal CLI automation commands prefer the on-demand Peekaboo daemon socket and will auto-start that daemon when it
is missing. This keeps bursty command sequences warm without probing unrelated host apps.

Bridge diagnostics inspect sockets in this order:

1. **Peekaboo daemon** (normal automation runtime)
   - Socket: `~/Library/Application Support/Peekaboo/daemon.sock`
2. **Peekaboo.app** (permission broker)
   - Socket: `~/Library/Application Support/Peekaboo/bridge.sock`
3. **Claude.app** (fallback host; piggyback on Claude Desktop TCC grants)
   - Socket: `~/Library/Application Support/Claude/bridge.sock`
4. **Clawdbot.app** (fallback host)
   - Socket: `~/Library/Application Support/clawdbot/bridge.sock`
5. **Local in-process** (no host available; requires the caller process to have TCC grants)

Normal runtime selection prefers the reusable daemon, then a healthy Peekaboo.app GUI host before starting a daemon.
This preserves existing app-held TCC grants while keeping socket ownership separate. Other app-host sockets remain
diagnostic-only unless selected with `--bridge-socket` or `PEEKABOO_BRIDGE_SOCKET`.

There is **no auto-launch** of Peekaboo.app.

`peekaboo mcp` never hosts a Bridge listener. When it must run services locally, its in-process daemon is limited to
the window tracker and other process-local support.

## Transport

- **UNIX-domain socket**, single request per connection:
  - Client writes one JSON request, then half-closes.
  - Host replies with one JSON response and closes.
- Payloads are `Codable` JSON with a small handshake for:
  - protocol version negotiation
  - capability/operation advertisement
- Each listener holds an exclusive lease beside its socket for its full lifetime.
- A host removes an existing socket only after acquiring the lease and matching the path to the exact device/inode
  recorded by the previous lease owner. Pre-lease sockets are recovered only after proving no same-user process has the
  exact UNIX path open; a failed connect alone never marks a socket stale.
- New listeners bind and secure a private temporary socket, then publish it atomically without replacing an existing
  path.
- Shutdown removes the socket only when its filesystem identity still matches the listener that created it.
- Connect, request read, and response write paths are nonblocking and deadline-bound so abandoned clients release their
  connection tasks instead of exhausting the host.

Protocol `1.3` adds element action operations:

- `setValue` for direct accessibility value mutation.
- `performAction` for named accessibility action invocation.

Protocol `1.4` adds browser MCP operations for persistent Chrome DevTools MCP sessions.

Protocol `1.5` adds `desktopObservation`, used by daemon-backed `image` and `see` paths. The host performs target resolution, capture, optional detection, and file writes, then returns lightweight metadata instead of embedding screenshot bytes in the Bridge response.

## Security

Peekaboo BridgeHost validates callers before processing any request:

- Reads the peer PID via `getsockopt(..., LOCAL_PEERPID, ...)`.
- Validates the peer’s **code signature TeamID** via Security.framework (`SecCodeCopyGuestWithAttributes`).
- Rejects any process not signed by an allowlisted TeamID (default: `FWJYW4S8P8`, plus `Y5PE65HELJ` for transition-era CLI compatibility).

Debug-only escape hatch:

- Set `PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS=1` to allow same-UID unsigned clients (local dev only).

## Snapshot state

Bridge hosts are intended to be long-lived and keep automation state **in memory**:

- Hosts typically use `InMemorySnapshotManager` so follow-up actions can reuse the “most recent snapshot” per app/bundle without passing IDs around.
- Screenshot artifacts are referenced by **file path** (e.g. in `/tmp`). Protocol 1.5 desktop observation avoids returning raw image bytes for daemon-backed screenshot calls.

## CLI behavior

- By default, automation-oriented CLI commands use a healthy reusable daemon, then a capable Peekaboo.app GUI host,
  then auto-start a daemon, with process-local execution as the final operation-dependent fallback.
- Use `--no-remote` to force local execution.
- Use `--bridge-socket <path>` or `PEEKABOO_BRIDGE_SOCKET` to override host discovery.
- Use `PEEKABOO_DAEMON_SOCKET` only to change the auto-start daemon socket without treating it as an explicit Bridge override.
- Use `peekaboo bridge status` to verify which host would be selected and why (probe results, handshake errors, etc.).

## Screen Recording troubleshooting

TCC permissions belong to the process that performs the capture. When the CLI routes through Bridge, Screen
Recording must be granted to the selected host app, not just to the terminal, Node process, or editor that
spawned `peekaboo`.

For subprocess runners such as OpenClaw, this means a capture can fail through Bridge even though the parent
process is listed in System Settings. Check the selected host and permission source first:

```bash
peekaboo bridge status --verbose
peekaboo permissions status
```

If the parent process already has Screen Recording but the selected Bridge host does not, force local capture
and the CoreGraphics engine:

```bash
peekaboo see --mode screen --screen-index 0 --no-remote --capture-engine cg --json
```
