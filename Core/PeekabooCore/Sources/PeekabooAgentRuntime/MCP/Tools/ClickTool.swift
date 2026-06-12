import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

/// MCP tool for clicking UI elements
public struct ClickTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "ClickTool")
    private let context: MCPToolContext

    public let name = "click"

    public var description: String {
        """
        Clicks on UI elements or coordinates.
        Supports element queries, specific IDs from `see` or `inspect_ui`, or raw coordinates.
        Background delivery is the default. Set `foreground` to true when the next step needs keyboard focus.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.5, anthropic/claude-opus-4-8
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "query": SchemaBuilder.string(
                    description: """
                    Optional. Element text or query to click. Will search for matching elements.
                    """),
                "on": SchemaBuilder.string(
                    description: """
                    Optional. Element ID to click (e.g., B1, T2) from `see` or `inspect_ui` output.
                    """),
                "coords": SchemaBuilder.string(
                    description: """
                    Optional. Click at specific coordinates in format 'x,y' (e.g., '100,200').
                    """),
                "snapshot": SchemaBuilder.string(
                    description: """
                    Optional. Snapshot ID from `see` or `inspect_ui`. Uses latest snapshot if not specified.
                    """),
                "wait_for": SchemaBuilder.number(
                    description: """
                    Optional. Maximum milliseconds to wait for element to become actionable. Default: 5000.
                    """,
                    default: 5000),
                "double": SchemaBuilder.boolean(
                    description: "Optional. Double-click instead of single click.",
                    default: false),
                "right": SchemaBuilder.boolean(
                    description: "Optional. Right-click (secondary click) instead of left-click.",
                    default: false),
                "foreground": SchemaBuilder.boolean(
                    description: "Optional. Use foreground/global click delivery. Background delivery is the default.",
                    default: false),
                "background": SchemaBuilder.boolean(
                    description: "Optional legacy alias. Defaults to true; set foreground=true for foreground clicks.",
                    default: true),
                "pid": SchemaBuilder.number(
                    description: "Optional. Target process ID for background coordinate clicks."),
            ],
            required: [])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        let request: ClickRequest
        do {
            request = try ClickRequest(arguments: arguments)
        } catch let error as ClickToolError {
            return ToolResponse.error(error.message)
        }

        let startTime = Date()

        do {
            let resolution = try await self.resolveClickTarget(for: request)
            let effectiveTargetProcessIdentifier = try self.backgroundProcessIdentifier(
                request: request,
                resolution: resolution)
            try await self.performClick(
                target: resolution.automationTarget,
                snapshotId: resolution.snapshotId,
                intent: request.intent,
                deliveryMode: request.deliveryMode,
                targetProcessIdentifier: effectiveTargetProcessIdentifier)

            let invalidatedSnapshotId = await UISnapshotManager.shared
                .invalidateActiveSnapshot(id: resolution.snapshotIdToInvalidate)
            let executionTime = Date().timeIntervalSince(startTime)
            return self.buildResponse(
                intent: request.intent,
                resolution: resolution,
                effectiveTargetProcessIdentifier: effectiveTargetProcessIdentifier,
                executionTime: executionTime,
                invalidatedSnapshotId: invalidatedSnapshotId)
        } catch let error as ClickToolError {
            return ToolResponse.error(error.message)
        } catch {
            self.logger.error("Click execution failed: \(error.localizedDescription)")
            return ToolResponse.error("Failed to perform click: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func getSnapshot(id: String?) async -> UISnapshot? {
        await UISnapshotManager.shared.getSnapshot(id: id)
    }

    private func resolveClickTarget(for request: ClickRequest) async throws -> ClickResolution {
        switch request.target {
        case let .coordinates(raw):
            let point = try self.parseCoordinates(raw)
            return ClickResolution(
                location: point,
                automationTarget: .coordinates(point),
                elementDescription: nil,
                targetProcessIdentifier: request.pid,
                snapshotId: nil,
                snapshotIdToInvalidate: request.snapshotId)
        case let .elementId(identifier):
            let snapshot = try await self.requireSnapshot(id: request.snapshotId)
            let element = try await self.requireElement(id: identifier, snapshot: snapshot)
            return ClickResolution(
                location: element.centerPoint,
                automationTarget: .elementId(identifier),
                elementDescription: element.humanDescription,
                targetApp: snapshot.applicationName,
                windowTitle: snapshot.windowTitle,
                elementRole: element.humanRole,
                elementLabel: element.displayLabel,
                targetProcessIdentifier: snapshot.applicationProcessId,
                snapshotId: snapshot.id)
        case let .query(text):
            let snapshot = try await self.requireSnapshot(id: request.snapshotId)
            let element = try await self.findElement(matching: text, snapshot: snapshot)
            return ClickResolution(
                location: element.centerPoint,
                automationTarget: .elementId(element.id),
                elementDescription: element.humanDescription,
                targetApp: snapshot.applicationName,
                windowTitle: snapshot.windowTitle,
                elementRole: element.humanRole,
                elementLabel: element.displayLabel,
                targetProcessIdentifier: snapshot.applicationProcessId,
                snapshotId: snapshot.id)
        }
    }

    private func performClick(
        target: ClickTarget,
        snapshotId: String?,
        intent: ClickIntent,
        deliveryMode: ClickToolDeliveryMode,
        targetProcessIdentifier: pid_t?) async throws
    {
        if deliveryMode == .background {
            guard let targetProcessIdentifier else {
                throw ClickToolError("Background click requires a snapshot target process or explicit pid.")
            }
            guard let automation = self.context.automation as? any TargetedClickServiceProtocol else {
                throw ClickToolError("This automation host does not support background click delivery.")
            }
            try await automation.click(
                target: target,
                clickType: intent.automationType,
                snapshotId: snapshotId,
                targetProcessIdentifier: targetProcessIdentifier)
        } else {
            try await self.context.automation.click(
                target: target,
                clickType: intent.automationType,
                snapshotId: snapshotId)
        }
    }

    private func backgroundProcessIdentifier(
        request: ClickRequest,
        resolution: ClickResolution) throws -> pid_t?
    {
        guard request.deliveryMode == .background else { return nil }
        if let pid = request.pid {
            guard pid > 0 else {
                throw ClickToolError("pid must be greater than 0.")
            }
            return pid_t(pid)
        }
        guard let targetProcessIdentifier = resolution.targetProcessIdentifier else { return nil }
        return pid_t(targetProcessIdentifier)
    }

    private func buildResponse(
        intent: ClickIntent,
        resolution: ClickResolution,
        effectiveTargetProcessIdentifier: pid_t?,
        executionTime: TimeInterval,
        invalidatedSnapshotId: String?) -> ToolResponse
    {
        var message = "\(AgentDisplayTokens.Status.success) \(intent.displayVerb)"
        if let element = resolution.elementDescription {
            message += " on \(element)"
        }
        message += " at (\(Int(resolution.location.x)), \(Int(resolution.location.y)))"
        message += " in \(String(format: "%.2f", executionTime))s"

        var metaDict: [String: Value] = [
            "click_location": .object([
                "x": .double(Double(resolution.location.x)),
                "y": .double(Double(resolution.location.y)),
            ]),
            "execution_time": .double(executionTime),
            "clicked_element": resolution.elementDescription.map(Value.string) ?? .null,
            "delivery_mode": .string(effectiveTargetProcessIdentifier == nil ? "foreground" : "background"),
        ]
        if let invalidatedSnapshotId {
            metaDict["invalidated_snapshot"] = .string(invalidatedSnapshotId)
            metaDict["requires_fresh_observation"] = .bool(true)
        }
        if let processId = effectiveTargetProcessIdentifier.map({ Int32($0) }) {
            metaDict["target_pid"] = .double(Double(processId))
        }

        let summary = ToolEventSummary(
            targetApp: resolution.targetApp,
            windowTitle: resolution.windowTitle,
            elementRole: resolution.elementRole,
            elementLabel: resolution.elementLabel,
            actionDescription: intent.displayVerb,
            coordinates: ToolEventSummary.Coordinates(
                x: Double(resolution.location.x),
                y: Double(resolution.location.y)))

        let metaValue = ToolEventSummary.merge(summary: summary, into: .object(metaDict))

        return ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: metaValue)
    }

    private func parseCoordinates(_ raw: String) throws -> CGPoint {
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1])
        else {
            throw ClickToolError("Invalid coordinates format. Use 'x,y' (e.g., '100,200').")
        }
        return CGPoint(x: x, y: y)
    }

    private func requireSnapshot(id: String?) async throws -> UISnapshot {
        guard let snapshot = await self.getSnapshot(id: id) else {
            throw ClickToolError("No active snapshot. Run 'see' or 'inspect_ui' first to capture UI state.")
        }
        return snapshot
    }

    private func requireElement(id: String, snapshot: UISnapshot) async throws -> UIElement {
        guard let element = await snapshot.getElement(byId: id) else {
            throw ClickToolError(
                "Element '\(id)' not found in current snapshot. Run 'see' or 'inspect_ui' to update UI state.")
        }
        return element
    }

    private func findElement(matching query: String, snapshot: UISnapshot) async throws -> UIElement {
        let searchText = query.lowercased()
        let elements = await snapshot.uiElements
        let matches = elements.filter { element in
            element.title?.lowercased().contains(searchText) ?? false ||
                element.label?.lowercased().contains(searchText) ?? false ||
                element.value?.lowercased().contains(searchText) ?? false
        }

        guard !matches.isEmpty else {
            throw ClickToolError("No elements found matching query: '\(query)'")
        }

        return matches.first { $0.isActionable } ?? matches[0]
    }
}

// MARK: - Supporting Types

private struct ClickRequest {
    let target: ClickRequestTarget
    let snapshotId: String?
    let intent: ClickIntent
    let deliveryMode: ClickToolDeliveryMode
    let pid: Int32?

    init(arguments: ToolArguments) throws {
        if let coords = arguments.getString("coords") {
            self.target = .coordinates(coords)
        } else if let elementId = arguments.getString("on") {
            self.target = .elementId(elementId)
        } else if let query = arguments.getString("query") {
            self.target = .query(query)
        } else {
            throw ClickToolError("Must specify either 'query', 'on', or 'coords'.")
        }

        self.snapshotId = arguments.getString("snapshot")
        let isDouble = arguments.getBool("double") ?? false
        let isRight = arguments.getBool("right") ?? false
        self.intent = ClickIntent(double: isDouble, right: isRight)
        let foreground = arguments.getBool("foreground") ?? false
        self.deliveryMode = if foreground || arguments.getBool("background") == false {
            .foreground
        } else {
            .background
        }
        if let rawPID = arguments.getNumber("pid") {
            guard let pid = Int32(exactly: rawPID) else {
                throw ClickToolError("pid is outside the supported Int32 range.")
            }
            self.pid = pid
        } else {
            self.pid = nil
        }
    }
}

private enum ClickRequestTarget {
    case coordinates(String)
    case elementId(String)
    case query(String)
}

private enum ClickToolDeliveryMode {
    case background
    case foreground
}

private struct ClickResolution {
    let location: CGPoint
    let automationTarget: ClickTarget
    let elementDescription: String?
    let targetApp: String?
    let windowTitle: String?
    let elementRole: String?
    let elementLabel: String?
    let targetProcessIdentifier: Int32?
    let snapshotId: String?
    let snapshotIdToInvalidate: String?

    init(
        location: CGPoint,
        automationTarget: ClickTarget,
        elementDescription: String?,
        targetApp: String? = nil,
        windowTitle: String? = nil,
        elementRole: String? = nil,
        elementLabel: String? = nil,
        targetProcessIdentifier: Int32? = nil,
        snapshotId: String?,
        snapshotIdToInvalidate: String? = nil)
    {
        self.location = location
        self.automationTarget = automationTarget
        self.elementDescription = elementDescription
        self.targetApp = targetApp
        self.windowTitle = windowTitle
        self.elementRole = elementRole
        self.elementLabel = elementLabel
        self.targetProcessIdentifier = targetProcessIdentifier
        self.snapshotId = snapshotId
        self.snapshotIdToInvalidate = snapshotIdToInvalidate ?? snapshotId
    }
}

private struct ClickIntent {
    let automationType: ClickType
    let displayVerb: String

    init(double: Bool, right: Bool) {
        if right {
            self.automationType = .right
            self.displayVerb = "Right-clicked"
        } else if double {
            self.automationType = .double
            self.displayVerb = "Double-clicked"
        } else {
            self.automationType = .single
            self.displayVerb = "Clicked"
        }
    }
}

private struct ClickToolError: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}

extension UIElement {
    fileprivate var centerPoint: CGPoint {
        CGPoint(x: self.frame.midX, y: self.frame.midY)
    }

    fileprivate var humanDescription: String {
        "\(self.role): \(self.title ?? self.label ?? "untitled")"
    }

    fileprivate var humanRole: String? {
        self.roleDescription ?? self.role
    }

    fileprivate var displayLabel: String? {
        self.title ?? self.label ?? self.value
    }
}
