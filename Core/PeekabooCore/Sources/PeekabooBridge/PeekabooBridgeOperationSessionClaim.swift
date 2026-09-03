import Foundation

struct PeekabooBridgeNegotiatedSessionCapabilities: Hashable, Sendable {
    let protocolVersion: PeekabooBridgeProtocolVersion
    let screenCaptureKitOwnershipDiagnostics: Bool
    let statelessClickVariants: Bool
    let exactWindowHeldPointerLifecycle: Bool
    let nativeBrowserConnectionBinding: Bool
    let browserConnectionHandoff: Bool
    let producerBoundSnapshotReferences: Bool
    let targetedClickAccessibilityValueDelivery: Bool
    let requestPinnedExactWindowScrollReceipt: Bool
    let compositeTypeDelivery: Bool
    let processGenerationBoundElementMutations: Bool

    static let current = Self(
        protocolVersion: PeekabooBridgeConstants.protocolVersion,
        statelessClickVariants: true,
        exactWindowHeldPointerLifecycle: true,
        nativeBrowserConnectionBinding: true,
        browserConnectionHandoff: true,
        producerBoundSnapshotReferences: true,
        targetedClickAccessibilityValueDelivery: true,
        requestPinnedExactWindowScrollReceipt: true,
        compositeTypeDelivery: true,
        processGenerationBoundElementMutations: true,
        screenCaptureKitOwnershipDiagnostics: true)

    init(
        protocolVersion: PeekabooBridgeProtocolVersion,
        statelessClickVariants: Bool,
        exactWindowHeldPointerLifecycle: Bool,
        nativeBrowserConnectionBinding: Bool = false,
        browserConnectionHandoff: Bool = false,
        producerBoundSnapshotReferences: Bool = false,
        targetedClickAccessibilityValueDelivery: Bool = false,
        requestPinnedExactWindowScrollReceipt: Bool = false,
        compositeTypeDelivery: Bool = false,
        processGenerationBoundElementMutations: Bool = false,
        screenCaptureKitOwnershipDiagnostics: Bool = false)
    {
        self.protocolVersion = protocolVersion
        self.screenCaptureKitOwnershipDiagnostics = screenCaptureKitOwnershipDiagnostics
        self.statelessClickVariants = statelessClickVariants
        self.exactWindowHeldPointerLifecycle = exactWindowHeldPointerLifecycle
        self.nativeBrowserConnectionBinding = nativeBrowserConnectionBinding
        self.browserConnectionHandoff = browserConnectionHandoff
        self.producerBoundSnapshotReferences = producerBoundSnapshotReferences
        self.targetedClickAccessibilityValueDelivery = targetedClickAccessibilityValueDelivery
        self.requestPinnedExactWindowScrollReceipt = requestPinnedExactWindowScrollReceipt
        self.compositeTypeDelivery = compositeTypeDelivery
        self.processGenerationBoundElementMutations = processGenerationBoundElementMutations
    }
}

/// One accepted sequence claim. It retains everything required to complete a receipt after its
/// session has retired or left the bounded registry.
final class PeekabooBridgeOperationSessionClaim: @unchecked Sendable {
    let requestID: UUID
    let sessionID: UUID
    let sessionSequence: PeekabooBridgeOperationSessionSequence
    let sessionAttestation: PeekabooBridgeOperationSessionAttestation
    let negotiatedCapabilities: PeekabooBridgeNegotiatedSessionCapabilities
    let remainingClaimCount: Int

    private let lock = NSLock()
    private var state = State.pending

    init(
        requestID: UUID,
        sessionID: UUID,
        sessionSequence: PeekabooBridgeOperationSessionSequence,
        sessionAttestation: PeekabooBridgeOperationSessionAttestation,
        negotiatedCapabilities: PeekabooBridgeNegotiatedSessionCapabilities,
        remainingClaimCount: Int)
    {
        self.requestID = requestID
        self.sessionID = sessionID
        self.sessionSequence = sessionSequence
        self.sessionAttestation = sessionAttestation
        self.negotiatedCapabilities = negotiatedCapabilities
        self.remainingClaimCount = remainingClaimCount
    }

    func beginSigning() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.state == .pending else { return false }
        self.state = .signed
        return true
    }

    func beginCompletion() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.state != .complete else { return false }
        self.state = .complete
        return true
    }

    private enum State {
        case pending
        case signed
        case complete
    }
}

enum PeekabooBridgeOperationSessionClaimResult: Sendable {
    case accepted(PeekabooBridgeOperationSessionClaim)
    case rolloverRequired(PeekabooBridgeOperationSessionRefusal)
}
