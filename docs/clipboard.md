---
summary: 'Use the shipped clipboard tool across CLI and MCP'
read_when:
  - 'using or debugging clipboard reads, writes, slots, or size limits'
  - 'keeping CLI and MCP clipboard behavior aligned'
---

# Clipboard Tool

Peekaboo ships one `clipboard` domain in the CLI and MCP server for text, images, files, and raw pasteboard data. Both surfaces call the shared `ClipboardService` in `PeekabooAutomationKit`.

## User-facing behaviors
- Actions: `get`, `set`, `clear`, `save`, `restore`, `load`.
- Text: read and write UTF-8 text; `--also-text` adds a plain-text companion to binary data.
- Files and images: infer the UTI from the file extension and write the file bytes to the pasteboard.
- Raw data: accept base64 plus an explicit UTI.
- Slots: `save` and `restore` snapshot all available pasteboard representations. The default slot is `0`; named slots use dedicated macOS pasteboards so separate CLI invocations can restore them.
- Size guard: block writes over 10 MB unless `--allow-large` is set. The limit includes all representations and companion text.
- Verification: CLI `set` and `load` support `--verify`, which reads each supported representation back and compares it with the requested payload.

## CLI syntax (`peekaboo clipboard …`)
- `get [--prefer <uti>] [--output <path|->] [--json-output]`
  - Text prints to stdout. Binary data is written with `--output`; `--output -` streams bytes in text mode and returns base64 in JSON mode.
- `set (--text <string> | --file-path <path> | --data-base64 <b64> --uti <uti>) [--also-text <string>] [--allow-large] [--verify]`
- `clear`
- `save [--slot <name>]`
- `restore [--slot <name>]`
- `load --file-path <path> [--allow-large] [--verify]`

The action may be positional or supplied with `--action`, but conflicting values are rejected.

## MCP schema
- Tool name: `clipboard`
- Required parameter: `action` with `get | set | clear | save | restore | load`.
- Optional parameters: `text`, `filePath`, `imagePath`, `dataBase64`, `uti`, `prefer`, `outputPath`, `slot`, `alsoText`, and `allowLarge`.
- Results use normal MCP text responses plus metadata such as `uti`, `size`, `textPreview`, `filePath`, and `slot` when available.

The MCP surface does not expose the CLI-only `--verify` readback option. `load` is an alias for setting data from `filePath` or `imagePath`.

## Implementation
- `ClipboardService` wraps `NSPasteboard`, applies the size limit, and owns slot save/restore.
- `ClipboardCommand` maps CLI flags to `ClipboardWriteRequest` and emits text or structured JSON.
- `ClipboardTool` maps MCP arguments to the same request and service.
- `PasteCommand` and `PasteTool` preserve and restore the current clipboard around Cmd+V when a payload is supplied.

## Tests and fixtures
- Service coverage lives with `PeekabooAutomationKit` clipboard tests.
- CLI coverage lives in `Apps/CLI/Tests`.
- `docs/testing/fixtures/clipboard-smoke.peekaboo.json` exercises the scripted command flow.
