import Foundation
import PeekabooAutomation

extension DragTool {
    func focusTargetIfNeeded(
        request: DragRequest,
        from: DragPointDescription,
        to: DragPointDescription) async throws -> MCPInteractionFocusResult?
    {
        let target: MCPInteractionTarget? = if let windowID = from.windowID ?? to.windowID {
            try MCPInteractionTarget(
                app: nil,
                pid: nil,
                windowTitle: nil,
                windowIndex: nil,
                windowId: windowID)
        } else if let appName = from.targetApp ?? to.targetApp,
                  let windowTitle = from.windowTitle ?? to.windowTitle
        {
            try MCPInteractionTarget(
                app: appName,
                pid: nil,
                windowTitle: windowTitle,
                windowIndex: nil,
                windowId: nil)
        } else if let appName = from.targetApp ?? to.targetApp ?? request.targetApp {
            try MCPInteractionTarget(
                app: appName,
                pid: nil,
                windowTitle: nil,
                windowIndex: nil,
                windowId: nil)
        } else {
            nil
        }
        guard let target else { return nil }
        return try await target.focusResultIfRequested(
            windows: self.context.windows,
            onlyWhenTargeted: true)
    }
}
