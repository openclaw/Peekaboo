---
summary: 'Capture raw screenshots or windows via peekaboo image'
read_when:
  - 'needing unannotated captures or multi-display exports'
  - 'pairing screenshots with inline AI analysis'
---

# `peekaboo image`

`peekaboo image` is the low-level capture command that produces raw PNG/JPG files for windows, screens, menu bar regions, or the current frontmost app. It shares the same snapshot cache as `see`, but skips annotation and element extraction so you can grab pixels quickly or feed them into the built-in AI analyzer.

If you need a longer-running, change-aware capture (idle/active FPS, contact sheet, PNG or optional MP4), use `peekaboo capture live` (or `capture video` to ingest an existing file).

## Common tasks
- Export every connected display (or a single `--screen-index`) before filing UX bugs.
- Pinpoint a specific window via `--app`, `--pid`, `--window-title`, or `--window-index` without forcing the `see` pipeline.
- Run inline audits by passing `--analyze "prompt"`, which uploads the capture to the active AI provider and prints the response next to the file list.

## Key options
| Flag | Description |
| --- | --- |
| `--app`, `--pid`, `--window-title`, `--window-index` | Resolve a window target; accepts bundle IDs, `PID:1234`, or friendly names. |
| `--window-id <id>` | Capture one exact WindowServer window. Pair it with `--app` or `--pid` to require that owner. It cannot be combined with `--window-title` or `--window-index`. |
| `--mode screen|window|frontmost|multi|area` | Override the auto mode picker (defaults to `window` when a target is given, `area` when `--region` is set, otherwise `frontmost`). `multi` grabs every window for the target app or, if no app is set, every display. |
| `--screen-index <n>` | Limit screen captures to a single 0-based display. |
| `--region x,y,width,height` | Capture an explicit desktop region when using `--mode area`; coordinates are global display points. |
| `--path <file>` | Force the output path; if omitted, filenames land in the CWD using sanitized app/window names plus an ISO8601 timestamp. |
| `--retina` | Store captures at native Retina scale (2x on HiDPI). Omit for the default 1x logical resolution to save space and speed. |
| `--format png|jpg` | Emit PNG (default) or re-encode to JPEG at ~92% quality. |
| `--capture-focus background|foreground|auto` | `background` is the default and never activates the target. `foreground` explicitly brings the target forward. `auto` remains as a legacy focus-if-needed mode. |
| `--analyze "prompt"` | Send the saved file to the configured AI provider and include `{provider,model,text}` in the output payload. |

## Implementation notes
- Special `--app menubar` captures just the status-bar strip, while `--app frontmost` triggers a targeted foreground grab without needing bundle info.
- Window, screen, menu bar, and area captures build desktop observation requests so target resolution, scale metadata, diagnostics, and file output follow the shared pipeline.
- When the on-demand daemon supports Bridge protocol 1.5, the desktop observation request runs inside the warm daemon and the CLI receives file paths plus metadata instead of large screenshot bytes.
- In `auto` engine mode, screenshots try the CoreGraphics path first for lower one-shot latency and fall back to ScreenCaptureKit when needed. Use `--capture-engine modern` for explicit ScreenCaptureKit checks.
- Multi-screen runs enumerate `services.screens.listScreens()` and save each display sequentially; filenames include the display index (`screen0`, `screen1`, …) so automated diffing scripts can glob reliably.
- Saved metadata (label, bundle, window index) is embedded in the `SavedFile` records that print to stdout/JSON, which means follow-up tooling can decide which attachment represents which surface without parsing filenames.
- Area captures use `--region x,y,width,height` and are clamped/validated by the shared capture service against the containing display.

## Examples
```bash
# Capture the Safari window titled "Release Notes" and save a JPEG
peekaboo image --app Safari --window-title "Release Notes" --format jpg --path /tmp/safari.jpg

# Dump every display and run a quick AI summarization
peekaboo image --mode screen --analyze "Summarize the key UI differences between the monitors"

# Snapshot only the menu bar icons without stealing focus from the active Space (background is the default)
peekaboo image --app menubar

# Capture a fixed desktop region in global display coordinates
peekaboo image --mode area --region 100,120,640,360 --path /tmp/region.png
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
