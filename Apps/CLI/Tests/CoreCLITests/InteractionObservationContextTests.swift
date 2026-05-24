import CoreGraphics
import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct InteractionObservationContextTests {
    @Test
    func `Explicit snapshot is trimmed and wins over latest`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let latest = try await snapshots.createSnapshot()

        let context = await InteractionObservationContext.resolve(
            explicitSnapshot: "  explicit-snapshot  ",
            fallbackToLatest: true,
            snapshots: snapshots
        )

        #expect(latest != "explicit-snapshot")
        #expect(context.explicitSnapshotId == "explicit-snapshot")
        #expect(context.snapshotId == "explicit-snapshot")
        #expect(context.source == .explicit)
    }

    @Test
    func `Latest snapshot is used only when requested`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let latest = try await snapshots.createSnapshot()

        let withoutFallback = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: false,
            snapshots: snapshots
        )
        let withFallback = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )

        #expect(withoutFallback.snapshotId == nil)
        #expect(withoutFallback.source == .none)
        #expect(withFallback.snapshotId == latest)
        #expect(withFallback.source == .latest)
    }

    @Test
    func `Explicit latest alias resolves to most recent snapshot`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let latest = try await snapshots.createSnapshot(id: "fresh-snapshot")

        let context = await InteractionObservationContext.resolve(
            explicitSnapshot: " latest ",
            fallbackToLatest: true,
            snapshots: snapshots
        )

        #expect(context.explicitSnapshotId == nil)
        #expect(context.snapshotId == latest)
        #expect(context.source == .latest)
    }

    @Test
    func `Explicit latest alias resolves even when omitted fallback is disabled`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let latest = try await snapshots.createSnapshot(id: "fresh-snapshot")

        let context = await InteractionObservationContext.resolve(
            explicitSnapshot: "most-recent",
            fallbackToLatest: false,
            snapshots: snapshots
        )

        #expect(context.explicitSnapshotId == nil)
        #expect(context.snapshotId == latest)
        #expect(context.source == .latest)
    }

    @Test
    func `Focus snapshot is skipped for latest snapshot with explicit target`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let latest = try await snapshots.createSnapshot()
        var target = InteractionTargetOptions()
        target.app = "TextEdit"

        let latestContext = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let explicitContext = await InteractionObservationContext.resolve(
            explicitSnapshot: "explicit",
            fallbackToLatest: true,
            snapshots: snapshots
        )

        #expect(latestContext.snapshotId == latest)
        #expect(latestContext.focusSnapshotId(for: target) == nil)
        #expect(explicitContext.focusSnapshotId(for: target) == "explicit")
    }

    @Test
    func `Interaction observation target prefers title over index`() throws {
        var target = InteractionTargetOptions()
        target.app = "Preview"
        target.windowTitle = "Main"
        target.windowIndex = 2

        switch try target.observationTargetRequest() {
        case let .app(identifier, window):
            #expect(identifier == "Preview")
            switch window {
            case let .some(.title(title)):
                #expect(title == "Main")
            default:
                Issue.record("Expected title window selection")
            }
        default:
            Issue.record("Expected app observation target")
        }
    }

    @Test
    func `Latest snapshot invalidates after mutation`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let latest = try await snapshots.createSnapshot()

        let context = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )

        let invalidated = try await context.invalidateAfterMutation(using: snapshots)

        #expect(invalidated == latest)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
        #expect(try await snapshots.listSnapshots().isEmpty)
    }

    @Test
    func `Explicit snapshot stays available after mutation`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let explicit = try await snapshots.createSnapshot(id: "explicit-snapshot")

        let context = await InteractionObservationContext.resolve(
            explicitSnapshot: "explicit-snapshot",
            fallbackToLatest: true,
            snapshots: snapshots
        )

        let invalidated = try await context.invalidateAfterMutation(using: snapshots)

        #expect(explicit == "explicit-snapshot")
        #expect(invalidated == nil)
        #expect(await snapshots.getMostRecentSnapshot() == "explicit-snapshot")
        #expect(try await snapshots.listSnapshots().map(\.id) == ["explicit-snapshot"])
    }

    @Test
    func `Latest snapshot can be invalidated after focus changes`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let latest = try await snapshots.createSnapshot()

        let invalidated = try await InteractionObservationContext.invalidateLatestSnapshot(using: snapshots)

        #expect(invalidated == latest)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
        #expect(try await snapshots.listSnapshots().isEmpty)
    }

    @Test
    func `Latest snapshot invalidation is a no-op when none exists`() async throws {
        let snapshots = CoreSnapshotManagerStub()

        let invalidated = try await InteractionObservationContext.invalidateLatestSnapshot(using: snapshots)

        #expect(invalidated == nil)
    }

    @Test
    func `Mutation invalidation without observation drops latest snapshot`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let latest = try await snapshots.createSnapshot()
        let context = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: false,
            snapshots: snapshots
        )

        await InteractionObservationInvalidator.invalidateAfterMutationOrLatest(
            context,
            snapshots: snapshots,
            logger: Logger.shared,
            reason: "test mutation"
        )

        #expect(latest.isEmpty == false)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    func `Mutation invalidation preserves explicit snapshot`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let explicit = try await snapshots.createSnapshot(id: "explicit-snapshot")
        let context = await InteractionObservationContext.resolve(
            explicitSnapshot: "explicit-snapshot",
            fallbackToLatest: false,
            snapshots: snapshots
        )

        await InteractionObservationInvalidator.invalidateAfterMutationOrLatest(
            context,
            snapshots: snapshots,
            logger: Logger.shared,
            reason: "test mutation"
        )

        #expect(explicit == "explicit-snapshot")
        #expect(await snapshots.getMostRecentSnapshot() == "explicit-snapshot")
    }

    @Test
    func `Missing implicit element refreshes observation snapshot`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let freshDetection = Self.detectionResult(
            snapshotId: "fresh-snapshot",
            element: Self.buttonElement(id: "B2")
        )
        let desktopObservation = RecordingDesktopObservationService(elements: freshDetection)
        var target = InteractionTargetOptions()
        target.app = "TextEdit"

        let refreshed = try await InteractionObservationRefresher.refreshForMissingElementIfNeeded(
            observation,
            elementId: "B2",
            target: target,
            dependencies: InteractionObservationRefreshDependencies(
                desktopObservation: desktopObservation,
                snapshots: snapshots
            ),
            logger: Logger.shared
        )

        #expect(refreshed.snapshotId == "fresh-snapshot")
        #expect(refreshed.source == .latest)
        #expect(desktopObservation.requests.map(\.target) == [.app(identifier: "TextEdit", window: nil)])
    }

    @Test
    func `Existing implicit element does not refresh observation snapshot`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let snapshotId = try await snapshots.createSnapshot(id: "latest-snapshot")
        try await snapshots.storeDetectionResult(
            snapshotId: snapshotId,
            result: Self.detectionResult(snapshotId: snapshotId, element: Self.buttonElement(id: "B1"))
        )
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let desktopObservation = RecordingDesktopObservationService(
            elements: Self.detectionResult(snapshotId: "fresh-snapshot", element: Self.buttonElement(id: "B1"))
        )

        let refreshed = try await InteractionObservationRefresher.refreshForMissingElementIfNeeded(
            observation,
            elementId: "B1",
            target: InteractionTargetOptions(),
            dependencies: InteractionObservationRefreshDependencies(
                desktopObservation: desktopObservation,
                snapshots: snapshots
            ),
            logger: Logger.shared
        )

        #expect(refreshed.snapshotId == "latest-snapshot")
        #expect(desktopObservation.requests.isEmpty)
    }

    @Test
    func `Explicit snapshot missing element does not refresh`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let explicit = try await snapshots.createSnapshot(id: "explicit-snapshot")
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: explicit,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let desktopObservation = RecordingDesktopObservationService(
            elements: Self.detectionResult(snapshotId: "fresh-snapshot", element: Self.buttonElement(id: "B2"))
        )

        let refreshed = try await InteractionObservationRefresher.refreshForMissingElementIfNeeded(
            observation,
            elementId: "B2",
            target: InteractionTargetOptions(),
            dependencies: InteractionObservationRefreshDependencies(
                desktopObservation: desktopObservation,
                snapshots: snapshots
            ),
            logger: Logger.shared
        )

        #expect(refreshed.snapshotId == "explicit-snapshot")
        #expect(desktopObservation.requests.isEmpty)
    }

    @Test
    func `Missing implicit query refreshes observation snapshot`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let staleSnapshotId = try await snapshots.createSnapshot(id: "latest-snapshot")
        try await snapshots.storeDetectionResult(
            snapshotId: staleSnapshotId,
            result: Self.detectionResult(snapshotId: staleSnapshotId, element: Self.buttonElement(id: "B1"))
        )
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let freshDetection = Self.detectionResult(
            snapshotId: "fresh-snapshot",
            element: Self.buttonElement(id: "B2", label: "Save")
        )
        let desktopObservation = RecordingDesktopObservationService(elements: freshDetection)

        let refreshed = try await InteractionObservationRefresher.refreshForMissingQueryIfNeeded(
            observation,
            query: "Save",
            target: InteractionTargetOptions(),
            dependencies: InteractionObservationRefreshDependencies(
                desktopObservation: desktopObservation,
                snapshots: snapshots
            ),
            logger: Logger.shared
        )

        #expect(refreshed.snapshotId == "fresh-snapshot")
        #expect(desktopObservation.requests.count == 1)
    }

    @Test
    func `Existing implicit query does not refresh observation snapshot`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let snapshotId = try await snapshots.createSnapshot(id: "latest-snapshot")
        try await snapshots.storeDetectionResult(
            snapshotId: snapshotId,
            result: Self.detectionResult(snapshotId: snapshotId, element: Self.buttonElement(id: "B1", label: "Save"))
        )
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: nil,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let desktopObservation = RecordingDesktopObservationService(
            elements: Self.detectionResult(snapshotId: "fresh-snapshot", element: Self.buttonElement(id: "B2"))
        )

        let refreshed = try await InteractionObservationRefresher.refreshForMissingQueryIfNeeded(
            observation,
            query: "Save",
            target: InteractionTargetOptions(),
            dependencies: InteractionObservationRefreshDependencies(
                desktopObservation: desktopObservation,
                snapshots: snapshots
            ),
            logger: Logger.shared
        )

        #expect(refreshed.snapshotId == "latest-snapshot")
        #expect(desktopObservation.requests.isEmpty)
    }

    @Test
    func `Explicit snapshot missing query does not refresh`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let explicit = try await snapshots.createSnapshot(id: "explicit-snapshot")
        let observation = await InteractionObservationContext.resolve(
            explicitSnapshot: explicit,
            fallbackToLatest: true,
            snapshots: snapshots
        )
        let desktopObservation = RecordingDesktopObservationService(
            elements: Self.detectionResult(snapshotId: "fresh-snapshot", element: Self.buttonElement(id: "B2"))
        )

        let refreshed = try await InteractionObservationRefresher.refreshForMissingQueryIfNeeded(
            observation,
            query: "Save",
            target: InteractionTargetOptions(),
            dependencies: InteractionObservationRefreshDependencies(
                desktopObservation: desktopObservation,
                snapshots: snapshots
            ),
            logger: Logger.shared
        )

        #expect(refreshed.snapshotId == "explicit-snapshot")
        #expect(desktopObservation.requests.isEmpty)
    }

    @Test
    func `Element target point resolver adjusts moved window centers`() async throws {
        let snapshots = CoreSnapshotManagerStub()
        let snapshotId = try await snapshots.createSnapshot(id: "snapshot-with-window")
        try await snapshots.storeDetectionResult(
            snapshotId: snapshotId,
            result: Self.detectionResult(
                snapshotId: snapshotId,
                element: DetectedElement(
                    id: "B1",
                    type: .button,
                    label: "Save",
                    bounds: CGRect(x: 50, y: 70, width: 100, height: 40)
                )
            )
        )
        snapshots.storeUIAutomationSnapshot(
            UIAutomationSnapshot(
                windowBounds: CGRect(x: 10, y: 20, width: 300, height: 200),
                windowID: 42
            ),
            snapshotId: snapshotId
        )
        let tracker = CoreWindowTracker(
            bounds: CGRect(x: 30, y: 25, width: 300, height: 200)
        )
        WindowMovementTracking.provider = tracker
        defer { WindowMovementTracking.provider = nil }

        let point = try await InteractionTargetPointResolver.elementCenter(
            elementId: "B1",
            snapshotId: snapshotId,
            snapshots: snapshots
        )

        #expect(point == CGPoint(x: 120, y: 95))

        let resolution = try await InteractionTargetPointResolver.elementCenterResolution(
            element: Self.buttonElement(id: "B1", label: "Save"),
            elementId: "B1",
            snapshotId: snapshotId,
            snapshots: snapshots
        )

        #expect(resolution.point == CGPoint(x: 70, y: 37))
        #expect(resolution.diagnostics.source == "element")
        #expect(resolution.diagnostics.elementId == "B1")
        #expect(resolution.diagnostics.snapshotId == snapshotId)
        #expect(resolution.diagnostics.original == InteractionPoint(CGPoint(x: 50, y: 32)))
        #expect(resolution.diagnostics.resolved == InteractionPoint(CGPoint(x: 70, y: 37)))
        #expect(resolution.diagnostics.windowAdjustment?.status == "adjusted")
        #expect(resolution.diagnostics.windowAdjustment?.delta == InteractionPoint(CGPoint(x: 20, y: 5)))
    }

    @Test
    func `Target point diagnostics describe coordinate targets`() {
        let point = CGPoint(x: 10, y: 20)
        let resolution = InteractionTargetPointResolver.coordinate(point, source: .coordinates)

        #expect(resolution.point == point)
        #expect(resolution.diagnostics.source == "coordinates")
        #expect(resolution.diagnostics.original == InteractionPoint(point))
        #expect(resolution.diagnostics.resolved == InteractionPoint(point))
        #expect(resolution.diagnostics.windowAdjustment == nil)
    }

    private static func buttonElement(id: String) -> DetectedElement {
        self.buttonElement(id: id, label: "Button \(id)")
    }

    private static func buttonElement(id: String, label: String) -> DetectedElement {
        DetectedElement(
            id: id,
            type: .button,
            label: label,
            bounds: CGRect(x: 10, y: 20, width: 80, height: 24)
        )
    }

    private static func detectionResult(snapshotId: String, element: DetectedElement) -> ElementDetectionResult {
        ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/\(snapshotId).png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 1, method: "test")
        )
    }
}

