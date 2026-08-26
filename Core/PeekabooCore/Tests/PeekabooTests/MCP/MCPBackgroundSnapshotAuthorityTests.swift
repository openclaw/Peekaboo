import CoreGraphics
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore

@Suite(.serialized)
struct MCPBackgroundSnapshotAuthorityTests {
    @Test
    @MainActor
    func `snapshot mutation uses one shared receipt and live authority`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(snapshotID: SnapshotReferenceFixtures.id(201))
        let graph = try LinkedApplicationInventoryGraph(linkedTargets: [fixture.desktopTarget])
        let applications = ScriptedApplicationInventoryService(graph: graph)
        let windows = ScriptedWindowInventoryService(graph: graph)
        let automation = SnapshotAuthorityAutomationService()
        let context = try await Self.makeContext(
            fixture: fixture,
            automation: automation,
            applications: applications,
            windows: windows)

        let response = try await context.execute(
            tool: ClickTool(context: context),
            arguments: ToolArguments(raw: [
                "coords": "30,40",
                "snapshot": fixture.snapshotID,
            ]))

        #expect(!response.isError)
        #expect(automation.targetedClickCalls.count == 1)
        #expect(applications.findApplicationRequests.count >= 2)
        #expect(windows.windowMutationInventoryRequests.count >= 2)
    }

    @Test
    @MainActor
    func `contradictory snapshot sources refuse before inventory or dispatch`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(snapshotID: SnapshotReferenceFixtures.id(202))
        let graph = try LinkedApplicationInventoryGraph(linkedTargets: [fixture.desktopTarget])
        let applications = ScriptedApplicationInventoryService(graph: graph)
        let windows = ScriptedWindowInventoryService(graph: graph)
        let automation = SnapshotAuthorityAutomationService()
        let owner = MCPToolSnapshotOwner()
        let uiSnapshots = MCPToolUISnapshotStore(owner: owner)
        let snapshot = await uiSnapshots.createSnapshot(id: fixture.snapshotID)
        let otherProcess = AutomationTestFixtures.processIdentity(
            processIdentifier: fixture.desktopTarget.processIdentity.processIdentifier,
            processStartIdentity: fixture.desktopTarget.processIdentity.processStartIdentity + 1)
        let contradictoryWindow = AutomationTestFixtures.window(
            windowID: fixture.desktopTarget.window.windowID,
            bounds: fixture.desktopTarget.window.bounds,
            processIdentity: otherProcess)
        await snapshot.setScreenshot(
            path: fixture.detectionResult.screenshotPath,
            metadata: CaptureMetadata(
                size: contradictoryWindow.bounds.size,
                mode: .window,
                applicationInfo: AutomationTestFixtures.application(
                    processIdentifier: otherProcess.processIdentifier,
                    processStartIdentity: otherProcess.processStartIdentity,
                    bundleIdentifier: fixture.desktopTarget.application.bundleIdentifier,
                    name: fixture.desktopTarget.application.name),
                windowInfo: contradictoryWindow))
        let snapshots = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            windows: windows,
            snapshots: snapshots,
            snapshotOwner: owner)

        let response = try await context.execute(
            tool: ClickTool(context: context),
            arguments: ToolArguments(raw: [
                "coords": "30,40",
                "snapshot": fixture.snapshotID,
            ]))

        #expect(response.isError)
        #expect(automation.targetedClickCalls.isEmpty)
        #expect(applications.applicationMutationInventoryCallCount == 0)
        #expect(windows.windowMutationInventoryRequests.isEmpty)
        Self.expectSafeTargetRefusal(response)
    }

    @Test
    @MainActor
    func `partial exact-window inventory without the receipt target refuses before dispatch`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(snapshotID: SnapshotReferenceFixtures.id(203))
        let graph = try LinkedApplicationInventoryGraph(linkedTargets: [fixture.desktopTarget])
        let applications = ScriptedApplicationInventoryService(graph: graph)
        let windows = ScriptedWindowInventoryService(
            graph: graph,
            inventorySequencesByTarget: [
                .windowId(fixture.desktopTarget.window.windowID): [
                    .partial([], warnings: ["exact window inventory timed out"]),
                ],
            ])
        let automation = SnapshotAuthorityAutomationService()
        let context = try await Self.makeContext(
            fixture: fixture,
            automation: automation,
            applications: applications,
            windows: windows)

        let response = try await context.execute(
            tool: ClickTool(context: context),
            arguments: ToolArguments(raw: [
                "coords": "30,40",
                "snapshot": fixture.snapshotID,
            ]))

        #expect(response.isError)
        #expect(automation.targetedClickCalls.isEmpty)
        Self.expectSafeTargetRefusal(response)
    }

    @Test
    @MainActor
    func `process generation replacement during final revalidation refuses before dispatch`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(snapshotID: SnapshotReferenceFixtures.id(204))
        let graph = try LinkedApplicationInventoryGraph(linkedTargets: [fixture.desktopTarget])
        let replacement = AutomationTestFixtures.application(
            processIdentifier: fixture.desktopTarget.processIdentity.processIdentifier,
            processStartIdentity: fixture.desktopTarget.processIdentity.processStartIdentity + 1,
            bundleIdentifier: fixture.desktopTarget.application.bundleIdentifier,
            name: fixture.desktopTarget.application.name,
            windowCount: 1,
            windowIDs: [fixture.desktopTarget.window.windowID])
        let applications = ReplacingSnapshotAuthorityApplicationService(
            graph: graph,
            responses: [fixture.desktopTarget.application, fixture.desktopTarget.application, replacement])
        let windows = ScriptedWindowInventoryService(graph: graph)
        let automation = SnapshotAuthorityAutomationService()
        let context = try await Self.makeContext(
            fixture: fixture,
            automation: automation,
            applications: applications,
            windows: windows)

        let response = try await context.execute(
            tool: ClickTool(context: context),
            arguments: ToolArguments(raw: [
                "coords": "30,40",
                "snapshot": fixture.snapshotID,
            ]))

        #expect(response.isError)
        #expect(automation.targetedClickCalls.isEmpty)
        Self.expectSafeTargetRefusal(response)
    }

    @Test
    @MainActor
    func `missing capture generation refuses before inventory or dispatch`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(snapshotID: SnapshotReferenceFixtures.id(205))
        let graph = try LinkedApplicationInventoryGraph(linkedTargets: [fixture.desktopTarget])
        let applications = ScriptedApplicationInventoryService(graph: graph)
        let windows = ScriptedWindowInventoryService(graph: graph)
        let automation = SnapshotAuthorityAutomationService()
        let owner = MCPToolSnapshotOwner()
        let uiSnapshot = await MCPToolUISnapshotStore(owner: owner).createSnapshot(id: fixture.snapshotID)
        let incompleteContext = WindowContext(
            applicationName: fixture.desktopTarget.application.name,
            applicationBundleId: fixture.desktopTarget.application.bundleIdentifier,
            applicationProcessId: fixture.desktopTarget.processIdentity.processIdentifier,
            windowTitle: fixture.desktopTarget.window.title,
            windowID: fixture.desktopTarget.window.windowID,
            windowBounds: fixture.desktopTarget.window.bounds)
        await uiSnapshot.setTargetMetadata(from: incompleteContext)
        let detection = AutomationTestFixtures.detectionResult(
            snapshotID: fixture.snapshotID,
            windowContext: incompleteContext)
        let snapshots = try await InMemorySnapshotManager.containing(detection)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            windows: windows,
            snapshots: snapshots,
            snapshotOwner: owner)

        let response = try await context.execute(
            tool: ClickTool(context: context),
            arguments: ToolArguments(raw: [
                "coords": "30,40",
                "snapshot": fixture.snapshotID,
            ]))

        #expect(response.isError)
        #expect(automation.targetedClickCalls.isEmpty)
        #expect(applications.findApplicationRequests.isEmpty)
        #expect(windows.windowMutationInventoryRequests.isEmpty)
        Self.expectSafeTargetRefusal(response)
    }

    @Test
    @MainActor
    func `snapshot authority preserves cancellation`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(snapshotID: SnapshotReferenceFixtures.id(206))
        let graph = try LinkedApplicationInventoryGraph(linkedTargets: [fixture.desktopTarget])
        let applications = CancellingSnapshotAuthorityApplicationService(graph: graph)
        let windows = ScriptedWindowInventoryService(graph: graph)
        let automation = SnapshotAuthorityAutomationService()
        let context = try await Self.makeContext(
            fixture: fixture,
            automation: automation,
            applications: applications,
            windows: windows)

        do {
            _ = try await context.execute(
                tool: ClickTool(context: context),
                arguments: ToolArguments(raw: [
                    "coords": "30,40",
                    "snapshot": fixture.snapshotID,
                ]))
            Issue.record("Expected cancellation to escape snapshot authority planning")
        } catch is CancellationError {
            // Expected.
        }
        #expect(automation.targetedClickCalls.isEmpty)

        let followUpCompleted = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    let response = try await context.execute(
                        tool: ClickTool(context: context),
                        arguments: ToolArguments(raw: [
                            "coords": "30,40",
                            "snapshot": fixture.snapshotID,
                        ]))
                    return !response.isError
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(250))
                return false
            }
            let completed = await group.next() ?? false
            group.cancelAll()
            return completed
        }
        #expect(followUpCompleted)
        #expect(automation.targetedClickCalls.count == 1)
    }

    @MainActor
    private static func makeContext(
        fixture: LinkedSnapshotTargetFixture,
        automation: SnapshotAuthorityAutomationService,
        applications: ScriptedApplicationInventoryService,
        windows: ScriptedWindowInventoryService) async throws -> MCPToolContext
    {
        let owner = MCPToolSnapshotOwner()
        let snapshot = await MCPToolUISnapshotStore(owner: owner).createSnapshot(id: fixture.snapshotID)
        await snapshot.setScreenshot(
            path: fixture.detectionResult.screenshotPath,
            metadata: CaptureMetadata(
                size: fixture.desktopTarget.window.bounds.size,
                mode: .window,
                applicationInfo: fixture.desktopTarget.application,
                windowInfo: fixture.desktopTarget.window))
        let snapshots = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        return await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            windows: windows,
            snapshots: snapshots,
            snapshotOwner: owner)
    }

    private static func expectSafeTargetRefusal(_ response: ToolResponse) {
        guard case let .object(metadata) = response.meta else {
            Issue.record("Expected structured target refusal")
            return
        }
        #expect(metadata["dispatch_state"] == .string("none"))
        #expect(metadata["mutation_dispatched"] == .bool(false))
        #expect(metadata["retry_safe"] == .bool(true))
        #expect(metadata["refusal_reason"] == .string("target_unavailable"))
    }
}

@MainActor
private final class SnapshotAuthorityAutomationService: MockAutomationService,
ScriptedUIAutomationActionOutcomeProviding {
    let uiAutomationOutcomeScript = UIAutomationOutcomeScript(defaultResponse: .outcome(.confirmedChange(
        delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
        unitCount: .one)))

    init() {
        super.init(accessibilityGranted: true)
    }
}

@MainActor
private final class CancellingSnapshotAuthorityApplicationService: ScriptedApplicationInventoryService {
    private var shouldCancel = true

    override func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        if self.shouldCancel {
            self.shouldCancel = false
            throw CancellationError()
        }
        return try await super.findApplication(identifier: identifier)
    }
}

@MainActor
private final class ReplacingSnapshotAuthorityApplicationService: ScriptedApplicationInventoryService {
    private var responses: [ServiceApplicationInfo]

    init(graph: LinkedApplicationInventoryGraph, responses: [ServiceApplicationInfo]) {
        self.responses = responses
        super.init(
            applications: graph.applications,
            windowsByIdentifier: graph.windowsByIdentifier)
    }

    override func findApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        guard !self.responses.isEmpty else {
            throw PeekabooError.appNotFound("replacement fixture exhausted")
        }
        return self.responses.removeFirst()
    }
}
