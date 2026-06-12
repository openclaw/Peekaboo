# Changelog

All notable changes to Peekaboo CLI will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.4.2] - 2026-06-12

### Added
- `peekaboo agent` now supports explicit Claude Fable 5 (`claude-fable-5`) selection with 1M context and 128K max output while keeping Anthropic defaults on Opus 4.8 for zero-retention compatibility.

### Fixed
- Legacy screen and area capture now fails with a permission or native capture error instead of returning wallpaper-only/redacted pixels from background sessions. Thanks @VishalJ99 for #185.

## [3.4.1] - 2026-06-10

### Fixed
- `peekaboo agent` now resolves saved custom providers, xAI/Grok, Gemini 3.5 Flash, Claude Opus 4.8, and GPT-5.5 model selections before falling back to unavailable built-in defaults. Thanks @udiedrichsen for #182.

## [3.4.0] - 2026-06-07

## [3.3.0] - 2026-06-01

## [3.2.3] - 2026-05-24

## [3.2.2] - 2026-05-22

### Fixed
- `peekaboo agent` now accepts OpenRouter model IDs and can use `OPENROUTER_API_KEY` from env or credentials. Thanks @delort for #155.

## [3.2.1] - 2026-05-18

### Fixed
- `peekaboo click --coords` now treats coordinates as target-window-relative when app/window target flags are supplied, reports resolved target metadata, and requires `--global-coords` for targeted global clicks.
- `peekaboo-mcp` now shuts down cleanly during restart backoff and repairs executable permissions without shelling out through an install path.
- `pnpm run peekaboo:dev` no longer depends on a hardcoded local checkout path.
- `peekaboo agent` now tells models to use the current tool schema instead of stale tool names and arguments. Thanks @vyctorbrzezowski for #139.
- AX element detection now honors traversal budgets and reports truncation when depth, count, or per-node child limits are reached. Thanks @vyctorbrzezowski for #140.
- `peekaboo agent` and MCP clients now have an `inspect_ui` tool for AX-only UI text/control inspection without capturing screenshots. Thanks @vyctorbrzezowski for #141.
- Window-mode capture now falls back to desktop-independent ScreenCaptureKit filters when multi-display setups cannot map a window to an enumerated display. Thanks @lonexreb for #147.
- `peekaboo agent` guidance now routes AX-only observation through `inspect_ui` consistently while keeping screenshot-backed checks on `see`. Thanks @vyctorbrzezowski for #144.
- Custom provider docs, CLI help, and macOS settings now prefer `${VAR}` API key references and shell examples that preserve them literally. Thanks @scotthuang for #142.
- `peekaboo agent` now refreshes desktop context before each model turn and wires opt-in action verification through the configured capture strategy. Thanks @lonexreb for #148.
- AX traversal budgets now have wider defaults plus CLI, MCP, and environment overrides for complex app trees. Thanks @widdowson for #150 and #151.
- `peekaboo agent` now keeps OAuth access tokens on Bearer auth paths instead of misclassifying them as API keys, including config-dir overrides and audio transcription. Thanks @Crux0453 for #154.

## [3.2.0] - 2026-05-15

### Fixed
- Release automation now verifies CLI, npm, macOS app, checksum, appcast, and uploaded GitHub assets before publish.
- `peekaboo type --json` now separates requested text from executed key actions, making escaped special keys such as `\n` visible to agents without losing backwards-compatible `typedText`.
- `peekaboo permissions status --all-sources` now compares Bridge and local TCC permission state side by side, so daemon grants are no longer confused with CLI grants.
- `peekaboo mcp serve --transport ...` now rejects invalid transport names instead of silently starting stdio mode.
- `peekaboo paste --app ...` now fails before mutating the clipboard when the requested app cannot be found.
- `peekaboo agent` no longer sends stale Anthropic extended-thinking options to Claude Opus 4.7 and now exits with failure when agent execution fails.
- Command timeout JSON now reports the intended timeout error instead of occasionally surfacing cancellation as an unknown error.
- Refreshed CLI docs and quickstart examples to use current flags such as `image --path`, `click --coords`, `type --return`, `press --count`, and `scroll --amount`.

### Performance
- Debug CLI startup no longer spawns `git config` on every launch when build-staleness checking is disabled, cutting startup-heavy command latency by more than 30% in local testing.

## [3.1.2] - 2026-05-11

