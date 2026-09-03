import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

public struct PeekabooBridgeProtocolVersion: Codable, Sendable, Comparable, Hashable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static func < (lhs: PeekabooBridgeProtocolVersion, rhs: PeekabooBridgeProtocolVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        return lhs.minor < rhs.minor
    }
}

public enum PeekabooBridgeHostKind: String, Codable, Sendable, CaseIterable {
    case gui
    case helper
    case onDemand
    case inProcess
}

public enum PeekabooBridgePermissionKind: String, Codable, Sendable {
    case screenRecording
    case accessibility
    case postEvent
    case appleScript
}

public enum PeekabooBridgeOperation: String, Codable, Sendable, CaseIterable, Hashable {
    // Core
    case permissionsStatus
    case requestPostEventPermission
    case daemonStatus
    case daemonStop
    case agentExecutionTrace
    case observeProcessGeneration
    case certificationProducerAttestation
    // Browser MCP
    case browserStatus
    case browserConnect
    case browserDisconnect
    case browserExecute
    case browserSessionBootstrap
    case browserSessionControl
    // Capture
    case captureScreen
    case captureWindow
    case captureFrontmost
    case captureArea
    case detectElements
    case inspectAccessibilityTree
    case getFocusedElement
    case desktopObservation
    // Input & automation
    case click
    case type
    case typeActions
    case targetedTypeActions
    case exactWindowTargetedTypeActions
    case exactWindowPixelFocusType
    case foregroundModifierClick
    case setValue
    case performAction
    case scroll
    case targetedScroll
    case hotkey
    case targetedHotkey
    case exactWindowTargetedHotkey
    case createExactWindowHeldPointerOwner
    case beginExactWindowHeldPointer
    case releaseExactWindowHeldPointer
    case revokeExactWindowHeldPointer
    case disconnectExactWindowHeldPointerOwner
    case targetedClick
    case exactWindowTargetedClick
    case swipe
    case drag
    case moveMouse
    case waitForElement
    // Windows
    case listWindows
    case focusWindow
    case moveWindow
    case resizeWindow
    case setWindowBounds
    case closeWindow
    case backgroundCloseWindow
    case minimizeWindow
    case restoreWindow
    case maximizeWindow
    case getFocusedWindow
    // Applications
    case listApplications
    case findApplication
    case getFrontmostApplication
    case isApplicationRunning
    case launchApplication
    case launchApplicationWithOptions
    case relaunchApplicationWithOptions
    case activateApplication
    case quitApplication
    case hideApplication
    case unhideApplication
    case hideOtherApplications
    case showAllApplications
    // Menus
    case listMenus
    case listFrontmostMenus
    case clickMenuItem
    case clickMenuItemByName
    // Menu bar extras
    case listMenuExtras
    case clickMenuExtra
    case menuExtraOpenMenuFrame
    case listMenuBarItems
    case clickMenuBarItemNamed
    case clickMenuBarItemIndex
    // Dock
    case listDockItems
    case launchDockItem
    case rightClickDockItem
    case hideDock
    case showDock
    case isDockHidden
    case findDockItem
    // Dialogs
    case dialogFindActive
    case dialogClickButton
    case backgroundDialogClickButton
    case dialogEnterText
    case dialogHandleFile
    case dialogDismiss
    case dialogListElements
    case targetedDialogListElements
    case prepareDialogAction
    case exactDialogClickButton
    case exactDialogDismiss
    case exactDialogEnterText
    case exactDialogForceDismiss
    // Snapshots/cache
    case createSnapshot
    case storeDetectionResult
    case getDetectionResult
    case ownsSnapshot
    case storeScreenshot
    case storeObservationSnapshot
    case storeAnnotatedScreenshot
    case listSnapshots
    case getMostRecentSnapshot
    case invalidateImplicitLatestSnapshot
    case beginSnapshotMutation
    case finishSnapshotMutation
    case cleanSnapshot
    case cleanSnapshotsOlderThan
    case cleanAllSnapshots
    case _appleScriptProbe

