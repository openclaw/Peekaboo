import Darwin
import Foundation
import os.log
import PeekabooAutomationKit
import PeekabooFoundation

struct PeekabooBridgeClientHostAuthentication: @unchecked Sendable {
    typealias LiveIdentityProvider = @Sendable (Int32) throws -> PeekabooBridgeLivePeerIdentity
    typealias SigningIdentityProvider = @Sendable (PeekabooBridgePeerAuditIdentity)
        -> PeekabooBridgeHost.PeerSigningIdentity?

    let liveIdentity: LiveIdentityProvider
    let signingIdentity: SigningIdentityProvider

    init(
        liveIdentity: @escaping LiveIdentityProvider = {
            try PeekabooBridgeSocketIO.livePeerIdentity(fd: $0)
        },
        signingIdentity: @escaping SigningIdentityProvider)
    {
        self.liveIdentity = liveIdentity
        self.signingIdentity = signingIdentity
    }

    static let live = Self(
        signingIdentity: { identity in
            PeekabooBridgeHost.signingIdentity(auditIdentity: identity)
        })
}

struct PeekabooBridgeConnectedHostIdentity: Equatable, Sendable {
    let liveIdentity: PeekabooBridgeLivePeerIdentity
    let signingIdentity: PeekabooBridgeHost.PeerSigningIdentity?
}

