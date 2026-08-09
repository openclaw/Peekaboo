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
struct PressCommandTests {
    @Test
    func `press --help documents command`() async throws {
        let context = await self.makeContext()
        let result = try await self.runPress(arguments: ["--help"], context: context)

        #expect(result.exitStatus == 0)
        #expect(self.output(from: result).contains("Press individual keys or key sequences"))
    }

    @Test
    func `Press command forwards keys to automation service`() async throws {
        let context = await self.makeContext()
        let result = try await self.runPress(arguments: ["return", "--foreground", "--json"], context: context)

        #expect(result.exitStatus == 0)
        let calls = await self.automationState(context) { $0.hotkeyCalls }
        let call = try #require(calls.first)
        #expect(call.keys == "return")
        #expect(call.holdDuration == 50)

        let payloadData = try #require(self.output(from: result).data(using: .utf8))
        let payload = try JSONDecoder().decode(CodableJSONResponse<PressResult>.self, from: payloadData)
        #expect(payload.success)
        #expect(payload.data.success)
        #expect(payload.data.keys == ["return"])
        #expect(payload.data.totalPresses == 1)
    }

    @Test
    func `Repeat count multiplies key actions`() async throws {
        let context = await self.makeContext()
        let result = try await self.runPress(arguments: ["tab", "--count", "3", "--foreground"], context: context)

        #expect(result.exitStatus == 0)
        let calls = await self.automationState(context) { $0.hotkeyCalls }
        #expect(calls.map(\.keys) == ["tab", "tab", "tab"])
    }

    @Test
    func `Press command supports multiple keys in sequence`() async throws {
        let context = await self.makeContext()
        let result = try await self.runPress(
            arguments: ["up", "down", "left", "right", "--foreground"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let calls = await self.automationState(context) { $0.hotkeyCalls }
        #expect(calls.map(\.keys) == ["up", "down", "left", "right"])
    }

    @Test
    func `Press command forwards hold duration`() async throws {
        let context = await self.makeContext()
        let result = try await self.runPress(
            arguments: ["space", "--hold", "250", "--foreground"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let calls = await self.automationState(context) { $0.hotkeyCalls }
        let call = try #require(calls.first)
        #expect(call.keys == "space")
        #expect(call.holdDuration == 250)
    }

    @Test
    func `Snapshot argument is forwarded`() async throws {
        let snapshotId = "snapshot-42"
        let context = await self.makeContext()
        let detection = ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/screenshot.png",
            elements: DetectedElements(),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 0, method: "stub")
        )
        try await context.snapshots.storeDetectionResult(snapshotId: snapshotId, result: detection)

        let result = try await self.runPress(
            arguments: ["escape", "--snapshot", snapshotId, "--foreground"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let calls = await self.automationState(context) { $0.hotkeyCalls }
        let call = try #require(calls.first)
        #expect(call.keys == "escape")
    }

    @Test
    func `Invalid key results in failure`() async throws {
        let context = await self.makeContext()
        let result = try await self.runPress(arguments: ["notakey"], context: context)

        #expect(result.exitStatus != 0)
        let calls = await self.automationState(context) { $0.hotkeyCalls }
        #expect(calls.isEmpty)
    }

    // MARK: - Helpers

    private func runPress(
        arguments: [String],
        context: TestServicesFactory.AutomationTestContext
    ) async throws -> CommandRunResult {
        try await InProcessCommandRunner.run(["press"] + arguments, services: context.services)
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
