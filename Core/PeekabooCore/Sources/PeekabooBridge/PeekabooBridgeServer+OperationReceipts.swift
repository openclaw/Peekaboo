import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

private struct OperationReceiptEncodingContext {
    let request: PeekabooBridgeRequest
    let requestPayload: PeekabooBridgeAttestedOperationRequest
    let authority: PeekabooBridgeOperationReceiptAuthority
    let claim: PeekabooBridgeOperationSessionClaim
    let startedAt: Int64
}

private struct OperationReceiptTargetState {
    let target: PeekabooBridgeOperationTargetReceipt?
    let focusedElement: FocusedElementIdentity?
    let failure: PeekabooBridgeTargetAttributionFailure?
    let failureEvidence: [PeekabooBridgeOperationTargetEvidence]?
}

private enum OperationReceiptRequestCarriage {
    case valid(PeekabooBridgeRequest)
    case invalidProjected(any Error)
}

@MainActor
extension PeekabooBridgeServer {
    func handleAttestedOperation(
        _ payload: PeekabooBridgeAttestedOperationRequest,
        peer: PeekabooBridgePeer?,
        admissionRefused: Bool = false) async throws -> Data
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
        let requestCarriage = try Self.validateOperationReceiptRequestCarriage(payload)
        let claim: PeekabooBridgeOperationSessionClaim
        do {
            switch try await authority.claim(payload, peer: peer) {
            case let .accepted(acceptedClaim):
                claim = acceptedClaim
            case let .rolloverRequired(refusal):
                return try self.encoder.encode(PeekabooBridgeResponse.operationSessionRollover(refusal))
            }
        } catch let error as PeekabooBridgeOperationReceiptError {
            let code = Self.operationReceiptClaimErrorCode(error)
            throw PeekabooBridgeErrorEnvelope(code: code, message: error.localizedDescription)
        }
        defer { authority.complete(claim) }

