---
summary: 'Invoke accessibility actions via peekaboo perform-action'
read_when:
  - 'calling AXPress, AXShowMenu, AXIncrement, or other AX actions from the CLI'
  - 'debugging action-first interaction behavior'
---

# `peekaboo perform-action`

`perform-action` invokes a named accessibility action on an element. It is the CLI equivalent of the MCP `perform_action` tool and gives direct access to actions such as `AXPress`, `AXShowMenu`, `AXIncrement`, `AXDecrement`, `AXShowAlternateUI`, and `AXRaise` when the target app supports them.

## Options

| Option | Description |
| --- | --- |
| `--on <id-or-query>` | Element ID from `peekaboo see`, or a query used by the automation service. Required. |
| `--action <name>` | Accessibility action name, for example `AXPress` or `AXIncrement`. Required. |
| `--snapshot <id>` | Snapshot ID from `peekaboo see`; uses the latest action context when omitted. |

## Notes

- Action-name advertising can be unreliable. Peekaboo validates the action string shape, invokes the action, and surfaces the AX error if the app rejects it.
- Use `click` for normal button activation; use `perform-action` when you need a specific semantic action.
- JSON output includes `target`, `actionName`, and `executionTime`.

## Examples

```bash
peekaboo see --app Calculator
peekaboo perform-action --on "$ELEMENT_ID" --action AXPress --snapshot <snapshot-id>

peekaboo perform-action --on Stepper --action AXIncrement
```