@MainActor
private final class RecordingDesktopObservationService: DesktopObservationServiceProtocol {
    private let elements: ElementDetectionResult
    private(set) var requests: [DesktopObservationRequest] = []

    init(elements: ElementDetectionResult) {
        self.elements = elements
    }

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.requests.append(request)
        return DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .frontmost),
            capture: CaptureResult(
                imageData: Data(),
                metadata: CaptureMetadata(size: CGSize(width: 1, height: 1), mode: .frontmost)
            ),
            elements: self.elements
        )
    }
}

private final class CoreSnapshotManagerStub: SnapshotManagerProtocol, @unchecked Sendable {
    private var snapshotInfos: [String: SnapshotInfo] = [:]
    private var detectionResults: [String: ElementDetectionResult] = [:]
    private var automationSnapshots: [String: UIAutomationSnapshot] = [:]
    private var mostRecentSnapshotId: String?

    func createSnapshot() async throws -> String {
        try await self.createSnapshot(id: UUID().uuidString)
    }

    func createSnapshot(id snapshotId: String) async throws -> String {
        let now = Date()
        self.snapshotInfos[snapshotId] = SnapshotInfo(
            id: snapshotId,
            processId: 0,
            createdAt: now,
            lastAccessedAt: now,
            sizeInBytes: 0,
            screenshotCount: 0,
            isActive: true
        )
        self.mostRecentSnapshotId = snapshotId
        return snapshotId
    }

