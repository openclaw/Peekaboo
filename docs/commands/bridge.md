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
| `status` (default) | Probes the configured socket paths, attempts a Bridge handshake, and reports which host would be selected (or if Peekaboo will fall back to local in-process execution). |

## Notes
- Normal automation routing reuses a healthy daemon, then tries a capable Peekaboo.app host before starting a daemon
  on demand; operation-specific requirements can prefer the GUI host or require a surviving daemon. The complete host
  discovery order is documented in `docs/bridge-host.md`.
- `--no-remote` (or `PEEKABOO_NO_REMOTE`) skips remote probing and forces local execution.
- `--bridge-socket <path>` (or `PEEKABOO_BRIDGE_SOCKET`) overrides host discovery and probes only that socket.
- Status probes run concurrently and give each candidate one second to complete its read-only diagnostic handshake. A `timeout` entry means that host missed the diagnostic deadline; other candidates are still reported and normal runtime selection order is unchanged.
- Hosts validate callers by code signature TeamID. If the host rejects the client (`unauthorizedClient`), install a signed Peekaboo CLI build or enable the debug-only escape hatch on the host.
- If `bridge status` reports `internalError` / “Bridge host returned no response”, the probed host likely closed the socket without replying (older host builds). Hosts built from `main` after 2025-12-18 return a structured `unauthorizedClient` error instead, which is much easier to debug.
- If a candidate reports `perm: SR=N`, grant Screen Recording to that host app. For capture-only subprocesses whose caller already has Screen Recording, bypass Bridge with `--no-remote --capture-engine cg`.
- Structured status includes optional `hostIdentity` and `hostCapabilities` from current hosts.
  `hostIdentity` carries the serving PID/process-start identity plus bundle versions and the exact
  executable code-signature hash; older hosts omit these fields and continue to decode normally.

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
