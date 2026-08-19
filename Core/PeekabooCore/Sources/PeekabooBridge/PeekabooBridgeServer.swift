import CoreGraphics
import Foundation
import os.log
import PeekabooAutomationKit
import PeekabooFoundation
import Security

public struct PeekabooBridgePeer: Sendable {
    public let processIdentifier: pid_t
    public let auditTokenProcessIdentifierVersion: Int32?
    public let processStartIdentity: UInt64?
    public let codeSignatureHash: String?
    public let userIdentifier: uid_t?
    public let bundleIdentifier: String?
    public let teamIdentifier: String?
    let liveIdentity: PeekabooBridgeLivePeerIdentity?

    public init(
        processIdentifier: pid_t,
        auditTokenProcessIdentifierVersion: Int32? = nil,
        processStartIdentity: UInt64? = nil,
        codeSignatureHash: String? = nil,
        userIdentifier: uid_t?,
        bundleIdentifier: String?,
        teamIdentifier: String?)
    {
        self.processIdentifier = processIdentifier
        self.auditTokenProcessIdentifierVersion = auditTokenProcessIdentifierVersion
        self.processStartIdentity = processStartIdentity
        self.codeSignatureHash = codeSignatureHash
        self.userIdentifier = userIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.liveIdentity = nil
    }

    init(
        liveIdentity: PeekabooBridgeLivePeerIdentity,
        bundleIdentifier: String?,
        teamIdentifier: String?)
    {
        self.processIdentifier = liveIdentity.processIdentifier
        self.auditTokenProcessIdentifierVersion = liveIdentity.processIdentifierVersion
        self.processStartIdentity = liveIdentity.processStartIdentity
        self.codeSignatureHash = liveIdentity.codeSignatureHash
        self.userIdentifier = liveIdentity.effectiveUserIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.liveIdentity = liveIdentity
    }
}

struct PeekabooBridgeHeldPointerOwnerBinding {
    let peerIdentity: ApplicationProcessIdentity
    var pendingBeginTarget: DesktopTargetIdentity?
    var activeReceipt: ExactWindowHeldPointerReceipt?
    var closedAt: ContinuousClock.Instant?
}

struct PeekabooBridgeReceiptlessNegotiation {
    let protocolVersion: PeekabooBridgeProtocolVersion
    let recordedAt: ContinuousClock.Instant
}

@MainActor
public final class PeekabooBridgeServer {
    let services: any PeekabooBridgeServiceProviding
    let hostKind: PeekabooBridgeHostKind
    let allowlistedTeams: Set<String>
    let allowlistedBundles: Set<String>
    nonisolated let supportedVersions: ClosedRange<PeekabooBridgeProtocolVersion>
    nonisolated let operationReceiptSessionCapacity: Int
    let allowedOperations: Set<PeekabooBridgeOperation>
    let hostIdentity: PeekabooBridgeHostIdentity?
    let hostCapabilities: Set<String>
    let servingSocketPath: String?
    var agentExecutionRunner: (any PeekabooBridgeAgentExecutionRunning)?
    let daemonControl: (any PeekabooDaemonControlProviding)?
    let postEventAccessRequester: @MainActor @Sendable () -> Bool
    let permissionStatusEvaluator: @MainActor @Sendable (_ allowAppleScriptLaunch: Bool) -> PermissionsStatus
    let windowOwnerProcessIdentifierProvider: @Sendable (CGWindowID) -> pid_t?
    let windowBoundsProvider: @Sendable (CGWindowID) -> CGRect?
    let maximizedVisibleWorkAreaProvider: @MainActor @Sendable (CGRect) -> CGRect?
    let processStartIdentityProvider: @Sendable (pid_t) -> UInt64?
    let desktopMutationWatermarkStore: DesktopMutationWatermarkStore?
    let desktopOperationLaneCoordinator: DesktopOperationLaneCoordinator
    let automationActivityObserver: (@Sendable (pid_t) -> Void)?
    let encoder: JSONEncoder
    let decoder: JSONDecoder
    let logger = Logger(subsystem: "boo.peekaboo.bridge", category: "server")
    var heldPointerBridgeOwners: [ExactWindowHeldPointerOwner: PeekabooBridgeHeldPointerOwnerBinding] = [:]
    var receiptlessNegotiations: [PeekabooBridgeLivePeerIdentity: PeekabooBridgeReceiptlessNegotiation] = [:]
    #if DEBUG
    var allowsAuthenticatedAgentExecutionPeerForTesting = false
    var requestDecodeObserverForTesting: (@Sendable () -> Void)?
    var admissionRefusalObserverForTesting: (@Sendable () async -> Void)?
    #endif

