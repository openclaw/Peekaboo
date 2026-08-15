import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

private struct OperationReceiptEncodingContext {
    let request: PeekabooBridgeRequest
    let requestPayload: PeekabooBridgeAttestedOperationRequest
    let authority: PeekabooBridgeOperationReceiptAuthority
    let startedAt: Int64
}

private struct OperationReceiptTargetState {
    let target: PeekabooBridgeOperationTargetReceipt?
    let focusedElement: FocusedElementIdentity?
    let failure: PeekabooBridgeTargetAttributionFailure?
    let failureEvidence: [PeekabooBridgeOperationTargetEvidence]?
}

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
        let encodingContext = OperationReceiptEncodingContext(
            request: request,
            requestPayload: payload,
            authority: authority,
            startedAt: startedAt)
        let requestEvidence = request.operationTargetEvidence
        let requestTarget: DesktopTargetIdentity?
        do {
            requestTarget = try PeekabooBridgeOperationTargetAttribution.resolveRequest(request)
        } catch let error as DesktopTargetIdentityError {
            let failure = PeekabooBridgeTargetAttributionFailure(error, stage: .preDispatch)
            let response = Self.targetAttributionFailureResponse(
                request: request,
                failure: failure,
                originalOutcome: nil,
                afterExecution: false)
            return try self.encodeAttestedResponse(
                response,
                targetState: .init(
                    target: nil,
                    focusedElement: nil,
                    failure: failure,
                    failureEvidence: requestEvidence.map(PeekabooBridgeOperationTargetEvidence.init)),
                context: encodingContext)
        }

        let handled = await self.terminalResponse(for: request, peer: peer)
        let response: PeekabooBridgeResponse
        let target: PeekabooBridgeOperationTargetReceipt?
        let focusedElement: FocusedElementIdentity?
        let targetFailure: PeekabooBridgeTargetAttributionFailure?
        let targetFailureEvidence: [PeekabooBridgeOperationTargetEvidence]?
        let attributionEvidence = PeekabooBridgeOperationTargetAttribution.evidence(
            request: request,
            response: handled.response,
            handledTarget: handled.targetIdentity ?? requestTarget)
        do {
            let resolved = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve(attributionEvidence)
            let receiptTarget = PeekabooBridgeResolvedOperationTarget(resolved)
            response = handled.response
            target = receiptTarget.target
            focusedElement = receiptTarget.focusedElement
            targetFailure = nil
            targetFailureEvidence = nil
        } catch let error as DesktopTargetIdentityError {
            let failure = PeekabooBridgeTargetAttributionFailure(error, stage: .postExecution)
            response = Self.targetAttributionFailureResponse(
                request: request,
                failure: failure,
                originalOutcome: handled.outcome?.projection ??
                    PeekabooBridgeOperationReceiptSemantics.outcome(in: handled.response),
                afterExecution: true)
            target = nil
            focusedElement = nil
            targetFailure = failure
            targetFailureEvidence = attributionEvidence.map(PeekabooBridgeOperationTargetEvidence.init)
        }
        return try self.encodeAttestedResponse(
            response,
            targetState: .init(
                target: target,
                focusedElement: focusedElement,
                failure: targetFailure,
                failureEvidence: targetFailureEvidence),
            context: encodingContext)
    }

    private func encodeAttestedResponse(
        _ response: PeekabooBridgeResponse,
        targetState: OperationReceiptTargetState,
        context: OperationReceiptEncodingContext) throws -> Data
    {
        let receiptPayload = try PeekabooBridgeOperationReceiptPayload(
            requestID: context.requestPayload.requestID,
            listenerInstanceID: context.authority.attestation.listenerInstanceID,
            listenerPublicKeySHA256: PeekabooBridgeOperationReceiptCoding.sha256(
                context.authority.attestation.publicKey),
            host: context.authority.attestation.host,
            client: context.requestPayload.client,
            operation: context.request.operation,
            requestSHA256: PeekabooBridgeOperationReceiptCoding.sha256(context.request),
            responseSHA256: PeekabooBridgeOperationReceiptCoding.sha256(response),
            target: targetState.target,
            focusedElement: targetState.focusedElement,
            targetAttributionFailure: targetState.failure,
            targetAttributionEvidence: targetState.failureEvidence,
            outcome: PeekabooBridgeOperationReceiptSemantics.outcome(in: response),
            startedAtUnixMilliseconds: context.startedAt,
            completedAtUnixMilliseconds: max(
                context.startedAt,
                PeekabooBridgeOperationReceiptCoding.unixMilliseconds()))
        let receipt: PeekabooBridgeOperationReceipt
        do {
            receipt = try context.authority.signAndArchive(receiptPayload)
        } catch {
            throw PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: "Bridge operation completed, but its signed receipt could not be archived",
                details: error.localizedDescription,
                operationMayHaveCompleted: context.request.mayMutateDesktop)
        }
        return try self.encoder.encode(PeekabooBridgeResponse.attestedOperation(.init(
            response: response,
            receipt: receipt)))
    }

    private func terminalResponse(
        for request: PeekabooBridgeRequest,
        peer: PeekabooBridgePeer) async -> PeekabooBridgeHandledResponse
    {
        if case let .projectedAction(payload) = request {
            do {
                let nestedRequest = try payload.validatedRequest()
                let handled = try await self.route(nestedRequest, peer: peer)
                return .init(
                    response: .projectedAction(.init(
                        response: handled.response,
                        outcome: handled.outcome?.routed(to: .bridge).projection)),
                    outcome: handled.outcome,
                    targetIdentity: handled.targetIdentity)
            } catch let envelope as PeekabooBridgeErrorEnvelope {
                return Self.projectedFailure(envelope)
            } catch is CancellationError {
                return Self.projectedFailure(.init(
                    code: .timeout,
                    message: "Bridge request was cancelled"))
            } catch {
                return Self.projectedFailure(.init(
                    code: .internalError,
                    message: error.localizedDescription,
                    details: "\(error)"))
            }
        }
        do {
            return try await self.route(request, peer: peer)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            return .init(response: .error(envelope.legacyCompatible))
        } catch is CancellationError {
            return .init(response: .error(.init(code: .timeout, message: "Bridge request was cancelled")))
        } catch {
            return .init(response: .error(.init(
                code: .internalError,
                message: error.localizedDescription,
                details: "\(error)")))
        }
    }

    private static func projectedFailure(
        _ envelope: PeekabooBridgeErrorEnvelope) -> PeekabooBridgeHandledResponse
    {
        .init(
            response: .projectedAction(.init(
                response: .error(envelope),
                outcome: envelope.actionOutcome)),
            outcome: envelope.actionOutcome?.outcome)
    }

    private static func targetAttributionFailureResponse(
        request: PeekabooBridgeRequest,
        failure: PeekabooBridgeTargetAttributionFailure,
        originalOutcome: DesktopActionOutcome.Projection?,
        afterExecution: Bool) -> PeekabooBridgeResponse
    {
        let context = "bridge_target_attribution:\(failure.code.rawValue)"
        guard request.mayMutateDesktop else {
            return .error(.init(
                code: .invalidRequest,
                message: "Bridge operation target attribution failed",
                details: failure.message,
                context: context))
        }

        let original = originalOutcome?.outcome
        let mayHaveDispatched = afterExecution && (original?.dispatchState.mutationDispatched ?? true)
        let actionFailure: DesktopActionFailure = if mayHaveDispatched {
            .indeterminate(
                route: .bridge,
                delivery: original?.delivery,
                evidence: .completionUnknown,
                unitCount: original?.dispatchState.unitCount,
                message: "Bridge operation completed without a trustworthy exact target receipt.",
                hint: "Observe the intended target before any retry.",
                causeDescription: failure.message)
        } else {
            .preDispatchRefusal(
                route: .bridge,
                reason: .invalidRequest,
                message: "Bridge operation was refused because its target receipt is invalid.",
                hint: "Capture fresh target evidence and retry with one exact process or window receipt.",
                causeDescription: failure.message)
        }
        let envelope = PeekabooBridgeErrorEnvelope(
            code: mayHaveDispatched ? .internalError : .invalidRequest,
            actionFailure: actionFailure,
            context: context)
        if case .projectedAction = request {
            return .projectedAction(.init(
                response: .error(envelope),
                outcome: actionFailure.outcome.projection))
        }
        return .error(envelope)
    }
}