    // swiftlint:disable cyclomatic_complexity
    /// Filters operations to cases a peer at `version` can decode.
    public static func compatible(
        _ operations: Set<Self>,
        with version: PeekabooBridgeProtocolVersion) -> Set<Self>
    {
        var compatible = operations
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 1) {
            compatible.remove(.targetedHotkey)
        }
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 2) {
            compatible.remove(.requestPostEventPermission)
        }
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 3) {
            compatible.remove(.setValue)
            compatible.remove(.performAction)
        }
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 4) {
            compatible.remove(.browserStatus)
            compatible.remove(.browserConnect)
            compatible.remove(.browserDisconnect)
            compatible.remove(.browserExecute)
        }
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 5) {
            compatible.remove(.desktopObservation)
        }
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 6) {
            compatible.remove(.targetedClick)
        }
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 7) {
            compatible.remove(.inspectAccessibilityTree)
        }
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 8) {
            compatible.remove(.targetedTypeActions)
        }
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 9) {
            compatible.remove(.launchApplicationWithOptions)
            compatible.remove(.relaunchApplicationWithOptions)
            compatible.remove(.invalidateImplicitLatestSnapshot)
            compatible.remove(.exactWindowTargetedClick)
        }
        if version < PeekabooBridgeConstants.composedInputParityVersion {
            compatible.remove(.exactWindowPixelFocusType)
            compatible.remove(.foregroundModifierClick)
        }
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 11) {
            compatible.remove(.targetedScroll)
            compatible.remove(.backgroundCloseWindow)
            compatible.remove(.backgroundDialogClickButton)
        }
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 14) {
            compatible.remove(.getFocusedElement)
        }
        if version < PeekabooBridgeConstants.processGenerationPinnedApplicationQuitVersion {
            compatible.remove(.quitApplication)
        }
        // 1.18 adds immutable capture-time bounds to destructive window receipts. Older hosts
        // would ignore that evidence, so new clients must not negotiate these operations down.
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 18) {
            compatible.subtract([
                .moveWindow,
                .resizeWindow,
                .setWindowBounds,
                .closeWindow,
                .backgroundCloseWindow,
                .minimizeWindow,
                .restoreWindow,
                .maximizeWindow,
            ])
        }
        if version < PeekabooBridgeProtocolVersion(major: 1, minor: 17) {
            compatible.remove(.exactWindowTargetedClick)
            compatible.remove(.exactWindowTargetedTypeActions)
            compatible.remove(.exactWindowTargetedHotkey)
        }
        if version < PeekabooBridgeConstants.atomicObservationSnapshotPublicationVersion {
            compatible.remove(.storeObservationSnapshot)
        }
        if version < PeekabooBridgeConstants.snapshotMutationLeaseVersion {
            compatible.remove(.beginSnapshotMutation)
            compatible.remove(.finishSnapshotMutation)
        }
        if version < PeekabooBridgeConstants.receiptPinnedDialogActionVersion {
            compatible.remove(.targetedDialogListElements)
            compatible.remove(.prepareDialogAction)
            compatible.remove(.exactDialogClickButton)
            compatible.remove(.exactDialogDismiss)
        }
        if version < PeekabooBridgeConstants.exactDialogInputExecutionVersion {
            compatible.remove(.exactDialogEnterText)
        }
        if version < PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion {
            compatible.remove(.exactDialogForceDismiss)
        }
        if version < PeekabooBridgeConstants.exactWindowHeldPointerLifecycleVersion {
            compatible.subtract([
                .createExactWindowHeldPointerOwner,
                .beginExactWindowHeldPointer,
                .releaseExactWindowHeldPointer,
                .revokeExactWindowHeldPointer,
                .disconnectExactWindowHeldPointerOwner,
            ])
        }
        if version < PeekabooBridgeConstants.agentExecutionTraceVersion {
            compatible.remove(.agentExecutionTrace)
        }
        if version < PeekabooBridgeConstants.processGenerationObservationVersion {
            compatible.remove(.observeProcessGeneration)
        }
        if version < PeekabooBridgeConstants.certificationProducerAttestationVersion {
            compatible.remove(.certificationProducerAttestation)
        }
        if version < PeekabooBridgeConstants.producerBoundSnapshotReferencesVersion {
            compatible.remove(.ownsSnapshot)
        }
        if version < PeekabooBridgeConstants.browserConnectionHandoffVersion {
            compatible.remove(.browserSessionBootstrap)
            compatible.remove(.browserSessionControl)
        }
        return compatible
    }
    // swiftlint:enable cyclomatic_complexity
}

