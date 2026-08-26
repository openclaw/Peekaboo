import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

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
        if self.requiresNativeBrowserConnectionBinding {
            return PeekabooBridgeConstants.nativeBrowserConnectionBindingVersion
        }
        if self.requiresCompositeTypeDeliverySupport {
            return PeekabooBridgeConstants.compositeTypeDeliveryVersion
        }
        if self.requiresStatelessClickVariantSupport {
            return PeekabooBridgeConstants.statelessClickVariantVersion
        }
        if self.requiresProducerBoundSnapshotReferences {
            return PeekabooBridgeConstants.producerBoundSnapshotReferencesVersion
        }
        if self.requiresTargetedClickAccessibilityValueDelivery {
            return PeekabooBridgeConstants.targetedClickAccessibilityValueDeliveryVersion
        }
        switch self.unwrappedOperationRequest.operation {
        case .targetedScroll:
            return PeekabooBridgeConstants.requestPinnedExactWindowScrollReceiptVersion
        case .exactWindowPixelFocusType, .foregroundModifierClick:
            return PeekabooBridgeConstants.composedInputParityVersion
        case .agentExecutionTrace:
            return PeekabooBridgeConstants.agentExecutionTraceVersion
        case .observeProcessGeneration:
            return PeekabooBridgeConstants.processGenerationObservationVersion
        case .certificationProducerAttestation:
            return PeekabooBridgeConstants.certificationProducerAttestationVersion
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

    /// Current clients must not create or publish snapshot state through a host that did not
    /// negotiate producer-bound references. This client-side predicate intentionally stays
    /// separate from the server's ownership-probe gate: an already-shipped 1.34 client treats the
    /// canonical ID returned by a current host as opaque and must still be able to publish it.
    var createsOrPublishesSnapshotState: Bool {
        switch self.unwrappedOperationRequest.operation {
        case .createSnapshot,
             .storeDetectionResult,
             .storeScreenshot,
             .storeObservationSnapshot,
             .storeAnnotatedScreenshot:
            true
        default:
            false
        }
    }

    var requiresProducerBoundSnapshotReferences: Bool {
        self.unwrappedOperationRequest.operation == .ownsSnapshot
    }

    var requiresTargetedClickAccessibilityValueDelivery: Bool {
        guard case let .targetedClick(payload) = self.unwrappedOperationRequest else { return false }
        // This capability proves that the host understands the additive policy field, not merely
        // that it can perform value delivery. An old host would ignore an explicit `false` and
        // retain its legacy AX-value fallback, so both Boolean values require negotiation.
        return payload.allowsAccessibilityValueDelivery != nil
    }

    var requiresNativeBrowserConnectionBinding: Bool {
        switch self.unwrappedOperationRequest {
        case let .browserConnect(payload):
            payload.browserURL == nil
        case let .browserExecute(payload):
            payload.expectedConnectionReceipt?.isCanonicalProcessBoundTarget == true
        default:
            false
        }
    }

    var requiresRequestPinnedExactWindowScrollReceipt: Bool {
        self.unwrappedOperationRequest.operation == .targetedScroll
    }

    var requiresCompositeTypeDeliverySupport: Bool {
        let actions: [TypeAction]
        switch self.unwrappedOperationRequest {
        case let .targetedTypeActions(payload):
            actions = payload.actions
        case let .exactWindowTargetedTypeActions(payload):
            actions = payload.actions
        case let .exactWindowPixelFocusType(payload):
            actions = payload.request.actions
        default:
            return false
        }
        return actions.contains(where: \.mayUseAccessibilityValueDelivery)
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
