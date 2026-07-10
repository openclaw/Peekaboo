import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

enum BridgeCapabilityPolicy {
    static func supportsRemoteRequirements(
        for handshake: PeekabooBridgeHandshakeResponse,
        options: CommandRuntimeOptions
    ) -> Bool {
        guard handshake.supportedOperations.contains(.captureScreen) else {
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

        if options.requiresApplicationRelaunch, !self.supportsApplicationRelaunch(for: handshake) {
            return false
        }

        if options.requiresSurvivingApplicationHost, handshake.hostKind != .onDemand {
            return false
        }

        if options.requiresHostApplicationInventory, !self.supportsHostApplicationInventory(for: handshake) {
            return false
        }

        if options.requiresExactWindowTargetedClicks,
           !self.supportsExactWindowTargetedClicks(for: handshake) {
            return false
        }

        if options.requiresPostEventClickPermission,
           handshake.permissions?.postEvent != true {
            return false
        }

        if options.requiresImplicitSnapshotInvalidation || options.usesPerToolSnapshotInvalidation,
           !self.supportsImplicitSnapshotInvalidation(for: handshake) {
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
            required.formUnion(handshake.permissionTags[operation.rawValue] ?? Array(operation.requiredPermissions))
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
        return self.requiredRemotePermissions(for: handshake, options: options)
            .subtracting(self.grantedPermissions(from: handshake.permissions))
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
        return operations
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

    static func supportsApplicationLaunchOptions(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 9) &&
            handshake.supportedOperations.contains(.launchApplicationWithOptions)
    }

    static func supportsApplicationRelaunch(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        guard handshake.hostKind == .onDemand,
              handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 9),
              handshake.supportedOperations.contains(.relaunchApplicationWithOptions)
        else {
            return false
        }

        let enabledOperations = handshake.enabledOperations ?? handshake.supportedOperations
        return enabledOperations.contains(.relaunchApplicationWithOptions)
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

    static func supportsElementActions(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 3) &&
            handshake.supportedOperations.contains(.setValue) &&
            handshake.supportedOperations.contains(.performAction)
    }

    static func supportsDesktopObservation(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 5) &&
            handshake.supportedOperations.contains(.desktopObservation)
    }

    static func supportsInspectAccessibilityTree(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 7) &&
            handshake.supportedOperations.contains(.inspectAccessibilityTree)
    }

    static func supportsBrowserMCP(for handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 4) &&
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
            let missingVariantPermissions: Set<PeekabooBridgePermissionKind> =
                handshake.permissions?.postEvent == false ? [.postEvent] : []
            return (true, nil, missingVariantPermissions)
        }

        let requestAwarePermissions =
            handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 9) &&
            handshake.permissionTags[PeekabooBridgeOperation.targetedClick.rawValue]?.isEmpty == true
        if requestAwarePermissions,
           handshake.permissions?.accessibility == false,
           handshake.permissions?.postEvent == false {
            return (
                false,
                "Remote bridge host background clicks require Accessibility or Event Synthesizing permission",
                []
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
        guard handshake.negotiatedVersion >= PeekabooBridgeProtocolVersion(major: 1, minor: 9),
              handshake.supportedOperations.contains(.exactWindowTargetedClick)
        else {
            return false
        }
        return (handshake.enabledOperations ?? handshake.supportedOperations)
            .contains(.exactWindowTargetedClick)
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
        let requiredPermissions = Set(
            handshake.permissionTags[operation.rawValue] ?? Array(operation.requiredPermissions)
        )
        let grantedPermissions = grantedPermissions(from: handshake.permissions)
        return requiredPermissions.subtracting(grantedPermissions)
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
