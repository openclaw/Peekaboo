import Foundation
import PeekabooFoundation

@MainActor
extension PeekabooBridgeServer {
    func handleAttestedOperation(
        _ payload: PeekabooBridgeAttestedOperationRequest,
        peer: PeekabooBridgePeer?) async throws -> Data
    {
        guard let authority = PeekabooBridgeRequestContext.operationReceiptAuthority else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "This Bridge listener does not support attested operation receipts")
        }
        guard let peer else {
            throw PeekabooBridgeErrorEnvelope(
                code: .unauthorizedClient,
                message: "Attested Bridge operations require an authenticated socket peer")
        }
        let request = try payload.validatedRequest()
        do {
            try authority.claim(payload, peer: peer)
        } catch let error as PeekabooBridgeOperationReceiptError {
            let code: PeekabooBridgeErrorCode = switch error {
            case .replayedRequest, .listenerInstanceMismatch, .clientIdentityMismatch:
                .invalidRequest
            default:
                .unauthorizedClient
            }
            throw PeekabooBridgeErrorEnvelope(code: code, message: error.localizedDescription)
        }

        let startedAt = PeekabooBridgeOperationReceiptCoding.unixMilliseconds()
        let response = await self.terminalResponse(for: request, peer: peer)
        let completedAt = PeekabooBridgeOperationReceiptCoding.unixMilliseconds()
        let receiptPayload = try PeekabooBridgeOperationReceiptPayload(
            requestID: payload.requestID,
            listenerInstanceID: authority.attestation.listenerInstanceID,
            listenerPublicKeySHA256: PeekabooBridgeOperationReceiptCoding.sha256(
                authority.attestation.publicKey),
            host: authority.attestation.host,
            client: payload.client,
            operation: request.operation,
            requestSHA256: PeekabooBridgeOperationReceiptCoding.sha256(request),
            responseSHA256: PeekabooBridgeOperationReceiptCoding.sha256(response),
            target: request.operationTargetReceipt(resolvedFrom: response),
            outcome: Self.operationOutcome(in: response),
            startedAtUnixMilliseconds: startedAt,
            completedAtUnixMilliseconds: max(startedAt, completedAt))
        let receipt: PeekabooBridgeOperationReceipt
        do {
            receipt = try authority.signAndArchive(receiptPayload)
        } catch {
            throw PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: "Bridge operation completed, but its signed receipt could not be archived",
                details: error.localizedDescription,
                operationMayHaveCompleted: request.mayMutateDesktop)
        }
        return try self.encoder.encode(PeekabooBridgeResponse.attestedOperation(.init(
            response: response,
            receipt: receipt)))
    }

    private func terminalResponse(
        for request: PeekabooBridgeRequest,
        peer: PeekabooBridgePeer) async -> PeekabooBridgeResponse
    {
        if case let .projectedAction(payload) = request {
            let data = await self.handleProjectedAction(payload, peer: peer)
            return (try? self.decoder.decode(PeekabooBridgeResponse.self, from: data)) ?? .error(.init(
                code: .internalError,
                message: "Failed to decode the Bridge's projected action response"))
        }
        do {
            return try await self.route(request, peer: peer).response
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            return .error(envelope.legacyCompatible)
        } catch is CancellationError {
            return .error(.init(code: .timeout, message: "Bridge request was cancelled"))
        } catch {
            return .error(.init(
                code: .internalError,
                message: error.localizedDescription,
                details: "\(error)"))
        }
    }

    private static func operationOutcome(
        in response: PeekabooBridgeResponse) -> DesktopActionOutcome.Projection?
    {
        switch response {
        case let .projectedAction(payload): payload.outcome
        case let .error(envelope): envelope.actionOutcome
        default: nil
        }
    }
}
