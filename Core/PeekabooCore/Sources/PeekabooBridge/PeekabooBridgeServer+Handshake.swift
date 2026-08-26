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

    // swiftlint:disable:next cyclomatic_complexity function_body_length
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
        let heldPointerOperations: Set<PeekabooBridgeOperation> = [
            .createExactWindowHeldPointerOwner,
            .beginExactWindowHeldPointer,
            .releaseExactWindowHeldPointer,
            .revokeExactWindowHeldPointer,
            .disconnectExactWindowHeldPointerOwner,
        ]

        let compatibleOperations = self.handshakeOperations(
            negotiated: negotiated,
            permissions: permissions,
            usesAttestedOperationReceipts: supportsAttestedOperationReceipts)
        var advertisedOps = compatibleOperations.advertised.sorted { $0.rawValue < $1.rawValue }
        var enabledOps = compatibleOperations.enabled
        let clientCapabilities = Set(payload.clientCapabilities ?? [])
        if !clientCapabilities.contains(PeekabooBridgeClientCapability.producerBoundSnapshotReferences) {
            advertisedOps.removeAll { $0 == .ownsSnapshot }
            enabledOps.remove(.ownsSnapshot)
        }
        if (try? self.requireCertificationCaller(peer)) == nil {
            advertisedOps.removeAll {
                $0 == .observeProcessGeneration || $0 == .certificationProducerAttestation
            }
            enabledOps.remove(.observeProcessGeneration)
            enabledOps.remove(.certificationProducerAttestation)
        }
        if negotiated >= PeekabooBridgeConstants.exactWindowHeldPointerLifecycleVersion,
           !supportsAttestedOperationReceipts
        {
            advertisedOps.removeAll { heldPointerOperations.contains($0) }
            enabledOps.subtract(heldPointerOperations)
        }
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
        let browserOperations: Set<PeekabooBridgeOperation> = [
            .browserStatus,
            .browserConnect,
            .browserDisconnect,
            .browserExecute,
        ]
        if !supportsAttestedOperationReceipts ||
            negotiated < PeekabooBridgeConstants.nativeBrowserConnectionBindingVersion ||
            (self.services as? any PeekabooBridgeBrowserConnectionResultProviding)?
            .supportsNativeBrowserConnectionBinding != true ||
            !browserOperations.isSubset(of: Set(advertisedOps))
        {
            advertisedCapabilities.remove(PeekabooBridgeHostCapability.nativeBrowserConnectionBinding)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < PeekabooBridgeConstants.producerBoundSnapshotReferencesVersion ||
            !clientCapabilities.contains(PeekabooBridgeClientCapability.producerBoundSnapshotReferences) ||
            !self.services.snapshots.supportsProducerBoundSnapshotReferences ||
            !advertisedOps.contains(.ownsSnapshot)
        {
            advertisedCapabilities.remove(PeekabooBridgeHostCapability.producerBoundSnapshotReferences)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < PeekabooBridgeConstants.targetedClickAccessibilityValueDeliveryVersion ||
            !clientCapabilities.contains(PeekabooBridgeClientCapability.targetedClickAccessibilityValueDelivery) ||
            (self.services.automation as? any TargetedClickServiceProtocol)?
            .supportsTargetedClickAccessibilityValueDelivery != true ||
            !advertisedOps.contains(.targetedClick)
        {
            advertisedCapabilities.remove(PeekabooBridgeHostCapability.targetedClickAccessibilityValueDelivery)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < PeekabooBridgeConstants.statelessClickVariantVersion ||
            (self.services.automation as? any TargetedClickServiceProtocol)?.supportsStatelessClickVariants != true ||
            !advertisedOps.contains(.targetedClick) ||
            !advertisedOps.contains(.exactWindowTargetedClick)
        {
            advertisedCapabilities.remove(PeekabooBridgeHostCapability.statelessClickVariants)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < PeekabooBridgeConstants.exactWindowHeldPointerLifecycleVersion ||
            (self.services.automation as? any ExactWindowHeldPointerLifecycleServiceProtocol)?
            .supportsExactWindowHeldPointerLifecycle != true ||
            !heldPointerOperations.isSubset(of: advertisedOps)
        {
            advertisedCapabilities.remove(PeekabooBridgeHostCapability.exactWindowHeldPointerLifecycle)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < PeekabooBridgeConstants.agentExecutionTraceVersion ||
            !advertisedOps.contains(.agentExecutionTrace) ||
            !enabledOps.contains(.agentExecutionTrace)
        {
            advertisedCapabilities.remove(PeekabooBridgeHostCapability.agentExecutionTrace)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < PeekabooBridgeConstants.processGenerationObservationVersion ||
            !advertisedOps.contains(.observeProcessGeneration) ||
            !enabledOps.contains(.observeProcessGeneration)
        {
            advertisedCapabilities.remove(PeekabooBridgeHostCapability.processGenerationObservation)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < PeekabooBridgeConstants.certificationProducerAttestationVersion ||
            !advertisedOps.contains(.certificationProducerAttestation) ||
            !enabledOps.contains(.certificationProducerAttestation)
        {
            advertisedCapabilities.remove(PeekabooBridgeHostCapability.certificationProducerAttestation)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < PeekabooBridgeConstants.setValueResultTargetBindingVersion ||
            (self.services.automation as? any ElementActionAutomationServiceProtocol)?
            .supportsSetValueResultTargetBinding != true ||
            !advertisedOps.contains(.setValue)
        {
            advertisedCapabilities.remove(PeekabooBridgeHostCapability.setValueResultTargetBinding)
        }
        let elementMutationOperations: Set<PeekabooBridgeOperation> = [.setValue, .performAction]
        if !supportsAttestedOperationReceipts ||
            negotiated < PeekabooBridgeConstants.processGenerationBoundElementMutationsVersion ||
            !(self.services.automation is any UIAutomationActionOutcomeProviding) ||
            (self.services.automation as? any ElementActionAutomationServiceProtocol)?
            .supportsProcessGenerationBoundElementMutations != true ||
            elementMutationOperations.isDisjoint(with: advertisedOps)
        {
            advertisedCapabilities.remove(
                PeekabooBridgeHostCapability.processGenerationBoundElementMutations)
        }
        if !supportsAttestedOperationReceipts ||
            negotiated < PeekabooBridgeConstants.composedInputParityVersion ||
            !self.services.snapshots.supportsSnapshotMutationLeases ||
            (self.services.automation as? any ForegroundModifierClickServiceProtocol)?
            .supportsForegroundModifierClickSnapshotLease != true ||
            !advertisedOps.contains(.foregroundModifierClick) ||
            !enabledOps.contains(.foregroundModifierClick)
        {
            advertisedCapabilities.remove(PeekabooBridgeHostCapability.foregroundModifierClickSnapshotLease)
        }
        self.applyRequestPinnedExactWindowScrollCapability(
            supportsAttestedOperationReceipts: supportsAttestedOperationReceipts,
            negotiated: negotiated,
            advertisedOperations: advertisedOps,
            enabledOperations: enabledOps,
            advertisedCapabilities: &advertisedCapabilities)
        if !supportsAttestedOperationReceipts ||
            negotiated < PeekabooBridgeConstants.compositeTypeDeliveryVersion ||
            (self.services.automation as? any UIAutomationActionOutcomeProviding) == nil ||
            (self.services.automation as? any CompositeTypeDeliveryServiceProtocol)?
            .supportsExactWindowCompositeTypeDelivery != true ||
            !advertisedOps.contains(where: {
                [.targetedTypeActions, .exactWindowTargetedTypeActions, .exactWindowPixelFocusType].contains($0)
            })
        {
            advertisedCapabilities.remove(PeekabooBridgeHostCapability.compositeTypeDelivery)
        }
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
                    negotiatedCapabilities: .init(
                        protocolVersion: negotiated,
                        statelessClickVariants: advertisedCapabilities.contains(
                            PeekabooBridgeHostCapability.statelessClickVariants),
                        exactWindowHeldPointerLifecycle: advertisedCapabilities.contains(
                            PeekabooBridgeHostCapability.exactWindowHeldPointerLifecycle),
                        nativeBrowserConnectionBinding: advertisedCapabilities.contains(
                            PeekabooBridgeHostCapability.nativeBrowserConnectionBinding),
                        producerBoundSnapshotReferences: advertisedCapabilities.contains(
                            PeekabooBridgeHostCapability.producerBoundSnapshotReferences),
                        targetedClickAccessibilityValueDelivery: advertisedCapabilities.contains(
                            PeekabooBridgeHostCapability.targetedClickAccessibilityValueDelivery),
                        requestPinnedExactWindowScrollReceipt: advertisedCapabilities.contains(
                            PeekabooBridgeHostCapability.requestPinnedExactWindowScrollReceipt),
                        compositeTypeDelivery: advertisedCapabilities.contains(
                            PeekabooBridgeHostCapability.compositeTypeDelivery),
                        processGenerationBoundElementMutations: advertisedCapabilities.contains(
                            PeekabooBridgeHostCapability.processGenerationBoundElementMutations)),
                    replacing: payload.replacingOperationSessionID)
                self.clearReceiptlessNegotiation(peer: peer)
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
            self.recordReceiptlessNegotiation(peer: peer, protocolVersion: negotiated)
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

    private func applyRequestPinnedExactWindowScrollCapability(
        supportsAttestedOperationReceipts: Bool,
        negotiated: PeekabooBridgeProtocolVersion,
        advertisedOperations: [PeekabooBridgeOperation],
        enabledOperations: Set<PeekabooBridgeOperation>,
        advertisedCapabilities: inout Set<String>)
    {
        guard supportsAttestedOperationReceipts,
              negotiated >= PeekabooBridgeConstants.requestPinnedExactWindowScrollReceiptVersion,
              (self.services.automation as? any UIAutomationActionOutcomeProviding)?
                  .supportsRequestPinnedExactWindowScrollReceipt == true,
                  advertisedOperations.contains(.targetedScroll),
                  enabledOperations.contains(.targetedScroll)
        else {
            advertisedCapabilities.remove(PeekabooBridgeHostCapability.requestPinnedExactWindowScrollReceipt)
            return
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
        if self.supportedVersions.upperBound >=
            PeekabooBridgeConstants.processGenerationBoundElementMutationsVersion,
            !usesAttestedOperationReceipts ||
            negotiated < PeekabooBridgeConstants.processGenerationBoundElementMutationsVersion
        {
            compatible.remove(.setValue)
            compatible.remove(.performAction)
        }
        if !usesAttestedOperationReceipts {
            compatible.remove(.observeProcessGeneration)
            compatible.remove(.certificationProducerAttestation)
        }
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
        if self.servingSocketPath == nil || self.agentExecutionRunner == nil {
            operations.remove(.agentExecutionTrace)
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
        if self.services.automation as? any ElementActionAutomationServiceProtocol == nil ||
            (self.supportedVersions.upperBound >=
                PeekabooBridgeConstants.processGenerationBoundElementMutationsVersion &&
                !Self.supportsProcessGenerationBoundElementMutationProvider(self.services.automation))
        {
            operations.remove(.setValue)
            operations.remove(.performAction)
        }
        operations = Set(operations.filter {
            $0 != .setValue ||
                self.supportedVersions.upperBound <
                PeekabooBridgeConstants.processGenerationBoundElementMutationsVersion ||
                (self.services.automation as? any ElementActionAutomationServiceProtocol)?
                .supportsSetValueResultTargetBinding == true
        })
        if self.services.automation as? any TargetedFocusedElementServiceProtocol == nil {
            operations.remove(.getFocusedElement)
        }
        if (self.services.automation as? any ExactWindowTargetedKeyboardServiceProtocol)?
            .supportsExactWindowTargetedKeyboard != true
        {
            operations.remove(.exactWindowTargetedTypeActions)
            operations.remove(.exactWindowTargetedHotkey)
        }
        if (self.services.automation as? any ExactWindowPixelFocusTypingServiceProtocol)?
            .supportsExactWindowPixelFocusTyping != true
        {
            operations.remove(.exactWindowPixelFocusType)
        }
        if !self.services.snapshots.supportsSnapshotMutationLeases ||
            (self.services.automation as? any ForegroundModifierClickServiceProtocol)?
            .supportsForegroundModifierClick != true ||
            (self.services.automation as? any ForegroundModifierClickServiceProtocol)?
            .supportsForegroundModifierClickSnapshotLease != true
        {
            operations.remove(.foregroundModifierClick)
        }
        if (self.services.automation as? any ExactWindowHeldPointerLifecycleServiceProtocol)?
            .supportsExactWindowHeldPointerLifecycle != true
        {
            operations.subtract([
                .createExactWindowHeldPointerOwner,
                .beginExactWindowHeldPointer,
                .releaseExactWindowHeldPointer,
                .revokeExactWindowHeldPointer,
                .disconnectExactWindowHeldPointerOwner,
            ])
        }
        if !self.services.snapshots.supportsImplicitLatestSnapshotInvalidation {
            operations.remove(.invalidateImplicitLatestSnapshot)
        }
        if !self.services.snapshots.supportsSnapshotMutationLeases {
            operations.remove(.beginSnapshotMutation)
            operations.remove(.finishSnapshotMutation)
        }
        if !self.services.snapshots.supportsProducerBoundSnapshotReferences {
            operations.remove(.ownsSnapshot)
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

    static func supportsProcessGenerationBoundElementMutationProvider(
        _ automation: any UIAutomationServiceProtocol) -> Bool
    {
        automation is any UIAutomationActionOutcomeProviding &&
            (automation as? any ElementActionAutomationServiceProtocol)?
            .supportsProcessGenerationBoundElementMutations == true
    }

    func effectiveAllowedOperations(permissions: PermissionsStatus) -> Set<PeekabooBridgeOperation> {
        let granted = Self.grantedPermissions(from: permissions)

        var operations = Set(
            self.allowedOperationsToAdvertise().filter { operation in
                operation.requiredPermissions.isSubset(of: granted)
            })

        // Every targeted click needs Accessibility for element/window validation. Variants that
        // use exact-window routed events receive their additional PostEvent check per request.
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

    func receiptlessProtocolVersion(for peer: PeekabooBridgePeer?) -> PeekabooBridgeProtocolVersion? {
        self.pruneReceiptlessNegotiations()
        guard let liveIdentity = peer?.liveIdentity,
              self.processStartIdentityProvider(liveIdentity.processIdentifier) ==
              liveIdentity.processStartIdentity
        else { return nil }
        return self.receiptlessNegotiations[liveIdentity]?.protocolVersion
    }

    private func recordReceiptlessNegotiation(
        peer: PeekabooBridgePeer?,
        protocolVersion: PeekabooBridgeProtocolVersion)
    {
        guard let liveIdentity = peer?.liveIdentity,
              self.processStartIdentityProvider(liveIdentity.processIdentifier) ==
              liveIdentity.processStartIdentity
        else { return }
        self.pruneReceiptlessNegotiations()
        if self.receiptlessNegotiations.count >= 1024,
           self.receiptlessNegotiations[liveIdentity] == nil,
           let oldest = self.receiptlessNegotiations.min(by: { $0.value.recordedAt < $1.value.recordedAt })?.key
        {
            self.receiptlessNegotiations.removeValue(forKey: oldest)
        }
        self.receiptlessNegotiations[liveIdentity] = PeekabooBridgeReceiptlessNegotiation(
            protocolVersion: protocolVersion,
            recordedAt: ContinuousClock.now)
    }

    private func clearReceiptlessNegotiation(peer: PeekabooBridgePeer?) {
        guard let liveIdentity = peer?.liveIdentity else { return }
        self.receiptlessNegotiations.removeValue(forKey: liveIdentity)
    }

    private func pruneReceiptlessNegotiations() {
        self.receiptlessNegotiations = self.receiptlessNegotiations.filter { liveIdentity, _ in
            self.processStartIdentityProvider(liveIdentity.processIdentifier) == liveIdentity.processStartIdentity
        }
    }
}