public struct PeekabooBridgeClientIdentity: Codable, Sendable {
    public let bundleIdentifier: String?
    public let teamIdentifier: String?
    public let processIdentifier: pid_t
    public let hostname: String?

    public init(
        bundleIdentifier: String?,
        teamIdentifier: String?,
        processIdentifier: pid_t,
        hostname: String? = nil)
    {
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.processIdentifier = processIdentifier
        self.hostname = hostname
    }
}

public struct PeekabooBridgeHandshake: Codable, Sendable {
    public let protocolVersion: PeekabooBridgeProtocolVersion
    public let client: PeekabooBridgeClientIdentity
    public let requestedHostKind: PeekabooBridgeHostKind?
    public let operationClientInstanceID: UUID?
    public let replacingOperationSessionID: UUID?
    /// Additive raw capability offer. Old hosts ignore the field; old clients omit it.
    public let clientCapabilities: [String]?

    public init(
        protocolVersion: PeekabooBridgeProtocolVersion,
        client: PeekabooBridgeClientIdentity,
        requestedHostKind: PeekabooBridgeHostKind? = nil,
        operationClientInstanceID: UUID? = nil,
        replacingOperationSessionID: UUID? = nil,
        clientCapabilities: [String]? = nil)
    {
        self.protocolVersion = protocolVersion
        self.client = client
        self.requestedHostKind = requestedHostKind
        self.operationClientInstanceID = operationClientInstanceID
        self.replacingOperationSessionID = replacingOperationSessionID
        self.clientCapabilities = clientCapabilities
    }
}

/// Generation and exact-build evidence for the process serving a Bridge socket.
///
/// Every field is additive and optional at the handshake level so current clients continue to
/// decode older hosts. Installers should require the fields they need rather than inferring a
/// process from a socket path or a display version alone.
public struct PeekabooBridgeHostIdentity: Codable, Sendable, Equatable {
    public let processIdentifier: pid_t
    public let processStartIdentity: UInt64?
    /// Canonical decimal representation for consumers that cannot losslessly decode every UInt64 JSON number.
    public let processStartIdentityDecimal: String?
    public let bundleIdentifier: String?
    public let bundleShortVersion: String?
    public let bundleVersion: String?
    public let codeSignatureHash: String?
    /// Canonical 40-hex source revision embedded by a stamped build.
    public let sourceCommit: String?

    public init(
        processIdentifier: pid_t,
        processStartIdentity: UInt64?,
        bundleIdentifier: String?,
        bundleShortVersion: String?,
        bundleVersion: String?,
        codeSignatureHash: String?,
        sourceCommit: String? = nil)
    {
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.processStartIdentityDecimal = processStartIdentity.map(String.init)
        self.bundleIdentifier = bundleIdentifier
        self.bundleShortVersion = bundleShortVersion
        self.bundleVersion = bundleVersion
        self.codeSignatureHash = codeSignatureHash
        self.sourceCommit = sourceCommit
    }
}

