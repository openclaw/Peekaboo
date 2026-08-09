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
struct SwipeCommandTests {
    @Test
    func `swipe --help describes usage`() async throws {
        let context = await self.makeContext()
        let result = try await self.runSwipe(arguments: ["--help"], context: context)

        #expect(result.exitStatus == 0)
        #expect(self.output(from: result).contains("Perform swipe gestures"))
    }

    @Test
    func `Swipe command validates sources and destinations`() async throws {
        let context = await self.makeContext()
        let result = try await self.runSwipe(arguments: ["--from-coords", "10,10"], context: context)

        #expect(result.exitStatus != 0)
        let swipeCalls = await self.automationState(context) { $0.swipeCalls }
        #expect(swipeCalls.isEmpty)
    }

    @Test
    func `Swipe coordinates are forwarded to automation service`() async throws {
        let context = await self.makeContext()
        let result = try await self.runSwipe(
            arguments: [
                "--from-coords", "100,200",
                "--to-coords", "300,450",
                "--duration", "1200",
                "--steps", "40",
                "--foreground",
                "--json",
            ],
            context: context
        )

        #expect(result.exitStatus == 0)

        let swipeCalls = await self.automationState(context) { $0.swipeCalls }
        let call = try #require(swipeCalls.first)
        #expect(call.from == CGPoint(x: 100, y: 200))
        #expect(call.to == CGPoint(x: 300, y: 450))
        #expect(call.duration == 1200)
        #expect(call.steps == 40)
        #expect(call.profile == .linear)

        let payloadData = try #require(self.output(from: result).data(using: .utf8))
        let payload = try JSONDecoder().decode(CodableJSONResponse<SwipeResult>.self, from: payloadData)
        #expect(payload.success)
        #expect(payload.data.success)
        #expect(payload.data.distance > 0)
        #expect(payload.data.profile == "linear")
    }

    @Test
    func `Element based swipe resolves using waitForElement`() async throws {
        let snapshotId = "snapshot-1"
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Submit",
            bounds: CGRect(x: 10, y: 20, width: 120, height: 40)
        )
        let targetElement = DetectedElement(
            id: "B5",
            type: .button,
            label: "Finish",
            bounds: CGRect(x: 300, y: 400, width: 80, height: 30)
        )
        let context = await self.makeContext { automation, snapshots in
            snapshots.mostRecentSnapshotId = snapshotId
            automation.setWaitForElementResult(
                WaitForElementResult(found: true, element: element, waitTime: 0.1),
                for: .elementId("B1")
            )
            automation.setWaitForElementResult(
                WaitForElementResult(found: true, element: targetElement, waitTime: 0.1),
                for: .elementId("B5")
            )
        }
        let detection = ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/screenshot.png",
            elements: DetectedElements(buttons: [element, targetElement]),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 2, method: "stub")
        )
        try await context.snapshots.storeDetectionResult(snapshotId: snapshotId, result: detection)

        let result = try await self.runSwipe(
            arguments: [
                "--from", "B1",
                "--to", "B5",
                "--foreground",
                "--json",
            ],
            context: context
        )

        #expect(result.exitStatus == 0)
        let waitCalls = await self.automationState(context) { $0.waitForElementCalls }
        #expect(waitCalls.count == 2)
        let swipeCalls = await self.automationState(context) { $0.swipeCalls }
        let call = try #require(swipeCalls.first)
        #expect(call.profile == .linear)
    }

    @Test
    func `Right button option is rejected`() async throws {
        let context = await self.makeContext()
        let result = try await self.runSwipe(
            arguments: [
                "--from-coords", "0,0",
                "--to-coords", "10,10",
                "--foreground",
                "--right-button",
            ],
            context: context
        )

        #expect(result.exitStatus != 0)
        #expect(self.output(from: result).contains("Right-button swipe"))
        let swipeCalls = await self.automationState(context) { $0.swipeCalls }
        #expect(swipeCalls.isEmpty)
    }

    @Test
    func `Human profile swipe adjusts motion`() async throws {
        let context = await self.makeContext()
        let result = try await self.runSwipe(
            arguments: [
                "--from-coords", "50,50",
                "--to-coords", "450,250",
                "--profile", "human",
                "--foreground",
                "--json",
            ],
            context: context
        )

        #expect(result.exitStatus == 0)
        let swipeCalls = await self.automationState(context) { $0.swipeCalls }
        let call = try #require(swipeCalls.first)
        #expect(call.profile == .human())
        #expect(call.steps >= 40)
        let payloadData = try #require(self.output(from: result).data(using: .utf8))
        let payload = try JSONDecoder().decode(CodableJSONResponse<SwipeResult>.self, from: payloadData)
        #expect(payload.data.profile == "human")
    }

    @Test
    func `Swipe requires explicit foreground consent`() async throws {
        let context = await self.makeContext()
        let result = try await self.runSwipe(
            arguments: ["--from-coords", "10,10", "--to-coords", "20,20"],
            context: context
        )

        #expect(result.exitStatus != 0)
        #expect(self.output(from: result).contains("requires explicit --foreground"))
        #expect(await self.automationState(context) { $0.swipeCalls }.isEmpty)
    }

    // MARK: - Helpers

    private func runSwipe(
        arguments: [String],
        context: TestServicesFactory.AutomationTestContext
    ) async throws -> CommandRunResult {
        try await InProcessCommandRunner.run(["swipe"] + arguments, services: context.services)
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
