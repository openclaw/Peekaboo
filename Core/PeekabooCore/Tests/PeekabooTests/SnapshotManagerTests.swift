import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore
@testable import PeekabooVisualizer

@MainActor
struct SnapshotManagerTests {
    let snapshotManager = SnapshotManager()

    @Test
    func `Create and retrieve snapshot`() async throws {
        // Create a snapshot
        let snapshotId = try await snapshotManager.createSnapshot()
        #expect(SnapshotReference(rawValue: snapshotId)?.rawValue == snapshotId)
        #expect(snapshotId.hasPrefix("ps1_"))
        #expect(snapshotId.utf8.count == 36)
        #expect(snapshotId.utf8.dropFirst(4).allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        })
        #expect(try await self.snapshotManager.ownsSnapshot(snapshotId: snapshotId))

        // Verify it shows up in the list
        let snapshots = try await snapshotManager.listSnapshots()
        #expect(snapshots.contains { $0.id == snapshotId })

        // Clean up
        try await self.snapshotManager.cleanSnapshot(snapshotId: snapshotId)
        #expect(try await !self.snapshotManager.ownsSnapshot(snapshotId: snapshotId))
    }

    @Test
    func `Store and retrieve detection result`() async throws {
        // Create a snapshot
        let snapshotId = try await snapshotManager.createSnapshot()

        // Create a mock detection result
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Test Button",
            bounds: CGRect(x: 100, y: 100, width: 100, height: 50))

        let elements = DetectedElements(buttons: [element])
        let metadata = DetectionMetadata(
            detectionTime: 0.5,
            elementCount: 1,
            method: "test")

