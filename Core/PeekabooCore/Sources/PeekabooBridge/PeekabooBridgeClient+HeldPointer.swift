import PeekabooAutomationKit
import PeekabooFoundation

extension PeekabooBridgeClient {
    public func createExactWindowHeldPointerOwner() async throws -> ExactWindowHeldPointerOwner {
        try self.requireExactWindowHeldPointerBegin()
        let response = try await self.send(.createExactWindowHeldPointerOwner)
        guard case let .exactWindowHeldPointerOwner(owner) = response else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected held pointer owner response")
        }
        return owner
    }

    public func beginExactWindowPointerHold(
        owner: ExactWindowHeldPointerOwner,
        request: ExactWindowHeldPointerRequest) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerReceipt>
    {
        try self.requireExactWindowHeldPointerBegin()
        return try await self.actionResult(
            for: .beginExactWindowHeldPointer(.init(owner: owner, request: request)),
            expectedResponse: "exact-window held pointer begin",
            requiresTargetIdentity: true,
            operationReceiptRequirement: .required)
        { response in
            guard case let .exactWindowHeldPointerReceipt(receipt) = response else { return nil }
            return receipt
        }
    }

    public func releaseExactWindowPointerHold(
        owner: ExactWindowHeldPointerOwner,
        receipt: ExactWindowHeldPointerReceipt) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination>
    {
        try await self.finishExactWindowPointerHold(
            request: .releaseExactWindowHeldPointer(.init(owner: owner, receipt: receipt)),
            expectedResponse: "exact-window held pointer release")
    }

    public func revokeExactWindowPointerHold(
        owner: ExactWindowHeldPointerOwner,
        receipt: ExactWindowHeldPointerReceipt) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination>
    {
        try await self.finishExactWindowPointerHold(
            request: .revokeExactWindowHeldPointer(.init(owner: owner, receipt: receipt)),
            expectedResponse: "exact-window held pointer revoke")
    }

    public func disconnectExactWindowHeldPointerOwner(
        _ owner: ExactWindowHeldPointerOwner) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination?>
    {
        try self.requireExactWindowHeldPointerTerminalCleanup()
        return try await self.actionResult(
            for: .disconnectExactWindowHeldPointerOwner(.init(owner: owner)),
            expectedResponse: "held pointer owner disconnect",
            operationReceiptRequirement: .required)
        { response in
            guard case let .exactWindowHeldPointerTermination(termination) = response else { return nil }
            return .some(termination)
        }
    }

    private func finishExactWindowPointerHold(
        request: PeekabooBridgeRequest,
        expectedResponse: String) async throws -> UIAutomationActionResult<ExactWindowHeldPointerTermination>
    {
        try self.requireExactWindowHeldPointerTerminalCleanup()
        return try await self.actionResult(
            for: request,
            expectedResponse: expectedResponse,
            requiresTargetIdentity: true,
            operationReceiptRequirement: .required)
        { response in
            guard case let .exactWindowHeldPointerTermination(termination?) = response else { return nil }
            return termination
        }
    }

    private func requireExactWindowHeldPointerBegin() throws {
        guard self.exactWindowHeldPointerLifecycleEnabled else {
            throw PeekabooError.serviceUnavailable(
                "Exact-window held pointer lifecycle requires a protocol-1.30 Bridge host advertising the capability")
        }
    }

    private func requireExactWindowHeldPointerTerminalCleanup() throws {
        guard self.exactWindowHeldPointerTerminalCleanupEnabled else {
            throw PeekabooError.serviceUnavailable(
                "Exact-window held pointer cleanup requires the protocol-1.30 Bridge host that owns the hold")
        }
    }
}
