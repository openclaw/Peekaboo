import Foundation
import MCP
import PeekabooCore
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
@MainActor
struct MCPToolSnapshotInvalidationLedgerTests {
    @Test
    func `Snapshot release retains owner until blocking invalidation recovery succeeds`() async {
        let fixture = await self.makeReleaseFixture(
            invalidationResults: [false, true],
            browserEndResults: [true, true])

        #expect(await !fixture.context.releaseSnapshotOwner())
        #expect(fixture.coordinator.completionAttempts == 1)
        #expect(fixture.browser.endCount == 1)
        #expect(await fixture.gate.pendingInvalidation() != nil)
        #expect(await fixture.context.uiSnapshots.getSnapshot(id: fixture.snapshotID) != nil)

        #expect(await fixture.context.releaseSnapshotOwner())
        #expect(fixture.coordinator.completionAttempts == 2)
        #expect(fixture.browser.endCount == 2)
        #expect(await fixture.gate.pendingInvalidation() == nil)
        #expect(await !fixture.context.uiSnapshots.hasOwnerState())
    }

    @Test
    func `Snapshot release retains owner when invalidation recovery throws`() async {
        let fixture = await self.makeReleaseFixture(
            invalidationResults: [true],
            browserEndResults: [true, true])

        #expect(await !fixture.context.releaseSnapshotOwnerForTesting {
            throw SnapshotReleaseFixtureError.injected
        })
        #expect(fixture.coordinator.completionAttempts == 0)
        #expect(fixture.browser.endCount == 1)
        #expect(await fixture.gate.pendingInvalidation() != nil)
        #expect(await fixture.context.uiSnapshots.getSnapshot(id: fixture.snapshotID) != nil)

        #expect(await fixture.context.releaseSnapshotOwner())
        #expect(fixture.coordinator.completionAttempts == 1)
        #expect(fixture.browser.endCount == 2)
        #expect(await fixture.gate.pendingInvalidation() == nil)
        #expect(await !fixture.context.uiSnapshots.hasOwnerState())
    }

    @Test(arguments: [false, true], [false, true])
    func `Snapshot and browser cleanup results compose without discarding invalidation debt`(
        invalidationConfirmed: Bool,
        browserConfirmed: Bool) async
    {
        let fixture = await self.makeReleaseFixture(
            invalidationResults: [invalidationConfirmed, true],
            browserEndResults: [browserConfirmed, true])

        let firstRelease = await fixture.context.releaseSnapshotOwner()
        #expect(firstRelease == (invalidationConfirmed && browserConfirmed))
        #expect(fixture.browser.endCount == 1)
        #expect(await fixture.context.uiSnapshots.hasOwnerState() == !invalidationConfirmed)
        #expect(await (fixture.gate.pendingInvalidation() != nil) == !invalidationConfirmed)

        if !firstRelease {
            #expect(await fixture.context.releaseSnapshotOwner())
            #expect(fixture.browser.endCount == 2)
            #expect(await fixture.gate.pendingInvalidation() == nil)
            #expect(await !fixture.context.uiSnapshots.hasOwnerState())
        }
    }

    @Test
    func `MCP server retries blocked invalidation recovery before reporting teardown success`() async throws {
        let fixture = await self.makeReleaseFixture(
            invalidationResults: [false, true],
            browserEndResults: [true, true],
            recordDebt: false)
        let server = try await PeekabooMCPServer(toolContext: fixture.context)
        let serverOwner = await server.snapshotOwnerForTesting()
        let serverSnapshots = MCPToolUISnapshotStore(owner: serverOwner)
        _ = await serverSnapshots.createSnapshot(id: "server-release-owner")
        await fixture.gate.recordPendingInvalidation(
            MCPToolSnapshotMutationScope(toolName: "click", effect: .mutation)
                .completed(at: Date(), preserving: nil),
            owner: serverOwner,
            usesCoordinatorBarrier: true,
            snapshotMutationCoordinator: fixture.coordinator)

        #expect(await server.stopForTesting())

        #expect(fixture.coordinator.completionAttempts == 2)
        #expect(fixture.browser.endCount == 2)
        #expect(await fixture.gate.pendingInvalidation() == nil)
        #expect(await !serverSnapshots.hasOwnerState())
    }

    @Test
    func `Concurrent preparation default completes its legacy barrier`() async throws {
        let coordinator = LegacyBarrierMutationCoordinator()
        let services = PeekabooServices()
        let context = MCPToolContext(
            services: services,
            snapshotMutationCoordinator: coordinator,
            snapshotExecutionGate: MCPToolSnapshotExecutionGate(),
            browserMutationExecutionGate: MCPToolSnapshotExecutionGate(),
            snapshotOwner: MCPToolSnapshotOwner(),
            executionPolicy: .unrestricted)

        _ = try await context.execute(
            tool: LedgerBrowserMutationTool(),
            arguments: ToolArguments(raw: [
                "action": "new_page",
                "url": "https://example.test/",
                "background": true,
            ]))

        #expect(coordinator.sharedPrepareCount == 1)
        #expect(coordinator.barrierCompletionCount == 1)
        #expect(coordinator.mutationCompletionCount == 1)
    }

    @Test
    func `Concurrent preparation default closes its legacy barrier on cancellation`() async throws {
        let coordinator = LegacyBarrierMutationCoordinator()
        let scope = MCPToolSnapshotMutationScope(toolName: "browser", effect: .mutation)

        try coordinator.prepareConcurrentMutation(scope)
        #expect(await coordinator.cancelMutation(scope))

        #expect(coordinator.sharedPrepareCount == 1)
        #expect(coordinator.barrierCompletionCount == 1)
        #expect(coordinator.mutationCompletionCount == 1)
    }

    @Test
    func `Ledger preserves shared barrier debt before later browser debt`() async throws {
        let gate = MCPToolSnapshotExecutionGate()
        let owner = MCPToolSnapshotOwner()
        let sharedScope = MCPToolSnapshotMutationScope(
            toolName: "click",
            effect: .mutation).completed(at: Date(), preserving: nil)
        let browserScope = MCPToolSnapshotMutationScope(
            toolName: "browser",
            effect: .mutation).completed(at: Date().addingTimeInterval(1), preserving: nil)

        await gate.recordPendingInvalidation(
            sharedScope,
            owner: owner,
            usesCoordinatorBarrier: true,
            snapshotMutationCoordinator: nil)
        await gate.recordPendingInvalidation(
            browserScope,
            owner: owner,
            usesCoordinatorBarrier: false,
            snapshotMutationCoordinator: nil)

        let firstPending = await gate.pendingInvalidation()
        let first = try #require(firstPending)
        #expect(first.scope.id == sharedScope.id)
        #expect(first.usesCoordinatorBarrier)
        await gate.clearPendingInvalidation(id: first.scope.id)
        let secondPending = await gate.pendingInvalidation()
        let second = try #require(secondPending)
        #expect(second.scope.id == browserScope.id)
        #expect(!second.usesCoordinatorBarrier)
        await gate.clearPendingInvalidation(id: second.scope.id)
        #expect(await gate.pendingInvalidation() == nil)
    }

    @Test
    func `Debt cleanup does not resurrect a retired snapshot owner`() async throws {
        let gate = MCPToolSnapshotExecutionGate()
        let retiredOwner = MCPToolSnapshotOwner()
        let retiredSnapshots = MCPToolUISnapshotStore(owner: retiredOwner)
        _ = await retiredSnapshots.createSnapshot(id: "retired")
        await retiredSnapshots.removeOwner()
        #expect(await !retiredSnapshots.hasOwnerState())
        await gate.recordPendingInvalidation(
            MCPToolSnapshotMutationScope(toolName: "browser", effect: .mutation)
                .completed(at: Date(), preserving: nil),
            owner: retiredOwner,
            usesCoordinatorBarrier: false,
            snapshotMutationCoordinator: nil)

        let services = PeekabooServices()
        let context = MCPToolContext(
            services: services,
            snapshotMutationCoordinator: LedgerMutationCoordinator(),
            snapshotExecutionGate: gate,
            snapshotOwner: MCPToolSnapshotOwner(),
            executionPolicy: .unrestricted)
        _ = try await context.execute(
            tool: LedgerMutationTool(),
            arguments: ToolArguments(raw: [:]))

        #expect(await !retiredSnapshots.hasOwnerState())
        #expect(await gate.pendingInvalidation() == nil)
    }

    private func makeReleaseFixture(
        invalidationResults: [Bool],
        browserEndResults: [Bool],
        recordDebt: Bool = true) async -> SnapshotReleaseFixture
    {
        let gate = MCPToolSnapshotExecutionGate()
        let owner = MCPToolSnapshotOwner()
        let coordinator = SequencedReleaseMutationCoordinator(results: invalidationResults)
        let browser = SnapshotReleaseBrowserClient(endResults: browserEndResults)
        let services = PeekabooServices()
        let context = MCPToolContext(
            automation: services.automation,
            menu: services.menu,
            windows: services.windows,
            applications: services.applications,
            dialogs: services.dialogs,
            dock: services.dock,
            screenCapture: services.screenCapture,
            desktopObservation: services.desktopObservation,
            snapshots: services.snapshots,
            screens: services.screens,
            agent: services.agent,
            permissions: services.permissions,
            clipboard: services.clipboard,
            browser: browser,
            snapshotMutationCoordinator: coordinator,
            snapshotExecutionGate: gate,
            snapshotOwner: owner,
            executionPolicy: .unrestricted)
        let snapshotID = "release-owner-\(UUID().uuidString)"
        if recordDebt {
            _ = await context.uiSnapshots.createSnapshot(id: snapshotID)
            let scope = MCPToolSnapshotMutationScope(
                toolName: "click",
                effect: .mutation)
                .completed(at: Date(), preserving: nil)
            await gate.recordPendingInvalidation(
                scope,
                owner: owner,
                usesCoordinatorBarrier: true,
                snapshotMutationCoordinator: coordinator)
        }
        return SnapshotReleaseFixture(
            context: context,
            gate: gate,
            coordinator: coordinator,
            browser: browser,
            snapshotID: snapshotID)
    }
}

