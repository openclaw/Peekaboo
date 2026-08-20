import Foundation

public struct PeekabooBridgeProcessGenerationObservationDelivery: Sendable {
    public let response: PeekabooBridgeProcessGenerationObservationResponse
    public let receiptBundle: PeekabooBridgeOperationReceiptBundle
}

extension PeekabooBridgeClient {
    public func observeProcessGeneration(
        _ request: PeekabooBridgeProcessGenerationObservationRequest) async throws
        -> PeekabooBridgeProcessGenerationObservationResponse
    {
        try await self.observeProcessGenerationWithReceipt(request).response
    }

    public func observeProcessGenerationWithReceipt(
        _ request: PeekabooBridgeProcessGenerationObservationRequest) async throws
        -> PeekabooBridgeProcessGenerationObservationDelivery
    {
        try self.requireProcessGenerationObservation()
        try request.validate()
        let reply = try await self.sendCarryingActionOutcome(
            .observeProcessGeneration(request),
            operationReceiptRequirement: .required)
        let response = try Self.validatedProcessGenerationObservationResponse(
            reply.response,
            request: request)
        guard let receiptBundle = reply.operationReceiptBundle else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("the required terminal bundle")
        }
        return .init(response: response, receiptBundle: receiptBundle)
    }

    /// Returns the exact signed bundle even when observation failed without producing a disposition.
    public func observeProcessGenerationReceiptBundle(
        _ request: PeekabooBridgeProcessGenerationObservationRequest) async throws
        -> PeekabooBridgeOperationReceiptBundle
    {
        try self.requireProcessGenerationObservation()
        try request.validate()
        let reply = try await self.sendCarryingActionOutcome(
            .observeProcessGeneration(request),
            operationReceiptRequirement: .required,
            throwsActionFailures: false)
        switch reply.response {
        case let .processGenerationObservation(response):
            try response.validate(request: request)
        case .error:
            break
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected process-generation observation response")
        }
        guard let receiptBundle = reply.operationReceiptBundle else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("the required terminal bundle")
        }
        try receiptBundle.validateIntegrity()
        return receiptBundle
    }

    private func requireProcessGenerationObservation() throws {
        guard self.processGenerationObservationEnabled else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge protocol 1.32 signed process-generation observation is unavailable",
                details: "The host must advertise and enable observeProcessGeneration before use.")
        }
    }

    private nonisolated static func validatedProcessGenerationObservationResponse(
        _ response: PeekabooBridgeResponse,
        request: PeekabooBridgeProcessGenerationObservationRequest) throws
        -> PeekabooBridgeProcessGenerationObservationResponse
    {
        switch response {
        case let .processGenerationObservation(result):
            try result.validate(request: request)
            return result
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected process-generation observation response")
        }
    }
}
