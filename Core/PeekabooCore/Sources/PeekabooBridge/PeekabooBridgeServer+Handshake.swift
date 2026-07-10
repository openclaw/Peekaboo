import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
extension PeekabooBridgeServer {
    static func invalidRequest(for request: PeekabooBridgeRequest) -> PeekabooBridgeErrorEnvelope {
        PeekabooBridgeErrorEnvelope(
            code: .invalidRequest,
            message: "Unexpected request for operation \(request.operation.rawValue)")
    }

    func handleHandshake(
        _ payload: PeekabooBridgeHandshake,
        peer: PeekabooBridgePeer?) throws -> PeekabooBridgeResponse
    {
        let resolvedBundle = peer?.bundleIdentifier ?? payload.client.bundleIdentifier
        let resolvedTeam = peer?.teamIdentifier ?? payload.client.teamIdentifier

        guard self.supportedVersions.contains(payload.protocolVersion) else {
            throw PeekabooBridgeErrorEnvelope(
                code: .versionMismatch,
                message: """
                Bridge protocol \(payload.protocolVersion.major).\(payload.protocolVersion.minor) is not supported by \
                this host. Ask the user to relaunch Peekaboo so the bridge host updates, then retry.
                """)
        }

        if let bundle = resolvedBundle,
           !self.allowlistedBundles.isEmpty,
           !self.allowlistedBundles.contains(bundle)
        {
            throw PeekabooBridgeErrorEnvelope(code: .unauthorizedClient, message: "Bundle \(bundle) is not authorized")
        }

        if let team = resolvedTeam,
           !self.allowlistedTeams.isEmpty,
           !self.allowlistedTeams.contains(team)
        {
            throw PeekabooBridgeErrorEnvelope(code: .unauthorizedClient, message: "Team \(team) is not authorized")
        }

        if let uid = peer?.userIdentifier, uid != getuid() {
            throw PeekabooBridgeErrorEnvelope(
                code: .unauthorizedClient,
                message: "UID \(uid) is not authorized for this listener")
        }

        if let pid = peer?.processIdentifier {
            let bundleDescription = resolvedBundle ?? "<unknown>"
            self.logger
                .debug(
                    "bridge handshake ok pid=\(pid, privacy: .public) bundle=\(bundleDescription, privacy: .public)")
        }

        let negotiated = min(
            max(payload.protocolVersion, self.supportedVersions.lowerBound),
            self.supportedVersions.upperBound)

        let permissions = self.currentPermissions(allowAppleScriptLaunch: false)
        let advertisedOps = Array(self.operationsCompatibleWithNegotiatedVersion(
            self.allowedOperationsToAdvertise(),
            negotiated)).sorted { $0.rawValue < $1.rawValue }
        var enabledOps = self.operationsCompatibleWithNegotiatedVersion(
            self.effectiveAllowedOperations(permissions: permissions),
            negotiated)
        var permissionTags = Dictionary(
            uniqueKeysWithValues: advertisedOps.map { op in
                (op.rawValue, Array(op.requiredPermissions).sorted { $0.rawValue < $1.rawValue })
            })
        let requestAwareTargetedClickVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 9)
        if negotiated < requestAwareTargetedClickVersion,
           advertisedOps.contains(.targetedClick)
        {
            // Protocol 1.6...1.8 exposed only synthetic targeted clicks. Preserve that
            // permission contract for old clients even though 1.9 can use AX per request.
            permissionTags[PeekabooBridgeOperation.targetedClick.rawValue] = [.postEvent]
            if !permissions.postEvent {
                enabledOps.remove(.targetedClick)
            }
        }

        self.logger.debug(
            """
            Handshake advertised=\(advertisedOps.count, privacy: .public) \
            enabled=\(enabledOps.count, privacy: .public) \
            tags=\(permissionTags.count, privacy: .public)
            """)

