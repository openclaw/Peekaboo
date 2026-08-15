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
    let operationReceiptExportDirectory: URL?
    let logger = Logger(subsystem: "boo.peekaboo.bridge", category: "client")
    var actionProjectionEnabled = false
    var exactDialogInputExecutionEnabled = false
    var exactDialogForceDismissExecutionEnabled = false
    var dialogInputFocusPolicyEnabled = false
    var operationAttestation: PeekabooBridgeListenerAttestation?
    var latestVerifiedOperationReceipt: PeekabooBridgeOperationReceipt?
    var latestVerifiedOperationReceiptBundle: PeekabooBridgeOperationReceiptBundle?

    public init(
        socketPath: String = PeekabooBridgeConstants.peekabooSocketPath,
        maxResponseBytes: Int = 64 * 1024 * 1024,
        requestTimeoutSec: TimeInterval = 10,
        encoder: JSONEncoder = .peekabooBridgeEncoder(),
        decoder: JSONDecoder = .peekabooBridgeDecoder(),
        operationReceiptExportDirectory: URL? = nil)
    {
        self.socketPath = socketPath
        self.maxResponseBytes = maxResponseBytes
        self.requestTimeoutSec = requestTimeoutSec
        self.encoder = encoder
        self.decoder = decoder
        let environmentDirectory = ProcessInfo.processInfo.environment["PEEKABOO_OPERATION_RECEIPT_DIRECTORY"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        self.operationReceiptExportDirectory = operationReceiptExportDirectory ?? environmentDirectory
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
        self.exactDialogInputExecutionEnabled = false
        self.exactDialogForceDismissExecutionEnabled = false
        self.dialogInputFocusPolicyEnabled = false
        self.operationAttestation = nil
        self.latestVerifiedOperationReceipt = nil
        self.latestVerifiedOperationReceiptBundle = nil
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

    /// Most recent protocol-1.29 receipt accepted by this client after signature and digest validation.
    public func lastOperationReceipt() -> PeekabooBridgeOperationReceipt? {
        self.latestVerifiedOperationReceipt
    }

    /// Most recent full audit bundle. It contains the complete request and response payload bytes.
    public func lastOperationReceiptBundle() -> PeekabooBridgeOperationReceiptBundle? {
        self.latestVerifiedOperationReceiptBundle
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
            if handshake.negotiatedVersion >= PeekabooBridgeConstants.attestedOperationReceiptVersion {
                guard handshake.hostCapabilities?.contains(
                    PeekabooBridgeHostCapability.attestedOperationReceipts) == true,
                    let attestation = handshake.operationAttestation
                else {
                    throw PeekabooBridgeErrorEnvelope(
                        code: .versionMismatch,
                        message: "Protocol 1.29 Bridge host omitted its operation receipt attestation")
                }
                do {
                    try attestation.validateSignature()
                } catch {
                    throw PeekabooBridgeErrorEnvelope(
                        code: .unauthorizedClient,
                        message: "Bridge listener operation attestation is invalid",
                        details: error.localizedDescription)
                }
                guard handshake.hostIdentity?.processIdentifier == attestation.host.processIdentifier,
                      handshake.hostIdentity?.processStartIdentity == attestation.host.processStartIdentity,
                      handshake.hostIdentity?.codeSignatureHash == attestation.host.codeSignatureHash
                else {
                    throw PeekabooBridgeErrorEnvelope(
                        code: .unauthorizedClient,
                        message: "Bridge listener attestation contradicts the advertised host identity")
                }
                self.operationAttestation = attestation
            }
            self.actionProjectionEnabled =
                handshake.negotiatedVersion >= PeekabooBridgeConstants.desktopActionOutcomeProjectionVersion &&
                handshake.hostCapabilities?.contains(
                    PeekabooBridgeHostCapability.desktopActionOutcomeProjection) == true
            let exactInputAdvertised = handshake.supportedOperations.contains(.exactDialogEnterText)
            let exactForceDismissAdvertised = handshake.supportedOperations.contains(.exactDialogForceDismiss)
            self.exactDialogInputExecutionEnabled =
                handshake.negotiatedVersion >= PeekabooBridgeConstants.exactDialogInputExecutionVersion &&
                exactInputAdvertised &&
                (handshake.enabledOperations?.contains(.exactDialogEnterText) ?? exactInputAdvertised) &&
                handshake.hostCapabilities?.contains(
                    PeekabooBridgeHostCapability.exactDialogInputExecution) == true
            self.exactDialogForceDismissExecutionEnabled =
                handshake.negotiatedVersion >= PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion &&
                exactForceDismissAdvertised &&
                (handshake.enabledOperations?.contains(.exactDialogForceDismiss) ?? exactForceDismissAdvertised) &&
                handshake.hostCapabilities?.contains(
                    PeekabooBridgeHostCapability.exactForcedDialogDismissExecution) == true
            let legacyInputAdvertised = handshake.supportedOperations.contains(.dialogEnterText)
            self.dialogInputFocusPolicyEnabled =
                handshake.negotiatedVersion >= PeekabooBridgeConstants.dialogInputFocusPolicyVersion &&
                legacyInputAdvertised &&
                (handshake.enabledOperations?.contains(.dialogEnterText) ?? legacyInputAdvertised) &&
                handshake.hostCapabilities?.contains(
                    PeekabooBridgeHostCapability.dialogInputFocusPolicy) == true
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