    func storeDetectionResult(snapshotId: String, result: ElementDetectionResult) async throws {
        self.detectionResults[snapshotId] = result
        self.mostRecentSnapshotId = snapshotId
    }

    func storeUIAutomationSnapshot(_ snapshot: UIAutomationSnapshot, snapshotId: String) {
        self.automationSnapshots[snapshotId] = snapshot
    }

    func getDetectionResult(snapshotId: String) async throws -> ElementDetectionResult? {
        self.detectionResults[snapshotId]
    }

    func getMostRecentSnapshot() async -> String? {
        self.mostRecentSnapshotId
    }

    func getMostRecentSnapshot(applicationBundleId _: String) async -> String? {
        self.mostRecentSnapshotId
    }

    func listSnapshots() async throws -> [SnapshotInfo] {
        Array(self.snapshotInfos.values)
    }

    func cleanSnapshot(snapshotId: String) async throws {
        self.snapshotInfos.removeValue(forKey: snapshotId)
        self.detectionResults.removeValue(forKey: snapshotId)
        self.automationSnapshots.removeValue(forKey: snapshotId)
        if self.mostRecentSnapshotId == snapshotId {
            self.mostRecentSnapshotId = nil
        }
    }

    func cleanSnapshotsOlderThan(days _: Int) async throws -> Int {
        0
    }

    func cleanAllSnapshots() async throws -> Int {
        let count = self.snapshotInfos.count
        self.snapshotInfos.removeAll()
        self.detectionResults.removeAll()
        self.automationSnapshots.removeAll()
        self.mostRecentSnapshotId = nil
        return count
    }

    func getSnapshotStoragePath() -> String {
        "/tmp/peekaboo-snapshots"
    }

    func storeScreenshot(_: SnapshotScreenshotRequest) async throws {}

    func storeAnnotatedScreenshot(snapshotId _: String, annotatedScreenshotPath _: String) async throws {}

    func getElement(snapshotId _: String, elementId _: String) async throws -> PeekabooCore.UIElement? {
        nil
    }

    func findElements(snapshotId _: String, matching _: String) async throws -> [PeekabooCore.UIElement] {
        []
    }

    func getUIAutomationSnapshot(snapshotId: String) async throws -> UIAutomationSnapshot? {
        self.automationSnapshots[snapshotId]
    }
}

@MainActor
private final class CoreWindowTracker: WindowTrackingProviding {
    private let bounds: CGRect?

    init(bounds: CGRect?) {
        self.bounds = bounds
    }

    func windowBounds(for _: CGWindowID) -> CGRect? {
        self.bounds
    }
}
