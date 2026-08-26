---
summary: 'Set accessibility element values directly via peekaboo set-value'
read_when:
  - 'filling form fields without synthesized typing'
  - 'debugging direct AX value mutation from the CLI'
---

# `peekaboo set-value`

`set-value` writes an accessibility value directly to a settable element. It is the CLI equivalent of the MCP `set_value` tool and avoids keyboard synthesis, cursor movement, input-method timing, and autocomplete side effects when replacement semantics are intended.

## Options

| Option | Description |
| --- | --- |
| `<value>` | String value to write. |
| `--on <id-or-query>` | Element ID from `peekaboo see`, or a query used by the automation service. Required. |
| `--snapshot <id>` | Snapshot ID from `peekaboo see`; uses the latest unmodified UI snapshot when omitted. |
| Target flags | `--app`, `--pid`, `--window-id`, `--window-title`, and `--window-index` scope the mutation without activating the app. |
| `--foreground` | Explicitly focus the target before mutation and allow web-content discovery to focus the page when required. |

## Notes

- The target element must expose a settable accessibility value.
- Every mutation requires a current snapshot. App/PID/window target flags capture one automatically; without target
  flags, run `peekaboo see` first. A missing snapshot is refused instead of falling through to the frontmost app. Exact
  process/window receipts and the final resolved Accessibility element PID are revalidated before the value is written.
- Remote value mutation requires Bridge protocol 1.37 and `processGenerationBoundElementMutations`; older or
  receiptless hosts are refused before the request is sent.
- A result with `requires_fresh_observation: true`, or no canonical outcome, makes that snapshot mutation-ineligible.
  The old evidence stays readable, but another mutation must use a new `peekaboo see` snapshot and otherwise fails
  before dispatch.
- If the Accessibility write is accepted but its readback cannot be verified, Peekaboo reports an indeterminate,
  retry-unsafe result with the exact target receipt. Observe the target again before deciding whether to retry; never
  replay the write against the old snapshot.
- Secure/password fields are rejected; use explicit typing flows for those contexts.
- This is not a replacement for `peekaboo type` when the app needs observable keystrokes, IME handling, autocomplete, or undo grouping.
- JSON and MCP output includes the canonical process-generation `target_identity` and `target_receipt` alongside
  `target`, `actionName`, `oldValue`, `newValue`, and `executionTime`.

## Examples

```bash
peekaboo see --app TextEdit
peekaboo set-value "hello" --on "$ELEMENT_ID" --snapshot <snapshot-id>

peekaboo set-value "42" --on "Search"
```
