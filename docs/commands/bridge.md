---
summary: 'Diagnose Peekaboo Bridge host connectivity via peekaboo bridge'
read_when:
  - 'verifying whether the CLI is using Peekaboo.app / Clawdbot.app as a Bridge host'
  - 'debugging codesign / TeamID failures for bridge.sock connections'
  - 'checking which socket path Peekaboo is probing'
---

# `peekaboo bridge`

`peekaboo bridge` reports how the CLI resolves a Peekaboo Bridge host (the socket-based TCC broker used for Screen Recording, Accessibility, and Event Synthesizing).

## Subcommands
| Name | Purpose |
| --- | --- |
| `status` (default) | Probes configured sockets and reports the selected reusable daemon, healthy Peekaboo.app GUI host, auto-start daemon plan, or final operation-dependent local fallback. |

## Notes
- Normal automation routing reuses a healthy daemon, then tries a capable Peekaboo.app host before starting a daemon
  on demand; operation-specific requirements can prefer the GUI host or require a surviving daemon. The complete host
  discovery order is documented in `docs/bridge-host.md`.
- `--no-remote` (or `PEEKABOO_NO_REMOTE`) skips remote probing and forces local execution.
- `--bridge-socket <path>` (or `PEEKABOO_BRIDGE_SOCKET`) overrides host discovery and probes only that socket.
  The override is strict: an unavailable or incompatible host fails non-zero instead of silently using the local
  runtime. Pass `--no-remote` explicitly when caller-local execution is intended.
- Status probes run concurrently and give each candidate one second to complete its read-only diagnostic handshake. A `timeout` entry means that host missed the diagnostic deadline; other candidates are still reported and normal runtime selection order is unchanged.
- Hosts validate callers by code signature TeamID. If the host rejects the client (`unauthorizedClient`), install a signed Peekaboo CLI build or enable the debug-only escape hatch on the host.
- If `bridge status` reports `internalError` / “Bridge host returned no response”, the probed host likely closed the socket without replying (older host builds). Hosts built from `main` after 2025-12-18 return a structured `unauthorizedClient` error instead, which is much easier to debug.
- If a candidate reports `perm: SR=N`, grant Screen Recording to that host app. For capture-only subprocesses whose caller already has Screen Recording, bypass Bridge with `--no-remote --capture-engine cg`.
- Structured status includes optional `hostIdentity` and `hostCapabilities` from current hosts.
  `hostIdentity` carries the serving PID/process-start identity plus bundle versions and the exact
  executable code-signature hash; older hosts omit these fields and continue to decode normally.
- Protocol 1.29 binds every post-handshake call to one ephemeral listener identity and one listener-signed logical
  operation session, then returns a signed terminal receipt. The listener remains stable for the socket lifetime;
  bounded peer sessions roll over without restarting the host or invalidating older in-flight receipts. Each session
  binds the client-instance UUID and the peer's exact PID, PID version/process generation, effective UID, and CDHash
  obtained from the kernel's Unix-socket audit token. Team ID and bundle ID are resolved from that same token rather
  than from a reusable numeric PID.
- The client authenticates a protocol 1.29 listener against the connected UNIX socket's audit token, exact PID/PID
  version, process-start identity, live kernel CDHash, and Apple-anchored signing team before installing its session.
  Standard Peekaboo, daemon, Claude, and Clawdbot socket paths trust Peekaboo's release signing teams by default.
  A custom `PeekabooBridgeClient` socket must pass `trustedHostTeamIDs`; without explicit host trust the client caps
  negotiation at receiptless protocol 1.28 instead of accepting an arbitrary Developer ID listener.
- Every attested request carries a canonical decimal-string session sequence and a deterministic RFC 9562 version-8
  request UUID derived from the complete `(session ID, sequence)` tuple. The tuple, not the UUID alone, is the replay
  key. Unused sequence slots may be claimed out of order so concurrent requests remain valid. Before the bounded
  session is exhausted, the client proactively negotiates a listener-signed successor that names its predecessor.
  A late request using an unclaimed slot in a retired session receives a distinct signed rollover refusal containing
  that successor and exact `mutation_dispatched=false`, `retry_safe=true` facts. Only after verifying the refusal
  against the original request, peer, predecessor session, and listener does the client retry once under the
  successor. A replayed claimed slot, unsigned or mismatched refusal, lost response, invalid receipt, failed successor
  installation, or second rollover refusal is never automatically redispatched.
