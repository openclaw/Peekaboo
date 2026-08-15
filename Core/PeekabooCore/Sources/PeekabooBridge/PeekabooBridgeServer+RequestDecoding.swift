import Foundation
import os.log

@MainActor
extension PeekabooBridgeServer {
    public func decodeAndHandle(_ requestData: Data, peer: PeekabooBridgePeer?) async -> Data {
        do {
            try PeekabooBridgeRequestPreflight.validate(requestData)
            let request = try self.decoder.decode(PeekabooBridgeRequest.self, from: requestData)
            if case let .attestedOperation(payload) = request {
                return try await self.handleAttestedOperation(payload, peer: peer)
            }
            if case let .projectedAction(payload) = request {
                return await self.handleProjectedAction(payload, peer: peer)
            }
            let handled = try await self.route(request, peer: peer)
            return try self.encoder.encode(handled.response)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            self.logger.error("bridge request failed: \(envelope.message, privacy: .public)")
            return PeekabooBridgeResponse.encodeError(envelope.legacyCompatible, using: self.encoder)
        } catch is CancellationError {
            self.logger.debug("bridge request cancelled after its client disconnected")
            let envelope = PeekabooBridgeErrorEnvelope(
                code: .timeout,
                message: "Bridge request was cancelled")
            return PeekabooBridgeResponse.encodeError(envelope, using: self.encoder)
        } catch {
            self.logger.error("bridge request decoding failed: \(error.localizedDescription, privacy: .public)")
            let envelope = PeekabooBridgeErrorEnvelope(
                code: .decodingFailed,
                message: "Failed to decode request",
                details: "\(error)")
            return PeekabooBridgeResponse.encodeError(envelope, using: self.encoder)
        }
    }
}
