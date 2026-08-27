import CryptoKit
import Darwin
import Foundation

enum PeekabooBridgeBrowserCapabilityNamespaceError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case invalidPrincipal
    case unauthenticatedNamespaceAdmission
    case unauthenticatedClaimAdmission
    case invalidReceipt
    case invalidSignature
    case listenerMismatch
    case registryGenerationMismatch
    case principalMismatch
    case receiptNotYetValid
    case receiptExpired
    case registryInvalidated
    case registryDraining
    case namespaceNotFound
    case namespaceClosing
    case namespaceClosed
    case namespaceExpired
    case namespaceCapacityExceeded
    case claimCapacityExceeded
    case replayedClaim
    case claimMismatch
    case drainAlreadyAwaited

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Browser capability namespace limits are invalid"
        case .invalidPrincipal:
            "Browser capability namespace principal is incomplete or malformed"
        case .unauthenticatedNamespaceAdmission:
            "Browser capability namespaces require an authenticated local native-capable host"
        case .unauthenticatedClaimAdmission:
            "Browser capability namespace claims require a scoped local execution authorization"
        case .invalidReceipt:
            "Browser capability namespace receipt is incomplete or malformed"
        case .invalidSignature:
            "Browser capability namespace receipt signature is invalid"
        case .listenerMismatch:
            "Browser capability namespace receipt belongs to another Bridge listener"
        case .registryGenerationMismatch:
            "Browser capability namespace receipt belongs to another host registry generation"
        case .principalMismatch:
            "Browser capability namespace receipt belongs to another signed principal"
        case .receiptNotYetValid:
            "Browser capability namespace receipt was issued in the future"
        case .receiptExpired:
            "Browser capability namespace receipt expired"
        case .registryInvalidated:
            "Browser capability namespace registry was invalidated by a host restart"
        case .registryDraining:
            "Browser capability namespace registry is draining and no longer accepts work"
        case .namespaceNotFound:
            "Browser capability namespace is not live in this host"
        case .namespaceClosing:
            "Browser capability namespace is closing and no longer accepts work"
        case .namespaceClosed:
            "Browser capability namespace is closed"
        case .namespaceExpired:
            "Browser capability namespace expired"
        case .namespaceCapacityExceeded:
            "Browser capability namespace registry is at capacity"
        case .claimCapacityExceeded:
            "Browser capability namespace exhausted its bounded replay fence"
        case .replayedClaim:
            "Browser capability namespace claim was already used"
        case .claimMismatch:
            "Browser capability namespace claim does not match a live operation"
        case .drainAlreadyAwaited:
            "Browser capability namespace drain already has a waiting owner"
        }
    }
}

/// Host-side proof that namespace creation already passed transport, principal, and provider admission.
///
/// This type is deliberately internal and has no permissive default. The Bridge server constructs it only after
/// proving that execution is local, the socket peer is authenticated, and a concrete native-capable service exists.
struct PeekabooBridgeBrowserCapabilityNamespaceAdmission: Equatable, Sendable {
    let allowsNativeBrowserWindowBinding: Bool

    init?(
        isLocalExecutionHost: Bool,
        isAuthenticatedPeer: Bool,
        hasNativeCapableService: Bool)
    {
        guard isLocalExecutionHost, isAuthenticatedPeer, hasNativeCapableService else { return nil }
        self.allowsNativeBrowserWindowBinding = true
    }
}

/// Per-operation policy proof. Foreground permission is intentionally absent from namespace state.
struct PeekabooBridgeBrowserCapabilityClaimAdmission: Equatable, Sendable {
    let executionPolicy: PeekabooBridgeBrowserCapabilityExecutionMode

    init?(
        executionPolicy: PeekabooBridgeBrowserCapabilityExecutionMode,
        isLocalExecutionHost: Bool,
        isAuthenticatedPeer: Bool,
        hasScopedForegroundAuthorization: Bool = false)
    {
        guard isLocalExecutionHost, isAuthenticatedPeer else { return nil }
        if executionPolicy == .foregroundAllowed, !hasScopedForegroundAuthorization {
            return nil
        }
        self.executionPolicy = executionPolicy
    }
}

/// Unforgeable outside PeekabooBridge and safe for the scoped runtime to consume without parsing bearer data.
struct PeekabooBridgeBrowserCapabilityNamespaceAuthorization: Equatable, Sendable {
    let namespaceID: UUID
    let registryGenerationID: UUID
    let claimID: UUID
    let principal: PeekabooBridgeBrowserCapabilityPrincipal
    let executionPolicy: PeekabooBridgeBrowserCapabilityExecutionMode
    let allowsNativeBrowserWindowBinding: Bool
}

