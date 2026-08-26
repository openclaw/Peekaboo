---
summary: 'Invoke accessibility actions via peekaboo action'
read_when:
  - 'invoking a specific AX action such as AXPress or AXIncrement'
---

# `peekaboo action`

`action` invokes a named accessibility action without synthesizing mouse or keyboard input. The action name is positional; `--action` remains available as an alternative form.

```bash
peekaboo action AXPress --on "$ELEMENT_ID" --snapshot <snapshot-id> --foreground
peekaboo action AXIncrement --on Stepper --app Calculator
peekaboo action --action AXShowMenu --on "$ELEMENT_ID" --pid 1234 --foreground
```

Use `--app`, `--pid`, `--window-id`, `--window-title`, or `--window-index` to resolve the intended target without
activating it. Window title/index selectors require an app or PID. Actions that can raise or expose foreground UI,
including `AXPress` and `AXShowMenu`, require `--foreground`; state-only actions such as `AXIncrement` remain
background-capable. Foreground mode also permits web-content discovery to focus the page when required. The equivalent
MCP tool is `action`, whose background-only policy refuses foreground-exposing actions before dispatch.

Every action resolves through a current UI snapshot. Pass `--snapshot` explicitly, reuse the latest unmodified `see`
snapshot, or supply app/PID/window target flags so Peekaboo captures a fresh targeted snapshot before dispatch. If no
snapshot can be established, the command refuses rather than searching the user's frontmost app. Process-scoped
snapshots pin the process generation; exact-window snapshots additionally pin window identity and bounds. Missing or
changed generation evidence is refused before element resolution or dispatch.

Remote element actions require Bridge protocol 1.37 and `processGenerationBoundElementMutations`; older or receiptless
hosts are refused before the request is sent. The final resolved Accessibility element must report the same PID as the
snapshot receipt.

Successful JSON and MCP results include the canonical `target_identity` and `target_receipt`, including the process-start
identity needed to distinguish a live process from PID reuse.

When JSON reports `requires_fresh_observation: true`, or the host cannot return a canonical outcome, that snapshot
remains readable for diagnostics but cannot drive another mutation. Run `peekaboo see` again and use its new snapshot
ID; replaying the old ID is refused before dispatch.