        let response = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: negotiated,
            hostKind: self.hostKind,
            build: PeekabooBridgeConstants.buildIdentifier,
            supportedOperations: advertisedOps,
            permissions: permissions,
            enabledOperations: Array(enabledOps).sorted { $0.rawValue < $1.rawValue },
            permissionTags: permissionTags)
        return .handshake(response)
    }

    func operationsCompatibleWithNegotiatedVersion(
        _ operations: Set<PeekabooBridgeOperation>,
        _ negotiated: PeekabooBridgeProtocolVersion) -> Set<PeekabooBridgeOperation>
    {
        PeekabooBridgeOperation.compatible(operations, with: negotiated)
    }

    func allowedOperationsToAdvertise() -> Set<PeekabooBridgeOperation> {
        var operations = self.allowedOperations
        if self.daemonControl == nil {
            operations.remove(.daemonStatus)
            operations.remove(.daemonStop)
            operations.remove(.relaunchApplicationWithOptions)
        }
        if (self.services.automation as? any TargetedHotkeyServiceProtocol)?.supportsTargetedHotkeys != true {
            operations.remove(.targetedHotkey)
        }
        if (self.services.automation as? any TargetedTypeServiceProtocol)?.supportsTargetedTypeActions != true {
            operations.remove(.targetedTypeActions)
        }
        if (self.services.automation as? any TargetedClickServiceProtocol)?.supportsTargetedClicks != true {
            operations.remove(.targetedClick)
        }
        if (self.services.automation as? any ExactWindowTargetedClickServiceProtocol)?
            .supportsExactWindowTargetedClicks != true
        {
            operations.remove(.exactWindowTargetedClick)
        }
        if self.services.automation as? any ElementActionAutomationServiceProtocol == nil {
            operations.remove(.setValue)
            operations.remove(.performAction)
        }
        if !self.services.snapshots.supportsImplicitLatestSnapshotInvalidation {
            operations.remove(.invalidateImplicitLatestSnapshot)
        }
        if !self.services.applications.supportsApplicationLaunchOptions {
            operations.remove(.launchApplicationWithOptions)
        }
        if !self.services.applications.supportsApplicationRelaunch {
            operations.remove(.relaunchApplicationWithOptions)
        }
        return operations
    }

    func effectiveAllowedOperations(permissions: PermissionsStatus) -> Set<PeekabooBridgeOperation> {
        let granted = Self.grantedPermissions(from: permissions)

        var operations = Set(
            self.allowedOperationsToAdvertise().filter { operation in
                operation.requiredPermissions.isSubset(of: granted)
            })

        // Targeted clicks are delivered exclusively through accessibility actions; the
        // synthetic pid-routed mouse path was removed because macOS delivers those events at
        // the window corner regardless of the requested point.
        if !permissions.accessibility {
            operations.remove(.targetedClick)
            operations.remove(.exactWindowTargetedClick)
        }
        return operations
    }

    static func grantedPermissions(from permissions: PermissionsStatus) -> Set<PeekabooBridgePermissionKind> {
        var granted: Set<PeekabooBridgePermissionKind> = []
        if permissions.screenRecording {
            granted.insert(.screenRecording)
        }
        if permissions.accessibility {
            granted.insert(.accessibility)
        }
        if permissions.appleScript {
            granted.insert(.appleScript)
        }
        if permissions.postEvent {
            granted.insert(.postEvent)
        }

        return granted
    }

    func currentPermissions(allowAppleScriptLaunch: Bool = true) -> PermissionsStatus {
        self.permissionStatusEvaluator(allowAppleScriptLaunch)
            .withPostEvent(self.postEventAccessEvaluator())
    }

    static func bridgePermission(for error: PeekabooError) -> PeekabooBridgePermissionKind? {
        switch error {
        case .permissionDeniedAccessibility:
            .accessibility
        case .permissionDeniedScreenRecording:
            .screenRecording
        case .permissionDeniedEventSynthesizing:
            .postEvent
        default:
            nil
        }
    }
}
