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
            return (try? self.encoder.encode(PeekabooBridgeResponse.error(envelope))) ?? Data()
        } catch {
            self.logger.error("bridge request decoding failed: \(error.localizedDescription, privacy: .public)")
            let envelope = PeekabooBridgeErrorEnvelope(
                code: .decodingFailed,
                message: "Failed to decode request",
                details: "\(error)")
            return (try? self.encoder.encode(PeekabooBridgeResponse.error(envelope))) ?? Data()
        }
    }

    private func route(
        _ request: PeekabooBridgeRequest,
        peer: PeekabooBridgePeer?) async throws -> PeekabooBridgeResponse
    {
        if peer == nil, !self.allowlistedTeams.isEmpty || !self.allowlistedBundles.isEmpty {
            throw PeekabooBridgeErrorEnvelope(
                code: .unauthorizedClient,
                message: "Unsigned bridge clients are not allowed for this listener")
        }

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
                    let response = try await self.handleAuthorized(request, peer: peer)
                    await daemonControl.recordActivityEnd(operation: op)
                    return response
                } catch {
                    await daemonControl.recordActivityEnd(operation: op)
                    throw error
                }
            }

            return try await self.handleAuthorized(request, peer: peer)
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
}