        let startedAt = PeekabooBridgeOperationReceiptCoding.unixMilliseconds()
        let request: PeekabooBridgeRequest
        switch requestCarriage {
        case let .valid(validatedRequest):
            request = validatedRequest
        case let .invalidProjected(error):
            return try await self.encodeInvalidAttestedRequestCarriage(
                error: error,
                payload: payload,
                authority: authority,
                claim: claim,
                startedAt: startedAt)
        }
        let encodingContext = OperationReceiptEncodingContext(
            request: request,
            requestPayload: payload,
            authority: authority,
            claim: claim,
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
            return try await self.encodeAttestedResponse(
                response,
                targetState: .init(
                    target: nil,
                    focusedElement: nil,
                    failure: failure,
                    failureEvidence: requestEvidence.map(PeekabooBridgeOperationTargetEvidence.init)),
                context: encodingContext)
        }
        if admissionRefused {
            let response = try PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics
                .withValue(true) {
                    try Self.admissionRefusalResponse(for: request)
                }
            guard PeekabooBridgeOperationReceiptSemantics.allowsTargetlessFailureReceipt(for: response) else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .internalError,
                    message: "Bridge admission refusal did not produce canonical no-dispatch semantics")
            }
            return try await self.encodeAttestedResponse(
                response,
                targetState: .init(
                    target: nil,
                    focusedElement: nil,
                    failure: nil,
                    failureEvidence: nil),
                context: encodingContext)
        }

        let handled = await PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(
            claim.negotiatedCapabilities)
        {
            await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                await self.terminalResponse(for: request, peer: peer)
            }
        }
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
            try PeekabooBridgeOperationResultSemantics.validateSuccessfulTargetDisposition(
                request: request,
                handled: handled)
            if PeekabooBridgeOperationReceiptSemantics.allowsTargetlessFailureReceipt(for: handled.response) {
                response = handled.response
                target = nil
                focusedElement = nil
            } else if let browserReceipt = handled.externalBrowserTarget,
                      !PeekabooBridgeOperationResultSemantics.isNoDispatchFailure(handled.response)
            {
                guard browserReceipt.isCanonicalExternalTarget,
                      handled.response.browserExecutionConnectionReceipt == browserReceipt
                else {
                    throw DesktopTargetIdentityError.incompleteExactWindow
                }
                response = handled.response
                target = .browser(browserReceipt)
                focusedElement = nil
            } else {
                let resolved = try PeekabooBridgeOperationTargetAttribution.resolve(
                    request: request,
                    response: handled.response,
                    handledTarget: handled.targetIdentity ?? requestTarget)
                let receiptTarget = PeekabooBridgeResolvedOperationTarget(resolved)
                response = handled.response
                target = receiptTarget.target
                focusedElement = receiptTarget.focusedElement
            }
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
        return try await self.encodeAttestedResponse(
            response,
            targetState: .init(
                target: target,
                focusedElement: focusedElement,
                failure: targetFailure,
                failureEvidence: targetFailureEvidence),
            selectedLeafEvidence: targetFailure == nil ? handled.selectedLeafEvidence : nil,
            context: encodingContext)
    }

    static func operationReceiptClaimErrorCode(
        _ error: PeekabooBridgeOperationReceiptError) -> PeekabooBridgeErrorCode
    {
        switch error {
        case .replayedRequest, .listenerInstanceMismatch, .clientIdentityMismatch:
            .invalidRequest
        case .operationSessionRegistryExhausted, .archiveWriteFailed,
             .invalidOperationSessionConfiguration:
            .serverBusy
        default:
            .unauthorizedClient
        }
    }

    private func encodeAttestedResponse(
        _ response: PeekabooBridgeResponse,
        targetState: OperationReceiptTargetState,
        selectedLeafEvidence: [DesktopSelectedLeafEvidence]? = nil,
        context: OperationReceiptEncodingContext) async throws -> Data
    {
        let receiptPayload = try PeekabooBridgeOperationReceiptPayload(
            requestID: context.requestPayload.requestID,
            sessionID: context.requestPayload.sessionID,
            sessionSequence: context.requestPayload.sessionSequence,
            sessionAttestationSHA256: PeekabooBridgeOperationReceiptCoding.sha256(
                context.claim.sessionAttestation),
            listenerInstanceID: context.authority.attestation.listenerInstanceID,
            listenerPublicKeySHA256: PeekabooBridgeOperationReceiptCoding.sha256(
                context.authority.attestation.publicKey),
            host: context.authority.attestation.host,
            clientInstanceID: context.requestPayload.clientInstanceID,
            client: context.requestPayload.client,
            operation: context.request.operation,
            requestSHA256: PeekabooBridgeOperationReceiptCoding.sha256(context.request),
            responseSHA256: PeekabooBridgeOperationReceiptCoding.sha256(response),
            target: targetState.target,
            focusedElement: targetState.focusedElement,
            targetAttributionFailure: targetState.failure,
            targetAttributionEvidence: targetState.failureEvidence,
            selectedLeafEvidence: selectedLeafEvidence,
            outcome: PeekabooBridgeOperationReceiptSemantics.outcome(in: response),
            remainingClaimCount: context.claim.remainingClaimCount,
            startedAtUnixMilliseconds: context.startedAt,
            completedAtUnixMilliseconds: max(
                context.startedAt,
                PeekabooBridgeOperationReceiptCoding.unixMilliseconds()))
        try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
            receiptPayload,
            request: context.request,
            response: response)
        let receipt: PeekabooBridgeOperationReceipt
        do {
            receipt = try await context.authority.signAndArchive(receiptPayload, claim: context.claim)
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

    private static func validateOperationReceiptRequestCarriage(
        _ payload: PeekabooBridgeAttestedOperationRequest) throws -> OperationReceiptRequestCarriage
    {
        do {
            return try .valid(payload.validatedRequest())
        } catch {
            guard case .projectedAction = payload.request else { throw error }
            return .invalidProjected(error)
        }
    }

    private func encodeInvalidAttestedRequestCarriage(
        error: any Error,
        payload: PeekabooBridgeAttestedOperationRequest,
        authority: PeekabooBridgeOperationReceiptAuthority,
        claim: PeekabooBridgeOperationSessionClaim,
        startedAt: Int64) async throws -> Data
    {
        try await self.encodeAttestedResponse(
            Self.invalidAttestedRequestCarriageResponse(error: error),
            targetState: .init(
                target: nil,
                focusedElement: nil,
                failure: nil,
                failureEvidence: nil),
            context: .init(
                request: payload.request,
                requestPayload: payload,
                authority: authority,
                claim: claim,
                startedAt: startedAt))
    }

    private static func invalidAttestedRequestCarriageResponse(error: any Error) -> PeekabooBridgeResponse {
        let failure = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .invalidRequest,
            message: "Bridge operation request carriage is invalid.",
            hint: "Rebuild the request with exactly one projected action wrapper.",
            causeDescription: error.localizedDescription)
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .invalidRequest,
            actionFailure: failure,
            details: error.localizedDescription)
        return .projectedActionForCurrentRequestVocabulary(
            response: .error(envelope),
            outcome: failure.outcome.projection,
            usesCurrentVocabulary: true)
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
                    response: .projectedActionForCurrentRequestVocabulary(
                        response: handled.response,
                        outcome: handled.outcome?.routed(to: .bridge).projection),
                    mutation: handled.mutation,
                    targetIdentity: handled.targetIdentity,
                    selectedLeafEvidence: handled.selectedLeafEvidence)
            } catch let envelope as PeekabooBridgeErrorEnvelope {
                return Self.projectedFailure(envelope, for: payload.request)
            } catch let failure as DesktopActionFailure {
                return Self.projectedFailure(.init(
                    code: .internalError,
                    actionFailure: failure.routed(to: .bridge),
                    details: "\(failure)"), for: payload.request)
            } catch is CancellationError {
                return Self.projectedFailure(.init(
                    code: .timeout,
                    message: "Bridge request was cancelled"), for: payload.request)
            } catch {
                return Self.projectedFailure(.init(
                    code: .internalError,
                    message: error.localizedDescription,
                    details: "\(error)"), for: payload.request)
            }
        }
        do {
            return try await self.route(request, peer: peer)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            return .init(
                response: .error(envelope.legacyCompatible),
                selectedLeafEvidence: envelope.actionSelectedLeafEvidence)
        } catch let failure as DesktopActionFailure
            where PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics
        {
            let routed = failure.routed(to: .bridge)
            return .init(
                response: .error(.init(
                    code: .internalError,
                    actionFailure: routed,
                    details: "\(failure)")),
                selectedLeafEvidence: routed.selectedLeafEvidence)
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
        _ unprojectedEnvelope: PeekabooBridgeErrorEnvelope,
        for request: PeekabooBridgeRequest) -> PeekabooBridgeHandledResponse
    {
        let envelope = self.canonicalMutationFailureEnvelope(unprojectedEnvelope, for: request)
        return .init(
            response: .projectedActionForCurrentRequestVocabulary(
                response: .error(envelope),
                outcome: envelope.actionOutcome),
            selectedLeafEvidence: envelope.actionSelectedLeafEvidence)
    }

    private static func canonicalMutationFailureEnvelope(
        _ envelope: PeekabooBridgeErrorEnvelope,
        for request: PeekabooBridgeRequest) -> PeekabooBridgeErrorEnvelope
    {
        guard request.mayMutateDesktop, envelope.actionOutcome == nil else { return envelope }
        let failure = DesktopActionFailure.indeterminate(
            route: .bridge,
            evidence: .completionUnknown,
            message: envelope.message,
            hint: "Observe the intended target before retrying this operation.",
            causeDescription: envelope.details)
        return PeekabooBridgeErrorEnvelope(
            code: envelope.code,
            actionFailure: failure,
            details: envelope.details,
            permission: envelope.permission,
            kind: envelope.kind,
            context: envelope.context)
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
            return .projectedActionForCurrentRequestVocabulary(
                response: .error(envelope),
                outcome: actionFailure.outcome.projection,
                usesCurrentVocabulary: true)
        }
        return .error(envelope)
    }
}
