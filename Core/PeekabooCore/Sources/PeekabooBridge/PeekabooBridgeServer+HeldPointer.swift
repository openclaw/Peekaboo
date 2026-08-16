import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
extension PeekabooBridgeServer {
    private static let heldPointerClosedOwnerRetention: Duration = .seconds(60)
    private static let heldPointerClosedOwnerCapacity = 256

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
            self.heldPointerBridgeOwners[owner] = PeekabooBridgeHeldPointerOwnerBinding(
                peerIdentity: peerIdentity,
                pendingBeginTarget: nil,
                activeReceipt: nil,
                closedAt: nil)
            return .init(response: .exactWindowHeldPointerOwner(owner))

        case let .beginExactWindowHeldPointer(payload):
            _ = try await self.requireHeldPointerOwner(
                payload.owner,
                peerIdentity: peerIdentity,
                service: service)
            let pendingTarget = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                identity: payload.request.windowIdentity,
                bounds: payload.request.windowBounds))
            guard var pendingBinding = self.heldPointerBridgeOwners[payload.owner],
                  pendingBinding.closedAt == nil,
                  pendingBinding.pendingBeginTarget == nil,
                  pendingBinding.activeReceipt == nil
            else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .invalidRequest,
                    message: "Held pointer owner already has a pending or active hold.",
                    hint: "Finish or disconnect the existing hold before beginning another one.")
            }
            pendingBinding.pendingBeginTarget = pendingTarget
            self.heldPointerBridgeOwners[payload.owner] = pendingBinding
            self.automationActivityObserver?(payload.request.windowIdentity.ownerProcessIdentifier)
            let result: UIAutomationActionResult<ExactWindowHeldPointerReceipt>
            do {
                result = try await self.translateHeldPointerErrors {
                    try await service.beginExactWindowPointerHold(
                        owner: payload.owner,
                        request: payload.request)
                }
            } catch {
                self.clearHeldPointerPendingBeginTargetIfOpen(
                    owner: payload.owner,
                    target: pendingTarget)
                throw error
            }
            guard var binding = self.heldPointerBridgeOwners[payload.owner],
                  binding.closedAt == nil,
                  binding.pendingBeginTarget == pendingTarget
            else {
                throw DesktopActionFailure.dispatchedUnverified(
                    route: .bridge,
                    delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                    evidence: .deliveryAccepted,
                    unitCount: result.outcome?.dispatchState.unitCount,
                    message: "Held pointer owner disconnected before its begin receipt could be delivered.",
                    hint: "Treat the hold as terminal and observe the target before retrying.")
                    .attributed(to: Self.actionTargetReceipt(result.payload))
            }
            binding.pendingBeginTarget = nil
            binding.activeReceipt = result.payload
            self.heldPointerBridgeOwners[payload.owner] = binding
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
            let binding = try await self.requireHeldPointerOwner(
                payload.owner,
                peerIdentity: peerIdentity,
                service: service,
                allowClosed: true)
            let activeReceipt = binding.activeReceipt
            let operationTarget: DesktopTargetIdentity? = if let activeReceipt {
                try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                    identity: activeReceipt.windowIdentity,
                    bounds: activeReceipt.windowBounds))
            } else {
                binding.pendingBeginTarget
            }
            let result: UIAutomationActionResult<ExactWindowHeldPointerTermination?>
            do {
                result = try await self.translateHeldPointerErrors {
                    try await service.disconnectExactWindowHeldPointerOwner(payload.owner)
                }
            } catch let failure as DesktopActionFailure {
                self.markHeldPointerOwnerClosed(payload.owner)
                guard let operationTarget else { throw failure }
                let routed = failure
                    .attributed(to: Self.actionTargetReceipt(operationTarget))
                    .routed(to: .bridge)
                return PeekabooBridgeHandledResponse(
                    response: .error(.init(
                        code: .internalError,
                        actionFailure: routed,
                        details: routed.localizedDescription)),
                    mutation: .init(
                        outcome: routed.outcome,
                        target: .handlerResolved(operationTarget)))
            }
            if result.payload == nil {
                self.heldPointerBridgeOwners.removeValue(forKey: payload.owner)
            } else {
                self.heldPointerBridgeOwners[payload.owner]?.pendingBeginTarget = nil
                self.heldPointerBridgeOwners[payload.owner]?.activeReceipt = result.payload?.receipt
                self.markHeldPointerOwnerClosed(payload.owner)
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
        _ = try await self.requireHeldPointerOwner(
            payload.owner,
            peerIdentity: peerIdentity,
            service: service,
            allowClosed: true)
        self.automationActivityObserver?(payload.receipt.windowIdentity.ownerProcessIdentifier)
        let result = try await self.translateHeldPointerErrors {
            try await operation(payload.owner, payload.receipt)
        }
        self.clearHeldPointerActiveReceiptIfMatching(
            owner: payload.owner,
            receipt: payload.receipt)
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
        service: any ExactWindowHeldPointerLifecycleServiceProtocol,
        allowClosed: Bool = false) async throws -> PeekabooBridgeHeldPointerOwnerBinding
    {
        await self.pruneHeldPointerBridgeOwners(service: service)
        guard let binding = self.heldPointerBridgeOwners[owner],
              binding.peerIdentity == peerIdentity,
              allowClosed || binding.closedAt == nil
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Held pointer owner does not belong to this Bridge client generation.",
                hint: "Use the opaque owner returned to the same authenticated Bridge client.")
        }
        return binding
    }

    private func pruneHeldPointerBridgeOwners(
        service: any ExactWindowHeldPointerLifecycleServiceProtocol) async
    {
        let now = ContinuousClock.now
        let staleOwners = self.heldPointerBridgeOwners.compactMap { owner, binding in
            let peerIsCurrent = self.processStartIdentityProvider(binding.peerIdentity.processIdentifier) ==
                binding.peerIdentity.processStartIdentity
            let closedOwnerIsRetained = binding.closedAt.map {
                $0.advanced(by: Self.heldPointerClosedOwnerRetention) > now
            } ?? true
            return peerIsCurrent && closedOwnerIsRetained ? nil : owner
        }
        for owner in staleOwners {
            let binding = self.heldPointerBridgeOwners.removeValue(forKey: owner)
            if binding?.closedAt == nil {
                do {
                    _ = try await service.disconnectExactWindowHeldPointerOwner(owner)
                } catch {
                    self.logger.error(
                        "Stale held pointer owner cleanup failed: \(error.localizedDescription, privacy: .private)")
                }
            }
        }

        self.enforceHeldPointerClosedOwnerCapacity()
    }

    private func markHeldPointerOwnerClosed(_ owner: ExactWindowHeldPointerOwner) {
        guard var binding = self.heldPointerBridgeOwners[owner] else { return }
        binding.closedAt = binding.closedAt ?? ContinuousClock.now
        self.heldPointerBridgeOwners[owner] = binding
        self.enforceHeldPointerClosedOwnerCapacity()
    }

    func clearHeldPointerActiveReceiptIfMatching(
        owner: ExactWindowHeldPointerOwner,
        receipt: ExactWindowHeldPointerReceipt)
    {
        guard var binding = self.heldPointerBridgeOwners[owner],
              binding.closedAt == nil,
              binding.activeReceipt == receipt
        else { return }
        binding.activeReceipt = nil
        self.heldPointerBridgeOwners[owner] = binding
    }

    private func clearHeldPointerPendingBeginTargetIfOpen(
        owner: ExactWindowHeldPointerOwner,
        target: DesktopTargetIdentity)
    {
        guard var binding = self.heldPointerBridgeOwners[owner],
              binding.closedAt == nil,
              binding.pendingBeginTarget == target
        else { return }
        binding.pendingBeginTarget = nil
        self.heldPointerBridgeOwners[owner] = binding
    }

    private func enforceHeldPointerClosedOwnerCapacity() {
        let closedOwners = self.heldPointerBridgeOwners.compactMap { owner, binding in
            binding.closedAt.map { (owner, $0) }
        }.sorted { $0.1 < $1.1 }
        for (owner, _) in closedOwners.dropLast(Self.heldPointerClosedOwnerCapacity) {
            self.heldPointerBridgeOwners.removeValue(forKey: owner)
        }
    }

    private static func actionTargetReceipt(
        _ receipt: ExactWindowHeldPointerReceipt) -> DesktopActionTargetReceipt
    {
        DesktopActionTargetReceipt(
            processIdentifier: receipt.windowIdentity.ownerProcessIdentifier,
            processStartIdentity: receipt.windowIdentity.ownerProcessStartIdentity,
            windowID: receipt.windowIdentity.windowID)
    }

    private static func actionTargetReceipt(
        _ target: DesktopTargetIdentity) -> DesktopActionTargetReceipt
    {
        DesktopActionTargetReceipt(
            processIdentifier: target.processIdentity.processIdentifier,
            processStartIdentity: target.processIdentity.processStartIdentity,
            windowID: target.exactWindow?.identity.windowID)
    }

    #if DEBUG
    var retainedClosedHeldPointerOwnerCountForTesting: Int {
        self.heldPointerBridgeOwners.values.count { $0.closedAt != nil }
    }
    #endif

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
