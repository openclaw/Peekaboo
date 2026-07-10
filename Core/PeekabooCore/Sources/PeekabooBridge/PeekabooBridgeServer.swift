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
    let daemonControl: (any PeekabooDaemonControlProviding)?
    let postEventAccessEvaluator: @MainActor @Sendable () -> Bool
    let postEventAccessRequester: @MainActor @Sendable () -> Bool
    let permissionStatusEvaluator: @MainActor @Sendable (_ allowAppleScriptLaunch: Bool) -> PermissionsStatus
    let desktopMutationWatermarkStore: DesktopMutationWatermarkStore?
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
        postEventAccessEvaluator: @escaping @MainActor @Sendable () -> Bool = { CGPreflightPostEventAccess() },
        postEventAccessRequester: @escaping @MainActor @Sendable () -> Bool = { CGRequestPostEventAccess() },
        permissionStatusEvaluator: (@MainActor @Sendable (_ allowAppleScriptLaunch: Bool) -> PermissionsStatus)? = nil,
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
        self.postEventAccessEvaluator = postEventAccessEvaluator
        self.postEventAccessRequester = postEventAccessRequester
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

            if let error = error as? PeekabooError {
                switch error {
                case let .invalidInput(message):
                    throw PeekabooBridgeErrorEnvelope(
                        code: .invalidRequest,
                        message: message,
                        details: "\(error)")
                case .permissionDeniedAccessibility, .permissionDeniedScreenRecording,
                     .permissionDeniedEventSynthesizing:
                    throw PeekabooBridgeErrorEnvelope(
                        code: .permissionDenied,
                        message: error.localizedDescription,
                        details: "\(error)",
                        permission: Self.bridgePermission(for: error))
                case let .serviceUnavailable(message):
                    throw PeekabooBridgeErrorEnvelope(
                        code: .operationNotSupported,
                        message: message,
                        details: "\(error)")
                case let .notImplemented(message):
                    throw PeekabooBridgeErrorEnvelope(
                        code: .operationNotSupported,
                        message: "Operation \(op.rawValue) is not supported: \(message)",
                        details: "\(error)")
                case .appNotFound, .notFound:
                    throw PeekabooBridgeErrorEnvelope(
                        code: .notFound,
                        message: error.localizedDescription,
                        details: "\(error)")
                case let .elementNotFound(identifier):
                    throw PeekabooBridgeErrorEnvelope(
                        code: .notFound,
                        message: error.localizedDescription,
                        details: "\(error)",
                        kind: .elementNotFound,
                        context: identifier)
                case let .snapshotNotFound(snapshotId):
                    throw PeekabooBridgeErrorEnvelope(
                        code: .notFound,
                        message: error.localizedDescription,
                        details: "\(error)",
                        kind: .snapshotNotFound,
                        context: snapshotId)
                case let .snapshotStale(reason):
                    throw PeekabooBridgeErrorEnvelope(
                        code: .invalidRequest,
                        message: error.localizedDescription,
                        details: "\(error)",
                        kind: .snapshotStale,
                        context: reason)
                case .timeout, .captureTimeout:
                    throw PeekabooBridgeErrorEnvelope(
                        code: .timeout,
                        message: error.localizedDescription,
                        details: "\(error)")
                default:
                    break
                }
            }

            throw PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: "Bridge operation failed",
                details: "\(error)")
        }
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
        if request.requiresPostEventPermission {
            guard permissions.postEvent else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .permissionDenied,
                    message: "Coordinate and double background clicks require Event Synthesizing permission",
                    permission: .postEvent)
            }
            return
        }

        guard permissions.accessibility || permissions.postEvent else {
            throw PeekabooBridgeErrorEnvelope(
                code: .permissionDenied,
                message: "Element and query background clicks require Accessibility or Event Synthesizing permission",
                permission: .accessibility)
        }
    }
}
