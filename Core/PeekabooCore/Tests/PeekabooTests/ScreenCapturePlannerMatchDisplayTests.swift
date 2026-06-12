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
struct ScreenCapturePlannerMatchDisplayTests {
    // MARK: - Single-display happy paths

    @Test
    func `window inside the only display maps to index 0`() {
        let displays = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        let window = CGRect(x: 0, y: 30, width: 1920, height: 960)

        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: window,
            displayFrames: displays)

        #expect(match == .mapped(displayIndex: 0))
    }

    @Test
    func `window matching the reporter's exact bounds maps to the primary display`() {
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

    @Test
    func `window centered on the secondary right-hand display maps to index 1`() {
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

    @Test
    func `window on a display stacked above the primary (negative Y origin) maps correctly`() {
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

    @Test
    func `window on a display to the left of primary (negative X origin) maps correctly`() {
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

    @Test
    func `three-display L-shape Mac Mini configuration resolves a centered window deterministically`() {
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

    @Test
    func `window straddling two displays maps to whichever contains the center point`() {
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

    @Test
    func `window with no center hit falls back to the display with the largest overlap area`() {
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

    @Test
    func `window with no center hit picks the display with strictly larger overlap`() {
        let displays = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 200, y: 0, width: 100, height: 100),
        ]
        // Center is in the gap. Display 0 has 30 px of overlap; display 1 has 10 px.
        let window = CGRect(x: 70, y: 0, width: 140, height: 100)

        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: window,
            displayFrames: displays)

        #expect(match == .mapped(displayIndex: 0))
    }

    @Test
    func `capture pixel size never returns zero dimensions for degenerate window frames`() {
        #expect(ScreenCapturePlanner.capturePixelSize(for: .zero, scale: 2).width == 1)
        #expect(ScreenCapturePlanner.capturePixelSize(for: .zero, scale: 2).height == 1)
        #expect(ScreenCapturePlanner.capturePixelSize(for: .null, scale: 2).width == 1)
        #expect(ScreenCapturePlanner.capturePixelSize(for: .null, scale: 2).height == 1)
    }

    @Test
    func `capture pixel size scales usable window frames`() {
        let size = ScreenCapturePlanner.capturePixelSize(
            for: CGRect(x: 0, y: 0, width: 320, height: 180),
            scale: 2)

        #expect(size.width == 640)
        #expect(size.height == 360)
    }

    @Test
    func `capture pixel size uses fallback frame when primary frame is degenerate`() {
        let size = ScreenCapturePlanner.capturePixelSize(
            for: .zero,
            fallbackFrame: CGRect(x: 10, y: 20, width: 320, height: 180),
            scale: 2)

        #expect(size.width == 640)
        #expect(size.height == 360)
    }

    // MARK: - System screencapture display selection

    @Test
    func `system screencapture maps the first active display to one`() {
        let displayNumber = ScreenCapturePlanner.systemScreencaptureDisplayNumber(
            displayID: 42,
            activeDisplayIDs: [42, 99])

        #expect(displayNumber == 1)
    }

    @Test
    func `system screencapture maps a secondary active display to its one-based position`() {
        let displayNumber = ScreenCapturePlanner.systemScreencaptureDisplayNumber(
            displayID: 99,
            activeDisplayIDs: [42, 99, 123])

        #expect(displayNumber == 2)
    }

    @Test
    func `system screencapture rejects a display missing from the active list`() {
        let displayNumber = ScreenCapturePlanner.systemScreencaptureDisplayNumber(
            displayID: 7,
            activeDisplayIDs: [42, 99])

        #expect(displayNumber == nil)
    }

    @Test
    func `system screencapture omits subordinate mirrors when numbering extended displays`() {
        let displayNumber = ScreenCapturePlanner.systemScreencaptureDisplayNumber(
            displayID: 99,
            activeDisplayIDs: [42, 43, 99],
            mirroredDisplayOwners: [43: 42])

        #expect(displayNumber == 2)
    }

    @Test
    func `system screencapture maps a subordinate mirror to its owner`() {
        let displayNumber = ScreenCapturePlanner.systemScreencaptureDisplayNumber(
            displayID: 43,
            activeDisplayIDs: [42, 43, 99],
            mirroredDisplayOwners: [43: 42])

        #expect(displayNumber == 1)
    }

    // MARK: - Unmapped fallback paths (the core #143 fix)

    @Test
    func `window entirely outside every display returns .unmapped with a sensible fallback`() {
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

    @Test
    func `degenerate zero-size window returns .unmapped (issue #143's likely failure mode)`() {
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

    @Test
    func `null window rect returns .unmapped`() {
        let displays = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
        ]

        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: .null,
            displayFrames: displays)

        #expect(match == .unmapped(fallbackDisplayIndex: 0))
    }

    @Test
    func `fallback prefers the display with origin (0, 0) even when listed second`() {
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

    @Test
    func `fallback uses index 0 when no display sits at origin`() {
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

    @Test
    func `no displays returns .noDisplays so callers can throw with a clear error`() {
        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayFrames: [])

        #expect(match == .noDisplays)
    }

    @Test
    func `no displays with degenerate window also returns .noDisplays`() {
        let match = ScreenCapturePlanner.matchDisplay(
            windowFrame: .zero,
            displayFrames: [])

        #expect(match == .noDisplays)
    }
}
