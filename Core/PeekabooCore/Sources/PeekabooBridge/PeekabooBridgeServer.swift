import CoreGraphics
import Foundation
import os.log
import PeekabooAutomationKit
import PeekabooFoundation
import Security

public struct PeekabooBridgePeer: Sendable {
    public let processIdentifier: pid_t
    public let userIdentifier: uid_t?
    public let bundleIdentifier: String?
    public let teamIdentifier: String?

    public init(
        processIdentifier: pid_t,
        userIdentifier: uid_t?,
        bundleIdentifier: String?,
        teamIdentifier: String?)
    {
        self.processIdentifier = processIdentifier
        self.userIdentifier = userIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
    }
}

@MainActor
public final class PeekabooBridgeServer {
    let services: any PeekabooBridgeServiceProviding
    let hostKind: PeekabooBridgeHostKind
    let allowlistedTeams: Set<String>
    let allowlistedBundles: Set<String>
    let supportedVersions: ClosedRange<PeekabooBridgeProtocolVersion>
    let allowedOperations: Set<PeekabooBridgeOperation>
    let hostIdentity: PeekabooBridgeHostIdentity?
    let hostCapabilities: Set<String>
    let daemonControl: (any PeekabooDaemonControlProviding)?
    let postEventAccessRequester: @MainActor @Sendable () -> Bool
    let permissionStatusEvaluator: @MainActor @Sendable (_ allowAppleScriptLaunch: Bool) -> PermissionsStatus
    let windowOwnerProcessIdentifierProvider: @Sendable (CGWindowID) -> pid_t?
    let windowBoundsProvider: @Sendable (CGWindowID) -> CGRect?
    let processStartIdentityProvider: @Sendable (pid_t) -> UInt64?
    let desktopMutationWatermarkStore: DesktopMutationWatermarkStore?
    let desktopOperationLaneCoordinator: DesktopOperationLaneCoordinator
    let automationActivityObserver: (@Sendable (pid_t) -> Void)?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    let logger = Logger(subsystem: "boo.peekaboo.bridge", category: "server")