/// Stable raw capability names advertised by current hosts. The wire representation remains an
/// array of strings so clients can safely ignore capabilities introduced by later builds.
public enum PeekabooBridgeHostCapability {
    public static let hostGenerationIdentity = "hostGenerationIdentity"
    public static let codeSignatureBuildIdentity = "codeSignatureBuildIdentity"
    public static let backgroundBridgeHost = "backgroundBridgeHost"
    public static let desktopObservationOCR = "desktopObservationOCR"
    public static let desktopObservationCaptureEngine = "desktopObservationCaptureEngine"
    // Old clients require successful preparation as well as implemented ownership support.
    public static let screenCaptureKitProcessOwnership = "screenCaptureKitProcessOwnership"
    public static let screenCaptureKitOwnershipEnforcement = "screenCaptureKitOwnershipEnforcement"
    public static let classicCaptureWithoutScreenCaptureKit = "classicCaptureWithoutScreenCaptureKit"
    public static let safeBackgroundApplicationLaunchNoOp = "safeBackgroundApplicationLaunchNoOp"
    public static let processGenerationPinnedApplicationActivation =
        "processGenerationPinnedApplicationActivation"
    public static let processGenerationPinnedApplicationHide =
        "processGenerationPinnedApplicationHide"
    public static let desktopActionOutcomeProjection = "desktopActionOutcomeProjection"
    public static let explicitSnapshotPublication = "explicitSnapshotPublication"
    public static let browserConnectionReceipts = "browserConnectionReceipts"
    public static let nativeBrowserConnectionBinding = "nativeBrowserConnectionBinding"
    public static let browserConnectionHandoff = "browserConnectionHandoff"
    public static let producerBoundSnapshotReferences = "producerBoundSnapshotReferences"
    public static let targetedClickAccessibilityValueDelivery = "targetedClickAccessibilityValueDelivery"
    public static let processGenerationBoundElementMutations = "processGenerationBoundElementMutations"
    public static let exactDialogInputExecution = "exactDialogInputExecution"
    public static let exactForcedDialogDismissExecution = "exactForcedDialogDismissExecution"
    public static let dialogInputFocusPolicy = "dialogInputFocusPolicy"
    public static let attestedOperationReceipts = "attestedOperationReceipts"
    public static let plannerInventoryTransport = "plannerInventoryTransport"
    public static let exactWindowHeldPointerLifecycle = "exactWindowHeldPointerLifecycle"
    public static let statelessClickVariants = "statelessClickVariants"
    public static let agentExecutionTrace = "agentExecutionTrace"
    public static let processGenerationObservation = "processGenerationObservation"
    public static let certificationProducerAttestation = "certificationProducerAttestation"
    public static let setValueResultTargetBinding = "setValueResultTargetBinding"
    public static let foregroundModifierClickSnapshotLease = "foregroundModifierClickSnapshotLease"
    public static let requestPinnedExactWindowScrollReceipt = "requestPinnedExactWindowScrollReceipt"
    public static let compositeTypeDelivery = "compositeTypeDelivery"
}

/// Stable raw capabilities a client may offer during handshake. Raw strings keep additions
/// decodable by already-shipped hosts while the offer prevents new 1.34 operations or semantics
/// from being advertised to already-shipped 1.34 clients.
public enum PeekabooBridgeClientCapability {
    public static let screenCaptureKitOwnershipDiagnostics = "screenCaptureKitOwnershipDiagnostics"
    public static let producerBoundSnapshotReferences = "producerBoundSnapshotReferences"
    public static let targetedClickAccessibilityValueDelivery = "targetedClickAccessibilityValueDelivery"
    public static let browserConnectionHandoff = "browserConnectionHandoff"
}

