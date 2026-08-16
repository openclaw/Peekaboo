import Foundation
import os.log
import PeekabooFoundation

@MainActor
extension PeekabooBridgeServer {
    public func decodeAndHandle(_ requestData: Data, peer: PeekabooBridgePeer?) async -> Data {
        do {
            let request = try self.decodeRequest(requestData)
            return await self.handleDecoded(request, peer: peer)
        } catch {
            return self.encodeDecodingFailure(error)
        }
    }

    /// Security boundary: request `Decodable` implementations are value-only. They must not perform I/O, Security
    /// validation, authority mutation, or desktop dispatch. The host authorizes and dispatches this exact returned
    /// value; it must never parse a second representation of the same wire bytes.
    func decodeRequest(_ requestData: Data) throws -> PeekabooBridgeRequest {
        #if DEBUG
        self.requestDecodeObserverForTesting?()
        #endif
        try PeekabooBridgeRequestPreflight.validate(requestData)
        return try self.decoder.decode(PeekabooBridgeRequest.self, from: requestData)
    }

    func handleDecoded(_ request: PeekabooBridgeRequest, peer: PeekabooBridgePeer?) async -> Data {
        do {
            if case let .attestedOperation(payload) = request {
                return try await self.handleAttestedOperation(payload, peer: peer)
            }
            if case let .projectedAction(payload) = request {
                return await self.handleProjectedAction(payload, peer: peer)
            }
            let handled = try await self.route(request, peer: peer)
            return try self.encoder.encode(handled.response)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            self.logger.error("bridge request failed code=\(envelope.code.rawValue, privacy: .public)")
            return PeekabooBridgeResponse.encodeError(envelope.legacyCompatible, using: self.encoder)
        } catch is CancellationError {
            self.logger.debug("bridge request cancelled after its client disconnected")
            let envelope = PeekabooBridgeErrorEnvelope(
                code: .timeout,
                message: "Bridge request was cancelled")
            return PeekabooBridgeResponse.encodeError(envelope, using: self.encoder)
        } catch {
            return self.encodeDecodingFailure(error)
        }
    }

    func encodeAdmissionRefusal(
        _ request: PeekabooBridgeRequest,
        peer: PeekabooBridgePeer) async -> Data
    {
        #if DEBUG
        await self.admissionRefusalObserverForTesting?()
        #endif
        do {
            if case let .attestedOperation(payload) = request {
                return try await self.handleAttestedOperation(
                    payload,
                    peer: peer,
                    admissionRefused: true)
            }
            return try self.encoder.encode(Self.admissionRefusalResponse(for: request))
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            return PeekabooBridgeResponse.encodeError(envelope.legacyCompatible, using: self.encoder)
        } catch {
            return self.encodeDecodingFailure(error)
        }
    }

    static func admissionRefusalResponse(
        for request: PeekabooBridgeRequest) throws -> PeekabooBridgeResponse
    {
        let semanticRequest: PeekabooBridgeRequest = if case let .projectedAction(payload) = request {
            try payload.validatedRequest()
        } else {
            request
        }
        let message = "Bridge request capacity is temporarily saturated"
        let details = "The decoded request was refused before desktop dispatch."
        let envelope: PeekabooBridgeErrorEnvelope = if
            PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics
        {
            .init(
                code: .serverBusy,
                actionFailure: .preDispatchRefusal(
                    route: .bridge,
                    reason: .transportSessionUnavailable,
                    message: message,
                    hint: "Reconnect the Bridge session before retrying.",
                    causeDescription: details),
                details: details)
        } else {
            PeekabooBridgeOperationResultSemantics.canonicalFailure(
                .init(code: .serverBusy, message: message, details: details),
                request: semanticRequest,
                stage: .preDispatch(.transportSessionUnavailable))
        }
        if case .projectedAction = request {
            return .projectedActionForCurrentRequestVocabulary(
                response: .error(envelope),
                outcome: envelope.actionOutcome)
        }
        return .error(envelope)
    }

    func encodeDecodingFailure(_ error: any Error) -> Data {
        if let envelope = error as? PeekabooBridgeErrorEnvelope {
            self.logger.error("bridge request failed code=\(envelope.code.rawValue, privacy: .public)")
            return PeekabooBridgeResponse.encodeError(envelope.legacyCompatible, using: self.encoder)
        }
        self.logger.error("bridge request decoding failed")
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .decodingFailed,
            message: "Failed to decode request",
            details: "\(error)")
        return PeekabooBridgeResponse.encodeError(envelope, using: self.encoder)
    }
}
