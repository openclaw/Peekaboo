---
summary: 'Poll window and element predicates via peekaboo verify'
read_when:
  - 'replacing sleep-based polling in UI automation'
  - 'checking window or accessibility state without interaction'
---

# `peekaboo verify`

`peekaboo verify` polls fresh native window and accessibility state until every requested predicate is stable or the timeout expires. It is the deterministic replacement for sleep-based polling: the command never focuses, clicks, or types.

An unrelated Accessibility read failure does not invalidate independently observed positive evidence: one element matching an exact, nonempty AXIdentifier and the full selector can prove existence or an expected value. Missing or ambiguous matches and selectors without an AXIdentifier remain unknown in an incomplete traversal. Such evidence cannot prove absence, a mismatched value, enabled state, or selected state. Cached, structurally truncated, deadline-limited, or identity-mismatched observations remain ineligible; fresh stability samples are still required.

Without `--screenshot`, verification does not probe or claim ScreenCaptureKit ownership, and ambient capture-engine settings do not change its selected host. Requested screenshots retain the normal capture-safety checks.

For a requested screenshot, choose classic capture with `PEEKABOO_CAPTURE_ENGINE=classic`; `verify` does not expose `see`'s `--capture-engine` flag. With an explicit `--bridge-socket`, that choice is transported to the selected compatible host without changing capture ownership. `--no-remote` explicitly selects caller-local capture. Missing host engine/inline-pixel capabilities refuse before evaluation; an ordinary capture or permission failure omits the optional image without discarding valid predicate results.

Results are ternary. `satisfied` exits 0, `unsatisfied` exits 1, and `unknown` exits 2. Evaluated results in JSON output include every predicate result and an `unknown_reason` field; it is `null` when the result is not unknown.

Tool failures that prevent evaluation also exit 2. These failures use the standard error envelope in JSON mode, without predicate results or an `unknown_reason` field.

## Key options

| Flag | Description |
| --- | --- |
| Target flags | `--app`, `--pid`, `--window-id`, `--window-title`, and `--window-index` use the shared target grammar. |
| `--window-exists` | Require the resolved target window to exist. |
| `--window-bounds x,y,w,h[,tolerance]` | Require exact logical-point bounds, with an optional per-component tolerance (default 1). |
| `--on <identifier-or-role:label>` | Select an element by exact AXIdentifier (for example `basic-text-field`) or exact role and label (for example `button:Reload`). |
| `--exists` | Require the selected element to exist. |
| `--value-equals <value>` | Require its accessibility value to match exactly. |
| `--enabled` / `--selected` | Require the corresponding accessibility state. |
| `--timeout <duration>` | Polling timeout (default `5s`, maximum `10s`; bare values are milliseconds). |
| `--stable-samples <n>` | Consecutive identical satisfied samples required (default 2). |
| `--screenshot <path>` | Save one final exact-window PNG when capture is available. |
| `--json` | Emit structured status, predicate results, timing, and the unknown reason. |

## Examples

For an identifier selector, copy `data.ui_elements[].identifier` from `see --json`, not the snapshot-local `data.ui_elements[].id`. Verification polls fresh observations and does not resolve snapshot element IDs. If the app exposes no AXIdentifier, use an exact `role:label` selector.

```bash
peekaboo verify --app Safari --window-exists
peekaboo verify --app Safari --on button:Reload --exists --enabled --json
peekaboo verify --app Playground --on basic-text-field --value-equals Ready --json
peekaboo verify --pid 1234 --window-bounds 40,80,1200,800,2 --timeout 10s
```

The command executes the same `verify_state` MCP tool used by agents, including its 100 ms fresh-observation polling, stability sampling, exact process/window identity checks, and hard ten-second deadline.

For a live explicit PID, polling reads that target's application metadata rather than a full application inventory. Target-specific warnings, failed lookups and process-generation changes remain `unknown`. Proving absence when the native generation is unavailable still requires complete inventory evidence, as do named-app selectors during polling. Optional final screenshots revalidate the pinned process generation and exact window before and after capture, without repeating application inventory.
