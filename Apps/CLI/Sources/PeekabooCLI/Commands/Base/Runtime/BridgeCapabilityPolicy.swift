import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

enum BridgeCapabilityPolicy {
    struct ObservationCapabilities: Equatable {
        let desktopObservation: Bool
        let desktopObservationOCR: Bool
        let desktopObservationCaptureEngine: Bool
        let exactWindowROIObservation: Bool
    }

    static func supportsRemoteRequirements(
        for handshake: PeekabooBridgeHandshakeResponse,
        options: CommandRuntimeOptions
    ) -> Bool {
        let defersScreenRecording = self.defersRemoteScreenRecordingPermission(options: options)
        let supportsCapture = defersScreenRecording
            ? handshake.supportedOperations.contains(.captureScreen)
            : self.supportsOperation(.captureScreen, for: handshake)
        if options.requiresScreenCapturePermission || options.requiresSilentCapture,
           !supportsCapture {
            return false
        }

        // Never select a host that explicitly reports it lacks a TCC permission this command
        // actually needs (e.g. a stale GUI host with screenRecording=false serving bridge.sock for
        // a capture command); rejecting here lets the resolver fall through to a permissioned
        // daemon. Only the permissions the command uses are required, so a non-capture command is
        // not blocked by a missing Screen Recording grant. Hosts that omit the permission report
        // entirely stay eligible for backward compatibility.
        guard self.explicitlyMissingRemotePermissions(for: handshake, options: options).isEmpty else {
            return false
        }

        if options.requiresSilentCapture, !self.supportsSilentCapture(for: handshake) {
            return false
        }

        if !self.supportsObservationRequirements(for: handshake, options: options) {
            return false
        }

        if !self.supportsInteractionRequirements(for: handshake, options: options) {
            return false
        }

        if options.requiresElementActions, !self.supportsElementActions(for: handshake) {
            return false
        }

        if options.requiresInspectAccessibilityTree, !self.supportsInspectAccessibilityTree(for: handshake) {
            return false
        }

        if options.requiresBrowserMCP, !self.supportsBrowserMCP(for: handshake) {
            return false
        }

        if options.requiresApplicationLaunchOptions, !self.supportsApplicationLaunchOptions(for: handshake) {
            return false
        }

        if options.requiresSafeBackgroundApplicationLaunchNoOp,
           !self.supportsSafeBackgroundApplicationLaunchNoOp(for: handshake) {
            return false
        }

        if options.requiresNewApplicationInstanceLaunch,
           !self.supportsNewApplicationInstanceLaunch(for: handshake) {
            return false
        }

        if options.requiresApplicationWindowReadiness,
           !self.supportsApplicationWindowReadiness(for: handshake) {
            return false
        }

        if options.requiresApplicationRelaunch, !self.supportsApplicationRelaunch(for: handshake) {
            return false
        }

        if options.requiresSurvivingApplicationHost, handshake.hostKind != .onDemand {
            return false
        }

        if options.requiresProcessGenerationPinnedApplicationQuit,
           !self.supportsProcessGenerationPinnedApplicationQuit(for: handshake) {
            return false
        }

        if options.requiresProcessGenerationPinnedHotkeys,
           !self.supportsProcessGenerationPinnedHotkeys(for: handshake) {
            return false
        }

        if options.requiresProcessGenerationPinnedTypeActions,
           !self.supportsProcessGenerationPinnedTypeActions(for: handshake) {
            return false
        }

        if options.requiresProcessGenerationPinnedClicks,
           !self.supportsProcessGenerationPinnedClicks(for: handshake) {
            return false
        }

        if options.requiresTargetedClickAccessibilityValueDelivery,
           !self.supportsTargetedClickAccessibilityValueDelivery(for: handshake) {
            return false
        }

        if options.requiresHostApplicationInventory, !self.supportsHostApplicationInventory(for: handshake) {
            return false
        }

        if options.requiresImplicitSnapshotInvalidation || options.usesPerToolSnapshotInvalidation,
           !self.supportsImplicitSnapshotInvalidation(for: handshake) {
            return false
        }

        if options.requiresProducerBoundSnapshotReferences,
           !self.supportsProducerBoundSnapshotReferences(for: handshake) {
            return false
        }

        return true
    }