struct PeekabooBridgeBrowserCapabilityNamespaceIdentity: Equatable, Sendable {
    let namespaceID: UUID
    let registryGenerationID: UUID
    let principal: PeekabooBridgeBrowserCapabilityPrincipal
    let allowsNativeBrowserWindowBinding: Bool
    fileprivate let drainLeaseID: UInt64?
}

struct PeekabooBridgeBrowserCapabilityNamespaceClaim: Equatable, Sendable {
    let authorization: PeekabooBridgeBrowserCapabilityNamespaceAuthorization
    fileprivate let receiptSHA256: String
}

struct PeekabooBridgeBrowserCapabilityNamespaceSigningContext: Sendable {
    typealias SignCanonicalPayload = @Sendable (
        PeekabooBridgeBrowserCapabilityNamespaceReceiptPayload) throws -> Data

    let listenerAttestation: PeekabooBridgeListenerAttestation
    private let signCanonicalPayload: SignCanonicalPayload

    init(
        listenerAttestation: PeekabooBridgeListenerAttestation,
        signCanonicalPayload: @escaping SignCanonicalPayload) throws
    {
        try listenerAttestation.validateSignature()
        self.listenerAttestation = listenerAttestation
        self.signCanonicalPayload = signCanonicalPayload
    }

    func sign(
        _ payload: PeekabooBridgeBrowserCapabilityNamespaceReceiptPayload) throws
        -> PeekabooBridgeBrowserCapabilityNamespaceReceipt
    {
        let receipt = try PeekabooBridgeBrowserCapabilityNamespaceReceipt(
            payload: payload,
            signature: self.signCanonicalPayload(payload))
        try self.validateSignature(receipt)
        return receipt
    }

    func validateSignature(_ receipt: PeekabooBridgeBrowserCapabilityNamespaceReceipt) throws {
        try self.listenerAttestation.validateSignature()
        guard receipt.payload.listenerInstanceID == self.listenerAttestation.listenerInstanceID,
              receipt.payload.listenerPublicKeySHA256 == PeekabooBridgeOperationReceiptCoding.sha256(
                  self.listenerAttestation.publicKey)
        else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.listenerMismatch
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: self.listenerAttestation.publicKey)
        } catch {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.invalidReceipt
        }
        guard try publicKey.isValidSignature(
            receipt.signature,
            for: PeekabooBridgeOperationReceiptCoding.canonicalData(receipt.payload))
        else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.invalidSignature
        }
    }
}

extension PeekabooBridgeOperationReceiptAuthority {
    func browserCapabilityNamespaceSigningContext() throws
        -> PeekabooBridgeBrowserCapabilityNamespaceSigningContext
    {
        try PeekabooBridgeBrowserCapabilityNamespaceSigningContext(
            listenerAttestation: self.attestation,
            signCanonicalPayload: { [self] payload in
                try self.signBrowserCapabilityNamespacePayload(payload)
            })
    }
}

