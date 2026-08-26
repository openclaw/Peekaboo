---
summary: 'Capture annotated UI maps with peekaboo see'
read_when:
  - 'Collecting UI element IDs for automation'
  - 'Troubleshooting click/type targeting'
---

# `peekaboo see`

`peekaboo see` captures the current macOS UI, extracts accessibility metadata, and (optionally) saves annotated screenshots. CLI and agent flows rely on these UI maps to find fresh element IDs, bounds, labels, and snapshot IDs.

Observation is read-only with respect to focus: targeting a background app does not activate it or move its windows.
With implicit host discovery and the standard daemon path, `see` prefers the current CLI build's deterministic
build-scoped daemon and may auto-start it before considering a healthy Peekaboo.app host. This applies to pixel and
AX-tree-only forms because their snapshots and capability decisions are host-memory state. An explicit
`--bridge-socket`, a custom daemon socket, or `--no-remote` remains authoritative.

Every reusable snapshot is identified by a producer-generated reference with the exact form `ps1_` followed by 32
lowercase ASCII hexadecimal digits, for example `ps1_0123456789abcdef0123456789abcdef`. The 32-digit suffix contains
128 random bits. The selected local or Bridge producer reserves that reference before storing detection results or
screenshots; later store operations can update only a reference that producer already owns and cannot create one.

A later command that supplies a concrete reference finds its unique live authenticated producer before applying the
normal daemon/app host preferences. Explicit routing remains a hard boundary: `--bridge-socket` probes only that host,
and `--no-remote` checks only the local process. Either form refuses before action when its selected host does not own
the reference. Legacy timestamp IDs are never accepted as action references; [clean](clean.md) recognizes only their
strict on-disk shape for cache removal.

```bash
# Capture frontmost window, print JSON, and save an annotated PNG
peekaboo see --json --annotate --path /tmp/see.png

# Target a specific app or window title
peekaboo see --app "Google Chrome" --window-title "Login" --json --path /tmp/chrome-login.png

# Crop one exact window without activating it
peekaboo see --window-id 12345 --roi 100,80,500,300 --json --path /tmp/window-roi.png

# Add host-local Vision text when an app exposes a sparse or incomplete AX tree
peekaboo see --app Calendar --window-id 12345 --ocr --json --path /tmp/calendar.png
```

## When to use

- Before element-targeted commands such as `click` or `action` so you have fresh IDs, or before `type` so you have
  a fresh target snapshot.
- When debugging automation failures—`--json` includes raw bounds, labels, and snapshot IDs.
- To snapshot UI regressions (pass `--annotate` + `--path`).

## Key options