// swiftlint:disable:next type_body_length
public actor PeekabooBridgeClient {
    let socketPath: String
    let maxResponseBytes: Int
    let requestTimeoutSec: TimeInterval
    let encoder: JSONEncoder
    let decoder: JSONDecoder
    let operationReceiptExportDirectory: URL?
    let trustedHostTeamIDs: Set<String>?
    let hostAuthentication: PeekabooBridgeClientHostAuthentication
    let logger = Logger(subsystem: "boo.peekaboo.bridge", category: "client")
    let operationClientInstanceID: UUID
    var actionProjectionEnabled = false
    var exactDialogInputExecutionEnabled = false
    var exactDialogForceDismissExecutionEnabled = false
    var dialogInputFocusPolicyEnabled = false
    var applicationMutationInventoryTransportEnabled = false
    var windowMutationInventoryTransportEnabled = false
    var exactWindowHeldPointerLifecycleEnabled = false
    var exactWindowHeldPointerTerminalCleanupEnabled = false
    var statelessClickVariantPayloadsEnabled = false
    var statelessClickVariantsEnabled = false
    var agentExecutionTraceEnabled = false
    var processGenerationObservationEnabled = false
    var certificationProducerAttestationEnabled = false
    var setValueResultTargetBindingEnabled = false
    var processGenerationBoundElementMutationsEnabled = false
    var foregroundModifierClickSnapshotLeaseEnabled = false
    var nativeBrowserConnectionBindingEnabled = false
    var producerBoundSnapshotReferencesEnabled = false
    var targetedClickAccessibilityValueDeliveryEnabled = false
    var requestPinnedExactWindowScrollReceiptEnabled = false
    var compositeTypeDeliveryEnabled = false
    var operationAttestation: PeekabooBridgeListenerAttestation?
    var latestVerifiedOperationReceipt: PeekabooBridgeOperationReceipt?
    var latestVerifiedOperationReceiptBundle: PeekabooBridgeOperationReceiptBundle?
    var latestOperationReceiptExportFailure: PeekabooBridgeOperationReceiptExportFailure?

    private var operationSession: PeekabooBridgeClientOperationSession?
    private var operationSessionInvalidated = false
    private var handshakeEpoch: UInt64 = 0
    private var operationSessionEpoch: UInt64 = 0
    private var activeHandshakeToken: UInt64?
    private var hasSuccessfulHandshake = false
    private var lastSuccessfulHandshakeInputs: PeekabooBridgeClientHandshakeInputs?
    private var operationSessionRenewal: PeekabooBridgeClientOperationSessionRenewal?
    private var receiptlessAuthenticatedHost: PeekabooBridgeConnectedHostIdentity?
    private var receiptlessAuthenticationEpoch: UInt64 = 0

    /// Creates a Bridge client.
    ///
    /// Bundled Peekaboo socket paths use the release signing teams automatically. Custom socket
    /// paths must provide `trustedHostTeamIDs` to negotiate protocol 1.29; without explicit host
    /// trust they remain source-compatible by negotiating receiptless protocol 1.28.
    public init(
        socketPath: String = PeekabooBridgeConstants.peekabooSocketPath,
        maxResponseBytes: Int = 64 * 1024 * 1024,
        requestTimeoutSec: TimeInterval = 10,
        encoder: JSONEncoder = .peekabooBridgeEncoder(),
        decoder: JSONDecoder = .peekabooBridgeDecoder(),
        operationReceiptExportDirectory: URL? = nil,
        operationClientInstanceID: UUID = UUID(),
        trustedHostTeamIDs: Set<String>? = nil)
    {
        self.socketPath = socketPath
        self.maxResponseBytes = maxResponseBytes
        self.requestTimeoutSec = requestTimeoutSec
        self.encoder = encoder
        self.decoder = decoder
        self.operationClientInstanceID = operationClientInstanceID
        self.trustedHostTeamIDs = Self.resolveTrustedHostTeamIDs(
            explicit: trustedHostTeamIDs,
            socketPath: socketPath)
        self.hostAuthentication = .live
        let environmentDirectory = ProcessInfo.processInfo.environment["PEEKABOO_OPERATION_RECEIPT_DIRECTORY"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        self.operationReceiptExportDirectory = operationReceiptExportDirectory ?? environmentDirectory
    }

    #if DEBUG
    package static func authenticatedTestClient(
        socketPath: String,
        maxResponseBytes: Int = 64 * 1024 * 1024,
        requestTimeoutSec: TimeInterval = 10,
        operationReceiptExportDirectory: URL? = nil,
        operationClientInstanceID: UUID = UUID(),
        trustedHostTeamIDs: Set<String>,
        signingTeamIdentifier: String) -> PeekabooBridgeClient
    {
        PeekabooBridgeClient(
            socketPath: socketPath,
            maxResponseBytes: maxResponseBytes,
            requestTimeoutSec: requestTimeoutSec,
            operationReceiptExportDirectory: operationReceiptExportDirectory,
            operationClientInstanceID: operationClientInstanceID,
            trustedHostTeamIDs: trustedHostTeamIDs,
            hostAuthentication: .init(signingIdentity: { auditIdentity in
                guard let hash = PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(
                    auditIdentity: auditIdentity)
                else { return nil }
                return PeekabooBridgeHost.PeerSigningIdentity(
                    bundleIdentifier: "dev.peekaboo.test-host",
                    teamIdentifier: signingTeamIdentifier,
                    codeSignatureHash: hash)
            }))
    }
    #endif

    init(
        socketPath: String,
        maxResponseBytes: Int = 64 * 1024 * 1024,
        requestTimeoutSec: TimeInterval = 10,
        encoder: JSONEncoder = .peekabooBridgeEncoder(),
        decoder: JSONDecoder = .peekabooBridgeDecoder(),
        operationReceiptExportDirectory: URL? = nil,
        operationClientInstanceID: UUID = UUID(),
        trustedHostTeamIDs: Set<String>?,
        hostAuthentication: PeekabooBridgeClientHostAuthentication)
    {
        self.socketPath = socketPath
        self.maxResponseBytes = maxResponseBytes
        self.requestTimeoutSec = requestTimeoutSec
        self.encoder = encoder
        self.decoder = decoder
        self.operationClientInstanceID = operationClientInstanceID
        self.trustedHostTeamIDs = Self.resolveTrustedHostTeamIDs(
            explicit: trustedHostTeamIDs,
            socketPath: socketPath)
        self.hostAuthentication = hostAuthentication
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
        let effectiveProtocolVersion = self.effectiveHandshakeProtocolVersion(protocolVersion)
        let inputs = PeekabooBridgeClientHandshakeInputs(
            client: client,
            requestedHost: requestedHost,
            protocolVersion: effectiveProtocolVersion,
            allowsProtocolFallback: protocolVersion == PeekabooBridgeConstants.protocolVersion)
        let replacingSessionID = self.operationSession?.attestation.sessionID
        let deadline = try self.handshakeDeadline(overallTimeoutSec: overallTimeoutSec)
        let token = self.beginHandshake(supersedingRenewal: true)
        do {
            let candidate: PeekabooBridgeClientHandshakeCandidate
            let candidateReplacingSessionID: UUID?
            do {
                candidate = try await self.negotiateHandshake(
                    inputs: inputs,
                    replacingOperationSessionID: replacingSessionID,
                    overallTimeoutSec: self.remainingOverallHandshakeTimeout(deadline: deadline),
                    token: token)
                candidateReplacingSessionID = replacingSessionID
            } catch {
                guard replacingSessionID != nil,
                      Self.canRetryFreshHandshake(after: error)
                else { throw error }
                try self.checkHandshakeToken(token)
                candidate = try await self.negotiateHandshake(
                    inputs: inputs,
                    replacingOperationSessionID: nil,
                    overallTimeoutSec: self.remainingOverallHandshakeTimeout(deadline: deadline),
                    token: token)
                candidateReplacingSessionID = nil
            }
            try self.installHandshakeCandidate(
                candidate,
                inputs: inputs,
                token: token,
                replacingSessionID: candidateReplacingSessionID,
                allowLegacyReplacement: true)
            return candidate.response
        } catch {
            self.finishHandshakeAttempt(token: token)
            throw error
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

    /// Most recent requested receipt export that failed after the response bundle was verified successfully.
    public func lastOperationReceiptExportFailure() -> PeekabooBridgeOperationReceiptExportFailure? {
        self.latestOperationReceiptExportFailure
    }

    func usesExplicitReceiptlessTransport() -> Bool {
        self.hasSuccessfulHandshake && self.operationAttestation == nil
    }

    func receiptlessAuthenticatedHostReservation() -> PeekabooBridgeReceiptlessHostReservation? {
        guard self.hasSuccessfulHandshake,
              self.operationAttestation == nil,
              let host = self.receiptlessAuthenticatedHost
        else { return nil }
        return .init(epoch: self.receiptlessAuthenticationEpoch, host: host)
    }

    /// Reserves one unique slot in the currently negotiated receipt session before transport suspends.
    ///
    /// The local remaining count is deliberately conservative. A failed request can consume a server claim,
    /// so only a verified signed receipt or a new session can establish a newer budget.
    func reserveOperationSession() throws -> PeekabooBridgeClientOperationSessionReservation? {
        let publicHandshakeInProgress = self.activeHandshakeToken != nil && self.operationSessionRenewal == nil
        let attestedSessionIsUnusable = self.operationAttestation != nil &&
            (self.operationSessionInvalidated || self.operationSessionRequiresRenewal())
        if publicHandshakeInProgress,
           !self.hasSuccessfulHandshake || attestedSessionIsUnusable
        {
            throw PeekabooBridgeClientOperationSessionError.negotiationInProgress
        }
        guard self.operationAttestation != nil else {
            guard self.hasSuccessfulHandshake else {
                throw PeekabooBridgeClientOperationSessionError.handshakeRequired
            }
            return nil
        }
        guard var session = self.operationSession else {
            throw PeekabooBridgeClientOperationSessionError.unavailable
        }
        if self.operationSessionInvalidated {
            throw PeekabooBridgeClientOperationSessionError.renewalRequired(
                sessionID: session.attestation.sessionID,
                epoch: session.epoch)
        }
        let maximumRequestCount = session.attestation.maximumRequestCount
        let shouldRenewProactively = maximumRequestCount > 1 && session.remainingClaimCount <= 1
        guard !shouldRenewProactively,
              session.remainingClaimCount > 0,
              session.nextSequence.value < UInt64(maximumRequestCount)
        else {
            throw PeekabooBridgeClientOperationSessionError.renewalRequired(
                sessionID: session.attestation.sessionID,
                epoch: session.epoch)
        }

        let sequence = session.nextSequence
        let nextValue = sequence.value.addingReportingOverflow(1)
        guard !nextValue.overflow else {
            throw PeekabooBridgeClientOperationSessionError.renewalRequired(
                sessionID: session.attestation.sessionID,
                epoch: session.epoch)
        }
        session.nextSequence = PeekabooBridgeOperationSessionSequence(nextValue.partialValue)
        session.remainingClaimCount -= 1
        self.operationSession = session
        return PeekabooBridgeClientOperationSessionReservation(
            epoch: session.epoch,
            listenerAttestation: session.listenerAttestation,
            listenerLiveIdentity: session.listenerLiveIdentity,
            sessionAttestation: session.attestation,
            sequence: sequence,
            requestID: PeekabooBridgeOperationReceiptCoding.deterministicRequestID(
                sessionID: session.attestation.sessionID,
                sequence: sequence),
            clientIdentity: session.attestation.client)
    }

    func operationSessionRequiresRenewal() -> Bool {
        guard self.operationAttestation != nil else { return false }
        guard !self.operationSessionInvalidated else { return true }
        guard let session = self.operationSession else { return true }
        return session.remainingClaimCount <= (session.attestation.maximumRequestCount > 1 ? 1 : 0) ||
            session.nextSequence.value >= UInt64(session.attestation.maximumRequestCount)
    }

    /// Installs a successor carried by a fully verified rollover refusal.
    @discardableResult
    func installOperationSession(
        _ successor: PeekabooBridgeOperationSessionAttestation,
        listenerAttestation: PeekabooBridgeListenerAttestation,
        replacingSessionID: UUID,
        expectedEpoch: UInt64) throws -> UInt64
    {
        if let current = self.operationSession,
           current.attestation.sessionID == successor.sessionID
        {
            self.cancelOperationSessionRenewal(replacingSessionID: replacingSessionID)
            return current.epoch
        }
        guard let current = self.operationSession,
              current.epoch == expectedEpoch,
              current.attestation.sessionID == replacingSessionID,
              current.listenerAttestation == listenerAttestation,
              self.operationAttestation == listenerAttestation
        else {
            throw PeekabooBridgeClientOperationSessionError.superseded
        }
        try self.validateOperationSession(
            successor,
            listenerAttestation: listenerAttestation,
            replacingSessionID: replacingSessionID)
        self.cancelOperationSessionRenewal(replacingSessionID: replacingSessionID)
        return self.installOperationSessionState(
            successor,
            listenerAttestation: listenerAttestation,
            listenerLiveIdentity: current.listenerLiveIdentity)
    }

    private func cancelOperationSessionRenewal(replacingSessionID: UUID) {
        guard let renewal = self.operationSessionRenewal,
              renewal.replacingSessionID == replacingSessionID
        else { return }
        renewal.task.cancel()
        self.finishOperationSessionRenewalAttempt(renewal)
    }

    /// Applies signed budget progress only to the exact session that issued the request.
    func recordOperationSessionReceipt(
        sessionID: UUID,
        epoch: UInt64,
        remainingClaimCount: Int)
    {
        guard var current = self.operationSession,
              !self.operationSessionInvalidated,
              current.epoch == epoch,
              current.attestation.sessionID == sessionID,
              remainingClaimCount >= 0,
              remainingClaimCount <= current.attestation.maximumRequestCount
        else { return }
        current.remainingClaimCount = min(current.remainingClaimCount, remainingClaimCount)
        self.operationSession = current
    }

    /// Publishes a verified bundle only while its session is still current.
    /// Old in-flight responses remain valid to their caller but cannot repopulate post-rollover shared state.
    func recordOperationReceiptBundle(
        _ bundle: PeekabooBridgeOperationReceiptBundle,
        reservation: PeekabooBridgeClientOperationSessionReservation)
    {
        guard self.operationSession?.epoch == reservation.epoch,
              !self.operationSessionInvalidated,
              self.operationSession?.attestation.sessionID == reservation.sessionAttestation.sessionID,
              self.operationAttestation == reservation.listenerAttestation
        else { return }
        self.recordOperationSessionReceipt(
            sessionID: reservation.sessionAttestation.sessionID,
            epoch: reservation.epoch,
            remainingClaimCount: bundle.receipt.payload.remainingClaimCount)
        self.latestVerifiedOperationReceipt = bundle.receipt
        self.latestVerifiedOperationReceiptBundle = bundle
    }

    /// Prevents future calls from using a session after any request that did not yield a valid receipt.
    /// Already in-flight requests keep their captured reservation and may still validate independently.
    func invalidateOperationSession(sessionID: UUID, epoch: UInt64) {
        guard self.operationSession?.epoch == epoch,
              self.operationSession?.attestation.sessionID == sessionID
        else { return }
        self.operationSessionInvalidated = true
        self.latestVerifiedOperationReceipt = nil
        self.latestVerifiedOperationReceiptBundle = nil
    }

    /// Requires an explicit cold recovery handshake without authorizing a retry of the request that exposed the
    /// replacement. The disabled session identity remains available so that handshake can first offer to retire it.
    func requireColdHandshakeRetainingOperationSession(sessionID: UUID, epoch: UInt64) {
        guard self.operationSession?.epoch == epoch,
              self.operationSession?.attestation.sessionID == sessionID
        else { return }
        self.operationAttestation = nil
        self.operationSessionInvalidated = true
        self.hasSuccessfulHandshake = false
        self.clearNegotiatedInputCapabilities()
        self.latestVerifiedOperationReceipt = nil
        self.latestVerifiedOperationReceiptBundle = nil
    }

    /// Applies transport evidence only to the exact session that reserved the failed request.
    ///
    /// A kernel-proven peer replacement can never produce a receipt from the cached listener. Keep its predecessor
    /// identity for recovery, but do not let later callers enter a doomed automatic renewal loop against that listener.
    func recordOperationSessionTransportFailure(
        _ error: any Error,
        sessionID: UUID,
        epoch: UInt64)
    {
        if Self.operationSessionFailureRequiresColdHandshake(error) {
            self.requireColdHandshakeRetainingOperationSession(sessionID: sessionID, epoch: epoch)
        } else {
            self.invalidateOperationSession(sessionID: sessionID, epoch: epoch)
        }
    }

    func invalidateReceiptlessAuthenticatedHost(
        reservation: PeekabooBridgeReceiptlessHostReservation?)
    {
        guard let reservation,
              self.operationAttestation == nil,
              self.receiptlessAuthenticationEpoch == reservation.epoch,
              self.receiptlessAuthenticatedHost == reservation.host
        else { return }
        self.receiptlessAuthenticatedHost = nil
        self.hasSuccessfulHandshake = false
        self.clearNegotiatedInputCapabilities()
        self.latestVerifiedOperationReceipt = nil
        self.latestVerifiedOperationReceiptBundle = nil
    }

    func clearNegotiatedInputCapabilities() {
        self.exactWindowHeldPointerLifecycleEnabled = false
        self.exactWindowHeldPointerTerminalCleanupEnabled = false
        self.statelessClickVariantPayloadsEnabled = false
        self.statelessClickVariantsEnabled = false
        self.agentExecutionTraceEnabled = false
        self.processGenerationObservationEnabled = false
        self.certificationProducerAttestationEnabled = false
        self.setValueResultTargetBindingEnabled = false
        self.processGenerationBoundElementMutationsEnabled = false
        self.foregroundModifierClickSnapshotLeaseEnabled = false
        self.nativeBrowserConnectionBindingEnabled = false
        self.producerBoundSnapshotReferencesEnabled = false
        self.targetedClickAccessibilityValueDeliveryEnabled = false
        self.requestPinnedExactWindowScrollReceiptEnabled = false
        self.compositeTypeDeliveryEnabled = false
    }

    /// Creates or joins one successor-session handshake using the most recent successful public inputs.
    @discardableResult
    func renewOperationSession(
        replacingSessionID: UUID,
        overallTimeoutSec: TimeInterval? = nil) async throws -> PeekabooBridgeOperationSessionAttestation
    {
        if let successor = self.installedOperationSessionSuccessor(replacingSessionID: replacingSessionID) {
            return successor
        }
        if let renewal = self.operationSessionRenewal {
            guard renewal.replacingSessionID == replacingSessionID else {
                throw PeekabooBridgeClientOperationSessionError.superseded
            }
            do {
                let candidate = try await Self.awaitOperationSessionRenewal(
                    renewal.task,
                    timeoutSec: overallTimeoutSec ?? self.requestTimeoutSec)
                return try self.finishOperationSessionRenewal(candidate, renewal: renewal)
            } catch {
                if let successor = self.installedOperationSessionSuccessor(
                    replacingSessionID: replacingSessionID)
                {
                    return successor
                }
                let normalizedError = Self.normalizedOperationSessionRenewalError(error)
                self.recordDefinitiveOperationSessionRenewalFailure(normalizedError, renewal: renewal)
                throw normalizedError
            }
        }
        guard let inputs = self.lastSuccessfulHandshakeInputs,
              let current = self.operationSession,
              current.attestation.sessionID == replacingSessionID
        else {
            throw PeekabooBridgeClientOperationSessionError.unavailable
        }

        let token = self.beginHandshake(supersedingRenewal: false)
        let renewalTransportTimeoutSec = self.requestTimeoutSec
        let task = Task { [inputs] in
            try await self.negotiateHandshake(
                inputs: inputs,
                replacingOperationSessionID: replacingSessionID,
                overallTimeoutSec: renewalTransportTimeoutSec,
                token: token)
        }
        let renewal = PeekabooBridgeClientOperationSessionRenewal(
            replacingSessionID: replacingSessionID,
            predecessorEpoch: current.epoch,
            token: token,
            task: task)
        self.operationSessionRenewal = renewal
        Task {
            do {
                let candidate = try await task.value
                self.operationSessionRenewalTaskDidSucceed(candidate, renewal: renewal)
            } catch {
                self.operationSessionRenewalTaskDidFail(error, renewal: renewal)
            }
        }
        do {
            let candidate = try await Self.awaitOperationSessionRenewal(
                task,
                timeoutSec: overallTimeoutSec ?? self.requestTimeoutSec)
            return try self.finishOperationSessionRenewal(candidate, renewal: renewal)
        } catch {
            if let successor = self.installedOperationSessionSuccessor(
                replacingSessionID: replacingSessionID)
            {
                return successor
            }
            let normalizedError = Self.normalizedOperationSessionRenewalError(error)
            self.recordDefinitiveOperationSessionRenewalFailure(normalizedError, renewal: renewal)
            throw normalizedError
        }
    }

    private func installedOperationSessionSuccessor(
        replacingSessionID: UUID) -> PeekabooBridgeOperationSessionAttestation?
    {
        guard !self.operationSessionInvalidated,
              let current = self.operationSession,
              current.attestation.predecessorSessionID == replacingSessionID,
              self.operationAttestation == current.listenerAttestation
        else { return nil }
        return current.attestation
    }

    private func operationSessionRenewalTaskDidSucceed(
        _ candidate: PeekabooBridgeClientHandshakeCandidate,
        renewal: PeekabooBridgeClientOperationSessionRenewal)
    {
        guard self.operationSessionRenewal?.token == renewal.token else { return }
        do {
            _ = try self.finishOperationSessionRenewal(candidate, renewal: renewal)
        } catch {
            self.finishOperationSessionRenewalAttempt(renewal)
        }
    }

    private func operationSessionRenewalTaskDidFail(
        _ error: any Error,
        renewal: PeekabooBridgeClientOperationSessionRenewal)
    {
        guard self.operationSessionRenewal?.token == renewal.token else { return }
        self.recordDefinitiveOperationSessionRenewalFailure(error, renewal: renewal)
        self.finishOperationSessionRenewalAttempt(renewal)
    }

    private func recordDefinitiveOperationSessionRenewalFailure(
        _ error: any Error,
        renewal: PeekabooBridgeClientOperationSessionRenewal)
    {
        guard Self.operationSessionFailureRequiresColdHandshake(error) else { return }
        self.requireColdHandshakeRetainingOperationSession(
            sessionID: renewal.replacingSessionID,
            epoch: renewal.predecessorEpoch)
    }

    private func finishOperationSessionRenewal(
        _ candidate: PeekabooBridgeClientHandshakeCandidate,
        renewal: PeekabooBridgeClientOperationSessionRenewal) throws
        -> PeekabooBridgeOperationSessionAttestation
    {
        if let current = self.installedOperationSessionSuccessor(
            replacingSessionID: renewal.replacingSessionID)
        {
            self.finishOperationSessionRenewalAttempt(renewal)
            return current
        }
        try self.checkHandshakeToken(renewal.token)
        guard self.operationSession?.epoch == renewal.predecessorEpoch,
              self.operationSession?.attestation.sessionID == renewal.replacingSessionID
        else {
            self.finishOperationSessionRenewalAttempt(renewal)
            throw PeekabooBridgeClientOperationSessionError.superseded
        }
        if candidate.response.negotiatedVersion < PeekabooBridgeConstants.attestedOperationReceiptVersion {
            // Automatic renewal must never turn the waiting operation into a receiptless request. Preserve the
            // predecessor only so a later explicit handshake can authorize the legacy downgrade deliberately.
            self.requireColdHandshakeRetainingOperationSession(
                sessionID: renewal.replacingSessionID,
                epoch: renewal.predecessorEpoch)
            self.finishOperationSessionRenewalAttempt(renewal)
            throw PeekabooBridgeClientOperationSessionError.handshakeRequired
        }
        try self.installHandshakeCandidate(
            candidate,
            inputs: self.lastSuccessfulHandshakeInputs,
            token: renewal.token,
            replacingSessionID: renewal.replacingSessionID)
        self.finishOperationSessionRenewalAttempt(renewal)
        guard let session = self.operationSession?.attestation else {
            throw PeekabooBridgeClientOperationSessionError.unavailable
        }
        return session
    }

    private func finishOperationSessionRenewalAttempt(
        _ renewal: PeekabooBridgeClientOperationSessionRenewal)
    {
        if self.operationSessionRenewal?.token == renewal.token {
            self.operationSessionRenewal = nil
        }
        self.finishHandshakeAttempt(token: renewal.token)
    }

    /// Bounds each caller's wait without cancelling the shared renewal needed by concurrent callers.
    private nonisolated static func awaitOperationSessionRenewal(
        _ task: Task<PeekabooBridgeClientHandshakeCandidate, any Error>,
        timeoutSec: TimeInterval) async throws -> PeekabooBridgeClientHandshakeCandidate
    {
        guard timeoutSec.isFinite, timeoutSec > 0 else { throw POSIXError(.ETIMEDOUT) }
        let waiter = PeekabooBridgeClientOperationSessionRenewalWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                Task {
                    do {
                        try await waiter.finish(.success(task.value))
                    } catch {
                        waiter.finish(.failure(error))
                    }
                }
                Task {
                    do {
                        try await Task.sleep(for: .seconds(timeoutSec))
                        waiter.finish(.failure(POSIXError(.ETIMEDOUT)))
                    } catch {
                        // The timeout worker is best-effort; cancellation is delivered by the handler below.
                    }
                }
            }
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
        }
    }

    private func negotiateHandshake(
        inputs: PeekabooBridgeClientHandshakeInputs,
        replacingOperationSessionID: UUID?,
        overallTimeoutSec: TimeInterval?,
        token: UInt64) async throws -> PeekabooBridgeClientHandshakeCandidate
    {
        let deadline = try self.handshakeDeadline(overallTimeoutSec: overallTimeoutSec)
        do {
            try self.checkHandshakeToken(token)
            return try await self.performHandshake(
                inputs: inputs,
                protocolVersion: inputs.protocolVersion,
                replacingOperationSessionID: replacingOperationSessionID,
                timeoutSec: self.remainingHandshakeTimeout(deadline: deadline))
        } catch let envelope as PeekabooBridgeErrorEnvelope
            where envelope.code == .versionMismatch &&
            inputs.allowsProtocolFallback &&
            PeekabooBridgeConstants.minimumProtocolVersion < inputs.protocolVersion
        {
            var version = PeekabooBridgeProtocolVersion(
                major: inputs.protocolVersion.major,
                minor: inputs.protocolVersion.minor - 1)
            while version >= PeekabooBridgeConstants.minimumProtocolVersion {
                do {
                    try self.checkHandshakeToken(token)
                    return try await self.performHandshake(
                        inputs: inputs,
                        protocolVersion: version,
                        replacingOperationSessionID: replacingOperationSessionID,
                        timeoutSec: self.remainingHandshakeTimeout(deadline: deadline))
                } catch let fallbackEnvelope as PeekabooBridgeErrorEnvelope
                    where fallbackEnvelope.code == .versionMismatch
                {
                    version = PeekabooBridgeProtocolVersion(major: version.major, minor: version.minor - 1)
                }
            }
            throw envelope
        }
    }

    private func performHandshake(
        inputs: PeekabooBridgeClientHandshakeInputs,
        protocolVersion: PeekabooBridgeProtocolVersion,
        replacingOperationSessionID: UUID?,
        timeoutSec: TimeInterval?) async throws -> PeekabooBridgeClientHandshakeCandidate
    {
        let payload = PeekabooBridgeHandshake(
            protocolVersion: protocolVersion,
            client: inputs.client,
            requestedHostKind: inputs.requestedHost,
            operationClientInstanceID: self.operationClientInstanceID,
            replacingOperationSessionID: replacingOperationSessionID,
            clientCapabilities: protocolVersion >= PeekabooBridgeConstants.producerBoundSnapshotReferencesVersion
                ? [
                    PeekabooBridgeClientCapability.producerBoundSnapshotReferences,
                    PeekabooBridgeClientCapability.targetedClickAccessibilityValueDelivery,
                ]
                : nil)
        let reply = try await self.sendCarryingActionOutcome(.handshake(payload), timeoutSec: timeoutSec)
        try self.validateTrustedConnectedHost(reply.connectedHost)
        let response = reply.response

        switch response {
        case let .handshake(handshake):
            return try self.handshakeCandidate(
                handshake,
                replacingOperationSessionID: replacingOperationSessionID,
                connectedHost: reply.connectedHost)
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected handshake response")
        }
    }

    /// Validates the kernel-connected host before interpreting any trusted-socket handshake response, including
    /// errors that could otherwise trigger protocol fallback. Custom sockets without an explicit trust policy retain
    /// their intentionally unauthenticated protocol-1.28 compatibility behavior.
    private func validateTrustedConnectedHost(_ connectedHost: PeekabooBridgeConnectedHostIdentity?) throws {
        guard let trustedHostTeamIDs = self.trustedHostTeamIDs else { return }
        guard let connectedHost,
              let liveCodeSignatureHash = connectedHost.liveIdentity.codeSignatureHash,
              !liveCodeSignatureHash.isEmpty,
              let signingIdentity = connectedHost.signingIdentity,
              signingIdentity.codeSignatureHash == liveCodeSignatureHash,
              let signingTeamIdentifier = signingIdentity.teamIdentifier,
              trustedHostTeamIDs.contains(signingTeamIdentifier)
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .unauthorizedClient,
                message: "Bridge handshake did not come from a trusted connected host")
        }
    }

    private func handshakeCandidate(
        _ handshake: PeekabooBridgeHandshakeResponse,
        replacingOperationSessionID: UUID?,
        connectedHost: PeekabooBridgeConnectedHostIdentity?) throws -> PeekabooBridgeClientHandshakeCandidate
    {
        let listenerAttestation: PeekabooBridgeListenerAttestation?
        let listenerLiveIdentity: PeekabooBridgeLivePeerIdentity?
        let sessionAttestation: PeekabooBridgeOperationSessionAttestation?
        let receiptlessAuthenticatedHost: PeekabooBridgeConnectedHostIdentity?
        if handshake.negotiatedVersion >= PeekabooBridgeConstants.attestedOperationReceiptVersion {
            guard handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.attestedOperationReceipts) == true,
                handshake.hostCapabilities?.contains(
                    PeekabooBridgeHostCapability.desktopActionOutcomeProjection) == true,
                let advertisedListenerAttestation = handshake.operationAttestation,
                let advertisedSessionAttestation = handshake.operationSessionAttestation
            else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .unauthorizedClient,
                    message: "Protocol 1.29 Bridge host omitted required operation receipt capabilities")
            }
            guard let connectedHost,
                  let liveCodeSignatureHash = connectedHost.liveIdentity.codeSignatureHash,
                  !liveCodeSignatureHash.isEmpty,
                  let signingIdentity = connectedHost.signingIdentity,
                  signingIdentity.codeSignatureHash == liveCodeSignatureHash,
                  let signingTeamIdentifier = signingIdentity.teamIdentifier,
                  self.trustedHostTeamIDs?.contains(signingTeamIdentifier) == true,
                  connectedHost.liveIdentity.processIdentifier == advertisedListenerAttestation.host.processIdentifier,
                  connectedHost.liveIdentity.processStartIdentity ==
                  advertisedListenerAttestation.host.processStartIdentity,
                  liveCodeSignatureHash == advertisedListenerAttestation.host.codeSignatureHash
            else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .unauthorizedClient,
                    message: "Bridge listener does not match the trusted connected host")
            }
            do {
                try advertisedListenerAttestation.validateSignature()
                try self.validateOperationSession(
                    advertisedSessionAttestation,
                    listenerAttestation: advertisedListenerAttestation,
                    replacingSessionID: replacingOperationSessionID)
            } catch {
                throw PeekabooBridgeErrorEnvelope(
                    code: .unauthorizedClient,
                    message: "Bridge operation session attestation is invalid",
                    details: error.localizedDescription)
            }
            guard handshake.hostIdentity?.processIdentifier == advertisedListenerAttestation.host.processIdentifier,
                  handshake.hostIdentity?.processStartIdentity ==
                  advertisedListenerAttestation.host.processStartIdentity,
                  handshake.hostIdentity?.codeSignatureHash == advertisedListenerAttestation.host.codeSignatureHash
            else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .unauthorizedClient,
                    message: "Bridge listener attestation contradicts the advertised host identity")
            }
            listenerAttestation = advertisedListenerAttestation
            listenerLiveIdentity = connectedHost.liveIdentity
            sessionAttestation = advertisedSessionAttestation
            receiptlessAuthenticatedHost = nil
        } else {
            listenerAttestation = nil
            listenerLiveIdentity = nil
            sessionAttestation = nil
            receiptlessAuthenticatedHost = self.trustedHostTeamIDs == nil ? nil : connectedHost
        }

        let exactInputAdvertised = handshake.supportedOperations.contains(.exactDialogEnterText)
        let exactForceDismissAdvertised = handshake.supportedOperations.contains(.exactDialogForceDismiss)
        let legacyInputAdvertised = handshake.supportedOperations.contains(.dialogEnterText)
        return PeekabooBridgeClientHandshakeCandidate(
            response: handshake,
            actionProjectionEnabled:
            handshake.negotiatedVersion >= PeekabooBridgeConstants.desktopActionOutcomeProjectionVersion &&
                handshake.hostCapabilities?.contains(
                    PeekabooBridgeHostCapability.desktopActionOutcomeProjection) == true,
            exactDialogInputExecutionEnabled:
            handshake.negotiatedVersion >= PeekabooBridgeConstants.exactDialogInputExecutionVersion &&
                exactInputAdvertised &&
                (handshake.enabledOperations?.contains(.exactDialogEnterText) ?? exactInputAdvertised) &&
                handshake.hostCapabilities?.contains(
                    PeekabooBridgeHostCapability.exactDialogInputExecution) == true,
            exactDialogForceDismissExecutionEnabled:
            handshake.negotiatedVersion >= PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion &&
                exactForceDismissAdvertised &&
                (handshake.enabledOperations?.contains(.exactDialogForceDismiss) ?? exactForceDismissAdvertised) &&
                handshake.hostCapabilities?.contains(
                    PeekabooBridgeHostCapability.exactForcedDialogDismissExecution) == true,
            dialogInputFocusPolicyEnabled:
            handshake.negotiatedVersion >= PeekabooBridgeConstants.dialogInputFocusPolicyVersion &&
                legacyInputAdvertised &&
                (handshake.enabledOperations?.contains(.dialogEnterText) ?? legacyInputAdvertised) &&
                handshake.hostCapabilities?.contains(
                    PeekabooBridgeHostCapability.dialogInputFocusPolicy) == true,
            applicationMutationInventoryTransportEnabled:
            handshake.negotiatedVersion >= PeekabooBridgeConstants.plannerInventoryTransportVersion &&
                handshake.hostCapabilities?.contains(
                    PeekabooBridgeHostCapability.plannerInventoryTransport) == true &&
                handshake.supportedOperations.contains(.listApplications) &&
                (handshake.enabledOperations?.contains(.listApplications) ?? true),
            windowMutationInventoryTransportEnabled:
            handshake.negotiatedVersion >= PeekabooBridgeConstants.plannerInventoryTransportVersion &&
                handshake.hostCapabilities?.contains(
                    PeekabooBridgeHostCapability.plannerInventoryTransport) == true &&
                handshake.supportedOperations.contains(.listWindows) &&
                (handshake.enabledOperations?.contains(.listWindows) ?? true),
            exactWindowHeldPointerLifecycleEnabled:
            handshake.negotiatedVersion >= PeekabooBridgeConstants.exactWindowHeldPointerLifecycleVersion &&
                handshake.hostCapabilities?.contains(
                    PeekabooBridgeHostCapability.exactWindowHeldPointerLifecycle) == true &&
                Set([
                    PeekabooBridgeOperation.createExactWindowHeldPointerOwner,
                    .beginExactWindowHeldPointer,
                    .releaseExactWindowHeldPointer,
                    .revokeExactWindowHeldPointer,
                    .disconnectExactWindowHeldPointerOwner,
                ]).isSubset(of: Set(handshake.supportedOperations)) &&
                Set([
                    PeekabooBridgeOperation.createExactWindowHeldPointerOwner,
                    .beginExactWindowHeldPointer,
                ]).isSubset(of: Set(handshake.enabledOperations ?? handshake.supportedOperations)),
            exactWindowHeldPointerTerminalCleanupEnabled:
            handshake.negotiatedVersion >= PeekabooBridgeConstants.exactWindowHeldPointerLifecycleVersion &&
                handshake.hostCapabilities?.contains(
                    PeekabooBridgeHostCapability.exactWindowHeldPointerLifecycle) == true &&
                Set([
                    PeekabooBridgeOperation.createExactWindowHeldPointerOwner,
                    .beginExactWindowHeldPointer,
                    .releaseExactWindowHeldPointer,
                    .revokeExactWindowHeldPointer,
                    .disconnectExactWindowHeldPointerOwner,
                ]).isSubset(of: Set(handshake.supportedOperations)) &&
                Set([
                    PeekabooBridgeOperation.releaseExactWindowHeldPointer,
                    .revokeExactWindowHeldPointer,
                    .disconnectExactWindowHeldPointerOwner,
                ]).isSubset(of: Set(handshake.enabledOperations ?? handshake.supportedOperations)),
            statelessClickVariantPayloadsEnabled:
            handshake.negotiatedVersion >= PeekabooBridgeConstants.statelessClickVariantVersion,
            statelessClickVariantsEnabled: Self.supportsStatelessClickVariants(handshake),
            agentExecutionTraceEnabled: Self.supportsAgentExecutionTrace(handshake),
            processGenerationObservationEnabled: Self.supportsProcessGenerationObservation(handshake),
            certificationProducerAttestationEnabled: Self.supportsCertificationProducerAttestation(handshake),
            setValueResultTargetBindingEnabled: Self.supportsSetValueResultTargetBinding(handshake),
            processGenerationBoundElementMutationsEnabled:
            Self.supportsProcessGenerationBoundElementMutations(handshake),
            foregroundModifierClickSnapshotLeaseEnabled:
            Self.supportsForegroundModifierClickSnapshotLease(handshake),
            nativeBrowserConnectionBindingEnabled:
            Self.supportsNativeBrowserConnectionBinding(handshake),
            producerBoundSnapshotReferencesEnabled:
            Self.supportsProducerBoundSnapshotReferences(handshake),
            targetedClickAccessibilityValueDeliveryEnabled:
            Self.supportsTargetedClickAccessibilityValueDelivery(handshake),
            requestPinnedExactWindowScrollReceiptEnabled:
            Self.supportsRequestPinnedExactWindowScrollReceipt(handshake),
            compositeTypeDeliveryEnabled: Self.supportsCompositeTypeDelivery(handshake),
            listenerAttestation: listenerAttestation,
            listenerLiveIdentity: listenerLiveIdentity,
            sessionAttestation: sessionAttestation,
            receiptlessAuthenticatedHost: receiptlessAuthenticatedHost)
    }

    private static func supportsStatelessClickVariants(_ handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        let requiredOperations: Set<PeekabooBridgeOperation> = [.targetedClick, .exactWindowTargetedClick]
        return handshake.negotiatedVersion >= PeekabooBridgeConstants.statelessClickVariantVersion &&
            handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.statelessClickVariants) == true &&
            requiredOperations.isSubset(of: Set(handshake.supportedOperations)) &&
            requiredOperations.isSubset(of: Set(handshake.enabledOperations ?? handshake.supportedOperations))
    }

    private static func supportsProducerBoundSnapshotReferences(
        _ handshake: PeekabooBridgeHandshakeResponse) -> Bool
    {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.producerBoundSnapshotReferencesVersion &&
            handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.attestedOperationReceipts) == true &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.producerBoundSnapshotReferences) == true &&
            handshake.supportedOperations.contains(.ownsSnapshot) &&
            (handshake.enabledOperations?.contains(.ownsSnapshot) ?? true)
    }

    private static func supportsTargetedClickAccessibilityValueDelivery(
        _ handshake: PeekabooBridgeHandshakeResponse) -> Bool
    {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.targetedClickAccessibilityValueDeliveryVersion &&
            handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.attestedOperationReceipts) == true &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.targetedClickAccessibilityValueDelivery) == true &&
            handshake.supportedOperations.contains(.targetedClick) &&
            (handshake.enabledOperations?.contains(.targetedClick) ?? true)
    }

    private static func supportsCompositeTypeDelivery(_ handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        let operations: Set<PeekabooBridgeOperation> = [
            .targetedTypeActions,
            .exactWindowTargetedTypeActions,
            .exactWindowPixelFocusType,
        ]
        let supported = Set(handshake.supportedOperations)
        let enabled = Set(handshake.enabledOperations ?? handshake.supportedOperations)
        return handshake.negotiatedVersion >= PeekabooBridgeConstants.compositeTypeDeliveryVersion &&
            handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.attestedOperationReceipts) == true &&
            handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.compositeTypeDelivery) == true &&
            !supported.isDisjoint(with: operations) &&
            !enabled.isDisjoint(with: operations)
    }

    private static func supportsAgentExecutionTrace(_ handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.agentExecutionTraceVersion &&
            handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.agentExecutionTrace) == true &&
            handshake.supportedOperations.contains(.agentExecutionTrace) &&
            (handshake.enabledOperations?.contains(.agentExecutionTrace) ?? true)
    }

    private static func supportsProcessGenerationObservation(_ handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.processGenerationObservationVersion &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.processGenerationObservation) == true &&
            handshake.supportedOperations.contains(.observeProcessGeneration) &&
            (handshake.enabledOperations?.contains(.observeProcessGeneration) ?? true)
    }

    private static func supportsCertificationProducerAttestation(
        _ handshake: PeekabooBridgeHandshakeResponse) -> Bool
    {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.certificationProducerAttestationVersion &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.certificationProducerAttestation) == true &&
            handshake.supportedOperations.contains(.certificationProducerAttestation) &&
            (handshake.enabledOperations?.contains(.certificationProducerAttestation) ?? true)
    }

    private static func supportsSetValueResultTargetBinding(_ handshake: PeekabooBridgeHandshakeResponse) -> Bool {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.setValueResultTargetBindingVersion &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.setValueResultTargetBinding) == true &&
            handshake.supportedOperations.contains(.setValue)
    }

    private static func supportsProcessGenerationBoundElementMutations(
        _ handshake: PeekabooBridgeHandshakeResponse) -> Bool
    {
        handshake.negotiatedVersion >=
            PeekabooBridgeConstants.processGenerationBoundElementMutationsVersion &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.processGenerationBoundElementMutations) == true
    }

    private static func supportsForegroundModifierClickSnapshotLease(
        _ handshake: PeekabooBridgeHandshakeResponse) -> Bool
    {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.composedInputParityVersion &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.foregroundModifierClickSnapshotLease) == true &&
            handshake.supportedOperations.contains(.foregroundModifierClick) &&
            (handshake.enabledOperations?.contains(.foregroundModifierClick) ?? true)
    }

    private static func supportsNativeBrowserConnectionBinding(
        _ handshake: PeekabooBridgeHandshakeResponse) -> Bool
    {
        let operations: Set<PeekabooBridgeOperation> = [
            .browserStatus,
            .browserConnect,
            .browserDisconnect,
            .browserExecute,
        ]
        return handshake.negotiatedVersion >= PeekabooBridgeConstants.nativeBrowserConnectionBindingVersion &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.nativeBrowserConnectionBinding) == true &&
            operations.isSubset(of: Set(handshake.supportedOperations))
    }

    private static func supportsRequestPinnedExactWindowScrollReceipt(
        _ handshake: PeekabooBridgeHandshakeResponse) -> Bool
    {
        handshake.negotiatedVersion >= PeekabooBridgeConstants.requestPinnedExactWindowScrollReceiptVersion &&
            handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.attestedOperationReceipts) == true &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.requestPinnedExactWindowScrollReceipt) == true &&
            handshake.supportedOperations.contains(.targetedScroll) &&
            (handshake.enabledOperations?.contains(.targetedScroll) ?? true)
    }

    private func installHandshakeCandidate(
        _ candidate: PeekabooBridgeClientHandshakeCandidate,
        inputs: PeekabooBridgeClientHandshakeInputs?,
        token: UInt64,
        replacingSessionID: UUID? = nil,
        allowLegacyReplacement: Bool = false) throws
    {
        try self.checkHandshakeToken(token)
        var preservesInstalledSuccessor = false
        if let replacingSessionID {
            if self.isExactInstalledSuccessor(candidate, replacingSessionID: replacingSessionID) {
                preservesInstalledSuccessor = true
            } else {
                guard self.operationSession?.attestation.sessionID == replacingSessionID else {
                    throw PeekabooBridgeClientOperationSessionError.superseded
                }
            }
            if !preservesInstalledSuccessor,
               candidate.response.negotiatedVersion >= PeekabooBridgeConstants.attestedOperationReceiptVersion
            {
                let predecessorListener = self.operationAttestation ?? self.operationSession?.listenerAttestation
                guard candidate.listenerAttestation == predecessorListener,
                      candidate.listenerLiveIdentity == self.operationSession?.listenerLiveIdentity,
                      candidate.sessionAttestation?.predecessorSessionID == replacingSessionID
                else {
                    throw PeekabooBridgeClientOperationSessionError.superseded
                }
            } else if !preservesInstalledSuccessor, !allowLegacyReplacement {
                throw PeekabooBridgeClientOperationSessionError.superseded
            }
        }
        self.actionProjectionEnabled = candidate.actionProjectionEnabled
        self.exactDialogInputExecutionEnabled = candidate.exactDialogInputExecutionEnabled
        self.exactDialogForceDismissExecutionEnabled = candidate.exactDialogForceDismissExecutionEnabled
        self.dialogInputFocusPolicyEnabled = candidate.dialogInputFocusPolicyEnabled
        self.applicationMutationInventoryTransportEnabled =
            candidate.applicationMutationInventoryTransportEnabled
        self.windowMutationInventoryTransportEnabled = candidate.windowMutationInventoryTransportEnabled
        self.exactWindowHeldPointerLifecycleEnabled = candidate.exactWindowHeldPointerLifecycleEnabled
        self.exactWindowHeldPointerTerminalCleanupEnabled = candidate.exactWindowHeldPointerTerminalCleanupEnabled
        self.statelessClickVariantPayloadsEnabled = candidate.statelessClickVariantPayloadsEnabled
        self.statelessClickVariantsEnabled = candidate.statelessClickVariantsEnabled
        self.agentExecutionTraceEnabled = candidate.agentExecutionTraceEnabled
        self.processGenerationObservationEnabled = candidate.processGenerationObservationEnabled
        self.certificationProducerAttestationEnabled = candidate.certificationProducerAttestationEnabled
        self.setValueResultTargetBindingEnabled = candidate.setValueResultTargetBindingEnabled
        self.processGenerationBoundElementMutationsEnabled =
            candidate.processGenerationBoundElementMutationsEnabled
        self.foregroundModifierClickSnapshotLeaseEnabled =
            candidate.foregroundModifierClickSnapshotLeaseEnabled
        self.nativeBrowserConnectionBindingEnabled = candidate.nativeBrowserConnectionBindingEnabled
        self.producerBoundSnapshotReferencesEnabled = candidate.producerBoundSnapshotReferencesEnabled
        self.targetedClickAccessibilityValueDeliveryEnabled =
            candidate.targetedClickAccessibilityValueDeliveryEnabled
        self.requestPinnedExactWindowScrollReceiptEnabled =
            candidate.requestPinnedExactWindowScrollReceiptEnabled
        self.compositeTypeDeliveryEnabled = candidate.compositeTypeDeliveryEnabled
        self.operationAttestation = candidate.listenerAttestation
        self.installReceiptlessAuthenticatedHost(candidate.receiptlessAuthenticatedHost)
        if let listenerAttestation = candidate.listenerAttestation,
           let listenerLiveIdentity = candidate.listenerLiveIdentity,
           let sessionAttestation = candidate.sessionAttestation
        {
            if !preservesInstalledSuccessor {
                self.installOperationSessionState(
                    sessionAttestation,
                    listenerAttestation: listenerAttestation,
                    listenerLiveIdentity: listenerLiveIdentity)
            }
        } else {
            // A legacy negotiation cannot retire the server-side 1.29 session because the old host ignores
            // additive replacement fields. Retain its identity only for a later authenticated 1.29 handshake;
            // `operationAttestation == nil` keeps all legacy requests outside receipt carriage meanwhile.
            if replacingSessionID == nil || !allowLegacyReplacement {
                self.operationSession = nil
            }
            self.operationSessionInvalidated = false
        }
        self.hasSuccessfulHandshake = true
        self.finishHandshakeAttempt(token: token)
        if !preservesInstalledSuccessor {
            self.latestVerifiedOperationReceipt = nil
            self.latestVerifiedOperationReceiptBundle = nil
        }
        if let inputs {
            self.lastSuccessfulHandshakeInputs = inputs
        }
    }

    private func installReceiptlessAuthenticatedHost(_ host: PeekabooBridgeConnectedHostIdentity?) {
        self.receiptlessAuthenticationEpoch &+= 1
        if self.receiptlessAuthenticationEpoch == 0 {
            self.receiptlessAuthenticationEpoch = 1
        }
        self.receiptlessAuthenticatedHost = host
    }

    /// A signed rollover can win the response race with an explicit replacement handshake. If both carry the exact
    /// same successor, the handshake succeeded logically, but reinstalling it would reset its deterministic sequence
    /// and local claim budget. Preserve the already-live state instead.
    private func isExactInstalledSuccessor(
        _ candidate: PeekabooBridgeClientHandshakeCandidate,
        replacingSessionID: UUID) -> Bool
    {
        guard !self.operationSessionInvalidated,
              candidate.response.negotiatedVersion >= PeekabooBridgeConstants.attestedOperationReceiptVersion,
              let candidateListener = candidate.listenerAttestation,
              let candidateLiveIdentity = candidate.listenerLiveIdentity,
              let candidateSession = candidate.sessionAttestation,
              candidateSession.predecessorSessionID == replacingSessionID,
              let current = self.operationSession,
              current.listenerAttestation == candidateListener,
              current.listenerLiveIdentity == candidateLiveIdentity,
              current.attestation == candidateSession,
              self.operationAttestation == candidateListener
        else { return false }
        return true
    }

    @discardableResult
    private func installOperationSessionState(
        _ attestation: PeekabooBridgeOperationSessionAttestation,
        listenerAttestation: PeekabooBridgeListenerAttestation,
        listenerLiveIdentity: PeekabooBridgeLivePeerIdentity) -> UInt64
    {
        self.operationSessionEpoch &+= 1
        if self.operationSessionEpoch == 0 {
            self.operationSessionEpoch = 1
        }
        let epoch = self.operationSessionEpoch
        self.operationSession = PeekabooBridgeClientOperationSession(
            epoch: epoch,
            listenerAttestation: listenerAttestation,
            listenerLiveIdentity: listenerLiveIdentity,
            attestation: attestation,
            nextSequence: .init(0),
            remainingClaimCount: attestation.remainingClaimCount)
        self.operationSessionInvalidated = false
        self.latestVerifiedOperationReceipt = nil
        self.latestVerifiedOperationReceiptBundle = nil
        return epoch
    }

    private func validateOperationSession(
        _ session: PeekabooBridgeOperationSessionAttestation,
        listenerAttestation: PeekabooBridgeListenerAttestation,
        replacingSessionID: UUID?) throws
    {
        try session.validateSignature(listenerAttestation: listenerAttestation)
        guard session.clientInstanceID == self.operationClientInstanceID,
              try session.client == (self.operationClientProcessIdentity()),
              session.predecessorSessionID == replacingSessionID
        else {
            throw PeekabooBridgeOperationReceiptError.operationSessionMismatch
        }
    }

    func operationClientProcessIdentity() throws -> PeekabooBridgeOperationProcessIdentity {
        let processIdentifier = getpid()
        guard let processStartIdentity = SystemIdentityResolver.processStartIdentity(processIdentifier) else {
            throw PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: "Could not establish the Bridge client's process-generation receipt")
        }
        guard let codeSignatureHash = PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(
            processIdentifier: processIdentifier)
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: "Could not establish the Bridge client's code-signature receipt")
        }
        return PeekabooBridgeOperationProcessIdentity(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            codeSignatureHash: codeSignatureHash)
    }

    private func beginHandshake(supersedingRenewal: Bool) -> UInt64 {
        if supersedingRenewal {
            self.operationSessionRenewal?.task.cancel()
            self.operationSessionRenewal = nil
        }
        self.handshakeEpoch &+= 1
        if self.handshakeEpoch == 0 {
            self.handshakeEpoch = 1
        }
        self.activeHandshakeToken = self.handshakeEpoch
        return self.handshakeEpoch
    }

    private func finishHandshakeAttempt(token: UInt64) {
        if self.activeHandshakeToken == token {
            self.activeHandshakeToken = nil
        }
    }

    private func checkHandshakeToken(_ token: UInt64) throws {
        guard token == self.handshakeEpoch else {
            throw PeekabooBridgeClientOperationSessionError.superseded
        }
    }

    private func handshakeDeadline(overallTimeoutSec: TimeInterval?) throws -> Date? {
        guard let overallTimeoutSec else { return nil }
        guard overallTimeoutSec.isFinite, overallTimeoutSec > 0 else {
            throw POSIXError(.EINVAL)
        }
        return Date().addingTimeInterval(overallTimeoutSec)
    }

    private func remainingOverallHandshakeTimeout(deadline: Date?) throws -> TimeInterval? {
        guard let deadline else { return nil }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw POSIXError(.ETIMEDOUT) }
        return remaining
    }

    private nonisolated static func canRetryFreshHandshake(after error: any Error) -> Bool {
        guard let envelope = error as? PeekabooBridgeErrorEnvelope else { return false }
        return switch envelope.code {
        case .invalidRequest, .unauthorizedClient, .decodingFailed:
            true
        default:
            false
        }
    }

    private nonisolated static func operationSessionFailureRequiresColdHandshake(_ error: any Error) -> Bool {
        if let receiptError = error as? PeekabooBridgeOperationReceiptError,
           receiptError == .peerIdentityMismatch
        {
            return true
        }
        return self.canRetryFreshHandshake(after: error)
    }

    /// A newer public handshake cancels the shared renewal task without cancelling its waiters. Preserve actual caller
    /// cancellation, but report shared-task cancellation as session supersession so mutations remain retry-safe.
    private nonisolated static func normalizedOperationSessionRenewalError(_ error: any Error) -> any Error {
        guard error is CancellationError, !Task.isCancelled else { return error }
        return PeekabooBridgeClientOperationSessionError.superseded
    }

    private func remainingHandshakeTimeout(deadline: Date?) throws -> TimeInterval? {
        guard let deadline else { return nil }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw POSIXError(.ETIMEDOUT)
        }
        return min(self.requestTimeoutSec, remaining)
    }

    private nonisolated static func resolveTrustedHostTeamIDs(
        explicit: Set<String>?,
        socketPath: String) -> Set<String>?
    {
        if let explicit, !explicit.isEmpty {
            return explicit
        }
        return PeekabooBridgeConstants.defaultTrustedHostTeamIDs(socketPath: socketPath)
    }

    private func effectiveHandshakeProtocolVersion(
        _ requested: PeekabooBridgeProtocolVersion) -> PeekabooBridgeProtocolVersion
    {
        guard requested >= PeekabooBridgeConstants.attestedOperationReceiptVersion,
              self.trustedHostTeamIDs == nil
        else { return requested }
        return PeekabooBridgeProtocolVersion(
            major: PeekabooBridgeConstants.attestedOperationReceiptVersion.major,
            minor: PeekabooBridgeConstants.attestedOperationReceiptVersion.minor - 1)
    }
}

