---
summary: 'List the MCP tool catalog via peekaboo tools'
read_when:
  - 'deciding which automation tool to call from agents or scripts'
  - 'debugging missing tool registrations'
---

# `peekaboo tools`

`peekaboo tools` prints the background-only MCP tool catalog that `peekaboo mcp` exposes (Image, See, Click, Press, Action, Window, Browser, Inspect UI, etc.). `peekaboo tools describe <name>` prints one tool's policy-aware JSON input schema for token-cheap, on-demand discovery. Guaranteed-refused foreground shapes are omitted from background-only schemas and their descriptions explain the required human-authorized foreground Agent or standalone CLI route. The public Agent catalog is a separate Shell-free surface; run `peekaboo learn` for that exact guide. The CLI keeps `browser` as a dedicated wrapper and exposes AX-only inspection through `peekaboo see --tree --no-screenshot`; run `peekaboo --help` for the full CLI command list.

## Key options
| Flag | Description |
| --- | --- |
| `--no-sort` | Preserve registration order instead of alphabetizing every tool. |
| `--verbose` | Include each tool's description alongside its name. |
| `--json` | Emit `{tools:[…], count:n}` for machine parsing. |

## Subcommands

| Name | Purpose |
| --- | --- |
| `describe <tool-name>` | Print the tool name, abstract, and pretty JSON input schema. With `--json`, emit `{name, description, input_schema}`. Unknown names fail and list every valid name. |

## Implementation notes
- The command and MCP server both use `MCPToolCatalog`, so tool additions only need to be registered once.
- Tool schemas receive the same execution policy as the catalog. Background `app`/`window` descriptions omit focus and switch actions, while foreground-capable Agent schemas expose them under explicit human authority.
- Background clipboard discovery exposes only `get` and `save`. `set`, `clear`, and `restore` persistently change the user's shared clipboard state and require a foreground-authorized workflow; prefer exact targeted transactional paste when possible.
- Allow/deny filtering happens before formatting (`ToolFiltering.apply`), so the output matches MCP server behavior.
- Input-strategy availability filtering also runs before formatting, so action-only tools are hidden when the current policy cannot support them.
- The command runs locally by default because it only reports the static native catalog; use per-tool wrappers or an attached MCP client to execute tools.
- Because the command implements `RuntimeOptionsConfigurable`, it respects global `--json`/`--verbose` flags even when invoked from other commands (e.g., `peekaboo learn` can embed the summaries verbatim).

## Examples
```bash
# Produce a JSON blob for an agent integration test
peekaboo tools --json > /tmp/tools.json

# Fetch only the click tool's schema
peekaboo tools describe click
peekaboo tools describe verify_state --json
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
