import CryptoKit
import Darwin
import Foundation
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeBrowserCapabilityNamespaceAuthorityTests {
    @Test
    func `reusable receipt signs canonical principal and rejects claim replay`() async throws {
        let fixture = try NamespaceAuthorityFixture(
            uuids: [Self.uuid(1), Self.uuid(2)],
            maximumClaimCount: 3)
        let receipt = try await fixture.authority.open(
            principal: fixture.principal,
            admission: fixture.namespaceAdmission,
            lifetimeMilliseconds: 10000)
        try await fixture.authority.verify(receipt, principal: fixture.principal)

        let canonical = try PeekabooBridgeOperationReceiptCoding.canonicalData(receipt)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeBrowserCapabilityNamespaceReceipt.self,
            from: canonical)
        #expect(try PeekabooBridgeOperationReceiptCoding.canonicalData(decoded) == canonical)
        #expect(receipt.payload.namespaceID == Self.uuid(2))
        #expect(receipt.payload.registryGenerationID == Self.uuid(1))
        #expect(receipt.payload.principal == fixture.principal)

        let claimID = Self.claimID(1)
        let claim = try await fixture.authority.claim(
            receipt,
            principal: fixture.principal,
            claimID: claimID,
            admission: fixture.backgroundAdmission)
        #expect(claim.authorization.namespaceID == receipt.payload.namespaceID)
        #expect(claim.authorization.executionPolicy == .backgroundOnly)
        #expect(claim.authorization.allowsNativeBrowserWindowBinding)

        let replay = await #expect(throws: PeekabooBridgeBrowserCapabilityNamespaceError.self) {
            try await fixture.authority.claim(
                receipt,
                principal: fixture.principal,
                claimID: claimID,
                admission: fixture.backgroundAdmission)
        }
        #expect(replay == .replayedClaim)
        try await fixture.authority.complete(claim)

        let second = try await fixture.authority.claim(
            receipt,
            principal: fixture.principal,
            claimID: Self.claimID(2),
            admission: fixture.foregroundAdmission)
        #expect(second.authorization.executionPolicy == .foregroundAllowed)
        try await fixture.authority.complete(second)

        let third = try await fixture.authority.claim(
            receipt,
            principal: fixture.principal,
            claimID: Self.claimID(3),
            admission: fixture.backgroundAdmission)
        #expect(third.authorization.executionPolicy == .backgroundOnly)
        try await fixture.authority.complete(third)
    }

    @Test
    func `receipt refuses copied principals wrong listeners wrong keys and forged signatures`() async throws {
        let fixture = try NamespaceAuthorityFixture(uuids: [Self.uuid(10), Self.uuid(11)])
        let receipt = try await fixture.authority.open(
            principal: fixture.principal,
            admission: fixture.namespaceAdmission,
            lifetimeMilliseconds: 10000)

        let foreignPrincipal = PeekabooBridgeBrowserCapabilityPrincipal(
            effectiveUserIdentifier: fixture.principal.effectiveUserIdentifier,
            teamIdentifier: fixture.principal.teamIdentifier,
            bundleIdentifier: "boo.peekaboo.foreign-cli",
            codeSignatureHash: String(repeating: "b", count: 40))
        let principalError = await #expect(throws: PeekabooBridgeBrowserCapabilityNamespaceError.self) {
            try await fixture.authority.verify(receipt, principal: foreignPrincipal)
        }
        #expect(principalError == .principalMismatch)

        let forged = PeekabooBridgeBrowserCapabilityNamespaceReceipt(
            payload: receipt.payload,
            signature: Data(repeating: 0xAA, count: receipt.signature.count))
        let signatureError = await #expect(throws: PeekabooBridgeBrowserCapabilityNamespaceError.self) {
            try await fixture.authority.verify(forged, principal: fixture.principal)
        }
        #expect(signatureError == .invalidSignature)

        let foreignListener = try DeterministicNamespaceSigner(seed: 0x44, listenerInstanceID: Self.uuid(20))
        let foreignAuthority = try PeekabooBridgeBrowserCapabilityNamespaceAuthority(
            signingContext: foreignListener.context,
            hostEffectiveUserIdentifier: fixture.principal.effectiveUserIdentifier,
            configuration: fixture.configuration,
            clock: fixture.clock.now,
            uuidGenerator: DeterministicUUIDGenerator([Self.uuid(21)]).next)
        let listenerError = await #expect(throws: PeekabooBridgeBrowserCapabilityNamespaceError.self) {
            try await foreignAuthority.verify(receipt, principal: fixture.principal)
        }
        #expect(listenerError == .listenerMismatch)

        let foreignKey = try DeterministicNamespaceSigner(
            seed: 0x55,
            listenerInstanceID: fixture.signer.listenerAttestation.listenerInstanceID)
        let foreignKeyAuthority = try PeekabooBridgeBrowserCapabilityNamespaceAuthority(
            signingContext: foreignKey.context,
            hostEffectiveUserIdentifier: fixture.principal.effectiveUserIdentifier,
            configuration: fixture.configuration,
            clock: fixture.clock.now,
            uuidGenerator: DeterministicUUIDGenerator([Self.uuid(22)]).next)
        let keyError = await #expect(throws: PeekabooBridgeBrowserCapabilityNamespaceError.self) {
            try await foreignKeyAuthority.verify(receipt, principal: fixture.principal)
        }
        #expect(keyError == .listenerMismatch)
    }

    @Test
    func `bounded issue and expiry times fail closed and update lifecycle`() async throws {
        let fixture = try NamespaceAuthorityFixture(uuids: [Self.uuid(30), Self.uuid(31)])
        let receipt = try await fixture.authority.open(
            principal: fixture.principal,
            admission: fixture.namespaceAdmission,
            lifetimeMilliseconds: 1000)

        let futurePayload = PeekabooBridgeBrowserCapabilityNamespaceReceiptPayload(
            schemaVersion: receipt.payload.schemaVersion,
            namespaceID: receipt.payload.namespaceID,
            listenerInstanceID: receipt.payload.listenerInstanceID,
            listenerPublicKeySHA256: receipt.payload.listenerPublicKeySHA256,
            registryGenerationID: receipt.payload.registryGenerationID,
            principal: receipt.payload.principal,
            issuedAtUnixMilliseconds: fixture.clock.value +
                fixture.configuration.maximumFutureSkewMilliseconds + 1,
            expiresAtUnixMilliseconds: fixture.clock.value +
                fixture.configuration.maximumFutureSkewMilliseconds + 501)
        let futureReceipt = try fixture.signer.context.sign(futurePayload)
        let futureError = await #expect(throws: PeekabooBridgeBrowserCapabilityNamespaceError.self) {
            try await fixture.authority.verify(futureReceipt, principal: fixture.principal)
        }
        #expect(futureError == .receiptNotYetValid)

        fixture.clock.advance(by: 1000)
        let expiryError = await #expect(throws: PeekabooBridgeBrowserCapabilityNamespaceError.self) {
            try await fixture.authority.verify(receipt, principal: fixture.principal)
        }
        #expect(expiryError == .receiptExpired)
        #expect(await fixture.authority.lifecycleState(namespaceID: receipt.payload.namespaceID) == .expired)
    }

    @Test
    func `claim exhaustion rolls to a fresh namespace and leaves predecessor closed`() async throws {
        let fixture = try NamespaceAuthorityFixture(
            uuids: [Self.uuid(40), Self.uuid(41), Self.uuid(42)],
            maximumClaimCount: 1)
        let first = try await fixture.authority.open(
            principal: fixture.principal,
            admission: fixture.namespaceAdmission,
            lifetimeMilliseconds: 10000)
        let firstClaim = try await fixture.authority.claim(
            first,
            principal: fixture.principal,
            claimID: Self.claimID(40),
            admission: fixture.backgroundAdmission)
        #expect(await fixture.authority.lifecycleState(namespaceID: first.payload.namespaceID) == .closing)
        try await fixture.authority.complete(firstClaim)
        #expect(await fixture.authority.lifecycleState(namespaceID: first.payload.namespaceID) == .closed)

        let successor = try await fixture.authority.rollover(
            first,
            principal: fixture.principal,
            admission: fixture.namespaceAdmission,
            lifetimeMilliseconds: 10000)
        #expect(successor.payload.namespaceID == Self.uuid(42))
        #expect(successor.payload.namespaceID != first.payload.namespaceID)
        #expect(await fixture.authority.lifecycleState(namespaceID: successor.payload.namespaceID) == .open)

        let staleError = await #expect(throws: PeekabooBridgeBrowserCapabilityNamespaceError.self) {
            try await fixture.authority.claim(
                first,
                principal: fixture.principal,
                claimID: Self.claimID(41),
                admission: fixture.backgroundAdmission)
        }
        #expect(staleError == .namespaceClosed)
        let successorClaim = try await fixture.authority.claim(
            successor,
            principal: fixture.principal,
            claimID: Self.claimID(42),
            admission: fixture.backgroundAdmission)
        try await fixture.authority.complete(successorClaim)
    }

    @Test
    func `close revokes first and concurrently drains every active claim`() async throws {
        let fixture = try NamespaceAuthorityFixture(uuids: [Self.uuid(50), Self.uuid(51)])
        let receipt = try await fixture.authority.open(
            principal: fixture.principal,
            admission: fixture.namespaceAdmission,
            lifetimeMilliseconds: 10000)
        let first = try await fixture.authority.claim(
            receipt,
            principal: fixture.principal,
            claimID: Self.claimID(50),
            admission: fixture.backgroundAdmission)
        let second = try await fixture.authority.claim(
            receipt,
            principal: fixture.principal,
            claimID: Self.claimID(51),
            admission: fixture.backgroundAdmission)
        let identity = try await fixture.authority.beginClose(receipt, principal: fixture.principal)
        #expect(identity.namespaceID == receipt.payload.namespaceID)
        #expect(await fixture.authority.lifecycleState(namespaceID: receipt.payload.namespaceID) == .closing)

        let closedClaim = await #expect(throws: PeekabooBridgeBrowserCapabilityNamespaceError.self) {
            try await fixture.authority.claim(
                receipt,
                principal: fixture.principal,
                claimID: Self.claimID(52),
                admission: fixture.backgroundAdmission)
        }
        #expect(closedClaim == .namespaceClosing)

        let drainFinished = CompletionProbe()
        let drain = Task {
            try await fixture.authority.awaitDrained(identity: identity)
            await drainFinished.markFinished()
        }
        await Task.yield()
        #expect(await !drainFinished.isFinished)
        try await fixture.authority.complete(first)
        await Task.yield()
        #expect(await !drainFinished.isFinished)
        try await fixture.authority.complete(second)
        try await drain.value
        #expect(await drainFinished.isFinished)
        #expect(await fixture.authority.lifecycleState(namespaceID: receipt.payload.namespaceID) == .closed)
    }

    @Test
    func `host restart invalidates old generation receipts and outstanding claims`() async throws {
        let fixture = try NamespaceAuthorityFixture(uuids: [Self.uuid(60), Self.uuid(61)])
        let receipt = try await fixture.authority.open(
            principal: fixture.principal,
            admission: fixture.namespaceAdmission,
            lifetimeMilliseconds: 10000)
        let claim = try await fixture.authority.claim(
            receipt,
            principal: fixture.principal,
            claimID: Self.claimID(60),
            admission: fixture.backgroundAdmission)
        let identity = try await fixture.authority.beginClose(receipt, principal: fixture.principal)
        let waitingClose = Task {
            try await fixture.authority.awaitDrained(identity: identity)
        }
        await Task.yield()
        #expect(await fixture.authority.invalidateForRestart() == 1)

        let waitingCloseError = await #expect(throws: PeekabooBridgeBrowserCapabilityNamespaceError.self) {
            try await waitingClose.value
        }
        #expect(waitingCloseError == .registryInvalidated)
        #expect(await fixture.authority.activeClaimCount(namespaceID: receipt.payload.namespaceID) == 1)

        let invalidated = await #expect(throws: PeekabooBridgeBrowserCapabilityNamespaceError.self) {
            try await fixture.authority.verify(receipt, principal: fixture.principal)
        }
        #expect(invalidated == .registryInvalidated)
        let completionError = await #expect(throws: PeekabooBridgeBrowserCapabilityNamespaceError.self) {
            try await fixture.authority.complete(claim)
        }
        #expect(completionError == .registryInvalidated)
        #expect(await fixture.authority.activeClaimCount(namespaceID: receipt.payload.namespaceID) == 0)

        let replacement = try PeekabooBridgeBrowserCapabilityNamespaceAuthority(
            signingContext: fixture.signer.context,
            hostEffectiveUserIdentifier: fixture.principal.effectiveUserIdentifier,
            configuration: fixture.configuration,
            clock: fixture.clock.now,
            uuidGenerator: DeterministicUUIDGenerator([Self.uuid(62)]).next)
        let staleGeneration = await #expect(throws: PeekabooBridgeBrowserCapabilityNamespaceError.self) {
            try await replacement.verify(receipt, principal: fixture.principal)
        }
        #expect(staleGeneration == .registryGenerationMismatch)
    }

    @Test
    func `global drain freezes admission until every active claim completes`() async throws {
        let fixture = try NamespaceAuthorityFixture(
            uuids: [Self.uuid(70), Self.uuid(71), Self.uuid(72)])
        let receipt = try await fixture.authority.open(
            principal: fixture.principal,
            admission: fixture.namespaceAdmission,
            lifetimeMilliseconds: 10000)
        let claim = try await fixture.authority.claim(
            receipt,
            principal: fixture.principal,
            claimID: Self.claimID(70),
            admission: fixture.backgroundAdmission)
        let drain = Task {
            try await fixture.authority.drainAll()
        }
        for _ in 0..<100 {
            if await fixture.authority.lifecycleState(namespaceID: receipt.payload.namespaceID) == .closing {
                break
            }
            await Task.yield()
        }
        #expect(await fixture.authority.lifecycleState(namespaceID: receipt.payload.namespaceID) == .closing)

        let openError = await #expect(throws: PeekabooBridgeBrowserCapabilityNamespaceError.self) {
            try await fixture.authority.open(
                principal: fixture.principal,
                admission: fixture.namespaceAdmission,
                lifetimeMilliseconds: 10000)
        }
        #expect(openError == .registryDraining)
        let claimError = await #expect(throws: PeekabooBridgeBrowserCapabilityNamespaceError.self) {
            try await fixture.authority.claim(
                receipt,
                principal: fixture.principal,
                claimID: Self.claimID(71),
                admission: fixture.backgroundAdmission)
        }
        #expect(claimError == .registryDraining)

        try await fixture.authority.complete(claim)
        try await drain.value
        #expect(await fixture.authority.lifecycleState(namespaceID: receipt.payload.namespaceID) == .closed)
    }

    @Test
    func `cancelled close wait removes its waiter and permits one bounded retry`() async throws {
        let fixture = try NamespaceAuthorityFixture(uuids: [Self.uuid(80), Self.uuid(81)])
        let receipt = try await fixture.authority.open(
            principal: fixture.principal,
            admission: fixture.namespaceAdmission,
            lifetimeMilliseconds: 10000)
        let claim = try await fixture.authority.claim(
            receipt,
            principal: fixture.principal,
            claimID: Self.claimID(80),
            admission: fixture.backgroundAdmission)
        let identity = try await fixture.authority.beginClose(receipt, principal: fixture.principal)
        let cancelled = Task {
            try await fixture.authority.awaitDrained(identity: identity)
        }
        await Task.yield()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }

        let retry = Task {
            try await fixture.authority.awaitDrained(identity: identity)
        }
        await Task.yield()
        try await fixture.authority.complete(claim)
        try await retry.value
        #expect(await fixture.authority.lifecycleState(namespaceID: receipt.payload.namespaceID) == .closed)
    }

    @Test
    func `already drained close identity survives terminal registry eviction`() async throws {
        let fixture = try NamespaceAuthorityFixture(
            uuids: [
                Self.uuid(90), Self.uuid(91), Self.uuid(92), Self.uuid(93),
                Self.uuid(94), Self.uuid(95),
            ])
        let receipt = try await fixture.authority.open(
            principal: fixture.principal,
            admission: fixture.namespaceAdmission,
            lifetimeMilliseconds: 10000)
        let identity = try await fixture.authority.beginClose(receipt, principal: fixture.principal)

        for _ in 0..<4 {
            _ = try await fixture.authority.open(
                principal: fixture.principal,
                admission: fixture.namespaceAdmission,
                lifetimeMilliseconds: 10000)
        }
        #expect(await fixture.authority.lifecycleState(namespaceID: receipt.payload.namespaceID) == nil)
        try await fixture.authority.awaitDrained(identity: identity)
    }

    private static func uuid(_ suffix: UInt16) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", suffix))!
    }

    private static func claimID(_ suffix: UInt16) -> UUID {
        UUID(uuidString: String(format: "10000000-0000-8000-8000-%012x", suffix))!
    }
}