public struct PeekabooBridgeHandshakeResponse: Codable, Sendable {
    public let negotiatedVersion: PeekabooBridgeProtocolVersion
    public let hostKind: PeekabooBridgeHostKind
    public let build: String?
    public let supportedOperations: [PeekabooBridgeOperation]
    /// Current permission status of the host process (TCC grants).
    public let permissions: PermissionsStatus?
    /// Operations that are currently enabled given the host's permission status.
    public let enabledOperations: [PeekabooBridgeOperation]?
    /// Map of operation rawValue to the permissions it requires so clients can surface missing grants.
    public let permissionTags: [String: [PeekabooBridgePermissionKind]]
    /// Optional exact process/build identity for generation-safe readiness checks.
    public let hostIdentity: PeekabooBridgeHostIdentity?
    /// Optional raw capabilities of this host process and its launch mode.
    public let hostCapabilities: [String]?
    public let screenCaptureKitReadiness: ScreenCaptureKitReadiness?
    /// Ephemeral identity of the exact listener that served this handshake.
    public let operationAttestation: PeekabooBridgeListenerAttestation?
    /// Listener-signed, peer-bound replay session for protocol 1.29 requests.
    public let operationSessionAttestation: PeekabooBridgeOperationSessionAttestation?

    public init(
        negotiatedVersion: PeekabooBridgeProtocolVersion,
        hostKind: PeekabooBridgeHostKind,
        build: String?,
        supportedOperations: [PeekabooBridgeOperation],
        permissions: PermissionsStatus? = nil,
        enabledOperations: [PeekabooBridgeOperation]? = nil,
        permissionTags: [String: [PeekabooBridgePermissionKind]] = [:],
        hostIdentity: PeekabooBridgeHostIdentity? = nil,
        hostCapabilities: [String]? = nil,
        screenCaptureKitReadiness: ScreenCaptureKitReadiness? = nil,
        operationAttestation: PeekabooBridgeListenerAttestation? = nil,
        operationSessionAttestation: PeekabooBridgeOperationSessionAttestation? = nil)
    {
        self.negotiatedVersion = negotiatedVersion
        self.hostKind = hostKind
        self.build = build
        self.supportedOperations = supportedOperations
        self.permissions = permissions
        self.enabledOperations = enabledOperations
        self.permissionTags = permissionTags
        self.hostIdentity = hostIdentity
        self.hostCapabilities = hostCapabilities
        self.screenCaptureKitReadiness = screenCaptureKitReadiness
        self.operationAttestation = operationAttestation
        self.operationSessionAttestation = operationSessionAttestation
    }

    private enum CodingKeys: String, CodingKey {
        case negotiatedVersion
        case hostKind
        case build
        case supportedOperations
        case permissions
        case enabledOperations
        case permissionTags
        case hostIdentity
        case hostCapabilities
        case screenCaptureKitReadiness
        case operationAttestation
        case operationSessionAttestation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.negotiatedVersion = try container.decode(PeekabooBridgeProtocolVersion.self, forKey: .negotiatedVersion)
        self.hostKind = try container.decode(PeekabooBridgeHostKind.self, forKey: .hostKind)
        self.build = try container.decodeIfPresent(String.self, forKey: .build)
        self.supportedOperations = try container.decode([PeekabooBridgeOperation].self, forKey: .supportedOperations)
        self.permissions = try container.decodeIfPresent(PermissionsStatus.self, forKey: .permissions)
        self.enabledOperations = try container.decodeIfPresent(
            [PeekabooBridgeOperation].self,
            forKey: .enabledOperations)
        self.permissionTags = try container.decodeIfPresent(
            [String: [PeekabooBridgePermissionKind]].self,
            forKey: .permissionTags) ?? [:]
        self.hostIdentity = try container.decodeIfPresent(PeekabooBridgeHostIdentity.self, forKey: .hostIdentity)
        self.hostCapabilities = try container.decodeIfPresent([String].self, forKey: .hostCapabilities)
        self.screenCaptureKitReadiness = try container.decodeIfPresent(
            ScreenCaptureKitReadiness.self, forKey: .screenCaptureKitReadiness)
        self.operationAttestation = try container.decodeIfPresent(
            PeekabooBridgeListenerAttestation.self,
            forKey: .operationAttestation)
        self.operationSessionAttestation = try container.decodeIfPresent(
            PeekabooBridgeOperationSessionAttestation.self,
            forKey: .operationSessionAttestation)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.negotiatedVersion, forKey: .negotiatedVersion)
        try container.encode(self.hostKind, forKey: .hostKind)
        try container.encodeIfPresent(self.build, forKey: .build)
        try container.encode(self.supportedOperations, forKey: .supportedOperations)
        try container.encodeIfPresent(self.permissions, forKey: .permissions)
        try container.encodeIfPresent(self.enabledOperations, forKey: .enabledOperations)
        if !self.permissionTags.isEmpty {
            try container.encode(self.permissionTags, forKey: .permissionTags)
        }
        try container.encodeIfPresent(self.hostIdentity, forKey: .hostIdentity)
        if let hostCapabilities, !hostCapabilities.isEmpty {
            try container.encode(hostCapabilities, forKey: .hostCapabilities)
        }
        try container.encodeIfPresent(self.screenCaptureKitReadiness, forKey: .screenCaptureKitReadiness)
        try container.encodeIfPresent(self.operationAttestation, forKey: .operationAttestation)
        try container.encodeIfPresent(
            self.operationSessionAttestation,
            forKey: .operationSessionAttestation)
    }
}