### Fixed
- Release automation now writes artifacts under `build/release` so clean release builds no longer embed `-dirty` in CLI version metadata.

## [3.1.1] - 2026-05-11

### Added
- `peekaboo image --path -` now writes a single captured image to stdout for shell pipelines.
- The npm package now allows Intel Macs when shipping the universal CLI binary.

### Fixed
- Agent tool schemas now preserve MCP `anyOf`/`oneOf` parameters so Gemini no longer rejects `peekaboo agent` requests with orphan `required` entries.
- `peekaboo see --capture-engine cg` now keeps frontmost/window captures on the CoreGraphics path instead of falling through to `SCScreenshotManager`.

## [3.1.0] - 2026-05-10

### Added
- `peekaboo agent --model` now understands GPT-5.5 and Claude Opus 4.7 identifiers, defaults to `gpt-5.5`, and rejects old GPT/Claude model families.
- Automation-oriented CLI commands now auto-start a warm Peekaboo daemon, reuse it across bursty invocations, and let it exit after an idle timeout.
- Bridge protocol 1.5 adds a daemon-side desktop observation operation so screenshot and `see` flows can execute fully in the warm daemon while returning compact metadata.

### Fixed
- MCP stdio servers now default to the local runtime instead of probing an existing Bridge host, avoiding recursive capture timeouts for `see` and `image` tool calls.
- MCP `image` now returns an `isError: true` tool result when Screen Recording permission is missing instead of surfacing an internal server error.
- MCP `analyze` now honors configured AI providers and per-call `provider_config` models instead of hardcoding an OpenAI model.
- Peekaboo.app now signs with the AppleEvents automation entitlement so macOS can prompt for Automation permission.
- The CLI bundle metadata and bundled Homebrew formula now advertise the macOS 15 minimum that the SwiftPM package already requires.
- `peekaboo see --annotate` now aligns labels using captured window bounds instead of guessing from the first detected element.
- Window capture on macOS 26 now resolves native Retina scale from `NSScreen.backingScaleFactor` before falling back to ScreenCaptureKit display ratios.
- `peekaboo image --app ... --window-title/--window-index` now captures the resolved window by stable window ID, avoiding mismatches between listed window indexes and ScreenCaptureKit window ordering.
- `peekaboo image --app ...` now prefers titled app windows over untitled helper windows, avoiding blank Chrome captures.
- `peekaboo image --capture-engine` is now accepted by Commander-based live parsing.
- Concurrent ScreenCaptureKit screenshot requests now queue through an in-process and cross-process capture gate instead of racing into continuation leaks or transient TCC-denied failures.
- Concurrent `peekaboo see` calls now queue the local screenshot/detection pipeline across processes, avoiding ReplayKit/ScreenCaptureKit continuation hangs under parallel usage.
- Natural-language automation examples now use `peekaboo agent "..."`.

### Performance
- `peekaboo see`, `image`, UI interaction, window, menu, dock, dialog, and app commands now prefer the warm on-demand daemon by default, avoiding repeated service startup cost across command bursts.
- `peekaboo tools`, `peekaboo list apps`, `peekaboo app list`, and purely local metadata commands still avoid daemon startup. Pass `--bridge-socket` to target a Bridge host explicitly where supported.
- Daemon-backed screenshot and `see` calls now write screenshot artifacts in the daemon and avoid sending image bytes through Bridge JSON, preventing large-payload timeouts and making warm calls substantially faster.
- Capture engine `auto` now tries the CoreGraphics path before ScreenCaptureKit, which makes repeated screenshot calls faster locally and avoids observed ScreenCaptureKit continuation hangs; explicit `--capture-engine modern` still forces ScreenCaptureKit.
- `peekaboo image --app` avoids redundant application/window-count lookups during screenshot setup and skips auto-focus work when the target app is already frontmost.
- `peekaboo image --app` now uses a CoreGraphics-only window selection fast path before falling back to full AX-enriched window enumeration, reducing warm Playground screenshot capture from about 350ms to 290ms.
- `peekaboo image` skips a redundant CLI-side screen-recording preflight and relies on the capture service's permission check, shaving about 8ms from warm one-shot app screenshots.
- `peekaboo see --app` avoids re-focusing the target window when Accessibility already reports the captured window as focused.
- `peekaboo see` avoids recursive AX child-text lookups for elements whose labels cannot use them, reducing Playground element detection from about 201ms to 134ms in local testing.
- `peekaboo see` batches per-element Accessibility descriptor reads and skips avoidable action/editability probes, reducing local Playground element detection from about 205ms to 176ms.
- `peekaboo see` limits expensive AX action and keyboard-shortcut probes to roles that can use them, reducing Playground element detection from about 286ms to roughly 180-190ms in local testing.
- `peekaboo see` skips a redundant CLI-side screen-recording preflight and relies on the capture service's permission check, shaving a fixed TCC probe from screenshot-plus-AX runs.
- `peekaboo see` now keeps AX traversal scoped to the captured window and skips web-content focus probing once a rich native AX tree is already visible, avoiding sibling-window elements and cutting native Playground detection from about 220ms to 130ms.

