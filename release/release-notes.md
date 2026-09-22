## 4.5.0 - 2026-09-22

**Highlights:** Prevent snapshot data loss, crashes, and stuck desktop mutations; restore reliable Chrome connections; and ship smaller architecture-specific CLI downloads with automatic Homebrew selection.

- Reject zero and negative snapshot retention hours before cleanup can remove any data. Thanks @SebTardif! #751.
- Avoid stack overflow when normalizing deeply nested OpenAI model prefixes while preserving generation settings. Thanks @SebTardif! #752.
- Validate menu-bar window-list status and counts before allocating buffers or consuming results, preventing negative-count crashes. Thanks @SebTardif! #753.
- Reject overflowing scroll amounts before focus or input instead of trapping in tick arithmetic; preserve signed and zero amounts.
- Bound desktop mutation lock acquisition and reserve concurrent mutation IDs before waiting, preventing hangs and orphaned barriers. Thanks @SebTardif! #758.
- Preserve valid long input delays and prevent overflow in typing and scrolling waits. Thanks @SebTardif! #746, #747.
- Connect to approval-mode Chrome with one persistent WebSocket for verification and page operations; preserve the approval window, explain HTTP discovery 404s, and refuse silent reconnection or endpoint redirects. Thanks @steipete for the report!
- Fix CLI browser page actions refusing after a successful connection by keeping scoped-session epochs out of root Bridge requests.
- Fix foreground browser commands being blocked by an untrusted historical daemon; retain host and receipt checks, allow explicitly selected browser-capable GUI hosts, and distinguish Bridge authentication failures from Chrome approval failures. #739.
- Accept IPv6 loopback browser endpoints and reject TCP ports outside 1–65535 before discovery or receipt validation.
- Preserve snapshot lookup failures during clicks instead of misreporting timeouts and other errors as stale snapshots. Thanks @SebTardif! #756.
- Reject empty MCP Accessibility results for an explicitly requested window while preserving empty app and frontmost inspections. Thanks @SebTardif! #755.
- Let automatic screenshots use the proven classic path on an explicitly selected Bridge host when another process owns ScreenCaptureKit; keep explicit modern capture strict.
- Stop Inspector screen-change notifications when monitoring ends or its controller is released, and prevent duplicate observer registration. Thanks @SebTardif! #754.
- Add smaller arm64 and x86_64 CLI release archives alongside the universal archive, with matching Swift runtime libraries and checksums.
- Use architecture-specific macOS CLI archives for Homebrew when a release provides the complete verified pair. Thanks @vincentkoc! #766.
- Read embedded source stamps from single-architecture CLI binaries as well as universal builds, retaining cross-slice consistency checks.
- Avoid rewriting temporary screenshots during MCP image resizing while preserving validated, atomic final output.
- Skip unused local service initialization when snapshot commands target an explicit Bridge socket.
- Reduce JSON CLI startup work by avoiding duplicate command-signature reflection.
- Reduce MCP outcome validation overhead by encoding typed metadata directly, retaining canonical result and retry-safety checks.
- Skip formatting metadata for disabled CLI log messages.
- Reduce capture postprocessing by drawing contact-sheet cells directly and converting screenshots to JPEG without an intermediate TIFF.
- Refresh CI and the verified qualification runtime to Node 26.9.0, pnpm to 11.27.1, Swift Configuration to 1.2.1, KeyboardShortcuts to 3.1.0, and Sparkle to 2.10.0 for current macOS compatibility fixes.
