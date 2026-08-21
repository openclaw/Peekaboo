import CoreGraphics
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation

struct TypeRequest {
    let text: String?
    let elementId: String?
    let snapshotId: String?
    let delay: Int
    let profile: TypingProfile
    let wordsPerMinute: Int?
    let clearField: Bool
    let foreground: Bool
    let target: MCPInteractionTarget
    let coordinateText: String?
    let coordinateSpace: CaptureCoordinateSpace?
    let coordinateReference: String?

    static let defaultHumanWPM = 140

    var hasActions: Bool {
        self.text != nil || self.clearField
    }

    var cadence: TypingCadence {
        switch self.profile {
        case .human:
            let wpm = self.wordsPerMinute ?? Self.defaultHumanWPM
            return .human(wordsPerMinute: wpm)
        case .linear:
            return .fixed(milliseconds: self.delay)
        }
    }
}

struct TypePixelFocusTarget {
    let point: CGPoint
    let snapshotID: String
    let exactWindow: UIAutomationTarget.ExactWindow
}

struct TypeToolValidationError: Error {
    let message: String
    let refusalReason: DesktopActionOutcome.RefusalReason

    init(
        _ message: String,
        refusalReason: DesktopActionOutcome.RefusalReason = .invalidRequest)
    {
        self.message = message
        self.refusalReason = refusalReason
    }
}

struct TargetElementContext {
    let snapshot: UISnapshot
    let element: UIElement
}
