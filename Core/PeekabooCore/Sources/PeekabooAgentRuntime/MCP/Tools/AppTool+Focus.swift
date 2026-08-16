import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

@MainActor
extension AppToolActions {
    func handleFocus(request: AppToolRequest, mode: FocusMode) async throws -> ToolResponse {
        switch mode {
        case .appSwitch where request.cycle:
            let actionResult = try await self.cycleApplications()
            try ApplicationActionResultSemantics.requireSuccessfulOutcome(
                actionResult.outcome,
                operation: "Application switch cycle")
            return try ToolResponse(
                content: [.text(
                    text: "\(AgentDisplayTokens.Status.success) Switched to next application",
                    annotations: nil,
                    _meta: nil)],
                meta: MCPToolResponseMetadataProjector.metadata(
                    merging: self.executionMeta(from: request.startTime).objectValue ?? [:],
                    outcome: actionResult.outcome))

        case .appSwitch:
            guard let identifier = request.switchTarget else {
                return ToolResponse.error("Must specify 'to' for switch action")
            }
            let app = try await self.service.findApplication(identifier: identifier)
            let actionResult = try await self.activateApplication(app)
            return try self.focusResponse(
                app: app,
                startTime: request.startTime,
                verb: "Switched",
                outcome: actionResult.outcome)

        case .focus:
            guard let identifier = request.name else {
                return ToolResponse.error("Must specify 'name' for focus action")
            }
            let app = try await self.service.findApplication(identifier: identifier)
            let actionResult = try await self.activateApplication(app)
            return try self.focusResponse(
                app: app,
                startTime: request.startTime,
                verb: "Focused",
                outcome: actionResult.outcome)
        }
    }

    private func activateApplication(_ appInfo: ServiceApplicationInfo) async throws -> DesktopActionResult<Void> {
        do {
            let request = try ApplicationActivationRequest(application: appInfo)
            return try await self.service.activateApplicationResult(request: request)
        } catch {
            self.logger.error("Failed to activate \(appInfo.name, privacy: .public): \(error, privacy: .public)")
            throw error
        }
    }

    private func cycleApplications() async throws -> DesktopActionResult<Void> {
        do {
            if let outcomes = self.automation as? any UIAutomationActionOutcomeProviding {
                return try await outcomes.hotkeyWithOutcome(
                    keys: "cmd,tab",
                    holdDuration: 50).desktopActionResult
            }
            try await self.automation.hotkey(keys: "cmd,tab", holdDuration: 50)
            return DesktopActionResult(outcome: nil)
        } catch {
            self.logger.error("Failed to send Cmd+Tab: \(error, privacy: .public)")
            throw error
        }
    }
}
