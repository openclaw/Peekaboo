---
summary: 'Dump the full Peekaboo agent guide via peekaboo learn'
read_when:
  - 'needing the latest system prompt, tool catalog, and best practices in one blob'
  - 'building or QA-ing external agents that embed Peekaboo instructions'
---

# `peekaboo learn`

`peekaboo learn` prints the canonical background-only public Agent guide for the current filtered tool catalog, followed by a complete standalone CLI reference. Its generated system prompt, tool count and quick reference agree with the Shell-free Agent registry; CLI examples do not make unavailable tools accessible to an Agent.

## What it emits
- **System instructions** generated from the same available tool names as the catalog. Unavailable tools do not contribute recipes; communication, authority and evidence rules remain unconditional.
- **Tool catalog** grouped by category with each public Agent tool’s abstract, required/optional parameters, and JSON examples (if available). Shell is not a public Agent tool.
- **Agent quick reference**: only names from the filtered catalog, including an explicit empty-catalog message when no tools are available.
- **CLI reference + best practices**: complete standalone command guidance, independently of Agent filters, including exact-window background drag and explicit foreground requirements for shared-pointer workflows.
- **Commander section**: a programmatic dump of every CLI command’s positional arguments, options, and flags (built by `CommanderRegistryBuilder.buildCommandSummaries()`).

## Implementation notes
- The command is intentionally text-only—`--json` is ignored—so downstream systems should capture stdout if they want to cache the content.
- Everything runs on the main actor because it pulls the same background-only, policy-filtered toolset as a normal Agent session plus live Commander metadata; no parallel discovery catalog is involved.
- Tool filters such as `PEEKABOO_ALLOW_TOOLS` and `PEEKABOO_DISABLE_TOOLS` affect the Agent sections, not the complete Commander command signatures. A blank allow-list means no allow-list restriction; combine an allow and matching disable filter to exercise an empty catalog.
- Because it reuses the same builders the CLI uses at runtime, new commands and eligible tools automatically show up here as soon as they land.
- Background-only typing examples use a fresh exact non-dialog snapshot; app/PID/window-selector-only Agent typing is intentionally absent because policy refuses it.
- When stdout is a rich TTY, output is rendered with Swiftdansi for ANSI color and table/box formatting; piped output stays plain Markdown for downstream tools.

## Examples
```bash
# Save the full guide for another agent runtime
peekaboo learn > /tmp/peekaboo-guide.md

# Inspect a minimal Agent catalog with the complete CLI reference
PEEKABOO_ALLOW_TOOLS=permissions peekaboo learn

# Extract just the Commander signatures
peekaboo learn | awk '/^## Commander/,0'
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
