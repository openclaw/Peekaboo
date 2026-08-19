import Foundation
import PeekabooAutomationKit

extension PeekabooBridgeRequest {
    /// The one canonical request-unwrapping path used by semantic planning and receipt validation.
    /// Invalid projected carriage remains wrapped so its validation failure cannot be reinterpreted
    /// as an authorized inner request.
    var unwrappedOperationRequest: PeekabooBridgeRequest {
        switch self {
        case let .attestedOperation(payload):
            (try? payload.validatedRequest())?.unwrappedOperationRequest ?? self
        case let .projectedAction(payload):
            (try? payload.validatedRequest())?.unwrappedOperationRequest ?? self
        default:
            self
        }
    }

    var requiresStatelessClickVariantSupport: Bool {
        switch self.unwrappedOperationRequest {
        case let .click(payload):
            payload.clickType.requiresStatelessVariantSupport
        case let .targetedClick(payload):
            payload.clickType.requiresStatelessVariantSupport
        default:
            false
        }
    }

    var minimumNegotiatedProtocolVersion: PeekabooBridgeProtocolVersion? {
        if self.requiresStatelessClickVariantSupport {
            return PeekabooBridgeConstants.statelessClickVariantVersion
        }
        switch self.unwrappedOperationRequest.operation {
        case .agentExecutionTrace:
            return PeekabooBridgeConstants.agentExecutionTraceVersion
        case .createExactWindowHeldPointerOwner,
             .beginExactWindowHeldPointer,
             .releaseExactWindowHeldPointer,
             .revokeExactWindowHeldPointer,
             .disconnectExactWindowHeldPointerOwner:
            return PeekabooBridgeConstants.exactWindowHeldPointerLifecycleVersion
        default:
            return nil
        }
    }

    var requiresExactWindowHeldPointerLifecycleSupport: Bool {
        switch self.unwrappedOperationRequest.operation {
        case .createExactWindowHeldPointerOwner,
             .beginExactWindowHeldPointer,
             .releaseExactWindowHeldPointer,
             .revokeExactWindowHeldPointer,
             .disconnectExactWindowHeldPointerOwner:
            true
        default:
            false
        }
    }

    var requiresExactWindowHeldPointerBeginSupport: Bool {
        switch self.unwrappedOperationRequest.operation {
        case .createExactWindowHeldPointerOwner, .beginExactWindowHeldPointer:
            true
        default:
            false
        }
    }

    var requiresExactWindowHeldPointerTerminalSupport: Bool {
        switch self.unwrappedOperationRequest.operation {
        case .releaseExactWindowHeldPointer,
             .revokeExactWindowHeldPointer,
             .disconnectExactWindowHeldPointerOwner:
            true
        default:
            false
        }
    }

    var requiresBackgroundStatelessClickVariantSupport: Bool {
        switch self.unwrappedOperationRequest {
        case let .targetedClick(payload):
            payload.clickType.requiresStatelessVariantSupport
        default:
            false
        }
    }

    /// Aggregate Agent orchestration is retry-unsafe process dispatch, but the outer request must
    /// never own the desktop lane or mutation watermark: its child re-enters this same Bridge and
    /// each nested tool call owns its own exact-target lane and signed receipt.
    var bypassesOuterDesktopMutationLane: Bool {
        self.unwrappedOperationRequest.operation == .agentExecutionTrace
    }
}

enum PeekabooBridgeRequestContext {
    @TaskLocal static var clientConnectionProbe: (@Sendable () -> Bool)?
    @TaskLocal static var operationReceiptAuthority: PeekabooBridgeOperationReceiptAuthority?
    @TaskLocal static var usesAttestedOperationResultSemantics = false
    @TaskLocal static var negotiatedSessionCapabilities: PeekabooBridgeNegotiatedSessionCapabilities?

    static func checkRequestIsActive() throws {
        try Task.checkCancellation()
        guard self.clientConnectionProbe?() != false else {
            throw CancellationError()
        }
    }
}

extension PeekabooBridgeRequest {
    /// Native services own these leases after resolving and revalidating their exact target.
    /// Remote callers and the Bridge router must not acquire a second copy of the same lane.
    var nativeLeafOwnsDesktopOperationLane: Bool {
        PeekabooBridgeOperationResultSemantics.semanticPlan(for: self)
            .nativeServiceOwnsDesktopOperationLane
    }

    var desktopOperationScope: DesktopOperationScope {
        PeekabooBridgeOperationResultSemantics.semanticPlan(for: self).desktopOperationScope
    }

    /// Bridge-owned coordination for native desktop reads and mutation paths whose concrete
    /// service provider does not own a leaf lease. Unresolved reads take the exclusive global
    /// lane so they cannot observe a partially completed scoped mutation.
    var desktopReadOperationLane: (scope: DesktopOperationScope, access: DesktopOperationAccess)? {
        PeekabooBridgeOperationResultSemantics.semanticPlan(for: self).desktopReadOperationLane
    }

    var exactWindowReadIdentity: WindowMutationIdentity? {
        guard case let .validatedWindow(identity) = PeekabooBridgeOperationResultSemantics
            .semanticPlan(for: self).exactReadTarget
        else { return nil }
        return identity
    }

    var requiresPinnedWindowMutationReceipt: Bool {
        PeekabooBridgeOperationResultSemantics.semanticPlan(for: self)
            .requiresPinnedWindowMutation
    }

    var pinnedWindowMutation: (target: WindowTarget, identity: WindowMutationIdentity)? {
        PeekabooBridgeOperationResultSemantics.semanticPlan(for: self).pinnedWindowMutation.map {
            ($0.target, $0.identity)
        }
    }

    var mayMutateDesktop: Bool {
        PeekabooBridgeOperationResultSemantics.semanticPlan(for: self).contract.completion.mutatesDesktop
    }
}
