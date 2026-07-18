## [3.9.5] - 2026-07-18

### Highlights
- Browser coordinate automation now fails closed instead of claiming success when Chrome exposes only non-actionable accessibility containers, and exact-window focus/selection keeps multi-window clicks on the intended window.

### Added
- Add `peekaboo screen list` display enumeration and expose key/frontmost, layer, and accessibility subrole metadata in `window list --json`.

### Changed
- Refresh `chrome-devtools-mcp` to 1.6.0.

### Fixed
- Make coordinate clicking fail closed on generic or unverified accessibility press targets, prefer the app's actual key window over helper panels, and require exact-window focus verification before foreground input.
