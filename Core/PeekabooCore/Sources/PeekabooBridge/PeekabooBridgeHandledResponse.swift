import PeekabooAutomationKit
import PeekabooFoundation

/// One internal Bridge response plus the canonical action outcome erased by the legacy wire case.
struct PeekabooBridgeHandledResponse: Sendable {
    struct Mutation: Sendable {
        enum TargetDisposition: Sendable {
            /// The operation is genuinely desktop-global and needs no narrower target receipt.
            case global
            /// The request carries the exact target generation that was revalidated before dispatch.
            case requestPinned
            /// The handler resolved and revalidated this exact target around dispatch.
            case handlerResolved(DesktopTargetIdentity)
            /// The successful response contains the exact target generation.
            case responseResolved
            /// The operation needs a richer non-process/window target receipt.
            case external
            /// Browser dispatch was bound to this exact non-process DevTools connection.
            case externalBrowser(PeekabooBridgeBrowserConnectionReceipt)
        }

        let outcome: DesktopActionOutcome
        let target: TargetDisposition
    }

    let response: PeekabooBridgeResponse
    let mutation: Mutation?
    let selectedLeafEvidence: [DesktopSelectedLeafEvidence]?
    private let readTargetIdentity: DesktopTargetIdentity?

    var outcome: DesktopActionOutcome? {
        self.mutation?.outcome
    }

    var targetIdentity: DesktopTargetIdentity? {
        if case let .handlerResolved(identity) = self.mutation?.target {
            return identity
        }
        return self.readTargetIdentity
    }

    var externalBrowserTarget: PeekabooBridgeBrowserConnectionReceipt? {
        guard case let .externalBrowser(receipt) = self.mutation?.target else { return nil }
        return receipt
    }

    init(
        response: PeekabooBridgeResponse,
        mutation: Mutation? = nil,
        targetIdentity: DesktopTargetIdentity? = nil,
        selectedLeafEvidence: [DesktopSelectedLeafEvidence]? = nil)
    {
        self.response = response
        self.mutation = mutation
        self.readTargetIdentity = targetIdentity
        self.selectedLeafEvidence = selectedLeafEvidence
    }

    func replacingResponse(_ response: PeekabooBridgeResponse) -> Self {
        Self(
            response: response,
            mutation: self.mutation,
            targetIdentity: self.readTargetIdentity,
            selectedLeafEvidence: self.selectedLeafEvidence)
    }

    func finalizingMutation(
        outcome: DesktopActionOutcome,
        target: Mutation.TargetDisposition) -> Self
    {
        Self(
            response: self.response,
            mutation: .init(outcome: outcome, target: target),
            targetIdentity: self.readTargetIdentity,
            selectedLeafEvidence: self.selectedLeafEvidence)
    }
}
