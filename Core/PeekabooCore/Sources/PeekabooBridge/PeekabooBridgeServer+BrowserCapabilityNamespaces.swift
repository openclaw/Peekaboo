import Foundation
import PeekabooFoundation

@MainActor
extension PeekabooBridgeServer {
    private struct BrowserCapabilityNamespaceContext {
        let authority: PeekabooBridgeBrowserCapabilityNamespaceAuthority
        let service: any PeekabooBridgeBrowserCapabilityNamespaceProviding
        let principal: PeekabooBridgeBrowserCapabilityPrincipal
    }

    func handleBrowserCapabilityNamespaceCreate(
        _ request: PeekabooBridgeBrowserCapabilityNamespaceCreateRequest,
        peer: PeekabooBridgePeer?) async throws -> PeekabooBridgeHandledResponse
    {
        _ = request
        let context = try self.browserCapabilityNamespaceContext(peer: peer, mutatesDesktop: false)
        try await self.retireExpiredBrowserCapabilityNamespaces(context)
        guard let admission = PeekabooBridgeBrowserCapabilityNamespaceAdmission(
            isLocalExecutionHost: self.hostKind == .onDemand,
            isAuthenticatedPeer: peer != nil,
            hasNativeCapableService: context.service.supportsNativeBrowserWindowBinding)
        else {
            throw Self.browserCapabilityNamespacePreDispatchRefusal(
                PeekabooBridgeBrowserCapabilityNamespaceError.unauthenticatedNamespaceAdmission,
                mutatesDesktop: false)
        }
        let receipt: PeekabooBridgeBrowserCapabilityNamespaceReceipt
        do {
            receipt = try await context.authority.open(
                principal: context.principal,
                admission: admission,
                lifetimeMilliseconds: PeekabooBridgeBrowserCapabilityNamespaceAuthority
                    .Configuration.current.maximumLifetimeMilliseconds)
        } catch let error as PeekabooBridgeBrowserCapabilityNamespaceError {
            throw Self.browserCapabilityNamespacePreDispatchRefusal(error, mutatesDesktop: false)
        }

        do {
            try await context.service.openBrowserCapabilityNamespace(
                namespaceID: receipt.payload.namespaceID)
        } catch {
            try? await context.authority.close(receipt, principal: context.principal)
            try? await context.authority.markRuntimeRetired(namespaceID: receipt.payload.namespaceID)
            throw error
        }
        return .init(response: .browserCapabilityNamespaceCreated(receipt))
    }

    func handleBrowserCapabilityNamespaceAction(
        _ request: PeekabooBridgeBrowserCapabilityNamespaceRequest,
        peer: PeekabooBridgePeer?) async throws -> PeekabooBridgeHandledResponse
    {
        let context = try self.browserCapabilityNamespaceContext(
            peer: peer,
            mutatesDesktop: !request.isReadOnly)
        try await self.retireExpiredBrowserCapabilityNamespaces(context)
        guard let requestID = PeekabooBridgeRequestContext.attestedOperationRequestID,
              let admission = PeekabooBridgeBrowserCapabilityClaimAdmission(
                  executionPolicy: request.executionMode,
                  isLocalExecutionHost: self.hostKind == .onDemand,
                  isAuthenticatedPeer: peer != nil,
                  hasScopedForegroundAuthorization: request.executionMode == .foregroundAllowed)
        else {
            throw Self.browserCapabilityNamespacePreDispatchRefusal(
                PeekabooBridgeBrowserCapabilityNamespaceError.unauthenticatedClaimAdmission,
                mutatesDesktop: !request.isReadOnly)
        }

        let claim: PeekabooBridgeBrowserCapabilityNamespaceClaim
        do {
            claim = try await context.authority.claim(
                request.namespaceReceipt,
                principal: context.principal,
                claimID: requestID,
                admission: admission)
        } catch let error as PeekabooBridgeBrowserCapabilityNamespaceError {
            throw Self.browserCapabilityNamespacePreDispatchRefusal(
                error,
                mutatesDesktop: !request.isReadOnly)
        }

        let result: PeekabooBridgeBrowserCapabilityNamespaceServiceResult
        do {
            result = try await context.service.executeBrowserCapabilityNamespace(
                namespaceID: claim.authorization.namespaceID,
                request: request)
        } catch {
            do {
                try await context.authority.complete(claim)
            } catch let completionError as PeekabooBridgeBrowserCapabilityNamespaceError {
                throw Self.browserCapabilityNamespaceCompletionFailure(completionError)
            }
            throw error
        }
        do {
            try await context.authority.complete(claim)
        } catch let error as PeekabooBridgeBrowserCapabilityNamespaceError {
            throw Self.browserCapabilityNamespaceCompletionFailure(error)
        }

        var handled = PeekabooBridgeHandledResponse(
            response: .browserCapabilityNamespaceAction(result.response),
            targetIdentity: result.targetIdentity)
        if !request.isReadOnly, let outcome = result.outcome {
            let target: PeekabooBridgeHandledResponse.Mutation.TargetDisposition =
                result.targetIdentity.map(PeekabooBridgeHandledResponse.Mutation.TargetDisposition.handlerResolved) ??
                .external
            handled = handled.finalizingMutation(outcome: outcome, target: target)
        }
        return handled
    }