private struct SnapshotReleaseFixture {
    let context: MCPToolContext
    let gate: MCPToolSnapshotExecutionGate
    let coordinator: SequencedReleaseMutationCoordinator
    let browser: SnapshotReleaseBrowserClient
    let snapshotID: String
}

private enum SnapshotReleaseFixtureError: Error {
    case injected
}

@MainActor
private final class SequencedReleaseMutationCoordinator: MCPToolSnapshotMutationCoordinating,
    @unchecked Sendable
{
    private var results: [Bool]
    private(set) var completionAttempts = 0

    init(results: [Bool]) {
        self.results = results
    }

    func completeMutation(_: MCPToolSnapshotMutationScope, succeeded _: Bool) async -> Bool {
        self.completionAttempts += 1
        return self.results.isEmpty ? true : self.results.removeFirst()
    }
}

@MainActor
private final class SnapshotReleaseBrowserClient: BrowserMCPAuthenticatedSessionEnding, @unchecked Sendable {
    private var endResults: [Bool]
    private(set) var endCount = 0

    init(endResults: [Bool]) {
        self.endResults = endResults
    }

    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        BrowserMCPStatus(isConnected: false, toolCount: 0, detectedBrowsers: [])
    }

    func connect(channel _: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        await self.status(channel: nil)
    }

    func disconnect() async {}

    func execute(
        toolName _: String,
        arguments _: [String: Any],
        channel _: BrowserMCPChannel?) async throws -> ToolResponse
    {
        .text("unused")
    }

    func endAuthenticatedBrowserSession() async -> Bool {
        self.endCount += 1
        return self.endResults.isEmpty ? true : self.endResults.removeFirst()
    }
}

