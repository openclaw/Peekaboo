import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

extension PeekabooBridgeClient {
    func send(
        _ request: PeekabooBridgeRequest,
        timeoutSec: TimeInterval? = nil) async throws -> PeekabooBridgeResponse
    {
        try await self.sendCarryingActionOutcome(request, timeoutSec: timeoutSec).response
    }

    func sendWithoutActionProjection(
        _ request: PeekabooBridgeRequest,
        timeoutSec: TimeInterval? = nil) async throws -> PeekabooBridgeResponse
    {
        try await self.sendCarryingActionOutcome(
            request,
            timeoutSec: timeoutSec,
            automaticallyProjectsActions: false).response
    }

    func sendCarryingActionOutcome(
        _ request: PeekabooBridgeRequest,
        timeoutSec: TimeInterval? = nil,
        automaticallyProjectsActions: Bool = true,
        operationReceiptRequirement: PeekabooBridgeOperationReceiptRequirement = .whenAvailable,
        throwsActionFailures: Bool = true) async throws
        -> PeekabooBridgeTransportReply
    {
        try self.requireNegotiatedInputCapabilities(for: request)
        let plan = PeekabooBridgeOperationResultSemantics.requestPlan(
            for: request,
            vocabulary: self.actionProjectionEnabled ? .current : .legacy)
        let mayMutateDesktop = plan.result.completion.mutatesDesktop
        let explicitlyProjected = if case .projectedAction = request {
            true
        } else {
            false
        }
        let expectsProjectedResponse = explicitlyProjected ||
            (automaticallyProjectsActions && self.actionProjectionEnabled && mayMutateDesktop)
        let projectedRequest = expectsProjectedResponse && !explicitlyProjected
            ? PeekabooBridgeRequest.projectedAction(.init(request: request))
            : request
        let op = request.operation
        let start = Date()
        self.logger.debug("Sending bridge request \(op.rawValue, privacy: .public)")

        let effectiveTimeoutSec = timeoutSec ?? self.requestTimeoutSec
        guard effectiveTimeoutSec.isFinite, effectiveTimeoutSec > 0 else {
            throw POSIXError(.EINVAL)
        }
        let deadline = Date().addingTimeInterval(effectiveTimeoutSec)
        var rolloverRetryCount = 0
        while true {
            let preparedRequest = try await self.prepareWireRequestForSend(
                projectedRequest,
                plan: plan,
                operation: op,
                deadline: deadline,
                operationReceiptRequirement: operationReceiptRequirement)
            try self.checkCancellationBeforeTransport(
                plan: plan,
                preparedRequest: preparedRequest)
            let verified = try await self.exchange(
                preparedRequest,
                plan: plan,
                deadline: deadline)
            switch verified {
            case let .terminal(verifiedWireResponse, bundle, connectedHost):
                let verifiedTargetIdentity = try bundle?.receipt.payload.resolvedTargetIdentity()
                if let bundle, let context = preparedRequest.context {
                    self.recordOperationReceiptBundle(bundle, reservation: context.reservation)
                    do {
                        try Self.exportOperationReceiptIfRequested(
                            bundle,
                            directory: self.operationReceiptExportDirectory)
                        if self.operationReceiptExportDirectory != nil {
                            self.latestOperationReceiptExportFailure = nil
                        }
                    } catch {
                        let directoryPath = self.operationReceiptExportDirectory?.standardizedFileURL.path ?? "<none>"
                        self.latestOperationReceiptExportFailure = .init(
                            requestID: context.requestID,
                            directoryPath: directoryPath,
                            message: error.localizedDescription)
                        self.logger.error(
                            """
                            Bridge operation receipt export failed \
                            request_id=\(context.requestID.uuidString.lowercased(), privacy: .public) \
                            error=\(error.localizedDescription, privacy: .private)
                            """)
                    }
                }
                let unwrappedReply = try Self.unwrapResponse(
                    verifiedWireResponse,
                    expectsProjectedResponse: expectsProjectedResponse,
                    hasVerifiedOperationReceipt: bundle != nil,
                    plan: plan)
                let reply = PeekabooBridgeTransportReply(
                    response: unwrappedReply.response,
                    outcome: unwrappedReply.outcome,
                    targetIdentity: verifiedTargetIdentity,
                    selectedLeafEvidence: bundle?.receipt.payload.selectedLeafEvidence,
                    connectedHost: connectedHost,
                    hasVerifiedOperationReceipt: bundle != nil,
                    operationReceiptBundle: bundle)
                let response = reply.response
                if case let .error(envelope) = response,
                   mayMutateDesktop,
                   throwsActionFailures
                {
                    if let failure = envelope.desktopActionFailure {
                        throw failure.attributed(to: verifiedTargetIdentity?.actionTargetReceipt)
                    }
                    if envelope.operationMayHaveCompleted {
                        throw Self.legacyCompletionUnknownFailure(envelope: envelope)
                    }
                }
                let duration = Date().timeIntervalSince(start)
                self.logger.debug(
                    "bridge \(op.rawValue, privacy: .public) completed in \(duration, format: .fixed(precision: 3))s")
                return reply
            case let .rollover(refusal):
                guard let context = preparedRequest.context else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "an operation session rollover without an attested request")
                }
                guard refusal.payload.disposition == .sessionRolloverRequired,
                      let successor = refusal.payload.successorSessionAttestation
                else {
                    self.invalidateOperationSession(for: context)
                    try Self.throwVerifiedRolloverUnavailable(
                        operation: op,
                        mutating: mayMutateDesktop)
                }
                do {
                    try self.installOperationSession(
                        successor,
                        listenerAttestation: context.reservation.listenerAttestation,
                        replacingSessionID: context.reservation.sessionAttestation.sessionID,
                        expectedEpoch: context.reservation.epoch)
                } catch {
                    try Self.throwVerifiedRolloverInstallationFailure(
                        operation: op,
                        mutating: mayMutateDesktop,
                        cause: error)
                }
                guard rolloverRetryCount == 0 else {
                    try Self.throwRepeatedRolloverRefusal(operation: op, mutating: mayMutateDesktop)
                }
                rolloverRetryCount += 1
                try Self.checkCancellationBeforeRolloverRetry(
                    operation: op,
                    mutating: mayMutateDesktop)
            }
        }
    }

    private func prepareWireRequestForSend(
        _ projectedRequest: PeekabooBridgeRequest,
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        operation: PeekabooBridgeOperation,
        deadline: Date,
        operationReceiptRequirement: PeekabooBridgeOperationReceiptRequirement) async throws
        -> PeekabooBridgePreparedRequest
    {
        let originalRequest = plan.request
        try self.requireNegotiatedInputCapabilities(for: originalRequest)
        let preparedRequest: PeekabooBridgePreparedRequest
        do {
            preparedRequest = try await self.prepareWireRequest(projectedRequest, deadline: deadline)
            guard operationReceiptRequirement != .required || preparedRequest.context != nil else {
                throw PeekabooBridgeClientOperationSessionError.handshakeRequired
            }
        } catch let cancellation as CancellationError {
            guard plan.result.completion.mutatesDesktop,
                  !self.usesExplicitReceiptlessTransport()
            else { throw cancellation }
            throw Self.preTransportRequestCancelledFailure(operation: operation)
        } catch {
            guard plan.result.completion.mutatesDesktop else { throw error }
            throw Self.preTransportSessionUnavailableFailure(operation: operation, cause: error)
        }
        try self.requireNegotiatedInputCapabilities(for: originalRequest)
        return preparedRequest
    }

    private func requireNegotiatedInputCapabilities(for request: PeekabooBridgeRequest) throws {
        if request.requiresBrowserConnectionHandoff, !self.browserConnectionHandoffEnabled {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge protocol 1.38 authenticated browser handoff is unavailable")
        }
        if request.createsOrPublishesSnapshotState || request.requiresProducerBoundSnapshotReferences,
           !self.producerBoundSnapshotReferencesEnabled
        {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge protocol 1.34 producer-bound snapshot ownership is unavailable")
        }
        if request.requiresTargetedClickAccessibilityValueDelivery,
           !self.targetedClickAccessibilityValueDeliveryEnabled
        {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "This Bridge host cannot honor an explicit accessibility-value click policy.",
                hint: "Update and relaunch Peekaboo before retrying the snapshot-backed click.")
        }
        if case let .targetedScroll(payload) = request.unwrappedOperationRequest {
            guard payload.request.expectedWindow != nil else {
                throw DesktopActionFailure.preDispatchRefusal(
                    route: .bridge,
                    reason: .targetUnavailable,
                    message: "Background scroll has no complete capture-owned exact-window receipt.",
                    hint: "Capture the exact window again and retry with its fresh snapshot.")
            }
            guard self.requestPinnedExactWindowScrollReceiptEnabled else {
                throw DesktopActionFailure.preDispatchRefusal(
                    route: .bridge,
                    reason: .runtimeIncompatible,
                    message: "This Bridge host cannot preserve an exact-window scroll receipt.",
                    hint: "Update and relaunch Peekaboo before retrying background scroll.")
            }
        }
        if request.requiresCompositeTypeDeliverySupport,
           !self.compositeTypeDeliveryEnabled
        {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "This Bridge host cannot return truthful composite background typing receipts.",
                hint: "Update and relaunch Peekaboo before retrying background typing.")
        }
        if request.unwrappedOperationRequest.operation == .foregroundModifierClick,
           !self.foregroundModifierClickSnapshotLeaseEnabled
        {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "This Bridge host cannot lease modifier-click snapshots at the execution leaf.",
                hint: "Update and relaunch Peekaboo before retrying modifier-click.")
        }
        if request.unwrappedOperationRequest.operation == .setValue,
           !self.setValueResultTargetBindingEnabled
        {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "This Bridge host cannot return a verifiable set-value result.",
                hint: "Update and relaunch Peekaboo before retrying set-value.")
        }
        if [.setValue, .performAction].contains(request.unwrappedOperationRequest.operation),
           !self.processGenerationBoundElementMutationsEnabled
        {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "This Bridge host cannot bind element mutations to one process generation.",
                hint: "Update and relaunch Peekaboo before retrying action or set-value.")
        }
        if request.unwrappedOperationRequest.operation == .observeProcessGeneration,
           !self.processGenerationObservationEnabled
        {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge protocol 1.32 signed process-generation observation is unavailable",
                details: "The host must advertise and enable observeProcessGeneration before use.")
        }
        if request.unwrappedOperationRequest.operation == .certificationProducerAttestation,
           !self.certificationProducerAttestationEnabled
        {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge protocol 1.32 certification producer attestation is unavailable",
                details: "The host must advertise and enable certificationProducerAttestation before use.")
        }
        if request.unwrappedOperationRequest.operation == .agentExecutionTrace,
           !self.agentExecutionTraceEnabled
        {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge protocol 1.31 signed Agent execution is unavailable",
                details: "The host must advertise and enable agentExecutionTrace before launch.")
        }
        if request.requiresStatelessClickVariantSupport, !self.statelessClickVariantPayloadsEnabled {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "Bridge protocol 1.30 middle/triple-click payload support is unavailable.",
                hint: "Update or relaunch the Peekaboo Bridge host before retrying.")
        }
        if request.requiresBackgroundStatelessClickVariantSupport,
           !self.statelessClickVariantsEnabled
        {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "Bridge protocol 1.30 background middle/triple-click support is unavailable.",
                hint: "Use explicit foreground delivery or update and relaunch the Peekaboo Bridge host.")
        }
        if request.requiresExactWindowHeldPointerBeginSupport,
           !self.exactWindowHeldPointerLifecycleEnabled
        {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "Bridge protocol 1.30 exact-window held-pointer support is unavailable.",
                hint: "Update or relaunch the Peekaboo Bridge host before retrying.")
        }
        if request.requiresExactWindowHeldPointerTerminalSupport,
           !self.exactWindowHeldPointerTerminalCleanupEnabled
        {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "Bridge protocol 1.30 exact-window held-pointer cleanup is unavailable.",
                hint: "Reconnect to the Bridge host that owns the active hold before retrying.")
        }
    }

    private func checkCancellationBeforeTransport(
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        preparedRequest: PeekabooBridgePreparedRequest) throws
    {
        do {
            try Task.checkCancellation()
        } catch let cancellation as CancellationError {
            self.invalidateOperationSession(for: preparedRequest.context)
            guard plan.result.completion.mutatesDesktop,
                  preparedRequest.context != nil
            else { throw cancellation }
            throw Self.preTransportRequestCancelledFailure(operation: plan.operation)
        }
    }

    private func exchange(
        _ preparedRequest: PeekabooBridgePreparedRequest,
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        deadline: Date) async throws -> PeekabooBridgeVerifiedResponse
    {
        let originalRequest = plan.request
        let attestedContext = preparedRequest.context
        let payload: Data
        do {
            payload = try self.encoder.encode(preparedRequest.request)
        } catch {
            self.invalidateOperationSession(for: attestedContext)
            throw error
        }
        let op = originalRequest.operation
        let socketPath = self.socketPath
        let maxResponseBytes = self.maxResponseBytes
        let hostAuthentication = self.hostAuthentication
        let requestTimeoutSec: TimeInterval
        do {
            requestTimeoutSec = try self.remainingTransportTimeout(deadline: deadline)
        } catch {
            self.invalidateOperationSession(for: attestedContext)
            throw error
        }
        let cancellation = PeekabooBridgeClientConnectionCancellation()
        let blockingResponse: PeekabooBridgeBlockingResponse
        do {
            let authenticatesInitialListener = if case .handshake = preparedRequest.request {
                self.trustedHostTeamIDs != nil
            } else {
                false
            }
            let expectedHost: PeekabooBridgeExpectedHost? = if let context = attestedContext {
                .attested(.init(
                    attestation: context.reservation.listenerAttestation,
                    liveIdentity: context.reservation.listenerLiveIdentity))
            } else if let reservation = preparedRequest.receiptlessHostReservation {
                .authenticated(reservation.host)
            } else {
                nil
            }
            blockingResponse = try await withTaskCancellationHandler {
                try await PeekabooBridgeBlockingIO.run {
                    try Self.sendBlocking(
                        .init(
                            socketPath: socketPath,
                            requestData: payload,
                            maxResponseBytes: maxResponseBytes,
                            timeoutSec: requestTimeoutSec,
                            expectedHost: expectedHost,
                            authenticatesInitialListener: authenticatesInitialListener,
                            hostAuthentication: hostAuthentication),
                        cancellation: cancellation)
                }
            } onCancel: {
                cancellation.cancel()
            }
        } catch let failure as PeekabooBridgePostDispatchFailure {
            self.invalidateOperationSession(for: attestedContext)
            self.invalidateReceiptlessAuthenticatedHost(
                reservation: preparedRequest.receiptlessHostReservation)
            guard plan.result.completion.mutatesDesktop else {
                throw failure.underlying
            }
            throw Self.responseLostFailure(
                operation: op,
                causeDescription: "\(failure.underlying)",
                requestID: attestedContext?.requestID)
        } catch {
            self.recordOperationSessionTransportFailure(error, for: attestedContext)
            self.invalidateReceiptlessAuthenticatedHost(
                reservation: preparedRequest.receiptlessHostReservation)
            if error is CancellationError,
               plan.result.completion.mutatesDesktop,
               attestedContext != nil
            {
                throw Self.preTransportRequestCancelledFailure(operation: op)
            }
            if plan.result.completion.mutatesDesktop,
               attestedContext != nil || preparedRequest.receiptlessHostReservation != nil
            {
                throw Self.preTransportSessionUnavailableFailure(operation: op, cause: error)
            }
            throw error
        }
        let responseData = blockingResponse.data
        guard !responseData.isEmpty else {
            let details = """
            EOF while reading response for \(op.rawValue).

            This usually means the host closed the socket before replying \
            (often due to an authorization/TeamID check). \
            Update Peekaboo.app / ClawdBot.app to a host build that returns a structured \
            `unauthorizedClient` response, or launch the host with \
            PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS=1 for local development.
            """

            self.invalidateOperationSession(for: attestedContext)
            self.invalidateReceiptlessAuthenticatedHost(
                reservation: preparedRequest.receiptlessHostReservation)
            guard plan.result.completion.mutatesDesktop else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .internalError,
                    message: "Bridge host returned no response",
                    details: details)
            }
            throw Self.responseLostFailure(
                operation: op,
                causeDescription: details,
                requestID: attestedContext?.requestID)
        }

        let wireResponse: PeekabooBridgeResponse
        do {
            wireResponse = try self.decoder.decode(PeekabooBridgeResponse.self, from: responseData)
        } catch {
            self.invalidateOperationSession(for: attestedContext)
            self.invalidateReceiptlessAuthenticatedHost(
                reservation: preparedRequest.receiptlessHostReservation)
            guard plan.result.completion.mutatesDesktop else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .decodingFailed,
                    message: "Bridge host returned an invalid response",
                    details: "\(error)")
            }
            throw Self.responseLostFailure(
                operation: op,
                causeDescription: "Bridge response decoding failed: \(error)",
                requestID: attestedContext?.requestID)
        }
        do {
            return try Self.verifyAttestedResponse(
                wireResponse,
                context: attestedContext,
                connectedHost: blockingResponse.connectedHost)
        } catch {
            let carriesAttestedResponse = switch wireResponse {
            case .attestedOperation, .operationSessionRollover:
                true
            default:
                false
            }
            if !carriesAttestedResponse {
                self.requireColdHandshakeRetainingOperationSession(for: attestedContext)
            } else {
                self.invalidateOperationSession(for: attestedContext)
            }
            self.invalidateReceiptlessAuthenticatedHost(
                reservation: preparedRequest.receiptlessHostReservation)
            guard plan.result.completion.mutatesDesktop else { throw error }
            throw Self.responseLostFailure(
                operation: op,
                causeDescription: "Bridge operation receipt validation failed: \(error.localizedDescription)",
                requestID: attestedContext?.requestID)
        }
    }

    private func prepareWireRequest(
        _ request: PeekabooBridgeRequest,
        deadline: Date) async throws -> PeekabooBridgePreparedRequest
    {
        if case .handshake = request {
            return .init(request: request, context: nil, receiptlessHostReservation: nil)
        }
        try Task.checkCancellation()
        var reservation: PeekabooBridgeClientOperationSessionReservation?
        while true {
            do {
                reservation = try self.reserveOperationSession()
                break
            } catch let error as PeekabooBridgeClientOperationSessionError {
                guard case let .renewalRequired(sessionID, _) = error else { throw error }
                _ = try await self.renewOperationSession(
                    replacingSessionID: sessionID,
                    overallTimeoutSec: self.remainingTransportTimeout(deadline: deadline))
                try Task.checkCancellation()
            }
        }
        guard let reservation else {
            return .init(
                request: request,
                context: nil,
                receiptlessHostReservation: self.receiptlessAuthenticatedHostReservation())
        }
        let attestedRequest = PeekabooBridgeAttestedOperationRequest(
            requestID: reservation.requestID,
            sessionID: reservation.sessionAttestation.sessionID,
            sessionSequence: reservation.sequence,
            expectedListenerInstanceID: reservation.listenerAttestation.listenerInstanceID,
            clientInstanceID: self.operationClientInstanceID,
            client: reservation.clientIdentity,
            request: request)
        let context = PeekabooBridgeAttestedRequestContext(
            reservation: reservation,
            attestedRequest: attestedRequest,
            request: request)
        return .init(
            request: .attestedOperation(attestedRequest),
            context: context,
            receiptlessHostReservation: nil)
    }

    private func invalidateOperationSession(for context: PeekabooBridgeAttestedRequestContext?) {
        guard let reservation = context?.reservation else { return }
        self.invalidateOperationSession(
            sessionID: reservation.sessionAttestation.sessionID,
            epoch: reservation.epoch)
    }

    private func recordOperationSessionTransportFailure(
        _ error: any Error,
        for context: PeekabooBridgeAttestedRequestContext?)
    {
        guard let reservation = context?.reservation else { return }
        self.recordOperationSessionTransportFailure(
            error,
            sessionID: reservation.sessionAttestation.sessionID,
            epoch: reservation.epoch)
    }

    /// An unsigned response cannot authorize retrying the current request, but it can prove that the cached signed
    /// session is unusable. Disable it while preserving its identity for a later explicit replacement handshake.
    private func requireColdHandshakeRetainingOperationSession(
        for context: PeekabooBridgeAttestedRequestContext?)
    {
        guard let reservation = context?.reservation else { return }
        self.requireColdHandshakeRetainingOperationSession(
            sessionID: reservation.sessionAttestation.sessionID,
            epoch: reservation.epoch)
    }

    private func remainingTransportTimeout(deadline: Date) throws -> TimeInterval {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw POSIXError(.ETIMEDOUT) }
        return remaining
    }

    private nonisolated static func unwrapResponse(
        _ response: PeekabooBridgeResponse,
        expectsProjectedResponse: Bool,
        hasVerifiedOperationReceipt: Bool,
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan) throws
        -> PeekabooBridgeTransportReply
    {
        let request = plan.request
        let needsStandaloneReceiptlessFamilyValidation = if case let .projectedAction(projected) = response {
            projected.outcome == nil
        } else {
            true
        }
        if plan.result.completion.mutatesDesktop,
           !hasVerifiedOperationReceipt,
           needsStandaloneReceiptlessFamilyValidation
        {
            let semanticResponse = if case let .projectedAction(projected) = response {
                projected.response
            } else {
                response
            }
            guard PeekabooBridgeOperationResultSemantics.responseMatchesContract(
                semanticResponse,
                plan: plan)
            else {
                throw Self.responseLostFailure(
                    operation: request.operation,
                    causeDescription: "Receiptless Bridge response family did not match the requested operation")
            }
        }
        if expectsProjectedResponse {
            guard case let .projectedAction(payload) = response else {
                throw self.responseLostFailure(
                    operation: request.operation,
                    causeDescription: "A projection-capable Bridge host returned an unwrapped action response")
            }
            if case .projectedAction = payload.response {
                throw Self.responseLostFailure(
                    operation: request.operation,
                    causeDescription: "A projection-capable Bridge host returned nested action carriage")
            }
            if case let .error(envelope) = payload.response,
               payload.outcome != envelope.actionOutcome
            {
                throw Self.responseLostFailure(
                    operation: request.operation,
                    causeDescription: "Bridge action response and error envelope carried contradictory outcomes")
            }
            if payload.outcome != nil, !hasVerifiedOperationReceipt {
                try Self.validateReceiptlessProjectedResponse(payload, plan: plan)
            }
            return PeekabooBridgeTransportReply(
                response: payload.response,
                outcome: payload.outcome)
        }

        guard case .projectedAction = response else {
            return PeekabooBridgeTransportReply(response: response, outcome: nil)
        }
        if plan.result.completion.mutatesDesktop {
            throw self.responseLostFailure(
                operation: request.operation,
                causeDescription: "Bridge host returned unrequested action projection carriage")
        }
        throw PeekabooBridgeErrorEnvelope(
            code: .decodingFailed,
            message: "Bridge host returned an unexpected projected response")
    }

    private nonisolated static func validateReceiptlessProjectedResponse(
        _ projected: PeekabooBridgeProjectedActionResponse,
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan) throws
    {
        let request = plan.request
        guard let projection = projected.outcome else { return }
        let outcome = projection.outcome
        guard PeekabooBridgeOperationResultSemantics.responseMatchesContract(
            projected.response,
            plan: plan)
        else {
            try Self.throwReceiptlessProjectionMismatch(
                request: request,
                detail: "response family did not match the requested operation")
        }

        let outcomeMatches: Bool = switch projected.response {
        case let .error(envelope):
            projection == envelope.actionOutcome &&
                PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
                    outcome,
                    plan: plan)
        case let .browserToolResponse(browserResponse):
            Self.receiptlessBrowserProjectionMatches(
                browserResponse,
                projection: projection,
                plan: plan)
        default:
            PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                outcome,
                response: projected.response,
                plan: plan) ||
                PeekabooBridgeOperationResultSemantics.nonErrorResponseAllowsFailureOutcome(
                    projected.response,
                    outcome: outcome,
                    plan: plan)
        }
        guard outcomeMatches else {
            try Self.throwReceiptlessProjectionMismatch(
                request: request,
                detail: "action state, route, delivery, or dispatch count contradicted the request")
        }

        let wrappedResponse = PeekabooBridgeResponse.projectedAction(projected)
        guard outcome.state != .refused,
              !PeekabooBridgeOperationResultSemantics.isNoDispatchFailure(wrappedResponse)
        else { return }
        do {
            try Self.validateReceiptlessProjectedTarget(
                plan: plan,
                response: wrappedResponse)
        } catch {
            try Self.throwReceiptlessProjectionMismatch(
                request: request,
                detail: "target attribution contradicted the request: \(error.localizedDescription)")
        }
    }

    private nonisolated static func validateReceiptlessProjectedTarget(
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        response: PeekabooBridgeResponse) throws
    {
        let request = plan.request
        switch request {
        case let .activateApplication(payload) where payload.expectedIdentity == nil:
            return
        case let .hideApplication(payload) where payload.expectedIdentity == nil:
            return
        default:
            break
        }
        let policy = plan.target.policy
        if policy == .external,
           request.operation == .browserExecute
        {
            guard let expected = request.browserExecutionRequest?.expectedConnectionReceipt,
                  expected.isCanonicalTarget,
                  let actual = response.browserExecutionConnectionReceipt,
                  actual.isCanonicalTarget,
                  actual == expected,
                  request.browserExecutionRequest?.channel.map({ $0 == actual.channel }) ?? true
            else {
                throw DesktopTargetIdentityError.incompleteExactWindow
            }
            return
        }
        if policy == .external,
           request.operation == .browserConnect
        {
            guard let connectRequest = request.browserConnectRequest,
                  let actual = response.browserExecutionConnectionReceipt,
                  actual.matchesConnectRequest(connectRequest)
            else {
                throw DesktopTargetIdentityError.incompleteExactWindow
            }
            return
        }

        let resolved = try PeekabooBridgeOperationTargetAttribution.resolve(
            plan: plan,
            response: response,
            handledTarget: nil)
        switch policy {
        case .global:
            guard resolved == nil else { throw DesktopTargetIdentityError.incompleteExactWindow }
        case .requestPinned:
            let requested = try PeekabooBridgeOperationTargetAttribution.resolveRequest(plan)
            guard requested != nil, resolved == requested else {
                throw DesktopTargetIdentityError.incompleteExactWindow
            }
        case .handlerRequired, .responseResolved, .external:
            guard resolved != nil else { throw DesktopTargetIdentityError.incompleteExactWindow }
        case .handlerResolvedOrGlobal:
            break
        case .notApplicable, .requestDependent:
            throw DesktopTargetIdentityError.incompleteExactWindow
        }
    }

    private nonisolated static func receiptlessBrowserProjectionMatches(
        _ response: PeekabooBridgeBrowserToolResponse,
        projection: DesktopActionOutcome.Projection,
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan) -> Bool
    {
        let request = plan.request
        guard let browserRequest = request.browserExecutionRequest,
              response.isError == (response.actionFailure != nil)
        else { return false }
        let callCount = browserRequest.mutationCallCount
        guard let completed = response.completedCallCount,
              let dispatched = response.dispatchedCallCount
        else {
            guard response.completedCallCount == nil,
                  response.dispatchedCallCount == nil,
                  let failure = response.actionFailure,
                  failure.outcome.projection == projection,
                  projection.outcome.state == .indeterminate,
                  projection.outcome.delivery == .init(
                      mechanism: .browserProtocol,
                      mode: .background),
                  projection.outcome.evidence == .completionUnknown,
                  projection.outcome.dispatchState.unitCount == nil
            else { return false }
            return PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
                failure.outcome,
                plan: plan)
        }
        guard completed >= 0,
              dispatched >= completed,
              dispatched <= callCount
        else { return false }
        if dispatched == 0 {
            guard completed == 0,
                  let failure = response.actionFailure,
                  failure.outcome.projection == projection,
                  projection.outcome.state == .refused
            else { return false }
            return PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
                failure.outcome,
                plan: plan)
        }
        guard let units = DesktopActionOutcome.DispatchUnitCount(dispatched),
              projection.outcome.dispatchState.unitCount == units
        else { return false }
        if let failure = response.actionFailure {
            return failure.outcome.projection == projection &&
                PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
                    failure.outcome,
                    plan: plan)
        }
        return completed == callCount &&
            dispatched == callCount &&
            PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                projection.outcome,
                response: .browserToolResponse(response),
                plan: plan)
    }

    private nonisolated static func throwReceiptlessProjectionMismatch(
        request: PeekabooBridgeRequest,
        detail: String) throws -> Never
    {
        throw self.responseLostFailure(
            operation: request.operation,
            causeDescription: "Receiptless Bridge action projection validation failed: \(detail)")
    }

    func sendExpectOK(
        _ request: PeekabooBridgeRequest,
        timeoutSec: TimeInterval? = nil) async throws
    {
        let response = try await self.send(request, timeoutSec: timeoutSec)
        switch response {
        case .ok:
            return
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected response for void request")
        }
    }

    func sendExpectOKCarryingActionOutcome(
        _ request: PeekabooBridgeRequest,
        timeoutSec: TimeInterval? = nil) async throws -> DesktopActionOutcome?
    {
        let reply = try await self.sendCarryingActionOutcome(request, timeoutSec: timeoutSec)
        switch reply.response {
        case .ok:
            return reply.outcome?.outcome
        case let .error(envelope):
            try Self.throwActionFailureOrEnvelope(envelope)
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected response for void request")
        }
    }

    nonisolated static func throwActionFailureOrEnvelope(
        _ envelope: PeekabooBridgeErrorEnvelope) throws -> Never
    {
        if let failure = envelope.desktopActionFailure {
            throw failure
        }
        throw envelope
    }

    private nonisolated static func disableSigPipe(fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
    }

    private nonisolated static func sendBlocking(
        _ request: PeekabooBridgeBlockingRequest,
        cancellation: PeekabooBridgeClientConnectionCancellation) throws -> PeekabooBridgeBlockingResponse
    {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try cancellation.install(fd: fd)
        defer {
            cancellation.clear(fd: fd)
            close(fd)
        }

        do {
            Self.disableSigPipe(fd: fd)
            try PeekabooBridgeSocketIO.configureConnectedSocket(fd)
            let deadline = Date().addingTimeInterval(request.timeoutSec)

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: addr.sun_path)
            let copied = request.socketPath.withCString { cstr -> Int in
                strlcpy(&addr.sun_path.0, cstr, capacity)
            }
            guard copied < capacity else { throw POSIXError(.ENAMETOOLONG) }
            addr.sun_len = UInt8(MemoryLayout.size(ofValue: addr))

            let len = socklen_t(MemoryLayout.size(ofValue: addr))
            let connectResult = withUnsafePointer(to: &addr) { ptr in
                connect(fd, UnsafePointer<sockaddr>(OpaquePointer(ptr)), len)
            }
            if connectResult != 0 {
                guard errno == EINPROGRESS || errno == EAGAIN || errno == EALREADY else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
                }
                try PeekabooBridgeSocketIO.finishConnect(fd: fd, deadline: deadline)
            }

            let connectedHost: PeekabooBridgeConnectedHostIdentity?
            if request.expectedHost != nil || request.authenticatesInitialListener {
                let liveIdentity = try request.hostAuthentication.liveIdentity(fd)
                let signingIdentity: PeekabooBridgeHost.PeerSigningIdentity? = if
                    request.authenticatesInitialListener || request.expectedHost?.requiresSigningIdentity == true,
                    let auditIdentity = liveIdentity.auditIdentity
                {
                    request.hostAuthentication.signingIdentity(auditIdentity)
                } else {
                    nil
                }
                connectedHost = .init(
                    liveIdentity: liveIdentity,
                    signingIdentity: signingIdentity)
            } else {
                connectedHost = nil
            }
            if case let .attested(expectedListener) = request.expectedHost {
                try expectedListener.attestation.validateSignature()
                guard connectedHost?.liveIdentity == expectedListener.liveIdentity,
                      expectedListener.liveIdentity.processIdentifier ==
                      expectedListener.attestation.host.processIdentifier,
                      expectedListener.liveIdentity.processStartIdentity ==
                      expectedListener.attestation.host.processStartIdentity,
                      expectedListener.liveIdentity.codeSignatureHash ==
                      expectedListener.attestation.host.codeSignatureHash
                else {
                    throw PeekabooBridgeOperationReceiptError.peerIdentityMismatch
                }
            } else if case let .authenticated(expectedHost) = request.expectedHost,
                      connectedHost != expectedHost
            {
                throw PeekabooBridgeOperationReceiptError.peerIdentityMismatch
            }

            try cancellation.check()
            // The host drains through EOF before it decodes a request. A failed `writeAll` therefore proves the host
            // received only an incomplete JSON document and could not dispatch it. Only a fully written request may
            // enter the response-loss phase: closing this socket after that point can deliver the final EOF that lets
            // the host decode and begin work even when shutdown or response reading fails locally.
            try PeekabooBridgeSocketIO.writeAll(fd: fd, data: request.requestData, deadline: deadline)
            do {
                guard shutdown(fd, SHUT_WR) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let response = try PeekabooBridgeSocketIO.readAll(
                    fd: fd,
                    maxBytes: request.maxResponseBytes,
                    deadline: deadline)
                try cancellation.check()
                return PeekabooBridgeBlockingResponse(data: response, connectedHost: connectedHost)
            } catch {
                let responseFailure: any Error
                do {
                    try cancellation.check()
                    responseFailure = error
                } catch let cancellationError {
                    responseFailure = cancellationError
                }
                throw PeekabooBridgePostDispatchFailure(underlying: responseFailure)
            }
        } catch let responseFailure as PeekabooBridgePostDispatchFailure {
            throw responseFailure
        } catch {
            try cancellation.check()
            throw error
        }
    }

    private nonisolated static func responseLostFailure(
        operation: PeekabooBridgeOperation,
        causeDescription: String,
        requestID: UUID? = nil) -> DesktopActionFailure
    {
        let requestSuffix = requestID.map { "; request_id=\($0.uuidString.lowercased())" } ?? ""
        let message = "Bridge response was lost after \(operation.rawValue) was dispatched; " +
            "outcome is indeterminate; do not retry\(requestSuffix)"
        return DesktopActionFailure.indeterminate(
            route: .bridge,
            evidence: .responseLost,
            message: message,
            hint: "Observe the target before retrying this operation.",
            causeDescription: causeDescription)
    }

    private nonisolated static func verifyAttestedResponse(
        _ response: PeekabooBridgeResponse,
        context: PeekabooBridgeAttestedRequestContext?,
        connectedHost: PeekabooBridgeConnectedHostIdentity?) throws
        -> PeekabooBridgeVerifiedResponse
    {
        guard let context else {
            switch response {
            case .attestedOperation, .operationSessionRollover:
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "an unrequested receipt or operation session rollover envelope")
            default:
                return .terminal(response, bundle: nil, connectedHost: connectedHost)
            }
        }
        if case let .operationSessionRollover(refusal) = response {
            try refusal.validate(
                listenerAttestation: context.reservation.listenerAttestation,
                predecessorSession: context.reservation.sessionAttestation,
                request: context.attestedRequest)
            return .rollover(refusal)
        }
        guard case let .attestedOperation(envelope) = response else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("the required receipt envelope")
        }
        guard case .attestedOperation = envelope.response else {
            let receipt = envelope.receipt
            let reservation = context.reservation
            let listenerAttestation = reservation.listenerAttestation
            let sessionAttestation = reservation.sessionAttestation
            try sessionAttestation.validateSignature(listenerAttestation: listenerAttestation)
            try receipt.validateSignature(publicKey: listenerAttestation.publicKey)
            let payload = receipt.payload
            guard payload.schemaVersion == 1 else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("schema_version")
            }
            guard payload.requestID == reservation.requestID,
                  payload.requestID == PeekabooBridgeOperationReceiptCoding.deterministicRequestID(
                      sessionID: reservation.sessionAttestation.sessionID,
                      sequence: reservation.sequence),
                  payload.sessionID == sessionAttestation.sessionID,
                  payload.sessionSequence == reservation.sequence,
                  try payload.sessionAttestationSHA256 == PeekabooBridgeOperationReceiptCoding.sha256(
                      sessionAttestation),
                  payload.clientInstanceID == sessionAttestation.clientInstanceID
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("operation session facts")
            }
            guard payload.listenerInstanceID == listenerAttestation.listenerInstanceID,
                  payload.listenerPublicKeySHA256 == PeekabooBridgeOperationReceiptCoding.sha256(
                      listenerAttestation.publicKey),
                  payload.host == listenerAttestation.host
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("listener identity")
            }
            guard payload.client == reservation.clientIdentity,
                  payload.client == sessionAttestation.client
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("client identity")
            }
            guard payload.operation == context.request.operation,
                  try payload.requestSHA256 == (PeekabooBridgeOperationReceiptCoding.sha256(context.request)),
                  try payload.responseSHA256 == (PeekabooBridgeOperationReceiptCoding.sha256(envelope.response)),
                  payload.outcome == PeekabooBridgeOperationReceiptSemantics.outcome(in: envelope.response),
                  payload.remainingClaimCount >= 0,
                  payload.remainingClaimCount < sessionAttestation.maximumRequestCount,
                  payload.completedAtUnixMilliseconds >= payload.startedAtUnixMilliseconds
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("operation facts")
            }
            try PeekabooBridgeOperationReceiptSemantics.validateTargetAttribution(
                payload,
                request: context.request,
                response: envelope.response)
            let bundle = try PeekabooBridgeOperationReceiptBundle(
                operationAttestation: listenerAttestation,
                operationSessionAttestation: sessionAttestation,
                receipt: receipt,
                canonicalListenerAttestationPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(
                    listenerAttestation.unsignedPayload),
                canonicalSessionAttestationPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(
                    sessionAttestation.unsignedPayload),
                canonicalReceiptPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(receipt.payload),
                canonicalRequest: PeekabooBridgeOperationReceiptCoding.canonicalData(context.request),
                canonicalResponse: PeekabooBridgeOperationReceiptCoding.canonicalData(envelope.response))
            try bundle.validate()
            return .terminal(envelope.response, bundle: bundle, connectedHost: connectedHost)
        }
        throw PeekabooBridgeOperationReceiptError.receiptMismatch("a nested receipt envelope")
    }

    private nonisolated static func throwRepeatedRolloverRefusal(
        operation: PeekabooBridgeOperation,
        mutating: Bool) throws -> Never
    {
        let message = "Bridge operation session rolled over twice before \(operation.rawValue) could be dispatched"
        if mutating {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .transportSessionUnavailable,
                message: message,
                hint: "Establish a fresh Bridge handshake before retrying.")
        }
        throw PeekabooBridgeErrorEnvelope(
            code: .serverBusy,
            message: message,
            operationMayHaveCompleted: false)
    }

    private nonisolated static func preTransportSessionUnavailableFailure(
        operation: PeekabooBridgeOperation,
        cause: any Error) -> DesktopActionFailure
    {
        DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .transportSessionUnavailable,
            message: "Bridge could not establish an operation session before \(operation.rawValue) dispatch.",
            hint: "Establish a fresh Bridge handshake before retrying.",
            causeDescription: cause.localizedDescription)
    }

    private nonisolated static func preTransportRequestCancelledFailure(
        operation: PeekabooBridgeOperation) -> DesktopActionFailure
    {
        DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .requestCancelled,
            message: "Bridge cancelled \(operation.rawValue) before dispatch.")
    }

    private nonisolated static func checkCancellationBeforeRolloverRetry(
        operation: PeekabooBridgeOperation,
        mutating: Bool) throws
    {
        do {
            try Task.checkCancellation()
        } catch let cancellation as CancellationError {
            guard mutating else { throw cancellation }
            throw self.preTransportRequestCancelledFailure(operation: operation)
        }
    }

    private nonisolated static func throwVerifiedRolloverInstallationFailure(
        operation: PeekabooBridgeOperation,
        mutating: Bool,
        cause: any Error) throws -> Never
    {
        let message = "Bridge safely refused \(operation.rawValue) before dispatch, but its successor session " +
            "could not be installed"
        if mutating {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .transportSessionUnavailable,
                message: message,
                hint: "Establish a fresh Bridge handshake before retrying.",
                causeDescription: cause.localizedDescription)
        }
        throw PeekabooBridgeErrorEnvelope(
            code: .serverBusy,
            message: message,
            details: cause.localizedDescription,
            operationMayHaveCompleted: false)
    }

    private nonisolated static func throwVerifiedRolloverUnavailable(
        operation: PeekabooBridgeOperation,
        mutating: Bool) throws -> Never
    {
        let message = "Bridge safely refused \(operation.rawValue) before dispatch, but no successor operation " +
            "session is currently available"
        if mutating {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .transportSessionUnavailable,
                message: message,
                hint: "Retry after the Bridge host can persist a new operation session.")
        }
        throw PeekabooBridgeErrorEnvelope(
            code: .serverBusy,
            message: message,
            operationMayHaveCompleted: false)
    }

    private nonisolated static func exportOperationReceiptIfRequested(
        _ bundle: PeekabooBridgeOperationReceiptBundle,
        directory: URL?) throws
    {
        guard let directory else { return }
        let directoryURL = directory.standardizedFileURL
        let destination = directoryURL.appendingPathComponent(
            bundle.receipt.payload.requestID.uuidString.lowercased() + ".json",
            isDirectory: false)
        try PeekabooBridgePrivateReceiptArchive.writeAtomically(
            PeekabooBridgeOperationReceiptCoding.canonicalData(bundle),
            to: destination)
    }

    private nonisolated static func legacyCompletionUnknownFailure(
        envelope: PeekabooBridgeErrorEnvelope) -> DesktopActionFailure
    {
        DesktopActionFailure.indeterminate(
            route: .bridge,
            evidence: .completionUnknown,
            message: envelope.message,
            hint: "Observe the target before retrying this operation.",
            causeDescription: envelope.details)
    }
}