    func handleBrowserCapabilityNamespaceClose(
        _ request: PeekabooBridgeBrowserCapabilityNamespaceCloseRequest,
        peer: PeekabooBridgePeer?) async throws -> PeekabooBridgeHandledResponse
    {
        let context = try self.browserCapabilityNamespaceContext(peer: peer, mutatesDesktop: false)
        try await self.retireExpiredBrowserCapabilityNamespaces(context)
        let identity: PeekabooBridgeBrowserCapabilityNamespaceIdentity
        do {
            identity = try await context.authority.beginClose(
                request.namespaceReceipt,
                principal: context.principal)
        } catch let error as PeekabooBridgeBrowserCapabilityNamespaceError {
            throw Self.browserCapabilityNamespacePreDispatchRefusal(error, mutatesDesktop: false)
        }

        var runtimeError: (any Error)?
        do {
            try await context.service.closeBrowserCapabilityNamespace(namespaceID: identity.namespaceID)
        } catch {
            runtimeError = error
        }
        do {
            try await context.authority.awaitDrained(identity: identity)
        } catch let error as PeekabooBridgeBrowserCapabilityNamespaceError {
            throw Self.browserCapabilityNamespaceCompletionFailure(error)
        }
        if let runtimeError {
            throw runtimeError
        }
        try await context.authority.markRuntimeRetired(namespaceID: identity.namespaceID)
        return .init(response: .browserCapabilityNamespaceClosed(.init(namespaceID: identity.namespaceID)))
    }

    private func retireExpiredBrowserCapabilityNamespaces(
        _ context: BrowserCapabilityNamespaceContext) async throws
    {
        let namespaceIDs = try await context.authority.terminalNamespaceIDsRequiringRuntimeRetirement()
        for namespaceID in namespaceIDs {
            do {
                try await context.service.closeBrowserCapabilityNamespace(namespaceID: namespaceID)
            } catch let envelope as PeekabooBridgeErrorEnvelope where envelope.code == .notFound {
                // An idempotent runtime may already have released this exact namespace.
            }
            try await context.authority.markRuntimeRetired(namespaceID: namespaceID)
        }
    }

    private func browserCapabilityNamespaceContext(
        peer: PeekabooBridgePeer?,
        mutatesDesktop: Bool) throws
        -> BrowserCapabilityNamespaceContext
    {
        guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics,
              PeekabooBridgeRequestContext.negotiatedSessionCapabilities?.browserCapabilityNamespaces == true,
              PeekabooBridgeRequestContext.negotiatedSessionCapabilities?.nativeBrowserWindowBinding == true,
              self.hostKind == .onDemand,
              let peer,
              let authority = PeekabooBridgeRequestContext.browserCapabilityNamespaceAuthority,
              let service = self.services as? any PeekabooBridgeBrowserCapabilityNamespaceProviding,
              service.supportsBrowserCapabilityNamespaces,
              service.supportsNativeBrowserWindowBinding
        else {
            throw Self.browserCapabilityNamespacePreDispatchRefusal(
                PeekabooBridgeBrowserCapabilityNamespaceError.unauthenticatedClaimAdmission,
                mutatesDesktop: mutatesDesktop)
        }
        do {
            return try BrowserCapabilityNamespaceContext(
                authority: authority,
                service: service,
                principal: PeekabooBridgeBrowserCapabilityNamespaceAuthority.principal(for: peer))
        } catch let error as PeekabooBridgeBrowserCapabilityNamespaceError {
            throw Self.browserCapabilityNamespacePreDispatchRefusal(error, mutatesDesktop: mutatesDesktop)
        }
    }

    private static func browserCapabilityNamespaceCompletionFailure(
        _ error: PeekabooBridgeBrowserCapabilityNamespaceError) -> PeekabooBridgeErrorEnvelope
    {
        PeekabooBridgeErrorEnvelope(
            code: .internalError,
            message: "Browser capability namespace completion could not be finalized",
            details: error.localizedDescription)
    }

    private static func browserCapabilityNamespacePreDispatchRefusal(
        _ error: PeekabooBridgeBrowserCapabilityNamespaceError,
        mutatesDesktop: Bool) -> PeekabooBridgeErrorEnvelope
    {
        let code: PeekabooBridgeErrorCode
        let reason: DesktopActionOutcome.RefusalReason
        switch error {
        case .invalidPrincipal, .unauthenticatedNamespaceAdmission, .unauthenticatedClaimAdmission,
             .invalidSignature, .principalMismatch:
            code = .unauthorizedClient
            reason = .transportSessionUnavailable
        case .invalidReceipt, .listenerMismatch, .registryGenerationMismatch, .receiptNotYetValid,
             .replayedClaim, .claimMismatch, .drainAlreadyAwaited:
            code = .invalidRequest
            reason = .invalidRequest
        case .receiptExpired, .namespaceNotFound, .namespaceClosing, .namespaceClosed, .namespaceExpired:
            code = .notFound
            reason = .targetUnavailable
        case .registryInvalidated, .registryDraining:
            code = .versionMismatch
            reason = .transportSessionUnavailable
        case .invalidConfiguration, .namespaceCapacityExceeded, .claimCapacityExceeded:
            code = .serverBusy
            reason = .runtimeIncompatible
        }
        guard mutatesDesktop else {
            return PeekabooBridgeErrorEnvelope(
                code: code,
                message: error.localizedDescription)
        }
        return PeekabooBridgeErrorEnvelope(
            code: code,
            actionFailure: .preDispatchRefusal(
                route: .bridge,
                reason: reason,
                message: error.localizedDescription,
                hint: reason == .targetUnavailable
                    ? "Create a new browser capability namespace before retrying."
                    : "Reconnect the on-demand Bridge session before retrying."))
    }
}
