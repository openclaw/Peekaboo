---
summary: 'Design for unified clipboard tool (CLI + MCP) covering text, images, files, and raw data'
read_when:
  - 'planning or implementing the peekaboo clipboard command/tool'
  - 'debugging clipboard read/write behaviors or size limits'
---

# Clipboard Tool Design

Goal: add a single `clipboard` tool (CLI + MCP) that handles text, images, files, and raw data while fitting Peekaboo’s existing one-tool-per-domain pattern.

## User-facing behaviors
- Actions: `get`, `set`, `clear`, `save`, `restore`, `load`.
- Text: read/write UTF‑8 plain text; optional `--also-text` when setting binary to supply a human-readable companion.
- Images: accept PNG/JPEG/TIFF input; write PNG+TIFF representations to the pasteboard; `get` can return a file path.
- Files: accept a file path; write as `public.file-url`.
- Raw: accept `--data-base64` plus `--uti` to write arbitrary pasteboard types.
- Slots: `save`/`restore` snapshot the current pasteboard (default slot `0`; allow named slots).
- Size guard: warn and block writes over 10 MB unless `--allow-large` is set; count every representation plus any `--also-text` companion text.
- Safety: never set Trimmy’s marker type; only requested UTIs.

## CLI syntax (`peekaboo clipboard …`)
- `get [--prefer <uti>] [--output <path|->] [--json] [--allow-base64]`
  - `--output -` streams binary to stdout; otherwise writes to file and returns a preview in JSON/text.
- `set (--text <string> | --file <path> | --image <path> | --data-base64 <b64> --uti <uti>) [--also-text <string>] [--allow-large]`
- `clear`
- `save [--slot <name|int>]`
- `restore [--slot <name|int>]`
- `load --file <path> [--json]` (infers UTI from extension: png/jpg/jpeg/tif/tiff/txt/rtf/html/pdf; falls back to raw with inferred UTI)
- Common flags: `--verbose`, `--timeout` (for symmetry with other commands).

## MCP schema (single tool)
- Tool name: `clipboard`
- Params:
  - `action: "get" | "set" | "clear" | "save" | "restore" | "load"`
  - `text?: string`
  - `filePath?: string`
  - `imagePath?: string` (alias of filePath; kept for ergonomics)
  - `dataBase64?: string`
  - `uti?: string`
  - `prefer?: string`          // UTI hint for get
  - `outputPath?: string`      // where to write binary on get/load
  - `slot?: string`            // default "0"
  - `alsoText?: string`
  - `allowLarge?: boolean`
- Result:
  - `ok: boolean`
  - `action: string`
  - `uti?: string`
  - `size?: number`
  - `textPreview?: string`     // first ~80 chars when text present
  - `filePath?: string`        // path we wrote/returned
  - `slot?: string`
  - `error?: string`
- Legacy aliases: keep `copy_to_clipboard` and `paste_from_clipboard` ToolTypes as thin wrappers that call `clipboard` internally (set, or get+press).

## Formatting / agent strings
- `[clip] Reading clipboard (pref=public.png)…`
- `[clip] Set clipboard text (42 chars)`
- `[clip] Set clipboard image (png, 120 KB)`
- `[clip] Cleared`
- `[clip] Saved slot "0"`
- `[clip] Restored slot "0"`
- Error: `⚠️ Clipboard write blocked: size 12.3 MB exceeds 10 MB (use --allow-large)`

## Implementation plan
- Add `ClipboardService` in `PeekabooAutomation` that wraps `NSPasteboard` with helpers:
  - `read(prefer:)` -> typed result (text/string or temp file path for binary)
  - `write(text|data|fileURL|image)` with multi-representation support
  - `clear()`, `save(slot)`, `restore(slot)`
  - Size guard and friendly errors
- CLI:
  - New commander command `ClipboardCommand` -> calls `ClipboardService`
  - Binary outputs: write to `--output` or stdout; JSON includes preview, size, UTI
- MCP:
  - Register a single `clipboard` tool in `ToolRegistry`
  - Param/Result schema per above; add formatter entries to `SystemToolFormatter`
  - Wire legacy `copy_to_clipboard` / `paste_from_clipboard` to the new tool to avoid breaking agents.
- Tests:
  - `PeekabooAutomationTests/ClipboardServiceTests` covering text round-trip, image round-trip, file URL, raw UTI, size guard, slots.
  - Fixtures: `docs/testing/fixtures/clipboard-text.peekaboo.json`, `clipboard-image.peekaboo.json`.
- Docs:
  - Add command doc to `docs/commands/clipboard.md` (flags table + examples).
  - Cross-link from `cli-command-reference.md` and MCP docs once implemented.

## Open questions
- Default image encoding on `set` of JPEG input: convert to PNG+TIFF or preserve JPEG? Proposed: always add PNG+TIFF, preserve original UTI if provided.
- Slot retention lifetime: in-memory only (cleared on app quit) to avoid disk writes.