public struct PeekabooBridgeOperationReceiptExportFailure: Equatable, Sendable {
    public let requestID: UUID
    public let directoryPath: String
    public let message: String
}

struct PeekabooBridgeClientOperationSessionReservation: Sendable {
    let epoch: UInt64
    let listenerAttestation: PeekabooBridgeListenerAttestation
    let listenerLiveIdentity: PeekabooBridgeLivePeerIdentity
    let sessionAttestation: PeekabooBridgeOperationSessionAttestation
    let sequence: PeekabooBridgeOperationSessionSequence
    let requestID: UUID
    let clientIdentity: PeekabooBridgeOperationProcessIdentity
}

enum PeekabooBridgeClientOperationSessionError: Error, LocalizedError, Equatable {
    case handshakeRequired
    case unavailable
    case negotiationInProgress
    case renewalRequired(sessionID: UUID, epoch: UInt64)
    case superseded

    var errorDescription: String? {
        switch self {
        case .handshakeRequired:
            "Bridge requests require a successful protocol handshake"
        case .unavailable:
            "Bridge operation session is unavailable; complete a new handshake"
        case .negotiationInProgress:
            "Bridge handshake is still negotiating an operation session"
        case .renewalRequired:
            "Bridge operation session must roll over before another request"
        case .superseded:
            "Bridge operation session negotiation was superseded by a newer handshake"
        }
    }
}

