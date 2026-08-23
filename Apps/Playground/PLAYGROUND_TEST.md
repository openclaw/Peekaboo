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

Choose the canonical window ID from `window list`, then observe that exact
window without activating it:

```bash
WINDOW_ID=12345
"$PB" see \
  --app "$PLAYGROUND" \
  --window-id "$WINDOW_ID" \
  --annotate \
  --path /tmp/peekaboo-playground-see.png \
  --json
```

Copy the returned `snapshot_id` and element ID into one background mutation.
For example, the Click Fixture exposes `single-click-button`:

```bash
SNAPSHOT_ID=replace-with-fresh-snapshot-id
ELEMENT_ID=replace-with-returned-element-id

"$PB" click \
  --window-id "$WINDOW_ID" \
  --snapshot "$SNAPSHOT_ID" \
  --on "$ELEMENT_ID" \
  --json
```

For text input, observe the exact Text Fixture, click its
`basic-text-field` element in the background, observe again to capture the
focused-element receipt, then type. Observe once more before sending Return:

```bash
"$PB" type "Peekaboo v4 background text" --snapshot "$SNAPSHOT_ID" --clear --json
"$PB" press Return --snapshot "$NEXT_SNAPSHOT_ID" --json
```

For the Scroll Fixture, use the fresh `vertical-scroll` element rather than a
targetless wheel event:

```bash
"$PB" scroll \
  --direction down \
  --amount 2 \
  --on "$ELEMENT_ID" \
  --snapshot "$SNAPSHOT_ID" \
  --json
```

Verify each effect with a new `see` and the PID-scoped Playground OSLog oracle:

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