public enum PeekabooBridgeErrorCode: String, Codable, Sendable {
    case permissionDenied
    case notFound
    case timeout
    case invalidRequest
    case operationNotSupported
    case serverBusy
    case versionMismatch
    case unauthorizedClient
    case decodingFailed
    case internalError
}

public enum PeekabooBridgeErrorKind: String, Codable, Sendable {
    case appNotFound
    case windowNotFound
    case elementNotFound
    case menuNotFound
    case menuItemNotFound
    case dockNotFound
    case dockListNotFound
    case dockItemNotFound
    case positionNotFound
    case snapshotNotFound
    case snapshotStale
}

public struct PeekabooBridgeErrorEnvelope: Codable, Sendable, LocalizedError {
    public static let standardizedErrorContextPrefix = "standard_error:"
    public let code: PeekabooBridgeErrorCode
    public let message: String
    public let details: String?
    public let permission: PeekabooBridgePermissionKind?
    public let kind: PeekabooBridgeErrorKind?
    public let context: String?
    public let operationMayHaveCompleted: Bool
    public let actionOutcome: DesktopActionOutcome.Projection?
    public let actionFailureHint: String?
    public let actionFailureCauseDescription: String?
    public let actionTargetReceipt: DesktopActionTargetReceipt?
    public let actionSelectedLeafEvidence: [DesktopSelectedLeafEvidence]?
    public private(set) var screenCaptureKitOwnershipDiagnostic: ScreenCaptureKitOwnershipDiagnostic?

    func removingScreenCaptureKitDiagnostic() -> Self {
        var compatible = self
        compatible.screenCaptureKitOwnershipDiagnostic = nil
        return compatible
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case details
        case permission
        case kind
        case context
        case operationMayHaveCompleted
        case actionOutcome
        case actionFailureHint
        case actionFailureCauseDescription
        case actionTargetReceipt
        case actionSelectedLeafEvidence
        case screenCaptureKitOwnershipDiagnostic
    }

    public init(
        code: PeekabooBridgeErrorCode,
        message: String,
        details: String? = nil,
        permission: PeekabooBridgePermissionKind? = nil,
        kind: PeekabooBridgeErrorKind? = nil,
        context: String? = nil,
        operationMayHaveCompleted: Bool = false,
        screenCaptureKitOwnershipDiagnostic: ScreenCaptureKitOwnershipDiagnostic? = nil)
    {
        self.code = code
        self.message = message
        self.details = details
        self.permission = permission
        self.kind = kind
        self.context = context
        self.operationMayHaveCompleted = operationMayHaveCompleted
        self.actionOutcome = nil
        self.actionFailureHint = nil
        self.actionFailureCauseDescription = nil
        self.actionTargetReceipt = nil
        self.actionSelectedLeafEvidence = nil
        self.screenCaptureKitOwnershipDiagnostic = screenCaptureKitOwnershipDiagnostic
    }

