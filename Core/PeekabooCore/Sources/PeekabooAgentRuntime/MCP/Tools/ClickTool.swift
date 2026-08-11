import CoreGraphics
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
        Background delivery is the default. Background coordinates require a nonempty snapshot or coordinate_reference
        from a fresh exact-window `see`; pid alone is never a safe coordinate target. Set `foreground` to true only for
        intentional shared-pointer input, which may omit the capture reference.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.6, anthropic/claude-opus-5
        """
    }

    public var inputSchema: Value {
        let baseSchema = SchemaBuilder.object(
            properties: [
                "query": SchemaBuilder.string(
                    description: """
                    Element text or query to click. Exclusive with on and coords; may use the latest UI snapshot.
                    """,
                    minLength: 1),
                "on": SchemaBuilder.string(
                    description: """
                    Opaque element ID copied exactly from current `see` or `inspect_ui` output. Exclusive with query
                    and coords; may use the latest UI snapshot.
                    """,
                    minLength: 1),
                "coords": SchemaBuilder.string(
                    description: """
                    Coordinates in 'x,y' format, exclusive with on and query. Background delivery requires a nonempty
                    snapshot or coordinate_reference from a fresh exact-window see. Without a reference, set
                    foreground=true for intentional shared-pointer global logical points.
                    """,
                    minLength: 1),
                "coordinate_space": SchemaBuilder.string(
                    description: """
                    Optional. Coordinate basis for coords. image_pixels and normalized require coordinate_reference.
                    """,
                    enum: CaptureCoordinateSpace.allCases.map(\.rawValue)),
                "coordinate_reference": SchemaBuilder.string(
                    description: """
                    Nonempty snapshot reference_id returned by a fresh exact-window see. Provide this or snapshot for
                    every background coordinate click; required for image_pixels and normalized coords.
                    """,
                    minLength: 1),
                "snapshot": SchemaBuilder.string(
                    description: """
                    Snapshot ID from `see` or `inspect_ui`. Element/query clicks may omit it to use the latest snapshot.
                    Background coordinate clicks must provide a nonempty ID from a fresh exact-window see.
                    """,
                    minLength: 1),
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
                    description: "Use foreground/shared-pointer delivery. Background delivery is the default.",
                    default: false),
                "background": SchemaBuilder.boolean(
                    description: """
                    Deprecated inverse alias. false explicitly selects foreground shared-pointer delivery.
                    """,
                    default: true),
                "pid": SchemaBuilder.integer(
                    description: """
                    Optional process consistency check. It never replaces the exact-window capture receipt.
                    """,
                    minimum: 1,
                    maximum: Int(Int32.max)),
            ],
            required: [])

        guard case let .object(fields) = baseSchema else { return baseSchema }
        var schema = fields
        schema["oneOf"] = .array(Self.targetRouteSchemas)
        return .object(schema)
    }

    private static var targetRouteSchemas: [Value] {
        [
            self.exclusiveTargetRoute("on"),
            self.exclusiveTargetRoute("query"),
            self.exclusiveTargetRoute("coords", additionalFields: [
                "anyOf": .array([
                    self.requiredConstant("foreground", value: true),
                    self.requiredConstant("background", value: false),
                    .object(["required": .array([.string("snapshot")])]),
                    .object(["required": .array([.string("coordinate_reference")])]),
                ]),
            ]),
        ]
    }

    private static func exclusiveTargetRoute(
        _ name: String,
        additionalFields: [String: Value] = [:]) -> Value
    {
        let otherTargets = ["on", "query", "coords"].filter { $0 != name }
        var fields = additionalFields
        fields["required"] = .array([.string(name)])
        fields["not"] = .object([
            "anyOf": .array(otherTargets.map { target in
                .object(["required": .array([.string(target)])])
            }),
        ])
        return .object(fields)
    }

    private static func requiredConstant(_ name: String, value: Bool) -> Value {
        .object([
            "properties": .object([name: .object(["const": .bool(value)])]),
            "required": .array([.string(name)]),
        ])
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
            return Self.preDispatchErrorResponse(error)
        }

        let startTime = Date()

        do {
            let resolution = try await self.resolveClickTarget(for: request)
            let effectiveTargetProcessIdentifier = try self.backgroundProcessIdentifier(
                request: request,
                resolution: resolution)
            try await self.performClick(
                resolution: resolution,
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
            return Self.preDispatchErrorResponse(error)
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
            return try await self.resolveCoordinates(raw, request: request)
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
                targetWindowID: snapshot.windowID,
                expectedWindowIdentity: snapshot.windowMutationIdentity,
                expectedWindowBounds: snapshot.windowBounds,
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
                targetWindowID: snapshot.windowID,
                expectedWindowIdentity: snapshot.windowMutationIdentity,
                expectedWindowBounds: snapshot.windowBounds,
                snapshotId: snapshot.id)
        }
    }

    @MainActor
    private func performClick(
        resolution: ClickResolution,
        intent: ClickIntent,
        deliveryMode: ClickToolDeliveryMode,
        targetProcessIdentifier: pid_t?) async throws
    {
        let target = resolution.automationTarget
        let snapshotId = resolution.snapshotId
        if deliveryMode == .background {
            guard let targetProcessIdentifier else {
                throw ClickToolError(
                    "Background click requires a capture-owned snapshot with an exact target process.")
            }
            if case .coordinates = target {
                try await self.validateCoordinateReceipt(
                    resolution,
                    targetProcessIdentifier: targetProcessIdentifier)
            }
            guard let automation = self.context.automation as? any TargetedClickServiceProtocol else {
                throw ClickToolError("This automation host does not support background click delivery.")
            }
            if let targetWindowID = resolution.targetWindowID {
                guard let exactWindowAutomation = automation as? any ExactWindowTargetedClickServiceProtocol,
                      exactWindowAutomation.supportsExactWindowTargetedClicks
                else {
                    throw ClickToolError("This automation host does not support exact-window background clicks.")
                }
                guard let expectedWindowIdentity = resolution.expectedWindowIdentity,
                      let expectedWindowBounds = resolution.expectedWindowBounds,
                      expectedWindowIdentity.windowID == targetWindowID,
                      expectedWindowIdentity.ownerProcessIdentifier == targetProcessIdentifier
                else {
                    throw ClickToolError(
                        "Exact-window snapshot has no capture-time process-generation receipt. Run see again.")
                }
                try await exactWindowAutomation.click(
                    target: target,
                    clickType: intent.automationType,
                    snapshotId: snapshotId,
                    expectedWindowIdentity: expectedWindowIdentity,
                    expectedWindowBounds: expectedWindowBounds)
            } else {
                try await automation.click(
                    target: target,
                    clickType: intent.automationType,
                    snapshotId: snapshotId,
                    targetProcessIdentifier: targetProcessIdentifier)
            }
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

        let routedPointerEffectIsUnverifiable = effectiveTargetProcessIdentifier != nil &&
            (intent.automationType == .right || intent.automationType == .double)
        if routedPointerEffectIsUnverifiable {
            message += "; routed events were dispatched, but the application effect is unverifiable"
        }

        var metaDict: [String: Value] = [
            "click_location": .object([
                "x": .double(Double(resolution.location.x)),
                "y": .double(Double(resolution.location.y)),
            ]),
            "execution_time": .double(executionTime),
            "clicked_element": resolution.elementDescription.map(Value.string) ?? .null,
            "delivery_mode": .string(effectiveTargetProcessIdentifier == nil ? "foreground" : "background"),
            "verified": routedPointerEffectIsUnverifiable ? .bool(false) : .null,
            "effect": routedPointerEffectIsUnverifiable ? .string("unverifiable") : .null,
            "mutation_dispatched": .bool(true),
        ]
        if let invalidatedSnapshotId {
            metaDict["invalidated_snapshot"] = .string(invalidatedSnapshotId)
            metaDict["requires_fresh_observation"] = .bool(true)
        }
        if let processId = effectiveTargetProcessIdentifier.map({ Int32($0) }) {
            metaDict["target_pid"] = .double(Double(processId))
        }
        if let targetWindowID = resolution.targetWindowID {
            metaDict["target_window_id"] = .double(Double(targetWindowID))
        }
        if let coordinateSpace = resolution.coordinateSpace {
            metaDict["coordinate_space"] = .string(coordinateSpace.rawValue)
        }
        if let coordinateReference = resolution.coordinateReference {
            metaDict["coordinate_reference"] = .string(coordinateReference)
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

    private func resolveCoordinates(_ raw: String, request: ClickRequest) async throws -> ClickResolution {
        let point = try self.parseCoordinates(raw)
        let referenceID = request.coordinateReference ?? request.snapshotId
        guard let referenceID else {
            guard request.deliveryMode == .foreground else {
                throw ClickToolError(Self.backgroundCoordinateReferenceMessage)
            }
            return ClickResolution(
                location: point,
                automationTarget: .coordinates(point),
                elementDescription: nil,
                targetProcessIdentifier: request.pid,
                snapshotId: nil,
                coordinateSpace: request.coordinateSpace)
        }

        let captured = try await self.requireCapturedCoordinateSnapshot(
            id: referenceID,
            explicitPID: request.pid,
            requiresExactWindow: request.deliveryMode == .background)
        if request.deliveryMode == .foreground {
            try await self.validateForegroundCoordinateContext(captured)
        }

        let mappedPoint: CGPoint
        if let coordinateSpace = request.coordinateSpace {
            do {
                mappedPoint = try CaptureCoordinateMapper.globalPoint(
                    for: point,
                    in: coordinateSpace,
                    context: captured.coordinateContext)
            } catch {
                throw ClickToolError(error.localizedDescription)
            }
        } else {
            mappedPoint = point
        }
        if request.deliveryMode == .background, captured.bounds?.contains(mappedPoint) != true {
            throw ClickToolError(
                "Background coordinates are outside captured window \(captured.identity?.windowID ?? 0). " +
                    "Run see again and use coordinates inside that exact window.")
        }

        return ClickResolution(
            location: mappedPoint,
            automationTarget: .coordinates(mappedPoint),
            elementDescription: nil,
            targetApp: captured.snapshot.applicationName,
            windowTitle: captured.snapshot.windowTitle,
            targetProcessIdentifier: request.pid ?? captured.processIdentifier,
            targetWindowID: captured.identity?.windowID,
            expectedWindowIdentity: captured.identity,
            expectedWindowBounds: captured.bounds,
            snapshotId: captured.snapshot.id,
            coordinateSpace: request.coordinateSpace,
            coordinateReference: referenceID)
    }

    private func requireCapturedCoordinateSnapshot(
        id: String,
        explicitPID: Int32?,
        requiresExactWindow: Bool) async throws -> CapturedCoordinateSnapshot
    {
        guard let snapshot = await self.getSnapshot(id: id) else {
            throw ClickToolError(
                "Coordinate reference '\(id)' is stale or unavailable. Run see for the exact target window.")
        }
        guard let coordinateContext = await snapshot.screenshotCoordinateContext,
              coordinateContext.referenceID == id
        else {
            throw ClickToolError(
                "Snapshot '\(id)' has no matching capture-owned coordinate context. Run see and retry with its " +
                    "reference_id.")
        }
        guard requiresExactWindow else {
            return CapturedCoordinateSnapshot(
                snapshot: snapshot,
                coordinateContext: coordinateContext,
                processIdentifier: snapshot.applicationProcessId,
                identity: snapshot.windowMutationIdentity,
                bounds: coordinateContext.logicalBounds)
        }
        guard
            let contextWindow = coordinateContext.window,
            let contextBounds = coordinateContext.logicalBounds,
            let sourceBounds = coordinateContext.viewport?.sourceLogicalBounds ?? coordinateContext.logicalBounds,
            let processIdentifier = snapshot.applicationProcessId,
            let windowID = snapshot.windowID,
            let bounds = snapshot.windowBounds,
            let identity = snapshot.windowMutationIdentity,
            contextWindow.windowID == windowID,
            identity.windowID == windowID,
            identity.ownerProcessIdentifier == processIdentifier,
            sourceBounds == bounds,
            bounds.insetBy(dx: -0.000_001, dy: -0.000_001).contains(contextBounds),
            explicitPID.map({ $0 == processIdentifier }) ?? true
        else {
            let requirement = requiresExactWindow ? "exact PID/window generation and bounds" : "window capture data"
            throw ClickToolError(
                "Snapshot '\(id)' is not a capture-owned coordinate reference with \(requirement). " +
                    "Run see for the exact target window and retry with its reference_id.")
        }
        return CapturedCoordinateSnapshot(
            snapshot: snapshot,
            coordinateContext: coordinateContext,
            processIdentifier: processIdentifier,
            identity: identity,
            bounds: bounds)
    }

    private func validateForegroundCoordinateContext(_ captured: CapturedCoordinateSnapshot) async throws {
        guard let window = captured.coordinateContext.window,
              let bounds = captured.coordinateContext.viewport?.sourceLogicalBounds ?? captured.coordinateContext
                  .logicalBounds
        else { return }
        let matches = try await self.context.windows.listWindows(target: .windowId(window.windowID))
        let exactMatches = matches.filter { $0.windowID == window.windowID }
        guard !exactMatches.isEmpty,
              exactMatches.allSatisfy({ current in
                  guard current.bounds == bounds else { return false }
                  guard let expectedIdentity = captured.identity else { return true }
                  return current.mutationIdentity == expectedIdentity
              })
        else {
            throw ClickToolError(
                "Coordinate reference is stale because its captured window moved, disappeared, or changed owner.")
        }
    }

    private func validateCoordinateReceipt(
        _ resolution: ClickResolution,
        targetProcessIdentifier: pid_t) async throws
    {
        guard let snapshotId = resolution.snapshotId,
              !snapshotId.isEmpty,
              let targetWindowID = resolution.targetWindowID,
              let expectedIdentity = resolution.expectedWindowIdentity,
              let expectedBounds = resolution.expectedWindowBounds,
              expectedIdentity.windowID == targetWindowID,
              expectedIdentity.ownerProcessIdentifier == targetProcessIdentifier,
              expectedBounds.contains(resolution.location)
        else {
            throw ClickToolError(Self.backgroundCoordinateReferenceMessage)
        }

        let matches = try await self.context.windows.listWindows(target: .windowId(targetWindowID))
        let exactMatches = matches.filter { $0.windowID == targetWindowID }
        guard !exactMatches.isEmpty,
              exactMatches.allSatisfy({
                  $0.bounds == expectedBounds && $0.mutationIdentity == expectedIdentity
              })
        else {
            throw ClickToolError(
                "Background coordinate reference '\(snapshotId)' is stale: its exact window moved, " +
                    "disappeared, changed owner, or changed process generation. Run see again before clicking.")
        }
    }

    private static func preDispatchErrorResponse(_ error: ClickToolError) -> ToolResponse {
        ToolResponse.error(
            error.message,
            meta: .object([
                "mutation_dispatched": .bool(false),
                "retry_safe": .bool(true),
            ]))
    }

    fileprivate static let backgroundCoordinateReferenceMessage =
        "Background coordinate clicks require a nonempty capture-owned snapshot/reference_id from see for the " +
        "exact target window. PID-only or app-only coordinates are refused; run see, then retry with its snapshot."

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
    let coordinateSpace: CaptureCoordinateSpace?
    let coordinateReference: String?

    init(arguments: ToolArguments) throws {
        let rawCoordinateSpace = Self.nonEmptyString(arguments.getString("coordinate_space"))
        let coordinateSpace = try rawCoordinateSpace.map { value in
            guard let space = CaptureCoordinateSpace(rawValue: value) else {
                throw ClickToolError(
                    "Invalid coordinate_space '\(value)'. Use global_display_points, image_pixels, or normalized.")
            }
            return space
        }
        let coordinateReference = Self.nonEmptyString(arguments.getString("coordinate_reference"))
        let snapshotId = Self.nonEmptyString(arguments.getString("snapshot"))
        let coords = Self.nonEmptyString(arguments.getString("coords"))
        let elementId = Self.nonEmptyString(arguments.getString("on"))
        let query = Self.nonEmptyString(arguments.getString("query"))
        let targetCount = [coords, elementId, query].compactMap(\.self).count
        guard targetCount > 0 else {
            throw ClickToolError("Must specify exactly one of 'query', 'on', or 'coords'.")
        }
        guard targetCount == 1 else {
            throw ClickToolError("Click targets are mutually exclusive; specify exactly one of query, on, or coords.")
        }

        if let coords {
            self.target = .coordinates(coords)
            if let coordinateSpace, coordinateSpace.requiresReference, coordinateReference == nil {
                throw ClickToolError("\(coordinateSpace.rawValue) coordinates require coordinate_reference from see.")
            }
        } else if let elementId {
            guard coordinateSpace == nil, coordinateReference == nil else {
                throw ClickToolError("coordinate_space and coordinate_reference are only valid with coords.")
            }
            self.target = .elementId(elementId)
        } else if let query {
            guard coordinateSpace == nil, coordinateReference == nil else {
                throw ClickToolError("coordinate_space and coordinate_reference are only valid with coords.")
            }
            self.target = .query(query)
        } else {
            throw ClickToolError("Must specify exactly one of 'query', 'on', or 'coords'.")
        }

        self.snapshotId = snapshotId
        if let snapshotId, let coordinateReference, snapshotId != coordinateReference {
            throw ClickToolError("snapshot and coordinate_reference must match when both are provided.")
        }
        self.coordinateSpace = coordinateSpace
        self.coordinateReference = coordinateReference
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
        if case .coordinates = self.target,
           self.deliveryMode == .background,
           snapshotId == nil,
           coordinateReference == nil
        {
            throw ClickToolError(ClickTool.backgroundCoordinateReferenceMessage)
        }
    }

    private static func nonEmptyString(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty
        else { return nil }
        return normalized
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
    let targetWindowID: Int?
    let expectedWindowIdentity: WindowMutationIdentity?
    let expectedWindowBounds: CGRect?
    let snapshotId: String?
    let snapshotIdToInvalidate: String?
    let coordinateSpace: CaptureCoordinateSpace?
    let coordinateReference: String?

    init(
        location: CGPoint,
        automationTarget: ClickTarget,
        elementDescription: String?,
        targetApp: String? = nil,
        windowTitle: String? = nil,
        elementRole: String? = nil,
        elementLabel: String? = nil,
        targetProcessIdentifier: Int32? = nil,
        targetWindowID: Int? = nil,
        expectedWindowIdentity: WindowMutationIdentity? = nil,
        expectedWindowBounds: CGRect? = nil,
        snapshotId: String?,
        snapshotIdToInvalidate: String? = nil,
        coordinateSpace: CaptureCoordinateSpace? = nil,
        coordinateReference: String? = nil)
    {
        self.location = location
        self.automationTarget = automationTarget
        self.elementDescription = elementDescription
        self.targetApp = targetApp
        self.windowTitle = windowTitle
        self.elementRole = elementRole
        self.elementLabel = elementLabel
        self.targetProcessIdentifier = targetProcessIdentifier
        self.targetWindowID = targetWindowID
        self.expectedWindowIdentity = expectedWindowIdentity
        self.expectedWindowBounds = expectedWindowBounds
        self.snapshotId = snapshotId
        self.snapshotIdToInvalidate = snapshotIdToInvalidate ?? snapshotId
        self.coordinateSpace = coordinateSpace
        self.coordinateReference = coordinateReference
    }
}

private struct CapturedCoordinateSnapshot {
    let snapshot: UISnapshot
    let coordinateContext: CaptureCoordinateContext
    let processIdentifier: Int32?
    let identity: WindowMutationIdentity?
    let bounds: CGRect?
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
