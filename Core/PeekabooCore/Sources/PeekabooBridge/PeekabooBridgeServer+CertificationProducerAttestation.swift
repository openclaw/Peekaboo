import Foundation

@MainActor
extension PeekabooBridgeServer {
    func handleCertificationProducerAttestation(
        _ request: PeekabooBridgeCertificationProducerAttestationRequest) async throws
        -> PeekabooBridgeCertificationProducerAttestationResponse
    {
        try request.validate()
        guard let listenerAttestation = PeekabooBridgeRequestContext.operationReceiptAuthority?.attestation else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Certification producer attestation requires signed Bridge operation receipts")
        }
        return try await PeekabooBridgeBlockingIO.run {
            try PeekabooBridgeCertificationProducerTransport.perform(
                request: request,
                listenerAttestation: listenerAttestation)
        }
    }
}
