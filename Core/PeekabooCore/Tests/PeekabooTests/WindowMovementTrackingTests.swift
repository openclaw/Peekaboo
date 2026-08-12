import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import Testing

@Suite(.tags(.safe))
struct WindowMovementTrackingTests {
    @Test
    @MainActor
    func `Adjusts points when window moves`() async {
        let snapshot = UIAutomationSnapshot(
            windowBounds: CGRect(x: 100, y: 100, width: 200, height: 200),
            windowID: 42)

        let tracker = StubWindowTracker(bounds: CGRect(x: 140, y: 150, width: 200, height: 200))
        await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let original = CGPoint(x: 150, y: 150)
            let result = WindowMovementTracking.adjustPoint(original, snapshot: snapshot)

            #expect(tracker.refreshCount == 0)
            switch result {
            case let .adjusted(point, delta):
                #expect(delta.x == 40)
                #expect(delta.y == 50)
                #expect(point == CGPoint(x: 190, y: 200))
            default:
                Issue.record("Expected adjusted point, got \(result)")
            }
        }
    }

    @Test
    @MainActor
    func `Refreshes exact window after provider cache miss`() async {
        let snapshot = UIAutomationSnapshot(
            applicationProcessId: 321,
            windowBounds: CGRect(x: 100, y: 100, width: 200, height: 200),
            windowID: 42)
        let tracker = StubWindowTracker(
            bounds: nil,
            refreshedBounds: CGRect(x: 140, y: 150, width: 200, height: 200),
            refreshedOwnerProcessIdentifier: 321)
        await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let result = WindowMovementTracking.adjustPoint(CGPoint(x: 150, y: 150), snapshot: snapshot)

            #expect(tracker.refreshedWindowIDs == [42])
            guard case let .adjusted(point, delta) = result else {
                Issue.record("Expected adjusted point after exact-window refresh, got \(result)")
                return
            }
            #expect(delta == CGPoint(x: 40, y: 50))
            #expect(point == CGPoint(x: 190, y: 200))
        }
    }

    @Test
    @MainActor
    func `Returns stale when window resizes`() async {
        let snapshot = UIAutomationSnapshot(
            applicationName: "TextEdit",
            windowTitle: "Notes",
            windowBounds: CGRect(x: 0, y: 0, width: 200, height: 200),
            windowID: 99)

        let tracker = StubWindowTracker(bounds: CGRect(x: 0, y: 0, width: 300, height: 200))
        await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let result = WindowMovementTracking.adjustPoint(CGPoint(x: 10, y: 10), snapshot: snapshot)
            switch result {
            case let .stale(message):
                #expect(message.contains("changed size"))
                #expect(message.contains("windowID: 99"))
                #expect(message.contains("app: TextEdit"))
                #expect(message.contains("title: Notes"))
                #expect(message.contains("Previous bounds:"))
                #expect(message.contains("current bounds:"))
            default:
                Issue.record("Expected stale result, got \(result)")
            }
        }
    }

    @Test
    @MainActor
    func `Allows tiny window size jitter`() async {
        let snapshot = UIAutomationSnapshot(
            windowBounds: CGRect(x: 100, y: 100, width: 200, height: 200),
            windowID: 98)

        let tracker = StubWindowTracker(bounds: CGRect(x: 110, y: 120, width: 203, height: 204))
        await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let result = WindowMovementTracking.adjustPoint(CGPoint(x: 150, y: 150), snapshot: snapshot)
            switch result {
            case let .adjusted(point, delta):
                #expect(delta == CGPoint(x: 10, y: 20))
                #expect(point == CGPoint(x: 160, y: 170))
            default:
                Issue.record("Expected adjusted point for tiny size jitter, got \(result)")
            }
        }
    }

    @Test
    @MainActor
    func `Returns stale when tracked window disappears`() async {
        let snapshot = UIAutomationSnapshot(
            applicationBundleId: "com.apple.TextEdit",
            windowTitle: "Notes",
            windowBounds: CGRect(x: 0, y: 0, width: 200, height: 200),
            windowID: 100)

        let tracker = StubWindowTracker(bounds: nil)
        await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let result = WindowMovementTracking.adjustPoint(CGPoint(x: 10, y: 10), snapshot: snapshot)
            switch result {
            case let .stale(message):
                #expect(message.contains("no longer available"))
                #expect(message.contains("windowID: 100"))
                #expect(message.contains("bundle: com.apple.TextEdit"))
                #expect(message.contains("title: Notes"))
            default:
                Issue.record("Expected stale result, got \(result)")
            }
        }
    }

    @Test
    @MainActor
    func `Returns stale when window without snapshot bounds disappears`() async {
        let snapshot = UIAutomationSnapshot(
            applicationProcessId: 321,
            windowID: 100)

        let tracker = StubWindowTracker(bounds: nil)
        await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let result = WindowMovementTracking.adjustPoint(CGPoint(x: 10, y: 10), snapshot: snapshot)
            guard case let .stale(message) = result else {
                Issue.record("Expected stale result, got \(result)")
                return
            }
            #expect(message.contains("no longer available"))
            #expect(message.contains("windowID: 100"))
        }
    }

    @Test
    @MainActor
    func `Returns stale when window ID belongs to another process`() async {
        let snapshot = UIAutomationSnapshot(
            applicationProcessId: 321,
            windowID: 100)

        let tracker = StubWindowTracker(
            bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
            ownerProcessIdentifier: 654)
        await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let result = WindowMovementTracking.adjustPoint(CGPoint(x: 10, y: 10), snapshot: snapshot)
            guard case let .stale(message) = result else {
                Issue.record("Expected stale result, got \(result)")
                return
            }
            #expect(message.contains("now belongs to PID 654"))
            #expect(message.contains("not PID 321"))
        }
    }

    @Test
    @MainActor
    func `Adjusts points by snapshot id using snapshot manager`() async throws {
        let snapshot = UIAutomationSnapshot(
            windowBounds: CGRect(x: 10, y: 20, width: 200, height: 200),
            windowID: 101)
        let snapshots = PointSnapshotManager(snapshot: snapshot)

        let tracker = StubWindowTracker(bounds: CGRect(x: 15, y: 35, width: 200, height: 200))
        try await WindowMovementTrackingProviderScope.withProvider(tracker) {
            let adjusted = try await WindowMovementTracking.adjustPoint(
                CGPoint(x: 50, y: 60),
                snapshotId: "snapshot-id",
                snapshots: snapshots)

            #expect(adjusted == CGPoint(x: 55, y: 75))
        }
    }
}