- The host keeps bounded listener and logical-session archives under a private per-user temporary namespace keyed by
  the socket path. Receipt files use mode `0600`; retired session archives are quarantined and pruned without rotating
  the listener. For a private certification run, setting `PEEKABOO_OPERATION_RECEIPT_DIRECTORY` exports one atomic
  verification bundle per successfully routed protocol 1.29 Bridge request. Local execution, protocol 1.28 and older
  hosts, and signed rollover refusals do not emit terminal receipt bundles. Certification must therefore distinguish a
  verified safe rollover from a missing terminal receipt and fail when a bundle expected for a completed operation is
  absent. The opt-in bundle includes the listener and session attestations, the exact canonical request and response,
  and the canonical signed payload bytes needed to recompute the request/response/session digests and verify Ed25519
  signatures. SHA-256 digests use lowercase hex; binary fields use JSON base64; session sequences and process
  generations use canonical decimal strings rather than lossy JSON numbers. Bundles can contain command text and
  response data, so do not enable export for ordinary automation or write it to a shared directory. The Swift
  `validateIntegrity()` API verifies canonical bytes, the complete signature chain, and operation semantics, but its
  listener is self-signed and carried inside the bundle. Certification must instead call `validate(trustAnchor:)` with
  the exact listener attestation, public key, or digest captured through an independently authenticated handshake.
  Peekaboo validates receipts in process against that live handshake state, but there is not yet a public
  `peekaboo bridge receipt validate` command; external physical certification remains pending that anchored first-party
  verifier rather than treating either structural JSON checks or an unanchored self-signature as proof.
- Target attribution delegates to the same canonical process/window receipt coalescer used by local automation.
  One exhaustive operation semantic plan also owns each success response family, allowed terminal states and result
  values, delivery/mode alternatives, dispatched-unit policy, and request/response/handler target provenance. The
  server uses that plan when filling legacy outcomes, and both live-client and offline bundle validation reject any
  result outside the same plan. Prepared dialog receipts additionally bind their requested action kind and any explicit
  PID/window selector before they can authorize the later exact mutation.
  Exact-window receipts include immutable bounds and optional focused-element identity. Local browser execution uses
  its process-generation target; PID-less explicit DevTools execution signs the full response-bound connection
  receipt. Browser batches separately preserve completed and dispatched-or-accepted call counts, and a partial or
  indeterminate suffix failure is retry-unsafe. Targetless operations with
  no target evidence are recorded as global; missing evidence for target-dependent operations and any incomplete or
  contradictory evidence are instead archived as explicit attribution failures.
  A mutating operation's attribution failure is retry-safe only before dispatch and becomes indeterminate and
  retry-unsafe after dispatch. Each failure signs its pre-dispatch or post-execution stage plus the lossless evidence
  fragments needed to reproduce the canonical failure code. Read-only attribution failures return an ordinary
  invalid-request response.

## Examples
```bash
# Human-readable status (selected host only)
peekaboo bridge status

# Full probe results + structured output for agents
peekaboo bridge status --verbose --json | jq '.data'

# Probe a specific host socket path
peekaboo bridge status --bridge-socket \
  ~/Library/Application\ Support/clawdbot/bridge.sock

# Probe Claude Desktop host socket path (if Claude.app hosts PeekabooBridge)
peekaboo bridge status --bridge-socket \
  ~/Library/Application\ Support/Claude/bridge.sock

# Force local (skip the reusable daemon and all Bridge app hosts)
peekaboo bridge status --no-remote

# OpenClaw/subprocess capture workaround when the caller already has Screen Recording
peekaboo see --mode screen --screen-index 0 \
  --no-remote --capture-engine cg --json
```
