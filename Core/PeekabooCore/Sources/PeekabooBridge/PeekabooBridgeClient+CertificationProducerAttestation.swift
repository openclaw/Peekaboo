import Foundation

public struct PeekabooBridgeCertificationProducerAttestationDelivery: Sendable {
    public let response: PeekabooBridgeCertificationProducerAttestationResponse
    public let receiptBundle: PeekabooBridgeOperationReceiptBundle
}

extension PeekabooBridgeClient {
    public func attestCertificationProducer(
        _ request: PeekabooBridgeCertificationProducerAttestationRequest) async throws
        -> PeekabooBridgeCertificationProducerAttestationResponse
    {
        try await self.attestCertificationProducerWithReceipt(request).response
    }

    public func attestCertificationProducerWithReceipt(
        _ request: PeekabooBridgeCertificationProducerAttestationRequest) async throws
        -> PeekabooBridgeCertificationProducerAttestationDelivery
    {
        try self.requireCertificationProducerAttestation()
        try request.validate()
        let reply = try await self.sendCarryingActionOutcome(
            .certificationProducerAttestation(request),
            operationReceiptRequirement: .required)
        guard case let .certificationProducerAttestation(response) = reply.response else {
            if case let .error(error) = reply.response {
                throw error
            }
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected certification producer attestation response")
        }
        guard let receiptBundle = reply.operationReceiptBundle else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("the required certification bundle")
        }
        try response.validate(
            request: request,
            listenerAttestation: receiptBundle.operationAttestation)
        return .init(response: response, receiptBundle: receiptBundle)
    }

    /// Returns the signed terminal bundle even when the producer refused or failed validation.
    public func certificationProducerAttestationReceiptBundle(
        _ request: PeekabooBridgeCertificationProducerAttestationRequest) async throws
        -> PeekabooBridgeOperationReceiptBundle
    {
        try self.requireCertificationProducerAttestation()
        try request.validate()
        let reply = try await self.sendCarryingActionOutcome(
            .certificationProducerAttestation(request),
            operationReceiptRequirement: .required,
            throwsActionFailures: false)
        switch reply.response {
        case let .certificationProducerAttestation(response):
            guard let receiptBundle = reply.operationReceiptBundle else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "the required certification bundle")
            }
            try response.validate(
                request: request,
                listenerAttestation: receiptBundle.operationAttestation)
        case .error:
            break
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected certification producer attestation response")
        }
        guard let receiptBundle = reply.operationReceiptBundle else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("the required certification bundle")
        }
        try receiptBundle.validateIntegrity()
        return receiptBundle
    }

    private func requireCertificationProducerAttestation() throws {
        guard self.certificationProducerAttestationEnabled else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge protocol 1.32 certification producer attestation is unavailable",
                details: "The host must advertise and enable certificationProducerAttestation before use.")
        }
    }
}
