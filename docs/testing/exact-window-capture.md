---
summary: 'Local synthetic proof for exact-window classic capture extent and coordinate mapping'
read_when:
  - 'Validating popup or sheet capture geometry'
---

# Exact-window capture proof

The classic path uses `/usr/sbin/screencapture -l <id> -o -a -x`. The `-a` option excludes attached windows. The
returned PNG must match the selected WindowServer bounds at the independently resolved source scale. A larger
surface is refused, because its PNG dimensions do not establish its origin or identify a safe crop. Successful
output must also match the requested delivery scale. This check supplements the existing owner-generation,
window-identity, and bounds receipts; it does not replace them.

## Verified local reproduction (2026-09-05)

On macOS 27.0 (26A5425a), with a 2× display and OpenClaw Foundation Developer ID signatures, the installed
4.3.0 (`main/44eff916c`) CLI reproduced the mismatch for both fixture modes: selecting the 448×240 popup or sheet
returned the complete 900×700 parent image while JSON still named the child and reported its bounds with scale 1.
The patched CLI returned only the asymmetric child: 448×240 at logical 1× and 896×480 with `--retina`, with matching
JSON dimensions, child ID, and origin. Popup origin was `(213,183)`; sheet origin was `(266,300)`. The four color
regions and upright label were preserved. All capture commands exited successfully. Existing local grants were
used without permission requests; neither Chrome nor private images were involved. Artifacts remain local.

## Offline checks

From the task checkout, with its pinned submodules initialized:

```bash
pnpm run setup:swift
pnpm exec swift test --package-path Core/PeekabooAutomationKit \
  --filter 'LegacyWindowCaptureGeometryTests|LegacyCapturedRasterTests|ScreenCaptureImageScalerTests|ObservationCaptureReceiptBindingTests'
pnpm run build:cli
```

The geometry tests use generated RGBA images only. They cover a parent/union substituted for a popup, the reported
1891×1490 versus 448×240 mismatch, asymmetric pixels, negative global offsets, 1×/2× source and output, already
logical private output, failed scaling, and invalid geometry. No screen capture or GUI fixture runs in these tests.

## Parent-owned live proof

Run this section only in the already-authorized GUI session. The caller and signed CLI must already have the
necessary Screen Recording and Accessibility grants. A matching approved Developer ID identity must already sign
without prompting. Stop on any permission/signing prompt or missing grant; do not grant permissions, change
Keychain access, attach Chrome, change a Gateway, or change global configuration to make the proof run.

The fixture has a distinct bundle ID, no Keychain/authentication code, no network access, and no saved application
state. It draws a fully opaque 900×700 striped magenta parent and a fully opaque 448×240 asymmetric red/green/blue/
yellow child. It requires a display with at least 1000×800 available logical points. Keep the complete fixture
visible and stationary throughout each comparison. All artifacts stay local. Do not use original/private images.

Build in a fresh local proof directory. This script only compiles an app; it never signs or launches it:

```bash
TASK_ROOT="$(pwd)"
mkdir -p "$TASK_ROOT/build"
PROOF_DIR="$(mktemp -d "$TASK_ROOT/build/exact-window-proof.XXXXXX")"
bash scripts/build-exact-window-fixture.sh "$PROOF_DIR/ExactWindowCapture.app"
pnpm run build:cli
CLI_BIN_DIR="$(pnpm exec swift build --package-path Apps/CLI --show-bin-path)"
mkdir "$PROOF_DIR/after"
cp "$CLI_BIN_DIR/peekaboo" "$PROOF_DIR/after/peekaboo"
git diff --binary > "$PROOF_DIR/source.patch"
git ls-files --others --exclude-standard > "$PROOF_DIR/new-source-files.txt"
```

The patch does not include untracked source files: retain those listed files with the task checkout when handing
off the proof. Set `SIGN_IDENTITY` to the already-approved Developer ID name matching the permitted CLI identity,
and `BEFORE_CLI` to the existing signed 4.3.0 binary from the observed build. Do not overwrite that binary. Reuse the
repository's signing wrapper, but not its debug helper that auto-selects an identity and copies a root binary:

