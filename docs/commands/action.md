---
summary: 'Invoke accessibility actions via peekaboo action'
read_when:
  - 'invoking a specific AX action such as AXPress or AXIncrement'
---

# `peekaboo action`

`action` invokes a named accessibility action without synthesizing mouse or keyboard input. The action name is positional; `--action` remains available as an alternative form.

```bash
peekaboo action AXPress --on "$ELEMENT_ID" --snapshot <snapshot-id>
peekaboo action AXIncrement --on Stepper --app Calculator
peekaboo action --action AXShowMenu --on "$ELEMENT_ID" --pid 1234
```

Use `--app`, `--pid`, `--window-id`, `--window-title`, or `--window-index` to focus the intended target before the action. Window title/index selectors require an app or PID. The equivalent MCP tool is `action`.