| Flag | Description |
| --- | --- |
| `--app`, `--window-title`, `--pid` | Limit capture to a known app/window/process. Use either `--app` or `--pid`; title requires one of them. |
| `--window-id <id>` | Observe one exact WindowServer window. Pair it with `--app` or `--pid` to require that owner. Use at most one of `--window-id`, `--window-title`, or `--window-index`. |
| `--roi x,y,width,height` | Crop an exact `--window-id` in window-local logical points. Produces a fresh snapshot with element detection; it cannot be combined with `--no-elements`, `--no-screenshot`, or `--path -`. |
| `--mode screen|window|frontmost|multi|area` | Override the target picker. `multi` captures every screen; `area` uses `--region`. |
| `--region x,y,width,height` | Capture a rectangular region (`area` mode is inferred). |
| `--format png|jpg` / `--retina` | Select the image encoding and native display scale. |
| `--capture-engine auto|modern|sckit|classic|cg` | Select the engine for this request on the chosen Bridge host. Explicit remote modern/classic selection requires `desktopObservationCaptureEngine`; every transported engine also requires the current `screenCaptureKitProcessOwnership` policy. Live pre-lease hosts/processes are refused during upgrades instead of creating an unrecorded second owner. `--no-remote --capture-engine modern` requests caller-local process-lifetime SCK ownership and refuses immediately if another Peekaboo process owns it; retry remotely, stop that exact owner generation, or explicitly choose classic. An explicit `--bridge-socket` never reroutes and must identify that exact owner for modern capture. |
| `--no-elements` | Skip element detection for the cheapest pixel path. An exact `--window-id` capture still returns an explicit-reference-only `snapshot_id` with a coordinate receipt for background clicks; it never replaces an earlier element map in implicit latest lookup. Remote receipt publication requires Bridge protocol 1.26 and fails with host-upgrade guidance before capture on older hosts. Ordinary screen, area, frontmost, multi, and app/PID-only pixel captures stay backward-compatible and do not return a receipt. |
| `--ocr` | Add Apple Vision text recognized on the selected runtime host to the AX element map. Requires screenshot-backed element detection and cannot be combined with `--no-elements`, `--no-screenshot`, `--path -`, `area`, or `multi`. |
| `--tree` | Print the accessibility text tree. For an explicit WindowServer ID with no matching AX window, tree-only read-only observation may return application-scoped partial semantics instead of relabeling another window as the requested target. |
| `--no-screenshot` | Skip pixel capture; requires `--tree` and rejects `--capture-engine` because no backend runs. Ambient engine configuration is ignored so it cannot reroute this AX-only form. Element IDs and a snapshot publish only after pinning the exact process generation, window, and bounds; target drift or a missing receipt fails before publication. |
| `--annotate` | Overlay element bounds/IDs on the output image. |
| `--path <file>` / `--save` / `--output` / `-o` | Save the screenshot/annotation to disk. Pixel-only `--no-elements` captures otherwise use the configured default save directory; pass `-` for raw screenshot bytes on stdout. |
| `--json` | Emit structured metadata (recommended for scripting). |
| `--menubar` | Capture menu bar popovers via window list + OCR (useful for status-item settings panels). When `--app` is set, the app name is used as an OCR hint for popover selection. |
| `--timeout <duration>` | Increase overall timeout for large/complex windows (defaults to `20s`, or `60s` with `--analyze`; bare values are milliseconds). |
| `--web-focus` | Opt into an `AXPress` retry on the target `AXWebArea` when a sparse Chromium/Tauri tree hides its content. This can change keyboard focus. |
| `--no-web-focus` | Deprecated compatibility flag. Web focus is already disabled by default. |
| `--depth <n>` | Override AX traversal depth (`PEEKABOO_AX_MAX_DEPTH` fallback, default 12). |
| `--max-elements <n>` | Override maximum collected AX elements (`PEEKABOO_AX_MAX_ELEMENTS` fallback, default 1000). |
| `--max-children <n>` | Override maximum AX children visited per node (`PEEKABOO_AX_MAX_CHILDREN` fallback, default 250). |

Note: `--app menubar` captures only the menu bar strip; `--menubar` attempts to find the active popover and OCR its text.

`--ocr` is additive: Accessibility controls remain the authoritative actionable elements, while Vision text is
returned as `staticText` with global logical bounds and confidence. OCR rows are marked non-actionable and are
refused as element targets; use an explicit exact-window coordinate plus the returned snapshot/reference receipt
when a deliberate pixel click is required. Recognition runs locally on the selected macOS runtime host and does not
use an AI provider, upload pixels, or activate the target app. Explicit remote `--ocr` requires a current Bridge host
advertising `desktopObservationOCR`; older hosts are refused before the new observation mode is sent. Update and
relaunch that host, or pass `--no-remote` to explicitly run Vision OCR in the caller process. The existing `--menubar`
preferred-OCR path retains its legacy Bridge contract. Incomplete AX warnings remain in the successful result so OCR
text never turns missing Accessibility evidence into a false completeness claim.

For agent and automation runs, pass `--path` to a known temporary file when using `see` so capture artifacts land at one exact caller-owned path. Use `peekaboo see --tree --no-screenshot --json` when you need AX metadata without a screenshot artifact.

Passive background observations retry one resolve-and-capture transaction when the target's exact receipt changes during capture, then fail closed if it changes again. Foreground capture, explicit web-focus fallback, and menu-opening observations never retry because they can mutate visible desktop state.

Pixel-only `see --no-elements` captures without `--path` write a generated file beneath `PEEKABOO_DEFAULT_SAVE_PATH`, `defaults.savePath`, or the built-in `~/Desktop` default, in that order. Generated names retain a readable timestamp and include a unique token so concurrent callers do not share a path. This also applies with `--json`; `data.files[].path` reports the saved file. Ordinary element-producing `--json` observations without `--path` instead retain the raw image only in managed snapshot storage and return empty `screenshot_raw` and `screenshot_annotated` fields.