    public init(
        services: any PeekabooBridgeServiceProviding,
        hostKind: PeekabooBridgeHostKind = .gui,
        allowlistedTeams: Set<String>,
        allowlistedBundles: Set<String>,
        supportedVersions: ClosedRange<PeekabooBridgeProtocolVersion> = PeekabooBridgeConstants.supportedProtocolRange,
        operationReceiptSessionCapacity: Int = 16384,
        allowedOperations: Set<PeekabooBridgeOperation> = PeekabooBridgeOperation.remoteDefaultAllowlist,
        hostIdentity: PeekabooBridgeHostIdentity? = .current(),
        hostCapabilities: Set<String> = [],
        servingSocketPath: String? = nil,
        daemonControl: (any PeekabooDaemonControlProviding)? = nil,
        desktopMutationWatermarkStore: DesktopMutationWatermarkStore? = nil,
        desktopOperationLaneCoordinator: DesktopOperationLaneCoordinator = .shared,
        postEventAccessEvaluator: (@MainActor @Sendable () -> Bool)? = nil,
        postEventAccessRequester: (@MainActor @Sendable () -> Bool)? = nil,
        permissionStatusEvaluator: (@MainActor @Sendable (_ allowAppleScriptLaunch: Bool) -> PermissionsStatus)? = nil,
        automationActivityObserver: (@Sendable (pid_t) -> Void)? = nil,
        windowOwnerProcessIdentifierProvider: @escaping @Sendable (CGWindowID) -> pid_t? =
            SystemIdentityResolver.windowOwnerProcessIdentifier,
        windowBoundsProvider: @escaping @Sendable (CGWindowID) -> CGRect? = {
            SystemIdentityResolver.windowIdentity($0)?.bounds
        },
        maximizedVisibleWorkAreaProvider: (@MainActor @Sendable (CGRect) -> CGRect?)? = nil,
        processStartIdentityProvider: @escaping @Sendable (pid_t) -> UInt64? =
            SystemIdentityResolver.processStartIdentity,
        encoder: JSONEncoder = .peekabooBridgeEncoder(),
        decoder: JSONDecoder = .peekabooBridgeDecoder())
    {
        self.services = services
        self.hostKind = hostKind
        self.allowlistedTeams = allowlistedTeams
        self.allowlistedBundles = allowlistedBundles
        self.supportedVersions = supportedVersions
        self.operationReceiptSessionCapacity = operationReceiptSessionCapacity
        self.allowedOperations = allowedOperations.subtracting([._appleScriptProbe])
        self.servingSocketPath = servingSocketPath
        self.agentExecutionRunner = servingSocketPath == nil ? nil : PeekabooBridgeLiveAgentExecutionRunner()
        self.hostIdentity = hostIdentity
        var resolvedHostCapabilities = protocolHostCapabilities(
            hostCapabilities,
            supportedVersions: supportedVersions,
            supportsExplicitSnapshotPublication: services.snapshots.supportsExplicitSnapshotPublication)
        if supportedVersions.upperBound >= PeekabooBridgeConstants.browserConnectionReceiptVersion,
           self.allowedOperations.isSuperset(of: [
               .browserStatus,
               .browserConnect,
               .browserDisconnect,
               .browserExecute,
           ])
        {
            resolvedHostCapabilities.insert(PeekabooBridgeHostCapability.browserConnectionReceipts)
        }
        let registeredScreenCaptureKitOwnership = services.supportsScreenCaptureKitProcessOwnership &&
            (try? ScreenCaptureKitOwnerLease.registerCurrentProcessCapability()) != nil
        if hostIdentity?.processStartIdentity != nil {
            resolvedHostCapabilities.insert(PeekabooBridgeHostCapability.hostGenerationIdentity)
        }
        if hostIdentity?.codeSignatureHash != nil {
            resolvedHostCapabilities.insert(PeekabooBridgeHostCapability.codeSignatureBuildIdentity)
        }
        if self.allowedOperations.contains(.desktopObservation) {
            resolvedHostCapabilities.insert(PeekabooBridgeHostCapability.desktopObservationOCR)
            if services.supportsDesktopObservationCaptureEngine {
                resolvedHostCapabilities.insert(PeekabooBridgeHostCapability.desktopObservationCaptureEngine)
            }
            if registeredScreenCaptureKitOwnership {
                resolvedHostCapabilities.insert(PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership)
            }
        }
        if supportedVersions.upperBound >= PeekabooBridgeConstants.agentExecutionTraceVersion,
           self.allowedOperations.contains(.agentExecutionTrace),
           servingSocketPath != nil,
           self.agentExecutionRunner != nil
        {
            resolvedHostCapabilities.insert(PeekabooBridgeHostCapability.agentExecutionTrace)
        } else {
            resolvedHostCapabilities.remove(PeekabooBridgeHostCapability.agentExecutionTrace)
        }
        if self.allowedOperations.contains(.launchApplicationWithOptions),
           services.applications.supportsSafeBackgroundApplicationLaunchNoOp
        {
            resolvedHostCapabilities.insert(PeekabooBridgeHostCapability.safeBackgroundApplicationLaunchNoOp)
        }
        if self.allowedOperations.contains(.activateApplication),
           services.applications.supportsProcessGenerationPinnedApplicationActivation
        {
            resolvedHostCapabilities.insert(
                PeekabooBridgeHostCapability.processGenerationPinnedApplicationActivation)
        }
        if self.allowedOperations.contains(.hideApplication),
           services.applications.supportsProcessGenerationPinnedApplicationHide
        {
            resolvedHostCapabilities.insert(
                PeekabooBridgeHostCapability.processGenerationPinnedApplicationHide)
        }
        self.hostCapabilities = resolvedHostCapabilities
        self.daemonControl = daemonControl
        self.desktopMutationWatermarkStore = desktopMutationWatermarkStore
        self.desktopOperationLaneCoordinator = desktopOperationLaneCoordinator
        self.automationActivityObserver = automationActivityObserver
        self.windowOwnerProcessIdentifierProvider = windowOwnerProcessIdentifierProvider
        self.windowBoundsProvider = windowBoundsProvider
        self.maximizedVisibleWorkAreaProvider = maximizedVisibleWorkAreaProvider ?? { bounds in
            WindowMutationGeometryPostcondition.currentMaximizedVisibleWorkArea(for: bounds)
        }
        self.processStartIdentityProvider = processStartIdentityProvider
        let resolvedPostEventAccessEvaluator = postEventAccessEvaluator ?? { [services] in
            services.permissions.checkPostEventPermission()
        }
        self.postEventAccessRequester = postEventAccessRequester ?? { [services] in
            services.permissions.requestPostEventPermission(interactive: true)
        }
        if let permissionStatusEvaluator, postEventAccessEvaluator != nil {
            self.permissionStatusEvaluator = { allowAppleScriptLaunch in
                permissionStatusEvaluator(allowAppleScriptLaunch)
                    .withPostEvent(resolvedPostEventAccessEvaluator())
            }
        } else if let permissionStatusEvaluator {
            self.permissionStatusEvaluator = permissionStatusEvaluator
        } else {
            self.permissionStatusEvaluator = { [services] _ in
                let status = services.permissions.checkAllPermissions()
                guard postEventAccessEvaluator != nil else { return status }
                return status.withPostEvent(resolvedPostEventAccessEvaluator())
            }
        }
        self.encoder = encoder
        self.decoder = decoder
    }

