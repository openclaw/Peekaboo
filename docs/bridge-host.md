---
summary: "Describe Peekaboo Bridge host architecture (socket-based TCC broker)"
read_when:
  - "embedding Peekaboo automation into another macOS app"
  - "debugging remote execution for Peekaboo CLI"
  - "auditing auth/security for privileged automation surfaces"
---

# Peekaboo Bridge Host

Peekaboo Bridge is a **socket-based** broker for permission-bound operations (Screen Recording, Accessibility, and Event Synthesizing). It lets a CLI (or other client process) drive automation via a host app that already has the necessary TCC grants.

This replaces the previous XPC-based helper approach.

## Hosts and discovery

Most CLI automation commands first reuse a healthy Peekaboo daemon. If none can satisfy the operation, they try a
capable Peekaboo.app GUI Bridge host before starting a daemon on demand. Operations that permit process-local fallback
can use it when no compatible host is available. Application inventory and launch prefer the GUI host, while relaunch
and quit require a reusable daemon that survives the caller.

Bridge diagnostics inspect sockets in this order:

1. **Peekaboo daemon** (normal automation runtime)
   - Socket: `~/Library/Application Support/Peekaboo/daemon.sock`
2. **Peekaboo.app** (permission broker)
   - Socket: `~/Library/Application Support/Peekaboo/bridge.sock`
3. **Claude.app** (fallback host; piggyback on Claude Desktop TCC grants)
   - Socket: `~/Library/Application Support/Claude/bridge.sock`
4. **Clawdbot.app** (fallback host)
   - Socket: `~/Library/Application Support/clawdbot/bridge.sock`
5. **Local in-process** (operation-dependent fallback or explicit `--no-remote`; requires caller-process TCC grants)

This selection preserves existing app-held TCC grants while keeping socket ownership separate. Claude.app and
Clawdbot.app sockets remain diagnostic-only unless selected with `--bridge-socket` or `PEEKABOO_BRIDGE_SOCKET`.

There is **no auto-launch** of Peekaboo.app.

`pnpm app:restart` remains the contributor workflow: it builds Debug with the repository's ordinary
local Xcode signing configuration. It does not require or inject an OpenClaw Foundation identity.
Managed replacement of the stable TCC app is deliberately
separate:

```bash
pnpm app:install-companion -- --source-app /absolute/path/Peekaboo.app --healthcheck-cli /absolute/path/peekaboo
```

The `--` separates pnpm's script invocation from the installer options. You can also pass
`--deployment` directly to `scripts/restart-peekaboo.sh` and omit that separator. Deployment mode requires the trusted signed artifact and current
signed CLI, then retains the transactional signer/native-only/readiness/rollback gates described
below.

Deployment may launch the GUI permission broker with the process argument
`--background-bridge-host`. That unattended mode still initializes the menu-bar status item,
permission state, and GUI Bridge listener, but startup never presents API-key or permission
onboarding, opens the main/Settings/Inspector windows, promotes the app into the Dock, or handles
an invisible-window reopen by activating UI. It also leaves Sparkle stopped so an automatic update
check or installer relaunch cannot drop the required host mode. Update actions stay hidden in this
managed process; quit it and launch Peekaboo with `--interactive` before updating. Explicit later user
intent from the status item or a configured shortcut still opens the requested interface. If its
Bridge listener cannot take
ownership after bounded legacy-host migration retries, the app exits nonzero instead of remaining
alive without a usable Bridge. The managed host binds the main-app Launch at Login mode to the
exact installed bundle version and code-signature hash. A registered main-app login
service can therefore restart that same build unattended, while a rolled-back or independently
updated build ignores the stale receipt. Quit the managed host and run
`open -a Peekaboo --args --interactive` for an explicit update session; the next ordinary login
launch remains background-only.

`peekaboo mcp` never hosts a Bridge listener. When it must run services locally, its in-process daemon is limited to
the window tracker and other process-local support.

## Transport

