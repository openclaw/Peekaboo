import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

extension PeekabooBridgeClient {
    public nonisolated static func browserSessionTerminalFailure(
        from error: any Error) -> PeekabooBridgeBrowserSessionTerminalFailure?
    {
        if let envelope = error as? PeekabooBridgeErrorEnvelope {
            return switch (envelope.code, envelope.context) {
            case (.invalidRequest, PeekabooBridgeBrowserSessionErrorContext.invalid): .invalidSession
            case (.invalidRequest, PeekabooBridgeBrowserSessionErrorContext.ended): .sessionEnded
            case (.unauthorizedClient, PeekabooBridgeBrowserSessionErrorContext.wrongOwner): .wrongOwner
            case (.versionMismatch, PeekabooBridgeBrowserSessionErrorContext.hostGenerationChanged):
                .hostGenerationChanged
            default: nil
            }
        }
        guard let receiptError = error as? PeekabooBridgeOperationReceiptError else { return nil }
        return switch receiptError {
        case .invalidListenerAttestation, .invalidListenerSignature,
             .invalidOperationSessionAttestation, .invalidOperationSessionSignature,
             .listenerInstanceMismatch, .peerIdentityMismatch, .clientIdentityMismatch:
            .hostGenerationChanged
        case .invalidOperationSessionConfiguration, .operationSessionMismatch,
             .operationSessionRegistryExhausted, .replayedRequest, .invalidOperationSignature,
             .receiptMismatch, .unsafeArchive, .archiveWriteFailed:
            nil
        }
    }