    public init(
        services: any PeekabooBridgeServiceProviding,
        hostKind: PeekabooBridgeHostKind = .gui,
        allowlistedTeams: Set<String>,
        allowlistedBundles: Set<String>,
        supportedVersions: ClosedRange<PeekabooBridgeProtocolVersion> = PeekabooBridgeConstants.supportedProtocolRange,
        allowedOperations: Set<PeekabooBridgeOperation> = PeekabooBridgeOperation.remoteDefaultAllowlist,
        hostIdentity: PeekabooBridgeHostIdentity? = .current(),
        hostCapabilities: Set<String> = [],
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
        self.allowedOperations = allowedOperations.subtracting([._appleScriptProbe])
        self.hostIdentity = hostIdentity
        var resolvedHostCapabilities = hostCapabilities
        if supportedVersions.upperBound >= PeekabooBridgeConstants.desktopActionOutcomeProjectionVersion {
            resolvedHostCapabilities.insert(PeekabooBridgeHostCapability.desktopActionOutcomeProjection)
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
        self.hostCapabilities = resolvedHostCapabilities
        self.daemonControl = daemonControl
        self.desktopMutationWatermarkStore = desktopMutationWatermarkStore
        self.desktopOperationLaneCoordinator = desktopOperationLaneCoordinator
        self.automationActivityObserver = automationActivityObserver
        self.windowOwnerProcessIdentifierProvider = windowOwnerProcessIdentifierProvider
        self.windowBoundsProvider = windowBoundsProvider
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

    public func decodeAndHandle(_ requestData: Data, peer: PeekabooBridgePeer?) async -> Data {
        do {
            try PeekabooBridgeRequestPreflight.validate(requestData)
            let request = try self.decoder.decode(PeekabooBridgeRequest.self, from: requestData)
            if case let .projectedAction(payload) = request {
                return await self.handleProjectedAction(payload, peer: peer)
            }
            let handled = try await self.route(request, peer: peer)
            return try self.encoder.encode(handled.response)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            self.logger.error("bridge request failed: \(envelope.message, privacy: .public)")
            return PeekabooBridgeResponse.encodeError(envelope.legacyCompatible, using: self.encoder)
        } catch is CancellationError {
            self.logger.debug("bridge request cancelled after its client disconnected")
            let envelope = PeekabooBridgeErrorEnvelope(
                code: .timeout,
                message: "Bridge request was cancelled")
            return PeekabooBridgeResponse.encodeError(envelope, using: self.encoder)
        } catch {
            self.logger.error("bridge request decoding failed: \(error.localizedDescription, privacy: .public)")
            let envelope = PeekabooBridgeErrorEnvelope(
                code: .decodingFailed,
                message: "Failed to decode request",
                details: "\(error)")
            return PeekabooBridgeResponse.encodeError(envelope, using: self.encoder)
        }
    }

    private func handleProjectedAction(
        _ payload: PeekabooBridgeProjectedActionRequest,
        peer: PeekabooBridgePeer?) async -> Data
    {
        do {
            let request = try payload.validatedRequest()
            let handled = try await self.route(request, peer: peer)
            return try self.encoder.encode(PeekabooBridgeResponse.projectedAction(.init(
                response: handled.response,
                outcome: handled.outcome?.routed(to: .bridge).projection)))
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            self.logger.error("projected bridge request failed: \(envelope.message, privacy: .public)")
            return self.encodeProjectedError(envelope)
        } catch is CancellationError {
            self.logger.debug("projected bridge request cancelled after its client disconnected")
            return self.encodeProjectedError(PeekabooBridgeErrorEnvelope(
                code: .timeout,
                message: "Bridge request was cancelled"))
        } catch {
            self.logger.error("projected bridge request failed: \(error.localizedDescription, privacy: .public)")
            return self.encodeProjectedError(PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: error.localizedDescription,
                details: "\(error)"))
        }
    }

    private func encodeProjectedError(_ envelope: PeekabooBridgeErrorEnvelope) -> Data {
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .error(envelope),
            outcome: envelope.actionOutcome))
        guard let data = try? self.encoder.encode(response), !data.isEmpty else {
            return PeekabooBridgeResponse.encodeError(envelope, using: self.encoder)
        }
        return data
    }

    private func route(
        _ request: PeekabooBridgeRequest,
        peer: PeekabooBridgePeer?) async throws -> PeekabooBridgeHandledResponse
    {
        try self.validatePeerAuthorization(peer)
        try PeekabooBridgeRequestContext.checkRequestIsActive()

        let start = Date()
        let pid = peer?.processIdentifier ?? 0
        var failed = false
        defer {
            if !failed {
                let duration = Date().timeIntervalSince(start)
                let durationString = String(format: "%.3f", duration)
                let message = "bridge op=\(request.operation.rawValue) pid=\(pid) ok in \(durationString)s"
                self.logger.debug("\(message, privacy: .public)")
            }
        }

        let op = request.operation
        let permissions = self.currentPermissions()
        let effectiveOps = self.effectiveAllowedOperations(permissions: permissions)

        do {
            try self.validateOperationAccess(for: request, permissions: permissions, effectiveOps: effectiveOps)
            if let daemonControl = self.daemonControl,
               op != .daemonStatus,
               op != .daemonStop
            {
                if let conditionalControl = daemonControl as? any PeekabooConditionalDaemonControlProviding {
                    guard await conditionalControl.admitActivity(operation: op) else {
                        throw PeekabooBridgeErrorEnvelope(
                            code: .serverBusy,
                            message: "Daemon is shutting down")
                    }
                } else {
                    await daemonControl.recordActivityStart(operation: op)
                }
                do {
                    let response = try await self.handleAuthorizedWithDesktopMutationBarrier(
                        request,
                        peer: peer,
                        permissions: permissions)
                    await daemonControl.recordActivityEnd(operation: op)
                    return response
                } catch {
                    await daemonControl.recordActivityEnd(operation: op)
                    throw error
                }
            }

            return try await self.handleAuthorizedWithDesktopMutationBarrier(
                request,
                peer: peer,
                permissions: permissions)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            failed = true
            let duration = Date().timeIntervalSince(start)
            let durationString = String(format: "%.3f", duration)
            let message =
                "bridge op=\(op.rawValue) pid=\(pid) failed in \(durationString)s: \(envelope.message)"
            self.logger.error("\(message, privacy: .public)")
            throw envelope
        } catch {
            failed = true
            let duration = Date().timeIntervalSince(start)
            let durationString = String(format: "%.3f", duration)
            let message =
                "bridge op=\(op.rawValue) pid=\(pid) failed in \(durationString)s: \(error.localizedDescription)"
            self.logger.error("\(message, privacy: .public)")

            throw Self.bridgeErrorEnvelope(for: error, operation: op)
        }
    }

    static func bridgeErrorEnvelope(
        for error: any Error,
        operation: PeekabooBridgeOperation) -> PeekabooBridgeErrorEnvelope
    {
        if let envelope = self.actionFailureEnvelope(for: error) {
            return envelope
        }
        if let error = error as? ApplicationLifecycleRefusalError {
            return .init(
                code: .internalError,
                message: error.userMessage,
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

    private func validatePeerAuthorization(_ peer: PeekabooBridgePeer?) throws {
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

    private func handleAuthorizedWithDesktopMutationBarrier(
        _ request: PeekabooBridgeRequest,
        peer: PeekabooBridgePeer?,
        permissions: PermissionsStatus) async throws -> PeekabooBridgeHandledResponse
    {
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
            try PeekabooBridgeRequestContext.checkRequestIsActive()
            try self.validatePinnedWindowMutation(request)
            return try await self.handleAuthorized(request, peer: peer, permissions: permissions)
        }
        try PeekabooBridgeRequestContext.checkRequestIsActive()
        try self.validatePinnedWindowMutation(request)
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
            try PeekabooBridgeRequestContext.checkRequestIsActive()
            try self.validatePinnedWindowMutation(request)
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
                "Desktop mutation barrier finalization failed: \(error.localizedDescription, privacy: .public)")
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
                    "Failed to preserve bridge observation after desktop mutation: \(failure, privacy: .public)")
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
                    desktopMutationPreservationAllowed: completion.allowsObservationPreservation)))
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

    private func validateOperationAccess(
        for request: PeekabooBridgeRequest,
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
        guard effectiveOps.contains(op) || defersClassicScreenRecordingPermission else {
            let missingPermission = op.requiredPermissions
                .subtracting(Self.grantedPermissions(from: permissions))
                .min { $0.rawValue < $1.rawValue }
            throw PeekabooBridgeErrorEnvelope(
                code: .permissionDenied,
                message: "Operation \(op.rawValue) is not allowed with current permissions",
                permission: missingPermission)
        }
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
        // All background clicks are delivered through accessibility actions; positioned
        // pid-routed mouse events are broken on modern macOS (they land at the window corner),
        // so Event Synthesizing permission no longer enables any targeted click path.
        guard permissions.accessibility else {
            throw PeekabooBridgeErrorEnvelope(
                code: .permissionDenied,
                message: "Background clicks require Accessibility permission",
                permission: .accessibility)
        }
    }
}
