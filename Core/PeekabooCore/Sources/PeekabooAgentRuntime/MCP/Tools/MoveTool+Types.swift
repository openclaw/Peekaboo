import CoreGraphics
import PeekabooAutomation
import PeekabooFoundation

enum MoveTarget {
    case center
    case coordinates(String)
    case element(String)
}

struct MoveRequest {
    let target: MoveTarget
    let snapshotId: String?
    let smooth: Bool
    let durationOverride: Int?
    let stepsOverride: Int?
    let profile: MovementProfileOption
}

struct ResolvedMoveTarget {
    let location: CGPoint
    let description: String
    let targetApp: String?
    let windowTitle: String?
    let windowID: Int?
    let elementRole: String?
    let elementLabel: String?

    init(
        location: CGPoint,
        description: String,
        targetApp: String? = nil,
        windowTitle: String? = nil,
        windowID: Int? = nil,
        elementRole: String? = nil,
        elementLabel: String? = nil)
    {
        self.location = location
        self.description = description
        self.targetApp = targetApp
        self.windowTitle = windowTitle
        self.windowID = windowID
        self.elementRole = elementRole
        self.elementLabel = elementLabel
    }
}

struct MovementExecution {
    let parameters: MovementParameters
    let startPoint: CGPoint
    let distance: CGFloat
    let direction: String?
    let actionResult: UIAutomationActionResult<Void>
}

struct MoveToolValidationError: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}