private struct NamespaceAuthorityFixture {
    let signer: DeterministicNamespaceSigner
    let clock: DeterministicUnixClock
    let principal: PeekabooBridgeBrowserCapabilityPrincipal
    let configuration: PeekabooBridgeBrowserCapabilityNamespaceAuthority.Configuration
    let authority: PeekabooBridgeBrowserCapabilityNamespaceAuthority
    let namespaceAdmission: PeekabooBridgeBrowserCapabilityNamespaceAdmission
    let backgroundAdmission: PeekabooBridgeBrowserCapabilityClaimAdmission
    let foregroundAdmission: PeekabooBridgeBrowserCapabilityClaimAdmission

    init(uuids: [UUID], maximumClaimCount: Int = 16) throws {
        let userIdentifier = uid_t(501)
        let clock = DeterministicUnixClock(1_000_000)
        let signer = try DeterministicNamespaceSigner(
            seed: 0x22,
            listenerInstanceID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!)
        let principal = PeekabooBridgeBrowserCapabilityPrincipal(
            effectiveUserIdentifier: userIdentifier,
            teamIdentifier: "TEAMID1234",
            bundleIdentifier: "boo.peekaboo.cli",
            codeSignatureHash: String(repeating: "a", count: 40))
        let configuration = PeekabooBridgeBrowserCapabilityNamespaceAuthority.Configuration(
            maximumNamespaceCount: 4,
            maximumLifetimeMilliseconds: 10000,
            maximumClaimCountPerNamespace: maximumClaimCount,
            maximumFutureSkewMilliseconds: 100)
        let generator = DeterministicUUIDGenerator(uuids)
        let namespaceAdmission = try #require(PeekabooBridgeBrowserCapabilityNamespaceAdmission(
            isLocalExecutionHost: true,
            isAuthenticatedPeer: true,
            hasNativeCapableService: true))
        let backgroundAdmission = try #require(PeekabooBridgeBrowserCapabilityClaimAdmission(
            executionPolicy: .backgroundOnly,
            isLocalExecutionHost: true,
            isAuthenticatedPeer: true))
        let foregroundAdmission = try #require(PeekabooBridgeBrowserCapabilityClaimAdmission(
            executionPolicy: .foregroundAllowed,
            isLocalExecutionHost: true,
            isAuthenticatedPeer: true,
            hasScopedForegroundAuthorization: true))
        self.signer = signer
        self.clock = clock
        self.principal = principal
        self.configuration = configuration
        self.namespaceAdmission = namespaceAdmission
        self.backgroundAdmission = backgroundAdmission
        self.foregroundAdmission = foregroundAdmission
        self.authority = try PeekabooBridgeBrowserCapabilityNamespaceAuthority(
            signingContext: signer.context,
            hostEffectiveUserIdentifier: userIdentifier,
            configuration: configuration,
            clock: clock.now,
            uuidGenerator: generator.next)
    }
}

