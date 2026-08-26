---
summary: 'Diagnose Bridge hosts and verify signed operation receipt bundles'
read_when:
  - 'verifying whether the CLI is using Peekaboo.app / Clawdbot.app as a Bridge host'
  - 'debugging codesign / TeamID failures for bridge.sock connections'
  - 'checking which socket path Peekaboo is probing'
  - 'verifying a private protocol 1.29 operation receipt bundle'
---

# `peekaboo bridge`

`peekaboo bridge` reports how the CLI resolves a Peekaboo Bridge host (the socket-based TCC broker used for Screen Recording, Accessibility, and Event Synthesizing).

## Subcommands
| Name | Purpose |
| --- | --- |
| `status` (default) | Probes configured sockets and reports reusable and build-scoped daemons, the healthy Peekaboo.app GUI host, auto-start plans, or final operation-dependent local fallback. |
| `receipt validate` | Authenticates one exact live listener and verifies one private exported protocol 1.29 terminal bundle against it. |

## Notes
- Normal automation routing reuses a healthy daemon, then tries a capable Peekaboo.app host before starting a daemon
  on demand; operation-specific requirements can prefer the GUI host or require a surviving daemon. The complete host
  discovery order is documented in `docs/bridge-host.md`.
- Implicit screen-capture observation, AX-tree inspection, browser, and snapshot-state commands first prefer the exact
  CLI build's build-scoped daemon and may auto-start it before considering the GUI host. Use the command's actual
  requirements—not the generic status ordering—to interpret which reported host it will select.
