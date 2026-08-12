import Foundation
import os.log
import PeekabooAutomationKit
import PeekabooFoundation

public actor PeekabooBridgeClient {
    let socketPath: String
    let maxResponseBytes: Int
    let requestTimeoutSec: TimeInterval
    let encoder: JSONEncoder
    let decoder: JSONDecoder
    let logger = Logger(subsystem: "boo.peekaboo.bridge", category: "client")
    var actionProjectionEnabled = false

    public init(
        socketPath: String = PeekabooBridgeConstants.peekabooSocketPath,
        maxResponseBytes: Int = 64 * 1024 * 1024,
        requestTimeoutSec: TimeInterval = 10,
        encoder: JSONEncoder = .peekabooBridgeEncoder(),
        decoder: JSONDecoder = .peekabooBridgeDecoder())
    {
        self.socketPath = socketPath
        self.maxResponseBytes = maxResponseBytes
        self.requestTimeoutSec = requestTimeoutSec
        self.encoder = encoder
        self.decoder = decoder
    }

    @discardableResult
    public func handshake(
        client: PeekabooBridgeClientIdentity,
        requestedHost: PeekabooBridgeHostKind? = nil,
        protocolVersion: PeekabooBridgeProtocolVersion = PeekabooBridgeConstants.protocolVersion,
        overallTimeoutSec: TimeInterval? = nil)
        async throws -> PeekabooBridgeHandshakeResponse
    {
        self.actionProjectionEnabled = false
        let deadline: Date?
        if let overallTimeoutSec {
            guard overallTimeoutSec.isFinite, overallTimeoutSec > 0 else {
                throw POSIXError(.EINVAL)
            }
            deadline = Date().addingTimeInterval(overallTimeoutSec)
        } else {
            deadline = nil
        }
        do {
            return try await self.performHandshake(
                client: client,
                requestedHost: requestedHost,
                protocolVersion: protocolVersion,
                timeoutSec: self.remainingHandshakeTimeout(deadline: deadline))
        } catch let envelope as PeekabooBridgeErrorEnvelope
            where envelope.code == .versionMismatch &&
            protocolVersion == PeekabooBridgeConstants.protocolVersion &&
            PeekabooBridgeConstants.minimumProtocolVersion < PeekabooBridgeConstants.protocolVersion
        {
            var version = PeekabooBridgeProtocolVersion(
                major: PeekabooBridgeConstants.protocolVersion.major,
                minor: PeekabooBridgeConstants.protocolVersion.minor - 1)
            while version >= PeekabooBridgeConstants.minimumProtocolVersion {
                do {
                    return try await self.performHandshake(
                        client: client,
                        requestedHost: requestedHost,
                        protocolVersion: version,
                        timeoutSec: self.remainingHandshakeTimeout(deadline: deadline))
                } catch let fallbackEnvelope as PeekabooBridgeErrorEnvelope
                    where fallbackEnvelope.code == .versionMismatch
                {
                    version = PeekabooBridgeProtocolVersion(major: version.major, minor: version.minor - 1)
                    continue
                }
            }
            throw envelope
        }
    }

    private func performHandshake(
        client: PeekabooBridgeClientIdentity,
        requestedHost: PeekabooBridgeHostKind?,
        protocolVersion: PeekabooBridgeProtocolVersion,
        timeoutSec: TimeInterval?) async throws -> PeekabooBridgeHandshakeResponse
    {
        let payload = PeekabooBridgeHandshake(
            protocolVersion: protocolVersion,
            client: client,
            requestedHostKind: requestedHost)
        let response = try await self.send(.handshake(payload), timeoutSec: timeoutSec)

        switch response {
        case let .handshake(handshake):
            self.actionProjectionEnabled =
                handshake.negotiatedVersion >= PeekabooBridgeConstants.desktopActionOutcomeProjectionVersion &&
                handshake.hostCapabilities?.contains(
                    PeekabooBridgeHostCapability.desktopActionOutcomeProjection) == true
            return handshake
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected handshake response")
        }
    }

    private func remainingHandshakeTimeout(deadline: Date?) throws -> TimeInterval? {
        guard let deadline else { return nil }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw POSIXError(.ETIMEDOUT)
        }
        return min(self.requestTimeoutSec, remaining)
    }
}