private struct DeterministicNamespaceSigner {
    let privateKey: Curve25519.Signing.PrivateKey
    let listenerAttestation: PeekabooBridgeListenerAttestation
    let context: PeekabooBridgeBrowserCapabilityNamespaceSigningContext

    init(seed: UInt8, listenerInstanceID: UUID) throws {
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((0..<32).map { seed &+ UInt8($0) }))
        let publicKey = privateKey.publicKey.rawRepresentation
        let unsigned = PeekabooBridgeListenerAttestation.UnsignedPayload(
            schemaVersion: 1,
            listenerInstanceID: listenerInstanceID,
            publicKey: publicKey,
            host: .init(
                processIdentifier: 123,
                processStartIdentity: 456,
                codeSignatureHash: String(repeating: "c", count: 40)),
            createdAtUnixMilliseconds: 999_000,
            receiptArchiveDirectory: "/tmp/peekaboo-namespace-tests")
        let listenerAttestation = try PeekabooBridgeListenerAttestation(
            listenerInstanceID: unsigned.listenerInstanceID,
            publicKey: unsigned.publicKey,
            host: unsigned.host,
            createdAtUnixMilliseconds: unsigned.createdAtUnixMilliseconds,
            receiptArchiveDirectory: unsigned.receiptArchiveDirectory,
            signature: privateKey.signature(
                for: PeekabooBridgeOperationReceiptCoding.canonicalData(unsigned)))
        self.privateKey = privateKey
        self.listenerAttestation = listenerAttestation
        self.context = try PeekabooBridgeBrowserCapabilityNamespaceSigningContext(
            listenerAttestation: listenerAttestation,
            signCanonicalPayload: { payload in
                try privateKey.signature(
                    for: PeekabooBridgeOperationReceiptCoding.canonicalData(payload))
            })
    }
}

private final class DeterministicUnixClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int64

    init(_ value: Int64) {
        self.storage = value
    }

    var value: Int64 {
        self.lock.withLock { self.storage }
    }

    func now() -> Int64 {
        self.value
    }

    func advance(by milliseconds: Int64) {
        self.lock.withLock {
            self.storage += milliseconds
        }
    }
}

private final class DeterministicUUIDGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        self.lock.withLock {
            precondition(!self.values.isEmpty, "Deterministic UUID fixture exhausted")
            return self.values.removeFirst()
        }
    }
}

private actor CompletionProbe {
    private(set) var isFinished = false

    func markFinished() {
        self.isFinished = true
    }
}
