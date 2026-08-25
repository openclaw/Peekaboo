import Foundation
import PeekabooFoundation

/// Internal postcondition for the one exact typing shape whose final value is deterministic.
/// Text values stay inside the operation lane and are never added to public results or logs.
struct ExactLiteralTypingEffectConfirmation {
    let focusedElement: FocusedElementIdentity
    let processStartIdentity: UInt64
    private let expectedValue: String

    static func plan(
        actions: [TypeAction],
        target: UIAutomationTarget.ExactWindow) -> Self?
    {
        guard let focusedElement = target.focusedElement,
              focusedElement.role != "AXSecureTextField",
              let firstAction = actions.first,
              case .clear = firstAction
        else { return nil }

        var expectedValue = ""
        for action in actions.dropFirst() {
            guard case let .text(text) = action,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            expectedValue += text
        }
        return Self(
            focusedElement: focusedElement,
            processStartIdentity: target.identity.ownerProcessStartIdentity,
            expectedValue: expectedValue)
    }

    func readableValue(
        from observation: Result<ExactWindowFocusSnapshot, FocusedElementReceiptError>) -> String?
    {
        guard case let .success(snapshot) = observation,
              snapshot.role != "AXSecureTextField",
              snapshot.subrole != "AXSecureTextField"
        else { return nil }
        return snapshot.value
    }

    func confirmedOutcome(
        from outcome: DesktopActionOutcome,
        previousValue: String,
        observedValue: String) -> DesktopActionOutcome
    {
        guard outcome.state == .dispatchedUnverified,
              outcome.delivery?.mode == .background,
              outcome.delivery?.mechanism == .windowTargetedEvents,
              !previousValue.utf8.elementsEqual(self.expectedValue.utf8),
              observedValue.utf8.elementsEqual(self.expectedValue.utf8),
              let delivery = outcome.delivery
        else { return outcome }
        return .confirmedChange(
            route: outcome.route,
            delivery: delivery,
            unitCount: outcome.dispatchState.unitCount)
    }
}
