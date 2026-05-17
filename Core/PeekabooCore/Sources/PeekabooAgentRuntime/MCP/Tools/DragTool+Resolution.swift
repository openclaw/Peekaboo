import Foundation
import PeekabooAutomation

extension DragTool {
    func resolveLocation(
        target: DragLocationInput,
        snapshotId: String?,
        parameterName: String) async throws -> DragPointDescription
    {
        switch target {
        case let .coordinates(raw):
            let point = try self.parseCoordinates(raw, parameterName: parameterName)
            return DragPointDescription(point: point, description: "(\(Int(point.x)), \(Int(point.y)))")
        case let .element(query):
            guard let snapshot = await self.getSnapshot(id: snapshotId) else {
                throw CoordinateParseError(
                    message: "No active snapshot. Run 'see' or 'inspect_ui' first to capture UI state.")
            }
            if let element = await snapshot.getElement(byId: query) {
                return DragPointDescription(
                    point: element.dragCenterPoint,
                    description: "element \(query) (\(element.dragHumanDescription))",
                    targetApp: snapshot.applicationName,
                    windowTitle: snapshot.windowTitle,
                    elementRole: element.summaryRole,
                    elementLabel: element.summaryLabel)
            }

            let elements = await snapshot.uiElements
            let matches = elements.filter { element in
                let searchText = query.lowercased()
                return element.title?.lowercased().contains(searchText) ?? false ||
                    element.label?.lowercased().contains(searchText) ?? false ||
                    element.value?.lowercased().contains(searchText) ?? false
            }

            guard !matches.isEmpty else {
                throw CoordinateParseError(message: "No elements found matching '\(query)' for \(parameterName)")
            }

            let element = matches.first { $0.isActionable } ?? matches[0]
            return DragPointDescription(
                point: element.dragCenterPoint,
                description: element.dragHumanDescription,
                targetApp: snapshot.applicationName,
                windowTitle: snapshot.windowTitle,
                elementRole: element.summaryRole,
                elementLabel: element.summaryLabel)
        }
    }

    func parseCoordinates(_ coordString: String, parameterName: String) throws -> CGPoint {
        let parts = coordString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        guard parts.count == 2 else {
            throw CoordinateParseError(
                message: "Invalid \(parameterName) coordinates format. Use 'x,y' (e.g., '100,200')")
        }

        guard let x = Double(parts[0]), let y = Double(parts[1]) else {
            throw CoordinateParseError(
                message: "Invalid \(parameterName) coordinates. Both x and y must be valid numbers")
        }

        // Coordinates outside the desktop are nearly always malformed tool input.
        guard x >= 0, y >= 0 else {
            throw CoordinateParseError(
                message: "Invalid \(parameterName) coordinates. Both x and y must be non-negative")
        }

        guard x <= 20000, y <= 20000 else {
            throw CoordinateParseError(
                message: "Invalid \(parameterName) coordinates. Both x and y must be 20000 or less")
        }

        return CGPoint(x: x, y: y)
    }

    func getSnapshot(id: String?) async -> UISnapshot? {
        await UISnapshotManager.shared.getSnapshot(id: id)
    }
}
