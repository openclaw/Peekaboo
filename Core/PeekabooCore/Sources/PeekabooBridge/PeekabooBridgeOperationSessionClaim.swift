import Foundation

struct PeekabooBridgeNegotiatedSessionCapabilities: Hashable, Sendable {
    let protocolVersion: PeekabooBridgeProtocolVersion
    let screenCaptureKitOwnershipDiagnostics: Bool
    let statelessClickVariants: Bool
    let exactWindowHeldPointerLifecycle: Bool
    let exactWindowDrag: Bool
    let nativeBrowserConnectionBinding: Bool
    let browserConnectionHandoff: Bool
    let producerBoundSnapshotReferences: Bool
    let scopedMenuBarActions: Bool
    let targetedClickAccessibilityValueDelivery: Bool
    let requestPinnedExactWindowScrollReceipt: Bool
    let backgroundCoordinateScroll: Bool
    let compositeTypeDelivery: Bool
    let exactFileDialogExecution: Bool
    let clipboardGuardedExactWindowHotkeys: Bool
    let preparedClipboardGuardedExactWindowHotkeys: Bool
    let processGenerationBoundElementMutations: Bool
    let setValueVerification: Bool

    static func offersSetValueVerification(
        _ capabilities: Set<String>,
        negotiatedVersion: PeekabooBridgeProtocolVersion) -> Bool
    {
        negotiatedVersion >= PeekabooBridgeConstants.processGenerationBoundElementMutationsVersion &&
            capabilities.contains(PeekabooBridgeClientCapability.setValueVerification)
    }

    static let current = Self(
        protocolVersion: PeekabooBridgeConstants.protocolVersion,
        statelessClickVariants: true,
        exactWindowHeldPointerLifecycle: true,
        exactWindowDrag: true,
        nativeBrowserConnectionBinding: true,
        browserConnectionHandoff: true,
        producerBoundSnapshotReferences: true,
        scopedMenuBarActions: true,
        targetedClickAccessibilityValueDelivery: true,
        requestPinnedExactWindowScrollReceipt: true,
        backgroundCoordinateScroll: true,
        compositeTypeDelivery: true,
        exactFileDialogExecution: true,
        clipboardGuardedExactWindowHotkeys: true,
        preparedClipboardGuardedExactWindowHotkeys: true,
        processGenerationBoundElementMutations: true,
        setValueVerification: true,
        screenCaptureKitOwnershipDiagnostics: true)

    init(
        protocolVersion: PeekabooBridgeProtocolVersion,
        statelessClickVariants: Bool,
        exactWindowHeldPointerLifecycle: Bool,
        exactWindowDrag: Bool = false,
        nativeBrowserConnectionBinding: Bool = false,
        browserConnectionHandoff: Bool = false,
        producerBoundSnapshotReferences: Bool = false,
        scopedMenuBarActions: Bool = false,
        targetedClickAccessibilityValueDelivery: Bool = false,
        requestPinnedExactWindowScrollReceipt: Bool = false,
        backgroundCoordinateScroll: Bool = false,
        compositeTypeDelivery: Bool = false,
        exactFileDialogExecution: Bool = false,
        clipboardGuardedExactWindowHotkeys: Bool = false,
        preparedClipboardGuardedExactWindowHotkeys: Bool = false,
        processGenerationBoundElementMutations: Bool = false,
        setValueVerification: Bool = false,
        screenCaptureKitOwnershipDiagnostics: Bool = false)
    {
        self.protocolVersion = protocolVersion
        self.screenCaptureKitOwnershipDiagnostics = screenCaptureKitOwnershipDiagnostics
        self.statelessClickVariants = statelessClickVariants
        self.exactWindowHeldPointerLifecycle = exactWindowHeldPointerLifecycle
        self.exactWindowDrag = exactWindowDrag
        self.nativeBrowserConnectionBinding = nativeBrowserConnectionBinding
        self.browserConnectionHandoff = browserConnectionHandoff
        self.producerBoundSnapshotReferences = producerBoundSnapshotReferences
        self.scopedMenuBarActions = scopedMenuBarActions
        self.targetedClickAccessibilityValueDelivery = targetedClickAccessibilityValueDelivery
        self.requestPinnedExactWindowScrollReceipt = requestPinnedExactWindowScrollReceipt
        self.backgroundCoordinateScroll = backgroundCoordinateScroll
        self.compositeTypeDelivery = compositeTypeDelivery
        self.exactFileDialogExecution = exactFileDialogExecution
        self.clipboardGuardedExactWindowHotkeys = clipboardGuardedExactWindowHotkeys
        self.preparedClipboardGuardedExactWindowHotkeys = preparedClipboardGuardedExactWindowHotkeys
        self.processGenerationBoundElementMutations = processGenerationBoundElementMutations
        self.setValueVerification = setValueVerification
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