    #if DEBUG
    func setAgentExecutionRunnerForTesting(_ runner: (any PeekabooBridgeAgentExecutionRunning)?) {
        self.agentExecutionRunner = runner
    }

    func allowAuthenticatedAgentExecutionPeerForTesting() {
        self.allowsAuthenticatedAgentExecutionPeerForTesting = true
    }

    func setRequestDecodeObserverForTesting(_ observer: (@Sendable () -> Void)?) {
        self.requestDecodeObserverForTesting = observer
    }

    func setAdmissionRefusalObserverForTesting(_ observer: (@Sendable () async -> Void)?) {
        self.admissionRefusalObserverForTesting = observer
    }
    #endif

    func handleProjectedAction(
        _ payload: PeekabooBridgeProjectedActionRequest,
        peer: PeekabooBridgePeer?) async -> Data
    {
        do {
            let request = try payload.validatedRequest()
            let handled = try await self.route(request, peer: peer)
            return try self.encoder.encode(PeekabooBridgeResponse.projectedActionForCurrentRequestVocabulary(
                response: handled.response,
                outcome: handled.outcome?.routed(to: .bridge).projection))
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            self.logger.error(
                "projected bridge request failed code=\(envelope.code.rawValue, privacy: .public)")
            return self.encodeProjectedError(envelope)
        } catch is CancellationError {
            self.logger.debug("projected bridge request cancelled after its client disconnected")
            return self.encodeProjectedError(PeekabooBridgeErrorEnvelope(
                code: .timeout,
                message: "Bridge request was cancelled"))
        } catch {
            self.logger.error("projected bridge request failed code=internal_error")
            return self.encodeProjectedError(PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: error.localizedDescription,
                details: "\(error)"))
        }
    }

    private func encodeProjectedError(_ envelope: PeekabooBridgeErrorEnvelope) -> Data {
        let response = PeekabooBridgeResponse.projectedActionForCurrentRequestVocabulary(
            response: .error(envelope),
            outcome: envelope.actionOutcome)
        guard let data = try? self.encoder.encode(response), !data.isEmpty else {
            return PeekabooBridgeResponse.encodeError(envelope, using: self.encoder)
        }
        return data
    }

    static func bridgeErrorEnvelope(
        for error: any Error,
        operation: PeekabooBridgeOperation) -> PeekabooBridgeErrorEnvelope
    {
        if let envelope = self.actionFailureEnvelope(for: error) {
            return envelope
        }
        if let error = error as? ApplicationLifecycleRefusalError {
            let failure = DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .foregroundConsentRequired,
                message: error.userMessage,
                hint: error.hint)
            return .init(
                code: .internalError,
                actionFailure: failure,
                details: error.hint,
                context: error.bridgeContext)
        }
        if let error = error as? ApplicationLifecycleReadOnlyFailureError {
            let base = self.bridgeErrorEnvelope(for: error.underlyingError, operation: operation)
            return .init(
                code: base?.code ?? .internalError,
                message: error.userMessage,
                details: base?.details,
                permission: base?.permission,
                kind: base?.kind,
                context: ApplicationLifecycleReadOnlyFailureError.bridgeContext,
                operationMayHaveCompleted: false)
        }
        if let error = error as? PeekabooError,
           let envelope = bridgeErrorEnvelope(for: error, operation: operation)
        {
            return envelope
        }
        if let error = error as? NotFoundError,
           let envelope = bridgeErrorEnvelope(for: error, operation: operation)
        {
            return envelope
        }
        if let error = error as? DesktopObservationError {
            switch error {
            case .targetNotFound, .targetChanged:
                return .init(
                    code: .notFound,
                    message: error.localizedDescription,
                    details: "\(error)",
                    kind: .windowNotFound)
            case .ambiguousWindowTitle:
                return .init(
                    code: .invalidRequest,
                    message: error.localizedDescription,
                    details: "\(error)")
            case .unsupportedTarget:
                return .init(
                    code: .operationNotSupported,
                    message: error.localizedDescription,
                    details: "\(error)")
            }
        }
        if let error = error as? CaptureROIError {
            let code: PeekabooBridgeErrorCode = switch error {
            case .invalidFormat, .invalidBounds, .exactWindowRequired, .missingExactWindowReceipt,
                 .outOfBounds, .outputTooLarge:
                .invalidRequest
            case .invalidSourceImage, .unsupportedScale, .hostDidNotApplyROI:
                .internalError
            }
            return .init(
                code: code,
                message: error.localizedDescription,
                details: "\(error)",
                context: "capture_roi:\(error.code)")
        }

        if let error = error as? DockError {
            let kind: PeekabooBridgeErrorKind?
            let context: String?
            switch error {
            case .dockNotFound:
                (kind, context) = (.dockNotFound, nil)
            case .dockListNotFound:
                (kind, context) = (.dockListNotFound, nil)
            case let .itemNotFound(name):
                (kind, context) = (.dockItemNotFound, name)
            case let .menuItemNotFound(name):
                (kind, context) = (.menuItemNotFound, name)
            case .positionNotFound:
                (kind, context) = (.positionNotFound, nil)
            case .launchFailed, .scriptError:
                (kind, context) = (nil, nil)
            }
            if let kind {
                return .init(
                    code: .notFound,
                    message: error.localizedDescription,
                    details: "\(error)",
                    kind: kind,
                    context: context)
            }
        }

        // Prefer the underlying error description so CLI clients do not only
        // see a generic message with the real text buried in details.
        let userMessage = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        return .init(
            code: .internalError,
            message: userMessage.isEmpty ? "Bridge operation failed" : userMessage,
            details: "\(error)")
    }

    private static func actionFailureEnvelope(for error: any Error) -> PeekabooBridgeErrorEnvelope? {
        if let failure = error as? DesktopActionFailure {
            return .init(
                code: .internalError,
                actionFailure: failure.routed(to: .bridge),
                details: "\(error)")
        }
        guard let error = error as? InputDeliveryIndeterminateError else { return nil }
        let unitCount = error.emittedUnitCount.flatMap { DesktopActionOutcome.DispatchUnitCount($0) }
        let failure = DesktopActionFailure.indeterminate(
            route: .bridge,
            evidence: .completionUnknown,
            unitCount: unitCount,
            message: error.localizedDescription,
            hint: "Observe the target before retrying this operation.",
            causeDescription: error.causeDescription)
        return .init(
            code: .internalError,
            actionFailure: failure,
            details: "\(error)")
    }

    private static func bridgeErrorEnvelope(
        for error: NotFoundError,
        operation: PeekabooBridgeOperation) -> PeekabooBridgeErrorEnvelope?
    {
        if error.code == .menuNotFound {
            let itemContext = error.context["menuItem"]
                ?? error.context["item"]
                ?? error.context["submenu"]
                ?? error.context["menuExtra"]
            if itemContext != nil || error.context["availableItems"] != nil {
                return .init(
                    code: .notFound,
                    message: error.userMessage,
                    details: "\(error)",
                    kind: .menuItemNotFound,
                    context: itemContext)
            }
        }
        return self.bridgeErrorEnvelope(for: error.asPeekabooError, operation: operation)
    }

    private static func bridgeErrorEnvelope(
        for error: PeekabooError,
        operation: PeekabooBridgeOperation) -> PeekabooBridgeErrorEnvelope?
    {
        let details = "\(error)"
        return switch error {
        case let .invalidInput(message):
            .init(code: .invalidRequest, message: message, details: details)
        case .permissionDeniedAccessibility, .permissionDeniedScreenRecording,
             .permissionDeniedEventSynthesizing:
            .init(
                code: .permissionDenied,
                message: error.localizedDescription,
                details: details,
                permission: Self.bridgePermission(for: error))
        case let .serviceUnavailable(message):
            .init(code: .operationNotSupported, message: message, details: details)
        case let .notImplemented(message):
            .init(
                code: .operationNotSupported,
                message: "Operation \(operation.rawValue) is not supported: \(message)",
                details: details)
        case let .appNotFound(name):
            Self.notFoundEnvelope(error, kind: .appNotFound, context: name)
        case let .windowNotFound(criteria):
            Self.notFoundEnvelope(error, kind: .windowNotFound, context: criteria)
        case let .elementNotFound(identifier):
            Self.notFoundEnvelope(error, kind: .elementNotFound, context: identifier)
        case let .menuNotFound(app):
            Self.notFoundEnvelope(error, kind: .menuNotFound, context: app)
        case let .menuItemNotFound(item):
            Self.notFoundEnvelope(error, kind: .menuItemNotFound, context: item)
        case let .snapshotNotFound(snapshotId):
            Self.notFoundEnvelope(error, kind: .snapshotNotFound, context: snapshotId)
        case let .snapshotNotAvailable(message):
            Self.notFoundEnvelope(error, kind: .snapshotNotFound, context: message)
        case let .snapshotStale(reason):
            .init(
                code: .invalidRequest,
                message: error.localizedDescription,
                details: details,
                kind: .snapshotStale,
                context: reason)
        case .notFound:
            .init(code: .notFound, message: error.localizedDescription, details: details)
        case .accessibilityIncomplete:
            .init(
                code: .internalError,
                message: error.localizedDescription,
                details: details,
                context: PeekabooBridgeErrorEnvelope.standardizedErrorContextPrefix + error.code.rawValue)
        case .captureFailed:
            .init(
                code: .internalError,
                message: error.localizedDescription,
                details: details,
                context: PeekabooBridgeErrorEnvelope.standardizedErrorContextPrefix + error.code.rawValue)
        case .timeout, .captureTimeout:
            .init(code: .timeout, message: error.localizedDescription, details: details)
        default:
            nil
        }
    }

    private static func notFoundEnvelope(
        _ error: PeekabooError,
        kind: PeekabooBridgeErrorKind,
        context: String?) -> PeekabooBridgeErrorEnvelope
    {
        .init(
            code: .notFound,
            message: error.localizedDescription,
            details: "\(error)",
            kind: kind,
            context: context)
    }

    func validatePeerAuthorization(_ peer: PeekabooBridgePeer?) throws {
        guard !self.allowlistedTeams.isEmpty || !self.allowlistedBundles.isEmpty else { return }
        guard let peer else {
            throw PeekabooBridgeErrorEnvelope(
                code: .unauthorizedClient,
                message: "Unsigned bridge clients are not allowed for this listener")
        }

        if !self.allowlistedTeams.isEmpty {
            guard let team = peer.teamIdentifier, self.allowlistedTeams.contains(team) else {
                let team = peer.teamIdentifier ?? "<unknown>"
                throw PeekabooBridgeErrorEnvelope(
                    code: .unauthorizedClient,
                    message: "Team \(team) is not authorized")
            }
        }

        if !self.allowlistedBundles.isEmpty {
            guard let bundle = peer.bundleIdentifier, self.allowlistedBundles.contains(bundle) else {
                let bundle = peer.bundleIdentifier ?? "<unknown>"
                throw PeekabooBridgeErrorEnvelope(
                    code: .unauthorizedClient,
                    message: "Bundle \(bundle) is not authorized")
            }
        }

        if let uid = peer.userIdentifier, uid != getuid() {
            throw PeekabooBridgeErrorEnvelope(
                code: .unauthorizedClient,
                message: "UID \(uid) is not authorized for this listener")
        }
    }

    func handleAuthorizedWithDesktopMutationBarrier(
        _ request: PeekabooBridgeRequest,
        peer: PeekabooBridgePeer?,
        permissions: PermissionsStatus) async throws -> PeekabooBridgeHandledResponse
    {
        if request.bypassesOuterDesktopMutationLane {
            return try await self.handleAuthorized(request, peer: peer, permissions: permissions)
        }
        let nativeLeafOwnsLane = request.nativeLeafOwnsDesktopOperationLane &&
            self.services.ownsDesktopOperationLane(for: request.operation)
        if let proposedReadLane = request.desktopReadOperationLane, !nativeLeafOwnsLane {
            return try await self.withValidatedDesktopReadOperationLane(
                for: request,
                proposed: proposedReadLane)
            {
                try await self.handleAuthorizedWithOwnedDesktopOperationLane(
                    request,
                    peer: peer,
                    permissions: permissions)
            }
        }

        if request.mayMutateDesktop, !nativeLeafOwnsLane {
            return try await self.desktopOperationLaneCoordinator.run(
                scope: request.desktopOperationScope,
                access: .write)
            {
                try await self.handleAuthorizedWithOwnedDesktopOperationLane(
                    request,
                    peer: peer,
                    permissions: permissions)
            }
        }
        return try await self.handleAuthorizedWithOwnedDesktopOperationLane(
            request,
            peer: peer,
            permissions: permissions)
    }

    private func handleAuthorizedWithOwnedDesktopOperationLane(
        _ request: PeekabooBridgeRequest,
        peer: PeekabooBridgePeer?,
        permissions: PermissionsStatus) async throws -> PeekabooBridgeHandledResponse
    {
        guard request.mayMutateDesktop else {
            return try await self.handleAuthorized(request, peer: peer, permissions: permissions)
        }

        guard let desktopMutationWatermarkStore else {
            try self.validatePreDispatchState(for: request)
            return try await self.handleAuthorized(request, peer: peer, permissions: permissions)
        }
        try self.validatePreDispatchState(for: request)
        let mutation: DesktopMutationWatermarkStore.PendingMutation
        do {
            mutation = try await desktopMutationWatermarkStore.beginMutationCancellable(
                target: request.desktopOperationScope)
        } catch {
            throw PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: "Could not establish the desktop mutation barrier; operation was not executed",
                details: error.localizedDescription)
        }

        do {
            try self.validatePreDispatchState(for: request)
        } catch {
            do {
                try desktopMutationWatermarkStore.cancelMutation(mutation)
            } catch {
                throw PeekabooBridgeErrorEnvelope(
                    code: .internalError,
                    message: "Could not cancel the desktop mutation barrier; operation was not executed",
                    details: error.localizedDescription)
            }
            throw error
        }

        let response: PeekabooBridgeHandledResponse?
        let operationError: (any Error)?
        do {
            response = try await self.handleAuthorized(request, peer: peer, permissions: permissions)
            operationError = nil
        } catch {
            response = nil
            operationError = error
        }

        if let failure = operationError as? DesktopActionFailure,
           failure.outcome.dispatchState == .none
        {
            do {
                try desktopMutationWatermarkStore.cancelMutation(mutation)
            } catch {
                throw PeekabooBridgeErrorEnvelope(
                    code: .internalError,
                    message: "Could not cancel the desktop mutation barrier after pre-dispatch refusal",
                    details: error.localizedDescription)
            }
            throw failure
        }

        let completedLegacyResponse: PeekabooBridgeResponse?
        do {
            completedLegacyResponse = try await self.completeDesktopMutation(
                mutation,
                request: request,
                response: response?.response,
                store: desktopMutationWatermarkStore)
        } catch {
            throw error
        }

        if let operationError {
            throw operationError
        }
        guard let response else {
            throw PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: "Desktop operation returned neither a response nor an error")
        }
        return completedLegacyResponse.map(response.replacingResponse) ?? response
    }

    private func validatePreDispatchState(for request: PeekabooBridgeRequest) throws {
        do {
            try PeekabooBridgeRequestContext.checkRequestIsActive()
            try self.validatePinnedWindowMutation(request)
        } catch is CancellationError {
            throw PeekabooBridgeOperationResultSemantics.canonicalFailure(
                .init(code: .timeout, message: "Bridge request was cancelled before dispatch"),
                request: request,
                stage: .preDispatch(.requestCancelled))
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw PeekabooBridgeOperationResultSemantics.canonicalFailure(
                envelope,
                request: request,
                stage: .preDispatch(PeekabooBridgeOperationResultSemantics.preDispatchReason(for: envelope)))
        }
    }

    private func validatePinnedWindowMutation(_ request: PeekabooBridgeRequest) throws {
        guard let pinned = request.pinnedWindowMutation else { return }
        let identity = pinned.identity
        guard identity.capturedBounds != nil else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Pinned window mutation receipt requires capture-time bounds")
        }
        let resolvedWindowID = CGWindowID(exactly: identity.windowID)
        let currentOwner = resolvedWindowID.flatMap(self.windowOwnerProcessIdentifierProvider)
        let currentBounds = resolvedWindowID.flatMap(self.windowBoundsProvider)
        guard case let .windowId(windowID) = pinned.target,
              windowID == identity.windowID,
              resolvedWindowID != nil,
              let capturedBounds = identity.capturedBounds,
              self.processStartIdentityProvider(identity.ownerProcessIdentifier) ==
              identity.ownerProcessStartIdentity,
              (currentOwner == identity.ownerProcessIdentifier && currentBounds == capturedBounds) ||
              (currentOwner == nil && currentBounds == nil && identity.isMinimized == true)
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Pinned window target disappeared or changed owner/process generation/bounds")
        }
    }

    private func completeDesktopMutation(
        _ mutation: DesktopMutationWatermarkStore.PendingMutation,
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse?,
        store: DesktopMutationWatermarkStore) async throws -> PeekabooBridgeResponse?
    {
        let completedAt = Date()
        let completion: DesktopMutationWatermarkStore.MutationCompletion
        do {
            completion = try store.completeMutation(mutation, through: completedAt)
        } catch {
            self.logger.error(
                "Desktop mutation barrier finalization failed: \(error.localizedDescription, privacy: .private)")
            throw PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: "The desktop operation completed, but its snapshot safety barrier could not be finalized",
                details: error.localizedDescription,
                operationMayHaveCompleted: true)
        }

        let completedResponse = response.map {
            Self.annotatingDesktopMutationCompletion($0, completion: completion)
        }
        if completion.allowsObservationPreservation,
           let snapshotId = Self.preservedSnapshotID(for: request, response: completedResponse)
        {
            do {
                _ = try await self.services.snapshots.invalidateImplicitLatestSnapshot(
                    through: completion.cutoff,
                    preserving: snapshotId,
                    preservedAt: completion.cutoff)
            } catch {
                let failure = error.localizedDescription
                self.logger.error(
                    "Failed to preserve bridge observation after desktop mutation: \(failure, privacy: .private)")
            }
        }
        return completedResponse
    }

    private static func preservedSnapshotID(
        for request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse?) -> String?
    {
        guard case let .desktopObservation(observationRequest) = request,
              case let .desktopObservation(result)? = response
        else { return nil }
        return result.elements?.snapshotId ?? observationRequest.output.snapshotID
    }

    private static func annotatingDesktopMutationCompletion(
        _ response: PeekabooBridgeResponse,
        completion: DesktopMutationWatermarkStore.MutationCompletion) -> PeekabooBridgeResponse
    {
        switch response {
        case let .elementDetection(result):
            .elementDetection(self.annotatingDetectionResult(result, completion: completion))
        case let .desktopObservation(result):
            .desktopObservation(DesktopObservationResult(
                target: result.target,
                capture: result.capture,
                elements: result.elements.map { self.annotatingDetectionResult($0, completion: completion) },
                ocr: result.ocr,
                files: result.files,
                timings: result.timings,
                diagnostics: DesktopObservationDiagnostics(
                    warnings: result.diagnostics.warnings,
                    stateSnapshot: result.diagnostics.stateSnapshot,
                    target: result.diagnostics.target,
                    desktopMutationCompletedAt: completion.cutoff,
                    desktopMutationPreservationAllowed: completion.allowsObservationPreservation),
                captureContentDigest: result.captureContentDigest))
        default:
            response
        }
    }

    private static func annotatingDetectionResult(
        _ result: ElementDetectionResult,
        completion: DesktopMutationWatermarkStore.MutationCompletion) -> ElementDetectionResult
    {
        let metadata = result.metadata
        return ElementDetectionResult(
            snapshotId: result.snapshotId,
            screenshotPath: result.screenshotPath,
            elements: result.elements,
            metadata: DetectionMetadata(
                detectionTime: metadata.detectionTime,
                elementCount: metadata.elementCount,
                method: metadata.method,
                warnings: metadata.warnings,
                windowContext: metadata.windowContext,
                isDialog: metadata.isDialog,
                truncationInfo: metadata.truncationInfo,
                desktopMutationCompletedAt: completion.cutoff,
                desktopMutationPreservationAllowed: completion.allowsObservationPreservation))
    }

    func validateOperationAccess(
        for request: PeekabooBridgeRequest,
        peer: PeekabooBridgePeer? = nil,
        permissions: PermissionsStatus,
        effectiveOps: Set<PeekabooBridgeOperation>) throws
    {
        let op = request.operation
        if case .handshake = request {
            return
        }

        guard self.allowedOperationsToAdvertise().contains(op) else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Operation \(op.rawValue) is not supported by this host")
        }
        if let minimumVersion = request.minimumNegotiatedProtocolVersion {
            let session = PeekabooBridgeRequestContext.negotiatedSessionCapabilities
            let negotiatedVersion = session?.protocolVersion ?? self.receiptlessProtocolVersion(for: peer)
            guard (negotiatedVersion ?? .init(major: 0, minor: 0)) >= minimumVersion,
                  !request.requiresBackgroundStatelessClickVariantSupport || session?.statelessClickVariants == true,
                  !request.requiresExactWindowHeldPointerLifecycleSupport ||
                  session?.exactWindowHeldPointerLifecycle == true
            else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message:
                    "Operation \(op.rawValue) requires its negotiated Bridge protocol " +
                        "\(minimumVersion.major).\(minimumVersion.minor) capability")
            }
        }
        if PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics,
           op == .exactDialogEnterText,
           !self.services.dialogs.supportsBackgroundExactDialogInput
        {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Operation \(op.rawValue) is not supported by this host's background dialog provider")
        }

        if request.requiresPinnedWindowMutationReceipt, request.pinnedWindowMutation == nil {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Operation \(op.rawValue) requires a process-generation window mutation receipt")
        }

        if case let .targetedClick(payload) = request {
            try Self.validateTargetedClickAccess(payload, permissions: permissions)
        }
        switch request {
        case let .scroll(payload):
            guard payload.request.foreground else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .invalidRequest,
                    message: "The scroll operation requires foreground=true; " +
                        "use targetedScroll for background AX input")
            }
        case let .targetedScroll(payload):
            guard !payload.request.foreground else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .invalidRequest,
                    message: "The targetedScroll operation requires foreground=false")
            }
        default:
            break
        }

        let defersClassicScreenRecordingPermission = Self.defersClassicScreenRecordingPermission(
            for: request,
            hostCapabilities: self.hostCapabilities,
            allowedOperations: self.allowedOperations)
        let requiredPermissions = Self.requiredPermissions(for: request)
        let missingPermissions = requiredPermissions
            .subtracting(Self.grantedPermissions(from: permissions))
        let undeferredMissingPermissions = defersClassicScreenRecordingPermission
            ? missingPermissions.subtracting([.screenRecording])
            : missingPermissions
        guard effectiveOps.contains(op) || defersClassicScreenRecordingPermission,
              undeferredMissingPermissions.isEmpty
        else {
            let missingPermission = undeferredMissingPermissions.min { $0.rawValue < $1.rawValue }
            throw PeekabooBridgeErrorEnvelope(
                code: .permissionDenied,
                message: "Operation \(op.rawValue) is not allowed with current permissions",
                permission: missingPermission)
        }
    }

    static func requiredPermissions(
        for request: PeekabooBridgeRequest) -> Set<PeekabooBridgePermissionKind>
    {
        if PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics,
           request.operation == .exactDialogEnterText
        {
            return [.accessibility]
        }
        if request.operation == .exactDialogEnterText {
            return [.accessibility, .postEvent]
        }
        return request.operation.requiredPermissions
    }

    nonisolated static func defersClassicScreenRecordingPermission(
        for request: PeekabooBridgeRequest,
        hostCapabilities: Set<String>,
        allowedOperations: Set<PeekabooBridgeOperation>) -> Bool
    {
        guard case let .desktopObservation(payload) = request else { return false }
        return payload.capture.engine == .legacy &&
            hostCapabilities.contains(PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership) &&
            allowedOperations.contains(.desktopObservation)
    }

    private static func validateTargetedClickAccess(
        _ request: PeekabooBridgeTargetedClickRequest,
        permissions: PermissionsStatus) throws
    {
        guard permissions.accessibility else {
            throw PeekabooBridgeErrorEnvelope(
                code: .permissionDenied,
                message: "Background clicks require Accessibility permission",
                permission: .accessibility)
        }
        guard !request.requiresPostEventPermission || permissions.postEvent else {
            throw PeekabooBridgeErrorEnvelope(
                code: .permissionDenied,
                message: "This background click requires Event Synthesizing permission",
                permission: .postEvent)
        }
    }
}

