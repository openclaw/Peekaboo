import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe, .regression))
struct SnapshotNotFoundRegressionTests {
    @Test
    func `click --snapshot errors when snapshot was cleaned`() async throws {
        let context = await MainActor.run { TestServicesFactory.makeAutomationTestContext() }

        let snapshotId = try await self.makeSnapshot(with: context.snapshots)
        try await context.snapshots.cleanSnapshot(snapshotId: snapshotId)

        let result = try await InProcessCommandRunner.run(
            ["click", "Single Click", "--snapshot", snapshotId, "--json"],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(response.success == false)
        #expect(response.error?.code == ErrorCode.SNAPSHOT_NOT_FOUND.rawValue)
    }

    @Test
    func `move --on --snapshot errors when snapshot was cleaned`() async throws {
        let context = await MainActor.run { TestServicesFactory.makeAutomationTestContext() }

        let snapshotId = try await self.makeSnapshot(with: context.snapshots)
        try await context.snapshots.cleanSnapshot(snapshotId: snapshotId)

        let result = try await InProcessCommandRunner.run(
            ["move", "--on", "B1", "--snapshot", snapshotId, "--foreground", "--json"],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(response.success == false)
        #expect(response.error?.code == ErrorCode.SNAPSHOT_NOT_FOUND.rawValue)
    }

    @Test
    func `scroll --on --snapshot errors when snapshot was cleaned`() async throws {
        let context = await MainActor.run { TestServicesFactory.makeAutomationTestContext() }

        let snapshotId = try await self.makeSnapshot(with: context.snapshots)
        try await context.snapshots.cleanSnapshot(snapshotId: snapshotId)

        let result = try await InProcessCommandRunner.run(
            ["scroll", "--direction", "down", "--on", "B1", "--snapshot", snapshotId, "--json"],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(response.success == false)
        #expect(response.error?.code == ErrorCode.SNAPSHOT_NOT_FOUND.rawValue)
    }

    @Test
    func `drag --from/--to --snapshot errors when snapshot was cleaned`() async throws {
        let context = await MainActor.run { TestServicesFactory.makeAutomationTestContext() }

        let snapshotId = try await self.makeSnapshot(with: context.snapshots)
        try await context.snapshots.cleanSnapshot(snapshotId: snapshotId)

        let result = try await InProcessCommandRunner.run(
            [
                "drag", "--from", "B1", "--to", "B1", "--snapshot", snapshotId,
                "--foreground", "--json",
            ],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(response.success == false)
        #expect(response.error?.code == ErrorCode.SNAPSHOT_NOT_FOUND.rawValue)
    }

    @Test
    func `swipe --from/--to --snapshot errors when snapshot was cleaned`() async throws {
        let context = await MainActor.run { TestServicesFactory.makeAutomationTestContext() }

        let snapshotId = try await self.makeSnapshot(with: context.snapshots)
        try await context.snapshots.cleanSnapshot(snapshotId: snapshotId)

        let result = try await InProcessCommandRunner.run(
            ["drag", "--from", "B1", "--to", "B1", "--snapshot", snapshotId, "--foreground", "--json"],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(response.success == false)
        #expect(response.error?.code == ErrorCode.SNAPSHOT_NOT_FOUND.rawValue)
    }

    @Test
    func `type --snapshot errors when snapshot was cleaned`() async throws {
        let context = await MainActor.run { TestServicesFactory.makeAutomationTestContext() }

        let snapshotId = try await self.makeSnapshot(with: context.snapshots)
        try await context.snapshots.cleanSnapshot(snapshotId: snapshotId)

        let result = try await InProcessCommandRunner.run(
            ["type", "Hello", "--snapshot", snapshotId, "--json", "--no-auto-focus"],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(response.success == false)
        #expect(response.error?.code == ErrorCode.SNAPSHOT_NOT_FOUND.rawValue)
    }

    @Test
    func `hotkey --snapshot errors when snapshot was cleaned`() async throws {
        let context = await MainActor.run { TestServicesFactory.makeAutomationTestContext() }

        let snapshotId = try await self.makeSnapshot(with: context.snapshots)
        try await context.snapshots.cleanSnapshot(snapshotId: snapshotId)

        let result = try await InProcessCommandRunner.run(
            ["press", "cmd+c", "--snapshot", snapshotId, "--json", "--no-auto-focus"],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(response.success == false)
        #expect(response.error?.code == ErrorCode.SNAPSHOT_NOT_FOUND.rawValue)
    }

    @Test
    func `press --snapshot errors when snapshot was cleaned`() async throws {
        let context = await MainActor.run { TestServicesFactory.makeAutomationTestContext() }

        let snapshotId = try await self.makeSnapshot(with: context.snapshots)
        try await context.snapshots.cleanSnapshot(snapshotId: snapshotId)

        let result = try await InProcessCommandRunner.run(
            ["press", "tab", "--snapshot", snapshotId, "--json", "--no-auto-focus"],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(response.success == false)
        #expect(response.error?.code == ErrorCode.SNAPSHOT_NOT_FOUND.rawValue)
    }

    @Test
    @MainActor
    func `shared snapshot fixture refuses storage before producer creation`() async throws {
        let snapshots = StubSnapshotManager()
        let unownedSnapshotID = SnapshotReference.generate().rawValue
        let detection = ElementDetectionResult(
            snapshotId: unownedSnapshotID,
            screenshotPath: "/tmp/screenshot.png",
            elements: DetectedElements(),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 0, method: "stub")
        )

        #expect(try await !snapshots.ownsSnapshot(snapshotId: unownedSnapshotID))
        await #expect(throws: SnapshotError.self) {
            try await snapshots.storeDetectionResult(snapshotId: unownedSnapshotID, result: detection)
        }
        await #expect(throws: SnapshotError.self) {
            try await snapshots.storeScreenshot(.init(
                snapshotId: unownedSnapshotID,
                screenshotPath: "/tmp/screenshot.png",
                applicationBundleId: nil,
                applicationProcessId: nil,
                applicationName: nil,
                windowTitle: nil,
                windowBounds: nil
            ))
        }
        await #expect(throws: SnapshotError.self) {
            try await snapshots.storeAnnotatedScreenshot(
                snapshotId: unownedSnapshotID,
                annotatedScreenshotPath: "/tmp/annotated.png"
            )
        }

        let ownedSnapshotID = try await snapshots.createSnapshot()
        #expect(try await snapshots.ownsSnapshot(snapshotId: ownedSnapshotID))
    }

    private func makeSnapshot(with snapshots: StubSnapshotManager) async throws -> String {
        let snapshotId = try await snapshots.createSnapshot()

        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Single Click",
            bounds: CGRect(x: 50, y: 70, width: 120, height: 40)
        )
        let detection = ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/screenshot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 1, method: "stub")
        )
        try await snapshots.storeDetectionResult(snapshotId: snapshotId, result: detection)

        return snapshotId
    }
}
