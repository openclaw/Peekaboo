---
summary: 'Heuristics for filtering CG windows before screenshotting'
read_when:
  - 'touching ImageCommand/SeeCommand window selection logic'
  - 'plumbing CGWindow metadata into ServiceWindowInfo'
  - 'debugging why peekaboo see --no-elements skips or captures overlays'
---

# Window Screenshot "Smart Select" Guide

Peekaboo’s screenshot tooling (`peekaboo see`, agent capture flows) must avoid the long tail of junk windows returned by CoreGraphics. This document explains how we map `CGWindow` metadata into `ServiceWindowInfo` and the heuristics every caller should apply before attempting a capture.

## 1. Metadata We Need

| Source | Key | Purpose |
| --- | --- | --- |
| `CGWindowListCopyWindowInfo` | `kCGWindowNumber` | Stable `CGWindowID` for cross-referencing and duplicate suppression. |
| `kCGWindowLayer` | Layer filtering (layer 0 = normal app windows). |
| `kCGWindowAlpha` | Skip fully transparent/hidden overlays. |
| `kCGWindowBounds` | Size thresholds + dedupe by area. |
| `kCGWindowIsOnscreen` | Detect off-screen windows when `.optionOnScreenOnly` isn’t in use. |
| `kCGWindowOwnerPID` / `Name` | Tie back to AX/Process info; drop background helpers. |
| `kCGWindowSharingState` | Respect `NSWindow.sharingType == .none` (system replaces pixels with a “bubble”). |
| `SCWindow` (`ScreenCaptureKit`) | `frame`, `isOnScreen`, `layer`, `sharingType`, `alpha`. |
| `NSWindow` (our own process) | `isExcludedFromWindowsMenu` so we never export intentionally hidden internal windows. |

`ServiceWindowInfo` should store these fields (or derived booleans like `isShareable`) so every CLI/agent feature can make the same decision.

## 2. Filtering Heuristics

`WindowFiltering.disqualificationReason` applies these checks in order; the first failure removes the candidate window:

1. **Visibility:** capture mode rejects minimized windows before inspecting other metadata. List mode keeps them.
2. **Layer:** require `layer == 0`.
3. **Transparency:** capture mode rejects `alpha <= 0.01`; list mode rejects only `alpha <= 0`.
4. **Sharing state:** capture mode requires `isShareableWindow`. List mode does not.
5. **On-screen state:** capture mode requires `isOnScreen` and rejects `isOffScreen`. List mode does not.
6. **Dimensions:** capture candidates require `width >= 80` and `height >= 40`; window listings use `width >= 60` and `height >= 60`.
7. **Owner policy:** both modes reject `isExcludedFromWindowsMenu`.

`WindowFiltering.isRenderable(_:mode:)` is the shared boolean entry point. Empty titles are not rejected; `ObservationTargetResolver` considers title presence while scoring automatic capture candidates.

## 3. Duplicate Handling

`CGWindowListCopyWindowInfo` frequently reports multiple entries per “real” window (tab bars, separators, compositing layers). To avoid double-counting:

After filtering, `ObservationTargetResolver` keeps the first entry for each `windowID` and preserves input order. Callers that assemble `ServiceWindowInfo` arrays therefore own the preferred ordering before deduplication.

## 4. Capture Pipeline Integration

The live capture and observation paths reuse the filter:

- `ObservationTargetResolver.captureCandidates` uses capture mode for automatic `see`/observation targeting.
- ScreenCaptureKit and legacy window capture operators reject non-renderable capture candidates.
- Window listing uses list mode so minimized, off-screen, and non-shareable windows remain discoverable while tiny, transparent, nonzero-layer, or menu-excluded entries stay filtered.

## 5. Testing Strategy

1. **Unit tests** for capture/list mode differences, size, sharing state, visibility, and deduplication.
2. **Metadata tests** that feed canned CoreGraphics dictionaries into `ObservationWindowMetadataCatalog`.
3. **CLI tests** ensuring `peekaboo see --no-elements` errors when only hidden windows exist and succeeds when a shareable window is available.

Keep fixtures small (two windows per app) so we can reason about why each candidate passes or fails the heuristic chain.