    public func browserStatus(
        channel: String?,
        sessionID: UUID? = nil) async throws -> PeekabooBridgeBrowserStatus
    {
        let response = try await self.send(.browserStatus(PeekabooBridgeBrowserChannelRequest(
            channel: channel,
            sessionID: sessionID)))
        switch response {
        case let .browserStatus(status):
            try self.validateBrowserStatus(status)
            if sessionID != nil, !status.isCanonicalScopedSessionStatus {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "canonical scoped browser status evidence")
            }
            return status
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected browser status response")
        }
    }

    public func browserConnect(
        channel: String?,
        browserURL: String? = nil) async throws -> PeekabooBridgeBrowserStatus
    {
        if browserURL == nil, !self.nativeBrowserConnectionBindingEnabled {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "Channel browser connect requires native browser connection binding.",
                hint: "Update and relaunch the Peekaboo Bridge host before retrying.")
        }
        if self.operationAttestation == nil {
            do {
                return try await self.directBrowserConnect(.browserConnect(.init(
                    channel: channel,
                    browserURL: browserURL)))
            } catch is PeekabooBridgeLegacyBrowserConnectResponseError {
                throw PeekabooBridgeErrorEnvelope(
                    code: .invalidRequest,
                    message: "Unexpected browser connect response")
            }
        }
        return try await self.browserConnectResult(channel: channel, browserURL: browserURL).payload
    }

    public func browserConnectResult(
        channel: String?,
        browserURL: String? = nil) async throws -> DesktopActionResult<PeekabooBridgeBrowserStatus>
    {
        if browserURL == nil, !self.nativeBrowserConnectionBindingEnabled {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "Channel browser connect requires native browser connection binding.",
                hint: "Update and relaunch the Peekaboo Bridge host before retrying.")
        }
        let request = PeekabooBridgeRequest.browserConnect(PeekabooBridgeBrowserChannelRequest(
            channel: channel,
            browserURL: browserURL))
        guard self.operationAttestation != nil else {
            guard self.usesExplicitReceiptlessTransport() else {
                throw DesktopActionFailure.preDispatchRefusal(
                    route: .bridge,
                    reason: .transportSessionUnavailable,
                    message: "Legacy Bridge browser connect requires a completed handshake.",
                    hint: "Complete a Bridge handshake before retrying.")
            }
            do {
                let status = try await self.directBrowserConnect(request)
                return DesktopActionResult(
                    payload: status,
                    outcome: .dispatchedUnverified(
                        route: .bridge,
                        delivery: .init(mechanism: .browserProtocol, mode: .foreground),
                        evidence: .deliveryAccepted,
                        unitCount: .one))
            } catch let failure as DesktopActionFailure {
                throw failure
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch let envelope as PeekabooBridgeErrorEnvelope {
                throw envelope
            } catch {
                throw DesktopActionFailure.indeterminate(
                    route: .bridge,
                    delivery: .init(mechanism: .browserProtocol, mode: .foreground),
                    evidence: .completionUnknown,
                    unitCount: .one,
                    message: "Legacy Bridge browser connect completion is unknown.",
                    hint: "Check browser status before deciding whether to reconnect.",
                    causeDescription: error.localizedDescription)
            }
        }
        let result: UIAutomationActionResult<PeekabooBridgeBrowserStatus> = try await self.actionResult(
            for: request,
            expectedResponse: "browser connect",
            timeoutSec: BrowserConnectionTiming.bridgeTransportTimeoutSeconds,
            operationReceiptRequirement: .required)
        { response in
            guard case let .browserStatus(status) = response else { return nil }
            return status
        }
        try self.validateBrowserStatus(result.payload)
        return result.desktopActionResult
    }

    public func browserConnectResult(
        sessionID: UUID,
        channel: String?,
        browserURL: String? = nil) async throws -> DesktopActionResult<PeekabooBridgeBrowserStatus>
    {
        guard self.browserConnectionHandoffEnabled else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge protocol 1.38 authenticated browser sessions are unavailable")
        }
        let request = PeekabooBridgeRequest.browserConnect(.init(
            channel: channel,
            browserURL: browserURL,
            sessionID: sessionID))
        let result: UIAutomationActionResult<PeekabooBridgeBrowserStatus> = try await self.actionResult(
            for: request,
            expectedResponse: "scoped browser connect",
            timeoutSec: BrowserConnectionTiming.bridgeTransportTimeoutSeconds,
            operationReceiptRequirement: .required)
        { response in
            guard case let .browserStatus(status) = response else { return nil }
            return status
        }
        try self.validateBrowserStatus(result.payload)
        guard result.payload.isCanonicalScopedSessionStatus else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "canonical scoped browser connect evidence")
        }
        return result.desktopActionResult
    }

    /// Connects in the foreground and returns the exact signed file-borne evidence needed by a
    /// later authenticated MCP process. Ordinary browser-connect APIs never request this grant.
    public func browserConnectHandoffResult(
        channel: String?,
        browserURL: String? = nil) async throws
        -> (
            result: DesktopActionResult<PeekabooBridgeBrowserStatus>,
            receiptBundle: PeekabooBridgeOperationReceiptBundle)
    {
        guard self.browserConnectionHandoffEnabled else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge protocol 1.38 authenticated browser handoff is unavailable")
        }
        if browserURL == nil, !self.nativeBrowserConnectionBindingEnabled {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "Channel browser connect requires native browser connection binding.",
                hint: "Update and relaunch the Peekaboo Bridge host before retrying.")
        }
        let request = PeekabooBridgeRequest.browserConnect(.init(
            channel: channel,
            browserURL: browserURL,
            requestsHandoff: true))
        let reply = try await self.sendCarryingActionOutcome(
            request,
            timeoutSec: BrowserConnectionTiming.bridgeTransportTimeoutSeconds,
            operationReceiptRequirement: .required)
        guard case let .browserStatus(status) = reply.response,
              let outcome = reply.outcome?.outcome,
              let receiptBundle = reply.operationReceiptBundle,
              let receipt = status.connectionReceipt,
              status.isConnected,
              receipt.matchesConnectRequest(.init(
                  channel: channel,
                  browserURL: browserURL,
                  requestsHandoff: true)),
              outcome.isAccepted(by: .confirmedNoChangeOrDispatched(
                  requiring: .init(mechanism: .browserProtocol, mode: .foreground),
                  unitCount: .exact(.one)))
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "the required handoff-enabled browser connect result")
        }
        try self.validateBrowserStatus(status)
        return (
            DesktopActionResult(payload: status, outcome: outcome),
            receiptBundle)
    }

    public func browserSessionBootstrap(
        receiptBundle: PeekabooBridgeOperationReceiptBundle? = nil,
        claimID: UUID) async throws -> PeekabooBridgeBrowserSessionBootstrapResponse
    {
        guard self.browserConnectionHandoffEnabled else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge protocol 1.38 authenticated browser handoff is unavailable")
        }
        let reply = try await self.sendCarryingActionOutcome(
            .browserSessionBootstrap(.init(receiptBundle: receiptBundle, claimID: claimID)),
            operationReceiptRequirement: .required)
        switch reply.response {
        case let .browserSessionBootstrap(response):
            let targetReceiptSHA256: String? = try receiptBundle.map { bundle in
                let connectResponse = try JSONDecoder.peekabooBridgeDecoder().decode(
                    PeekabooBridgeResponse.self,
                    from: bundle.canonicalResponse)
                guard let connectionReceipt = connectResponse.browserExecutionConnectionReceipt else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "the browser handoff connection receipt")
                }
                return try PeekabooBridgeOperationReceiptCoding.sha256(connectionReceipt)
            }
            guard response.claimID == claimID,
                  response.targetReceiptSHA256 == targetReceiptSHA256
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "the browser session bootstrap claim or target identifier")
            }
            return response
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected browser session bootstrap response")
        }
    }

    public func browserSessionDisconnect(_ sessionID: UUID) async throws {
        try await self.sendExpectOK(.browserSessionControl(.init(
            sessionID: sessionID,
            action: .disconnect)))
    }

    public func browserSessionEnd(_ sessionID: UUID) async throws {
        try await self.sendExpectOK(.browserSessionControl(.init(
            sessionID: sessionID,
            action: .end)))
    }

    private func directBrowserConnect(
        _ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeBrowserStatus
    {
        let response = try await self.sendWithoutActionProjection(
            request,
            timeoutSec: BrowserConnectionTiming.bridgeTransportTimeoutSeconds)
        switch response {
        case let .browserStatus(status):
            try self.validateBrowserStatus(status)
            return status
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeLegacyBrowserConnectResponseError()
        }
    }

    public func browserDisconnect() async throws {
        try await self.sendExpectOK(.browserDisconnect)
    }

    public func browserExecute(_ request: PeekabooBridgeBrowserExecuteRequest) async throws
        -> PeekabooBridgeBrowserToolResponse
    {
        if request.expectedConnectionReceipt?.isCanonicalProcessBoundTarget == true,
           !self.nativeBrowserConnectionBindingEnabled
        {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "Process-bound browser execution requires native browser connection binding.",
                hint: "Update and relaunch the Peekaboo Bridge host before retrying.")
        }
        if self.operationAttestation == nil {
            let boundRequest = try await self.receiptBoundBrowserRequest(request)
            return try await self.directBrowserExecute(boundRequest)
        }
        let result = try await self.browserExecuteResult(request)
        if let failure = result.payload.actionFailure {
            throw failure
        }
        return result.payload
    }

    /// Executes a browser request while retaining the Bridge's canonical outer action outcome when it mutates.
    ///
    /// The legacy ``browserExecute(_:)`` API still throws an embedded browser action failure.
    /// Result-aware mutations require receipt-bound execution; read-only requests return a nil outcome.
    public func browserExecuteResult(_ request: PeekabooBridgeBrowserExecuteRequest) async throws
        -> DesktopActionResult<PeekabooBridgeBrowserToolResponse>
    {
        if request.expectedConnectionReceipt?.isCanonicalProcessBoundTarget == true,
           !self.nativeBrowserConnectionBindingEnabled
        {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "Process-bound browser execution requires native browser connection binding.",
                hint: "Update and relaunch the Peekaboo Bridge host before retrying.")
        }
        let boundRequest = try await self.receiptBoundBrowserRequest(request)
        if request.isReadOnly {
            let response = try await self.directBrowserExecute(boundRequest)
            try self.validateBrowserReadResponse(response, request: boundRequest)
            return DesktopActionResult(payload: response, outcome: nil)
        }
        guard self.operationAttestation != nil else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .operationUnsupported,
                message: "Result-aware browser execution requires receipt-bound Bridge execution.",
                hint: "Use a protocol 1.29 runtime with operation receipts, or use the legacy browser API.")
        }
        let result: DesktopActionResult<PeekabooBridgeBrowserToolResponse> = try await self.actionResult(
            for: .browserExecute(boundRequest),
            expectedResponse: "browser tool",
            operationReceiptRequirement: .required)
        { response in
            guard case let .browserToolResponse(result) = response else { return nil }
            return result
        }.desktopActionResult
        if result.payload.actionFailure == nil,
           !result.payload.isError,
           let expectedEpoch = boundRequest.expectedProviderSessionEpoch,
           result.payload.providerSessionEpoch != expectedEpoch
        {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .targetUnavailable,
                message: "Scoped browser execution returned a different provider epoch.",
                hint: "Refresh scoped browser status before retrying.")
        }
        return result
    }

    private func receiptBoundBrowserRequest(
        _ request: PeekabooBridgeBrowserExecuteRequest) async throws -> PeekabooBridgeBrowserExecuteRequest
    {
        if let expectedReceipt = request.expectedConnectionReceipt {
            guard expectedReceipt.isCanonicalExecutionTarget,
                  request.channel == nil || request.channel == expectedReceipt.channel
            else {
                throw DesktopActionFailure.preDispatchRefusal(
                    route: .bridge,
                    reason: .invalidRequest,
                    message: "Result-aware browser mutation requires one complete target receipt.",
                    hint: "Refresh browser status and bind its complete receipt before retrying.")
            }
            if expectedReceipt.isCanonicalProcessBoundTarget,
               !self.nativeBrowserConnectionBindingEnabled
            {
                throw DesktopActionFailure.preDispatchRefusal(
                    route: .bridge,
                    reason: .runtimeIncompatible,
                    message: "Process-bound browser execution requires native browser connection binding.",
                    hint: "Update and relaunch the Peekaboo Bridge host before retrying.")
            }
            return request.binding(to: expectedReceipt)
        }
        let expectedOperationAttestation = self.operationAttestation
        let status = try await self.browserStatus(
            channel: request.channel,
            sessionID: request.sessionID)
        if let expectedOperationAttestation,
           self.operationAttestation != expectedOperationAttestation
        {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .transportSessionUnavailable,
                message: "Bridge operation session changed during browser target inspection.",
                hint: "Establish a fresh Bridge handshake before retrying.")
        }
        guard status.isConnected,
              let receipt = status.connectionReceipt,
              receipt.isCanonicalExecutionTarget,
              request.channel == nil || receipt.channel == request.channel
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .targetUnavailable,
                message: "Browser execution requires one exact live connection receipt.",
                hint: "Reconnect the intended browser and retry.")
        }
        if receipt.isCanonicalProcessBoundTarget,
           !self.nativeBrowserConnectionBindingEnabled
        {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "Process-bound browser execution requires native browser connection binding.",
                hint: "Update and relaunch the Peekaboo Bridge host before retrying.")
        }
        if request.sessionID != nil, status.providerSessionEpoch == nil {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .targetUnavailable,
                message: "Scoped browser status omitted its provider epoch.",
                hint: "Refresh the scoped browser session before retrying.")
        }
        return request.binding(
            to: receipt,
            providerSessionEpoch: status.providerSessionEpoch)
    }

    private func directBrowserExecute(
        _ request: PeekabooBridgeBrowserExecuteRequest) async throws -> PeekabooBridgeBrowserToolResponse
    {
        let response = try await self.sendWithoutActionProjection(.browserExecute(request))
        switch response {
        case let .browserToolResponse(result):
            if let failure = result.actionFailure {
                throw failure
            }
            return result
        case let .error(envelope):
            try Self.throwActionFailureOrEnvelope(envelope)
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected browser tool response")
        }
    }

    private func validateBrowserReadResponse(
        _ response: PeekabooBridgeBrowserToolResponse,
        request: PeekabooBridgeBrowserExecuteRequest) throws
    {
        guard let expectedReceipt = request.expectedConnectionReceipt else {
            preconditionFailure("Receipt binding must precede browser read transport")
        }
        if let returnedReceipt = response.connectionReceipt {
            guard returnedReceipt == expectedReceipt else {
                throw DesktopActionFailure.preDispatchRefusal(
                    route: .bridge,
                    reason: .targetUnavailable,
                    message: "Browser read response did not match its requested connection receipt.",
                    hint: "Refresh browser status and retry against its exact connection receipt.")
            }
        } else if self.operationAttestation != nil {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .targetUnavailable,
                message: "Attested browser read response omitted its connection receipt.",
                hint: "Update and relaunch the Peekaboo Bridge host before retrying.")
        }
        if request.sessionID != nil,
           !response.isError,
           response.providerSessionEpoch != request.expectedProviderSessionEpoch
        {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .targetUnavailable,
                message: "Scoped browser read returned a different provider epoch.",
                hint: "Refresh scoped browser status before retrying.")
        }
    }

    private func validateBrowserStatus(_ status: PeekabooBridgeBrowserStatus) throws {
        guard let receipt = status.connectionReceipt else { return }
        guard receipt.isCanonicalTarget else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .targetUnavailable,
                message: "Bridge returned a noncanonical browser connection receipt.",
                hint: "Update the Bridge host and reconnect the intended browser.")
        }
        if receipt.isCanonicalProcessBoundTarget,
           !self.nativeBrowserConnectionBindingEnabled
        {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "Process-bound browser status requires native browser connection binding.",
                hint: "Update and relaunch the Peekaboo Bridge host before retrying.")
        }
    }
}

private struct PeekabooBridgeLegacyBrowserConnectResponseError: LocalizedError {
    var errorDescription: String? {
        "Legacy Bridge host returned an unexpected browser connect response."
    }
}
