import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

enum MCPDesktopActionFailureHandler {
    @MainActor
    static func response(
        for failure: DesktopActionFailure,
        uiSnapshots: MCPToolUISnapshotStore,
        snapshotID: String?,
        additionalFields: [String: Value] = [:]) async throws -> ToolResponse
    {
        let invalidatedSnapshotID = await MCPDesktopActionSnapshotInvalidator.invalidate(
            uiSnapshots: uiSnapshots,
            snapshotID: snapshotID,
            outcome: failure.outcome)
        return try MCPToolResponseMetadataProjector.errorResponse(
            for: failure,
            invalidatedSnapshotID: invalidatedSnapshotID,
            additionalFields: additionalFields)
    }
}

enum MCPDesktopActionSnapshotInvalidator {
    @MainActor
    static func invalidate(
        uiSnapshots: MCPToolUISnapshotStore,
        snapshotID: String?,
        outcome: DesktopActionOutcome?) async -> String?
    {
        await self.invalidate(
            uiSnapshots: uiSnapshots,
            snapshotID: snapshotID,
            mutationDispatched: outcome?.dispatchState.mutationDispatched ?? true)
    }

    @MainActor
    static func invalidate(
        uiSnapshots: MCPToolUISnapshotStore,
        snapshotID: String?,
        mutationDispatched: Bool) async -> String?
    {
        guard mutationDispatched else { return nil }
        return await uiSnapshots.invalidateActiveSnapshot(id: snapshotID)
    }
}

enum MCPElementActionSnapshotAuthority {
    @MainActor
    static func withConfirmedMutation(
        snapshot: UISnapshot,
        expectedTarget: DesktopTargetIdentity,
        context: MCPToolContext,
        operation: String,
        mutate: () async throws -> UIAutomationActionResult<ElementActionResult>,
        validateResult: (UIAutomationActionResult<ElementActionResult>) throws -> Void = { _ in }) async throws
        -> (result: UIAutomationActionResult<ElementActionResult>, invalidatedSnapshotID: String?)
    {
        let result = try await context.snapshots.withSnapshotMutation(
            snapshotId: snapshot.id,
            targetIdentity: expectedTarget,
            operation: {
                let result = try await mutate()
                _ = try UIAutomationActionResultSemantics.requireAcceptedOutcome(
                    result,
                    policy: .confirmed(requiring: .background),
                    targetRequirement: .compatible(expectedTarget),
                    operation: operation)
                try validateResult(result)
                return result
            },
            outcome: { $0.outcome })
        let invalidatedSnapshotID = await MCPDesktopActionSnapshotInvalidator.invalidate(
            uiSnapshots: context.uiSnapshots,
            snapshotID: snapshot.id,
            outcome: result.outcome)
        return (result, invalidatedSnapshotID)
    }

    static func expectedTargetIdentity(
        _ snapshot: UISnapshot,
        requireExactWindow: Bool = false) throws -> DesktopTargetIdentity
    {
        let receipt: SnapshotTargetReceipt
        do {
            receipt = try snapshot.targetReceipt()
            if !requireExactWindow {
                return try DesktopTargetIdentity(processIdentity: receipt.requireIdentity().processIdentity)
            }
            if case .invalidated = receipt.targetEvidence {
                _ = try receipt.requireIdentity()
            }
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The selected snapshot has no consistent process-generation receipt.",
                hint: "Run 'peekaboo see' or 'inspect_ui' again before retrying this element action.",
                causeDescription: error.localizedDescription,
                standardErrorCode: .snapshotStale)
        }
        guard let exactWindow = receipt.identity?.exactWindow else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Text selection requires a fresh exact-window snapshot.",
                hint: "Run 'see' or 'inspect_ui' with window_id, then retry with that fresh exact-window snapshot.",
                standardErrorCode: .invalidInput)
        }
        return DesktopTargetIdentity(exactWindow: exactWindow)
    }
}
