import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite(
    .tags(.automation),
    .enabled(if: CLITestEnvironment.runAutomationRead)
)
struct ClickCommandTests {
    @Test
    func `Click command  requires argument or option`() throws {
        var command = try ClickCommand.parse([])
        #expect(throws: (any Error).self) {
            try command.validate()
        }
    }

    @Test
    func `Click command  parses coordinates correctly`() async throws {
        let context = await self.makeContext()
        let result = try await InProcessCommandRunner.run(
            ["click", "--coords", "100,200", "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        let calls = await self.automationState(context) { $0.clickCalls }
        let call = try #require(calls.first)
        if case let .coordinates(point) = call.target {
            #expect(point == CGPoint(x: 100, y: 200))
        } else {
            Issue.record("Expected coordinates click target")
        }
    }

    @Test
    func `Click command  validates coordinate format`() throws {
        var command = try ClickCommand.parse(["--coords", "invalid", "--json"])
        #expect(throws: (any Error).self) {
            try command.validate()
        }
    }

    @Test
    func `Click command supports background coordinate clicks`() async throws {
        let context = await self.makeContext()
        let result = try await InProcessCommandRunner.run(
            ["click", "--coords", "100,200", "--pid", "12345", "--focus-background", "--global-coords", "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        let calls = await self.automationState(context) { $0.targetedClickCalls }
        let call = try #require(calls.first)
        if case let .coordinates(point) = call.target {
            #expect(point == CGPoint(x: 100, y: 200))
        } else {
            Issue.record("Expected coordinates click target")
        }
        #expect(call.targetProcessIdentifier == 12345)
    }

    @Test
    func `Click command background element click uses cached snapshot without waiting`() async throws {
        let context = await self.makeContext()
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Save",
            bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
        )
        let snapshotId = try await self.storeSnapshot(element: element, in: context.snapshots)

        let result = try await InProcessCommandRunner.run(
            ["click", "--on", "B1", "--snapshot", snapshotId, "--pid", "12345", "--focus-background", "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        let waitCalls = await self.automationState(context) { $0.waitForElementCalls }
        let calls = await self.automationState(context) { $0.targetedClickCalls }
        #expect(waitCalls.isEmpty)
        let call = try #require(calls.first)
        #expect(call.snapshotId == snapshotId)
        #expect(call.targetProcessIdentifier == 12345)
        if case let .elementId(id) = call.target {
            #expect(id == "B1")
        } else {
            Issue.record("Expected element ID click target")
        }
    }

    @Test
    func `Click command background query click resolves cached snapshot without waiting`() async throws {
        let context = await self.makeContext()
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Save",
            bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
        )
        let snapshotId = try await self.storeSnapshot(element: element, in: context.snapshots)

        let result = try await InProcessCommandRunner.run(
            ["click", "Save", "--snapshot", snapshotId, "--pid", "12345", "--focus-background", "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        let waitCalls = await self.automationState(context) { $0.waitForElementCalls }
        let calls = await self.automationState(context) { $0.targetedClickCalls }
        #expect(waitCalls.isEmpty)
        let call = try #require(calls.first)
        #expect(call.snapshotId == snapshotId)
        #expect(call.targetProcessIdentifier == 12345)
        if case let .elementId(id) = call.target {
            #expect(id == "B1")
        } else {
            Issue.record("Expected resolved element ID click target")
        }
    }

    @Test
    func `Click command reuses latest snapshot for element lookup with app target`() async throws {
        let context = await self.makeContext()
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Save",
            bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
        )
        let snapshotId = try await self.storeSnapshot(element: element, in: context.snapshots)
        await MainActor.run {
            context.automation.setWaitForElementResult(
                WaitForElementResult(found: true, element: element, waitTime: 0),
                for: .query("Save")
            )
        }

        let result = try await InProcessCommandRunner.run(
            ["click", "Save", "--app", "TextEdit", "--json", "--no-auto-focus"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        let waitCalls = await self.automationState(context) { $0.waitForElementCalls }
        let clickCalls = await self.automationState(context) { $0.clickCalls }
        #expect(waitCalls.first?.snapshotId == snapshotId)
        #expect(clickCalls.first?.snapshotId == snapshotId)
    }

    private func makeContext() async -> TestServicesFactory.AutomationTestContext {
        await MainActor.run {
            TestServicesFactory.makeAutomationTestContext()
        }
    }

    private func storeSnapshot(element: DetectedElement, in snapshots: StubSnapshotManager) async throws -> String {
        let snapshotId = try await snapshots.createSnapshot()
        let detection = ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/screenshot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 1, method: "stub")
        )
        try await snapshots.storeDetectionResult(snapshotId: snapshotId, result: detection)
        return snapshotId
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
