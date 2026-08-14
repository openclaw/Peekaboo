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
struct ScrollCommandTests {
    @Test
    func `scroll --help surfaces command documentation`() async throws {
        let context = await self.makeContext()
        let result = try await self.runScroll(arguments: ["--help"], context: context)

        #expect(result.exitStatus == 0)
        let output = self.output(from: result)
        #expect(output.contains("Scroll the mouse wheel in any direction"))
    }

    @Test
    func `Scroll command requires a direction`() async throws {
        let context = await self.makeContext()
        let result = try await self.runScroll(arguments: [], context: context)

        #expect(result.exitStatus == 0)
        let output = self.output(from: result)
        #expect(output.contains("--direction"))
        let scrollCalls = await self.automationState(context) { $0.scrollCalls }
        #expect(scrollCalls.isEmpty)
    }

    @Test
    func `Scroll forwards parameters to automation service`() async throws {
        let snapshotId = "snapshot-42"
        let context = await self.makeContext()
        try await context.snapshots.storeDetectionResult(
            snapshotId: snapshotId,
            result: Self.detectionResult(snapshotId: snapshotId, element: Self.buttonElement(id: "B1"))
        )

        let result = try await self.runScroll(
            arguments: [
                "--direction", "down",
                "--amount", "5",
                "--delay", "10",
                "--smooth",
                "--snapshot", snapshotId,
                "--on", "B1",
                "--foreground",
                "--json",
            ],
            context: context
        )

        #expect(result.exitStatus == 0)

        let scrollCalls = await self.automationState(context) { $0.scrollCalls }
        let call = try #require(scrollCalls.first)
        #expect(call.request.direction == .down)
        #expect(call.request.amount == 5)
        #expect(call.request.delay == 10)
        #expect(call.request.smooth == true)
        #expect(call.request.target == "B1")
        #expect(call.request.snapshotId == "snapshot-42")
        #expect(call.request.foreground)

        let payloadData = try #require(self.output(from: result).data(using: .utf8))
        let payload = try JSONDecoder().decode(CodableJSONResponse<ScrollResult>.self, from: payloadData)
        #expect(payload.success)
        #expect(payload.data.direction == "down")
        #expect(payload.data.amount == 5)
    }

