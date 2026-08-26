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
            usesCoordinatorBarrier: true)
        await gate.recordPendingInvalidation(
            browserScope,
            owner: owner,
            usesCoordinatorBarrier: false)

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
            usesCoordinatorBarrier: false)

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