        let result = ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/test.png",
            elements: elements,
            metadata: metadata)

        // Store the result
        try await snapshotManager.storeDetectionResult(snapshotId: snapshotId, result: result)

        // Retrieve it
        let retrieved = try await snapshotManager.getDetectionResult(snapshotId: snapshotId)
        #expect(retrieved != nil)
        #expect(retrieved?.elements.buttons.count == 1)
        #expect(retrieved?.elements.buttons.first?.id == "B1")
        #expect(retrieved?.elements.buttons.first?.label == "Test Button")

        // Clean up
        try await self.snapshotManager.cleanSnapshot(snapshotId: snapshotId)
    }

    @Test
    func `Store detection result preserves typed window context`() async throws {
        let snapshotId = try await snapshotManager.createSnapshot()
        let windowBounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let metadata = DetectionMetadata(
            detectionTime: 0.1,
            elementCount: 0,
            method: "test",
            windowContext: WindowContext(
                applicationName: "TextEdit",
                applicationBundleId: "com.apple.TextEdit",
                applicationProcessId: 1234,
                windowTitle: "Notes",
                windowID: 777,
                windowBounds: windowBounds))
        let result = ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/test.png",
            elements: DetectedElements(),
            metadata: metadata)

        try await snapshotManager.storeDetectionResult(snapshotId: snapshotId, result: result)

        let snapshot = try await snapshotManager.getUIAutomationSnapshot(snapshotId: snapshotId)
        #expect(snapshot?.applicationName == "TextEdit")
        #expect(snapshot?.applicationBundleId == "com.apple.TextEdit")
        #expect(snapshot?.applicationProcessId == 1234)
        #expect(snapshot?.windowTitle == "Notes")
        #expect(snapshot?.windowID == CGWindowID(777))
        #expect(snapshot?.windowBounds == windowBounds)

        try await self.snapshotManager.cleanSnapshot(snapshotId: snapshotId)
    }

    @Test
    func `In-memory snapshot manager preserves typed window context`() async throws {
        let manager = InMemorySnapshotManager()
        let snapshotId = try await manager.createSnapshot()
        let windowBounds = CGRect(x: 30, y: 40, width: 500, height: 400)
        let metadata = DetectionMetadata(
            detectionTime: 0.1,
            elementCount: 0,
            method: "test",
            windowContext: WindowContext(
                applicationName: "Safari",
                applicationBundleId: "com.apple.Safari",
                applicationProcessId: 4321,
                windowTitle: "Example",
                windowID: 888,
                windowBounds: windowBounds))
        let result = ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/test.png",
            elements: DetectedElements(),
            metadata: metadata)

        try await manager.storeDetectionResult(snapshotId: snapshotId, result: result)

        let snapshot = try await manager.getUIAutomationSnapshot(snapshotId: snapshotId)
        #expect(snapshot?.applicationName == "Safari")
        #expect(snapshot?.applicationBundleId == "com.apple.Safari")
        #expect(snapshot?.applicationProcessId == 4321)
        #expect(snapshot?.windowTitle == "Example")
        #expect(snapshot?.windowID == CGWindowID(888))
        #expect(snapshot?.windowBounds == windowBounds)
    }

    @Test
    func `Snapshot managers preserve accessibility control metadata`() async throws {
        try await Self.verifyAccessibilityMetadataRoundTrip(SnapshotManager())
        try await Self.verifyAccessibilityMetadataRoundTrip(InMemorySnapshotManager())
    }

    @Test
    func `UI element decodes the legacy v1 metadata shape`() throws {
        let legacy = UIElement(
            id: "B1",
            elementId: "element_0",
            role: "AXButton",
            label: "Save",
            frame: CGRect(x: 10, y: 20, width: 80, height: 30),
            isActionable: true)
        let encoded = try JSONEncoder().encode(legacy)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["isEnabled"] == nil)
        #expect(object["isSelected"] == nil)
        #expect(object["isValueSettable"] == nil)

        let decoded = try JSONDecoder().decode(UIElement.self, from: encoded)
        #expect(decoded.id == "B1")
        #expect(decoded.isActionable)
        #expect(decoded.isEnabled == nil)
        #expect(decoded.isSelected == nil)
        #expect(decoded.isValueSettable == nil)
    }

    @Test
    func `Find elements by query`() async throws {
        // Create a snapshot
        let snapshotId = try await snapshotManager.createSnapshot()

        // Create mock detection elements
        let element1 = DetectedElement(
            id: "B1",
            type: .button,
            label: "Save Document",
            bounds: CGRect(x: 100, y: 100, width: 100, height: 50))

        let element2 = DetectedElement(
            id: "B2",
            type: .button,
            label: "Cancel Operation",
            bounds: CGRect(x: 210, y: 100, width: 100, height: 50))

        let elements = DetectedElements(buttons: [element1, element2])
        let metadata = DetectionMetadata(
            detectionTime: 0.5,
            elementCount: 2,
            method: "test")

        let result = ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/test.png",
            elements: elements,
            metadata: metadata)

        // Store the detection result which will create the UI map
        try await snapshotManager.storeDetectionResult(snapshotId: snapshotId, result: result)

        // Now find elements by query
        let foundElements = try await snapshotManager.findElements(snapshotId: snapshotId, matching: "save")
        #expect(foundElements.count == 1)
        #expect(foundElements.first?.label?.lowercased().contains("save") == true)

        // Find by partial match
        let cancelElements = try await snapshotManager.findElements(snapshotId: snapshotId, matching: "cancel")
        #expect(cancelElements.count == 1)
        #expect(cancelElements.first?.label?.lowercased().contains("cancel") == true)

        // Clean up
        try await self.snapshotManager.cleanSnapshot(snapshotId: snapshotId)
    }

    @Test
    func `Get most recent snapshot`() async throws {
        // Create two snapshots with a delay
        let snapshot1 = try await snapshotManager.createSnapshot()
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        let snapshot2 = try await snapshotManager.createSnapshot()

        // The most recent should be snapshot2
        let mostRecent = await snapshotManager.getMostRecentSnapshot()
        #expect(mostRecent == snapshot2)

        // Clean up
        try await self.snapshotManager.cleanSnapshot(snapshotId: snapshot1)
        try await self.snapshotManager.cleanSnapshot(snapshotId: snapshot2)
    }

    @Test
    func `Snapshot cleanup`() async throws {
        // Create multiple snapshots
        let snapshot1 = try await snapshotManager.createSnapshot()
        let snapshot2 = try await snapshotManager.createSnapshot()
        let snapshot3 = try await snapshotManager.createSnapshot()

        // Clean all snapshots
        let cleanedCount = try await snapshotManager.cleanAllSnapshots()
        #expect(cleanedCount >= 3)

        // Verify they're gone
        let snapshots = try await snapshotManager.listSnapshots()
        #expect(!snapshots.contains { $0.id == snapshot1 })
        #expect(!snapshots.contains { $0.id == snapshot2 })
        #expect(!snapshots.contains { $0.id == snapshot3 })
    }

    @Test
    func `Mutation lease requiring observation blocks mutation but preserves reads`() async throws {
        let manager = SnapshotManager()
        let snapshotId = try await manager.createSnapshot()
        let lease = try await manager.beginSnapshotMutation(snapshotId: snapshotId)
        #expect(try await manager.getUIAutomationSnapshot(snapshotId: snapshotId) != nil)

        try await manager.finishSnapshotMutation(lease, requiresFreshObservation: true)
        try await manager.finishSnapshotMutation(lease, requiresFreshObservation: false)

        // Consumption is mutation-specific: diagnostics and other read-only users retain evidence.
        #expect(try await manager.getUIAutomationSnapshot(snapshotId: snapshotId) != nil)
        do {
            _ = try await manager.beginSnapshotMutation(snapshotId: snapshotId)
            Issue.record("Expected consumed snapshot to refuse a second mutation")
        } catch let PeekabooError.snapshotStale(message) {
            #expect(message.contains("fresh observation"))
        }
        try await manager.cleanSnapshot(snapshotId: snapshotId)
    }

    @Test
    func `Confirmed mutation lease releases snapshot and pending lease blocks overlap`() async throws {
        let manager = InMemorySnapshotManager()
        let snapshotId = try await manager.createSnapshot()
        let firstLease = try await manager.beginSnapshotMutation(snapshotId: snapshotId)

        await #expect(throws: PeekabooError.self) {
            _ = try await manager.beginSnapshotMutation(snapshotId: snapshotId)
        }

        try await manager.finishSnapshotMutation(firstLease, requiresFreshObservation: false)
        let secondLease = try await manager.beginSnapshotMutation(snapshotId: snapshotId)
        #expect(secondLease != firstLease)
        try await manager.finishSnapshotMutation(secondLease, requiresFreshObservation: true)
        try await manager.finishSnapshotMutation(secondLease, requiresFreshObservation: false)
        await #expect(throws: PeekabooError.self) {
            _ = try await manager.beginSnapshotMutation(snapshotId: snapshotId)
        }
    }

    private static func verifyAccessibilityMetadataRoundTrip(
        _ manager: any SnapshotManagerProtocol) async throws
    {
        let snapshotId = try await manager.createSnapshot()
        let slider = DetectedElement(
            id: "elem_1",
            type: .slider,
            label: "Liquid Glass Tint Amount",
            value: "0.5",
            bounds: CGRect(x: 10, y: 20, width: 200, height: 16),
            isEnabled: true,
            attributes: [
                "role": "AXSlider",
                "description": "Liquid Glass Tint Amount",
                "help": "Adjust tint",
                "roleDescription": "slider",
                "identifier": "tint-amount",
                "isActionable": "true",
                "isValueSettable": "true",
                "axEnabledKnown": "true",
            ])
        let result = ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/appearance.png",
            elements: DetectedElements(sliders: [slider]),
            metadata: DetectionMetadata(detectionTime: 0.1, elementCount: 1, method: "test"))

        try await manager.storeDetectionResult(snapshotId: snapshotId, result: result)

        let stored = try #require(try await manager.getUIAutomationSnapshot(snapshotId: snapshotId))
        let storedSlider = try #require(stored.uiMap[slider.id])
        #expect(storedSlider.role == "AXSlider")
        #expect(storedSlider.label == "Liquid Glass Tint Amount")
        #expect(storedSlider.value == "0.5")
        #expect(storedSlider.description == "Liquid Glass Tint Amount")
        #expect(storedSlider.help == "Adjust tint")
        #expect(storedSlider.roleDescription == "slider")
        #expect(storedSlider.identifier == "tint-amount")
        #expect(storedSlider.isActionable)
        #expect(storedSlider.isEnabled == true)
        #expect(storedSlider.isValueSettable == true)

        let hydrated = try #require(try await manager.getDetectionResult(snapshotId: snapshotId))
        let hydratedSlider = try #require(hydrated.elements.sliders.first)
        #expect(hydratedSlider.value == "0.5")
        #expect(hydratedSlider.attributes["description"] == "Liquid Glass Tint Amount")
        #expect(hydratedSlider.attributes["help"] == "Adjust tint")
        #expect(hydratedSlider.attributes["roleDescription"] == "slider")
        #expect(hydratedSlider.knownIsEnabled == true)
        #expect(hydratedSlider.isActionable)
        #expect(hydratedSlider.isValueSettable == true)
        try await manager.cleanSnapshot(snapshotId: snapshotId)
    }
}