## [2.0.2] - 2025-07-03

### Fixed
- Actually fixed compatibility with macOS Sequoia 26 by ensuring LC_UUID load command is generated during linking
- The v2.0.1 fix was incomplete - the binary was still missing LC_UUID despite the strip command change
- Added `-Xlinker -random_uuid` to Package.swift to ensure UUID generation
- Verified both x86_64 and arm64 architectures now contain proper LC_UUID load commands

## [2.0.1] - 2025-07-03

### Fixed
- Fixed compatibility with macOS Sequoia 26 (pre-release) by preserving LC_UUID load command during binary stripping
- The strip command now uses the `-u` flag to ensure the LC_UUID load command is retained, which is required by the dynamic linker (dyld) on macOS 26

### Technical Details
- Modified build script to use `strip -Sxu` instead of `strip -Sx` to preserve the LC_UUID load command
- This ensures the binary includes the necessary UUID for debugging, crash reporting, and symbol resolution on newer macOS versions

## [2.0.0] - 2025-07-03

### Added
- **Standalone Swift CLI** - Complete rewrite in Swift for better performance and native macOS integration
- **MCP Server** - Model Context Protocol support for AI assistant integration
- **Multiple Capture Modes**:
  - Window capture (single or all windows)
  - Screen capture (main or specific display)
  - Frontmost window capture
  - Multi-window capture from multiple apps
- **AI Vision Analysis** - Analyze screenshots with OpenAI or Ollama directly from Swift CLI
- **Configuration File Support** - JSONC format configuration at `~/.config/peekaboo/config.json` with:
  - Environment variable expansion (`${HOME}`, `${OPENAI_API_KEY}`)
  - Comments support for better documentation
  - Hierarchical settings for AI providers, defaults, and logging
- **Config Command** - New `peekaboo config` subcommand to manage configuration:
  - `config init` - Create default configuration file
  - `config show` - Display current configuration
  - `config edit` - Open configuration in default editor
  - `config validate` - Validate configuration syntax
- **Permissions Command** - New `peekaboo list permissions` to check system permissions
- **PID Targeting** - Target applications by process ID with `PID:12345` syntax
- **Homebrew Distribution** - Install via `brew install steipete/tap/peekaboo` for easy installation and updates
- **Comprehensive Test Suite** - 331 tests with 100% pass rate covering all major components
- **DocC Documentation** - Comprehensive API documentation for Swift codebase

### Changed
- Complete architecture redesign separating CLI and MCP server
- Improved performance with native Swift implementation
- Better error handling and permission management
- More intuitive command-line interface following Unix conventions
- Enhanced permission visibility with clear indicators when permissions are missing
- Unified AI provider interface for consistent API across OpenAI and Ollama
- Logger's `setJsonOutputMode` and `clearDebugLogs` methods are now synchronous for better reliability

### Fixed
- Configuration precedence (CLI args > env vars > config file > defaults)
- SwiftLint violations across the codebase
- ImageSaver crash when paths contain invalid characters
- Logger race conditions in test environment
- PermissionErrorDetector now handles all relevant error domains
- Test isolation issues preventing interference between tests
- Various edge cases in error handling and file operations

### Removed
- Node.js CLI (replaced with Swift implementation)
- Legacy screenshot methods

## [1.1.0] - 2024-12-20

### Added
- Initial TypeScript implementation
- Basic screenshot capabilities
- Simple MCP integration

### Changed
- Various bug fixes and improvements

## [1.0.0] - 2024-12-19

### Added
- Initial release
- Basic screenshot functionality
