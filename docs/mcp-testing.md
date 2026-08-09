---
summary: 'Test the Peekaboo MCP server from the current CLI build'
read_when:
  - 'changing MCP tools, schemas, transports, or startup'
  - 'verifying a local MCP build with Inspector or mcporter'
---

# MCP Server Testing Guide

This guide explains how to test the MCP server shipped by `peekaboo mcp`. The same executable accepts `peekaboo mcp serve` explicitly.

## Build the Server Under Test

Build once and resolve the binary from SwiftPM:

```bash
pnpm run build:cli
PEEKABOO_BIN="$(swift build --package-path Apps/CLI --show-bin-path)/peekaboo"
"$PEEKABOO_BIN" --version
```

Use that absolute path throughout a run so an installed `peekaboo` cannot shadow the fresh build.

## Testing Approaches

### 1. MCP Inspector

The official Inspector provides interactive schema and tool-call testing:

```bash
npx @modelcontextprotocol/inspector "$PEEKABOO_BIN" mcp
```

Use it to inspect the tool list, validate inputs, call read-only tools first, and then exercise permission-bound automation.

### 2. mcporter CLI

`mcporter` is useful for repeatable stdio smoke tests:

```bash
mcporter list peekaboo-local --stdio "$PEEKABOO_BIN mcp" --timeout 20000 --schema
mcporter call peekaboo-local.permissions --stdio "$PEEKABOO_BIN mcp" --timeout 15000
```

These commands start a fresh stdio server, perform the MCP initialize handshake, and then list or call tools without a repository wrapper.

### 3. Claude Code Integration

Register the absolute local build for a production-like client test:

```bash
claude mcp add peekaboo-local -- "$PEEKABOO_BIN" mcp
claude mcp list
```

Remove or replace that registration after the test so future sessions do not silently keep using an old debug binary.

### 4. Manual stdio testing

For low-level protocol testing, you can interact with the MCP server directly:

```bash
# Start the server in stdio mode
peekaboo mcp

# Send one JSON-RPC request; Peekaboo drains its response before exiting on EOF
printf '%s\n' '{"jsonrpc":"2.0","method":"tools/list","id":1}' | peekaboo mcp
```

## Development Workflow

### Recommended Testing Cycle

1. Run `pnpm run build:cli` and resolve `PEEKABOO_BIN`.
2. Use Inspector or `mcporter list ... --schema` to confirm initialization and schemas.
3. Call `permissions`, `list`, or another read-only tool.
4. Exercise the changed tool against the Playground fixture when behavior requires real UI.
5. Rebuild after source changes and restart the client/server process; the MCP server does not hot-reload itself.

### Environment Configuration

Set provider selection before starting the server when testing `agent` or `analyze`:

```bash
PEEKABOO_AI_PROVIDERS="ollama/<model>" npx @modelcontextprotocol/inspector "$PEEKABOO_BIN" mcp
```

Credential storage uses the normal CLI:

```bash
"$PEEKABOO_BIN" config credential set ANTHROPIC_API_KEY <value>
```

Do not paste live credential values into test logs or committed fixtures.

## Common Testing Scenarios

### Tool Discovery

- Confirm the changed tool appears once.
- Inspect its description, required properties, and enum values.
- Compare the schema with the corresponding implementation under `Core/PeekabooCore/Sources/PeekabooAgentRuntime/MCP/Tools`.

### Screenshot and Observation

Call `image` or `see` against a known Playground fixture and confirm the response metadata identifies the intended app/window.

### UI Automation

Capture a fresh `see` snapshot, then call `click`, `type`, or another interaction tool with an identifier from that snapshot. Verify the result in Playground's OSLog output.

### Agent Integration

Provider-backed `agent` and `analyze` calls require configuration at server startup. Test missing-credential and invalid-model failures as well as the successful path.

## Troubleshooting

### Server Won't Start

- Run `"$PEEKABOO_BIN" mcp` directly and inspect stderr.
- Confirm the CLI was rebuilt and the absolute binary path exists.
- Check Screen Recording and Accessibility with `"$PEEKABOO_BIN" permissions status`.

### Tools Not Available

- Re-run the schema listing against the same absolute binary.
- Confirm the tool is registered in `MCPToolRegistry`.
- Restart clients after rebuilding.

### Connection Issues

- Keep stdout reserved for MCP protocol traffic; diagnostics belong on stderr.
- Prefer Inspector or mcporter over hand-written JSON-RPC because clients must perform the initialize handshake.
- Increase the client timeout for first startup if the embedded daemon is cold.

## Best Practices

1. Record the exact binary version and command used.
2. Test invalid parameters and permission failures, not only success.
3. Use deterministic Playground fixtures for UI mutations.
4. Keep provider credentials and captured desktop data out of committed artifacts.
5. Run the repository's focused unit tests alongside live MCP smoke tests.
