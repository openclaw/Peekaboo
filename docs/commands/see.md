---
summary: 'Capture annotated UI maps with peekaboo see'
read_when:
  - 'Collecting UI element IDs for automation'
  - 'Troubleshooting click/type targeting'
---

# `peekaboo see`

`peekaboo see` captures the current macOS UI, extracts accessibility metadata, and (optionally) saves annotated screenshots. CLI and agent flows rely on these UI maps to find fresh element IDs, bounds, labels, and snapshot IDs.

```bash
# Capture frontmost window, print JSON, and save an annotated PNG
peekaboo see --json --annotate --path /tmp/see.png

# Target a specific app or window title
peekaboo see --app "Google Chrome" --window-title "Login" --json --path /tmp/chrome-login.png
```

## When to use

- Before issuing `click`/`type` commands so you have fresh element IDs.
- When debugging automation failures—`--json` includes raw bounds, labels, and snapshot IDs.
- To snapshot UI regressions (pass `--annotate` + `--path`).

## Key options

| Flag | Description |
| --- | --- |
| `--app`, `--window-title`, `--pid` | Limit capture to a known app/window/process. |
| `--mode screen|window|frontmost|multi` | Override the auto target picker. `area` is intentionally rejected because `see` does not expose rectangle coordinates; use `peekaboo image --mode area --region x,y,width,height` for raw region screenshots. |
| `--annotate` | Overlay element bounds/IDs on the output image. |
| `--path <file>` | Save the screenshot/annotation to disk. |
| `--json` | Emit structured metadata (recommended for scripting). |
| `--menubar` | Capture menu bar popovers via window list + OCR (useful for status-item settings panels). When `--app` is set, the app name is used as an OCR hint for popover selection. |
| `--timeout-seconds <seconds>` | Increase overall timeout for large/complex windows (defaults to 20s, or 60s with `--analyze`). |
| `--no-web-focus` | Skip the automatic web-content focus retry (useful if the page reacts badly to synthetic clicks). |
| `--max-depth <n>` | Override AX traversal depth (`PEEKABOO_AX_MAX_DEPTH` fallback, default 12). |
| `--max-elements <n>` | Override maximum collected AX elements (`PEEKABOO_AX_MAX_ELEMENTS` fallback, default 1000). |
| `--max-children <n>` | Override maximum AX children visited per node (`PEEKABOO_AX_MAX_CHILDREN` fallback, default 250). |

Note: `--app menubar` captures only the menu bar strip; `--menubar` attempts to find the active popover and OCR its text.

For agent and automation runs, pass `--path` to a known temporary file when using `see` so capture artifacts land where expected. Use `peekaboo inspect-ui --json` when you need AX metadata and no screenshot artifact.

## Automatic web focus fallback (Nov 2025)

Modern browsers sometimes keep keyboard focus in the omnibox, which means embedded login forms (Instagram, Facebook, etc.) never expose their `AXTextField` nodes to accessibility clients. Starting November 2025:

1. `peekaboo see` performs a normal accessibility traversal.
2. If **zero** text fields are detected, the command locates the dominant `AXWebArea` (or equivalent) inside the target window and performs a synthetic `AXPress`.
3. The traversal runs **one more time**. If the web view exposes its inputs after gaining focus, they now appear in the JSON output.

This fallback only runs inside the resolved window (it won’t hop between windows) and logs a debug entry when it fires. If you need to disable it for a specialized flow, run `see` inside a different window or manually focus the desired element first.

## JSON output primer

When `--json` is supplied, the CLI prints:

- `snapshot_id` – reference for subsequent `click --snapshot …` and `type --snapshot …`.
- `ui_map` – path to the persisted snapshot file (`~/.peekaboo/snapshots/<id>/snapshot.json`).
- `ui_elements` – flattened list of actionable nodes (buttons, text fields, links, etc.).
- `interactable_count`, `element_count`, `capture_mode`, and performance metadata for debugging.
- Each `ui_elements[n]` entry now mirrors the raw AX metadata we capture—`title`, `label`, **`description`**, `role_description`, `help`, `identifier`, and the keyboard shortcut if one exists. That makes Chrome toolbar icons (which frequently hide their name in `AXDescription`) searchable without relying on coordinates.
- GLM vision model analysis responses are converted from the model's 0-1000 bounding box coordinate space into screenshot pixel coordinates before they are printed, so follow-up `click --coords` calls can use returned box centers directly.

Use `jq` or any JSON parser to find elements:

```bash
peekaboo see --app "Safari" --json --path /tmp/safari-see.png \
  | jq '.data.ui_elements[] | select(.label | test("Sign in"; "i"))'

# Toolbar buttons that only expose AXDescription:
peekaboo see --app "Google Chrome" --json --path /tmp/chrome-see.png \
  | jq '.data.ui_elements[] | select((.description // "") | test("Wingman"; "i"))'
```

## Troubleshooting tips

- If the CLI reports **blind typing**, pass an explicit `--app`, `--pid`, `--window-id`, or fresh `--snapshot` so `type` can resolve a background target process, or add `--foreground` when the target app requires focused keyboard input.
- If JSON/text output reports `AX tree truncated`, rerun with larger `--max-depth`, `--max-elements`, or `--max-children` values. For repeated captures, export the matching `PEEKABOO_AX_MAX_*` environment variable before launching Peekaboo.
- Missing text fields after the fallback usually means the page is shielding its inputs from AX entirely. For Chrome targets, use the `browser` tool (`status` → `connect` → `snapshot`/`fill`/`click`) after enabling Chrome remote debugging; otherwise rely on image-based hit tests.
- For repeatable local tests, run `RUN_LOCAL_TESTS=true swift test --filter SeeCommandPlaygroundTests` to exercise the Playground fixtures mentioned in `docs/research/interaction-debugging.md`.
- Rapid repeated `see` calls for the same window reuse a short-lived AX cache (~1.5s); wait a beat if you need a fully fresh traversal.

## Smart label placement (`--annotate`)
- The `SmartLabelPlacer` generates external label candidates (above/below/sides/corners) for each element, filters out overlaps/out-of-bounds positions, then scores remaining spots via `AcceleratedTextDetector.scoreRegionForLabelPlacement` to prefer calm regions. Internal placements are a last-resort fallback.
- Edge-aware scoring samples a padded rectangle (6 px halo, clamped to the image) so the chosen region stays clean once text is drawn; above/below placements get slight bonuses to reduce sideways clutter.
- Preferred orientations nudge horizontally tight elements toward vertical labels when scores tie.
- Tests: `Apps/CLI/Tests/CoreCLITests/SmartLabelPlacerTests.swift` (run with `swift test --package-path Apps/CLI --filter SmartLabelPlacerTests`).
- Manual validation: `peekaboo see --app Playground --annotate --path /tmp/see.png --json` then inspect the annotated PNG; if labels cover dense UI, capture the repro and adjust padding/scoring before committing.