struct PeekabooBridgeTransportReply: Sendable {
    let response: PeekabooBridgeResponse
    let outcome: DesktopActionOutcome.Projection?
    let targetIdentity: DesktopTargetIdentity?
    let selectedLeafEvidence: [DesktopSelectedLeafEvidence]?
    let connectedHost: PeekabooBridgeConnectedHostIdentity?
    let hasVerifiedOperationReceipt: Bool
    let operationReceiptBundle: PeekabooBridgeOperationReceiptBundle?

    init(
        response: PeekabooBridgeResponse,
        outcome: DesktopActionOutcome.Projection?,
        targetIdentity: DesktopTargetIdentity? = nil,
        selectedLeafEvidence: [DesktopSelectedLeafEvidence]? = nil,
        connectedHost: PeekabooBridgeConnectedHostIdentity? = nil,
        hasVerifiedOperationReceipt: Bool = false,
        operationReceiptBundle: PeekabooBridgeOperationReceiptBundle? = nil)
    {
        self.response = response
        self.outcome = outcome
        self.targetIdentity = targetIdentity
        self.selectedLeafEvidence = selectedLeafEvidence
        self.connectedHost = connectedHost
        self.hasVerifiedOperationReceipt = hasVerifiedOperationReceipt
        self.operationReceiptBundle = operationReceiptBundle
    }
}

