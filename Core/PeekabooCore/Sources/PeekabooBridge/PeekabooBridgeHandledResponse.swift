import PeekabooAutomationKit
import PeekabooFoundation

/// One internal Bridge response plus the canonical action outcome erased by the legacy wire case.
struct PeekabooBridgeHandledResponse: Sendable {
    let response: PeekabooBridgeResponse
    let outcome: DesktopActionOutcome?
    let targetIdentity: DesktopTargetIdentity?

    init(
        response: PeekabooBridgeResponse,
        outcome: DesktopActionOutcome? = nil,
        targetIdentity: DesktopTargetIdentity? = nil)
    {
        self.response = response
        self.outcome = outcome
        self.targetIdentity = targetIdentity
    }

    func replacingResponse(_ response: PeekabooBridgeResponse) -> Self {
        Self(response: response, outcome: self.outcome, targetIdentity: self.targetIdentity)
    }
}