- **UNIX-domain socket**, single request per connection:
  - Client writes one JSON request, then half-closes.
  - Host replies with one JSON response and closes.
- Payloads are `Codable` JSON with a small handshake for:
  - protocol version negotiation
  - capability/operation advertisement
  - optional host PID/process-start identity, bundle version, code-signature hash, and launch-mode
    capabilities for exact-generation deployment readiness checks
- Each listener holds an exclusive lease beside its socket for its full lifetime.
- A host removes an existing socket only after acquiring the lease and matching the path to the exact device/inode
  recorded by the previous lease owner. Pre-lease sockets are recovered only after proving no same-user process has the
  exact UNIX path open; a failed connect alone never marks a socket stale.
- New listeners bind and secure a private temporary socket, then publish it atomically without replacing an existing
  path.
- Shutdown removes the socket only when its filesystem identity still matches the listener that created it.
- Connect, request read, and response write paths are nonblocking and deadline-bound so abandoned clients release their
  connection tasks instead of exhausting the host.
- Listener acceptance is kernel-readiness-driven: one coalesced notification drains the queued connection backlog to
  `EAGAIN`, while source cancellation owns descriptor closure and bounded shutdown waits for queued handlers to drain.

Protocol `1.3` adds element action operations:

- `setValue` for direct accessibility value mutation.
- `performAction` for named accessibility action invocation.

Protocol `1.4` adds browser MCP operations for persistent Chrome DevTools MCP sessions.

Protocol `1.5` adds `desktopObservation`, used by daemon-backed `image` and `see` paths. The host performs target resolution, capture, optional detection, and file writes, then returns lightweight metadata instead of embedding screenshot bytes in the Bridge response.

Protocol `1.12` adds the silent capture visualizer mode. Background `see`, `image`, and live-capture requests use it so a ScreenCaptureKit host does not display screenshot flashes or capture HUD overlays. Capture-capable clients reject older hosts before sending the new enum value.

Protocol `1.13` extends `ApplicationLaunchRequest` with default-false `createsNewInstance` and `waitForWindow` fields. New hosts decode payloads from older clients with both behaviors disabled. Clients requesting either behavior require a negotiated 1.13 host before sending: this prevents an older host from ignoring the unknown field and silently reusing an existing process or returning before a window exists. Ordinary launch requests keep negotiating back to 1.9 and preserve the existing `waitUntilReady` launch-completion contract.

Protocol `1.14` adds a read-only PID-scoped focused-element query, including its owning exact CGWindowID, for diagnostics and non-mutating focus inspection.

Protocol `1.15` introduced the host-side atomic exact-window keyboard transaction, but that initial wire shape is not
accepted by current clients because it could not carry the final capture receipt and focused-destination evidence.
PID-only keyboard delivery keeps its existing protocol.

Protocol `1.16` adds process-generation-pinned destructive window mutations and application quit. Window listings return a receipt containing the exact CGWindowID, owner PID, and owner process-start identity. Move, resize, set-bounds, minimize, maximize, and close carry that receipt through the Bridge queue; application discovery similarly returns a PID/process-start receipt that quit requests carry to the host. The host revalidates receipts after mutation admission and the native service revalidates immediately around dispatch/readback or termination. New clients reject older hosts for these mutations instead of letting an old host ignore the receipt. Current hosts do not advertise `quitApplication` to pre-1.16 clients, and reject any direct quit request that omits the receipt.

Protocol `1.17` is the first currently compatible exact-window keyboard capability. One mutation request validates the
PID-scoped focused element, owning CGWindowID, expected bounds, capture receipt, and optional focused destination on the
host, then dispatches type or hotkey input while the Bridge mutation gate remains held. Paced typing revalidates before
every character or key boundary. Exact clicks likewise retain the capture-time receipt through final native dispatch
and completion validation. New clients reject older hosts for these exact-input operations.