enum PeekabooBridgeOperationReceiptRequirement: Sendable {
    case whenAvailable
    case required
}

private struct PeekabooBridgeAttestedRequestContext: Sendable {
    let reservation: PeekabooBridgeClientOperationSessionReservation
    let attestedRequest: PeekabooBridgeAttestedOperationRequest
    let request: PeekabooBridgeRequest

    var requestID: UUID {
        self.reservation.requestID
    }
}

private struct PeekabooBridgePreparedRequest: Sendable {
    let request: PeekabooBridgeRequest
    let context: PeekabooBridgeAttestedRequestContext?
    let receiptlessHostReservation: PeekabooBridgeReceiptlessHostReservation?
}

private struct PeekabooBridgeBlockingRequest: Sendable {
    let socketPath: String
    let requestData: Data
    let maxResponseBytes: Int
    let timeoutSec: TimeInterval
    let expectedHost: PeekabooBridgeExpectedHost?
    let authenticatesInitialListener: Bool
    let hostAuthentication: PeekabooBridgeClientHostAuthentication
}

private struct PeekabooBridgeExpectedListener: Sendable {
    let attestation: PeekabooBridgeListenerAttestation
    let liveIdentity: PeekabooBridgeLivePeerIdentity
}

private enum PeekabooBridgeExpectedHost: Sendable {
    case attested(PeekabooBridgeExpectedListener)
    case authenticated(PeekabooBridgeConnectedHostIdentity)

