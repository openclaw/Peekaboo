import Foundation

public struct PeekabooBridgeAgentExecutionTraceDelivery: Sendable {
    public let response: PeekabooBridgeAgentExecutionTraceResponse
    public let receiptBundle: PeekabooBridgeOperationReceiptBundle
}

extension PeekabooBridgeClient {
    /// Runs one exact authenticated CLI peer as a suspended background Agent through protocol 1.31.
    ///
    /// The caller must arrange the owner-private coordination acknowledgement. The Bridge keeps
    /// this request open until the child reaches one terminal waitpid result and the signed response
    /// commits the exact launch, acknowledgement, output, and exit evidence.
    public func agentExecutionTrace(
        _ request: PeekabooBridgeAgentExecutionTraceRequest,
        timeoutSeconds: TimeInterval) async throws -> PeekabooBridgeAgentExecutionTraceResponse
    {
        try await self.agentExecutionTraceWithReceipt(request, timeoutSeconds: timeoutSeconds).response
    }

    /// Returns the typed result and its exact verified signature bundle from the same transport reply.
    public func agentExecutionTraceWithReceipt(
        _ request: PeekabooBridgeAgentExecutionTraceRequest,
        timeoutSeconds: TimeInterval) async throws -> PeekabooBridgeAgentExecutionTraceDelivery
    {
        try self.requireAgentExecutionTrace()
        let reply = try await self.sendCarryingActionOutcome(
            .agentExecutionTrace(request),
            timeoutSec: timeoutSeconds,
            operationReceiptRequirement: .required)
        let result = try Self.validatedAgentExecutionResponse(reply.response, request: request)
        guard let bundle = reply.operationReceiptBundle else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("the required terminal bundle")
        }
        return .init(response: result, receiptBundle: bundle)
    }

    /// Returns the exact bundle even when the signed terminal response is a retry-safe refusal.
    public func agentExecutionTraceReceiptBundle(
        _ request: PeekabooBridgeAgentExecutionTraceRequest,
        timeoutSeconds: TimeInterval) async throws -> PeekabooBridgeOperationReceiptBundle
    {
        try self.requireAgentExecutionTrace()
        let reply = try await self.sendCarryingActionOutcome(
            .agentExecutionTrace(request),
            timeoutSec: timeoutSeconds,
            operationReceiptRequirement: .required,
            throwsActionFailures: false)
        switch reply.response {
        case let .agentExecutionTrace(result):
            try result.validate(request: request)
        case .error:
            break
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected Agent execution trace response")
        }
        guard let bundle = reply.operationReceiptBundle else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("the required terminal bundle")
        }
        try bundle.validateIntegrity()
        return bundle
    }

    private func requireAgentExecutionTrace() throws {
        guard self.agentExecutionTraceEnabled else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge protocol 1.31 signed Agent execution is unavailable",
                details: "The host must advertise and enable agentExecutionTrace before launch.")
        }
    }

    private nonisolated static func validatedAgentExecutionResponse(
        _ response: PeekabooBridgeResponse,
        request: PeekabooBridgeAgentExecutionTraceRequest) throws -> PeekabooBridgeAgentExecutionTraceResponse
    {
        switch response {
        case let .agentExecutionTrace(result):
            try result.validate(request: request)
            return result
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected Agent execution trace response")
        }
    }
}
