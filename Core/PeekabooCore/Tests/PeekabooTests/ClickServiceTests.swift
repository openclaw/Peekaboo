import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore
@testable import PeekabooFoundation
@testable import PeekabooVisualizer

@Suite(
    .tags(.ui, .automation),
    .enabled(if: TestEnvironment.runInputAutomationScenarios))
@MainActor
struct ClickServiceTests {
    @MainActor
    struct InitializationTests {
        @Test
        func `ClickService initializes with snapshot manager dependency`() {
            let snapshotManager = MockSnapshotManager()
            let service: ClickService? = ClickService(snapshotManager: snapshotManager)
            #expect(service != nil)
        }
    }

    @MainActor
    struct CoordinateClickingTests {
        @Test
        func `Click performs at specified screen coordinates without errors`() async throws {
            let snapshotManager = MockSnapshotManager()
            let service = ClickService(
                snapshotManager: snapshotManager,
                inputPolicy: UIInputPolicy(defaultStrategy: .synthFirst))

            let point = CGPoint(x: 100, y: 100)

            // This will attempt to click at the coordinates
            // In a test environment, we can't verify the actual click happened,
            // but we can verify no errors are thrown
            try await service.click(
                target: .coordinates(point),
                clickType: .single,
                snapshotId: nil)
        }
    }

    @MainActor
    struct ElementClickingTests {
        @Test
        func `Click finds and clicks element by ID using snapshot detection results`() async throws {
            let snapshotManager = MockSnapshotManager()

            // Create mock detection result
            let mockElement = DetectedElement(
                id: "test-button",
                type: .button,
                label: "Test Button",
                value: nil,
                bounds: CGRect(x: 50, y: 50, width: 100, height: 50),
                isEnabled: true,
                isSelected: nil,
                attributes: [:])

            let detectedElements = DetectedElements(
                buttons: [mockElement])

            let detectionResult = ElementDetectionResult(
                snapshotId: "test-snapshot",
                screenshotPath: "/tmp/test.png",
                elements: detectedElements,
                metadata: DetectionMetadata(
                    detectionTime: 0.1,
                    elementCount: 1,
                    method: "AXorcist"))

            snapshotManager.primeDetectionResult(detectionResult)

            let service = ClickService(
                snapshotManager: snapshotManager,
                inputPolicy: UIInputPolicy(defaultStrategy: .synthFirst))

            // Should find element in session and click at its center
            try await service.click(
                target: .elementId("test-button"),
                clickType: .single,
                snapshotId: "test-snapshot")
        }

        @Test
        func `Click element by ID not found throws specific error`() async throws {
            let snapshotManager = MockSnapshotManager()
            let service = ClickService(
                snapshotManager: snapshotManager,
                inputPolicy: UIInputPolicy(defaultStrategy: .synthFirst))
            let nonExistentId = "non-existent-button"

            // NotFoundError factories now bridge to the public PeekabooError enum.
            await #expect(throws: PeekabooError.self) {
                try await service.click(
                    target: .elementId(nonExistentId),
                    clickType: .single,
                    snapshotId: nil)
            }
        }
    }

    @MainActor
    struct ClickTypeTests {
        @Test
        func `Click supports single, double, right-click, and long-press types`() async throws {
            let snapshotManager = MockSnapshotManager()
            let service = ClickService(snapshotManager: snapshotManager)

            let point = CGPoint(x: 100, y: 100)

            // Test single click
            try await service.click(
                target: .coordinates(point),
                clickType: .single,
                snapshotId: nil)

            // Test right click
            try await service.click(
                target: .coordinates(point),
                clickType: .right,
                snapshotId: nil)

            // Test double click
            try await service.click(
                target: .coordinates(point),
                clickType: .double,
                snapshotId: nil)

            try await service.click(
                target: .coordinates(point),
                clickType: .longPress,
                snapshotId: nil)
        }
    }

    @Test
    func `Click element by query matches partial text`() async throws {
        let snapshotManager = MockSnapshotManager()

        // Create mock detection result with searchable element
        let mockElement = DetectedElement(
            id: "submit-btn",
            type: .button,
            label: "Submit Form",
            value: nil,
            bounds: CGRect(x: 100, y: 100, width: 80, height: 40),
            isEnabled: true,
            isSelected: nil,
            attributes: [:])

        let detectedElements = DetectedElements(
            buttons: [mockElement])

        let detectionResult = ElementDetectionResult(
            snapshotId: "test-snapshot",
            screenshotPath: "/tmp/test.png",
            elements: detectedElements,
            metadata: DetectionMetadata(
                detectionTime: 0.1,
                elementCount: 1,
                method: "AXorcist"))

        snapshotManager.primeDetectionResult(detectionResult)

        let service = ClickService(
            snapshotManager: snapshotManager,
            inputPolicy: UIInputPolicy(defaultStrategy: .synthFirst))

        // Should find element by query and click it
        try await service.click(
            target: .query("submit"),
            clickType: .single,
            snapshotId: "test-snapshot")
    }
}

// MARK: - Mock Snapshot Manager

@MainActor
private final class MockSnapshotManager: SnapshotManagerProtocol {
    private var mockDetectionResult: ElementDetectionResult?

    func primeDetectionResult(_ result: ElementDetectionResult?) {
        self.mockDetectionResult = result
    }

    func createSnapshot() async throws -> String {
        "test-snapshot-\(UUID().uuidString)"
    }

    func storeDetectionResult(snapshotId: String, result: ElementDetectionResult) async throws {
        // No-op for tests
    }

    func getDetectionResult(snapshotId: String) async throws -> ElementDetectionResult? {
        self.mockDetectionResult
    }

    func getMostRecentSnapshot() async -> String? {
        nil
    }

    func getMostRecentSnapshot(applicationBundleId _: String) async -> String? {
        nil
    }

    func invalidateImplicitLatestSnapshot() async throws -> String? {
        nil
    }

    func listSnapshots() async throws -> [SnapshotInfo] {
        []
    }

    func cleanSnapshot(snapshotId: String) async throws {
        // No-op for tests
    }

    func cleanSnapshotsOlderThan(days: Int) async throws -> Int {
        0
    }

    func cleanAllSnapshots() async throws -> Int {
        0
    }

    nonisolated func getSnapshotStoragePath() -> String {
        "/tmp/test-snapshots"
    }

    func storeScreenshot(_ request: SnapshotScreenshotRequest) async throws {
        // No-op for tests
        _ = request
    }

    func storeAnnotatedScreenshot(snapshotId: String, annotatedScreenshotPath: String) async throws {
        _ = snapshotId
        _ = annotatedScreenshotPath
    }

    func getElement(snapshotId: String, elementId: String) async throws -> UIElement? {
        nil
    }

    func findElements(snapshotId: String, matching query: String) async throws -> [UIElement] {
        []
    }

    func getUIAutomationSnapshot(snapshotId: String) async throws -> UIAutomationSnapshot? {
        nil
    }
}
