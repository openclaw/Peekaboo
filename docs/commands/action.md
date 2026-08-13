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

Every action resolves through a current UI snapshot. Pass `--snapshot` explicitly, reuse the latest unmodified `see`
snapshot, or supply app/PID/window target flags so Peekaboo captures a fresh targeted snapshot before dispatch. If no
snapshot can be established, the command refuses rather than searching the user's frontmost app. Exact-window snapshots
also pin the process generation, window identity, and bounds; drift before dispatch is refused.

When JSON reports `requires_fresh_observation: true`, or the host cannot return a canonical outcome, that snapshot
remains readable for diagnostics but cannot drive another mutation. Run `peekaboo see` again and use its new snapshot
ID; replaying the old ID is refused before dispatch.