## Exact-window ROI capture

`--roi` is a stateless output crop, not persistent window zoom. Peekaboo first resolves and generation-pins one exact WindowServer window, captures and inspects that full window, then emits only the requested rectangle. The request fails if the window moves, resizes, changes owner, is recycled, or the rectangle extends outside the captured window. Pixel output is limited to 8192 pixels per edge and 64 megapixels.

Remote ROI requires Bridge protocol 1.21 with enabled observation and atomic snapshot publication and is rejected before dispatch against an older or restricted host. Returned files and snapshots remain quarantined or unpublished until the client verifies both the exact-window/viewport receipt and every raster's real cropped pixel dimensions. The host commits the snapshot raster, element map, and optional annotation as one transaction. If a validated snapshot is saved but a caller-visible file cannot be installed afterward, the observation remains successful with a warning and omits the unavailable file paths; the independently managed snapshot stays usable. Ordinary full-window `see` remains compatible with older desktop-observation hosts.

Producer-bound references use an independently negotiated Bridge 1.34 client/host capability. A current client does
not infer support from the `1.34` version number alone: an older 1.34 host that cannot advertise producer ownership is
refused before a snapshot is published. The separate Bridge 1.34 targeted Accessibility-value delivery capability
controls click behavior and does not grant snapshot ownership.

ROI coordinates are `x,y,width,height` in top-left-origin, window-local logical points. `--retina` changes the delivered pixel density, not that coordinate system. Pixel alignment can expand a fractional logical rectangle by less than one source pixel; JSON reports both the requested and delivered rectangles.

ROI JSON adds `coordinate_context.viewport`:

- `source_logical_bounds` is the full exact-window frame used for freshness and later dispatch validation.
- `requested_window_relative_bounds` is the caller's window-local rectangle.
- `delivered_window_relative_bounds` is the pixel-aligned rectangle actually emitted.
- `logical_bounds` maps the delivered raster into global logical coordinates.
- `source_image_size` is the uncropped source raster size.

