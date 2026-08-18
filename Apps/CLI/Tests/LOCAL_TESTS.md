# Local-Only Tests for Peekaboo

This directory contains tests that can only be run locally (not on CI) because they require:
- Screen recording permissions
- Accessibility permissions (optional)
- A graphical environment
- User interaction (for permission dialogs)

## Test Host Application

The `TestHost` directory contains a simple SwiftUI application that serves as a controlled environment for testing screenshots and window management. The test host app:

- Displays permission status
- Shows a known window with identifiable content
- Provides various test patterns for screenshot validation
- Logs test interactions

The `TestFixtures/BackgroundHotkeyProbe` package is a focused AppKit process for
the internal process-targeted hotkey transport used by typed composite operations.
Raw `press` refuses targetless and PID-only background delivery. Direct CLI exact-window/snapshot receipts and
background-only Agent/MCP explicit fresh non-dialog snapshots remain available; the fixture must not be used to
advertise raw PID-routed keys as certified intent.

## Running Local Tests

Run the repository-owned local automation entry point from the repository root:

```bash
pnpm run test:automation:local
```

The runner builds the current CLI, exports its exact path through `PEEKABOO_CLI_PATH`, includes the automation test target, and enables both local read and action suites. To run only the Playground-backed `see` test manually:

```bash
cli_bin_dir="$(swift build --package-path Apps/CLI --show-bin-path)"
swift build --package-path Apps/CLI --product peekaboo
PEEKABOO_INCLUDE_AUTOMATION_TESTS=true RUN_LOCAL_TESTS=true \
  PEEKABOO_CLI_PATH="$cli_bin_dir/peekaboo" \
  swift test --package-path Apps/CLI --filter SeeCommandPlaygroundTests
```

If LaunchServices cannot resolve `Playground` by name, also set `PEEKABOO_PLAYGROUND_APP` to an absolute, team-signed `Playground.app` path. The test launches its own instance and cleans up only the returned PID/process generation.

`RUN_AUTOMATION_READ=true` and `RUN_AUTOMATION_ACTIONS=true` select the reusable automation suites used by `test:automation:read` and `test:automation:actions`. `RUN_LOCAL_TESTS=true` enables tests that require locally built companion fixtures or an interactive Aqua session. Do not introduce one-off per-test environment flags; route new tests through these shared selectors.

Tests that read or mutate uncontrolled host state use the shared `PEEKABOO_INCLUDE_AMBIENT_STATE_TESTS=true` selector. Ordinary local and automation-action selectors never imply this consent, and `test:safe` explicitly overrides inherited ambient-state opt-ins. The live clipboard smoke test uses this selector and must only be enabled with fresh authorization to read, replace, and restore the ambient clipboard.

## Test Categories

### Screenshot Validation Tests (`ScreenshotValidationTests.swift`)
- **Image content validation**: Captures windows with known content and validates the output
- **Visual regression testing**: Compares screenshots to detect visual changes
- **Format testing**: Tests PNG and JPG output formats
- **Multi-display support**: Tests capturing from multiple monitors
- **Performance benchmarks**: Measures screenshot capture performance

### Local Integration Tests (`LocalOnlyTests.swift`)
- **Test host window capture**: Captures the test host application window
- **Full screen capture**: Tests screen capture with test host visible
- **Permission dialog testing**: Tests permission request flows
- **Multi-window scenarios**: Tests capturing multiple windows
- **Focus and foreground testing**: Tests window focus behavior

## Adding New Local Tests

When adding new local-only tests:

1. Tag them with `.localOnly` and gate them with `RUN_LOCAL_TESTS` to ensure they don't run on CI
2. Use the test host app for controlled testing scenarios
3. Clean up any created files/windows in test cleanup
4. Document any special requirements

Example:
```swift
@Test("My new local test", .tags(.localOnly, .screenshot))
func myLocalTest() async throws {
    // Your test code here
}
```

## Permissions

The tests will automatically check for required permissions and attempt to trigger permission dialogs if needed. Grant the following permissions when prompted:

1. **Screen Recording**: Required for all screenshot functionality
2. **Accessibility**: Optional, needed for window focus operations

## CI Considerations

These tests are automatically skipped on CI because:
- The `RUN_LOCAL_TESTS` environment variable is not set by CI or the safe automation-read runner
- CI environments typically lack screen recording permissions
- There's no graphical environment for window creation

The `.enabled(if:)` trait ensures these tests only run when explicitly enabled.
