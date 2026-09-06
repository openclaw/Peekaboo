## 4.3.1 - 2026-09-05

**Highlights:** Exact popup and sheet screenshots, bounded image reads, and updater security fixes.

### Fixed
- Capture exact popup and sheet extents without attached windows, reject mismatched images before publishing coordinates, and preserve 1×/Retina mapping without double-scaling. #689.
- Update Sparkle to 2.9.6 for installer archive handling and signature validation security fixes. #691.
- Cap observation and MCP screenshot reads and reject files that grow or are replaced during reading; thanks @SebTardif for #683.
- Bound `see` publication reads while preserving annotations larger than their raw screenshots; thanks @SebTardif for #688.
- Start the `capture action` TERM grace after signal dispatch so delayed cancellation or timeout handling does not prematurely kill graceful children; retain the absolute completion deadline. #692.
- Add an optional `config edit --timeout` for scripted editor waits while preserving unlimited interactive editing; thanks @SebTardif for #681.
- Bound debug build-staleness Git probes and drain their output so large dirty worktrees still report stale builds; thanks @SebTardif for #682.
- Preserve GUI capture readiness after ScreenCaptureKit preparation fails, allowing explicit classic recovery on the same proven host while retaining typed blockers, automatic-engine behavior, and older clients' signed receipts. #684.
- Preserve omitted capability metadata in legacy Bridge 1.28 handshakes while retaining modern diagnostic negotiation. #692.
- Verify ScreenCaptureKit owner and capability-marker close-on-fork protection through child descriptor behavior instead of SDK query bits, preserving atomic open flags.
- Route Homebrew release updates and installation instructions through `openclaw/tap`.
- Refresh Swift networking and crypto dependencies, pnpm, and Node setup tooling. #691.
- Keep validation fixtures independent of operator credentials and live window IDs, and synchronize cleanup/disconnect checks with completed state transitions. #690, #692.
