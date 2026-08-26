import CoreGraphics
import Foundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooAutomation
@testable import PeekabooCore

@Suite(.tags(.safe))
struct UIAutomationServiceWaitTests {
    @Test
    @MainActor
    func `Coordinates return immediately`() async throws {
        let service = UIAutomationService(snapshotManager: InMemorySnapshotManager())

        let result = try await service.waitForElement(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            timeout: 1.0,
            snapshotId: nil)

        #expect(result.found)
        #expect(result.waitTime == 0)
    }

    @Test
    @MainActor
    func `Element ID resolves from snapshot cache`() async throws {
        let elements = DetectedElements(
            buttons: [DetectedElement(
                id: "B42",
                type: .button,
                label: "Launch",
                value: nil,
                bounds: CGRect(x: 100, y: 200, width: 50, height: 20))])
        let detection = Self.makeDetectionResult(elements: elements)

        let snapshots = try await InMemorySnapshotManager.containing(detection)
        let service = UIAutomationService(snapshotManager: snapshots)

        let result = try await service.waitForElement(
            target: .elementId("B42"),
            timeout: 1.0,
            snapshotId: detection.snapshotId)

        #expect(result.found)
        #expect(result.element?.id == "B42")
        #expect(result.waitTime < 0.1)
    }

    @Test
    @MainActor
    func `Query resolves using snapshot detection cache`() async throws {
        let elements = DetectedElements(
            buttons: [DetectedElement(
                id: "B1",
                type: .button,
                label: "Submit",
                value: nil,
                bounds: CGRect(x: 10, y: 10, width: 80, height: 30))])
        let detection = Self.makeDetectionResult(elements: elements)

        let snapshots = try await InMemorySnapshotManager.containing(detection)
        let service = UIAutomationService(snapshotManager: snapshots)

        let result = try await service.waitForElement(
            target: .query("submit"),
            timeout: 1.0,
            snapshotId: detection.snapshotId)

        #expect(result.found)
        #expect(result.element?.label?.lowercased() == "submit")
    }

    @Test
    @MainActor
    func `Query resolves via element identifier attribute`() async throws {
        let elements = DetectedElements(
            sliders: [DetectedElement(
                id: "S1",
                type: .slider,
                label: "Slider",
                value: nil,
                bounds: CGRect(x: 10, y: 10, width: 200, height: 24),
                attributes: ["identifier": "continuous-slider"])])
        let detection = Self.makeDetectionResult(elements: elements)

        let snapshots = try await InMemorySnapshotManager.containing(detection)
        let service = UIAutomationService(snapshotManager: snapshots)

        let result = try await service.waitForElement(
            target: .query("continuous-slider"),
            timeout: 1.0,
            snapshotId: detection.snapshotId)

        #expect(result.found)
        #expect(result.element?.id == "S1")
    }

    // MARK: - Helpers

    private static func makeDetectionResult(
        snapshotId: String = SnapshotReferenceFixtures.id(100),
        elements: DetectedElements) -> ElementDetectionResult
    {
        let metadata = DetectionMetadata(
            detectionTime: 0.01,
            elementCount: elements.all.count,
            method: "test")

        return ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/test.png",
            elements: elements,
            metadata: metadata)
    }
}