```bash
: "${SIGN_IDENTITY:?Set the pre-approved Developer ID identity}"
: "${BEFORE_CLI:?Set the existing signed baseline binary path}"
bash scripts/codesign-with-retry.sh --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none \
  "$PROOF_DIR/ExactWindowCapture.app"
bash scripts/codesign-with-retry.sh --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none \
  --identifier boo.peekaboo.peekaboo --entitlements Apps/CLI/Sources/Resources/peekaboo.entitlements \
  "$PROOF_DIR/after/peekaboo"
codesign --verify --strict "$PROOF_DIR/ExactWindowCapture.app"
codesign --verify --strict "$PROOF_DIR/after/peekaboo"
codesign --verify --strict "$BEFORE_CLI"
codesign -dv --verbose=4 "$PROOF_DIR/ExactWindowCapture.app" 2> "$PROOF_DIR/fixture-signature.txt"
codesign -dv --verbose=4 "$PROOF_DIR/after/peekaboo" 2> "$PROOF_DIR/after-signature.txt"
codesign -dv --verbose=4 "$BEFORE_CLI" 2> "$PROOF_DIR/before-signature.txt"
shasum -a 256 "$BEFORE_CLI" "$PROOF_DIR/after/peekaboo" > "$PROOF_DIR/binary-sha256.txt"
```

Inspect those signature records for the expected identity before launch. In a separate tracked foreground terminal
or parent-owned execution session, launch the fixture and leave it running:

```bash
"$PROOF_DIR/ExactWindowCapture.app/Contents/MacOS/ExactWindowCapture" popup "$PROOF_DIR/ready.json"
```

The fixture writes `ready.json` after showing both windows. Use that exact file in the capture terminal; no global
application/window inventory is needed. These commands capture only the fixture's explicit popup ID. `--no-remote`
keeps the request caller-local, and `--capture-engine cg` avoids claiming caller-local ScreenCaptureKit ownership:

```bash
FIXTURE_PID="$(jq -er '.pid' "$PROOF_DIR/ready.json")"
POPUP_ID="$(jq -er '.popup.window_id' "$PROOF_DIR/ready.json")"
mkdir "$PROOF_DIR/config"

capture_proof() {
  local label="$1" binary="$2"
  shift 2
  local capture_rc=0
  env PEEKABOO_CONFIG_DIR="$PROOF_DIR/config" PEEKABOO_CONFIG_DISABLE_MIGRATION=1 \
    "$binary" see --pid "$FIXTURE_PID" --window-id "$POPUP_ID" \
    --no-remote --capture-engine cg --no-elements --path "$PROOF_DIR/$label.png" --json "$@" \
    > "$PROOF_DIR/$label.json" 2> "$PROOF_DIR/$label.stderr" || capture_rc=$?
  printf '%s\n' "$capture_rc" > "$PROOF_DIR/$label.exit"
}
capture_proof before "$BEFORE_CLI"
capture_proof after "$PROOF_DIR/after/peekaboo"
capture_proof after-retina "$PROOF_DIR/after/peekaboo" --retina
```

`PEEKABOO_CONFIG_DIR` isolates configuration; normal exact-window snapshot receipts still use local
`~/.peekaboo/snapshots`. Keep those receipts intact for inspection. A geometry failure must return nonzero and must
not create the requested PNG or a new reusable snapshot. Preserve the error JSON and exit status. If the baseline
does not reproduce on this OS/fixture, record that; do not claim a live before/after reproduction.

For successful results, compare the real PNG dimensions with JSON:

```bash
cat "$PROOF_DIR/ready.json"
jq '{success, error, data: {files: .data.files, observations: .data.observations, snapshot_id: .data.snapshot_id}}' \
  "$PROOF_DIR/after.json"
sips -g pixelWidth -g pixelHeight "$PROOF_DIR/after.png"
sips -g pixelWidth -g pixelHeight "$PROOF_DIR/after-retina.png"
```

The ordinary PNG must be 448×240; the Retina PNG must be 448×240 multiplied by the fixture's `popup.backing_scale`.
`data.files[0].window_id` must equal `popup.window_id`. The observation coordinates must report that same popup's
global bounds, the actual pixel size, and scale 1 or the recorded backing scale. Inspect each entire local image:
the upper-left red tile occupies one quarter of the width and one third of the height; green is above/right, blue
below/left, yellow below/right. The popup label remains upright. Parent stripes/magenta must never fill the popup
image. A pixel `(71*s,113*s)` maps to `(popup.x+71,popup.y+113)` global logical points at output scale `s`.

Stop the fixture through its owned foreground session (Ctrl-C), then repeat in a fresh proof directory with `sheet`
instead of `popup`; record the actual sheet bounds from its new ready file. If display availability permits, repeat
on an already-configured 1× and 2× display without changing global display settings. Do not reuse stale PIDs/window
IDs. Parent capture can be checked separately using the fixture's explicit parent ID. No live proof is complete
until the parent has checked signed launch, pixels, metadata, and refusal behavior on the relevant OS.
