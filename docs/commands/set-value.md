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
| `--snapshot <id>` | Snapshot ID from `peekaboo see`; uses the latest action context when omitted. |

## Notes

- The target element must expose a settable accessibility value.
- Secure/password fields are rejected; use explicit typing flows for those contexts.
- This is not a replacement for `peekaboo type` when the app needs observable keystrokes, IME handling, autocomplete, or undo grouping.
- JSON output includes `target`, `actionName`, `oldValue`, `newValue`, and `executionTime`.

## Examples

```bash
peekaboo see --app TextEdit
peekaboo set-value "hello" --on "$ELEMENT_ID" --snapshot <snapshot-id>

peekaboo set-value "42" --on "Search"
```
