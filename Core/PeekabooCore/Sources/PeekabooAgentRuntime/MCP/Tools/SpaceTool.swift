import CoreGraphics
import Foundation
import MCP
import os.log
import PeekabooAutomation
import TachikomaMCP

@MainActor
protocol SpaceManaging: AnyObject {
    func getAllSpaces() -> [SpaceInfo]
    func moveWindowToCurrentSpace(windowID: CGWindowID) throws
    func moveWindowToSpace(windowID: CGWindowID, spaceID: CGSSpaceID) throws
    func switchToSpace(_ spaceID: CGSSpaceID) async throws
}

extension SpaceManagementService: SpaceManaging {}

private final class SpaceServiceBox: @unchecked Sendable {
    let service: any SpaceManaging

    init(service: any SpaceManaging) {
        self.service = service
    }
}

/// MCP tool for managing macOS Spaces (virtual desktops)
public struct SpaceTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "SpaceTool")
    private let spaceServiceOverride: SpaceServiceBox?
    let context: MCPToolContext

    public let name = "space"

    public var description: String {
        """
        Manage macOS Spaces (virtual desktops).

        Actions:
        - list: List spaces with detailed information
        - switch: Switch to a specific space
        - move-window: Move windows between spaces

        Supports moving windows with optional follow behavior to switch along with the window.

        Examples:
        - List spaces: { "action": "list" }
        - List with details: { "action": "list", "detailed": true }
        - Switch to space 2: { "action": "switch", "to": 2 }
        - Move window to space 3: { "action": "move-window", "app": "Safari", "to": 3 }
        - Move window to current space: { "action": "move-window", "app": "TextEdit", "to_current": true }
        - Move and follow: { "action": "move-window", "app": "Terminal", "to": 2, "follow": true }
        \(PeekabooMCPVersion.banner) using openai/gpt-5.5, anthropic/claude-opus-4-8
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "action": SchemaBuilder.string(
                    description: "The action to perform",
                    enum: ["list", "switch", "move-window"]),
                "to": SchemaBuilder.number(
                    description: "Space number to switch to (for switch action)"),
                "app": SchemaBuilder.string(
                    description: "Application name for move-window action"),
                "window_title": SchemaBuilder.string(
                    description: "Window title to move"),
                "window_index": SchemaBuilder.number(
                    description: "Window index for multi-window apps"),
                "to_current": SchemaBuilder.boolean(
                    description: "Move window to current space (for move-window action)",
                    default: false),
                "follow": SchemaBuilder.boolean(
                    description: "Follow the window to the new space (for move-window action)",
                    default: false),
                "detailed": SchemaBuilder.boolean(
                    description: "Show detailed space information (for list action)",
                    default: false),
            ],
            required: ["action"])
    }

    public init(context: MCPToolContext = .shared) {
        self.spaceServiceOverride = nil
        self.context = context
    }

    init(testingSpaceService: any SpaceManaging, context: MCPToolContext = .shared) {
        self.spaceServiceOverride = SpaceServiceBox(service: testingSpaceService)
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        let spaceService: any SpaceManaging = self.spaceServiceOverride?.service ?? SpaceManagementService()
        let parsedAction: SpaceAction

        do {
            parsedAction = try self.parseAction(arguments: arguments)
        } catch let validationError as SpaceActionValidationError {
            return ToolResponse.error(validationError.message)
        }

        do {
            return try await self.perform(action: parsedAction, service: spaceService, startTime: Date())
        } catch {
            self.logger.error("Space operation execution failed: \(error)")
            return ToolResponse.error("Failed to \(parsedAction.description): \(error.localizedDescription)")
        }
    }

    private func parseAction(arguments: ToolArguments) throws -> SpaceAction {
        guard let actionName = arguments.getString("action") else {
            throw SpaceActionValidationError("Missing required parameter: action")
        }

        switch actionName {
        case "list":
            let detailed = arguments.getBool("detailed") ?? false
            return .list(detailed: detailed)
        case "switch":
            guard let spaceNumber = arguments.getNumber("to").map(Int.init) else {
                throw SpaceActionValidationError("Switch action requires 'to' parameter (space number)")
            }
            return .switchSpace(spaceNumber: spaceNumber)
        case "move-window":
            return try self.parseMoveWindow(arguments: arguments)
        default:
            throw SpaceActionValidationError(
                "Unknown action: \(actionName). Supported actions: list, switch, move-window")
        }
    }

    private func parseMoveWindow(arguments: ToolArguments) throws -> SpaceAction {
        guard let appName = arguments.getString("app") else {
            throw SpaceActionValidationError("Move-window action requires 'app' parameter")
        }

        let toCurrent = arguments.getBool("to_current") ?? false
        let targetSpace = arguments.getNumber("to").map(Int.init)

        if toCurrent, targetSpace != nil {
            throw SpaceActionValidationError("Cannot specify both 'to_current' and 'to' parameters")
        }

        if !toCurrent, targetSpace == nil {
            throw SpaceActionValidationError(
                "Move-window action requires either 'to' (space number) or 'to_current' parameter")
        }

        let request = MoveWindowRequest(
            appName: appName,
            windowTitle: arguments.getString("window_title"),
            windowIndex: arguments.getInt("window_index"),
            targetSpaceNumber: targetSpace,
            toCurrent: toCurrent,
            follow: arguments.getBool("follow") ?? false)

        return .moveWindow(request)
    }
}

enum SpaceAction {
    case list(detailed: Bool)
    case switchSpace(spaceNumber: Int)
    case moveWindow(MoveWindowRequest)

    var description: String {
        switch self {
        case .list:
            "list"
        case .switchSpace:
            "switch"
        case .moveWindow:
            "move-window"
        }
    }
}

struct MoveWindowRequest {
    let appName: String
    let windowTitle: String?
    let windowIndex: Int?
    let targetSpaceNumber: Int?
    let toCurrent: Bool
    let follow: Bool
}

private struct SpaceActionValidationError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