private struct PeekabooBridgeClientOperationSession: Sendable {
    let epoch: UInt64
    let listenerAttestation: PeekabooBridgeListenerAttestation
    let listenerLiveIdentity: PeekabooBridgeLivePeerIdentity
    let attestation: PeekabooBridgeOperationSessionAttestation
    var nextSequence: PeekabooBridgeOperationSessionSequence
    var remainingClaimCount: Int
}

private struct PeekabooBridgeClientHandshakeInputs: Sendable {
    let client: PeekabooBridgeClientIdentity
    let requestedHost: PeekabooBridgeHostKind?
    let protocolVersion: PeekabooBridgeProtocolVersion
    let allowsProtocolFallback: Bool
}

private struct PeekabooBridgeClientHandshakeCandidate: Sendable {
    let response: PeekabooBridgeHandshakeResponse
    let actionProjectionEnabled: Bool
    let exactDialogInputExecutionEnabled: Bool
    let exactDialogForceDismissExecutionEnabled: Bool
    let dialogInputFocusPolicyEnabled: Bool
    let applicationMutationInventoryTransportEnabled: Bool
    let windowMutationInventoryTransportEnabled: Bool
    let exactWindowHeldPointerLifecycleEnabled: Bool
    let exactWindowHeldPointerTerminalCleanupEnabled: Bool
    let statelessClickVariantPayloadsEnabled: Bool
    let statelessClickVariantsEnabled: Bool
    let agentExecutionTraceEnabled: Bool
    let processGenerationObservationEnabled: Bool
    let certificationProducerAttestationEnabled: Bool
    let setValueResultTargetBindingEnabled: Bool
    let processGenerationBoundElementMutationsEnabled: Bool
    let foregroundModifierClickSnapshotLeaseEnabled: Bool
    let nativeBrowserConnectionBindingEnabled: Bool
    let producerBoundSnapshotReferencesEnabled: Bool
    let targetedClickAccessibilityValueDeliveryEnabled: Bool
    let requestPinnedExactWindowScrollReceiptEnabled: Bool
    let compositeTypeDeliveryEnabled: Bool
    let listenerAttestation: PeekabooBridgeListenerAttestation?
    let listenerLiveIdentity: PeekabooBridgeLivePeerIdentity?
    let sessionAttestation: PeekabooBridgeOperationSessionAttestation?
    let receiptlessAuthenticatedHost: PeekabooBridgeConnectedHostIdentity?
}

struct PeekabooBridgeReceiptlessHostReservation: Sendable {
    let epoch: UInt64
    let host: PeekabooBridgeConnectedHostIdentity
}

private struct PeekabooBridgeClientOperationSessionRenewal: Sendable {
    let replacingSessionID: UUID
    let predecessorEpoch: UInt64
    let token: UInt64
    let task: Task<PeekabooBridgeClientHandshakeCandidate, any Error>
}

private final class PeekabooBridgeClientOperationSessionRenewalWaiter: @unchecked Sendable {
    typealias RenewalResult = Result<PeekabooBridgeClientHandshakeCandidate, any Error>

    private let lock = NSLock()
    private var continuation: CheckedContinuation<PeekabooBridgeClientHandshakeCandidate, any Error>?
    private var result: RenewalResult?

    func install(_ continuation: CheckedContinuation<PeekabooBridgeClientHandshakeCandidate, any Error>) {
        self.lock.lock()
        if let result = self.result {
            self.lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        self.lock.unlock()
    }

    func finish(_ result: RenewalResult) {
        self.lock.lock()
        guard self.result == nil else {
            self.lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        continuation?.resume(with: result)
    }
}
