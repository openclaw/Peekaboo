import Foundation
import PeekabooFoundation

extension PeekabooBridgeClient {
    public func browserStatus(channel: String?) async throws -> PeekabooBridgeBrowserStatus {
        let response = try await self.send(.browserStatus(PeekabooBridgeBrowserChannelRequest(channel: channel)))
        switch response {
        case let .browserStatus(status):
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
        return try await self.actionResult(
            for: request,
            expectedResponse: "browser connect",
            operationReceiptRequirement: .required)
        { response in
            guard case let .browserStatus(status) = response else { return nil }
            return status
        }.desktopActionResult
    }

    private func directBrowserConnect(
        _ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeBrowserStatus
    {
        let response = try await self.sendWithoutActionProjection(request)
        switch response {
        case let .browserStatus(status):
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
        if self.operationAttestation == nil {
            return try await self.directBrowserExecute(request)
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
        if request.isReadOnly {
            return try await DesktopActionResult(payload: self.directBrowserExecute(request), outcome: nil)
        }
        let boundRequest = try await self.receiptBoundBrowserRequest(request)
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
        guard self.operationAttestation != nil else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .operationUnsupported,
                message: "Result-aware browser mutation requires receipt-bound Bridge execution.",
                hint: "Use a protocol 1.29 runtime with operation receipts, or use the legacy browser API.")
        }
        if let expectedReceipt = request.expectedConnectionReceipt {
            guard expectedReceipt.isCanonicalTarget,
                  request.channel == nil || request.channel == expectedReceipt.channel
            else {
                throw DesktopActionFailure.preDispatchRefusal(
                    route: .bridge,
                    reason: .invalidRequest,
                    message: "Result-aware browser mutation requires one complete target receipt.",
                    hint: "Refresh browser status and bind its complete receipt before retrying.")
            }
            return request
        }
        let status = try await self.browserStatus(channel: request.channel)
        guard status.isConnected,
              let receipt = status.connectionReceipt,
              receipt.isCanonicalTarget,
              request.channel == nil || receipt.channel == request.channel
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .targetUnavailable,
                message: "Browser execution requires one exact live connection receipt.",
                hint: "Reconnect the intended browser and retry.")
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
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected browser tool response")
        }
    }
}

private struct PeekabooBridgeLegacyBrowserConnectResponseError: LocalizedError {
    var errorDescription: String? {
        "Legacy Bridge host returned an unexpected browser connect response."
    }
}
