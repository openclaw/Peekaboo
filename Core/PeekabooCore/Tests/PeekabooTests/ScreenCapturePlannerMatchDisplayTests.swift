import CoreGraphics
import Foundation
import Testing
@_spi(Testing) import PeekabooAutomationKit

/// Regression coverage for `ScreenCapturePlanner.matchDisplay` — the helper that maps a window's
/// global desktop rectangle to one of the enumerated displays. Introduced to resolve issue #143,
/// where window-mode capture failed on a multi-display Mac Mini even though `peekaboo window list`
/// reported the same window as on-screen. The previous code used `SCDisplay.frame.intersects(window.frame)`
/// directly and threw on `nil`, which left no recovery path for degenerate window frames or partial
/// display enumeration. The new helper degrades gracefully to a desktop-independent capture filter.
@Suite
struct ScreenCapturePlannerMatchDisplayTests {
    // MARK: - Single-display happy paths

    @Test("window inside the only display maps to index 0")
    func windowInsideOnlyDisplay() {
        let displays = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        let window = CGRect(x: 0, y: 30, width: 1920, height: 960)

        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: window,
            displayFrames: displays)

        #expect(match == .mapped(displayIndex: 0))
    }

    @Test("window matching the reporter's exact bounds maps to the primary display")
    func windowMatchingReporterBounds() {
        // From issue #143: Telegram window reported at (0, 30, 1920, 960) on a Mac Mini.
        // The current `.intersects` test would also succeed for this geometry against the
        // primary display, but we lock the behavior in so any future refactor that drops
        // primary-display matching gets caught.
        let displays = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: -1080, width: 1920, height: 1080),
        ]
        let window = CGRect(x: 0, y: 30, width: 1920, height: 960)

        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: window,
            displayFrames: displays)

        #expect(match == .mapped(displayIndex: 0))
    }

    // MARK: - Multi-display geometries

    @Test("window centered on the secondary right-hand display maps to index 1")
    func windowOnSecondaryRightDisplay() {
        let displays = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 2560, height: 1440),
        ]
        let window = CGRect(x: 2500, y: 200, width: 1200, height: 800)

        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: window,
            displayFrames: displays)

        #expect(match == .mapped(displayIndex: 1))
    }

    @Test("window on a display stacked above the primary (negative Y origin) maps correctly")
    func windowOnDisplayAbovePrimary() {
        let displays = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: -1080, width: 1920, height: 1080),
        ]
        let window = CGRect(x: 200, y: -500, width: 600, height: 400)

        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: window,
            displayFrames: displays)

        #expect(match == .mapped(displayIndex: 1))
    }

    @Test("window on a display to the left of primary (negative X origin) maps correctly")
    func windowOnDisplayLeftOfPrimary() {
        let displays = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: -3008, y: 0, width: 3008, height: 1692),
        ]
        let window = CGRect(x: -2000, y: 100, width: 800, height: 600)

        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: window,
            displayFrames: displays)

        #expect(match == .mapped(displayIndex: 1))
    }

    @Test("three-display L-shape Mac Mini configuration resolves a centered window deterministically")
    func threeDisplayLShape() {
        // Approximates the reporter's Mac Mini: primary + right + above-primary.
        let displays = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: -1080, width: 1920, height: 1080),
        ]

        let onPrimary = CGRect(x: 400, y: 400, width: 600, height: 400)
        let onRight = CGRect(x: 2400, y: 400, width: 600, height: 400)
        let onAbove = CGRect(x: 400, y: -700, width: 600, height: 400)

        #expect(ScreenCapturePlanner.matchDisplay(
            windowFrame: onPrimary,
            displayFrames: displays) == .mapped(displayIndex: 0))
        #expect(ScreenCapturePlanner.matchDisplay(
            windowFrame: onRight,
            displayFrames: displays) == .mapped(displayIndex: 1))
        #expect(ScreenCapturePlanner.matchDisplay(
            windowFrame: onAbove,
            displayFrames: displays) == .mapped(displayIndex: 2))
    }

    // MARK: - Straddling and ambiguous geometry

    @Test("window straddling two displays maps to whichever contains the center point")
    func windowStraddlingTwoDisplaysPrefersCenter() {
        let displays = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        ]
        // Window spans (1800..2200) horizontally — midX = 2000 sits on the second display.
        let window = CGRect(x: 1800, y: 100, width: 400, height: 300)

        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: window,
            displayFrames: displays)

        #expect(match == .mapped(displayIndex: 1))
    }

    @Test("window with no center hit falls back to the display with the largest overlap area")
    func windowFallsBackToLargestOverlapWhenCenterMisses() {
        // Place displays with a gap so that no display contains the center, but one has more overlap.
        let displays = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 200, y: 0, width: 100, height: 100),
        ]
        // Window spans both displays plus the 100px gap; center (150, 50) is in neither.
        // Overlap with display 0: (50, 0, 50, 100) = 5000. Overlap with display 1: (200, 0, 50, 100) = 5000.
        // Tie-breaker is iteration order, so the earlier index wins.
        let window = CGRect(x: 50, y: 0, width: 200, height: 100)

        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: window,
            displayFrames: displays)

        #expect(match == .mapped(displayIndex: 0))
    }

    @Test("window with no center hit picks the display with strictly larger overlap")
    func windowPicksLargerOverlapDisplay() {
        let displays = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 200, y: 0, width: 100, height: 100),
        ]
        // Center (190, 50) is in neither. Overlap with display 0: (140, 0, 60, 100) — wait, that would
        // actually contain the center. Use a window centered in the gap but skewed toward display 1.
        // Window: x=110, w=180 → spans 110..290, center 200 is on display 1's left edge (200, 0).
        // display 1 contains center? `.contains(CGPoint)` is inclusive of origin so yes — adjust.
        // Use x=110, w=140 → spans 110..250, center=180 in the gap, no center hit.
        // Overlap with display 0: (110, 0, ...) intersect (0,0,100,100) = (110..100) = empty. Hmm.
        // Use x=80, w=140 → 80..220, center=150 in gap, overlap0 = (80..100)=20*100=2000, overlap1 = (200..220)=20*100=2000. Tie.
        // Make it asymmetric: x=70, w=140 → 70..210, center=140 in gap, overlap0=(70..100)=30*100=3000, overlap1=(200..210)=10*100=1000. Display 0 wins.
        let window = CGRect(x: 70, y: 0, width: 140, height: 100)

        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: window,
            displayFrames: displays)

        #expect(match == .mapped(displayIndex: 0))
    }

    // MARK: - Unmapped fallback paths (the core #143 fix)

    @Test("window entirely outside every display returns .unmapped with a sensible fallback")
    func windowEntirelyOffscreenReturnsUnmapped() {
        let displays = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        ]
        // Window far below any display.
        let window = CGRect(x: 100, y: 5000, width: 400, height: 300)

        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: window,
            displayFrames: displays)

        // Primary (origin == .zero) is preferred as the fallback for scale and metadata purposes;
        // the operator will use a desktop-independent capture filter regardless.
        #expect(match == .unmapped(fallbackDisplayIndex: 0))
    }

    @Test("degenerate zero-size window returns .unmapped (issue #143's likely failure mode)")
    func zeroSizeWindowReturnsUnmapped() {
        let displays = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
        ]
        // Reproduces the suspected Mac Mini failure: SCWindow.frame reports degenerate bounds on
        // certain multi-display setups, which makes the old `.intersects` test return false for
        // every display.
        let window = CGRect.zero

        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: window,
            displayFrames: displays)

        #expect(match == .unmapped(fallbackDisplayIndex: 0))
    }

    @Test("null window rect returns .unmapped")
    func nullWindowRectReturnsUnmapped() {
        let displays = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
        ]

        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: .null,
            displayFrames: displays)

        #expect(match == .unmapped(fallbackDisplayIndex: 0))
    }

    @Test("fallback prefers the display with origin (0, 0) even when listed second")
    func fallbackPrefersOriginDisplay() {
        // Primary is at (0,0) but listed second — emulates an enumeration order quirk.
        let displays = [
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
        ]
        let window = CGRect(x: 10000, y: 10000, width: 100, height: 100)

        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: window,
            displayFrames: displays)

        #expect(match == .unmapped(fallbackDisplayIndex: 1))
    }

    @Test("fallback uses index 0 when no display sits at origin")
    func fallbackUsesFirstDisplayWhenNoOriginDisplay() {
        // Pathological config where no display has origin (0,0) — e.g. only a single secondary display
        // is enumerated. The fallback should still pick a deterministic index so capture can proceed.
        let displays = [
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        ]
        let window = CGRect(x: 100, y: 100, width: 100, height: 100)

        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: window,
            displayFrames: displays)

        #expect(match == .unmapped(fallbackDisplayIndex: 0))
    }

    // MARK: - Empty enumeration

    @Test("no displays returns .noDisplays so callers can throw with a clear error")
    func noDisplaysReturnsNoDisplays() {
        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayFrames: [])

        #expect(match == .noDisplays)
    }

    @Test("no displays with degenerate window also returns .noDisplays")
    func noDisplaysWithDegenerateWindow() {
        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: .zero,
            displayFrames: [])

        #expect(match == .noDisplays)
    }
}
