import Foundation
import MCP
import PeekabooAutomation
import TachikomaMCP

struct DragRequest {
    let fromTarget: DragLocationInput
    let toTarget: DragLocationInput
    let snapshotId: String?
    let targetApp: String?
    let durationOverride: Int?
    let stepsOverride: Int?
    let modifiers: String?
    let button: DragButton
    let profile: MovementProfileOption

    init(arguments: ToolArguments) throws {
        guard arguments.getBool("foreground") == true else {
            throw DragToolError(
                "drag changes the shared physical cursor and requires foreground=true.")
        }
        let fromElement = arguments.getString("from")
        let fromCoords = arguments.getString("from_coords")
        let toElement = arguments.getString("to")
        let toCoords = arguments.getString("to_coords")

        guard let fromTarget = DragLocationInput(element: fromElement, coordinates: fromCoords) else {
            throw DragToolError("Must specify either 'from' or 'from_coords' for the start point.")
        }
        guard let toTarget = DragLocationInput(element: toElement, coordinates: toCoords) else {
            throw DragToolError("Must specify either 'to' or 'to_coords' for the end point.")
        }

        let profileName = (arguments.getString("profile") ?? "linear").lowercased()
        guard let profile = MovementProfileOption(rawValue: profileName) else {
            throw DragToolError("Invalid profile '\(profileName)'. Use 'linear' or 'human'.")
        }
        let buttonName = (arguments.getString("button") ?? "left").lowercased()
        guard let button = DragButton(rawValue: buttonName) else {
            throw DragToolError("Invalid button '\(buttonName)'. Use 'left' or 'right'.")
        }

        let durationOverride = try arguments.validatedInt("duration")
        let stepsOverride = try arguments.validatedInt("steps")

        if let override = durationOverride {
            guard override > 0 else {
                throw DragToolError("Duration must be greater than 0.")
            }
            guard override <= 30000 else {
                throw DragToolError("Duration must be 30 seconds or less to prevent excessive delays.")
            }
        }

        if let override = stepsOverride {
            guard override > 0 else {
                throw DragToolError("Steps must be greater than 0.")
            }
            guard override <= 100 else {
                throw DragToolError("Steps must be 100 or less to prevent excessive processing.")
            }
        }

        self.fromTarget = fromTarget
        self.toTarget = toTarget
        self.snapshotId = arguments.getString("snapshot")
        self.targetApp = arguments.getString("to_app")
        self.durationOverride = durationOverride
        self.stepsOverride = stepsOverride
        self.modifiers = arguments.getString("modifiers")
        self.button = button
        self.profile = profile
    }
}

enum DragLocationInput {
    case element(String)
    case coordinates(String)

    init?(element: String?, coordinates: String?) {
        if let coords = coordinates {
            self = .coordinates(coords)
        } else if let element {
            self = .element(element)
        } else {
            return nil
        }
    }
}

struct DragToolError: Swift.Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

struct CoordinateParseError: Swift.Error {
    let message: String
}

struct DragPointDescription {
    let point: CGPoint
    let description: String
    let targetApp: String?
    let windowTitle: String?
    let windowID: Int?
    let elementRole: String?
    let elementLabel: String?

    init(
        point: CGPoint,
        description: String,
        targetApp: String? = nil,
        windowTitle: String? = nil,
        windowID: Int? = nil,
        elementRole: String? = nil,
        elementLabel: String? = nil)
    {
        self.point = point
        self.description = description
        self.targetApp = targetApp
        self.windowTitle = windowTitle
        self.windowID = windowID
        self.elementRole = elementRole
        self.elementLabel = elementLabel
    }
}

struct DragResponseContext {
    let movement: MovementParameters
    let executionTime: TimeInterval
    let request: DragRequest
    let actionResult: UIAutomationActionResult<Void>
    let invalidatedSnapshotID: String?
}

extension UIElement {
    var dragCenterPoint: CGPoint {
        CGPoint(x: self.frame.midX, y: self.frame.midY)
    }

    var dragHumanDescription: String {
        "\(self.role): \(self.title ?? self.label ?? "untitled")"
    }
}
