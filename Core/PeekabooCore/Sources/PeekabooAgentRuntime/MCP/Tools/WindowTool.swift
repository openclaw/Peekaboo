import Foundation
import MCP
import os.log
import PeekabooAutomation
import TachikomaMCP

/// MCP tool for manipulating application windows
public struct WindowTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "WindowTool")
    private let context: MCPToolContext

    public let name = "window"

    public var description: String {
        """
        Manipulate application windows - close, minimize, maximize, move, resize, and focus.

        Actions:
        - close: Close a window
        - minimize: Minimize a window
        - maximize: Maximize a window
        - move: Move a window to specific coordinates (requires x, y)
        - resize: Resize a window to specific dimensions (requires width, height)
        - set-bounds: Set both position and size (requires x, y, width, height)
        - focus: Bring a window to the foreground

        Target windows by application name and optionally by window title or index.
        For deterministic targeting, prefer `window_id` (from `peekaboo window list`).
        Supports partial title matching for convenience.

        JSON Examples (ALWAYS include `action`):
        - { "action": "focus", "app": "Google Chrome" }
        - { "action": "move", "app": "TextEdit", "x": 100, "y": 100 }
        - { "action": "set-bounds", "app": "Terminal", "x": 0, "y": 0, "width": 1280, "height": 720 }
        - { "action": "close", "app": "Safari", "title": "Grindr Web" }
        \(PeekabooMCPVersion.banner) using openai/gpt-5.5, anthropic/claude-opus-4-8
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "action": SchemaBuilder.string(
                    description: "The action to perform on the window",
                    enum: ["close", "minimize", "maximize", "move", "resize", "set-bounds", "focus"]),
                "app": SchemaBuilder.string(
                    description: "Target application name, bundle ID, or process ID"),
                "title": SchemaBuilder.string(
                    description: "Window title to target (partial matching supported)"),
                "index": SchemaBuilder.number(
                    description: "Window index (0-based) for multi-window applications"),
                "window_id": SchemaBuilder.number(
                    description: "Window ID (from window list); preferred stable selector"),
                "x": SchemaBuilder.number(
                    description: "X coordinate for move or set-bounds action"),
                "y": SchemaBuilder.number(
                    description: "Y coordinate for move or set-bounds action"),
                "width": SchemaBuilder.number(
                    description: "Width for resize or set-bounds action"),
                "height": SchemaBuilder.number(
                    description: "Height for resize or set-bounds action"),
            ],
            required: ["action"])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        guard let actionName = arguments.getString("action") else {
            return ToolResponse.error("Missing required parameter: action")
        }

        guard let action = WindowAction(rawValue: actionName) else {
            let supported = WindowAction.allCases.map(\.description).joined(separator: ", ")
            return ToolResponse.error("Unknown action: \(actionName). Supported actions: \(supported)")
        }

        let app = arguments.getString("app")
        let title = arguments.getString("title")
        let index = arguments.getInt("index")
        let windowId = arguments.getInt("window_id")
        let x = arguments.getNumber("x")
        let y = arguments.getNumber("y")
        let width = arguments.getNumber("width")
        let height = arguments.getNumber("height")

        let inputs = WindowActionInputs(
            app: app,
            title: title,
            index: index,
            windowId: windowId,
            x: x,
            y: y,
            width: width,
            height: height)
        let windowService = self.context.windows
        let startTime = Date()

        do {
            return try await self.perform(
                action: action,
                inputs: inputs,
                service: windowService,
                startTime: startTime)
        } catch let validationError as WindowActionError {
            return ToolResponse.error(validationError.message)
        } catch {
            self.logger.error("Window operation execution failed: \(error)")
            return ToolResponse.error("Failed to \(action.description) window: \(error.localizedDescription)")
        }
    }

    private func perform(
        action: WindowAction,
        inputs: WindowActionInputs,
        service: any WindowManagementServiceProtocol,
        startTime: Date) async throws -> ToolResponse
    {
        let target = try self.createWindowTarget(
            app: inputs.app,
            title: inputs.title,
            index: inputs.index,
            windowId: inputs.windowId)

        switch action {
        case .close:
            return try await self.handleClose(
                service: service,
                target: target,
                appName: inputs.app,
                startTime: startTime)

        case .minimize:
            return try await self.handleMinimize(
                service: service,
                target: target,
                appName: inputs.app,
                startTime: startTime)

        case .maximize:
            return try await self.handleMaximize(
                service: service,
                target: target,
                appName: inputs.app,
                startTime: startTime)

        case .move:
            let position = try inputs.requirePosition(for: action)
            return try await self.handleMove(
                service: service,
                target: target,
                appName: inputs.app,
                position: position,
                startTime: startTime)

        case .resize:
            let size = try inputs.requireSize(for: action)
            return try await self.handleResize(
                service: service,
                target: target,
                appName: inputs.app,
                size: size,
                startTime: startTime)

        case .setBounds:
            let bounds = try inputs.requireBounds()
            return try await self.handleSetBounds(
                service: service,
                target: target,
                appName: inputs.app,
                bounds: bounds,
                startTime: startTime)

        case .focus:
            return try await self.handleFocus(
                service: service,
                target: target,
                appName: inputs.app,
                startTime: startTime)
        }
    }

    // MARK: - Helper Methods

    private func createWindowTarget(app: String?, title: String?, index: Int?, windowId: Int?) throws -> WindowTarget {
        if let windowId {
            return .windowId(windowId)
        }

        if let app, let title {
            return .applicationAndTitle(app: app, title: title)
        }

        if let app, let index {
            return .index(app: app, index: index)
        }

        if let app {
            return .application(app)
        }

        if let title {
            return .title(title)
        }

        throw WindowActionError.missingParameters(
            "Must specify at least 'window_id', 'app', or 'title' parameter to target a window")
    }
}

private enum WindowAction: String, CaseIterable {
    case close
    case minimize
    case maximize
    case move
    case resize
    case setBounds = "set-bounds"
    case focus

    var description: String {
        self.rawValue
    }
}

private struct WindowActionInputs {
    let app: String?
    let title: String?
    let index: Int?
    let windowId: Int?
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?

    func requirePosition(for action: WindowAction) throws -> CGPoint {
        guard let x, let y else {
            let message = "\(action.description) action requires both 'x' and 'y' coordinates"
            throw WindowActionError.missingParameters(message)
        }
        return CGPoint(x: x, y: y)
    }

    func requireSize(for action: WindowAction) throws -> CGSize {
        guard let width, let height else {
            let message = "\(action.description) action requires both 'width' and 'height' dimensions"
            throw WindowActionError.missingParameters(message)
        }
        return CGSize(width: width, height: height)
    }

    func requireBounds() throws -> CGRect {
        let origin = try requirePosition(for: .setBounds)
        let size = try requireSize(for: .setBounds)
        return CGRect(origin: origin, size: size)
    }
}

private enum WindowActionError: Error {
    case missingParameters(String)

    var message: String {
        switch self {
        case let .missingParameters(details):
            details
        }
    }
}
