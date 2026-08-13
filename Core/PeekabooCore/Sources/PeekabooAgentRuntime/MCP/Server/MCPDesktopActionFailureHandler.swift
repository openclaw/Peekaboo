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
        let invalidatedSnapshotID: String? = if failure.outcome.dispatchState.mutationDispatched {
            await uiSnapshots.invalidateActiveSnapshot(id: snapshotID)
        } else {
            nil
        }
        return try MCPToolResponseMetadataProjector.errorResponse(
            for: failure,
            invalidatedSnapshotID: invalidatedSnapshotID,
            additionalFields: additionalFields)
    }
}