    @Test
    func `Scroll on element refreshes stale latest snapshot`() async throws {
        let detectorReturnedSnapshotID = "detector-returned-snapshot"
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 42,
            bundleIdentifier: "com.example.ScrollApp",
            name: "ScrollApp",
            windowCount: 1
        )
        let window = ServiceWindowInfo(
            windowID: 4242,
            title: "Scroll",
            bounds: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        let automation = await MainActor.run {
            let automation = StubAutomationService()
            automation.detectElementsHandler = { _, _, _ in
                Self.detectionResult(
                    snapshotId: detectorReturnedSnapshotID,
                    element: Self.buttonElement(id: "B1")
                )
            }
            return automation
        }
        let snapshots = StubSnapshotManager()
        let staleSnapshotID = try await snapshots.createSnapshot()
        let context = await MainActor.run {
            TestServicesFactory.makeAutomationTestContext(
                automation: automation,
                snapshots: snapshots,
                applications: StubApplicationService(
                    applications: [appInfo],
                    windowsByApp: ["com.example.ScrollApp": [window]]
                )
            )
        }

        let result = try await self.runScroll(
            arguments: ["--direction", "down", "--on", "B1", "--json"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let scrollCalls = await self.automationState(context) { $0.scrollCalls }
        let call = try #require(scrollCalls.first)
        #expect(call.request.target == "B1")
        let refreshedSnapshotID = try #require(call.request.snapshotId)
        #expect(refreshedSnapshotID != staleSnapshotID)
        #expect(refreshedSnapshotID != detectorReturnedSnapshotID)
        let detectionCalls = await MainActor.run { automation.detectElementsCalls }
        #expect(detectionCalls.first?.snapshotId == refreshedSnapshotID)
        let storedResult = try #require(try await snapshots.getDetectionResult(snapshotId: refreshedSnapshotID))
        #expect(storedResult.snapshotId == refreshedSnapshotID)
        #expect(storedResult.elements.findById("B1") != nil)
        #expect(call.request.delay == 0)
        #expect(!call.request.foreground)
    }

    @Test
    func `Scroll without snapshot still executes`() async throws {
        let context = await self.makeContext()
        let result = try await self.runScroll(
            arguments: ["--direction", "up", "--amount", "2", "--foreground"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let scrollCalls = await self.automationState(context) { $0.scrollCalls }
        #expect(scrollCalls.count == 1)
        let call = try #require(scrollCalls.first)
        #expect(call.request.snapshotId == nil)
        #expect(call.request.amount == 2)
        #expect(call.request.foreground)
    }

    @Test
    func `Smooth scrolling adjusts total ticks in JSON output`() async throws {
        let context = await self.makeContext()
        let result = try await self.runScroll(
            arguments: ["--direction", "down", "--amount", "4", "--smooth", "--foreground", "--json"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let payloadData = try #require(self.output(from: result).data(using: .utf8))
        let payload = try JSONDecoder().decode(CodableJSONResponse<ScrollResult>.self, from: payloadData)
        #expect(payload.data.totalTicks == 40) // 4 * 10 when smooth
    }

    @Test
    func `Scroll without element reports pointer location from automation service`() async throws {
        let context = await self.makeContext { automation, _ in
            automation.stubCurrentMouseLocation = CGPoint(x: 123, y: 456)
        }

        let result = try await self.runScroll(
            arguments: ["--direction", "down", "--foreground", "--json"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let payloadData = try #require(self.output(from: result).data(using: .utf8))
        let payload = try JSONDecoder().decode(CodableJSONResponse<ScrollResult>.self, from: payloadData)
        #expect(payload.data.location["x"] == 123)
        #expect(payload.data.location["y"] == 456)
    }

    @Test(arguments: [
        "up", "down", "left", "right",
    ])
    func `Direction validation accepts common values`(value: String) async throws {
        let context = await self.makeContext()
        let result = try await self.runScroll(arguments: ["--direction", value, "--foreground"], context: context)
        #expect(result.exitStatus == 0)
    }

    @Test
    func `Targetless background scroll fails closed`() async throws {
        let context = await self.makeContext()
        let result = try await self.runScroll(arguments: ["--direction", "down"], context: context)

        #expect(result.exitStatus != 0)
        #expect(self.output(from: result).contains("Background scroll requires --on"))
        #expect(await self.automationState(context) { $0.scrollCalls }.isEmpty)
    }

    @Test
    func `Smooth background scroll requires foreground`() async throws {
        let context = await self.makeContext()
        let result = try await self.runScroll(
            arguments: ["--direction", "down", "--on", "S1", "--smooth"],
            context: context
        )

        #expect(result.exitStatus != 0)
        #expect(self.output(from: result).contains("require --foreground"))
        #expect(await self.automationState(context) { $0.scrollCalls }.isEmpty)
    }

    @Test
    func `stale background scroll reports canonical retry-safe refusal`() async throws {
        let snapshotId = "stale-scroll-snapshot"
        let context = await self.makeContext { automation, _ in
            automation.scrollError = PeekabooError.snapshotStale(
                "target window owner, process generation, or bounds changed"
            )
        }
        try await context.snapshots.storeDetectionResult(
            snapshotId: snapshotId,
            result: Self.detectionResult(snapshotId: snapshotId, element: Self.buttonElement(id: "B1"))
        )

        let result = try await self.runScroll(
            arguments: [
                "--direction", "down",
                "--on", "B1",
                "--snapshot", snapshotId,
                "--json",
            ],
            context: context
        )

        #expect(result.exitStatus != 0)
        let payloadData = try #require(self.output(from: result).data(using: .utf8))
        let payload = try JSONDecoder().decode(JSONResponse.self, from: payloadData)
        #expect(!payload.success)
        #expect(payload.error?.code == ErrorCode.SNAPSHOT_STALE.rawValue)
        #expect(payload.outcome?.state == .refused)
        #expect(payload.outcome?.retrySafety == .safe)
        #expect(payload.outcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(payload.outcome?.refusalReason == .targetUnavailable)
    }

    // MARK: - Helpers

    private func runScroll(
        arguments: [String],
        context: TestServicesFactory.AutomationTestContext
    ) async throws -> CommandRunResult {
        try await InProcessCommandRunner.run(["scroll"] + arguments, services: context.services)
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

    private static func buttonElement(id: String) -> DetectedElement {
        DetectedElement(
            id: id,
            type: .button,
            label: "Button \(id)",
            bounds: CGRect(x: 20, y: 30, width: 100, height: 40)
        )
    }

    private static func detectionResult(snapshotId: String, element: DetectedElement) -> ElementDetectionResult {
        ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/\(snapshotId).png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 1, method: "stub")
        )
    }
}
#endif

@Suite(.tags(.safe))
struct ScrollCommandResultStructTests {
    @Test
    func `Scroll result structure maintains fields`() {
        let result = ScrollResult(
            direction: "down",
            amount: 5,
            location: ["x": 500.0, "y": 300.0],
            totalTicks: 5,
            executionTime: 0.15
        )

        #expect(result.direction == "down")
        #expect(result.amount == 5)
        #expect(result.location["x"] == 500.0)
        #expect(result.location["y"] == 300.0)
        #expect(result.totalTicks == 5)
        #expect(result.executionTime == 0.15)
    }
}