Returned `ui_elements[].bounds` are clipped and translated into ROI-local logical coordinates for presentation. The snapshot retains their global action coordinates, so copy element IDs into element-targeted commands such as `click` and `action` rather than replaying the displayed bounds. `type` does not accept an element ID; focus the field with a background `click`, run `see` again, then type with the new snapshot. For coordinate work, use `coordinate_context.logical_bounds` to convert ROI pixels to global points and pass `--global`, or prefer the MCP `image_pixels`/`normalized` mapping described in [MCP](../MCP.md#exact-window-roi).

## Optional web focus fallback

Modern browsers sometimes keep keyboard focus in the omnibox, which means embedded forms never expose their `AXTextField` nodes to accessibility clients. Peekaboo does not alter focus during ordinary observation. If a browser-native AX inspection is required and DOM-based browser automation is unavailable, pass `--web-focus` (or MCP `web_focus: true`) to enable this retry:

1. `peekaboo see` performs a normal accessibility traversal.
2. If **zero** text fields are detected and web focus was explicitly enabled, the command locates the dominant `AXWebArea` (or equivalent) inside the target window and performs `AXPress`.
3. The traversal runs **one more time**. If the web view exposes its inputs after gaining focus, they now appear in the JSON output.

This fallback only runs inside the resolved window (it won’t hop between windows) and logs a debug entry when it fires. Prefer the `browser` tool for Chrome page content because its DOM/accessibility inspection does not need to focus the macOS window.

## JSON output primer

When `--json` is supplied, the CLI prints:

- `snapshot_id` – producer-bound `ps1_` reference for subsequent `click --snapshot …` and `type --snapshot …`.
- `semantic_scope`, `snapshot_reusable`, and `mutation_targeting_available` – authority for the returned semantics. `application_partial` always carries `snapshot_id: null`, an empty `ui_map`, both authority booleans `false`, `interactable_count: 0`, and no actionable/value-settable element claims; its elements are read-only context from the exact window's attested process, not evidence for the requested exact window.
- `ui_map` – path to the persisted snapshot file (`~/.peekaboo/snapshots/<id>/snapshot.json`).
- `ui_elements` – flattened AX nodes with honest `is_actionable` and optional `is_value_settable` capability metadata.
- `coordinate_context` – capture-owned raster mapping. ROI results include the full-window and cropped viewport rectangles described above.
- `interactable_count`, `element_count`, `capture_mode`, and performance metadata for debugging.
- Each `ui_elements[n]` entry mirrors the raw AX metadata we capture—semantic `role`, raw `ax_role`, `title`, `label`, scalar `value`, **`description`**, `role_description`, `help`, `identifier`, known enabled/selected state, value-settable capability, and the keyboard shortcut if one exists. The persisted `ui_map` keeps the same fields for follow-up tools. That makes controls whose name lives only in `AXDescription`, including Chrome toolbar icons and unlabeled sliders, searchable without relying on coordinates.
- GLM vision model analysis responses are converted from the model's 0-1000 bounding box space into delivered screenshot pixels before they are printed. Screenshot pixels are not CLI `click --at` coordinates: map them through `coordinate_context` to global logical points before using `--global`, or use the MCP `image_pixels`/`normalized` coordinate mapping.

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
- If a concrete snapshot reports no unique live host affinity, keep the producing host running or capture again. Do
  not rewrite the reference, switch to a legacy timestamp ID, or force a different Bridge socket: explicit sockets
  and `--no-remote` intentionally refuse references they do not own.
- If JSON/text output reports an AX time deadline, rerun with a longer `--timeout` or a narrower exact-window target. Increase `--depth`, `--max-elements`, or `--max-children` only when the corresponding structural cap is reported. A tree-only inspection that reaches a cap before finding any element exits nonzero instead of publishing an unusable empty snapshot; useful partial evidence remains successful and explicitly truncated.
- `ACCESSIBILITY_INCOMPLETE` means the exact target exists but an AX-only or combined screenshot+AX observation returned no usable Accessibility elements. This includes legacy Bridge responses that omit the incomplete-read marker: an empty exact-window map is not clean success. Combined failure preserves a valid raster at an explicitly requested `--path` but does not publish the unusable element snapshot. A read-only `--tree --no-screenshot` request can instead return nonempty `application_partial` semantics when the exact WindowServer window still belongs to the requested process but has no AX-window counterpart. That result is explicitly incomplete, has no reusable snapshot or mutation authority, and never claims its elements came from the requested window. Retry the same exact observation once for fresh evidence; if it persists, use `--no-elements` for explicit screenshot-only evidence or add OCR. This code never means the element is absent and never substitutes for `TIMEOUT`; useful nonempty partial evidence remains successful with its warning.
- Missing text fields after an explicit `--web-focus` retry usually means the page is shielding its inputs from AX entirely. For Chrome targets, use the `browser` tool (`status` → `connect` → `snapshot`/`fill`/`click`) after enabling Chrome remote debugging; otherwise rely on image-based hit tests.
- For repeatable local tests, run `pnpm run test:automation:local`; the runner builds the real external CLI, exports its exact `PEEKABOO_CLI_PATH`, launches one owned Playground instance with current v4 syntax, and cleans it up by process-generation receipt. Set `PEEKABOO_PLAYGROUND_APP=/absolute/path/Playground.app` when LaunchServices cannot resolve the signed fixture by name.
- Rapid repeated `see` calls for the same window reuse a short-lived AX cache (~1.5s); wait a beat if you need a fully fresh traversal.

## Smart label placement (`--annotate`)
- The `SmartLabelPlacer` generates external label candidates (above/below/sides/corners) for each element, filters out overlaps/out-of-bounds positions, then scores remaining spots via `AcceleratedTextDetector.scoreRegionForLabelPlacement` to prefer calm regions. Internal placements are a last-resort fallback.
- Edge-aware scoring samples a padded rectangle (6 px halo, clamped to the image) so the chosen region stays clean once text is drawn; above/below placements get slight bonuses to reduce sideways clutter.
- Preferred orientations nudge horizontally tight elements toward vertical labels when scores tie.
- Tests: `Apps/CLI/Tests/CoreCLITests/SmartLabelPlacerTests.swift` (run with `swift test --package-path Apps/CLI --filter SmartLabelPlacerTests`).
- Manual validation: `peekaboo see --app Playground --annotate --path /tmp/see.png --json` then inspect the annotated PNG; if labels cover dense UI, capture the repro and adjust padding/scoring before committing.
