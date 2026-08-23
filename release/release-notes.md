## [4.2.3] - 2026-08-23

### Highlights

- **Credentials and provider authentication are safer.** Secure prompts, stdin, and owner-only files keep secrets out of process lists, while Gemini, OAuth, clipboard, and editor workflows receive additional hardening.
- **Window inspection explains which observation route actually works.** Per-window eligibility distinguishes combined Accessibility capture, pixels-only recovery, and unknown evidence, with safe application-level partial tree context.
- **Background automation is more capable and predictable.** Verified non-modal SwiftUI actions, exact-target inventory isolation, and policy-filtered Agent and MCP catalogs avoid unrelated or foreground-only interference.
- **CLI and MCP workflows start faster and recover more clearly.** Deferred Agent startup, Bridge-bound capture, and precise browser, help, locked-session, and window-close guidance keep routine automation moving.

### Added
- Report per-window `combined_eligible`, `pixels_only`, or `unknown` observation eligibility in CLI and MCP, including screenshot-only recovery.
- Add an embedding-only Bridge protocol 1.32 API for signed, process-generation-bound observation.
- Add atomic exact-window pixel-focus typing to CLI, MCP, Agent, and Bridge, keeping the focus-only Accessibility write and every background keyboard unit under one target receipt and retry-safe prefix accounting.
- Add explicit foreground modifier-click with exact target preflight and compare-and-swap cursor and focus restoration, preserving newer user or application state instead of overwriting it.

### Changed
- Read `config credential set` secrets from no-echo prompts, stdin, or owner-only files; let `config provider add` also accept non-secret references; retain deprecated argv compatibility.
- Skip provider discovery and Agent construction for caller-local commands that cannot invoke the Agent.
- Avoid reopening and hashing Bridge screenshot artifacts twice before CLI or MCP consumption while retaining signed client verification and use-time publication checks.
- Skip the ScreenCaptureKit post-capture settlement delay for classic captures that never enter ScreenCaptureKit.
- Reuse validated classic PNG bytes when capture performs no transform instead of encoding the same image twice.

### Fixed
- Downscale straight-alpha legacy screenshots to logical 1x instead of silently returning Retina-sized pixels.
- Bound exclusive ScreenCaptureKit transaction-lock waits inside the Bridge request envelope so a wedged peer fails clearly instead of hanging capture indefinitely. Thanks @SebTardif for #599.
- Send Gemini API keys in request headers, require HTTPS OAuth endpoints, and redact OAuth state. Thanks Vincent Koc for #575 and Tachikoma #73.
- Enforce a 10 MiB clipboard and paste file payload limit on the opened descriptor to prevent file-replacement races. Thanks @SebTardif for #561.
- Prevent configured editors from injecting command-line options. Thanks @SebTardif for #562.
- Keep Agent traces privacy-safe and deterministic, and mark unknown mutation dispatch as unsafe to retry.
- Hide foreground-only pointer tools and unsupported input shapes from background Agent and MCP catalogs while preserving explicit CLI foreground consent.
- Keep verified non-modal SwiftUI actions available, isolate exact targets from unrelated incomplete inventory, and recognize fresh `inspect_ui` observations.
- Preserve process-scoped Accessibility receipts and return read-only `application_partial` trees without reusable snapshots or mutation authority.
- Bind persistent MCP capture to its selected Bridge, keep classic capture request-local, and preserve precise signed refusals, causes, and recovery hints.
- Bind `set-value` results to the exact requested element and refuse incompatible Bridge hosts before dispatch.
- Treat confirmed window disappearance after `window close` as success.
- Fail MCP `see` when element detection did not run while accepting genuine empty scans. Thanks @SebTardif for #563.
- Require HTTP 200 responses when testing provider connectivity. Thanks @SebTardif for #560.
- Explain why locked macOS sessions cannot be captured even when `screen list` still reports connected displays.
- Restore terminal echo when credential prompts receive signals and reject background prompts or insecure credential files.
- Deduplicate runtime flags and improve unknown-command, browser reconnect, help, `learn`, schema, and background-automation guidance.