Protocol `1.18` also carries the initially selected application process-generation receipt through atomic relaunch.
The daemon re-resolves the selector only to verify that exact receipt, then uses the same receipt for quit and fails
closed if the PID was recycled. Current clients therefore require a 1.18 on-demand host for relaunch.

Protocol `1.18` adds immutable capture-time bounds to destructive window mutation receipts and a native background `restoreWindow` operation. Hosts reject a same-process replacement that reuses the selected CGWindowID with different bounds before move, resize, set-bounds, minimize, restore, maximize, or close dispatch; geometry operations then repin the requested final bounds instead of mistaking the intended transition for replacement. Restore clears only the retained exact AX window's minimized attribute and verifies its receipt without activation or focus. Window mutations are not advertised to older clients, and new clients refuse hosts that would ignore the added receipt evidence or lack restore support.

Exact background PID/window reads are coordinated at the host on generation-pinned process/window read lanes. Each live frame acquires and releases its own lane, so different-process mutations overlap and queued same-process writers cannot be starved by the next frame. The host revalidates owner, process generation, and bounds after admission and completion; drift fails the request without redispatching it against a broader or recycled target. Screen, frontmost, area, unresolved, foreground, web-focus, and menu-opening paths remain globally exclusive. IPC-backed services acquire only in the execution host, never in both client and host.

Protocol `1.21` extends `desktopObservation` with exact-window ROI requests, capture viewport receipts, and one host-owned snapshot-publication transaction. ROI clients require a negotiated 1.21 host with enabled desktop observation and atomic snapshot publication before dispatch so an older or restricted host cannot ignore the optional crop, return full-window pixels, or acknowledge only a raw raster. The client then validates the window ID, owner PID/process generation, full-window bounds, requested and pixel-aligned delivered rectangles, output scale, and every quarantined artifact dimension before publishing caller-visible files or snapshots. Ordinary full-window desktop observation remains compatible with protocol 1.5 hosts.

Current hosts add optional `hostIdentity` and `hostCapabilities` fields to every successful
handshake without advancing the protocol. New clients decode those fields when present and retain
compatibility with older hosts that omit them; older clients ignore the additive keys. Deployment
can require the `backgroundBridgeHost`, `hostGenerationIdentity`, and
`codeSignatureBuildIdentity` capabilities, then compare the reported PID/process-start identity
and code-signature hash with the newly installed app generation before committing an update.

Current hosts with enabled desktop observation also advertise the additive
`desktopObservationOCR` capability without advancing protocol 1.22. Clients require both the
enabled `desktopObservation` operation and that raw capability before sending the new
`accessibilityAndOCR` mode, including dynamic MCP `see {ocr:true}` calls. This prevents an older
1.22 host from trying to decode the newer enum case, and prevents a remote runtime from silently
moving explicit additive OCR into the caller process. The older `preferOCR` request used by
`see --menubar` remains compatible without this new capability. Relaunch an updated host, or use
explicit `--no-remote` caller-local CLI execution when that ownership change is intended.

The additive `desktopObservationCaptureEngine` capability likewise identifies hosts that apply a
non-`auto` capture-engine preference inside each desktop-observation request. Clients refuse
explicit remote `modern` or `classic` selection before transport when this capability or the
enabled `desktopObservation` operation is absent; an older host cannot silently ignore the field
and run its default backend. `auto` remains compatible, and request-scoped selection does not alter
the long-lived daemon's fallback policy.

Protocol `1.22` adds process-generation receipts to process-targeted typing and clicks. Current CLI, Agent, and MCP background input retain the application discovery receipt through Bridge admission and native dispatch. Typing revalidates it before every emitted unit; clicks validate before dispatch and report a retry-unsafe indeterminate outcome if the generation changes after dispatch. Process-targeted Cmd+V uses the generation-pinned hotkey contract introduced in 1.19. New clients refuse older hosts before sending these inputs because an older decoder could otherwise ignore the optional receipt and route input using only a reusable PID. Legacy raw-PID payloads remain decodable for old clients, but current user-facing paths never select them.

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