@MainActor
private final class StubWindowTracker: WindowTrackingProviding {
    private var bounds: CGRect?
    private var ownerProcessIdentifier: pid_t?
    private let refreshedBounds: CGRect?
    private let refreshedOwnerProcessIdentifier: pid_t?
    private(set) var refreshedWindowIDs: [CGWindowID] = []

    var refreshCount: Int {
        self.refreshedWindowIDs.count
    }

    init(
        bounds: CGRect?,
        ownerProcessIdentifier: pid_t? = nil,
        refreshedBounds: CGRect? = nil,
        refreshedOwnerProcessIdentifier: pid_t? = nil)
    {
        self.bounds = bounds
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.refreshedBounds = refreshedBounds
        self.refreshedOwnerProcessIdentifier = refreshedOwnerProcessIdentifier
    }

    func windowBounds(for windowID: CGWindowID) -> CGRect? {
        guard windowID > 0 else { return nil }
        return self.bounds
    }

    func windowOwnerProcessIdentifier(for _: CGWindowID) -> pid_t? {
        self.ownerProcessIdentifier
    }

    func refreshWindow(for windowID: CGWindowID) {
        self.refreshedWindowIDs.append(windowID)
        self.bounds = self.refreshedBounds
        self.ownerProcessIdentifier = self.refreshedOwnerProcessIdentifier
    }
}

@MainActor
private final class PointSnapshotManager: SnapshotManagerProtocol {
    private let snapshot: UIAutomationSnapshot

    init(snapshot: UIAutomationSnapshot) {
        self.snapshot = snapshot
    }

    func createSnapshot() async throws -> String {
        "snapshot-id"
    }

    func storeDetectionResult(snapshotId _: String, result _: ElementDetectionResult) async throws {}

    func getDetectionResult(snapshotId _: String) async throws -> ElementDetectionResult? {
        nil
    }

    func getMostRecentSnapshot() async -> String? {
        "snapshot-id"
    }

    func getMostRecentSnapshot(applicationBundleId _: String) async -> String? {
        "snapshot-id"
    }

    func invalidateImplicitLatestSnapshot() async throws -> String? {
        "snapshot-id"
    }

    func listSnapshots() async throws -> [SnapshotInfo] {
        []
    }

    func cleanSnapshot(snapshotId _: String) async throws {}

    func cleanSnapshotsOlderThan(days _: Int) async throws -> Int {
        0
    }

    func cleanAllSnapshots() async throws -> Int {
        0
    }

    func getSnapshotStoragePath() -> String {
        "memory"
    }

    func storeScreenshot(_: SnapshotScreenshotRequest) async throws {}

    func storeAnnotatedScreenshot(snapshotId _: String, annotatedScreenshotPath _: String) async throws {}

    func getElement(snapshotId _: String, elementId _: String) async throws -> UIElement? {
        nil
    }

    func findElements(snapshotId _: String, matching _: String) async throws -> [UIElement] {
        []
    }

    func getUIAutomationSnapshot(snapshotId _: String) async throws -> UIAutomationSnapshot? {
        self.snapshot
    }
}