    private static func supportsObservationRequirements(
        for handshake: PeekabooBridgeHandshakeResponse,
        options: CommandRuntimeOptions
    ) -> Bool {
        let capabilities = self.observationCapabilities(for: handshake, options: options)
        if options.requiresDesktopObservation, !capabilities.desktopObservation {
            return false
        }
        if options.requiresDesktopObservationOCR, !capabilities.desktopObservationOCR {
            return false
        }
        if options.requiresCaptureEnginePreferenceCapability,
           !capabilities.desktopObservationCaptureEngine {
            return false
        }
        if options.requiresScreenCaptureKitOwnerCapability,
           !self.supportsScreenCaptureKitProcessOwnership(for: handshake) {
            return false
        }
        if options.requiresExactWindowROIObservation, !capabilities.exactWindowROIObservation {
            return false
        }
        if options.requiresExplicitSnapshotPublication,
           !self.supportsExplicitSnapshotPublication(for: handshake) {
            return false
        }
        return true
    }

    static func observationCapabilities(
        for handshake: PeekabooBridgeHandshakeResponse,
        options: CommandRuntimeOptions
    ) -> ObservationCapabilities {
        let usesRequestScopedEngine = options.usesPerToolSnapshotInvalidation
        guard self.defersClassicScreenRecordingPermission(options: options) || usesRequestScopedEngine else {
            return ObservationCapabilities(
                desktopObservation: self.supportsDesktopObservation(for: handshake),
                desktopObservationOCR: self.supportsDesktopObservationOCR(for: handshake),
                desktopObservationCaptureEngine: self.supportsDesktopObservationCaptureEngine(for: handshake),
                exactWindowROIObservation: self.supportsExactWindowROIObservation(for: handshake)
            )
        }

        let supportsObservation = handshake.negotiatedVersion >=
            PeekabooBridgeProtocolVersion(major: 1, minor: 5) &&
            handshake.supportedOperations.contains(.desktopObservation)
        return ObservationCapabilities(
            desktopObservation: supportsObservation,
            desktopObservationOCR: supportsObservation &&
                handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.desktopObservationOCR) == true,
            desktopObservationCaptureEngine: supportsObservation &&
                handshake.hostCapabilities?.contains(
                    PeekabooBridgeHostCapability.desktopObservationCaptureEngine
                ) == true,
            exactWindowROIObservation: supportsObservation &&
                handshake.negotiatedVersion >= PeekabooBridgeConstants.exactWindowROIObservationVersion &&
                self.supportsOperation(.storeObservationSnapshot, for: handshake)
        )
    }

    private static func supportsInteractionRequirements(
        for handshake: PeekabooBridgeHandshakeResponse,
        options: CommandRuntimeOptions
    ) -> Bool {
        if options.requiresProcessGenerationPinnedApplicationActivation,
           !self.supportsProcessGenerationPinnedApplicationActivation(for: handshake) {
            return false
        }
        if options.requiresProcessGenerationPinnedApplicationHide,
           !self.supportsProcessGenerationPinnedApplicationHide(for: handshake) {
            return false
        }
        if options.requiresTargetedFocusedElement, !self.supportsTargetedFocusedElement(for: handshake) {
            return false
        }
        if options.requiresExactWindowTargetedKeyboard,
           !self.supportsExactWindowTargetedKeyboard(for: handshake) {
            return false
        }
        if options.requiresPinnedWindowMutations, !self.supportsPinnedWindowMutations(for: handshake) {
            return false
        }
        if options.requiresWindowRestore, !self.supportsOperation(.restoreWindow, for: handshake) {
            return false
        }
        if options.requiresExactWindowTargetedClicks,
           !self.supportsExactWindowTargetedClicks(for: handshake) {
            return false
        }
        if options.requiresStatelessClickVariants,
           handshake.negotiatedVersion < PeekabooBridgeConstants.statelessClickVariantVersion {
            return false
        }
        if options.requiresBackgroundStatelessClickVariants,
           !self.supportsStatelessClickVariants(for: handshake) {
            return false
        }
        if options.requiresForegroundModifierClickSnapshotLease,
           !self.supportsForegroundModifierClick(for: handshake) {
            return false
        }
        if options.requiresExactWindowPixelFocusTyping,
           !self.supportsExactWindowPixelFocusTyping(for: handshake) {
            return false
        }
        if options.requiresTargetedScroll,
           !self.supportsTargetedScroll(for: handshake) ||
           !self.supportsRequestPinnedExactWindowScrollReceipt(for: handshake) {
            return false
        }
        if options.requiresPostEventPermission, handshake.permissions?.postEvent != true {
            return false
        }
        if options.requiresAccessibilityPermission, handshake.permissions?.accessibility != true {
            return false
        }
        if options.requiresLongPressClick, !self.supportsLongPressClicks(for: handshake) {
            return false
        }
        if options.requiresBackgroundWindowClose,
           !self.supportsOperation(.backgroundCloseWindow, for: handshake) {
            return false
        }
        if options.requiresBackgroundDialogClick,
           !self.supportsOperation(.backgroundDialogClickButton, for: handshake) {
            return false
        }
        if options.requiresTargetedDialogList,
           !self.supportsOperation(.targetedDialogListElements, for: handshake) {
            return false
        }
        if options.requiresPreparedDialogClick,
           !self.supportsOperation(.prepareDialogAction, for: handshake) ||
           !self.supportsOperation(.exactDialogClickButton, for: handshake) {
            return false
        }
        if options.requiresPreparedDialogDismiss,
           !self.supportsOperation(.prepareDialogAction, for: handshake) ||
           !self.supportsOperation(.exactDialogDismiss, for: handshake) {
            return false
        }
        return true
    }

    /// TCC permissions the current command needs from a remote host, derived from the operations
    /// it will use. The host's own `permissionTags` contract wins; operations without a tag fall
    /// back to the client-side mapping so hosts that predate permission tags are still covered.
    static func requiredRemotePermissions(
        for handshake: PeekabooBridgeHandshakeResponse,
        options: CommandRuntimeOptions
    ) -> Set<PeekabooBridgePermissionKind> {
        var required: Set<PeekabooBridgePermissionKind> = []
        for operation in self.requiredRemoteOperations(options: options) {
            required.formUnion(self.requiredPermissions(for: operation, handshake: handshake))
        }
        return required
    }

    /// Required permissions the host explicitly reports as not granted. A host that omits the
    /// permission report (`permissions == nil`, older protocol builds) is trusted and never
    /// rejected here; only an explicit `false` counts as missing.
    static func explicitlyMissingRemotePermissions(
        for handshake: PeekabooBridgeHandshakeResponse,
        options: CommandRuntimeOptions
    ) -> Set<PeekabooBridgePermissionKind> {
        guard handshake.permissions != nil else { return [] }
        var missing = self.requiredRemotePermissions(for: handshake, options: options)
            .subtracting(self.grantedPermissions(from: handshake.permissions))
        if self.defersRemoteScreenRecordingPermission(options: options) {
            missing.remove(.screenRecording)
        }
        return missing
    }

    /// Operations whose required TCC permissions the current command must find granted on a remote
    /// host, based on declared runtime options. This is a permission gate only: capability (does the
    /// host support the operation) is enforced separately by `supportsRemoteRequirements`. Screen
    /// Recording is demanded ONLY for commands that actually acquire screen pixels
    /// (`requiresScreenCapturePermission`); non-capture commands are never rejected for lacking it.
    /// Operations that require no permission (app launch/relaunch, inventory, exact-window clicks)
    /// are intentionally absent — they are already capability-gated and add nothing here.
    private static func requiredRemoteOperations(options: CommandRuntimeOptions) -> [PeekabooBridgeOperation] {
        // Permission-request commands intentionally target hosts that still lack grants.
        guard !options.requestsHostPermissionGrant else { return [] }

        var operations: [PeekabooBridgeOperation] = []
        if options.requiresScreenCapturePermission {
            operations.append(.captureScreen)
        }
        if options.requiresElementActions {
            operations.append(contentsOf: [.setValue, .performAction])
        }
        if options.requiresInspectAccessibilityTree {
            operations.append(.inspectAccessibilityTree)
        }
        if options.requiresBackgroundWindowClose {
            operations.append(.backgroundCloseWindow)
        }
        if options.requiresWindowRestore {
            operations.append(.restoreWindow)
        }
        if options.requiresBackgroundDialogClick {
            operations.append(.backgroundDialogClickButton)
        }
        if options.requiresTargetedDialogList {
            operations.append(.targetedDialogListElements)
        }
        if options.requiresPreparedDialogClick {
            operations.append(contentsOf: [.prepareDialogAction, .exactDialogClickButton])
        }
        if options.requiresPreparedDialogDismiss {
            operations.append(contentsOf: [.prepareDialogAction, .exactDialogDismiss])
        }
        if options.requiresTargetedFocusedElement {
            operations.append(.getFocusedElement)
        }
        if options.requiresExactWindowTargetedKeyboard {
            operations.append(contentsOf: [.exactWindowTargetedTypeActions, .exactWindowTargetedHotkey])
        }
        return operations
    }

    static func supportsOperation(
        _ operation: PeekabooBridgeOperation,
        for handshake: PeekabooBridgeHandshakeResponse
    ) -> Bool {
        handshake.supportedOperations.contains(operation) &&
            (handshake.enabledOperations ?? handshake.supportedOperations).contains(operation)
    }

    static func supportsForegroundModifierClick(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.composedInputParityVersion &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.foregroundModifierClickSnapshotLease
            ) == true &&
            self.supportsOperation(.foregroundModifierClick, for: handshake)
    }

    static func supportsExactWindowPixelFocusTyping(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.composedInputParityVersion &&
            self.supportsOperation(.exactWindowPixelFocusType, for: handshake)
    }

    static func supportsTargetedHotkeys(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        self.targetedHotkeyAvailability(for: handshake).isEnabled
    }

    static func supportsTargetedTypeActions(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        self.targetedTypeAvailability(for: handshake).isEnabled
    }

    static func supportsTargetedClicks(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        self.targetedClickAvailability(for: handshake).isEnabled
    }

    static func supportsLongPressClicks(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        guard handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 10),
              handshake.supportedOperations.contains(.click)
        else {
            return false
        }
        return (handshake.enabledOperations ?? handshake.supportedOperations).contains(.click)
    }

    static func supportsApplicationLaunchOptions(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 9) &&
            handshake.supportedOperations.contains(.launchApplicationWithOptions)
    }

    static func supportsSafeBackgroundApplicationLaunchNoOp(
        for handshake: PeekabooBridgeHandshakeResponse
    ) -> Bool {
        self.supportsApplicationLaunchOptions(for: handshake) &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.safeBackgroundApplicationLaunchNoOp
            ) == true
    }

    static func supportsNewApplicationInstanceLaunch(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 13) &&
            handshake.supportedOperations.contains(.launchApplicationWithOptions)
    }

    static func supportsApplicationWindowReadiness(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 13) &&
            handshake.supportedOperations.contains(.launchApplicationWithOptions)
    }

    static func supportsApplicationRelaunch(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        guard handshake.hostKind == .onDemand,
              handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 18),
              handshake.supportedOperations.contains(.relaunchApplicationWithOptions)
        else {
            return false
        }

        let enabledOperations = handshake.enabledOperations ?? handshake.supportedOperations
        return enabledOperations.contains(.relaunchApplicationWithOptions)
    }

    static func supportsProcessGenerationPinnedApplicationActivation(
        for handshake: PeekabooBridgeHandshakeResponse
    ) -> Bool {
        self.supportsOperation(.activateApplication, for: handshake) &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.processGenerationPinnedApplicationActivation
            ) == true
    }

    static func supportsProcessGenerationPinnedApplicationHide(
        for handshake: PeekabooBridgeHandshakeResponse
    ) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.processGenerationPinnedApplicationHideVersion &&
            self.supportsOperation(.hideApplication, for: handshake) &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.attestedOperationReceipts
            ) == true &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.processGenerationPinnedApplicationHide
            ) == true
    }

    static func supportsHostApplicationInventory(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        guard handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 0),
              handshake.supportedOperations.contains(.listApplications)
        else {
            return false
        }

        let enabledOperations = handshake.enabledOperations ?? handshake.supportedOperations
        return enabledOperations.contains(.listApplications)
    }

    static func supportsImplicitSnapshotInvalidation(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        guard handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 9),
              handshake.supportedOperations.contains(.invalidateImplicitLatestSnapshot)
        else {
            return false
        }

        let enabledOperations = handshake.enabledOperations ?? handshake.supportedOperations
        return enabledOperations.contains(.invalidateImplicitLatestSnapshot)
    }

    static func supportsSnapshotMutationLeases(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        guard handshake.negotiatedVersion >= PeekabooBridgeConstants.snapshotMutationLeaseVersion,
              handshake.supportedOperations.contains(.beginSnapshotMutation),
              handshake.supportedOperations.contains(.finishSnapshotMutation)
        else {
            return false
        }

        let enabledOperations = handshake.enabledOperations ?? handshake.supportedOperations
        return enabledOperations.contains(.beginSnapshotMutation) &&
            enabledOperations.contains(.finishSnapshotMutation)
    }

    static func supportsExplicitSnapshotPublication(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.explicitSnapshotPublicationVersion &&
            handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.explicitSnapshotPublication) == true
    }

    static func supportsProducerBoundSnapshotReferences(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.producerBoundSnapshotReferencesVersion &&
            handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.attestedOperationReceipts) == true &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.producerBoundSnapshotReferences
            ) == true &&
            self.supportsOperation(.ownsSnapshot, for: handshake)
    }

    static func supportsTargetedClickAccessibilityValueDelivery(
        for handshake: PeekabooBridgeHandshakeResponse
    ) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.targetedClickAccessibilityValueDeliveryVersion &&
            handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.attestedOperationReceipts) == true &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.targetedClickAccessibilityValueDelivery
            ) == true &&
            self.supportsOperation(.targetedClick, for: handshake)
    }

    static func supportsElementActions(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 3) &&
            handshake.supportedOperations.contains(.setValue) &&
            handshake.supportedOperations.contains(.performAction)
    }

    static func supportsDesktopObservation(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 5) &&
            self.supportsOperation(.desktopObservation, for: handshake)
    }

    static func supportsDesktopObservationOCR(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        self.supportsDesktopObservation(for: handshake) &&
            handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.desktopObservationOCR) == true
    }

    static func supportsDesktopObservationCaptureEngine(
        for handshake: PeekabooBridgeHandshakeResponse
    ) -> Bool {
        self.supportsDesktopObservation(for: handshake) &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.desktopObservationCaptureEngine
            ) == true
    }

    static func supportsScreenCaptureKitProcessOwnership(
        for handshake: PeekabooBridgeHandshakeResponse
    ) -> Bool {
        handshake.supportedOperations.contains(.desktopObservation) &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership
            ) == true
    }

    private static func defersClassicScreenRecordingPermission(options: CommandRuntimeOptions) -> Bool {
        options.requiresScreenCaptureKitOwnerCapability &&
            ObservationCommandSupport.captureEnginePreference(
                cliValue: options.captureEnginePreference,
                configuredValue: nil
            ) == .legacy
    }

    private static func defersRemoteScreenRecordingPermission(options: CommandRuntimeOptions) -> Bool {
        self.defersClassicScreenRecordingPermission(options: options) || options.usesPerToolSnapshotInvalidation
    }

    static func supportsExactWindowROIObservation(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        guard handshake.negotiatedVersion >= PeekabooBridgeConstants.exactWindowROIObservationVersion else {
            return false
        }
        return [
            PeekabooBridgeOperation.desktopObservation,
            .storeObservationSnapshot,
        ].allSatisfy { self.supportsOperation($0, for: handshake) }
    }

    static func supportsSilentCapture(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 12) &&
            handshake.supportedOperations.contains(.captureScreen)
    }

    static func supportsTargetedFocusedElement(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 14) &&
            self.supportsOperation(.getFocusedElement, for: handshake)
    }

    static func supportsExactWindowTargetedKeyboard(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 17) &&
            self.supportsOperation(.exactWindowTargetedTypeActions, for: handshake) &&
            self.supportsOperation(.exactWindowTargetedHotkey, for: handshake)
    }

    static func supportsPinnedWindowMutations(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 18)
    }

    static func supportsProcessGenerationPinnedApplicationQuit(
        for handshake: PeekabooBridgeHandshakeResponse
    ) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.processGenerationPinnedApplicationQuitVersion &&
            self.supportsOperation(.quitApplication, for: handshake)
    }

    static func supportsProcessGenerationPinnedHotkeys(
        for handshake: PeekabooBridgeHandshakeResponse
    ) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.processGenerationPinnedHotkeyVersion &&
            self.supportsOperation(.targetedHotkey, for: handshake)
    }

    static func supportsProcessGenerationPinnedTypeActions(
        for handshake: PeekabooBridgeHandshakeResponse
    ) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.processGenerationPinnedInteractionVersion &&
            self.supportsOperation(.targetedTypeActions, for: handshake)
    }

    static func supportsProcessGenerationPinnedClicks(
        for handshake: PeekabooBridgeHandshakeResponse
    ) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.processGenerationPinnedInteractionVersion &&
            self.supportsOperation(.targetedClick, for: handshake)
    }

    static func supportsInspectAccessibilityTree(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 7) &&
            handshake.supportedOperations.contains(.inspectAccessibilityTree)
    }

    static func supportsBrowserMCP(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.hostKind == .onDemand &&
            handshake.negotiatedVersion >= PeekabooBridgeConstants.browserConnectionReceiptVersion &&
            handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.browserConnectionReceipts) == true &&
            handshake.supportedOperations.contains(.browserStatus) &&
            handshake.supportedOperations.contains(.browserConnect) &&
            handshake.supportedOperations.contains(.browserDisconnect) &&
            handshake.supportedOperations.contains(.browserExecute)
    }

    static func supportsPostEventPermissionRequest(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 2) &&
            handshake.supportedOperations.contains(.requestPostEventPermission)
    }

    static func targetedHotkeyAvailability(for handshake: PeekabooBridgeHandshakeResponse)
    -> (isEnabled: Bool, unavailableReason: String?, missingPermissions: Set<PeekabooBridgePermissionKind>) {
        guard
            handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 1),
            handshake.supportedOperations.contains(.targetedHotkey)
        else {
            return (false, nil, [])
        }

        let enabledOperations = handshake.enabledOperations ?? handshake.supportedOperations
        if enabledOperations.contains(.targetedHotkey) {
            return (true, nil, [])
        }

        let missingPermissions = missingPermissions(for: .targetedHotkey, handshake: handshake)
        guard !missingPermissions.isEmpty else {
            return (
                false,
                "Remote bridge host supports background hotkeys, but they are disabled by current permissions",
                []
            )
        }

        return (
            false,
            "Remote bridge host supports background hotkeys, but current permissions are missing: " +
                self.missingPermissionNames(missingPermissions).joined(separator: ", "),
            missingPermissions
        )
    }

    static func targetedClickAvailability(for handshake: PeekabooBridgeHandshakeResponse)
    -> (isEnabled: Bool, unavailableReason: String?, missingPermissions: Set<PeekabooBridgePermissionKind>) {
        guard
            handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 6),
            handshake.supportedOperations.contains(.targetedClick)
        else {
            return (false, nil, [])
        }

        let enabledOperations = handshake.enabledOperations ?? handshake.supportedOperations
        if enabledOperations.contains(.targetedClick) {
            return (true, nil, [])
        }

        let requestAwarePermissions =
            handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 9)
        if requestAwarePermissions, handshake.permissions?.accessibility == false {
            return (
                false,
                "Remote bridge host background clicks require Accessibility permission",
                [.accessibility]
            )
        }

        let missingPermissions = missingPermissions(for: .targetedClick, handshake: handshake)
        guard !missingPermissions.isEmpty else {
            return (
                false,
                "Remote bridge host supports background clicks, but they are disabled by current permissions",
                []
            )
        }

        return (
            false,
            "Remote bridge host supports background clicks, but current permissions are missing: " +
                self.missingPermissionNames(missingPermissions).joined(separator: ", "),
            missingPermissions
        )
    }

    static func supportsExactWindowTargetedClicks(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        guard handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 17),
              handshake.supportedOperations.contains(.exactWindowTargetedClick)
        else {
            return false
        }
        return (handshake.enabledOperations ?? handshake.supportedOperations)
            .contains(.exactWindowTargetedClick)
    }

    static func supportsStatelessClickVariants(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.statelessClickVariantVersion &&
            handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.statelessClickVariants) == true &&
            self.supportsOperation(.targetedClick, for: handshake) &&
            self.supportsOperation(.exactWindowTargetedClick, for: handshake)
    }

    static func supportsExactWindowHeldPointerLifecycle(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        let requiredOperations: Set<PeekabooBridgeOperation> = [
            .createExactWindowHeldPointerOwner,
            .beginExactWindowHeldPointer,
            .releaseExactWindowHeldPointer,
            .revokeExactWindowHeldPointer,
            .disconnectExactWindowHeldPointerOwner,
        ]
        return handshake.negotiatedVersion >= PeekabooBridgeConstants.exactWindowHeldPointerLifecycleVersion &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.exactWindowHeldPointerLifecycle
            ) == true &&
            requiredOperations.isSubset(of: Set(handshake.supportedOperations)) &&
            requiredOperations.isSubset(of: Set(handshake.enabledOperations ?? handshake.supportedOperations))
    }

    static func supportsTargetedScroll(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        guard handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 11),
              handshake.supportedOperations.contains(.targetedScroll)
        else {
            return false
        }
        return (handshake.enabledOperations ?? handshake.supportedOperations).contains(.targetedScroll)
    }

    static func supportsRequestPinnedExactWindowScrollReceipt(
        for handshake: PeekabooBridgeHandshakeResponse
    ) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.requestPinnedExactWindowScrollReceiptVersion &&
            handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.attestedOperationReceipts) == true &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.requestPinnedExactWindowScrollReceipt
            ) == true &&
            self.supportsTargetedScroll(for: handshake)
    }

    static func targetedTypeAvailability(for handshake: PeekabooBridgeHandshakeResponse)
    -> (isEnabled: Bool, unavailableReason: String?, missingPermissions: Set<PeekabooBridgePermissionKind>) {
        guard
            handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 8),
            handshake.supportedOperations.contains(.targetedTypeActions)
        else {
            return (false, nil, [])
        }

        let enabledOperations = handshake.enabledOperations ?? handshake.supportedOperations
        if enabledOperations.contains(.targetedTypeActions) {
            return (true, nil, [])
        }

        let missingPermissions = missingPermissions(for: .targetedTypeActions, handshake: handshake)
        guard !missingPermissions.isEmpty else {
            return (
                false,
                "Remote bridge host supports background typing, but it is disabled by current permissions",
                []
            )
        }

        return (
            false,
            "Remote bridge host supports background typing, but current permissions are missing: " +
                self.missingPermissionNames(missingPermissions).joined(separator: ", "),
            missingPermissions
        )
    }

    private static func missingPermissions(
        for operation: PeekabooBridgeOperation,
        handshake: PeekabooBridgeHandshakeResponse
    ) -> Set<PeekabooBridgePermissionKind> {
        let requiredPermissions = self.requiredPermissions(for: operation, handshake: handshake)
        let grantedPermissions = grantedPermissions(from: handshake.permissions)
        return requiredPermissions.subtracting(grantedPermissions)
    }

    static func requiredPermissions(
        for operation: PeekabooBridgeOperation,
        handshake: PeekabooBridgeHandshakeResponse
    ) -> Set<PeekabooBridgePermissionKind> {
        if let tagged = handshake.permissionTags[operation.rawValue] {
            return Set(tagged)
        }
        guard operation == .exactDialogEnterText else {
            return operation.requiredPermissions
        }
        let usesAttestedReceipts = handshake.negotiatedVersion >=
            PeekabooBridgeConstants.attestedOperationReceiptVersion &&
            handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.attestedOperationReceipts) == true
        return usesAttestedReceipts ? [.accessibility] : [.accessibility, .postEvent]
    }

    static func missingPermissionNames(_ permissions: Set<PeekabooBridgePermissionKind>) -> [String] {
        permissions.map(\.displayName).sorted()
    }

    private static func grantedPermissions(from status: PermissionsStatus?) -> Set<PeekabooBridgePermissionKind> {
        guard let status else { return [] }

        var granted: Set<PeekabooBridgePermissionKind> = []
        if status.screenRecording {
            granted.insert(.screenRecording)
        }
        if status.accessibility {
            granted.insert(.accessibility)
        }
        if status.appleScript {
            granted.insert(.appleScript)
        }
        if status.postEvent {
            granted.insert(.postEvent)
        }
        return granted
    }
}

extension PeekabooBridgePermissionKind {
    fileprivate var displayName: String {
        switch self {
        case .screenRecording:
            "Screen Recording"
        case .accessibility:
            "Accessibility"
        case .postEvent:
            "Event Synthesizing"
        case .appleScript:
            "AppleScript"
        }
    }
}
