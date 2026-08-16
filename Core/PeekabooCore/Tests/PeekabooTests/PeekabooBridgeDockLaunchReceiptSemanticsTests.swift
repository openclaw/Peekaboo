import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeDockLaunchReceiptSemanticsTests {
    @Test
    func `receipt semantic gate rejects background Dock launch ambiguity`() {
        let request = PeekabooBridgeRequest.projectedAction(.init(
            request: .launchDockItem(.init(appName: "Safari"))))
        let foreground = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: .one)
        let background = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one)

        #expect(PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
            foreground,
            request: request))
        #expect(!PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
            background,
            request: request))
    }
}
