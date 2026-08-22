import CoreGraphics
import PeekabooFoundation
@testable import PeekabooAutomationKit

extension ForegroundModifierClickRequest {
    init(
        point: CGPoint,
        clickType: ClickType,
        modifiers: [PointerModifier],
        windowIdentity: WindowMutationIdentity,
        windowBounds: CGRect)
    {
        self.init(
            point: point,
            clickType: clickType,
            modifiers: modifiers,
            snapshotID: "modifier-click-executor-test-snapshot",
            windowIdentity: windowIdentity,
            windowBounds: windowBounds)
    }
}
