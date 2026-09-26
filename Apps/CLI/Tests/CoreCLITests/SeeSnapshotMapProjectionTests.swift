import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooCLI

@MainActor
@Suite(.tags(.safe))
struct SeeSnapshotMapProjectionTests {
    @Test
    func `reusable memory snapshot keeps inline elements and authority without a map file`() async throws {
        let snapshots = InMemorySnapshotManager()
        let snapshotId = try await snapshots.createSnapshot()
        let detection = Self.detection(snapshotId: snapshotId)
        try await snapshots.storeDetectionResult(snapshotId: snapshotId, result: detection)
        let result = try Self.project(detection, snapshots: snapshots)

        #expect(result.ui_map.isEmpty)
        Self.expectReusable(result, snapshotId: snapshotId)
        #expect(try await snapshots.getElement(snapshotId: snapshotId, elementId: "field")?.value == "synthetic text")
        #expect(try await snapshots.ownsSnapshot(snapshotId: snapshotId))
        #expect(await snapshots.getMostRecentSnapshot() == snapshotId)
    }

    @Test
    func `disk snapshot reports its real map through the recording wrapper`() async throws {
        let storage = Self.temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let snapshots = SnapshotManager(snapshotStorageURL: storage)
        let snapshotId = try await snapshots.createSnapshot()
        let detection = Self.detection(snapshotId: snapshotId)
        try await snapshots.storeDetectionResult(snapshotId: snapshotId, result: detection)
        let recording = SnapshotMutationRecordingManager(wrapping: snapshots)
        let expected = storage.appendingPathComponent(snapshotId).appendingPathComponent("snapshot.json")

        let result = try Self.project(detection, snapshots: recording)

        #expect(result.ui_map == expected.path)
        Self.expectReusable(result, snapshotId: snapshotId)
        let persisted = try JSONCoding.makeDecoder().decode(UIAutomationSnapshot.self, from: Data(contentsOf: expected))
        #expect(persisted.uiMap["field"]?.value == result.ui_elements.first?.value)

        try FileManager.default.removeItem(at: expected)
        let missing = try Self.project(detection, snapshots: recording)
        #expect(missing.ui_map.isEmpty)
        Self.expectReusable(missing, snapshotId: snapshotId)
    }

    @Test
    func `remote projection never substitutes an available local map for its producer`() async throws {
        let storage = Self.temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let local = SnapshotManager(snapshotStorageURL: storage)
        let snapshotId = try await local.createSnapshot()
        let detection = Self.detection(snapshotId: snapshotId)
        try await local.storeDetectionResult(snapshotId: snapshotId, result: detection)
        let remote = RemoteSnapshotManager(
            client: PeekabooBridgeClient(socketPath: storage.appendingPathComponent("absent.sock").path),
            supportsProducerBoundSnapshotReferences: true
        )

        let result = try Self.project(detection, snapshots: remote)

        #expect(local.getPersistedSnapshotMapPath(snapshotId: snapshotId) != nil)
        #expect(result.ui_map.isEmpty)
        Self.expectReusable(result, snapshotId: snapshotId)
    }

    @Test
    func `application partial projection never advertises even an existing disk map`() async throws {
        let storage = Self.temporaryStorage()
        defer { try? FileManager.default.removeItem(at: storage) }
        let snapshots = SnapshotManager(snapshotStorageURL: storage)
        let snapshotId = try await snapshots.createSnapshot()
        let result = try Self.project(
            Self.detection(snapshotId: snapshotId, partial: true),
            snapshots: snapshots
        )

        #expect(snapshots.getPersistedSnapshotMapPath(snapshotId: snapshotId) != nil)
        #expect(result.ui_map.isEmpty)
        #expect(result.snapshot_id == nil)
        #expect(!result.snapshot_reusable)
        #expect(!result.mutation_targeting_available)
        #expect(result.semantic_scope == "application_partial")
        #expect(result.interactable_count == 0)
        #expect(result.ui_elements.first?.is_actionable == false)
        #expect(result.ui_elements.first?.is_value_settable == nil)
    }

    private static func expectReusable(_ result: SeeResult, snapshotId: String) {
        #expect(result.snapshot_id == snapshotId)
        #expect(result.snapshot_reusable)
        #expect(result.mutation_targeting_available)
        #expect(result.semantic_scope == "exact_or_requested")
        #expect(result.element_count == 1)
        #expect(result.interactable_count == 1)
        #expect(result.ui_elements.first?.id == "field")
        #expect(result.ui_elements.first?.value == "synthetic text")
        #expect(result.ui_elements.first?.is_actionable == true)
        #expect(result.ui_elements.first?.is_value_settable == true)
        #expect(result.screenshot_raw.isEmpty)
        #expect(result.screenshot_annotated.isEmpty)
    }

    private static func project(
        _ detection: ElementDetectionResult,
        snapshots: any SnapshotManagerProtocol
    ) throws -> SeeResult {
        let context = SeeCommandRenderContext(
            snapshotId: detection.snapshotId,
            screenshotPath: "",
            screenshotData: nil,
            annotatedPath: nil,
            annotatedData: nil,
            metadata: detection.metadata,
            elements: detection.elements,
            coordinateContext: nil,
            analysis: nil,
            executionTime: 0,
            observation: nil,
            menuBar: nil,
            receipt: .none
        )
        var command = SeeCommand()
        command.mode = .window
        command.runtimeOptions.jsonOutput = true
        let result = command.makeJSONResult(
            context: context,
            snapshotPaths: command.snapshotPaths(for: context, snapshots: snapshots)
        )
        #expect(command.runtime == nil)
        return try JSONDecoder().decode(SeeResult.self, from: JSONEncoder().encode(result))
    }

    private static func detection(snapshotId: String, partial: Bool = false) -> ElementDetectionResult {
        ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "",
            elements: DetectedElements(textFields: [DetectedElement(
                id: "field",
                type: .textField,
                label: "Editor",
                value: "synthetic text",
                bounds: CGRect(x: 10, y: 20, width: 150, height: 24),
                attributes: ["isActionable": "true", "isValueSettable": "true"]
            )]),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 1,
                method: "test",
                warnings: partial ? [DetectionMetadata.applicationScopedAccessibilityFallbackWarning] : []
            )
        )
    }

    private static func temporaryStorage() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("peekaboo-see-map-\(UUID().uuidString)", isDirectory: true)
    }
}
