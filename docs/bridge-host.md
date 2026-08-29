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
capable Peekaboo.app GUI Bridge host before starting a daemon on demand. Implicit screen-capture observation, AX-tree
inspection, browser, and snapshot-state commands additionally prefer the current CLI build's deterministic
`daemon-<build>.sock` and may start that exact-build daemon before considering the GUI host. This keeps in-memory state
and host capabilities on the same executable generation. An explicit Bridge socket, a custom daemon socket, and
`--no-remote` bypass that preference.
Operations that permit process-local fallback can use it when no compatible host is available. Application inventory
and launch prefer the GUI host, while relaunch and quit require a reusable daemon that survives the caller.

Commands carrying a concrete snapshot reference do not use this preference order. They resolve the unique producer as
described in [Snapshot authority](#snapshot-authority) before selecting an execution host.

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
Clawdbot.app sockets participate automatically only in authenticated snapshot-owner resolution; for commands without
a concrete snapshot they remain diagnostic-only unless selected with `--bridge-socket` or
`PEEKABOO_BRIDGE_SOCKET`.

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

## Embedding a native host

Signed macOS applications can host the native automation surface without linking `PeekabooCore`, Tachikoma, browser
support, or agent/provider state. The `PeekabooBridge` product exposes a checked runtime with an explicit socket and
explicit caller-signing policy:

```swift
import PeekabooBridge

let runtime = await PeekabooEmbeddedBridgeRuntime.make(
    configuration: .init(
        socketPath: embeddedBridgeSocketPath,
        allowlistedTeams: ["YOUR_TEAM_ID"],
        allowlistedBundles: ["com.example.AutomationClient"]))
try await runtime.startChecked()
```

The standard assembly uses one durable desktop-mutation watermark with one in-memory snapshot manager, copies retained
capture artifacts into manager-owned storage, and defaults action-capable input to accessibility-first background
delivery. Its allowlist is native-only: browser MCP, daemon control, interactive permission prompts, and the legacy
AppleScript probe cannot be enabled by configuration. Protocol 1.31 Agent execution is also excluded: the embedded
native Bridge deliberately has no Agent or provider surface. The containing app remains responsible for presenting
permission UI and choosing an app-specific socket path; embedded hosts never compete for Peekaboo.app's socket by
default. The runtime always advertises the `backgroundBridgeHost` capability; caller-supplied capabilities are additive
and cannot remove that routing contract.

Retain the runtime for the full host lifetime. `startChecked()` returns only after the private UNIX listener is ready,
and `stopChecked()` waits for non-cooperative in-flight requests to release the socket lease. Concurrent start, stop,
and restart intents execute in arrival order, so a later stop cannot be undone by an older suspended restart. A failed
signing-capability registration or bind leaves the runtime stopped and does not publish a partial host.

Native embedding clients that need a split pointer down/up sequence can use
`ExactWindowHeldPointerLifecycleServiceProtocol`. This API is intentionally absent from the standalone CLI and MCP
tool catalog. The source-bound `peekaboo-certification-controller --held-pointer-plan` mode exercises this same
embedding API for physical release qualification; it is not an end-user input command. Create one opaque owner,
begin with an exact process-generation/window/bounds target and a bounded
expiry, then release or revoke with the returned opaque hold receipt. Mouse-down retains that exact window's mutation
lane across calls. A matching release, explicit owner disconnect, caller cancellation, target drift, or watchdog expiry
wins terminal cleanup exactly once. Mouse-up is sent only while the original process generation remains live; if its
PID was recycled, cleanup fails with a typed partial outcome instead of targeting the replacement process. Disconnect
the owner before releasing the embedding client. Terminal results remain available in a bounded replay cache so
concurrent or retried release/revoke calls return the first result without another mouse-up; idle-owner disconnect
closes the owner as a signed no-change operation.

Peekaboo.app and the reusable daemon still use the full `PeekabooServices` registry because they also own agent,
browser, configuration, audio, and visualizer state. A follow-up can make that registry compose this native bundle once
those app-only services are injected separately; moving them into the embedded runtime would defeat its lean boundary.

## Transport

- **UNIX-domain socket**, single request per connection:
  - Client writes one JSON request, then half-closes.
  - Host replies with one JSON response and closes.
- Payloads are `Codable` JSON with a small handshake for:
  - protocol version negotiation
  - capability/operation advertisement
  - optional raw-string client capability offers for same-version feature negotiation
  - optional host PID/process-start identity, bundle version, code-signature hash, and launch-mode
    capabilities for exact-generation deployment readiness checks
- Each listener holds an exclusive lease beside its socket for its full lifetime.
- A host removes an existing socket only after acquiring the lease and matching the path to the exact device/inode
  recorded by the previous lease owner. Pre-lease sockets are recovered only after proving no same-user process has the
  exact UNIX path open; a failed connect alone never marks a socket stale.
- New listeners bind and secure a private temporary socket, then publish it atomically without replacing an existing
  path.
- Shutdown removes the socket only when its filesystem identity still matches the listener that created it.
- Socket descriptors are nonblocking and deadline-bound. Client, host, and certification transport waits run off
  Swift's cooperative executor; their owners await actual I/O completion before closing descriptors or releasing permits.
- Accepted connections are bounded before liveness/task allocation. Authenticated connections acquire a separate bounded
  body-read permit before reading or decoding a request. Decoded requests then acquire request admission, whose default
  limit is 32 concurrent requests (`maximumConcurrentRequests`). Saturated decoded requests use a separately bounded
  refusal lane without claiming or dispatching the operation; stalled bodies cannot consume request admission.
- Listener acceptance is kernel-readiness-driven: one coalesced notification drains the queued connection backlog to
  `EAGAIN`, while source cancellation owns descriptor closure and bounded shutdown waits for queued handlers to drain.

Protocol `1.3` adds element action operations:

- `setValue` for direct accessibility value mutation.
- `performAction` for named accessibility action invocation.

Protocol `1.4` adds browser MCP operations for persistent Chrome DevTools MCP sessions.
Protocol `1.26` makes those sessions fail closed: connection success requires a read-only page probe and an exact
process-generation or loopback DevTools-browser receipt, and later calls cannot silently rediscover another profile.

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

Protocol `1.36` adds `compositeTypeDelivery` for background type requests that may use AXValue delivery: non-empty text,
clear, and editable focused-text keys. Each direct AX mutation counts as one dispatch and zero key presses; event fallback
counts its posted key events, and mixed requests report composite delivery. Event-only special keys retain their earlier
compatibility floor. Current clients require the raw capability before transport, and current hosts reject older
negotiated sessions before handler entry; signed results correlate the request actions, key count, dispatch count, and
actual delivery mechanisms. Current type results also carry an optional special-key event count; older payloads omit it
and remain decodable, while present counts are bound by signed receipt validation.

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

Protocol `1.29` adds listener-signed operation receipts without imposing a lifetime request limit on a long-running
host. The handshake returns a stable ephemeral listener attestation and a peer-bound logical operation-session
attestation. The session binds the listener, client-instance UUID, exact peer process generation and CDHash, bounded
request capacity, and optional predecessor session. Protocol 1.28 and older handshakes omit both attestations and keep
their existing raw, receiptless request/response behavior.

Protocol `1.30` adds separate application and window mutation-inventory requests and responses. These responses carry
the planner's catalog rows together with explicit `complete` or `partial` state and bounded warnings. The legacy
`listApplications` and `listWindows` request bytes, response families, operations, and protocol 1.29 receipt contract
remain unchanged. A client uses the new cases only after negotiating 1.30 plus the `plannerInventoryTransport`
capability and the corresponding enabled list operation. Otherwise it converts the legacy row array into an explicit
partial inventory: broad name, title, index, or automatic selection then fails closed, while the planner may still use
a direct exact-PID or exact-window-ID provider. The selected mutation plan remains local; Bridge transports evidence,
not a second host-owned selector policy.

Protocol `1.30` also adds the embedding-only exact-window held-pointer lifecycle. The host registers a random bearer
owner bound to the authenticated Bridge client generation and returns a separate opaque receipt after routing primer
and mouse-down dispatch. Release, revoke, and disconnect accept only the matching owner and receipt, carry exact target
and cleanup outcomes through signed operation receipts, and refuse zero-dispatch against protocol 1.29 or older hosts.
The host retains the exact-window write lane until terminal cleanup; a short watchdog handles expiry, window drift,
client-generation exit, and target-generation exit without ever posting mouse-up to a recycled PID.

Protocol `1.31` adds the capability-gated `agentExecutionTrace` operation for one long-running, signed background Agent
execution. It is a single Bridge request from launch through terminal reap, not a prepare/start or other two-call
lifecycle. The host derives the executable from the exact authenticated Peekaboo CLI peer and accepts only the task and
bounded coordination inputs. It never accepts an executable path, shell command, AppleScript, JXA, arbitrary arguments,
or environment overrides. Because the task is carried in `argv`, its UTF-8 encoding is limited to 256 KiB and the host
also caps the complete argument, environment, terminator, and pointer payload at 512 KiB before `posix_spawn`; this
retains half of macOS's 1 MiB `ARG_MAX` as headroom instead of exposing a late `E2BIG`. The closed provider environment
accepts canonical `X_AI_API_KEY` as well as the `XAI_API_KEY` and `GROK_API_KEY` aliases. The child invocation is fixed
to background-only `agent run --no-cache --bridge-socket
<serving-host> --json`; there is no foreground-authority flag, session resume, or cache write.

The host creates bounded anonymous stdout and stderr pipes plus separate anonymous lockdown-readiness and release
pipes. It spawns the exact CLI with `START_SUSPENDED | SETSID`, then sends `SIGCONT` only to enter the CLI's trusted
earliest gate. Before command routing, that gate requires an untainted non-root process with equal real and effective
UIDs, irreversibly lowers both soft and hard `RLIMIT_NPROC` to zero, verifies the readback, removes the private gate
variables, and writes the exact challenge plus EOF to the lockdown pipe. The host requires that readiness before it
publishes the owner-private coordination file. Only after the connected client acknowledges the locked-down child and
all identities are revalidated does the host provision the nested operation-receipt directory. Preparation retains a
nonblocking exclusive lock on the exact owner-private run-root descriptor but creates no directory, so any refusal
before coordination publication leaves the same root retryable without deleting caller-visible state. After a valid
acknowledgement, the host creates an unguessable staging directory, binds its descriptor and inode, and atomically
publishes it at the canonical receipt path immediately before release. A replacement, nonempty entry, symlink, or
publish race is preserved and refused rather than removed. The host then writes the challenge plus EOF to the release
pipe. A stray same-user
`SIGCONT` can therefore start only the fail-closed gate; it cannot authorize Agent command routing.

Hard `RLIMIT_NPROC = 0` is inherited and cannot be raised by the non-root child. It denies `fork`, `vfork`, and ordinary
`posix_spawn`, while threads, files, provider networking, and nested Bridge sockets remain available. The fresh session
therefore contains one process for its entire lifetime; the fixed background Agent also exposes no Shell tool. The host
observes that exact leader with `waitid(..., WNOWAIT)` and reaps it with `waitpid`; cancellation, timeout, and output
overflow signal only the leader. If the kernel wait anchor is unexpectedly lost, cleanup never signals an unverified
numeric PID: it uses the retained PID-version audit token for a generation-bound signal and reaps only after the exact
WNOWAIT child is reacquired. A future Agent tool that needs child processes requires a new protocol policy or a separate
broker; it must not weaken this launch contract.

The process limit is not rollback for effects already accepted by external apps, launchd, XPC services, or nested
Bridge tools, and it is not a containment claim for a compromised signed CLI. Those effects remain governed by their
own exact target, receipt, permission, and retry semantics.

The signed terminal v1 response commits the exact request, process identity, fixed argv, task and closed-environment
commitments, coordination and acknowledgement bytes plus hashes, complete bounded stdout/stderr bytes plus hashes and
sizes, exit status or terminating signal, and launch/lockdown/release/terminal-observation timestamps. Its canonical
`responseSHA256` binds those fields into the protocol 1.29 receipt chain. The hidden qualification adapter writes the
canonical `PeekabooBridgeOperationReceiptBundle` itself, not a newly encoded semantic response, so its exact canonical
request/response bytes and listener/session signatures remain independently checkable. The connected listener
attestation captured during the authenticated handshake remains the external trust anchor; a bundle's self-carried
listener proves integrity but not provenance by itself. Once the release pipe accepts the complete challenge, losing
the response is retry-unsafe: callers must not launch the task again speculatively.

The outer orchestration request deliberately takes no desktop-operation lane or mutation watermark. Each nested Agent
tool call returns through the same host and acquires its own exact-target lane and signed operation receipt, so a
long-running Agent does not serialize unrelated desktop work. Protocol 1.30 and older hosts, and 1.31 hosts that do not
advertise and enable `agentExecutionTrace`, refuse before child launch. The CLI adapter for qualification is hidden and
deliberately omitted from public help and shell completions.

The client does not treat the response-carried, self-signed listener as provenance by itself. It captures the connected
socket peer's audit token and requires exact PID/PID-version, process-start, live kernel CDHash, Apple-anchored signing
identity, trusted team membership, and listener-host agreement before installing a 1.29 session. Bundled Peekaboo
socket paths use the release-team migration allowlist. Custom socket clients must pass `trustedHostTeamIDs`; omitting
that policy caps the handshake at receiptless protocol 1.28 so an arbitrary same-user Developer ID process cannot
replace the socket and mint a trusted-looking receipt chain.

Each protocol 1.29 request reserves one decimal-string sequence in its logical session and carries a deterministic
RFC 9562 version-8 request UUID derived from the full `(session ID, sequence)` tuple. Replay protection retains the
tuple in a fixed-size bitset and accepts previously unused slots out of order, so concurrent requests do not depend on
arrival order. A successful terminal response is inseparable from its Ed25519 receipt: it binds the listener and
session attestations, exact request and response digests, peer identity, canonical target attribution, desktop-action
outcome when present, remaining session capacity, and timestamps. A missing or invalid receipt invalidates that client
session. For a mutating operation, losing the response or receipt after dispatch yields an indeterminate,
retry-unsafe result rather than a speculative retry.

Window and frontmost capture receipts bind the exact process/window identity returned by capture metadata; a missing
target or a window ID that contradicts the request is rejected. Screen and area captures remain targetless global reads.

Protocol `1.37` adds `processGenerationBoundElementMutations`. Current clients require this capability, attested
operation receipts, and the existing `setValueResultTargetBinding` contract before sending `setValue` or
`performAction`. The host binds the snapshot receipt, final resolved AX element PID, canonical outcome, and returned
target to one process generation. All pre-1.37 hosts, including protocol 1.32–1.36, are refused before the request is
written. A current 1.37-capable host advertises these operations only when its automation provider supports
generation-bound mutations and canonical outcomes. It removes `setValue` and `performAction` from downgraded or
receiptless handshakes and rejects direct requests without the negotiated capability before invoking the provider. A
claimed success without its process-generation target is treated as indeterminate and retry-unsafe.

Protocol `1.34` introduced three independent capabilities:

- `nativeBrowserConnectionBinding` authenticates native Chrome channel ownership.
- `producerBoundSnapshotReferences` enables canonical snapshot creation plus the read-only `ownsSnapshot` ownership
  probe.
- `targetedClickAccessibilityValueDelivery` attests that the host understands and enforces the targeted-click
  Accessibility value-delivery policy. An omitted policy retains legacy value fallback; explicit `true` and `false`
  both require this negotiated capability.

Clients must test the capability needed by an operation; none implies either of the others. The latter two additions
also require their exact raw strings in the optional handshake `clientCapabilities` offer. A current host suppresses
`ownsSnapshot` and the corresponding host capability when an already-shipped 1.34 client omits that offer, so the old
client never sees an unknown operation. Conversely, a current client refuses snapshot creation/publication through an
old or restricted 1.34 host that does not return `producerBoundSnapshotReferences`. It does not silently downgrade to
timestamp references, publish locally after remote observation, or replay an action through another host.

Protocol `1.35` adds the service-derived `requestPinnedExactWindowScrollReceipt` capability. A background scroll
carries the fresh snapshot's PID, process generation, WindowServer ID, and immutable bounds in the request; the native
service independently resolves the snapshot and refuses any mismatch before dispatch. Successful results and
retry-unsafe failures retain that same target in the signed receipt. Current clients do not send background scroll to
older hosts, and current hosts negotiating protocol 1.34 or earlier return an explicit runtime-incompatible no-dispatch
refusal instead of silently accepting the older receipt-less request shape.

Browser execution is bound atomically to the connection receipt observed before dispatch. Protocol 1.29 carries the
complete normalized browser URL, WebSocket debugger URL, DevTools browser ID, browser version, protocol version, and
channel. Protocol 1.34 plus `nativeBrowserConnectionBinding` is required for native channel resolution, which carries
the owning PID, process generation, and exact Chrome bundle identity after authenticating the signed channel identifier,
Google Team ID `EQHXZ8M8AV`, and CDHash for that PID generation, binding Chrome's stable authority file to one exact
loopback listening socket, opening its approval-gated WebSocket, verifying CDP `Browser.getVersion`, and rechecking both
signer and listener ownership before publication and later execution. Protocol 1.33 and older hosts retain explicit
loopback URL compatibility but cannot authorize this combined receipt. Isolated-profile children remain unbound.
Explicit loopback `browser_url` remains the custom/non-Google compatibility path and does not claim native channel
signer authority. The response carries the same endpoint receipt, and any process, signer, listener, endpoint, or channel drift refuses
before the first tool call. Browser batches also sign separate completed and dispatched-or-accepted call
counts. If a later call fails, the typed partial or indeterminate outcome preserves that exact prefix and is
retry-unsafe, so a client cannot safely replay the whole batch.

The current client renews before consuming the final ordinary slot. A successor handshake names and retires its
predecessor while leaving already-claimed operations able to finish and sign against their captured session. If a
previously unclaimed request reaches a retired or exhausted session, the listener returns a separate signed rollover
refusal. That refusal binds the exact attested request and successor attestation and states
`mutation_dispatched=false` and `retry_safe=true`. The client verifies every field and signature before installing the
successor, and automatically retries that request at most once. Claimed-slot replay is rejected rather than converted
to rollover; an invalid refusal, failed successor installation, or second refusal stops before redispatch. A late
valid receipt from the predecessor still completes its original caller, but cannot regress the current session budget
or replace the latest-receipt cache.

The listener archive is private and bounded by listener and logical-session retention, with retired session
directories quarantined before asynchronous cleanup. `PEEKABOO_OPERATION_RECEIPT_DIRECTORY` optionally exports the
complete verification bundle for each terminal protocol 1.29 request. The export is sensitive and intended for
private certification. The Swift `validateIntegrity()` API proves canonical encoding, signature-chain integrity, and
operation semantics, but not listener provenance: the bundle carries its own self-signed listener. Certification uses
`validate(trustAnchor:)` with an exact listener attestation, public key, or digest obtained from an independently
authenticated live handshake. `peekaboo bridge receipt validate` exposes that anchored verification and reports the
authenticated host source commit and negotiated protocol separately from the protocol-1.29 receipt floor. The live
multi-target coordinator validates every exported bundle against the exact connected listener before certification.

Protocol 1.29 result validation is driven by one exhaustive semantic plan shared by server finalization and receipt
verification. It classifies the response family, allowed delivery/mode alternatives, fixed or operation-dependent unit
counts, allowed terminal states and result values, and whether target evidence must come from the request, response, or
execution handler. Offline verification therefore never feeds a claimed response-resolved target back into its own
proof, accepts a success for an error-only protocol 1.29 operation, or permits a prepared-dialog kind/target to drift.

## Security

Peekaboo BridgeHost validates callers before processing any request:

- Reads the peer PID via `getsockopt(..., LOCAL_PEERPID, ...)`.
- Validates the peer’s **code signature TeamID** via Security.framework (`SecCodeCopyGuestWithAttributes`).
- Rejects any process not signed by an allowlisted TeamID (default: `FWJYW4S8P8`, plus `Y5PE65HELJ` for transition-era CLI compatibility).

Debug-only escape hatch:

- Set `PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS=1` to allow same-UID unsigned clients (local dev only).

## Snapshot authority

Actionable snapshot references are producer-bound opaque values with the exact grammar `ps1_` plus 32 lowercase ASCII
hexadecimal digits. The 128-bit random suffix makes cross-process collisions impractical; a reference becomes owned
only when its producer creates it, before storing detection or screenshot state. Malformed and legacy timestamp-style
IDs are never accepted as action authority.

The disk owner marker is durable routing and collision evidence inside the user's cooperative cache. It does not
authenticate snapshot state against a hostile same-user process that can already rewrite that cache.

When an action supplies a concrete reference, the CLI checks caller-local services and all authenticated live Bridge
candidates: reusable and build-scoped daemons, Peekaboo.app, Claude.app, and Clawdbot.app. It routes only when exactly
one reports ownership through `ownsSnapshot`. Zero claims, multiple claims, an unreachable producer, or a host that
cannot negotiate producer-bound references fails before dispatch. There is no “latest” substitution, local fallback,
cross-host recreation, or speculative replay.

`--bridge-socket` and `PEEKABOO_BRIDGE_SOCKET` are strict: only that authenticated listener may claim the reference,
and failure is terminal. `--no-remote` and `PEEKABOO_NO_REMOTE` check only the caller-local manager. Without either
override, the ownership probe can select Claude.app or Clawdbot.app even though those sockets are not general implicit
routing fallbacks.

Long-lived hosts normally keep automation state in memory; disk-backed managers persist an owner marker with the
snapshot directory so ownership survives restart. Screenshot artifacts remain path references rather than raw Bridge
response bytes. Protocol 1.5 desktop observation provides the raster metadata, while protocol 1.34 plus the negotiated
`producerBoundSnapshotReferences` capability governs current creation and affinity checks.

## CLI behavior

- By default, automation-oriented CLI commands use a healthy reusable daemon, then a capable Peekaboo.app GUI host,
  then auto-start a daemon, with process-local execution as the final operation-dependent fallback. Implicit
  screen-capture observation, AX-tree inspection, browser, and snapshot-state work first prefers—and may auto-start—the
  current CLI build's build-scoped daemon so an older compatible host does not become the owner of build-sensitive
  in-memory state.
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
