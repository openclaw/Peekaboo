import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

#if !PEEKABOO_SKIP_AUTOMATION
@Suite(
    .serialized,
    .tags(.safe),
    .enabled(if: CLITestEnvironment.runAutomationRead)
)
struct MoveCommandTests {
    @Test
    func `move --help lists options`() async throws {
        let context = await self.makeContext()
        let result = try await self.runMove(arguments: ["--help"], context: context)

        #expect(result.exitStatus == 0)
        #expect(self.output(from: result).contains("Move the mouse cursor"))
    }

    @Test
    func `Coordinate moves call automation service`() async throws {
        let context = await self.makeContext()
        let result = try await self.runMove(
            arguments: ["100,200", "--duration", "750", "--steps", "10"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let moveCalls = await self.automationState(context) { $0.moveMouseCalls }
        let call = try #require(moveCalls.first)
        #expect(call.destination == CGPoint(x: 100, y: 200))
        #expect(call.duration == 750)
        #expect(call.steps == 10)
        #expect(call.profile == .human())
    }

    @Test
    func `Move command requires a target`() async throws {
        let context = await self.makeContext()
        let result = try await self.runMove(arguments: [], context: context)

        #expect(result.exitStatus == 0)
        let moveCalls = await self.automationState(context) { $0.moveMouseCalls }
        #expect(moveCalls.isEmpty)
    }

    @Test
    func `Move by element ID resolves using stored detection results`() async throws {
        let context = await self.makeContext()
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Submit",
            bounds: CGRect(x: 50, y: 70, width: 120, height: 40)
        )
        let detection = ElementDetectionResult(
            snapshotId: "snapshot-id",
            screenshotPath: "/tmp/screenshot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 1, method: "stub")
        )
        try await context.snapshots.storeDetectionResult(snapshotId: "snapshot-id", result: detection)

        let result = try await self.runMove(
            arguments: ["--on", "B1", "--snapshot", "snapshot-id", "--json"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let moveCalls = await self.automationState(context) { $0.moveMouseCalls }
        let call = try #require(moveCalls.first)
        #expect(call.destination.x == element.bounds.midX)
        #expect(call.destination.y == element.bounds.midY)
        #expect(call.profile == .linear)
    }

    @Test
    func `Move by element ID accepts id alias`() async throws {
        let context = await self.makeContext()
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Submit",
            bounds: CGRect(x: 50, y: 70, width: 120, height: 40)
        )
        let detection = ElementDetectionResult(
            snapshotId: "snapshot-id",
            screenshotPath: "/tmp/screenshot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 1, method: "stub")
        )
        try await context.snapshots.storeDetectionResult(snapshotId: "snapshot-id", result: detection)

        let result = try await self.runMove(
            arguments: ["--id", "B1", "--snapshot", "snapshot-id", "--json"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let moveCalls = await self.automationState(context) { $0.moveMouseCalls }
        let call = try #require(moveCalls.first)
        #expect(call.destination.x == element.bounds.midX)
        #expect(call.destination.y == element.bounds.midY)
    }

    @Test
    func `Move by query waits for element using automation service`() async throws {
        let snapshotId = "snapshot-query"
        let element = DetectedElement(
            id: "B2",
            type: .button,
            label: "Continue",
            bounds: CGRect(x: 200, y: 300, width: 80, height: 24)
        )
        let context = await self.makeContext { automation, snapshots in
            snapshots.mostRecentSnapshotId = snapshotId
            automation.setWaitForElementResult(
                WaitForElementResult(found: true, element: element, waitTime: 0.05),
                for: .query("Continue")
            )
        }
        let detection = ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/screenshot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 1, method: "stub")
        )
        try await context.snapshots.storeDetectionResult(snapshotId: snapshotId, result: detection)

        let result = try await self.runMove(arguments: ["--to", "Continue"], context: context)

        #expect(result.exitStatus == 0)
        let waitCalls = await self.automationState(context) { $0.waitForElementCalls }
        #expect(waitCalls.count == 1)
        let moveCalls = await self.automationState(context) { $0.moveMouseCalls }
        let call = try #require(moveCalls.first)
        #expect(call.destination == CGPoint(x: 240, y: 312)) // mid-point of element bounds
        #expect(call.profile == .linear)
    }

    @Test
    func `JSON output contains expected shape`() async throws {
        let context = await self.makeContext()
        let result = try await self.runMove(arguments: ["150,250", "--json"], context: context)

        #expect(result.exitStatus == 0)
        let data = try #require(self.output(from: result).data(using: .utf8))
        let payload = try JSONDecoder().decode(CodableJSONResponse<MoveResult>.self, from: data)
        #expect(payload.success)
        #expect(payload.data.success)
        #expect(payload.data.targetDescription.contains("Coordinates"))
        #expect(payload.data.targetLocation["x"] == 150)
        #expect(payload.data.targetLocation["y"] == 250)
        #expect(payload.data.profile == "linear")
    }

    @Test
    func `JSON output reports cursor location from automation service`() async throws {
        let context = await self.makeContext { automation, _ in
            automation.stubCurrentMouseLocation = CGPoint(x: 30, y: 40)
        }

        let result = try await self.runMove(arguments: ["33,44", "--json"], context: context)

        #expect(result.exitStatus == 0)
        let data = try #require(self.output(from: result).data(using: .utf8))
        let payload = try JSONDecoder().decode(CodableJSONResponse<MoveResult>.self, from: data)
        #expect(payload.data.fromLocation["x"] == 30)
        #expect(payload.data.fromLocation["y"] == 40)
        #expect(payload.data.distance == 5)
    }

    @Test
    func `Human profile toggles movement mode`() async throws {
        let context = await self.makeContext()
        let result = try await self.runMove(arguments: ["100,200", "--profile", "human"], context: context)

        #expect(result.exitStatus == 0)
        let moveCalls = await self.automationState(context) { $0.moveMouseCalls }
        let call = try #require(moveCalls.first)
        #expect(call.profile == .human())
        #expect(call.steps >= 30)
        #expect(call.duration >= 280)
    }

    @Test
    func `Smooth defaults to natural human movement`() async throws {
        let context = await self.makeContext()
        let result = try await self.runMove(arguments: ["100,200", "--smooth"], context: context)

        #expect(result.exitStatus == 0)
        let call = try #require(await self.automationState(context) { $0.moveMouseCalls }.first)
        #expect(call.profile == .human())
        #expect(call.steps >= 30)
        #expect(call.steps <= 96)
    }

    @Test
    func `Explicit linear profile preserves straight smooth movement`() async throws {
        let context = await self.makeContext()
        let result = try await self.runMove(
            arguments: ["100,200", "--smooth", "--profile", "linear", "--steps", "8"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let call = try #require(await self.automationState(context) { $0.moveMouseCalls }.first)
        #expect(call.profile == .linear)
        #expect(call.duration == 500)
        #expect(call.steps == 8)
    }

    @Test
    func `Human profile honors explicit sample count`() async throws {
        let context = await self.makeContext()
        let result = try await self.runMove(
            arguments: ["100,200", "--profile", "human", "--steps", "8"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let call = try #require(await self.automationState(context) { $0.moveMouseCalls }.first)
        #expect(call.profile == .human())
        #expect(call.steps == 8)
    }

    @Test
    func `Human profile honors explicit zero duration`() async throws {
        let context = await self.makeContext()
        let result = try await self.runMove(
            arguments: ["100,200", "--profile", "human", "--duration", "0"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let call = try #require(await self.automationState(context) { $0.moveMouseCalls }.first)
        #expect(call.profile == .human())
        #expect(call.duration == 0)
    }

    // MARK: - Helpers

    private func runMove(
        arguments: [String],
        context: TestServicesFactory.AutomationTestContext
    ) async throws -> CommandRunResult {
        try await InProcessCommandRunner.run(["move"] + arguments, services: context.services)
    }

    private func output(from result: CommandRunResult) -> String {
        result.stdout.isEmpty ? result.stderr : result.stdout
    }

    private func makeContext(
        configure: (@MainActor (StubAutomationService, StubSnapshotManager) -> Void)? = nil
    ) async -> TestServicesFactory.AutomationTestContext {
        await MainActor.run {
            let context = TestServicesFactory.makeAutomationTestContext()
            configure?(context.automation, context.snapshots)
            return context
        }
    }

    private func automationState<T: Sendable>(
        _ context: TestServicesFactory.AutomationTestContext,
        _ operation: @MainActor (StubAutomationService) -> T
    ) async -> T {
        await MainActor.run {
            operation(context.automation)
        }
    }
}
#endif
