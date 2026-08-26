import Foundation
import PeekabooFoundation

struct ExactLiteralTypingEffectConfirmationTiming: Sendable {
    static let live = Self(
        timeout: .milliseconds(250),
        interval: .milliseconds(20),
        maximumSampleCount: 32,
        now: { ContinuousClock.now },
        sleep: { try await ContinuousClock().sleep(for: $0) })

    let timeout: Duration
    let interval: Duration
    let maximumSampleCount: Int
    let now: @MainActor @Sendable () -> ContinuousClock.Instant
    let sleep: @MainActor @Sendable (Duration) async throws -> Void

    init(
        timeout: Duration,
        interval: Duration,
        maximumSampleCount: Int = 32,
        now: @escaping @MainActor @Sendable () -> ContinuousClock.Instant,
        sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void)
    {
        precondition(timeout > .zero)
        precondition(interval > .zero)
        precondition(maximumSampleCount > 0)
        self.timeout = timeout
        self.interval = interval
        self.maximumSampleCount = maximumSampleCount
        self.now = now
        self.sleep = sleep
    }
}

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
        guard let delivery = outcome.delivery,
              outcome.state == .dispatchedUnverified,
              Self.supportsExactBackgroundDelivery(delivery),
              !previousValue.utf8.elementsEqual(self.expectedValue.utf8),
              observedValue.utf8.elementsEqual(self.expectedValue.utf8)
        else { return outcome }
        return .confirmedChange(
            route: outcome.route,
            delivery: delivery,
            unitCount: outcome.dispatchState.unitCount)
    }

    func expectedValueMatches(_ value: String) -> Bool {
        value.utf8.elementsEqual(self.expectedValue.utf8)
    }

    private static func supportsExactBackgroundDelivery(_ delivery: DesktopActionOutcome.Delivery) -> Bool {
        guard delivery.mode == .background else { return false }
        switch delivery.mechanism {
        case .windowTargetedEvents, .accessibilityValue, .composite:
            return true
        default:
            return false
        }
    }
}
