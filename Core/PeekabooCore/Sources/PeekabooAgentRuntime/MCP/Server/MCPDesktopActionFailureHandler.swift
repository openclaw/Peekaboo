import MCP
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
