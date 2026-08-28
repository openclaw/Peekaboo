import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

/// Explicit opt-in carriage for a Bridge request that returns canonical action semantics.
///
/// Bridge connections serve one request each, so a prior handshake cannot select the response
/// shape of a later connection. A capable client therefore wraps each action request while the
/// nested request preserves the established wire payload exactly.
public struct PeekabooBridgeProjectedActionRequest: Codable, Sendable {
    public let request: PeekabooBridgeRequest

    public init(request: PeekabooBridgeRequest) {
        self.request = request
    }

    private enum CodingKeys: String, CodingKey {
        case request
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.request = try container.decode(
            PeekabooBridgeRequestCodingBox.self,
            forKey: .request).value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(PeekabooBridgeRequestCodingBox(self.request), forKey: .request)
    }

    /// Returns the legacy action request after enforcing the one-layer action-result contract.
    public func validatedRequest() throws -> PeekabooBridgeRequest {
        if case .projectedAction = self.request {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Projected Bridge action requests cannot be nested")
        }
        if case .attestedOperation = self.request {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Projected Bridge action requests cannot contain attested operations")
        }
        let isSafeApplicationCheck = if case let .launchApplicationWithOptions(request) = self.request {
            request.isSafeBackgroundNoOp
        } else {
            false
        }
        guard self.request.mayMutateDesktop || isSafeApplicationCheck else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Projected Bridge action carriage requires a mutation or safe application check")
        }
        return self.request
    }
}

/// Additive response carriage for one projected action request.
///
/// `response` remains the legacy response. `outcome` is optional because older service seams do
/// not all expose their successful native outcome yet; absence must never be upgraded to a
/// fabricated confirmation.
public struct PeekabooBridgeProjectedActionResponse: Codable, Sendable {
    public let response: PeekabooBridgeResponse
    public let outcome: DesktopActionOutcome.Projection?

    public init(
        response: PeekabooBridgeResponse,
        outcome: DesktopActionOutcome.Projection?)
    {
        self.response = response
        self.outcome = outcome
    }

    private enum CodingKeys: String, CodingKey {
        case response
        case outcome
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.response = try container.decode(
            PeekabooBridgeResponseCodingBox.self,
            forKey: .response).value
        self.outcome = try container.decodeIfPresent(
            DesktopActionOutcome.Projection.self,
            forKey: .outcome)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(PeekabooBridgeResponseCodingBox(self.response), forKey: .response)
        try container.encodeIfPresent(self.outcome, forKey: .outcome)
    }
}

extension PeekabooBridgeResponse {
    /// Builds projected response carriage using only vocabulary understood by the active wire protocol.
    ///
    /// Receiptless projected requests are protocol 1.23...1.28. Those released clients have a closed
    /// delivery-mechanism enum without `composite` and require every action target receipt to contain a window ID.
    /// Suppress fields they cannot decode; protocol 1.29 validates and signs the complete current outcome.
    static func projectedActionForCurrentRequestVocabulary(
        response: PeekabooBridgeResponse,
        outcome: DesktopActionOutcome.Projection?,
        usesCurrentVocabulary: Bool = PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics)
        -> PeekabooBridgeResponse
    {
        guard !usesCurrentVocabulary else {
            return .projectedAction(.init(response: response, outcome: outcome))
        }
        let carriesCompositeOutcome = outcome?.deliveryMechanism == .composite ||
            response.carriesCompositeActionOutcome
        return .projectedAction(.init(
            response: response.removingLegacyIncompatibleActionFields,
            outcome: carriesCompositeOutcome ? nil : outcome))
    }

    private var carriesCompositeActionOutcome: Bool {
        switch self {
        case let .error(envelope):
            envelope.actionOutcome?.deliveryMechanism == .composite
        case let .browserToolResponse(response):
            response.actionFailure?.outcome.delivery?.mechanism == .composite
        case let .dialogResult(result):
            result.outcome?.delivery?.mechanism == .composite
        default:
            false
        }
    }

    private var removingLegacyIncompatibleActionFields: PeekabooBridgeResponse {
        switch self {
        case let .error(envelope) where envelope.actionOutcome?.deliveryMechanism == .composite:
            .error(envelope.legacyCompatible)
        case let .error(envelope):
            .error(envelope.removingProcessOnlyTargetReceiptForLegacyProjection)
        case let .browserToolResponse(response)
            where response.actionFailure?.outcome.delivery?.mechanism == .composite:
            .browserToolResponse(.init(
                content: response.content,
                isError: response.isError,
                meta: response.meta,
                connectionReceipt: response.connectionReceipt,
                completedCallCount: response.completedCallCount,
                dispatchedCallCount: response.dispatchedCallCount,
                actionFailure: nil))
        case let .browserToolResponse(response):
            .browserToolResponse(.init(
                content: response.content,
                isError: response.isError,
                meta: response.meta,
                connectionReceipt: response.connectionReceipt,
                completedCallCount: response.completedCallCount,
                dispatchedCallCount: response.dispatchedCallCount,
                actionFailure: response.actionFailure?.removingProcessOnlyTargetReceiptForLegacyProjection))
        case let .dialogResult(result) where result.outcome?.delivery?.mechanism == .composite:
            .dialogResult(.init(
                success: result.success,
                action: result.action,
                details: result.details,
                outcome: nil,
                targetReceipt: result.legacyCompatibleTargetReceipt,
                targetWindowIdentity: result.targetWindowIdentity,
                targetWindowBounds: result.targetWindowBounds,
                focusedElement: result.focusedElement,
                resolvedTarget: result.resolvedTarget))
        case let .dialogResult(result):
            .dialogResult(result.removingProcessOnlyTargetReceiptForLegacyProjection)
        default:
            self
        }
    }
}

extension DialogActionResult {
    fileprivate var legacyCompatibleTargetReceipt: DesktopActionTargetReceipt? {
        guard self.targetReceipt?.windowID != nil else { return nil }
        return self.targetReceipt
    }

    fileprivate var removingProcessOnlyTargetReceiptForLegacyProjection: Self {
        guard let targetReceipt = self.targetReceipt, targetReceipt.windowID == nil else { return self }
        return Self(
            success: self.success,
            action: self.action,
            details: self.details,
            outcome: self.outcome,
            targetReceipt: self.legacyCompatibleTargetReceipt,
            targetWindowIdentity: self.targetWindowIdentity,
            targetWindowBounds: self.targetWindowBounds,
            focusedElement: self.focusedElement,
            resolvedTarget: self.resolvedTarget)
    }
}

extension DesktopActionFailure {
    fileprivate var removingProcessOnlyTargetReceiptForLegacyProjection: Self {
        guard let targetReceipt = self.targetReceipt,
              targetReceipt.windowID == nil,
              let compatible = Self(
                  outcome: self.outcome,
                  message: self.message,
                  hint: self.hint,
                  causeDescription: self.causeDescription)
        else { return self }
        return compatible
    }
}

extension PeekabooBridgeErrorEnvelope {
    fileprivate var removingProcessOnlyTargetReceiptForLegacyProjection: Self {
        guard let targetReceipt = self.actionTargetReceipt,
              targetReceipt.windowID == nil,
              let failure = self.desktopActionFailure
        else { return self }
        return Self(
            code: self.code,
            actionFailure: failure.removingProcessOnlyTargetReceiptForLegacyProjection,
            details: self.details,
            permission: self.permission,
            kind: self.kind,
            context: self.context)
    }
}
