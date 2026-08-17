import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAutomationKit

/// The window listing path scans `[.optionAll, .excludeDesktopElements]`, so it reports minimized and
/// off-Space windows. Exact-window lookup must agree with it: resolving only through
/// `optionIncludingWindow` reported those live windows as gone, which surfaced to callers as a stale
/// snapshot at dispatch time for a window the listing had just handed out.
@MainActor
struct WindowIdentityExactWindowLookupTests {
    @Test
    func `Exact window lookup resolves a window optionIncludingWindow omits`() throws {
        let bounds = CGRect(x: 463, y: 187, width: 586, height: 488)
        let catalog = WindowServerCatalogFixture(
            onScreenWindowIDs: [10847],
            allWindows: [
                Self.windowDictionary(windowID: 10847, ownerPID: 3764, bounds: bounds),
                Self.windowDictionary(windowID: 10852, ownerPID: 3764, bounds: bounds),
            ])

        let info = try #require(WindowIdentityService.exactWindowServerInfo(
            windowID: 10852,
            windowListProvider: catalog.windowList))

        #expect(info.windowID == 10852)
        #expect(info.ownerPID == 3764)
        #expect(info.bounds == bounds)
    }

    @Test
    func `Exact window lookup stays unresolved for a window absent from the whole catalog`() {
        let catalog = WindowServerCatalogFixture(
            onScreenWindowIDs: [10847],
            allWindows: [
                Self.windowDictionary(
                    windowID: 10847,
                    ownerPID: 3764,
                    bounds: CGRect(x: 405, y: 129, width: 586, height: 488)),
            ])

        #expect(WindowIdentityService.exactWindowServerInfo(
            windowID: 10852,
            windowListProvider: catalog.windowList) == nil)
    }

    /// Mirrors the measured WindowServer contract: `optionIncludingWindow` answers only for on-screen
    /// windows, while the full catalog still carries every live window's exact identity.
    private struct WindowServerCatalogFixture {
        let onScreenWindowIDs: Set<CGWindowID>
        let allWindows: [[String: Any]]

        func windowList(_ options: CGWindowListOption, _ relativeToWindow: CGWindowID) -> [[String: Any]]? {
            guard options.contains(.optionIncludingWindow) else {
                return self.allWindows
            }
            guard self.onScreenWindowIDs.contains(relativeToWindow) else {
                return []
            }
            return self.allWindows.filter {
                ($0[kCGWindowNumber as String] as? Int).map(CGWindowID.init) == relativeToWindow
            }
        }
    }

    private static func windowDictionary(
        windowID: Int,
        ownerPID: Int,
        bounds: CGRect) -> [String: Any]
    {
        [
            kCGWindowNumber as String: windowID,
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
            kCGWindowLayer as String: 0,
            kCGWindowAlpha as String: 1,
        ]
    }
}