/// Host-lifetime authority for reusable browser capability namespaces.
///
/// The signed receipt is reusable across same-principal CLI processes. Replay protection applies to the enclosing
/// attested Bridge request ID, allowing distinct requests to execute concurrently without turning the namespace into
/// a one-shot token. No BrowserMCPService type crosses this boundary.
actor PeekabooBridgeBrowserCapabilityNamespaceAuthority {
    private typealias DrainContinuation = CheckedContinuation<Void, any Error>

    struct Configuration: Equatable, Sendable {
        static let hardMaximumNamespaceCount = 1024
        static let hardMaximumLifetimeMilliseconds: Int64 = 60 * 60 * 1000
        static let hardMaximumClaimCountPerNamespace = 65536
        static let hardMaximumFutureSkewMilliseconds: Int64 = 60 * 1000

        static let current = Self(
            maximumNamespaceCount: 64,
            maximumLifetimeMilliseconds: 15 * 60 * 1000,
            maximumClaimCountPerNamespace: 16384,
            maximumFutureSkewMilliseconds: 5 * 1000)

        let maximumNamespaceCount: Int
        let maximumLifetimeMilliseconds: Int64
        let maximumClaimCountPerNamespace: Int
        let maximumFutureSkewMilliseconds: Int64

        init(
            maximumNamespaceCount: Int,
            maximumLifetimeMilliseconds: Int64,
            maximumClaimCountPerNamespace: Int,
            maximumFutureSkewMilliseconds: Int64)
        {
            self.maximumNamespaceCount = maximumNamespaceCount
            self.maximumLifetimeMilliseconds = maximumLifetimeMilliseconds
            self.maximumClaimCountPerNamespace = maximumClaimCountPerNamespace
            self.maximumFutureSkewMilliseconds = maximumFutureSkewMilliseconds
        }

        fileprivate var isValid: Bool {
            (2...Self.hardMaximumNamespaceCount).contains(self.maximumNamespaceCount) &&
                (1...Self.hardMaximumLifetimeMilliseconds).contains(self.maximumLifetimeMilliseconds) &&
                (1...Self.hardMaximumClaimCountPerNamespace).contains(self.maximumClaimCountPerNamespace) &&
                (0...Self.hardMaximumFutureSkewMilliseconds).contains(self.maximumFutureSkewMilliseconds)
        }
    }

    enum LifecycleState: String, Equatable, Sendable {
        case open
        case closing
        case closed
        case expired
    }

    typealias UnixMillisecondsClock = @Sendable () -> Int64
    typealias UUIDGenerator = @Sendable () -> UUID

    let registryGenerationID: UUID

    private let signingContext: PeekabooBridgeBrowserCapabilityNamespaceSigningContext
    private let hostEffectiveUserIdentifier: uid_t
    private let configuration: Configuration
    private let clock: UnixMillisecondsClock
    private let uuidGenerator: UUIDGenerator
    private var entries: [UUID: Entry] = [:]
    private var ordinal: UInt64 = 0
    private var invalidatedForRestart = false
    private var drainingAll = false
    private var drainLeaseOrdinal: UInt64 = 0
    private var allDrainWaiter: DrainWaiter?

    init(
        signingContext: PeekabooBridgeBrowserCapabilityNamespaceSigningContext,
        hostEffectiveUserIdentifier: uid_t = geteuid(),
        configuration: Configuration = .current,
        clock: @escaping UnixMillisecondsClock = {
            PeekabooBridgeOperationReceiptCoding.unixMilliseconds()
        },
        uuidGenerator: @escaping UUIDGenerator = { UUID() }) throws
    {
        guard configuration.isValid else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.invalidConfiguration
        }
        let registryGenerationID = uuidGenerator()
        guard Self.isVersion4(registryGenerationID) else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.invalidConfiguration
        }
        self.signingContext = signingContext
        self.hostEffectiveUserIdentifier = hostEffectiveUserIdentifier
        self.configuration = configuration
        self.clock = clock
        self.uuidGenerator = uuidGenerator
        self.registryGenerationID = registryGenerationID
    }

    static func principal(
        for peer: PeekabooBridgePeer,
        hostEffectiveUserIdentifier: uid_t = geteuid()) throws
        -> PeekabooBridgeBrowserCapabilityPrincipal
    {
        guard let liveIdentity = peer.liveIdentity,
              liveIdentity.effectiveUserIdentifier == hostEffectiveUserIdentifier,
              peer.userIdentifier == liveIdentity.effectiveUserIdentifier,
              let teamIdentifier = peer.teamIdentifier,
              let bundleIdentifier = peer.bundleIdentifier,
              let codeSignatureHash = liveIdentity.codeSignatureHash,
              peer.codeSignatureHash == codeSignatureHash
        else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.invalidPrincipal
        }
        let principal = PeekabooBridgeBrowserCapabilityPrincipal(
            effectiveUserIdentifier: liveIdentity.effectiveUserIdentifier,
            teamIdentifier: teamIdentifier,
            bundleIdentifier: bundleIdentifier,
            codeSignatureHash: codeSignatureHash)
        try Self.validatePrincipal(principal, expectedUserIdentifier: hostEffectiveUserIdentifier)
        return principal
    }

    func open(
        principal: PeekabooBridgeBrowserCapabilityPrincipal,
        admission: PeekabooBridgeBrowserCapabilityNamespaceAdmission,
        lifetimeMilliseconds: Int64) throws -> PeekabooBridgeBrowserCapabilityNamespaceReceipt
    {
        guard admission.allowsNativeBrowserWindowBinding else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.unauthenticatedNamespaceAdmission
        }
        try self.requireAcceptingRegistry()
        try Self.validatePrincipal(principal, expectedUserIdentifier: self.hostEffectiveUserIdentifier)
        let now = self.clock()
        self.expireEntries(at: now)
        let receipt = try self.makeReceipt(
            principal: principal,
            lifetimeMilliseconds: lifetimeMilliseconds,
            now: now)
        try self.reserveCapacity(excluding: [])
        self.ordinal &+= 1
        self.entries[receipt.payload.namespaceID] = Entry(
            receipt: receipt,
            state: .open,
            allowsNativeBrowserWindowBinding: admission.allowsNativeBrowserWindowBinding,
            ordinal: self.ordinal)
        return receipt
    }

    /// Atomically creates a successor before revoking the predecessor. In-flight predecessor claims may drain.
    func rollover(
        _ receipt: PeekabooBridgeBrowserCapabilityNamespaceReceipt,
        principal: PeekabooBridgeBrowserCapabilityPrincipal,
        admission: PeekabooBridgeBrowserCapabilityNamespaceAdmission,
        lifetimeMilliseconds: Int64) throws -> PeekabooBridgeBrowserCapabilityNamespaceReceipt
    {
        guard admission.allowsNativeBrowserWindowBinding else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.unauthenticatedNamespaceAdmission
        }
        try self.requireAcceptingRegistry()
        let now = self.clock()
        let namespaceID = try self.validateRegisteredReceipt(
            receipt,
            principal: principal,
            at: now,
            allowsClosedNamespace: true)
        guard let predecessor = self.entries[namespaceID] else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.namespaceNotFound
        }
        guard predecessor.outstandingDrainLeaseID == nil, predecessor.drainWaiters.isEmpty else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.namespaceClosing
        }
        guard predecessor.state == .open ||
            ((predecessor.state == .closing || predecessor.state == .closed) &&
                predecessor.claimedIDs.count >= self.configuration.maximumClaimCountPerNamespace)
        else {
            throw self.lifecycleError(predecessor.state)
        }

        let successor = try self.makeReceipt(
            principal: principal,
            lifetimeMilliseconds: lifetimeMilliseconds,
            now: now)
        try self.reserveCapacity(excluding: [namespaceID])
        self.ordinal &+= 1
        self.entries[successor.payload.namespaceID] = Entry(
            receipt: successor,
            state: .open,
            allowsNativeBrowserWindowBinding: admission.allowsNativeBrowserWindowBinding,
            ordinal: self.ordinal)
        predecessor.state = predecessor.activeClaimIDs.isEmpty ? .closed : .closing
        self.resumeNamespaceDrainWaiterIfDrained(predecessor)
        return successor
    }

    func claim(
        _ receipt: PeekabooBridgeBrowserCapabilityNamespaceReceipt,
        principal: PeekabooBridgeBrowserCapabilityPrincipal,
        claimID: UUID,
        admission: PeekabooBridgeBrowserCapabilityClaimAdmission) throws
        -> PeekabooBridgeBrowserCapabilityNamespaceClaim
    {
        try self.requireAcceptingRegistry()
        guard Self.isNonzero(claimID) else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.invalidReceipt
        }
        let now = self.clock()
        let namespaceID = try self.validateRegisteredReceipt(receipt, principal: principal, at: now)
        guard let entry = self.entries[namespaceID] else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.namespaceNotFound
        }
        if entry.claimedIDs.contains(claimID) {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.replayedClaim
        }
        guard entry.state == .open else {
            throw self.lifecycleError(entry.state)
        }
        guard entry.claimedIDs.count < self.configuration.maximumClaimCountPerNamespace else {
            entry.state = entry.activeClaimIDs.isEmpty ? .closed : .closing
            throw PeekabooBridgeBrowserCapabilityNamespaceError.claimCapacityExceeded
        }
        guard entry.allowsNativeBrowserWindowBinding else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.unauthenticatedClaimAdmission
        }

        entry.claimedIDs.insert(claimID)
        entry.activeClaimIDs.insert(claimID)
        if entry.claimedIDs.count == self.configuration.maximumClaimCountPerNamespace {
            entry.state = .closing
        }
        return try PeekabooBridgeBrowserCapabilityNamespaceClaim(
            authorization: .init(
                namespaceID: namespaceID,
                registryGenerationID: self.registryGenerationID,
                claimID: claimID,
                principal: principal,
                executionPolicy: admission.executionPolicy,
                allowsNativeBrowserWindowBinding: true),
            receiptSHA256: PeekabooBridgeOperationReceiptCoding.sha256(receipt))
    }

    func complete(_ claim: PeekabooBridgeBrowserCapabilityNamespaceClaim) throws {
        guard claim.authorization.registryGenerationID == self.registryGenerationID,
              let entry = self.entries[claim.authorization.namespaceID],
              entry.receipt.payload.principal == claim.authorization.principal,
              entry.allowsNativeBrowserWindowBinding == claim.authorization.allowsNativeBrowserWindowBinding,
              try PeekabooBridgeOperationReceiptCoding.sha256(entry.receipt) == claim.receiptSHA256,
              entry.activeClaimIDs.remove(claim.authorization.claimID) != nil
        else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.claimMismatch
        }
        self.finishTerminalStateIfDrained(entry)
        self.resumeAllDrainWaiterIfDrained()
        if self.invalidatedForRestart {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.registryInvalidated
        }
    }

    /// Revokes new claims before the caller closes the scoped runtime namespace.
    func beginClose(
        _ receipt: PeekabooBridgeBrowserCapabilityNamespaceReceipt,
        principal: PeekabooBridgeBrowserCapabilityPrincipal) throws
        -> PeekabooBridgeBrowserCapabilityNamespaceIdentity
    {
        try self.requireLiveRegistry()
        let now = self.clock()
        self.expireEntries(at: now)
        try Self.validatePrincipal(principal, expectedUserIdentifier: self.hostEffectiveUserIdentifier)
        try self.validateReceipt(receipt, principal: principal, at: now, allowsExpired: true)
        let namespaceID = receipt.payload.namespaceID
        guard let entry = self.entries[namespaceID] else {
            // Open entries are never evicted. A valid same-generation receipt missing from the bounded registry can
            // therefore only name an already-terminal namespace whose close acknowledgement was lost.
            return PeekabooBridgeBrowserCapabilityNamespaceIdentity(
                namespaceID: namespaceID,
                registryGenerationID: self.registryGenerationID,
                principal: principal,
                allowsNativeBrowserWindowBinding: true,
                drainLeaseID: nil)
        }
        guard entry.receipt == receipt else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.invalidReceipt
        }
        if entry.state == .closed || entry.state == .expired, entry.activeClaimIDs.isEmpty {
            entry.state = .closed
            return PeekabooBridgeBrowserCapabilityNamespaceIdentity(
                namespaceID: namespaceID,
                registryGenerationID: self.registryGenerationID,
                principal: principal,
                allowsNativeBrowserWindowBinding: entry.allowsNativeBrowserWindowBinding,
                drainLeaseID: entry.outstandingDrainLeaseID)
        }
        guard entry.state == .open || entry.state == .closing || entry.state == .expired else {
            throw self.lifecycleError(entry.state)
        }
        let drainLeaseID: UInt64?
        if entry.activeClaimIDs.isEmpty {
            entry.state = .closed
            drainLeaseID = nil
        } else {
            entry.state = .closing
            if let existing = entry.outstandingDrainLeaseID {
                drainLeaseID = existing
            } else {
                let issued = self.nextDrainLeaseID()
                entry.outstandingDrainLeaseID = issued
                drainLeaseID = issued
            }
        }
        return PeekabooBridgeBrowserCapabilityNamespaceIdentity(
            namespaceID: namespaceID,
            registryGenerationID: self.registryGenerationID,
            principal: principal,
            allowsNativeBrowserWindowBinding: entry.allowsNativeBrowserWindowBinding,
            drainLeaseID: drainLeaseID)
    }

    func awaitDrained(identity: PeekabooBridgeBrowserCapabilityNamespaceIdentity) async throws {
        try self.requireLiveRegistry()
        try Task.checkCancellation()
        guard identity.registryGenerationID == self.registryGenerationID else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.registryGenerationMismatch
        }
        guard let drainLeaseID = identity.drainLeaseID else { return }
        guard let entry = self.entries[identity.namespaceID] else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.namespaceNotFound
        }
        guard entry.receipt.payload.principal == identity.principal,
              entry.allowsNativeBrowserWindowBinding == identity.allowsNativeBrowserWindowBinding
        else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.principalMismatch
        }
        if entry.outstandingDrainLeaseID != drainLeaseID {
            guard entry.outstandingDrainLeaseID == nil,
                  entry.activeClaimIDs.isEmpty,
                  entry.state == .closed || entry.state == .expired
            else {
                throw PeekabooBridgeBrowserCapabilityNamespaceError.claimMismatch
            }
            return
        }
        guard entry.state != .open else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.namespaceClosing
        }
        if entry.activeClaimIDs.isEmpty {
            entry.outstandingDrainLeaseID = nil
            self.finishTerminalStateIfDrained(entry)
            return
        }
        let waiterID = self.nextDrainWaiterID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: DrainContinuation) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    entry.drainWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelNamespaceDrainWaiter(
                    namespaceID: identity.namespaceID,
                    waiterID: waiterID)
            }
        }
        try Task.checkCancellation()
    }

    func close(
        _ receipt: PeekabooBridgeBrowserCapabilityNamespaceReceipt,
        principal: PeekabooBridgeBrowserCapabilityPrincipal) async throws
    {
        let identity = try self.beginClose(receipt, principal: principal)
        try await self.awaitDrained(identity: identity)
    }

    /// Stops all namespaces, waits for in-flight authority claims, and leaves no accepting entry.
    func drainAll() async throws {
        try self.beginDrainingAll()
        try Task.checkCancellation()
        guard self.entries.values.contains(where: { !$0.activeClaimIDs.isEmpty }) else { return }
        guard self.allDrainWaiter == nil else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.drainAlreadyAwaited
        }
        let waiterID = self.nextDrainWaiterID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: DrainContinuation) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.allDrainWaiter = DrainWaiter(id: waiterID, continuation: continuation)
                }
            }
        } onCancel: {
            Task {
                await self.cancelAllDrainWaiter(waiterID: waiterID)
            }
        }
        try Task.checkCancellation()
    }

    /// Freezes namespace admission synchronously without waiting for already-claimed work.
    func beginDrainingAll() throws {
        try self.requireLiveRegistry()
        self.drainingAll = true
        let now = self.clock()
        self.expireEntries(at: now)
        for entry in self.entries.values where entry.state == .open {
            entry.state = entry.activeClaimIDs.isEmpty ? .closed : .closing
            self.resumeNamespaceDrainWaiterIfDrained(entry)
        }
    }

    /// Immediately invalidates this generation. A replacement authority must mint a new generation and namespace IDs.
    @discardableResult
    func invalidateForRestart() -> Int {
        guard !self.invalidatedForRestart else { return 0 }
        self.invalidatedForRestart = true
        self.drainingAll = true
        let invalidatedCount = self.entries.count
        for entry in self.entries.values {
            entry.state = .closed
            entry.outstandingDrainLeaseID = nil
            let waiters = Array(entry.drainWaiters.values)
            entry.drainWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(throwing: PeekabooBridgeBrowserCapabilityNamespaceError.registryInvalidated)
            }
        }
        let allWaiter = self.allDrainWaiter
        self.allDrainWaiter = nil
        allWaiter?.continuation.resume(
            throwing: PeekabooBridgeBrowserCapabilityNamespaceError.registryInvalidated)
        return invalidatedCount
    }

    func lifecycleState(namespaceID: UUID) -> LifecycleState? {
        self.expireEntries(at: self.clock())
        return self.entries[namespaceID]?.state
    }

    func activeClaimCount(namespaceID: UUID) -> Int? {
        self.entries[namespaceID]?.activeClaimIDs.count
    }

    func retainedNamespaceCount() -> Int {
        self.entries.count
    }

    func terminalNamespaceIDsRequiringRuntimeRetirement() throws -> [UUID] {
        try self.requireLiveRegistry()
        self.expireEntries(at: self.clock())
        return self.entries.values
            .filter { ($0.state == .closed || $0.state == .expired) && !$0.runtimeRetired }
            .sorted { $0.ordinal < $1.ordinal }
            .map(\.receipt.payload.namespaceID)
    }

    func markRuntimeRetired(namespaceID: UUID) throws {
        try self.requireLiveRegistry()
        guard let entry = self.entries[namespaceID] else { return }
        guard entry.state == .closed || entry.state == .expired else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.namespaceClosing
        }
        entry.runtimeRetired = true
    }

    func verify(
        _ receipt: PeekabooBridgeBrowserCapabilityNamespaceReceipt,
        principal: PeekabooBridgeBrowserCapabilityPrincipal) throws
    {
        _ = try self.validateRegisteredReceipt(receipt, principal: principal, at: self.clock())
    }

    private func requireLiveRegistry() throws {
        guard !self.invalidatedForRestart else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.registryInvalidated
        }
    }

    private func requireAcceptingRegistry() throws {
        try self.requireLiveRegistry()
        guard !self.drainingAll else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.registryDraining
        }
    }

    private func makeReceipt(
        principal: PeekabooBridgeBrowserCapabilityPrincipal,
        lifetimeMilliseconds: Int64,
        now: Int64) throws -> PeekabooBridgeBrowserCapabilityNamespaceReceipt
    {
        guard now > 0,
              (1...self.configuration.maximumLifetimeMilliseconds).contains(lifetimeMilliseconds)
        else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.invalidReceipt
        }
        let (expiresAt, overflow) = now.addingReportingOverflow(lifetimeMilliseconds)
        guard !overflow else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.invalidReceipt
        }
        let namespaceID = try self.nextUniqueNamespaceID()
        let payload = PeekabooBridgeBrowserCapabilityNamespaceReceiptPayload(
            schemaVersion: 1,
            namespaceID: namespaceID,
            listenerInstanceID: self.signingContext.listenerAttestation.listenerInstanceID,
            listenerPublicKeySHA256: PeekabooBridgeOperationReceiptCoding.sha256(
                self.signingContext.listenerAttestation.publicKey),
            registryGenerationID: self.registryGenerationID,
            principal: principal,
            issuedAtUnixMilliseconds: now,
            expiresAtUnixMilliseconds: expiresAt)
        return try self.signingContext.sign(payload)
    }

    private func validateRegisteredReceipt(
        _ receipt: PeekabooBridgeBrowserCapabilityNamespaceReceipt,
        principal: PeekabooBridgeBrowserCapabilityPrincipal,
        at now: Int64,
        allowsClosedNamespace: Bool = false) throws -> UUID
    {
        try self.requireLiveRegistry()
        try Self.validatePrincipal(principal, expectedUserIdentifier: self.hostEffectiveUserIdentifier)
        self.expireEntries(at: now)
        try self.validateReceipt(receipt, principal: principal, at: now)
        guard let entry = self.entries[receipt.payload.namespaceID] else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.namespaceNotFound
        }
        guard entry.receipt == receipt else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.invalidReceipt
        }
        switch entry.state {
        case .expired:
            throw PeekabooBridgeBrowserCapabilityNamespaceError.namespaceExpired
        case .closed:
            if allowsClosedNamespace {
                return receipt.payload.namespaceID
            }
            throw PeekabooBridgeBrowserCapabilityNamespaceError.namespaceClosed
        case .open, .closing:
            return receipt.payload.namespaceID
        }
    }

    private func validateReceipt(
        _ receipt: PeekabooBridgeBrowserCapabilityNamespaceReceipt,
        principal: PeekabooBridgeBrowserCapabilityPrincipal,
        at now: Int64,
        allowsExpired: Bool = false) throws
    {
        let payload = receipt.payload
        guard payload.schemaVersion == 1,
              Self.isVersion4(payload.namespaceID),
              Self.isVersion4(payload.registryGenerationID),
              payload.issuedAtUnixMilliseconds > 0,
              payload.expiresAtUnixMilliseconds > payload.issuedAtUnixMilliseconds,
              payload.signatureInputsAreCanonical
        else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.invalidReceipt
        }
        guard payload.listenerInstanceID == self.signingContext.listenerAttestation.listenerInstanceID,
              payload.listenerPublicKeySHA256 == PeekabooBridgeOperationReceiptCoding.sha256(
                  self.signingContext.listenerAttestation.publicKey)
        else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.listenerMismatch
        }
        guard payload.registryGenerationID == self.registryGenerationID else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.registryGenerationMismatch
        }
        guard payload.principal == principal else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.principalMismatch
        }
        let (lifetime, lifetimeOverflow) = payload.expiresAtUnixMilliseconds.subtractingReportingOverflow(
            payload.issuedAtUnixMilliseconds)
        guard !lifetimeOverflow,
              lifetime <= self.configuration.maximumLifetimeMilliseconds
        else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.invalidReceipt
        }
        let (latestAllowedIssue, issueOverflow) = now.addingReportingOverflow(
            self.configuration.maximumFutureSkewMilliseconds)
        guard !issueOverflow, payload.issuedAtUnixMilliseconds <= latestAllowedIssue else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.receiptNotYetValid
        }
        guard allowsExpired || now < payload.expiresAtUnixMilliseconds else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.receiptExpired
        }
        try self.signingContext.validateSignature(receipt)
    }

    private func reserveCapacity(excluding excludedNamespaceIDs: Set<UUID>) throws {
        while self.entries.count >= self.configuration.maximumNamespaceCount {
            guard let removable = self.entries.values
                .filter({
                    !excludedNamespaceIDs.contains($0.receipt.payload.namespaceID) &&
                        ($0.state == .closed || $0.state == .expired) &&
                        $0.runtimeRetired &&
                        $0.activeClaimIDs.isEmpty &&
                        $0.drainWaiters.isEmpty &&
                        $0.outstandingDrainLeaseID == nil
                })
                .min(by: { $0.ordinal < $1.ordinal })
            else {
                throw PeekabooBridgeBrowserCapabilityNamespaceError.namespaceCapacityExceeded
            }
            self.entries[removable.receipt.payload.namespaceID] = nil
        }
    }

    private func expireEntries(at now: Int64) {
        for entry in self.entries.values
            where entry.state != .closed && now >= entry.receipt.payload.expiresAtUnixMilliseconds
        {
            entry.state = .expired
            self.resumeNamespaceDrainWaiterIfDrained(entry)
        }
        self.resumeAllDrainWaiterIfDrained()
    }

    private func finishTerminalStateIfDrained(_ entry: Entry) {
        guard entry.activeClaimIDs.isEmpty else { return }
        if entry.state == .closing {
            entry.state = .closed
        }
        self.resumeNamespaceDrainWaiterIfDrained(entry)
    }

    private func resumeNamespaceDrainWaiterIfDrained(_ entry: Entry) {
        guard entry.activeClaimIDs.isEmpty else { return }
        let waiters = Array(entry.drainWaiters.values)
        entry.drainWaiters.removeAll()
        entry.outstandingDrainLeaseID = nil
        waiters.forEach { $0.resume() }
    }

    private func resumeAllDrainWaiterIfDrained() {
        guard !self.entries.values.contains(where: { !$0.activeClaimIDs.isEmpty }) else { return }
        guard let waiter = self.allDrainWaiter else { return }
        self.allDrainWaiter = nil
        waiter.continuation.resume()
    }

    private func cancelNamespaceDrainWaiter(namespaceID: UUID, waiterID: UInt64) {
        guard let entry = self.entries[namespaceID],
              let waiter = entry.drainWaiters.removeValue(forKey: waiterID)
        else { return }
        waiter.resume(throwing: CancellationError())
    }

    private func cancelAllDrainWaiter(waiterID: UInt64) {
        guard self.allDrainWaiter?.id == waiterID else { return }
        let waiter = self.allDrainWaiter
        self.allDrainWaiter = nil
        waiter?.continuation.resume(throwing: CancellationError())
    }

    private func nextDrainLeaseID() -> UInt64 {
        self.drainLeaseOrdinal &+= 1
        if self.drainLeaseOrdinal == 0 {
            self.drainLeaseOrdinal &+= 1
        }
        return self.drainLeaseOrdinal
    }

    private func nextDrainWaiterID() -> UInt64 {
        self.nextDrainLeaseID()
    }

    private func nextUniqueNamespaceID() throws -> UUID {
        for _ in 0..<32 {
            let candidate = self.uuidGenerator()
            if Self.isVersion4(candidate), self.entries[candidate] == nil, candidate != self.registryGenerationID {
                return candidate
            }
        }
        throw PeekabooBridgeBrowserCapabilityNamespaceError.invalidConfiguration
    }

    private func lifecycleError(_ state: LifecycleState) -> PeekabooBridgeBrowserCapabilityNamespaceError {
        switch state {
        case .open:
            .claimMismatch
        case .closing:
            .namespaceClosing
        case .closed:
            .namespaceClosed
        case .expired:
            .namespaceExpired
        }
    }

    private static func validatePrincipal(
        _ principal: PeekabooBridgeBrowserCapabilityPrincipal,
        expectedUserIdentifier: uid_t) throws
    {
        guard principal.effectiveUserIdentifier == expectedUserIdentifier,
              (1...128).contains(principal.teamIdentifier.utf8.count),
              (1...512).contains(principal.bundleIdentifier.utf8.count),
              principal.teamIdentifier.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0)
              }),
              principal.bundleIdentifier.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0)
              }),
              principal.codeSignatureHash.count == 40,
              principal.codeSignatureHash == principal.codeSignatureHash.lowercased(),
              principal.codeSignatureHash.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef").contains($0)
              })
        else {
            throw PeekabooBridgeBrowserCapabilityNamespaceError.invalidPrincipal
        }
    }

    private static func isVersion4(_ value: UUID) -> Bool {
        let bytes = withUnsafeBytes(of: value.uuid) { Array($0) }
        return bytes.count == 16 && bytes[6] >> 4 == 4 && bytes[8] >> 6 == 2
    }

    private static func isNonzero(_ value: UUID) -> Bool {
        value != self.zeroUUID
    }

    private static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    private struct DrainWaiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private final class Entry: @unchecked Sendable {
        let receipt: PeekabooBridgeBrowserCapabilityNamespaceReceipt
        var state: LifecycleState
        let allowsNativeBrowserWindowBinding: Bool
        let ordinal: UInt64
        var claimedIDs: Set<UUID> = []
        var activeClaimIDs: Set<UUID> = []
        var outstandingDrainLeaseID: UInt64?
        var drainWaiters: [UInt64: DrainContinuation] = [:]
        var runtimeRetired = false

        init(
            receipt: PeekabooBridgeBrowserCapabilityNamespaceReceipt,
            state: LifecycleState,
            allowsNativeBrowserWindowBinding: Bool,
            ordinal: UInt64)
        {
            self.receipt = receipt
            self.state = state
            self.allowsNativeBrowserWindowBinding = allowsNativeBrowserWindowBinding
            self.ordinal = ordinal
        }
    }
}

extension PeekabooBridgeBrowserCapabilityNamespaceReceiptPayload {
    fileprivate var signatureInputsAreCanonical: Bool {
        self.listenerPublicKeySHA256.count == 64 &&
            self.listenerPublicKeySHA256 == self.listenerPublicKeySHA256.lowercased() &&
            self.listenerPublicKeySHA256.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdef").contains($0)
            }
    }
}