    var requiresSigningIdentity: Bool {
        if case .authenticated = self {
            return true
        }
        return false
    }
}

private struct PeekabooBridgeBlockingResponse: Sendable {
    let data: Data
    let connectedHost: PeekabooBridgeConnectedHostIdentity?
}

private struct PeekabooBridgePostDispatchFailure: Error {
    let underlying: any Error
}

private enum PeekabooBridgeVerifiedResponse: Sendable {
    case terminal(
        PeekabooBridgeResponse,
        bundle: PeekabooBridgeOperationReceiptBundle?,
        connectedHost: PeekabooBridgeConnectedHostIdentity?)
    case rollover(PeekabooBridgeOperationSessionRefusal)
}

/// Wakes blocking socket I/O when the Swift caller is cancelled. The blocking worker remains the sole owner of
/// `close(2)` so cancellation cannot close a descriptor that the kernel has already recycled for another request.
final class PeekabooBridgeClientConnectionCancellation: @unchecked Sendable {
    typealias ShutdownHandler = @Sendable (Int32) -> Void

    private let lock = NSLock()
    private let shutdownHandler: ShutdownHandler
    private var fileDescriptor: Int32?
    private var isCancelled = false

    init(shutdownHandler: @escaping ShutdownHandler = { fd in
        _ = shutdown(fd, SHUT_RDWR)
    }) {
        self.shutdownHandler = shutdownHandler
    }

    func install(fd: Int32) throws {
        self.lock.lock()
        if self.isCancelled {
            self.lock.unlock()
            close(fd)
            throw CancellationError()
        }
        self.fileDescriptor = fd
        self.lock.unlock()
    }

    func cancel() {
        self.lock.lock()
        self.isCancelled = true
        if let fd = self.fileDescriptor {
            // `clear(fd:)` cannot release this descriptor for close/reuse until shutdown completes.
            self.shutdownHandler(fd)
        }
        self.lock.unlock()
    }

    func clear(fd: Int32) {
        self.lock.lock()
        if self.fileDescriptor == fd {
            self.fileDescriptor = nil
        }
        self.lock.unlock()
    }

    func check() throws {
        self.lock.lock()
        let isCancelled = self.isCancelled
        self.lock.unlock()
        if isCancelled {
            throw CancellationError()
        }
    }
}
