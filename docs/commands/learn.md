---
summary: 'Dump the full Peekaboo agent guide via peekaboo learn'
read_when:
  - 'needing the latest system prompt, tool catalog, and best practices in one blob'
  - 'building or QA-ing external agents that embed Peekaboo instructions'
---

# `peekaboo learn`

`peekaboo learn` prints the canonical background-only public Agent guide. It stitches together the matching generated system prompt and Shell-free Agent tool registry, best-practice checklists, common workflows, and the full Commander signature table so other runtimes can stay in sync with the CLI release.

## What it emits
- **System instructions** straight from background-only `AgentSystemPrompt.generate()`, including communication rules and safety guidance.
- **Tool catalog** grouped by category with each public Agent tool’s abstract, required/optional parameters, and JSON examples (if available). Shell is not a public Agent tool.
- **Best practices + quick reference**: long-form guidance for automation patterns, then a condensed cheat sheet.
- **Commander section**: a programmatic dump of every CLI command’s positional arguments, options, and flags (built by `CommanderRegistryBuilder.buildCommandSummaries()`).

## Implementation notes
- The command is intentionally text-only—`--json` is ignored—so downstream systems should capture stdout if they want to cache the content.
- Everything runs on the main actor because it pulls the same background-only, policy-filtered toolset as a normal Agent session plus live Commander metadata; no parallel discovery catalog is involved.
- Because it reuses the same builders the CLI uses at runtime, new commands/tools automatically show up here as soon as they land.
- Background-only typing examples use a fresh exact non-dialog snapshot; app/PID/window-selector-only Agent typing is intentionally absent because policy refuses it.
- When stdout is a rich TTY, output is rendered with Swiftdansi for ANSI color and table/box formatting; piped output stays plain Markdown for downstream tools.

## Examples
```bash
# Save the full guide for another agent runtime
peekaboo learn > /tmp/peekaboo-guide.md

# Extract just the Commander signatures
peekaboo learn | awk '/^## Commander/,0'
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
