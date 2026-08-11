import CoreGraphics
import Foundation
import TachikomaMCP

extension MoveTool {
    func parseCoordinates(_ coordString: String, parameterName: String) throws -> CGPoint {
        let parts = coordString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        guard parts.count == 2 else {
            throw CoordinateParseError(
                message: "Invalid \(parameterName) format. Use 'x,y' (e.g., '100,200') or 'center'")
        }

        guard let x = Double(parts[0]), let y = Double(parts[1]) else {
            throw CoordinateParseError(message: "Invalid \(parameterName). Both x and y must be valid numbers")
        }

        guard x >= 0, y >= 0 else {
            throw CoordinateParseError(message: "Invalid \(parameterName). Both x and y must be non-negative")
        }

        guard x <= 20000, y <= 20000 else {
            throw CoordinateParseError(message: "Invalid \(parameterName). Both x and y must be 20000 or less")
        }

        return CGPoint(x: x, y: y)
    }

    func parseRequest(arguments: ToolArguments) throws -> MoveRequest {
        guard arguments.getBool("foreground") == true else {
            throw MoveToolValidationError(
                "move changes the shared physical cursor and requires foreground=true.")
        }
        let target = try self.parseTarget(from: arguments)
        let snapshotId = arguments.getString("snapshot")
        let profileName = (arguments.getString("profile") ?? "linear").lowercased()
        guard let profile = MovementProfileOption(rawValue: profileName) else {
            throw MoveToolValidationError("Invalid profile '\(profileName)'. Use 'linear' or 'human'.")
        }
        let smooth = profile == .human ? true : (arguments.getBool("smooth") ?? false)

        let durationOverride = try arguments.validatedInt("duration")
        let stepsOverride = try arguments.validatedInt("steps")

        if smooth, profile == .linear {
            let durationToValidate = durationOverride ?? 500
            let stepsToValidate = stepsOverride ?? 10
            try self.validateSmoothParameters(duration: durationToValidate, steps: stepsToValidate)
        }

        return MoveRequest(
            target: target,
            snapshotId: snapshotId,
            smooth: smooth,
            durationOverride: durationOverride,
            stepsOverride: stepsOverride,
            profile: profile)
    }

    func parseTarget(from arguments: ToolArguments) throws -> MoveTarget {
        if arguments.getBool("center") ?? false {
            return .center
        }

        if let elementId = arguments.getString("id") {
            return .element(elementId)
        }

        if let coordinate = arguments.getString("to") ?? arguments.getString("coordinates") {
            return coordinate.lowercased() == "center" ? .center : .coordinates(coordinate)
        }

        throw MoveToolValidationError("Must specify either 'to', 'coordinates', 'id', or 'center'")
    }

    func validateSmoothParameters(duration: Int, steps: Int) throws {
        guard duration > 0 else {
            throw MoveToolValidationError("Duration must be greater than 0")
        }
        guard duration <= 30000 else {
            throw MoveToolValidationError("Duration must be 30 seconds or less to prevent excessive delays")
        }
        guard steps > 0 else {
            throw MoveToolValidationError("Steps must be greater than 0")
        }
        guard steps <= 100 else {
            throw MoveToolValidationError("Steps must be 100 or less to prevent excessive processing")
        }
    }
}
