import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
extension PeekabooBridgeServer {
    func handleHeldPointerRequest(
        _ request: PeekabooBridgeRequest,
        peer: PeekabooBridgePeer?) async throws -> PeekabooBridgeHandledResponse
    {
        guard let service = self.services.automation as? any ExactWindowHeldPointerLifecycleServiceProtocol,
              service.supportsExactWindowHeldPointerLifecycle
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "Exact-window held pointer lifecycle is unavailable on this Bridge host.",
                hint: "Update the Bridge host to protocol 1.30 before retrying.")
        }
        let peerIdentity = try self.heldPointerPeerIdentity(peer)

        switch request {
        case .createExactWindowHeldPointerOwner:
            await self.pruneHeldPointerBridgeOwners(service: service)
            let owner = try await self.translateHeldPointerErrors {
                try await service.createExactWindowHeldPointerOwner(boundTo: peerIdentity)
            }
            self.heldPointerBridgeOwners[owner] = peerIdentity
            return .init(response: .exactWindowHeldPointerOwner(owner))

        case let .beginExactWindowHeldPointer(payload):
            try await self.requireHeldPointerOwner(
                payload.owner,
                peerIdentity: peerIdentity,
                service: service)
            self.automationActivityObserver?(payload.request.windowIdentity.ownerProcessIdentifier)
            let result = try await self.translateHeldPointerErrors {
                try await service.beginExactWindowPointerHold(
                    owner: payload.owner,
                    request: payload.request)
            }
            return try Self.handledActionResponse(
                response: .exactWindowHeldPointerReceipt(result.payload),
                result: result,
                fallbackTarget: .requestPinned)

        case let .releaseExactWindowHeldPointer(payload):
            return try await self.handleHeldPointerTerminal(
                payload,
                peerIdentity: peerIdentity,
                service: service,
                operation: service.releaseExactWindowPointerHold)

        case let .revokeExactWindowHeldPointer(payload):
            return try await self.handleHeldPointerTerminal(
                payload,
                peerIdentity: peerIdentity,
                service: service,
                operation: service.revokeExactWindowPointerHold)

        case let .disconnectExactWindowHeldPointerOwner(payload):
            try await self.requireHeldPointerOwner(
                payload.owner,
                peerIdentity: peerIdentity,
                service: service)
            defer { self.heldPointerBridgeOwners.removeValue(forKey: payload.owner) }
            let result = try await self.translateHeldPointerErrors {
                try await service.disconnectExactWindowHeldPointerOwner(payload.owner)
            }
            return try Self.handledActionResponse(
                response: .exactWindowHeldPointerTermination(result.payload),
                result: result,
                fallbackTarget: result.payload == nil ? .global : .requestPinned)

        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private func handleHeldPointerTerminal(
        _ payload: PeekabooBridgeFinishHeldPointerRequest,
        peerIdentity: ApplicationProcessIdentity,
        service: any ExactWindowHeldPointerLifecycleServiceProtocol,
        operation: (ExactWindowHeldPointerOwner, ExactWindowHeldPointerReceipt) async throws
            -> UIAutomationActionResult<ExactWindowHeldPointerTermination>) async throws
        -> PeekabooBridgeHandledResponse
    {
        try await self.requireHeldPointerOwner(
            payload.owner,
            peerIdentity: peerIdentity,
            service: service)
        self.automationActivityObserver?(payload.receipt.windowIdentity.ownerProcessIdentifier)
        let result = try await self.translateHeldPointerErrors {
            try await operation(payload.owner, payload.receipt)
        }
        return try Self.handledActionResponse(
            response: .exactWindowHeldPointerTermination(result.payload),
            result: result,
            fallbackTarget: .requestPinned)
    }

    private func heldPointerPeerIdentity(_ peer: PeekabooBridgePeer?) throws -> ApplicationProcessIdentity {
        guard let peer,
              peer.processIdentifier > 0,
              let processStartIdentity = peer.processStartIdentity,
              self.processStartIdentityProvider(peer.processIdentifier) == processStartIdentity
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Held pointer ownership requires an authenticated live client process generation.",
                hint: "Reconnect and negotiate a fresh protocol-1.30 Bridge session.")
        }
        return ApplicationProcessIdentity(
            processIdentifier: peer.processIdentifier,
            processStartIdentity: processStartIdentity)
    }

    private func requireHeldPointerOwner(
        _ owner: ExactWindowHeldPointerOwner,
        peerIdentity: ApplicationProcessIdentity,
        service: any ExactWindowHeldPointerLifecycleServiceProtocol) async throws
    {
        await self.pruneHeldPointerBridgeOwners(service: service)
        guard self.heldPointerBridgeOwners[owner] == peerIdentity else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Held pointer owner does not belong to this Bridge client generation.",
                hint: "Use the opaque owner returned to the same authenticated Bridge client.")
        }
    }

    private func pruneHeldPointerBridgeOwners(
        service: any ExactWindowHeldPointerLifecycleServiceProtocol) async
    {
        let staleOwners = self.heldPointerBridgeOwners.compactMap { owner, identity in
            self.processStartIdentityProvider(identity.processIdentifier) == identity.processStartIdentity
                ? nil
                : owner
        }
        for owner in staleOwners {
            self.heldPointerBridgeOwners.removeValue(forKey: owner)
            do {
                _ = try await service.disconnectExactWindowHeldPointerOwner(owner)
            } catch {
                self.logger.error(
                    "Stale held pointer owner cleanup failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func translateHeldPointerErrors<Payload: Sendable>(
        _ operation: () async throws -> Payload) async throws -> Payload
    {
        do {
            return try await operation()
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch let error as ExactWindowHeldPointerLifecycleError {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: error.localizedDescription,
                hint: "Use the exact owner and hold receipt returned by this Bridge host.")
        }
    }
}
