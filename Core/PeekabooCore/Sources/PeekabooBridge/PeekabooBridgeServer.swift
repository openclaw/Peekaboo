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
    let daemonControl: (any PeekabooDaemonControlProviding)?
    let postEventAccessEvaluator: @MainActor @Sendable () -> Bool
    let postEventAccessRequester: @MainActor @Sendable () -> Bool
    let permissionStatusEvaluator: @MainActor @Sendable (_ allowAppleScriptLaunch: Bool) -> PermissionsStatus
    let desktopMutationWatermarkStore: DesktopMutationWatermarkStore?
    let automationActivityObserver: (@Sendable (pid_t) -> Void)?
    private let desktopMutationGate = PeekabooBridgeMutationGate()
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
        daemonControl: (any PeekabooDaemonControlProviding)? = nil,
        desktopMutationWatermarkStore: DesktopMutationWatermarkStore? = nil,
        postEventAccessEvaluator: (@MainActor @Sendable () -> Bool)? = nil,
        postEventAccessRequester: (@MainActor @Sendable () -> Bool)? = nil,
        permissionStatusEvaluator: (@MainActor @Sendable (_ allowAppleScriptLaunch: Bool) -> PermissionsStatus)? = nil,
        automationActivityObserver: (@Sendable (pid_t) -> Void)? = nil,
        encoder: JSONEncoder = .peekabooBridgeEncoder(),
        decoder: JSONDecoder = .peekabooBridgeDecoder())
    {
        self.services = services
        self.hostKind = hostKind
        self.allowlistedTeams = allowlistedTeams
        self.allowlistedBundles = allowlistedBundles
        self.supportedVersions = supportedVersions
        self.allowedOperations = allowedOperations
        self.daemonControl = daemonControl
        self.desktopMutationWatermarkStore = desktopMutationWatermarkStore
        self.automationActivityObserver = automationActivityObserver
        self.postEventAccessEvaluator = postEventAccessEvaluator ?? { [services] in
            services.permissions.checkPostEventPermission()
        }
        self.postEventAccessRequester = postEventAccessRequester ?? { [services] in
            services.permissions.requestPostEventPermission(interactive: true)
        }
        if let permissionStatusEvaluator {
            self.permissionStatusEvaluator = permissionStatusEvaluator
        } else {
            self.permissionStatusEvaluator = { [services] allowAppleScriptLaunch in
                services.permissions.checkAllPermissions(allowAppleScriptLaunch: allowAppleScriptLaunch)
            }
        }
        self.encoder = encoder
        self.decoder = decoder
    }

    public func decodeAndHandle(_ requestData: Data, peer: PeekabooBridgePeer?) async -> Data {
        do {
            let request = try self.decoder.decode(PeekabooBridgeRequest.self, from: requestData)
            let response = try await self.route(request, peer: peer)
            return try self.encoder.encode(response)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            self.logger.error("bridge request failed: \(envelope.message, privacy: .public)")
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

    private func route(
        _ request: PeekabooBridgeRequest,
        peer: PeekabooBridgePeer?) async throws -> PeekabooBridgeResponse
    {
        try self.validatePeerAuthorization(peer)

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
        let permissions = self.currentPermissions(allowAppleScriptLaunch: op.requiredPermissions.contains(.appleScript))
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
                    let response = try await self.handleAuthorizedWithDesktopMutationBarrier(request, peer: peer)
                    await daemonControl.recordActivityEnd(operation: op)
                    return response
                } catch {
                    await daemonControl.recordActivityEnd(operation: op)
                    throw error
                }
            }

            return try await self.handleAuthorizedWithDesktopMutationBarrier(request, peer: peer)
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
        peer: PeekabooBridgePeer?) async throws -> PeekabooBridgeResponse
    {
        guard request.mayMutateDesktop, let desktopMutationWatermarkStore else {
            return try await self.handleAuthorized(request, peer: peer)
        }

        await self.desktopMutationGate.acquire()
        let mutation: DesktopMutationWatermarkStore.PendingMutation
        do {
            mutation = try desktopMutationWatermarkStore.beginMutation()
        } catch {
            await self.desktopMutationGate.release()
            throw PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: "Could not establish the desktop mutation barrier; operation was not executed",
                details: error.localizedDescription)
        }

        let response: PeekabooBridgeResponse?
        let operationError: (any Error)?
        do {
            response = try await self.handleAuthorized(request, peer: peer)
            operationError = nil
        } catch {
            response = nil
            operationError = error
        }

        let completedResponse: PeekabooBridgeResponse?
        do {
            completedResponse = try await self.completeDesktopMutation(
                mutation,
                request: request,
                response: response,
                store: desktopMutationWatermarkStore)
        } catch {
            await self.desktopMutationGate.release()
            throw error
        }
        await self.desktopMutationGate.release()

        if let operationError {
            throw operationError
        }
        guard let completedResponse = completedResponse ?? response else {
            throw PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: "Desktop operation returned neither a response nor an error")
        }
        return completedResponse
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

        if case let .targetedClick(payload) = request {
            try Self.validateTargetedClickAccess(payload, permissions: permissions)
        }
        switch request {
        case let .scroll(payload):
            guard payload.request.foreground else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .invalidRequest,
                    message: "The scroll operation requires foreground=true; use targetedScroll for background AX input")
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

        guard effectiveOps.contains(op) else {
            let missingPermission = op.requiredPermissions
                .subtracting(Self.grantedPermissions(from: permissions))
                .min { $0.rawValue < $1.rawValue }
            throw PeekabooBridgeErrorEnvelope(
                code: .permissionDenied,
                message: "Operation \(op.rawValue) is not allowed with current permissions",
                permission: missingPermission)
        }
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
