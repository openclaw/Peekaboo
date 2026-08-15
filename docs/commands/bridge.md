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
- Protocol 1.29 binds every post-handshake call to one ephemeral listener identity and returns a signed operation
  receipt. Connected peers are bound to the kernel's Unix-socket audit token, including PID version and effective
  UID; Team ID, bundle ID, and CDHash are resolved from that same audit token rather than a reusable numeric PID.
  The host keeps privacy-minimized receipts under `<socket>.receipts/<listener-id>/` with mode `0600` in
  owner-only directories. For a private certification run, setting `PEEKABOO_OPERATION_RECEIPT_DIRECTORY` exports
  one atomic verification bundle per successfully routed protocol 1.29 Bridge request. Local execution and older
  Bridge protocols do not emit a bundle, and certification must fail when an expected bundle is missing. The opt-in
  bundle includes the exact canonical request and response bytes so an independent validator can recompute both
  signed digests, plus the exact listener-attestation and operation-receipt payload bytes used for Ed25519 signature
  verification. SHA-256 digests use lowercase hex; binary fields use JSON base64; process generations use canonical
  decimal strings rather than lossy JSON numbers. The bundle can therefore contain command text and response data
  and must not be enabled for ordinary automation or written to a shared directory.
- Target attribution delegates to the same canonical process/window receipt coalescer used by local automation.
  Exact-window receipts include immutable bounds and optional focused-element identity. Targetless operations with
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