    public init(
        code: PeekabooBridgeErrorCode,
        actionFailure: DesktopActionFailure,
        details: String? = nil,
        permission: PeekabooBridgePermissionKind? = nil,
        kind: PeekabooBridgeErrorKind? = nil,
        context: String? = nil)
    {
        self.code = code
        self.message = actionFailure.message
        self.details = details
        self.permission = permission
        self.kind = kind
        self.context = context ?? actionFailure.standardErrorCode.map {
            Self.standardizedErrorContextPrefix + $0.rawValue
        }
        self.operationMayHaveCompleted = actionFailure.outcome.projection.mutationDispatched
        self.actionOutcome = actionFailure.outcome.projection
        self.actionFailureHint = actionFailure.hint
        self.actionFailureCauseDescription = actionFailure.causeDescription
        self.actionTargetReceipt = actionFailure.targetReceipt
        self.actionSelectedLeafEvidence = actionFailure.selectedLeafEvidence
        self.screenCaptureKitOwnershipDiagnostic = actionFailure.screenCaptureKitOwnershipDiagnostic
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decode(PeekabooBridgeErrorCode.self, forKey: .code)
        self.message = try container.decode(String.self, forKey: .message)
        self.details = try container.decodeIfPresent(String.self, forKey: .details)
        self.permission = try container.decodeIfPresent(PeekabooBridgePermissionKind.self, forKey: .permission)
        self.context = try container.decodeIfPresent(String.self, forKey: .context)
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind)
        self.kind = rawKind.flatMap(PeekabooBridgeErrorKind.init(rawValue:))
        let encodedOperationMayHaveCompleted = try container.decodeIfPresent(
            Bool.self,
            forKey: .operationMayHaveCompleted)
        self.screenCaptureKitOwnershipDiagnostic = try container.decodeIfPresent(
            ScreenCaptureKitOwnershipDiagnostic.self, forKey: .screenCaptureKitOwnershipDiagnostic)
        self.actionOutcome = try container.decodeIfPresent(
            DesktopActionOutcome.Projection.self,
            forKey: .actionOutcome)
        self.actionFailureHint = try container.decodeIfPresent(String.self, forKey: .actionFailureHint)
        self.actionFailureCauseDescription = try container.decodeIfPresent(
            String.self,
            forKey: .actionFailureCauseDescription)
        self.actionTargetReceipt = try container.decodeIfPresent(
            DesktopActionTargetReceipt.self,
            forKey: .actionTargetReceipt)
        self.actionSelectedLeafEvidence = try container.decodeIfPresent(
            [DesktopSelectedLeafEvidence].self,
            forKey: .actionSelectedLeafEvidence)
        if let actionOutcome = self.actionOutcome {
            guard !actionOutcome.outcome.isConfirmed,
                  self.actionSelectedLeafEvidence == nil || actionOutcome.mutationDispatched,
                  self.actionSelectedLeafEvidence?.isEmpty != true,
                  self.actionSelectedLeafEvidence?.allSatisfy(\.isCanonical) != false
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .actionOutcome,
                    in: container,
                    debugDescription: "A Bridge error envelope carries inconsistent action failure evidence")
            }
            let expected = actionOutcome.mutationDispatched
            if let encodedOperationMayHaveCompleted,
               encodedOperationMayHaveCompleted != expected
            {
                throw DecodingError.dataCorruptedError(
                    forKey: .operationMayHaveCompleted,
                    in: container,
                    debugDescription: "Compatibility field contradicts the canonical desktop action outcome")
            }
            self.operationMayHaveCompleted = expected
        } else {
            guard self.actionFailureHint == nil,
                  self.actionFailureCauseDescription == nil,
                  self.actionTargetReceipt == nil,
                  self.actionSelectedLeafEvidence == nil
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .actionOutcome,
                    in: container,
                    debugDescription: "Desktop action failure context requires a canonical outcome")
            }
            self.operationMayHaveCompleted = encodedOperationMayHaveCompleted ?? false
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.code, forKey: .code)
        try container.encode(self.message, forKey: .message)
        try container.encodeIfPresent(self.details, forKey: .details)
        try container.encodeIfPresent(self.permission, forKey: .permission)
        try container.encodeIfPresent(self.kind?.rawValue, forKey: .kind)
        try container.encodeIfPresent(self.context, forKey: .context)
        if self.operationMayHaveCompleted {
            try container.encode(true, forKey: .operationMayHaveCompleted)
        }
        try container.encodeIfPresent(
            self.screenCaptureKitOwnershipDiagnostic,
            forKey: .screenCaptureKitOwnershipDiagnostic)
        try container.encodeIfPresent(self.actionOutcome, forKey: .actionOutcome)
        try container.encodeIfPresent(self.actionFailureHint, forKey: .actionFailureHint)
        try container.encodeIfPresent(
            self.actionFailureCauseDescription,
            forKey: .actionFailureCauseDescription)
        try container.encodeIfPresent(self.actionTargetReceipt, forKey: .actionTargetReceipt)
        try container.encodeIfPresent(
            self.actionSelectedLeafEvidence,
            forKey: .actionSelectedLeafEvidence)
    }

    public var errorDescription: String? {
        self.message
    }

    public var standardizedErrorCode: StandardErrorCode? {
        guard let context,
              context.hasPrefix(Self.standardizedErrorContextPrefix)
        else { return nil }
        return StandardErrorCode(rawValue: String(context.dropFirst(Self.standardizedErrorContextPrefix.count)))
    }

    public var desktopActionFailure: DesktopActionFailure? {
        guard let actionOutcome else { return nil }
        return DesktopActionFailure(
            outcome: actionOutcome.outcome,
            message: self.message,
            hint: self.actionFailureHint,
            causeDescription: self.actionFailureCauseDescription,
            standardErrorCode: self.standardizedErrorCode,
            targetReceipt: self.actionTargetReceipt,
            selectedLeafEvidence: self.actionSelectedLeafEvidence,
            screenCaptureKitOwnershipDiagnostic: self.screenCaptureKitOwnershipDiagnostic)
    }
}

