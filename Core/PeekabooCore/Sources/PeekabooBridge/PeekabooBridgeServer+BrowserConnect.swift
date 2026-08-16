import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
extension PeekabooBridgeServer {
    func handleBrowserConnect(
        _ payload: PeekabooBridgeBrowserChannelRequest) async throws -> PeekabooBridgeHandledResponse
    {
        guard let provider = self.services as? any PeekabooBridgeBrowserConnectionResultProviding else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "The Bridge browser provider cannot report canonical connection outcomes.",
                hint: "Update the runtime host before retrying browser connect.")
        }
        let result = try await provider.browserConnectResult(
            channel: payload.channel,
            browserURL: payload.browserURL)
        guard result.payload.isConnected,
              let receipt = result.payload.connectionReceipt,
              let outcome = result.outcome
        else {
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .browserProtocol, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Browser connect returned without a live receipt and canonical outcome.",
                hint: "Check browser status before deciding whether to reconnect.")
        }
        guard receipt.matchesConnectRequest(payload) else {
            throw DesktopActionFailure.indeterminate(
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "Browser connect returned a connection receipt for a different endpoint or channel.",
                hint: "Check browser status before deciding whether to reconnect and update the runtime host.")
        }
        switch outcome.state {
        case .confirmedNoChange:
            guard outcome.delivery == nil, outcome.dispatchState == .none else {
                throw Self.invalidBrowserConnectOutcome(outcome)
            }
        case .dispatchedUnverified:
            guard outcome.delivery == .init(mechanism: .browserProtocol, mode: .foreground),
                  outcome.dispatchState.unitCount == .one
            else {
                throw Self.invalidBrowserConnectOutcome(outcome)
            }
        case .confirmedChange, .partial, .suspectedNoop, .refused, .indeterminate:
            throw Self.invalidBrowserConnectOutcome(outcome)
        }
        return try .init(
            response: .browserStatus(result.payload),
            mutation: .init(
                outcome: outcome.routed(to: .bridge),
                target: self.browserTargetDisposition(receipt)))
    }

    func browserTargetDisposition(
        _ receipt: PeekabooBridgeBrowserConnectionReceipt) throws
        -> PeekabooBridgeHandledResponse.Mutation.TargetDisposition
    {
        if let processIdentity = receipt.localProcessIdentity {
            guard
                self.processStartIdentityProvider(processIdentity.processIdentifier)
                == processIdentity.processStartIdentity
            else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "The browser process generation changed before execution.",
                    hint: "Refresh browser status and retry against its new connection receipt.")
            }
            let identity = try DesktopTargetIdentity(processIdentity: processIdentity)
            return .handlerResolved(identity)
        }
        guard receipt.isCanonicalExternalTarget else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The browser connection has no complete process or DevTools identity.",
                hint: "Reconnect the intended browser and retry with its full connection receipt.")
        }
        return .externalBrowser(receipt)
    }

    func browserExecutionTarget(
        _ payload: PeekabooBridgeBrowserExecuteRequest) async throws
        -> (
            receipt: PeekabooBridgeBrowserConnectionReceipt,
            disposition: PeekabooBridgeHandledResponse.Mutation.TargetDisposition)
    {
        let status: PeekabooBridgeBrowserStatus
        do {
            status = try await self.services.browserStatus(channel: payload.channel)
        } catch is CancellationError {
            throw Self.browserPreDispatchCancellationFailure()
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            if let failure = envelope.desktopActionFailure {
                throw failure
            }
            if envelope.code == .operationNotSupported {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .operationUnsupported,
                    message: envelope.message,
                    hint: "Use a browser provider that supports exact receipt-bound execution.",
                    causeDescription: envelope.details)
            }
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The exact browser connection could not be inspected before execution.",
                hint: "Reconnect the intended browser and retry.",
                causeDescription: envelope.localizedDescription)
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The exact browser connection could not be inspected before execution.",
                hint: "Reconnect the intended browser and retry.",
                causeDescription: error.localizedDescription)
        }
        guard status.isConnected, let receipt = status.connectionReceipt else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Browser execution requires a live exact connection receipt.",
                hint: "Connect the intended browser and retry.")
        }
        guard payload.channel == nil || receipt.channel == payload.channel else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The connected browser channel changed before execution.",
                hint: "Refresh browser status and retry against its exact channel.")
        }
        guard let expectedReceipt = payload.expectedConnectionReceipt else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Attested browser execution requires an expected connection receipt.",
                hint: "Refresh browser status and bind the request to its complete connection receipt.")
        }
        guard expectedReceipt == receipt else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The exact browser connection changed before execution.",
                hint: "Refresh browser status and retry against its complete connection receipt.")
        }
        return try (receipt, self.browserTargetDisposition(receipt))
    }

    private static func invalidBrowserConnectOutcome(_ outcome: DesktopActionOutcome) -> DesktopActionFailure {
        .indeterminate(
            delivery: outcome.delivery,
            evidence: .completionUnknown,
            unitCount: outcome.dispatchState.unitCount,
            message: "Browser connect returned contradictory canonical action semantics.",
            hint: "Check browser status before deciding whether to reconnect and update the runtime host.")
    }

    private static func browserPreDispatchCancellationFailure() -> DesktopActionFailure {
        .preDispatchRefusal(
            reason: .requestCancelled,
            message: "Browser execution was cancelled before tool dispatch.",
            hint: "Submit a new request only if the browser action is still wanted.")
    }
}
