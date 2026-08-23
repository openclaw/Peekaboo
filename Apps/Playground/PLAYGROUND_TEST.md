# Playground testing with Peekaboo v4

This is the current Peekaboo v4 workflow. It replaces the pre-v4 append-only test
log that previously lived here. Those dated results remain available in Git
history, but their commands are historical evidence and must not be copied into
new runs.

For a certifying run, use the source-controlled
[background computer-use harness](../../docs/testing/background-computer-use.md).
The manual smoke below is useful while developing a fixture or command, but it
does not replace that harness.

## Safety contract

- Background delivery is the default. Omit `--foreground` unless the test is
  explicitly exercising shared focus, keyboard, wheel, or pointer state.
- Resolve an exact app, PID, and window before mutation. Prefer a fresh snapshot
  and element ID over a query, and prefer either over coordinates.
- Re-observe after every mutation. Never replay an indeterminate result or a
  snapshot that Peekaboo reports as stale.
- Treat the physical cursor as observational: the user may move it at any time.
  A background test must not require its position to remain stable.
- Use Peekaboo's native app, window, menu, dialog, and Accessibility commands.
  The Playground workflow does not use AppleScript or JXA.

Commands that intentionally move the shared cursor, including `move` and the
current `drag` implementation, require `--foreground` and belong in a separate,
idle-desktop test. They are not part of the background smoke below.

## Prepare signed binaries

From the repository root, build a signed CLI and the team-signed Debug
Playground app:

```bash
pnpm run build:swift

xcodebuild \
  -workspace Apps/Peekaboo.xcworkspace \
  -scheme Playground \
  -configuration Debug \
  -derivedDataPath /tmp/peekaboo-playground-derived \
  build

codesign --verify --deep --strict \
  /tmp/peekaboo-playground-derived/Build/Products/Debug/Playground.app
```

Do not launch an unsigned or ad-hoc Peekaboo build against saved TCC state. The
Debug Playground target is configured for the OpenClaw Foundation development
team. Use the installed signed Peekaboo app as the Bridge host when it owns the
required permissions:

```bash
open -gj -a Peekaboo
open -gj /tmp/peekaboo-playground-derived/Build/Products/Debug/Playground.app

PB=./peekaboo
"$PB" --version
"$PB" bridge status --verbose --json
"$PB" permissions status --all-sources --json
```

Screen Recording and Accessibility must be granted on the selected runtime
host. Background keyboard and routed pointer delivery additionally need Event
Synthesizing. Peekaboo does not need Apple Events Automation permission.

## Run a background smoke

The Debug bundle identifier is `boo.peekaboo.playground.debug`. Open fixture
windows through the native application menu, which remains background-capable:

```bash
PB=./peekaboo
PLAYGROUND=boo.peekaboo.playground.debug

"$PB" app list --include-hidden --include-background --json
"$PB" menu click --app "$PLAYGROUND" --path "Fixtures > Open Click Fixture" --json
"$PB" menu click --app "$PLAYGROUND" --path "Fixtures > Open Text Fixture" --json
"$PB" menu click --app "$PLAYGROUND" --path "Fixtures > Open Scroll Fixture" --json
"$PB" window list --app "$PLAYGROUND" --json
```

Resolve exactly one Click Fixture window, observe it without activation, and
extract the opaque element ID for `single-click-button` from that same snapshot:

```bash
CLICK_WINDOW_ID=$("$PB" window list --app "$PLAYGROUND" --json | jq -er '
  [.data.windows[] | select(.window_title == "Click Fixture") | .window_id]
  | select(length == 1) | .[0]')
CLICK_SEE=$("$PB" see \
  --app "$PLAYGROUND" \
  --window-id "$CLICK_WINDOW_ID" \
  --annotate \
  --path /tmp/peekaboo-playground-see.png \
  --json)
CLICK_SNAPSHOT_ID=$(printf '%s\n' "$CLICK_SEE" | jq -er '.data.snapshot_id')
SINGLE_CLICK_ID=$(printf '%s\n' "$CLICK_SEE" | jq -er '
  [.data.ui_elements[] | select(.identifier == "single-click-button") | .id]
  | select(length == 1) | .[0]')
CLICK_COUNT_BEFORE=$(printf '%s\n' "$CLICK_SEE" | jq -er '
  [.data.ui_elements[] | select(.identifier == "single-click-count") | (.value | tonumber)]
  | select(length == 1) | .[0]')

"$PB" click \
  --window-id "$CLICK_WINDOW_ID" \
  --snapshot "$CLICK_SNAPSHOT_ID" \
  --on "$SINGLE_CLICK_ID" \
  --json
CLICK_AFTER_SEE=$("$PB" see --tree --no-screenshot \
  --app "$PLAYGROUND" --window-id "$CLICK_WINDOW_ID" --json)
CLICK_COUNT_AFTER=$(printf '%s\n' "$CLICK_AFTER_SEE" | jq -er '
  [.data.ui_elements[] | select(.identifier == "single-click-count") | (.value | tonumber)]
  | select(length == 1) | .[0]')
test "$CLICK_COUNT_AFTER" -eq "$((CLICK_COUNT_BEFORE + 1))"
```

For text input, independently resolve and observe the Text Fixture. Click the
returned `basic-text-field`, observe its focused state, type, then observe once
more before sending Return:

```bash
TEXT_WINDOW_ID=$("$PB" window list --app "$PLAYGROUND" --json | jq -er '
  [.data.windows[] | select(.window_title == "Text Fixture") | .window_id]
  | select(length == 1) | .[0]')
TEXT_SEE=$("$PB" see --app "$PLAYGROUND" --window-id "$TEXT_WINDOW_ID" --json)
TEXT_SNAPSHOT_ID=$(printf '%s\n' "$TEXT_SEE" | jq -er '.data.snapshot_id')
BASIC_TEXT_ID=$(printf '%s\n' "$TEXT_SEE" | jq -er '
  [.data.ui_elements[] | select(.identifier == "basic-text-field") | .id]
  | select(length == 1) | .[0]')

"$PB" click --window-id "$TEXT_WINDOW_ID" \
  --snapshot "$TEXT_SNAPSHOT_ID" --on "$BASIC_TEXT_ID" --json
TEXT_FOCUSED_SEE=$("$PB" see --app "$PLAYGROUND" --window-id "$TEXT_WINDOW_ID" --json)
TEXT_FOCUSED_SNAPSHOT_ID=$(printf '%s\n' "$TEXT_FOCUSED_SEE" | jq -er '.data.snapshot_id')

"$PB" type "Peekaboo v4 background text" --window-id "$TEXT_WINDOW_ID" \
  --snapshot "$TEXT_FOCUSED_SNAPSHOT_ID" --clear --json
TEXT_TYPED_SEE=$("$PB" see --app "$PLAYGROUND" --window-id "$TEXT_WINDOW_ID" --json)
TEXT_TYPED_SNAPSHOT_ID=$(printf '%s\n' "$TEXT_TYPED_SEE" | jq -er '.data.snapshot_id')
"$PB" press Return --window-id "$TEXT_WINDOW_ID" \
  --snapshot "$TEXT_TYPED_SNAPSHOT_ID" --json
```

For scrolling, independently resolve and observe the Scroll Fixture and use
its fresh `vertical-scroll` element rather than a targetless wheel event:

```bash
SCROLL_WINDOW_ID=$("$PB" window list --app "$PLAYGROUND" --json | jq -er '
  [.data.windows[] | select(.window_title == "Scroll Fixture") | .window_id]
  | select(length == 1) | .[0]')
SCROLL_SEE=$("$PB" see --app "$PLAYGROUND" --window-id "$SCROLL_WINDOW_ID" --json)
SCROLL_SNAPSHOT_ID=$(printf '%s\n' "$SCROLL_SEE" | jq -er '.data.snapshot_id')
VERTICAL_SCROLL_ID=$(printf '%s\n' "$SCROLL_SEE" | jq -er '
  [.data.ui_elements[] | select(.identifier == "vertical-scroll") | .id]
  | select(length == 1) | .[0]')
SCROLL_OFFSET_BEFORE=$(printf '%s\n' "$SCROLL_SEE" | jq -er '
  [.data.ui_elements[] | select(.identifier == "vertical-scroll-offset") | (.value | tonumber)]
  | select(length == 1) | .[0]')

"$PB" scroll \
  --direction down \
  --amount 2 \
  --window-id "$SCROLL_WINDOW_ID" \
  --on "$VERTICAL_SCROLL_ID" \
  --snapshot "$SCROLL_SNAPSHOT_ID" \
  --json
/bin/sleep 0.3
SCROLL_AFTER_SEE=$("$PB" see --tree --no-screenshot \
  --app "$PLAYGROUND" --window-id "$SCROLL_WINDOW_ID" --json)
SCROLL_OFFSET_AFTER=$(printf '%s\n' "$SCROLL_AFTER_SEE" | jq -er '
  [.data.ui_elements[] | select(.identifier == "vertical-scroll-offset") | (.value | tonumber)]
  | select(length == 1) | .[0]')
jq -en --arg before "$SCROLL_OFFSET_BEFORE" --arg after "$SCROLL_OFFSET_AFTER" \
  '($before | tonumber) != ($after | tonumber)' >/dev/null
```

The fresh exact-window reads above prove the Click and Scroll effects through
their fixture-owned semantic witnesses. Use the PID-scoped Playground OSLog
oracle as independent corroboration:

```bash
./Apps/Playground/scripts/playground-log.sh --last 10m --all --json
```

The pass condition is not merely a successful exit. The exact intended fixture
must change, the Playground log or semantic witness must corroborate the effect,
and the user's foreground app, focused window, clipboard, and unrelated windows
must remain unchanged.

## Current v4 command names

Do not translate old revisions of this file literally:

| Historical spelling | Peekaboo v4 spelling |
| --- | --- |
| `polter peekaboo -- ...` | invoke the selected `peekaboo` binary directly |
| `list windows`, `list apps`, `list screens` | `window list`, `app list`, `screen list` |
| `image` | `see --no-elements` |
| `hotkey` | `press` |
| `click --coords x,y` | `click --at x,y` |
| frontmost-app targeting | exact `--app`, `--pid`, `--window-id`, or fresh snapshot targeting |

The [command docs](../../docs/commands/README.md) and the selected binary's
`<command> --help` output are the syntax authorities. Run the deterministic
non-GUI contract check with `pnpm run test:background-certification`; run
`scripts/test-background-computer-use.sh` for the live background matrix.