extension PeekabooBridgeErrorEnvelope: PendingSnapshotFailureDispositionProviding {
    public var mayCompleteSnapshotWorkAfterFailure: Bool {
        if self.operationMayHaveCompleted {
            return true
        }
        return switch self.code {
        case .timeout:
            true
        case .internalError:
            self.message == "Bridge host returned no response"
        case .decodingFailed:
            self.message == "Bridge host returned an invalid response"
        default:
            false
        }
    }
}

extension PeekabooBridgeErrorEnvelope: ApplicationLifecycleRefusalMetadataProviding {
    public var applicationLifecycleRefusalHint: String? {
        ApplicationLifecycleRefusalError.hint(forBridgeContext: self.context)
    }

    public var applicationLifecycleFailureMetadata: ApplicationLifecycleFailureMetadata? {
        if let hint = self.applicationLifecycleRefusalHint {
            return ApplicationLifecycleFailureMetadata(
                effect: "refused",
                errorCode: .interactionFailed,
                hint: hint,
                retrySafe: true,
                mutationDispatched: false)
        }
        guard self.context == ApplicationLifecycleReadOnlyFailureError.bridgeContext else { return nil }
        return ApplicationLifecycleFailureMetadata(
            effect: "unverifiable",
            errorCode: self.code == .timeout ? .timeout : .unknownError,
            retrySafe: true,
            mutationDispatched: false)
    }
}