private func protocolHostCapabilities(
    _ declaredCapabilities: Set<String>,
    supportedVersions: ClosedRange<PeekabooBridgeProtocolVersion>,
    supportsExplicitSnapshotPublication: Bool) -> Set<String>
{
    var capabilities = declaredCapabilities
    if supportedVersions.upperBound >= PeekabooBridgeConstants.desktopActionOutcomeProjectionVersion {
        capabilities.insert(PeekabooBridgeHostCapability.desktopActionOutcomeProjection)
    }
    if supportedVersions.upperBound >= PeekabooBridgeConstants.explicitSnapshotPublicationVersion,
       supportsExplicitSnapshotPublication
    {
        capabilities.insert(PeekabooBridgeHostCapability.explicitSnapshotPublication)
    }
    if supportedVersions.upperBound >= PeekabooBridgeConstants.exactDialogInputExecutionVersion {
        capabilities.insert(PeekabooBridgeHostCapability.exactDialogInputExecution)
    }
    if supportedVersions.upperBound >= PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion {
        capabilities.insert(PeekabooBridgeHostCapability.exactForcedDialogDismissExecution)
        capabilities.insert(PeekabooBridgeHostCapability.dialogInputFocusPolicy)
    }
    if supportedVersions.upperBound >= PeekabooBridgeConstants.plannerInventoryTransportVersion {
        capabilities.insert(PeekabooBridgeHostCapability.plannerInventoryTransport)
    }
    if supportedVersions.upperBound >= PeekabooBridgeConstants.exactWindowHeldPointerLifecycleVersion {
        capabilities.insert(PeekabooBridgeHostCapability.exactWindowHeldPointerLifecycle)
    }
    if supportedVersions.upperBound >= PeekabooBridgeConstants.statelessClickVariantVersion {
        capabilities.insert(PeekabooBridgeHostCapability.statelessClickVariants)
    }
    return capabilities
}
