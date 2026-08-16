import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

/// MCP tool for manipulating application windows
public struct WindowTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "WindowTool")
    let context: MCPToolContext

    public let name = "window"

    public var description: String {
        """
        List and manipulate application windows.

        Actions:
        - list: List an application's windows with IDs, bounds, and off-screen state
        - close: Close a window
        - minimize: Minimize a window
        - restore: Restore a minimized window without activating or focusing its application
        - maximize: Maximize a window
        - move: Move a window to specific coordinates (requires x, y)
        - resize: Resize a window to specific dimensions (requires width, height)
        - set-bounds: Set both position and size (requires x, y, width, height)
        - focus: Bring a window to the foreground

        Target windows by application name and optionally by window title or index.
        For deterministic targeting, prefer `window_id` (from `peekaboo window list`).
        Supports partial title matching for convenience.

        JSON Examples (ALWAYS include `action`):
        - { "action": "list", "app": "Safari" }
        - { "action": "focus", "app": "Google Chrome" }
        - { "action": "move", "app": "TextEdit", "x": 100, "y": 100 }
        - { "action": "restore", "app": "PID:1234", "window_id": 5678 }
        - { "action": "set-bounds", "app": "Terminal", "x": 0, "y": 0, "width": 1280, "height": 720 }
        - { "action": "close", "app": "Safari", "title": "Grindr Web" }
        \(PeekabooMCPVersion.banner) using openai/gpt-5.6, anthropic/claude-opus-5
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "action": SchemaBuilder.string(
                    description: "The action to perform on the window",
                    enum: [
                        "list",
                        "close",
                        "minimize",
                        "restore",
                        "maximize",
                        "move",
                        "resize",
                        "set-bounds",
                        "focus",
                    ]),
                "app": SchemaBuilder.string(
                    description: "Target application name, bundle ID, or process ID"),
                "title": SchemaBuilder.string(
                    description: "Window title to target (partial matching supported)"),
                "index": SchemaBuilder.integer(
                    description: "Window index (0-based) for multi-window applications"),
                "window_id": SchemaBuilder.integer(
                    description: "Window ID (from window list); preferred stable selector"),
                "x": SchemaBuilder.number(
                    description: "X coordinate for move or set-bounds action"),
                "y": SchemaBuilder.number(
                    description: "Y coordinate for move or set-bounds action"),
                "width": SchemaBuilder.number(
                    description: "Width for resize or set-bounds action"),
                "height": SchemaBuilder.number(
                    description: "Height for resize or set-bounds action"),
                "foreground": SchemaBuilder.boolean(
                    description: "For close only: allow focused/global fallback after AX close fails.",
                    default: false),
                "include_window_details": SchemaBuilder.array(
                    items: SchemaBuilder.string(enum: WindowDetail.allCases.map(\.rawValue)),
                    description: "Details for list results. Defaults to ids, bounds, and off_screen."),
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
        let index: Int?
        let windowId: Int?
        do {
            index = try arguments.validatedInt("index")
            windowId = try arguments.validatedInt("window_id")
        } catch {
            return ToolResponse.error(error.localizedDescription)
        }
        let x = arguments.getNumber("x")
        let y = arguments.getNumber("y")
        let width = arguments.getNumber("width")
        let height = arguments.getNumber("height")
        let foreground = arguments.getBool("foreground") ?? false
        if foreground {
            guard action == .close else {
                return ToolResponse.error("foreground is only supported for the close action")
            }
        }

        if action == .list {
            guard let app, !app.isEmpty else {
                return ToolResponse.error("Missing required parameter: app (required for list action)")
            }
            let rawDetails = arguments.getStringArray("include_window_details")
                ?? WindowDetail.allCases.map(\.rawValue)
            do {
                let details = try Set(rawDetails.map { raw in
                    guard let detail = WindowDetail(rawValue: raw) else {
                        throw WindowActionError.missingParameters(
                            "Unknown value in 'include_window_details': \(raw).")
                    }
                    return detail
                })
                return try await self.listWindows(app: app, details: details)
            } catch let validationError as WindowActionError {
                return ToolResponse.error(validationError.message)
            } catch {
                return ToolResponse.error("Failed to list windows: \(error.localizedDescription)")
            }
        }

        let inputs = WindowActionInputs(
            app: app,
            title: title,
            index: index,
            windowId: windowId,
            x: x,
            y: y,
            width: width,
            height: height,
            foreground: foreground)
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
        } catch let failure as DesktopActionFailure {
            self.logger.error("Window operation execution failed: \(failure)")
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: nil)
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
        let operation = "Window \(action.description)"
        let authorizedPlan = try self.context.authorizedDesktopTargetPlan(operation: operation)
        let authorizedWindow = try authorizedPlan?.requireSelectedWindow(operation: operation)
        let rawTarget = if let authorizedWindow {
            WindowTarget.windowId(authorizedWindow.windowID)
        } else {
            try self.createWindowTarget(
                app: inputs.app,
                title: inputs.title,
                index: inputs.index,
                windowId: inputs.windowId)
        }
        let expectedOwnerIdentity: ApplicationProcessIdentity?
        if let authorizedPlan {
            expectedOwnerIdentity = authorizedPlan.processIdentity
        } else if inputs.windowId != nil, let app = inputs.app {
            let application = try await self.context.applications.findApplication(identifier: app)
            guard let identity = application.processIdentity else {
                throw PeekabooError.commandFailed("The selected application did not include a process receipt")
            }
            expectedOwnerIdentity = identity
        } else {
            expectedOwnerIdentity = nil
        }
        let target = WindowActionTarget(
            target: rawTarget,
            expectedOwnerIdentity: expectedOwnerIdentity,
            authorizedWindow: authorizedWindow)

        switch action {
        case .list:
            preconditionFailure("list is handled before window mutation dispatch")

        case .close:
            return try await self.handleClose(
                service: service,
                target: target,
                appName: inputs.app,
                allowForegroundFallback: inputs.foreground,
                startTime: startTime)

        case .minimize:
            return try await self.handleMinimize(
                service: service,
                target: target,
                appName: inputs.app,
                startTime: startTime)

        case .restore:
            return try await self.handleRestore(
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

    private func listWindows(app: String, details: Set<WindowDetail>) async throws -> ToolResponse {
        let output = try await self.context.applications.listWindows(for: app, timeout: nil)
        return WindowListFormatter(
            appInfo: output.data.targetApplication,
            identifier: app,
            windows: output.data.windows,
            details: details).response()
    }

    // MARK: - Helper Methods

    private func createWindowTarget(app: String?, title: String?, index: Int?, windowId: Int?) throws -> WindowTarget {
        let selector = InteractionTargetSelector(
            applicationIdentifier: app,
            windowID: windowId,
            windowTitle: title,
            windowIndex: index)
        try selector.validate(policy: .windowGlobalTitleAllowed)

        if let windowId = selector.windowID {
            return .windowId(windowId)
        }

        if let app = selector.applicationIdentifier, let title = selector.windowTitle {
            return .applicationAndTitle(app: app, title: title)
        }

        if let app = selector.applicationIdentifier, let index = selector.windowIndex {
            return .index(app: app, index: index)
        }

        if let app = selector.applicationIdentifier {
            return .application(app)
        }

        if let title = selector.windowTitle {
            return .title(title)
        }

        throw WindowActionError.missingParameters(
            "Must specify at least 'window_id', 'app', or 'title' parameter to target a window")
    }
}

struct WindowActionTarget {
    let target: WindowTarget
    let expectedOwnerIdentity: ApplicationProcessIdentity?
    let authorizedWindow: ServiceWindowInfo?

    init(
        target: WindowTarget,
        expectedOwnerIdentity: ApplicationProcessIdentity?,
        authorizedWindow: ServiceWindowInfo? = nil)
    {
        self.target = target
        self.expectedOwnerIdentity = expectedOwnerIdentity
        self.authorizedWindow = authorizedWindow
    }
}

private enum WindowAction: String, CaseIterable, Equatable {
    case list
    case close
    case minimize
    case restore
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
    let foreground: Bool

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
