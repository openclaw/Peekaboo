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
            let location = CGPoint(x: element.frame.midX, y: element.frame.midY)
            let label = element.title ?? element.label ?? "untitled"
            let summary = "element \(elementId) (\(element.role): \(label))"
            return ResolvedMoveTarget(
                location: location,
                description: summary,
                targetApp: snapshot.applicationName,
                windowTitle: snapshot.windowTitle,
                elementRole: element.summaryRole,
                elementLabel: element.summaryLabel)
        }
    }

    func performMovement(to location: CGPoint, request: MoveRequest) async throws -> MovementExecution {
        let automation = self.context.automation
        let currentLocation = await automation.currentMouseLocation() ?? .zero
        let distance = hypot(location.x - currentLocation.x, location.y - currentLocation.y)
        let movement = self.resolveMovementParameters(for: request, distance: distance)

        if movement.smooth {
            try await automation.moveMouse(
                to: location,
                duration: movement.duration,
                steps: movement.steps,
                profile: movement.profile)
        } else {
            try await automation.moveMouse(
                to: location,
                duration: 0,
                steps: 1,
                profile: movement.profile)
        }
        return MovementExecution(
            parameters: movement,
            startPoint: currentLocation,
            distance: distance,
            direction: pointerDirection(from: currentLocation, to: location))
    }

    func buildResponse(
        target: ResolvedMoveTarget,
        movement: MovementExecution,
        executionTime: TimeInterval) -> ToolResponse
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

        let metaValue = ToolEventSummary.merge(summary: summary, into: .object(metaDict))

        return ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: metaValue)
    }

    func getSnapshot(id: String?) async -> UISnapshot? {
        await UISnapshotManager.shared.getSnapshot(id: id)
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
