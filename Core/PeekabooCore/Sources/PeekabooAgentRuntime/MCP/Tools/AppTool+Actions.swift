import Foundation
import MCP
import os.log
import PeekabooAutomation
import TachikomaMCP

@MainActor
struct AppToolActions {
    enum FocusMode {
        case focus
        case appSwitch
    }

    let service: any ApplicationServiceProtocol
    let automation: any UIAutomationServiceProtocol
    let logger: Logger
    let context: MCPToolContext?

    init(
        service: any ApplicationServiceProtocol,
        automation: any UIAutomationServiceProtocol,
        logger: Logger,
        context: MCPToolContext? = nil)
    {
        self.service = service
        self.automation = automation
        self.logger = logger
        self.context = context
    }

    func perform(action: String, request: AppToolRequest) async throws -> ToolResponse {
        switch action {
        case "launch":
            return try await self.handleLaunch(request: request)
        case "open":
            return try await self.handleOpen(request: request)
        case "quit":
            return try await self.handleQuit(request: request)
        case "relaunch":
            return try await self.handleRelaunch(request: request)
        case "focus":
            return try await self.handleFocus(request: request, mode: .focus)
        case "switch":
            return try await self.handleFocus(request: request, mode: .appSwitch)
        case "hide":
            return try await self.handleHide(request: request)
        case "unhide":
            return try await self.handleUnhide(request: request)
        case "list":
            return try await self.handleList(request: request)
        default:
            let supported = "launch, open, quit, relaunch, focus, hide, unhide, switch, list"
            return ToolResponse.error("Unknown action: \(action). Supported actions: \(supported)")
        }
    }
}
