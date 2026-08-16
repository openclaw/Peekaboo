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
        peer: PeekabooBridgePeer?,
        permissions: PermissionsStatus) async throws -> PeekabooBridgeResponse
    {
        let resolvedBundle = peer?.bundleIdentifier ?? payload.client.bundleIdentifier
        let resolvedTeam = peer?.teamIdentifier ?? payload.client.teamIdentifier
        let operationReceiptAuthority = PeekabooBridgeRequestContext.operationReceiptAuthority

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
            self.logger.debug("bridge handshake ok pid=\(pid, privacy: .public)")
        }

        let negotiated = min(
            max(payload.protocolVersion, self.supportedVersions.lowerBound),
            self.supportedVersions.upperBound)
        let supportsAttestedOperationReceipts =
            negotiated >= PeekabooBridgeConstants.attestedOperationReceiptVersion &&
            operationReceiptAuthority != nil &&
            self.hostCapabilities.contains(PeekabooBridgeHostCapability.desktopActionOutcomeProjection)

        let compatibleOperations = self.handshakeOperations(
            negotiated: negotiated,
            permissions: permissions,
            usesAttestedOperationReceipts: supportsAttestedOperationReceipts)
        var advertisedOps = compatibleOperations.advertised.sorted { $0.rawValue < $1.rawValue }
        var enabledOps = compatibleOperations.enabled
        if negotiated >= PeekabooBridgeConstants.attestedOperationReceiptVersion,
           !advertisedOps.contains(.listWindows)
        {
            advertisedOps.removeAll { $0 == .focusWindow }
            enabledOps.remove(.focusWindow)
        }
        if negotiated >= PeekabooBridgeConstants.attestedOperationReceiptVersion,
           !enabledOps.contains(.listWindows)
        {
            enabledOps.remove(.focusWindow)
        }
        if negotiated >= PeekabooBridgeConstants.attestedOperationReceiptVersion,
           !advertisedOps.contains(.findApplication)
        {
            advertisedOps.removeAll { $0 == .activateApplication }
            enabledOps.remove(.activateApplication)
        }
        if negotiated >= PeekabooBridgeConstants.attestedOperationReceiptVersion,
           !enabledOps.contains(.findApplication)
        {
            enabledOps.remove(.activateApplication)
        }
        var permissionTags = Dictionary(
            uniqueKeysWithValues: advertisedOps.map { op in
                (op.rawValue, Array(op.requiredPermissions).sorted { $0.rawValue < $1.rawValue })
            })
        Self.applyExactDialogInputPermissionContract(
            supportsAttestedOperationReceipts: supportsAttestedOperationReceipts,
            advertisedOperations: advertisedOps,
            permissions: permissions,
            enabledOperations: &enabledOps,
            permissionTags: &permissionTags)
        let requestAwareTargetedClickVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 9)
        if negotiated < requestAwareTargetedClickVersion,
           advertisedOps.contains(.targetedClick)
        {
            // Protocol 1.6...1.8 exposed only synthetic targeted clicks. Preserve that
            // permission contract for old clients even though 1.9 can use AX per request.
            permissionTags[PeekabooBridgeOperation.targetedClick.rawValue] = [.postEvent]
            if !permissions.postEvent {
                enabledOps.remove(.targetedClick)
            } else {
                enabledOps.insert(.targetedClick)
            }
        }

        self.logger.debug(
            """
            Handshake advertised=\(advertisedOps.count, privacy: .public) \
            enabled=\(enabledOps.count, privacy: .public) \
            tags=\(permissionTags.count, privacy: .public)
            """)

        var advertisedCapabilities = self.hostCapabilities
        if supportsAttestedOperationReceipts {
            advertisedCapabilities.insert(PeekabooBridgeHostCapability.attestedOperationReceipts)
        }
        let operationSessionAttestation: PeekabooBridgeOperationSessionAttestation?
        if supportsAttestedOperationReceipts {
            guard let peer,
                  let clientInstanceID = payload.operationClientInstanceID
            else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .unauthorizedClient,
                    message: "Protocol 1.29 requires a peer-bound operation client instance")
            }
            do {
                operationSessionAttestation = try await operationReceiptAuthority?.createSession(
                    clientInstanceID: clientInstanceID,
                    peer: peer,
                    replacing: payload.replacingOperationSessionID)
            } catch let error as PeekabooBridgeOperationReceiptError {
                let code: PeekabooBridgeErrorCode = switch error {
                case .operationSessionMismatch:
                    .invalidRequest
                case .operationSessionRegistryExhausted, .archiveWriteFailed,
                     .invalidOperationSessionConfiguration:
                    .serverBusy
                case .peerIdentityMismatch, .clientIdentityMismatch:
                    .unauthorizedClient
                default:
                    .internalError
                }
                throw PeekabooBridgeErrorEnvelope(
                    code: code,
                    message: error.localizedDescription,
                    details: "\(error)",
                    context: "bridge_operation_session:handshake")
            }
        } else {
            operationSessionAttestation = nil
        }
        let response = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: negotiated,
            hostKind: self.hostKind,
            build: PeekabooBridgeConstants.buildIdentifier,
            supportedOperations: advertisedOps,
            permissions: permissions,
            enabledOperations: Array(enabledOps).sorted { $0.rawValue < $1.rawValue },
            permissionTags: permissionTags,
            hostIdentity: self.hostIdentity,
            hostCapabilities: advertisedCapabilities.sorted(),
            operationAttestation: supportsAttestedOperationReceipts
                ? operationReceiptAuthority?.attestation
                : nil,
            operationSessionAttestation: operationSessionAttestation)
        return .handshake(response)
    }

    private static func applyExactDialogInputPermissionContract(
        supportsAttestedOperationReceipts: Bool,
        advertisedOperations: [PeekabooBridgeOperation],
        permissions: PermissionsStatus,
        enabledOperations: inout Set<PeekabooBridgeOperation>,
        permissionTags: inout [String: [PeekabooBridgePermissionKind]])
    {
        guard advertisedOperations.contains(.exactDialogEnterText) else { return }

        let requiredPermissions: Set<PeekabooBridgePermissionKind> = supportsAttestedOperationReceipts
            ? [.accessibility]
            : [.accessibility, .postEvent]
        permissionTags[PeekabooBridgeOperation.exactDialogEnterText.rawValue] = requiredPermissions
            .sorted { $0.rawValue < $1.rawValue }
        if requiredPermissions.isSubset(of: self.grantedPermissions(from: permissions)) {
            enabledOperations.insert(.exactDialogEnterText)
        } else {
            enabledOperations.remove(.exactDialogEnterText)
        }
    }

    private func handshakeOperations(
        negotiated: PeekabooBridgeProtocolVersion,
        permissions: PermissionsStatus,
        usesAttestedOperationReceipts: Bool)
        -> (advertised: [PeekabooBridgeOperation], enabled: Set<PeekabooBridgeOperation>)
    {
        let advertised = self.operationsCompatibleWithNegotiatedVersion(
            self.allowedOperationsToAdvertise(),
            negotiated,
            usesAttestedOperationReceipts: usesAttestedOperationReceipts)
        let enabled = self.operationsCompatibleWithNegotiatedVersion(
            self.effectiveAllowedOperations(permissions: permissions),
            negotiated,
            usesAttestedOperationReceipts: usesAttestedOperationReceipts)
        return (Array(advertised), enabled)
    }

    func operationsCompatibleWithNegotiatedVersion(
        _ operations: Set<PeekabooBridgeOperation>,
        _ negotiated: PeekabooBridgeProtocolVersion,
        usesAttestedOperationReceipts: Bool) -> Set<PeekabooBridgeOperation>
    {
        var compatible = PeekabooBridgeOperation.compatible(operations, with: negotiated)
        if usesAttestedOperationReceipts,
           !self.services.dialogs.supportsBackgroundExactDialogInput
        {
            compatible.remove(.exactDialogEnterText)
        }
        return compatible
    }

    func allowedOperationsToAdvertise() -> Set<PeekabooBridgeOperation> {
        var operations = self.allowedOperations
        // Retain the wire enum for old-client decoding, but current hosts never advertise or execute the probe.
        operations.remove(._appleScriptProbe)
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
        if self.services.automation as? any TargetedFocusedElementServiceProtocol == nil {
            operations.remove(.getFocusedElement)
        }
        if (self.services.automation as? any ExactWindowTargetedKeyboardServiceProtocol)?
            .supportsExactWindowTargetedKeyboard != true
        {
            operations.remove(.exactWindowTargetedTypeActions)
            operations.remove(.exactWindowTargetedHotkey)
        }
        if !self.services.snapshots.supportsImplicitLatestSnapshotInvalidation {
            operations.remove(.invalidateImplicitLatestSnapshot)
        }
        if !self.services.snapshots.supportsSnapshotMutationLeases {
            operations.remove(.beginSnapshotMutation)
            operations.remove(.finishSnapshotMutation)
        }
        if !self.services.snapshots.supportsAtomicObservationSnapshotPublication {
            operations.remove(.storeObservationSnapshot)
        }
        if !self.services.applications.supportsApplicationLaunchOptions {
            operations.remove(.launchApplicationWithOptions)
        }
        if !self.services.applications.supportsApplicationRelaunch {
            operations.remove(.relaunchApplicationWithOptions)
        }
        if !self.services.applications.supportsProcessGenerationPinnedApplicationQuit {
            operations.remove(.quitApplication)
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

    func effectiveAllowedOperations(
        for request: PeekabooBridgeRequest,
        permissions: PermissionsStatus) -> Set<PeekabooBridgeOperation>
    {
        var operations = self.effectiveAllowedOperations(permissions: permissions)
        let operation = request.operation
        let advertisedOperations = self.allowedOperationsToAdvertise()
        if PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics,
           operation == .exactDialogEnterText
        {
            if advertisedOperations.contains(operation),
               self.services.dialogs.supportsBackgroundExactDialogInput,
               permissions.accessibility
            {
                // Protocol 1.29 executes exact dialog input through AXValue, so only its
                // legacy PostEvent requirement is waived. Host allowlisting and service
                // advertisement remain authoritative.
                operations.insert(operation)
            } else {
                operations.remove(operation)
            }
        } else if operation == .exactDialogEnterText,
                  !permissions.accessibility || !permissions.postEvent
        {
            operations.remove(operation)
        }
        return operations.intersection(advertisedOperations)
    }

    static func grantedPermissions(from permissions: PermissionsStatus) -> Set<PeekabooBridgePermissionKind> {
        var granted: Set<PeekabooBridgePermissionKind> = []
        if permissions.screenRecording {
            granted.insert(.screenRecording)
        }
        if permissions.accessibility {
            granted.insert(.accessibility)
        }
        if permissions.postEvent {
            granted.insert(.postEvent)
        }

        return granted
    }

    func currentPermissions() -> PermissionsStatus {
        let permissions = self.permissionStatusEvaluator(false)
        return PermissionsStatus(
            screenRecording: permissions.screenRecording,
            accessibility: permissions.accessibility,
            appleScript: false,
            postEvent: permissions.postEvent)
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
