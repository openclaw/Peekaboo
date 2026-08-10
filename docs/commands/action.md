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

Use `--app`, `--pid`, `--window-id`, `--window-title`, or `--window-index` to resolve the intended target without
activating it. Window title/index selectors require an app or PID. Add `--foreground` only when the action depends on
focused-window state; this also permits web-content discovery to focus the page when required. The equivalent MCP tool
is `action`.
