import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

extension PeekabooBridgeClient {
    public func browserStatus(channel: String?) async throws -> PeekabooBridgeBrowserStatus {
        let response = try await self.send(.browserStatus(PeekabooBridgeBrowserChannelRequest(channel: channel)))
        switch response {
        case let .browserStatus(status):
            try self.validateBrowserStatus(status)
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
        return try await self.actionResult(
            for: .browserExecute(boundRequest),
            expectedResponse: "browser tool",
            operationReceiptRequirement: .required)
        { response in
            guard case let .browserToolResponse(result) = response else { return nil }
            return result
        }.desktopActionResult
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
        let status = try await self.browserStatus(channel: request.channel)
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
        return request.binding(to: receipt)
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
