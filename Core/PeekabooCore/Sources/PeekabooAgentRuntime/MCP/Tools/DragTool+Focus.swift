import Foundation
import PeekabooAutomation

extension DragTool {
    func focusTargetIfNeeded(
        request: DragRequest,
        from: DragPointDescription,
        to: DragPointDescription) async throws
    {
        let target: WindowTarget? = if let windowID = from.windowID ?? to.windowID {
            WindowTarget.windowId(windowID)
        } else if let appName = from.targetApp ?? to.targetApp,
                  let windowTitle = from.windowTitle ?? to.windowTitle
        {
            WindowTarget.applicationAndTitle(app: appName, title: windowTitle)
        } else if let appName = from.targetApp ?? to.targetApp ?? request.targetApp {
            WindowTarget.application(appName)
        } else {
            nil
        }
        guard let target else { return }
        try await self.context.windows.focusWindow(target: target)
    }
}
