import Foundation
import MCP
import os.log
import PeekabooAutomation
import TachikomaMCP

@MainActor
extension AppToolActions {
    func handleFocus(request: AppToolRequest, mode: FocusMode) async throws -> ToolResponse {
        switch mode {
        case .appSwitch where request.cycle:
            await self.cycleApplications()
            return ToolResponse(
                content: [.text(
                    text: "\(AgentDisplayTokens.Status.success) Switched to next application",
                    annotations: nil,
                    _meta: nil)],
                meta: self.executionMeta(from: request.startTime))

        case .appSwitch:
            guard let identifier = request.switchTarget else {
                return ToolResponse.error("Must specify 'to' for switch action")
            }
            let app = try await self.service.findApplication(identifier: identifier)
            guard await self.activateApplication(app) else {
                return ToolResponse.error("Failed to focus \(app.name). Application may not be running.")
            }
            return self.focusResponse(app: app, startTime: request.startTime, verb: "Switched")

        case .focus:
            guard let identifier = request.name else {
                return ToolResponse.error("Must specify 'name' for focus action")
            }
            let app = try await self.service.findApplication(identifier: identifier)
            guard await self.activateApplication(app) else {
                return ToolResponse.error("Failed to focus \(app.name). Application may not be running.")
            }
            return self.focusResponse(app: app, startTime: request.startTime, verb: "Focused")
        }
    }

    private func activateApplication(_ appInfo: ServiceApplicationInfo) async -> Bool {
        do {
            try await self.service.activateApplication(
                request: ApplicationActivationRequest(application: appInfo))
            return true
        } catch {
            self.logger.error("Failed to activate \(appInfo.name, privacy: .public): \(error, privacy: .public)")
            return false
        }
    }

    private func cycleApplications() async {
        do {
            try await self.automation.hotkey(keys: "cmd,tab", holdDuration: 50)
        } catch {
            self.logger.error("Failed to send Cmd+Tab: \(error, privacy: .public)")
        }
    }
}
