import PeekabooFoundation

/// One internal Bridge response plus the canonical action outcome erased by the legacy wire case.
struct PeekabooBridgeHandledResponse: Sendable {
    let response: PeekabooBridgeResponse
    let outcome: DesktopActionOutcome?

    init(
        response: PeekabooBridgeResponse,
        outcome: DesktopActionOutcome? = nil)
    {
        self.response = response
        self.outcome = outcome
    }

    func replacingResponse(_ response: PeekabooBridgeResponse) -> Self {
        Self(response: response, outcome: self.outcome)
    }
}