- A command carrying a canonical `ps1_` snapshot reference uses unique authenticated producer affinity instead of the
  generic ordering, including local, daemon, Peekaboo.app, Claude.app, and Clawdbot.app candidates. Zero or multiple
  owners fail before dispatch with no fallback or replay. See [`bridge-host.md`](../bridge-host.md#snapshot-authority).
- `--no-remote` (or `PEEKABOO_NO_REMOTE`) skips remote probing and forces local execution.
- `--bridge-socket <path>` (or `PEEKABOO_BRIDGE_SOCKET`) overrides host discovery and probes only that socket.
  The override is strict: an unavailable or incompatible host fails non-zero instead of silently using the local
  runtime. Pass `--no-remote` explicitly when caller-local execution is intended.
- Status probes run concurrently and give each candidate one second to complete its read-only diagnostic handshake. A `timeout` entry means that host missed the diagnostic deadline; other candidates are still reported and normal runtime selection order is unchanged.
- Hosts validate callers by code signature TeamID. If the host rejects the client (`unauthorizedClient`), install a signed Peekaboo CLI build or enable the debug-only escape hatch on the host.
- If every selection-eligible implicit host is rejected, normal human output warns before the CLI reports local fallback. Structured output keeps the established full status-report schema for compatibility.
- If `bridge status` reports `internalError` / “Bridge host returned no response”, the probed host likely closed the socket without replying (older host builds). Hosts built from `main` after 2025-12-18 return a structured `unauthorizedClient` error instead, which is much easier to debug.
- If a candidate reports `perm: SR=N`, grant Screen Recording to that host app. For capture-only subprocesses whose caller already has Screen Recording, bypass Bridge with `--no-remote --capture-engine cg`.
- Structured status includes optional `hostIdentity` and `hostCapabilities` from current hosts.
  `hostIdentity` carries the serving PID/process-start identity plus bundle versions and the exact
  executable code-signature hash; older hosts omit these fields and continue to decode normally.
- Protocol 1.34 negotiates `nativeBrowserConnectionBinding`, `producerBoundSnapshotReferences`, and
  `targetedClickAccessibilityValueDelivery` independently. The snapshot and targeted-click additions require matching
  optional raw client offers, so old 1.34 clients are not shown the unknown `ownsSnapshot` operation, an omitted click
  policy retains legacy value fallback, and either explicit allow or deny requires a host that understands the field.
  New clients refuse hosts that cannot publish producer-bound references.
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
  listener is self-signed and carried inside the bundle. `bridge receipt validate` instead requires `--bridge-socket`,
  authenticates that exact connected host from the Unix-socket audit identity and signing team, and calls
  `validate(trustAnchor:)` with the complete listener attestation from that independent live handshake. Standard
  Peekaboo socket paths use the built-in release-team policy; custom paths require one or more explicit
  `--trusted-host-team-id` values. A listener mismatch, protocol 1.28 downgrade, missing attestation, invalid signature,
  or semantic contradiction fails nonzero. Structural JSON checks and the bundle's own self-signature are never trust
  anchors.
- Receipt validation accepts only an owner-private, non-symlink regular bundle, reads at most 256 MiB through one
  descriptor, and reports minimized hashes/identities rather than the canonical command/response bytes or private host
  archive path. A live result also includes the authenticated handshake's `host_source_commit` and
  `host_protocol_version`, so certification can bind the listener to its exact source and negotiated protocol.
  `minimum_protocol_version` remains `1.29`: it describes the signed receipt-schema floor, not the connected host's
  negotiated protocol. The output fields `target_attested` and `outcome_attested` describe actual signed field
  presence; a valid read-only receipt can truthfully report `outcome_attested: false`.
- Protocol 1.30 advertises `plannerInventoryTransport` and carries application/window mutation inventories through
  separate request and response cases with explicit completeness and warnings. Protocol 1.29 list requests remain
  byte-compatible; clients treat their row-only responses as partial evidence, refusing broad mutation selectors while
  retaining direct exact-PID and exact-window-ID compatibility.
- Protocol 1.31 advertises `agentExecutionTrace` for one long Bridge request that launches and reaps an authenticated
  Peekaboo CLI peer as a fixed background-only `agent run --no-cache --bridge-socket <serving-host> --json` child. The
  host accepts no executable, shell, AppleScript, JXA, arbitrary argv, or environment input. It binds suspended-child
  identity revalidation, fresh `SETSID` session, earliest-entrypoint lockdown/readiness and release pipes,
  owner-private challenge/acknowledgement coordination, bounded stdout/stderr, and terminal `waitid`/`waitpid`
  evidence into a signed v1 response. Task UTF-8 is capped at 256 KiB, and a 512 KiB aggregate argv/environment
  preflight leaves half of macOS's 1 MiB `ARG_MAX` for runtime overhead. The closed provider environment preserves
  canonical `X_AI_API_KEY` plus the `XAI_API_KEY` and `GROK_API_KEY` aliases. Preparation locks the exact owner-private
  run-root descriptor without creating the nested receipt directory. Only after a valid acknowledgement does the host
  bind a fresh staging directory by descriptor and inode and atomically publish it at the canonical receipt path
  immediately before release; replacement, nonempty, symlink, and publish-race state is retained and refused. Before
  readiness, the untainted non-root CLI locks both soft and hard
  `RLIMIT_NPROC` to zero; the signed response commits that exact policy. `SIGCONT` alone cannot authorize Agent code.
  The child cannot `fork`, `vfork`, or use ordinary `posix_spawn`, so normal exit, cancellation, timeout, and overflow
  own and reap one exact WNOWAIT leader. An unexpected lost wait anchor permits only PID-version/audit-token-bound
  direct signaling and requires the exact WNOWAIT child again before reap, never a raw unverified PID. Threads,
  provider networking, and nested Bridge sockets remain available, but the fixed background Agent exposes no Shell
  tool; future child-spawning tools require a new protocol policy or separate broker. External app, launchd, XPC, and
  nested-tool effects remain outside process rollback. The outer request takes no
  desktop lane, while nested Agent tools take their own exact lanes and signed receipts. Missing protocol/capability
  support refuses before launch, and response loss after release is retry-unsafe. The qualification CLI adapter is
  intentionally hidden from help and completions and emits the canonical signed receipt bundle; it is not a public
  two-call lifecycle or a general process-launch command.
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
# Human-readable status (selected host plus any local-fallback rejection warning)
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

# Validate one private bundle against the authenticated listener that produced it
peekaboo bridge receipt validate \
  --bundle /private/path/to/request-id.json \
  --bridge-socket ~/Library/Application\ Support/Peekaboo/bridge.sock \
  --json

# OpenClaw/subprocess capture workaround when the caller already has Screen Recording
peekaboo see --mode screen --screen-index 0 \
  --no-remote --capture-engine cg --json
```
