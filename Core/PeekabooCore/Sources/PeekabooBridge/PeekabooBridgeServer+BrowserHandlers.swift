import Foundation
@_spi(Bridge) import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
extension PeekabooBridgeServer {
    func handleBrowserRequest(_ request: PeekabooBridgeRequest) async throws
        -> PeekabooBridgeResponse
    {
        switch request {
        case let .browserStatus(payload):
            return try await .browserStatus(self.services.browserStatus(channel: payload.channel))
        case let .browserConnect(payload):
            let status = try await self.legacyBrowserConnectionStatus(payload)
            return .browserStatus(status)
        case .browserDisconnect:
            try await self.services.browserDisconnect()
            return .ok
        case let .browserExecute(payload):
            return try await .browserToolResponse(self.services.browserExecute(payload))
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    func handleScopedBrowserStatus(
        sessionID: UUID,
        channel: String?) async throws -> PeekabooBridgeBrowserStatus
    {
        let caller = try self.authenticatedBrowserSessionCaller()
        let lease = try await self.browserHandoffGrantRegistry.authorizeSession(sessionID, caller: caller)
        defer { self.browserHandoffGrantRegistry.completeSessionOperation(lease) }
        guard let provider = self.browserSessionBootstrapProvider else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "This Bridge host has no scoped browser session provider")
        }
        let status = try await provider.browserSessionStatus(sessionID: sessionID, channel: channel)
        guard status.isCanonicalScopedSessionStatus else {
            throw PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: "Scoped browser provider returned contradictory status evidence")
        }
        return status
    }

    func handleBrowserSessionControl(
        _ request: PeekabooBridgeBrowserSessionControlRequest) async throws -> PeekabooBridgeResponse
    {
        let caller = try self.authenticatedBrowserSessionCaller()
        guard let provider = self.browserSessionBootstrapProvider else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "This Bridge host has no scoped browser session provider")
        }
        switch request.action {
        case .disconnect:
            let lease = try await self.browserHandoffGrantRegistry.authorizeSession(
                request.sessionID,
                caller: caller)
            defer { self.browserHandoffGrantRegistry.completeSessionOperation(lease) }
            try await provider.disconnectBrowserSession(request.sessionID)
        case .end:
            try await self.browserHandoffGrantRegistry.endSession(request.sessionID, caller: caller)
        }
        return .ok
    }

    func authenticatedBrowserSessionCaller() throws -> PeekabooBridgeBrowserSessionCaller {
        guard let operation = PeekabooBridgeRequestContext.browserHandoffOperation else {
            throw PeekabooBridgeErrorEnvelope(
                code: .unauthorizedClient,
                message: "Scoped browser operations require an attested operation caller")
        }
        return try operation.peer.browserSessionCaller(clientInstanceID: operation.clientInstanceID)
    }

    func handleBrowserExecute(
        _ payload: PeekabooBridgeBrowserExecuteRequest) async throws -> PeekabooBridgeHandledResponse
    {
        guard !payload.resolvedCalls.isEmpty else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Browser execution requires at least one tool call.",
                hint: "Provide one browser tool call before retrying.")
        }
        let target: (
            receipt: PeekabooBridgeBrowserConnectionReceipt,
            disposition: PeekabooBridgeHandledResponse.Mutation.TargetDisposition)
        let scopedSessionID = payload.sessionID
        var scopedLease: PeekabooBridgeBrowserHandoffGrantRegistry.SessionOperationLease?
        defer {
            if let scopedLease {
                self.browserHandoffGrantRegistry.completeSessionOperation(scopedLease)
            }
        }
        if let scopedSessionID {
            let caller = try self.authenticatedBrowserSessionCaller()
            scopedLease = try await self.browserHandoffGrantRegistry.authorizeSession(
                scopedSessionID,
                caller: caller)
            guard let expectedReceipt = payload.expectedConnectionReceipt,
                  expectedReceipt.isCanonicalExecutionTarget,
                  payload.expectedProviderSessionEpoch != nil,
                  payload.connectionPolicy == .requireExistingLiveReceipt,
                  payload.elementPreflight?.isCanonical != false
            else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .invalidRequest,
                    message: "Scoped browser execution requires an exact receipt, epoch, and canonical preflight.",
                    hint: "Refresh scoped browser status before retrying.")
            }
            target = try (expectedReceipt, self.browserTargetDisposition(expectedReceipt))
        } else {
            scopedLease = nil
            target = try await self.browserExecutionTarget(payload)
        }
        let result: PeekabooBridgeBrowserExecutionResult
        do {
            if let scopedSessionID {
                guard let provider = self.browserSessionBootstrapProvider else {
                    throw PeekabooBridgeErrorEnvelope(
                        code: .operationNotSupported,
                        message: "This Bridge host has no scoped browser session provider")
                }
                result = try await provider.browserSessionExecute(
                    sessionID: scopedSessionID,
                    request: payload,
                    expectedConnectionReceipt: target.receipt)
            } else {
                result = try await self.services.browserExecute(
                    payload,
                    expectedConnectionReceipt: target.receipt)
            }
        } catch is CancellationError {
            let acceptedProviderSessionEpoch = scopedSessionID == nil
                ? nil
                : payload.expectedProviderSessionEpoch
            if payload.isReadOnly {
                return Self.browserReadCancellationHandledResponse(
                    target: target,
                    providerSessionEpoch: acceptedProviderSessionEpoch)
            }
            return Self.browserOpaqueCancellationHandledResponse(
                target: target,
                providerSessionEpoch: acceptedProviderSessionEpoch,
                causeDescription:
                "The browser provider was cancelled after accepting the execution request.")
        }
        guard result.connectionReceipt == target.receipt,
              scopedSessionID == nil || result.providerSessionEpoch == payload.expectedProviderSessionEpoch
        else {
            if payload.isReadOnly {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Browser read returned a different connection receipt.",
                    hint: "Refresh browser status and retry against its exact connection receipt.")
            }
            throw DesktopActionFailure.indeterminate(
                evidence: .completionUnknown,
                message: "Browser execution returned a different connection receipt.",
                hint: "Observe the intended browser before retrying and update the runtime host.")
        }
        if payload.isReadOnly {
            return try Self.browserReadHandledResponse(result: result, request: payload, target: target)
        }
        guard
            result.completedCallCount >= 0,
            result.dispatchedCallCount >= result.completedCallCount,
            result.dispatchedCallCount <= payload.mutationCallCount
        else {
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .browserProtocol, mode: .background),
                evidence: .completionUnknown,
                message: "Browser execution returned a different connection receipt.",
                hint: "Observe the intended browser before retrying and update the runtime host.")
        }
        if result.dispatchedCallCount == 0 {
            return try Self.browserNoDispatchHandledResponse(result: result, target: target)
        }
        guard
            let dispatchedCallCount = DesktopActionOutcome.DispatchUnitCount(result.dispatchedCallCount)
        else {
            preconditionFailure("A positive browser dispatch count must have a canonical unit count")
        }
        let routedFailure: DesktopActionFailure? =
            if let failure = result.actionFailure,
            failure.outcome.dispatchState.mutationDispatched,
            failure.outcome.dispatchState.unitCount == dispatchedCallCount {
                failure.routed(to: .bridge)
            } else if result.actionFailure != nil || result.response.isError
                || result.completedCallCount != payload.mutationCallCount
            {
                Self.browserProviderIndeterminateFailure(
                    completedCallCount: result.completedCallCount,
                    dispatchedCallCount: dispatchedCallCount,
                    causeDescription:
                    "The browser provider returned incomplete or contradictory result semantics.")
            } else {
                nil
            }
        let response = PeekabooBridgeBrowserToolResponse(
            content: result.response.content,
            isError: routedFailure != nil,
            meta: result.response.meta,
            structuredContent: result.response.structuredContent,
            connectionReceipt: target.receipt,
            completedCallCount: result.completedCallCount,
            dispatchedCallCount: result.dispatchedCallCount,
            actionFailure: routedFailure,
            providerSessionEpoch: result.providerSessionEpoch)
        let outcome =
            routedFailure?.outcome
                ?? .dispatchedUnverified(
                    delivery: .init(mechanism: .browserProtocol, mode: .background),
                    evidence: .deliveryAccepted,
                    unitCount: dispatchedCallCount)
        return .init(
            response: .browserToolResponse(response),
            mutation: .init(
                outcome: outcome,
                target: target.disposition))
    }

    private static func browserReadCancellationHandledResponse(
        target: (
            receipt: PeekabooBridgeBrowserConnectionReceipt,
            disposition: PeekabooBridgeHandledResponse.Mutation.TargetDisposition),
        providerSessionEpoch: UUID?)
        -> PeekabooBridgeHandledResponse
    {
        .init(response: .browserToolResponse(.init(
            content: [
                .object([
                    "type": .string("text"),
                    "text": .string("Browser read was cancelled after provider entry."),
                ]),
            ],
            isError: true,
            meta: nil,
            connectionReceipt: target.receipt,
            providerSessionEpoch: providerSessionEpoch)))
    }

    private static func browserReadHandledResponse(
        result: PeekabooBridgeBrowserExecutionResult,
        request: PeekabooBridgeBrowserExecuteRequest,
        target: (
            receipt: PeekabooBridgeBrowserConnectionReceipt,
            disposition: PeekabooBridgeHandledResponse.Mutation.TargetDisposition)) throws
        -> PeekabooBridgeHandledResponse
    {
        let callCount = request.resolvedCalls.count
        guard result.completedCallCount >= 0,
              result.dispatchedCallCount >= result.completedCallCount,
              result.completedCallCount <= callCount,
              result.dispatchedCallCount <= callCount,
              result.response.isError || (
                  result.completedCallCount == callCount &&
                      result.dispatchedCallCount == callCount &&
                      result.actionFailure == nil)
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Receipt-bound browser read did not complete canonically.",
                hint: "Refresh browser status and retry against its exact connection receipt.")
        }
        return .init(response: .browserToolResponse(.init(
            content: result.response.content,
            isError: result.response.isError,
            meta: result.response.meta,
            structuredContent: result.response.structuredContent,
            connectionReceipt: target.receipt,
            completedCallCount: result.completedCallCount,
            dispatchedCallCount: result.dispatchedCallCount,
            providerSessionEpoch: result.providerSessionEpoch)))
    }

    private static func browserNoDispatchHandledResponse(
        result: PeekabooBridgeBrowserExecutionResult,
        target: (
            receipt: PeekabooBridgeBrowserConnectionReceipt,
            disposition: PeekabooBridgeHandledResponse.Mutation.TargetDisposition)) throws
        -> PeekabooBridgeHandledResponse
    {
        guard result.completedCallCount == 0,
              let failure = result.actionFailure,
              failure.outcome.state == .refused,
              failure.outcome.dispatchState == .none,
              failure.outcome.retrySafety == .safe,
              failure.outcome.refusalReason != nil
        else {
            throw DesktopActionFailure.indeterminate(
                route: .bridge,
                delivery: .init(mechanism: .browserProtocol, mode: .background),
                evidence: .completionUnknown,
                message: "Browser provider returned contradictory zero-progress semantics.",
                hint: "Observe the exact browser before retrying and update the runtime host.")
        }
        let routedFailure = failure.routed(to: .bridge)
        return .init(
            response: .browserToolResponse(
                .init(
                    content: result.response.content,
                    isError: true,
                    meta: result.response.meta,
                    structuredContent: result.response.structuredContent,
                    connectionReceipt: target.receipt,
                    completedCallCount: 0,
                    dispatchedCallCount: 0,
                    actionFailure: routedFailure,
                    providerSessionEpoch: result.providerSessionEpoch)),
            mutation: .init(outcome: routedFailure.outcome, target: target.disposition))
    }

    private static func browserOpaqueCancellationHandledResponse(
        target: (
            receipt: PeekabooBridgeBrowserConnectionReceipt,
            disposition: PeekabooBridgeHandledResponse.Mutation.TargetDisposition),
        providerSessionEpoch: UUID?,
        causeDescription: String) -> PeekabooBridgeHandledResponse
    {
        let failure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            message: "Browser execution completion is indeterminate; exact progress is unavailable.",
            hint: "Observe the exact browser before deciding which work remains unfinished.",
            causeDescription: causeDescription)
        return .init(
            response: .browserToolResponse(
                .init(
                    content: [
                        .object([
                            "type": .string("text"),
                            "text": .string(failure.message),
                        ]),
                    ],
                    isError: true,
                    meta: nil,
                    connectionReceipt: target.receipt,
                    actionFailure: failure,
                    providerSessionEpoch: providerSessionEpoch)),
            mutation: .init(outcome: failure.outcome, target: target.disposition))
    }

    private static func browserProviderIndeterminateFailure(
        completedCallCount: Int,
        dispatchedCallCount: DesktopActionOutcome.DispatchUnitCount,
        causeDescription: String) -> DesktopActionFailure
    {
        .indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            unitCount: dispatchedCallCount,
            message: "Browser execution completion is indeterminate "
                + "(\(completedCallCount) completed, \(dispatchedCallCount.rawValue) dispatched or accepted).",
            hint: "Observe the exact browser before resuming unfinished work.",
            causeDescription: causeDescription)
    }
}