@MainActor
private final class LedgerMutationCoordinator: MCPToolSnapshotMutationCoordinating, @unchecked Sendable {
    func completeMutation(_: MCPToolSnapshotMutationScope, succeeded _: Bool) async -> Bool {
        true
    }
}

@MainActor
private final class LegacyBarrierMutationCoordinator: MCPToolSnapshotMutationCoordinating, @unchecked Sendable {
    private(set) var sharedPrepareCount = 0
    private(set) var barrierCompletionCount = 0
    private(set) var mutationCompletionCount = 0

    func prepareMutation(_: MCPToolSnapshotMutationScope) throws {
        self.sharedPrepareCount += 1
    }

    func completeMutationBarrier(
        _: MCPToolSnapshotMutationScope) throws -> MCPToolMutationBarrierCompletion?
    {
        self.barrierCompletionCount += 1
        return MCPToolMutationBarrierCompletion(cutoff: Date(), allowsObservationPreservation: false)
    }

    func completeMutation(_: MCPToolSnapshotMutationScope, succeeded _: Bool) async -> Bool {
        self.mutationCompletionCount += 1
        return true
    }
}

private struct LedgerMutationTool: MCPTool {
    let name = "click"
    let description = "Ledger mutation fixture"
    let inputSchema = SchemaBuilder.object(properties: [:])

    @MainActor
    func execute(arguments _: ToolArguments) async throws -> ToolResponse {
        .text("ok")
    }
}

private struct LedgerBrowserMutationTool: MCPTool {
    let name = "browser"
    let description = "Browser mutation fixture"
    let inputSchema = SchemaBuilder.object(properties: [
        "action": SchemaBuilder.string(),
        "url": SchemaBuilder.string(),
        "background": SchemaBuilder.boolean(),
    ])

    @MainActor
    func execute(arguments _: ToolArguments) async throws -> ToolResponse {
        .text("ok")
    }
}
