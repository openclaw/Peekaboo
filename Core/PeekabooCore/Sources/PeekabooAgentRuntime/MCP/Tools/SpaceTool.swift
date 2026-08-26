import CoreGraphics
import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

@MainActor
protocol SpaceManaging: AnyObject {
    func getAllSpaces() -> [SpaceInfo]
    func moveWindowToCurrentSpaceResult(
        windowID: CGWindowID,
        expectedIdentity: WindowMutationIdentity) throws -> UIAutomationActionResult<Void>
    func moveWindowToSpaceResult(
        windowID: CGWindowID,
        expectedIdentity: WindowMutationIdentity,
        spaceID: CGSSpaceID) throws -> UIAutomationActionResult<Void>
    func switchToSpaceResult(_ spaceID: CGSSpaceID) async throws -> DesktopActionResult<Void>
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
    static let remoteExecutionRefusalErrorCode = "REMOTE_SPACE_EXECUTION_UNAVAILABLE"

    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "SpaceTool")
    private let spaceServiceOverride: SpaceServiceBox?
    let context: MCPToolContext

    public let name = "space"

    public var description: String {
        if self.context.executionPolicy == .backgroundOnly {
            return """
            Inspect macOS Spaces or move an exact window without following it under immutable background-only
            authority. Available actions are `list` and `move-window`. Space switching and `follow=true` change the
            user's visible desktop and require a human-authorized foreground-capable Agent session or standalone CLI.

            Examples:
            - List spaces: { "action": "list" }
            - Move window to space 3: { "action": "move-window", "app": "Safari", "to": 3 }
            - Move window to current space: { "action": "move-window", "app": "TextEdit", "to_current": true }
            \(PeekabooMCPVersion.banner)
            """
        }

        return """
        Manage macOS Spaces (virtual desktops).

        Actions:
        - list: List spaces with detailed information
        - switch: Switch to a specific space
        - move-window: Move windows between spaces

        Space switching changes the user's visible desktop. `switch` and `move-window` with `follow=true`
        require explicit `foreground=true`. Unfollowed window placement remains background-safe.

        Examples:
        - List spaces: { "action": "list" }
        - List with details: { "action": "list", "detailed": true }
        - Switch to space 2: { "action": "switch", "to": 2, "foreground": true }
        - Move window to space 3: { "action": "move-window", "app": "Safari", "to": 3 }
        - Move window to current space: { "action": "move-window", "app": "TextEdit", "to_current": true }
        - Move and follow: { "action": "move-window", "app": "Terminal", "to": 2, "follow": true,
          "foreground": true }
        \(PeekabooMCPVersion.banner) using openai/gpt-5.6, anthropic/claude-opus-5
        """
    }

    public var inputSchema: Value {
        let foregroundCapable = self.context.executionPolicy != .backgroundOnly
        let actions = foregroundCapable ? ["list", "switch", "move-window"] : ["list", "move-window"]
        var properties: [String: Value] = [
            "action": SchemaBuilder.string(
                description: foregroundCapable
                    ? "The action to perform"
                    : "Background-safe Space action; switching is unavailable",
                enum: actions),
            "to": SchemaBuilder.integer(
                description: "Space number to switch or move a window to"),
            "app": SchemaBuilder.string(
                description: "Application name for move-window action"),
            "window_id": SchemaBuilder.integer(
                description: "Exact window ID for move-window action"),
            "window_title": SchemaBuilder.string(
                description: "Window title to move"),
            "window_index": SchemaBuilder.integer(
                description: "Window index for multi-window apps"),
            "to_current": SchemaBuilder.boolean(
                description: "Move window to current space (for move-window action)",
                default: false),
            "detailed": SchemaBuilder.boolean(
                description: "Show detailed space information (for list action)",
                default: false),
        ]
        if foregroundCapable {
            properties["follow"] = SchemaBuilder.boolean(
                description: "Follow the window to the new space; requires foreground=true",
                default: false)
            properties["foreground"] = SchemaBuilder.boolean(
                description: "Explicit consent for switch and move-window follow actions",
                default: false)
        }
        return SchemaBuilder.object(
            properties: properties,
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
        let parsedAction: SpaceAction

        do {
            parsedAction = try self.parseAction(arguments: arguments)
        } catch let validationError as SpaceActionValidationError {
            return ToolResponse.error(validationError.message)
        } catch {
            return ToolResponse.error(error.localizedDescription)
        }

        if let message = parsedAction.foregroundConsentRefusalMessage {
            return MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
                message: message,
                reason: .foregroundConsentRequired)
        }

        if self.spaceServiceOverride == nil, self.context.executionHost == .remote {
            return Self.remoteExecutionRefusal(action: parsedAction)
        }

        let spaceService: any SpaceManaging = self.spaceServiceOverride?.service ?? SpaceManagementService()

        do {
            return try await self.perform(action: parsedAction, service: spaceService, startTime: Date())
        } catch let failure as DesktopActionFailure {
            self.logger.error("Space operation execution refused or failed: \(failure)")
            return (try? MCPToolResponseMetadataProjector.errorResponse(
                for: failure,
                invalidatedSnapshotID: nil)) ?? ToolResponse.error(failure.localizedDescription)
        } catch {
            self.logger.error("Space operation execution failed: \(error)")
            return ToolResponse.error("Failed to \(parsedAction.description): \(error.localizedDescription)")
        }
    }

    private static func remoteExecutionRefusal(action: SpaceAction) -> ToolResponse {
        MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
            message: "Cannot \(action.description) Spaces through a remote service context because remote Spaces " +
                "are not implemented. No local Space operation was dispatched.",
            reason: .operationUnsupported,
            additionalFields: [
                "error_code": .string(self.remoteExecutionRefusalErrorCode),
                "execution_host": .string(PeekabooServiceExecutionHost.remote.rawValue),
            ])
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
            guard let spaceNumber = try arguments.validatedInt("to") else {
                throw SpaceActionValidationError("Switch action requires 'to' parameter (space number)")
            }
            return .switchSpace(
                spaceNumber: spaceNumber,
                foreground: arguments.getBool("foreground") ?? false)
        case "move-window":
            return try self.parseMoveWindow(arguments: arguments)
        default:
            throw SpaceActionValidationError(
                "Unknown action: \(actionName). Supported actions: list, switch, move-window")
        }
    }

    private func parseMoveWindow(arguments: ToolArguments) throws -> SpaceAction {
        let appName = arguments.getString("app")
        let windowID = try arguments.validatedInt("window_id")
        guard appName != nil || windowID != nil else {
            throw SpaceActionValidationError("Move-window action requires 'app' or 'window_id' parameter")
        }
        if let windowID, windowID <= 0 || UInt32(exactly: windowID) == nil {
            throw SpaceActionValidationError("Move-window action requires a valid positive 'window_id'")
        }
        if windowID != nil,
           arguments.getValue(for: "window_title") != nil || arguments.getValue(for: "window_index") != nil
        {
            throw SpaceActionValidationError("Cannot combine 'window_id' with title or index selectors")
        }

        let toCurrent = arguments.getBool("to_current") ?? false
        let targetSpace = try arguments.validatedInt("to")

        if toCurrent, targetSpace != nil {
            throw SpaceActionValidationError("Cannot specify both 'to_current' and 'to' parameters")
        }

        if !toCurrent, targetSpace == nil {
            throw SpaceActionValidationError(
                "Move-window action requires either 'to' (space number) or 'to_current' parameter")
        }

        let request = try MoveWindowRequest(
            appName: appName,
            windowID: windowID,
            windowTitle: arguments.getString("window_title"),
            windowIndex: arguments.validatedInt("window_index"),
            targetSpaceNumber: targetSpace,
            toCurrent: toCurrent,
            follow: arguments.getBool("follow") ?? false,
            foreground: arguments.getBool("foreground") ?? false)

        return .moveWindow(request)
    }
}

enum SpaceAction {
    case list(detailed: Bool)
    case switchSpace(spaceNumber: Int, foreground: Bool)
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

    var foregroundConsentRefusalMessage: String? {
        switch self {
        case .list:
            nil
        case let .switchSpace(_, foreground) where !foreground:
            "Space switch changes the visible desktop and requires foreground=true."
        case let .moveWindow(request) where request.follow && !request.foreground:
            "Space move-window follow changes the visible desktop and requires foreground=true."
        case .switchSpace, .moveWindow:
            nil
        }
    }
}

struct MoveWindowRequest {
    let appName: String?
    let windowID: Int?
    let windowTitle: String?
    let windowIndex: Int?
    let targetSpaceNumber: Int?
    let toCurrent: Bool
    let follow: Bool
    let foreground: Bool
}

private struct SpaceActionValidationError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
