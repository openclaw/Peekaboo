import CoreGraphics
import Foundation
import MCP
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

extension MoveTool {
    @MainActor
    func getCenterOfScreen() throws -> CGPoint {
        guard let mainScreen = self.context.screens.primaryScreen else {
            throw CoordinateParseError(message: "Unable to determine main screen dimensions")
        }

        let screenFrame = mainScreen.frame
        return CGPoint(
            x: screenFrame.midX,
            y: screenFrame.midY)
    }

    @MainActor
    func resolveMoveTarget(request: MoveRequest) async throws -> ResolvedMoveTarget {
        switch request.target {
        case .center:
            let location = try self.getCenterOfScreen()
            return ResolvedMoveTarget(location: location, description: "center of screen")
        case let .coordinates(value):
            let location = try self.parseCoordinates(value, parameterName: "coordinates")
            let summary = "coordinates (\(Int(location.x)), \(Int(location.y)))"
            return ResolvedMoveTarget(location: location, description: summary)
        case let .element(elementId):
            guard let snapshot = await self.getSnapshot(id: request.snapshotId) else {
                throw MoveToolValidationError(
                    "No active snapshot. Run 'see' or 'inspect_ui' first to capture UI state.")
            }
            guard let element = await snapshot.getElement(byId: elementId) else {
                throw MoveToolValidationError(
                    "Element '\(elementId)' not found in current snapshot. " +
                        "Run 'see' or 'inspect_ui' to update UI state.")
            }
            guard !element.isOCRSemanticEvidence else {
                throw MoveToolValidationError(OCRSemanticEvidencePolicy.interactionRefusalMessage)
            }
            let location = CGPoint(x: element.frame.midX, y: element.frame.midY)
            let label = element.title ?? element.label ?? "untitled"
            let summary = "element \(elementId) (\(element.role): \(label))"
            let screenshotMetadata = await snapshot.screenshotMetadata
            return ResolvedMoveTarget(
                location: location,
                description: summary,
                targetApp: snapshot.applicationName,
                windowTitle: snapshot.windowTitle,
                windowID: screenshotMetadata?.windowInfo?.windowID,
                elementRole: element.summaryRole,
                elementLabel: element.summaryLabel)
        }
    }

    @MainActor
    func focusTargetIfNeeded(_ target: ResolvedMoveTarget) async throws -> MCPInteractionFocusResult? {
        let interactionTarget: MCPInteractionTarget? = if let windowID = target.windowID {
            try MCPInteractionTarget(
                app: nil,
                pid: nil,
                windowTitle: nil,
                windowIndex: nil,
                windowId: windowID)
        } else if let appName = target.targetApp, let windowTitle = target.windowTitle {
            try MCPInteractionTarget(
                app: appName,
                pid: nil,
                windowTitle: windowTitle,
                windowIndex: nil,
                windowId: nil)
        } else if let appName = target.targetApp {
            try MCPInteractionTarget(
                app: appName,
                pid: nil,
                windowTitle: nil,
                windowIndex: nil,
                windowId: nil)
        } else {
            nil
        }
        guard let interactionTarget else { return nil }
        return try await interactionTarget.focusResultIfRequested(
            windows: self.context.windows,
            onlyWhenTargeted: true)
    }

    @MainActor
    func performMovement(
        to location: CGPoint,
        request: MoveRequest,
        setupFocus: MCPInteractionFocusResult?) async throws -> MovementExecution
    {
        let automation = self.context.automation
        let currentLocation = automation.currentMouseLocation() ?? .zero
        let distance = hypot(location.x - currentLocation.x, location.y - currentLocation.y)
        let movement = self.resolveMovementParameters(for: request, distance: distance)

        let pointerAction: UIAutomationActionResult<Void> = if movement.smooth {
            try await MCPGlobalPointerActionResult.move(
                automation: automation,
                to: location,
                duration: movement.duration,
                steps: movement.steps,
                profile: movement.profile)
        } else {
            try await MCPGlobalPointerActionResult.move(
                automation: automation,
                to: location,
                duration: 0,
                steps: 1,
                profile: movement.profile)
        }
        let actionResult = try MCPGlobalPointerActionResult.compose(
            setupFocus: setupFocus,
            pointerAction: pointerAction,
            operation: "Cursor move",
            route: MCPGlobalPointerActionResult.route(for: self.context))
        return MovementExecution(
            parameters: movement,
            startPoint: currentLocation,
            distance: distance,
            direction: pointerDirection(from: currentLocation, to: location),
            actionResult: actionResult)
    }

    func buildResponse(
        target: ResolvedMoveTarget,
        movement: MovementExecution,
        executionTime: TimeInterval,
        invalidatedSnapshotID: String?) throws -> ToolResponse
    {
        var message = "\(AgentDisplayTokens.Status.success) Moved mouse cursor to \(target.description)"
        message += " using \(movement.parameters.profileName) profile"
        if movement.parameters.smooth {
            message += " (\(movement.parameters.duration)ms, \(movement.parameters.steps) steps)"
        }
        message += " in \(String(format: "%.2f", executionTime))s"

        var metaDict: [String: Value] = [
            "target_location": .object([
                "x": .double(Double(target.location.x)),
                "y": .double(Double(target.location.y)),
            ]),
            "target_description": .string(target.description),
            "smooth": .bool(movement.parameters.smooth),
            "profile": .string(movement.parameters.profileName),
            "duration": movement.parameters.smooth ? .double(Double(movement.parameters.duration)) : .null,
            "steps": movement.parameters.smooth ? .double(Double(movement.parameters.steps)) : .null,
            "execution_time": .double(executionTime),
            "distance": .double(Double(movement.distance)),
            "start_location": .object([
                "x": .double(Double(movement.startPoint.x)),
                "y": .double(Double(movement.startPoint.y)),
            ]),
        ]

        if let direction = movement.direction {
            metaDict["direction"] = .string(direction)
        }
        if let invalidatedSnapshotID {
            metaDict["invalidated_snapshot"] = .string(invalidatedSnapshotID)
        }

        let summary = ToolEventSummary(
            targetApp: target.targetApp,
            windowTitle: target.windowTitle,
            elementRole: target.elementRole,
            elementLabel: target.elementLabel,
            actionDescription: "Move cursor",
            coordinates: ToolEventSummary.Coordinates(
                x: Double(target.location.x),
                y: Double(target.location.y)),
            pointerProfile: movement.parameters.profileName,
            pointerDistance: Double(movement.distance),
            pointerDirection: movement.direction,
            pointerDurationMs: Double(movement.parameters.duration),
            notes: target.description)

        let meta = try MCPToolResponseMetadataProjector.metadata(
            merging: metaDict,
            outcome: movement.actionResult.outcome)
        let metaValue = ToolEventSummary.merge(summary: summary, into: meta)

        return ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: metaValue)
    }

    func getSnapshot(id: String?) async -> UISnapshot? {
        await self.context.uiSnapshots.getSnapshot(id: id)
    }

    func resolveMovementParameters(for request: MoveRequest, distance: CGFloat) -> MovementParameters {
        request.profile.resolveParameters(
            smooth: request.smooth,
            durationOverride: request.durationOverride,
            stepsOverride: request.stepsOverride,
            defaultDuration: 500,
            defaultSteps: 10,
            distance: distance)
    }
}
