---
summary: 'Poll window and element predicates via peekaboo verify'
read_when:
  - 'replacing sleep-based polling in UI automation'
  - 'checking window or accessibility state without interaction'
---

# `peekaboo verify`

`peekaboo verify` polls fresh native window and accessibility state until every requested predicate is stable or the timeout expires. It is the deterministic replacement for sleep-based polling: the command never focuses, clicks, types, or treats an incomplete observation as success.

Results are ternary. `satisfied` exits 0, `unsatisfied` exits 1, and `unknown` exits 2. Evaluated results in JSON output include every predicate result and an `unknown_reason` field; it is `null` when the result is not unknown.

Tool failures that prevent evaluation also exit 2. These failures use the standard error envelope in JSON mode, without predicate results or an `unknown_reason` field.

## Key options

| Flag | Description |
| --- | --- |
| Target flags | `--app`, `--pid`, `--window-id`, `--window-title`, and `--window-index` use the shared target grammar. |
| `--window-exists` | Require the resolved target window to exist. |
| `--window-bounds x,y,w,h[,tolerance]` | Require exact logical-point bounds, with an optional per-component tolerance (default 1). |
| `--on <id-or-role:label>` | Select an element by opaque ID (for example `B7`) or exact role and label (for example `button:Reload`). |
| `--exists` | Require the selected element to exist. |
| `--value-equals <value>` | Require its accessibility value to match exactly. |
| `--enabled` / `--selected` | Require the corresponding accessibility state. |
| `--timeout <duration>` | Polling timeout (default `5s`, maximum `10s`; bare values are milliseconds). |
| `--stable-samples <n>` | Consecutive identical satisfied samples required (default 2). |
| `--screenshot <path>` | Save one final exact-window PNG when capture is available. |
| `--json` | Emit structured status, predicate results, timing, and the unknown reason. |

## Examples

```bash
peekaboo verify --app Safari --window-exists
peekaboo verify --app Safari --on button:Reload --exists --enabled --json
peekaboo verify --pid 1234 --window-bounds 40,80,1200,800,2 --timeout 10s
```

The command executes the same `verify_state` MCP tool used by agents, including its 100 ms fresh-observation polling, stability sampling, exact process/window identity checks, and hard ten-second deadline.
