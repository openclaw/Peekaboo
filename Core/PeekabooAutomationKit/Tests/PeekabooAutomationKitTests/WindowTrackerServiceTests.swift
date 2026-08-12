import CoreGraphics
import PeekabooAutomationKitTestSupport
import Testing
@testable import PeekabooAutomationKit

struct WindowTrackerServiceTests {
    @Test
    @MainActor
    func `Movement tracking refreshes exact window on cache miss and preserves cache hits`() async {
        let windowID = CGWindowID(42)
        let bounds = CGRect(x: 40, y: 50, width: 300, height: 200)
        let source = WindowInfoSource(currentInfo: Self.windowInfo(
            windowID: windowID,
            bounds: bounds,
            ownerPID: 111))
        let tracker = WindowTrackerService(
            configuration: WindowTrackerConfiguration(useAXNotifications: false),
            exactWindowIdentityProvider: { source.info(for: $0) })
        await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let snapshot = UIAutomationSnapshot(
                applicationProcessId: 111,
                windowBounds: bounds,
                windowID: windowID)

            let firstResult = WindowMovementTracking.adjustPoint(CGPoint(x: 80, y: 90), snapshot: snapshot)
            source.currentInfo = nil
            let secondResult = WindowMovementTracking.adjustPoint(CGPoint(x: 80, y: 90), snapshot: snapshot)

            guard case .unchanged = firstResult else {
                Issue.record("Expected exact-window refresh to recover the cache miss, got \(firstResult)")
                return
            }
            guard case .unchanged = secondResult else {
                Issue.record("Expected cached exact-window hit, got \(secondResult)")
                return
            }
            #expect(source.requestedWindowIDs == [windowID])
        }
    }

    @Test
    @MainActor
    func `Refresh replaces cached identity and removes missing windows`() {
        let windowID = CGWindowID(42)
        let source = WindowInfoSource(currentInfo: Self.windowInfo(
            windowID: windowID,
            bounds: CGRect(x: 10, y: 20, width: 300, height: 200),
            ownerPID: 111))
        let tracker = WindowTrackerService(
            configuration: WindowTrackerConfiguration(useAXNotifications: false),
            exactWindowIdentityProvider: { _ in source.currentInfo })

        tracker.refreshWindow(windowID: windowID)
        #expect(tracker.windowBounds(for: windowID) == CGRect(x: 10, y: 20, width: 300, height: 200))
        #expect(tracker.windowOwnerProcessIdentifier(for: windowID) == 111)

        source.currentInfo = Self.windowInfo(
            windowID: windowID,
            bounds: CGRect(x: 40, y: 50, width: 500, height: 400),
            ownerPID: 222)
        tracker.refreshWindow(windowID: windowID)
        #expect(tracker.windowBounds(for: windowID) == CGRect(x: 40, y: 50, width: 500, height: 400))
        #expect(tracker.windowOwnerProcessIdentifier(for: windowID) == 222)

        source.currentInfo = nil
        tracker.refreshWindow(windowID: windowID)
        #expect(tracker.windowBounds(for: windowID) == nil)
        #expect(tracker.windowOwnerProcessIdentifier(for: windowID) == nil)
    }

    @Test
    @MainActor
    func `Full reconciliation keeps only bounds and owner and removes vanished windows`() {
        let exactSource = WindowInfoSource(currentInfo: nil)
        let catalog = VisibleWindowCatalog(rows: [
            Self.windowDictionary(
                windowID: 42,
                bounds: CGRect(x: 10, y: 20, width: 300, height: 200),
                ownerPID: 111),
            Self.windowDictionary(
                windowID: 43,
                bounds: CGRect(x: 30, y: 40, width: 500, height: 400),
                ownerPID: 222),
        ])
        let tracker = WindowTrackerService(
            configuration: WindowTrackerConfiguration(useAXNotifications: false),
            exactWindowIdentityProvider: { exactSource.info(for: $0) },
            visibleWindowInfoProvider: { catalog.rows })

        tracker.refreshAllWindows()
        #expect(tracker.windowBounds(for: 42) == CGRect(x: 10, y: 20, width: 300, height: 200))
        #expect(tracker.windowOwnerProcessIdentifier(for: 42) == 111)
        #expect(tracker.windowBounds(for: 43) == CGRect(x: 30, y: 40, width: 500, height: 400))
        #expect(exactSource.requestedWindowIDs.isEmpty)

        catalog.rows = [
            Self.windowDictionary(
                windowID: 42,
                bounds: CGRect(x: 70, y: 80, width: 300, height: 200),
                ownerPID: 333),
        ]
        tracker.refreshAllWindows()

        #expect(tracker.windowBounds(for: 42) == CGRect(x: 70, y: 80, width: 300, height: 200))
        #expect(tracker.windowOwnerProcessIdentifier(for: 42) == 333)
        #expect(tracker.windowBounds(for: 43) == nil)
        #expect(exactSource.requestedWindowIDs.isEmpty)
    }

    @Test
    @MainActor
    func `Stop clears cached window state`() {
        let windowID = CGWindowID(42)
        let source = WindowInfoSource(currentInfo: Self.windowInfo(
            windowID: windowID,
            bounds: CGRect(x: 10, y: 20, width: 300, height: 200),
            ownerPID: 111))
        let tracker = WindowTrackerService(
            configuration: WindowTrackerConfiguration(useAXNotifications: false),
            exactWindowIdentityProvider: { source.info(for: $0) })

        tracker.refreshWindow(windowID: windowID)
        #expect(tracker.windowBounds(for: windowID) != nil)

        tracker.stop()

        #expect(tracker.windowBounds(for: windowID) == nil)
        #expect(tracker.windowOwnerProcessIdentifier(for: windowID) == nil)
    }

    private static func windowInfo(
        windowID: CGWindowID,
        bounds: CGRect,
        ownerPID: pid_t) -> SystemWindowIdentity
    {
        SystemWindowIdentity(
            windowID: windowID,
            ownerProcessIdentifier: ownerPID,
            title: "",
            bounds: bounds,
            layer: 0,
            alpha: 1,
            isOnScreen: true,
            sharingState: nil)
    }

    private static func windowDictionary(
        windowID: Int,
        bounds: CGRect,
        ownerPID: Int) -> [String: Any]
    {
        [
            kCGWindowNumber as String: windowID,
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowBounds as String: [
                "X": bounds.origin.x,
                "Y": bounds.origin.y,
                "Width": bounds.size.width,
                "Height": bounds.size.height,
            ],
            kCGWindowOwnerName as String: "Ignored Owner",
            kCGWindowName as String: "Ignored Title",
        ]
    }
}

@MainActor
private final class WindowInfoSource {
    var currentInfo: SystemWindowIdentity?
    private(set) var requestedWindowIDs: [CGWindowID] = []

    init(currentInfo: SystemWindowIdentity?) {
        self.currentInfo = currentInfo
    }

    func info(for windowID: CGWindowID) -> SystemWindowIdentity? {
        self.requestedWindowIDs.append(windowID)
        return self.currentInfo
    }
}

@MainActor
private final class VisibleWindowCatalog {
    var rows: [[String: Any]]

    init(rows: [[String: Any]]) {
        self.rows = rows
    }
}
