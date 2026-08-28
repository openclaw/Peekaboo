import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

public struct PeekabooBridgeBrowserSessionBootstrapRequest: Codable, Sendable, Equatable {
    public let receiptBundle: PeekabooBridgeOperationReceiptBundle?
    public let claimID: UUID

    public init(receiptBundle: PeekabooBridgeOperationReceiptBundle? = nil, claimID: UUID) {
        self.receiptBundle = receiptBundle
        self.claimID = claimID
    }
}

/// The public result deliberately contains no provider identifier or DevTools endpoint.
public struct PeekabooBridgeBrowserSessionBootstrapResponse: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let claimID: UUID
    public let targetReceiptSHA256: String?

    public init(sessionID: UUID, claimID: UUID, targetReceiptSHA256: String? = nil) {
        self.sessionID = sessionID
        self.claimID = claimID
        self.targetReceiptSHA256 = targetReceiptSHA256
    }
}

public enum PeekabooBridgeBrowserSessionControlAction: String, Codable, Sendable, Equatable {
    case disconnect
    case end
}

public enum PeekabooBridgeBrowserSessionErrorContext {
    public static let invalid = "browser_session:invalid"
    public static let ended = "browser_session:ended"
    public static let wrongOwner = "browser_session:wrong_owner"
    public static let hostGenerationChanged = "browser_session:host_generation_changed"
}

public struct PeekabooBridgeBrowserSessionControlRequest: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let action: PeekabooBridgeBrowserSessionControlAction

    public init(sessionID: UUID, action: PeekabooBridgeBrowserSessionControlAction) {
        self.sessionID = sessionID
        self.action = action
    }
}

extension PeekabooBridgeBrowserStatus {
    var isCanonicalScopedSessionStatus: Bool {
        guard let observation = self.observation,
              self.toolCount >= 0
        else { return false }
        let hasCanonicalTarget = self.connectionReceipt?.isCanonicalExecutionTarget == true
        let hasReceipt = self.connectionReceipt != nil
        let hasEpoch = self.providerSessionEpoch != nil
        guard hasReceipt == hasEpoch,
              self.providerSessionEpoch != Self.zeroProviderSessionEpoch,
              !hasReceipt || hasCanonicalTarget
        else { return false }
        return switch observation {
        case .confirmed:
            self.isConnected
                ? hasReceipt
                : self.toolCount == 0 && !hasReceipt
        case .indeterminate:
            !self.isConnected && self.toolCount == 0
        }
    }

    private static let zeroProviderSessionEpoch = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

public struct PeekabooBridgeBrowserSessionCaller: Sendable, Equatable {
    public let operationClientInstanceID: UUID
    public let process: PeekabooBridgeOperationProcessIdentity
    public let processIdentifierVersion: Int32
    public let effectiveUserIdentifier: uid_t
    public let bundleIdentifier: String
    public let teamIdentifier: String

    public init(
        operationClientInstanceID: UUID,
        process: PeekabooBridgeOperationProcessIdentity,
        processIdentifierVersion: Int32,
        effectiveUserIdentifier: uid_t,
        bundleIdentifier: String,
        teamIdentifier: String)
    {
        self.operationClientInstanceID = operationClientInstanceID
        self.process = process
        self.processIdentifierVersion = processIdentifierVersion
        self.effectiveUserIdentifier = effectiveUserIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
    }
}

public struct PeekabooBridgeBrowserSessionBootstrapContext: Sendable {
    public let sessionID: UUID
    public let claimID: UUID
    public let caller: PeekabooBridgeBrowserSessionCaller
    public let connectionReceipt: PeekabooBridgeBrowserConnectionReceipt?
    /// Host-private lookup key for the source epoch authorization; never encoded on the wire.
    public let handoffAuthorizationID: UUID?

    public init(
        sessionID: UUID,
        claimID: UUID,
        caller: PeekabooBridgeBrowserSessionCaller,
        connectionReceipt: PeekabooBridgeBrowserConnectionReceipt?,
        handoffAuthorizationID: UUID? = nil)
    {
        self.sessionID = sessionID
        self.claimID = claimID
        self.caller = caller
        self.connectionReceipt = connectionReceipt
        self.handoffAuthorizationID = handoffAuthorizationID
    }
}

/// Narrow transaction boundary implemented by the host-owned browser session pool.
///
/// Implementations must either install the complete caller-scoped child before returning or throw.
/// The invalidation hook is idempotent and lets the Bridge clean up failures after claim ownership
/// has become exclusive.
@MainActor
public protocol PeekabooBridgeBrowserSessionBootstrapProviding: Sendable {
    var supportsBrowserSessionBootstrap: Bool { get }

    func bootstrapBrowserSession(_ context: PeekabooBridgeBrowserSessionBootstrapContext) async throws

    func authorizeBrowserConnectionHandoff(
        _ connectionReceipt: PeekabooBridgeBrowserConnectionReceipt) async throws -> UUID

    func discardBrowserConnectionHandoffAuthorization(_ authorizationID: UUID) async

    func browserSessionStatus(
        sessionID: UUID,
        channel: String?) async throws -> PeekabooBridgeBrowserStatus

    func browserSessionConnect(
        sessionID: UUID,
        channel: String?,
        browserURL: String?) async throws -> DesktopActionResult<PeekabooBridgeBrowserStatus>

    func browserSessionExecute(
        sessionID: UUID,
        request: PeekabooBridgeBrowserExecuteRequest,
        expectedConnectionReceipt: PeekabooBridgeBrowserConnectionReceipt) async throws
        -> PeekabooBridgeBrowserExecutionResult

    func disconnectBrowserSession(_ sessionID: UUID) async throws

    /// Returns true only after the provider child, capability state, and target reservation are absent.
    func invalidateBrowserSession(_ sessionID: UUID) async -> Bool
}

extension PeekabooBridgeBrowserSessionBootstrapProviding {
    public func authorizeBrowserConnectionHandoff(
        _: PeekabooBridgeBrowserConnectionReceipt) async throws -> UUID
    {
        throw PeekabooBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "This Bridge provider cannot authorize an epoch-bound browser handoff")
    }

    public func discardBrowserConnectionHandoffAuthorization(_: UUID) async {}

    public func browserSessionStatus(sessionID _: UUID, channel _: String?) async throws
        -> PeekabooBridgeBrowserStatus
    {
        throw PeekabooBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "This Bridge provider does not implement scoped browser status")
    }

    public func browserSessionConnect(
        sessionID _: UUID,
        channel _: String?,
        browserURL _: String?) async throws -> DesktopActionResult<PeekabooBridgeBrowserStatus>
    {
        throw PeekabooBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "This Bridge provider does not implement scoped browser connect")
    }

    public func browserSessionExecute(
        sessionID _: UUID,
        request _: PeekabooBridgeBrowserExecuteRequest,
        expectedConnectionReceipt _: PeekabooBridgeBrowserConnectionReceipt) async throws
        -> PeekabooBridgeBrowserExecutionResult
    {
        throw PeekabooBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "This Bridge provider does not implement scoped browser execution")
    }

    public func disconnectBrowserSession(_: UUID) async throws {
        throw PeekabooBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "This Bridge provider does not implement scoped browser disconnect")
    }
}

struct PeekabooBridgeBrowserHandoffOperationContext: Sendable {
    let requestID: UUID
    let clientInstanceID: UUID
    let peer: PeekabooBridgePeer
}

@MainActor
final class PeekabooBridgeBrowserHandoffGrantRegistry {
    static let defaultCapacity = 128
    static let defaultLifetimeMilliseconds: Int64 = 60000

    private struct Claim: Equatable {
        let claimID: UUID
        let caller: PeekabooBridgeBrowserSessionCaller
        let sessionID: UUID
    }

    struct SessionOperationLease: Hashable {
        let sessionID: UUID
        let token: UUID
    }

    private final class BootstrapWaiter: @unchecked Sendable {
        typealias BootstrapResult = Result<PeekabooBridgeBrowserSessionBootstrapResponse, any Error>

        private let lock = NSLock()
        private var continuation: CheckedContinuation<BootstrapResult, Never>?
        private var result: BootstrapResult?

        func value() async -> BootstrapResult {
            await withCheckedContinuation { continuation in
                self.lock.withLock {
                    if let result = self.result {
                        continuation.resume(returning: result)
                    } else {
                        self.continuation = continuation
                    }
                }
            }
        }

        @discardableResult
        func finish(_ result: BootstrapResult) -> Bool {
            self.lock.withLock {
                guard self.result == nil else { return false }
                self.result = result
                let continuation = self.continuation
                self.continuation = nil
                continuation?.resume(returning: result)
                return true
            }
        }
    }

    private enum State {
        case reserved
        case pending
        case inFlight(Claim, Task<PeekabooBridgeBrowserSessionBootstrapResponse, any Error>)
        case succeeded(Claim, PeekabooBridgeBrowserSessionBootstrapResponse)
        case ending(Claim, PeekabooBridgeBrowserSessionBootstrapResponse, UUID, Task<Bool, Never>)
    }

    private struct Grant {
        let issuer: PeekabooBridgeBrowserSessionCaller
        var expiresAtUnixMilliseconds: Int64
        var receiptBundleSHA256: String?
        var connectionReceipt: PeekabooBridgeBrowserConnectionReceipt?
        var targetReceiptSHA256: String?
        var handoffAuthorizationID: UUID?
        var state: State
    }

    private struct EndedSession {
        let caller: PeekabooBridgeBrowserSessionCaller
        let expiresAtUnixMilliseconds: Int64
    }

    private struct EndedClaim {
        let caller: PeekabooBridgeBrowserSessionCaller
        let expiresAtUnixMilliseconds: Int64
    }

    private let capacity: Int
    private let lifetimeMilliseconds: Int64
    private let now: @Sendable () -> Int64
    private let provider: (any PeekabooBridgeBrowserSessionBootstrapProviding)?
    private let processStartIdentity: @Sendable (pid_t) -> UInt64?
    private let processPresence: @Sendable (pid_t) -> Bool?
    private var grants: [UUID: Grant] = [:]
    private var sessionGrantIDs: [UUID: UUID] = [:]
    private var endedSessions: [UUID: EndedSession] = [:]
    private var endedClaims: [UUID: EndedClaim] = [:]
    private var handoffAuthorizationIDs: Set<UUID> = []
    private var pendingCleanupSessionIDs: Set<UUID> = []
    private var activeOperationTokens: [UUID: Set<UUID>] = [:]
    private var operationDrainWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    init(
        provider: (any PeekabooBridgeBrowserSessionBootstrapProviding)?,
        capacity: Int = defaultCapacity,
        lifetimeMilliseconds: Int64 = defaultLifetimeMilliseconds,
        now: @escaping @Sendable () -> Int64 = {
            PeekabooBridgeOperationReceiptCoding.unixMilliseconds()
        },
        processStartIdentity: @escaping @Sendable (pid_t) -> UInt64? =
            SystemIdentityResolver.processStartIdentity,
        processPresence: @escaping @Sendable (pid_t) -> Bool? = {
            PeekabooBridgeServer.observeProcessPresence($0)
        })
    {
        precondition(capacity > 0)
        precondition(lifetimeMilliseconds > 0)
        self.provider = provider
        self.capacity = capacity
        self.lifetimeMilliseconds = lifetimeMilliseconds
        self.now = now
        self.processStartIdentity = processStartIdentity
        self.processPresence = processPresence
    }

    func reserve(requestID: UUID, issuer: PeekabooBridgeBrowserSessionCaller) async throws {
        await self.pruneExpired()
        guard self.grants[requestID] == nil else {
            throw Self.invalidRequest("Browser handoff request identifier was already reserved")
        }
        guard self.grants.count + self.pendingCleanupSessionIDs.count < self.capacity else {
            throw PeekabooBridgeErrorEnvelope(
                code: .serverBusy,
                message: "The bounded browser handoff grant registry is full")
        }
        let now = self.now()
        self.grants[requestID] = Grant(
            issuer: issuer,
            expiresAtUnixMilliseconds: Self.addingClamped(now, self.lifetimeMilliseconds),
            receiptBundleSHA256: nil,
            connectionReceipt: nil,
            targetReceiptSHA256: nil,
            handoffAuthorizationID: nil,
            state: .reserved)
    }

    func abandonReservation(requestID: UUID) -> UUID? {
        guard case .reserved = self.grants[requestID]?.state else { return nil }
        let authorizationID = self.grants.removeValue(forKey: requestID)?.handoffAuthorizationID
        if let authorizationID {
            self.handoffAuthorizationIDs.remove(authorizationID)
        }
        return authorizationID
    }

    func attachAuthorization(requestID: UUID, authorizationID: UUID) throws {
        guard authorizationID != Self.zeroID,
              var grant = self.grants[requestID],
              case .reserved = grant.state,
              grant.handoffAuthorizationID == nil,
              self.handoffAuthorizationIDs.insert(authorizationID).inserted
        else {
            throw Self.invalidRequest("Browser handoff authorization could not be attached to its reservation")
        }
        grant.handoffAuthorizationID = authorizationID
        self.grants[requestID] = grant
    }

    func finalize(
        requestID: UUID,
        receiptBundle: PeekabooBridgeOperationReceiptBundle,
        connectionReceipt: PeekabooBridgeBrowserConnectionReceipt) throws
    {
        guard var grant = self.grants[requestID],
              case .reserved = grant.state,
              grant.handoffAuthorizationID != nil
        else {
            throw Self.invalidRequest("Browser handoff grant was not reserved by this request")
        }
        guard connectionReceipt.isCanonicalExecutionTarget else {
            throw Self.invalidRequest("Browser handoff target receipt is not canonical")
        }
        let bundleSHA256 = try PeekabooBridgeOperationReceiptCoding.sha256(receiptBundle)
        let targetSHA256 = try PeekabooBridgeOperationReceiptCoding.sha256(connectionReceipt)
        grant.receiptBundleSHA256 = bundleSHA256
        grant.connectionReceipt = connectionReceipt
        grant.targetReceiptSHA256 = targetSHA256
        grant.expiresAtUnixMilliseconds = Self.addingClamped(
            receiptBundle.receipt.payload.completedAtUnixMilliseconds,
            self.lifetimeMilliseconds)
        grant.state = .pending
        self.grants[requestID] = grant
    }

    func bootstrap(
        request: PeekabooBridgeBrowserSessionBootstrapRequest,
        authority: PeekabooBridgeOperationReceiptAuthority,
        caller: PeekabooBridgeBrowserSessionCaller) async throws
        -> PeekabooBridgeBrowserSessionBootstrapResponse
    {
        try Task.checkCancellation()
        await self.pruneExpired()
        try Task.checkCancellation()
        let resolvedGrant = try self.resolveGrant(request: request, authority: authority, caller: caller)
        let grantID = resolvedGrant.id
        var grant = resolvedGrant.grant

        let task: Task<PeekabooBridgeBrowserSessionBootstrapResponse, any Error>
        let claim: Claim
        switch grant.state {
        case .reserved:
            throw Self.invalidRequest("Browser handoff grant has not reached a signed successful result")
        case .pending:
            guard self.now() <= grant.expiresAtUnixMilliseconds else {
                self.grants.removeValue(forKey: grantID)
                throw Self.invalidRequest("Browser handoff grant expired before its first claim")
            }
            guard let provider, provider.supportsBrowserSessionBootstrap else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "This Bridge host has no browser session bootstrap provider")
            }
            claim = Claim(claimID: request.claimID, caller: caller, sessionID: UUID())
            let response = PeekabooBridgeBrowserSessionBootstrapResponse(
                sessionID: claim.sessionID,
                claimID: claim.claimID,
                targetReceiptSHA256: grant.targetReceiptSHA256)
            let context = PeekabooBridgeBrowserSessionBootstrapContext(
                sessionID: claim.sessionID,
                claimID: claim.claimID,
                caller: caller,
                connectionReceipt: grant.connectionReceipt,
                handoffAuthorizationID: grant.handoffAuthorizationID)
            task = self.makeBootstrapTask(context: context, response: response, provider: provider)
            grant.state = .inFlight(claim, task)
            self.grants[grantID] = grant
        case let .inFlight(existingClaim, existingTask):
            guard existingClaim.claimID == request.claimID, existingClaim.caller == caller else {
                throw Self.invalidRequest("Browser handoff grant was claimed by another caller")
            }
            claim = existingClaim
            task = existingTask
        case let .succeeded(existingClaim, response):
            guard existingClaim.claimID == request.claimID, existingClaim.caller == caller else {
                throw Self.invalidRequest("Browser handoff grant was already consumed")
            }
            return response
        case let .ending(existingClaim, _, _, _):
            guard existingClaim.caller == caller else { throw Self.wrongOwner() }
            throw Self.sessionError(
                code: .invalidRequest,
                context: PeekabooBridgeBrowserSessionErrorContext.ended,
                message: "Browser session is ending")
        }

        do {
            let response = try await task.value
            if var current = self.grants[grantID],
               case let .inFlight(currentClaim, _) = current.state,
               currentClaim == claim
            {
                current.expiresAtUnixMilliseconds = Self.addingClamped(
                    self.now(),
                    self.lifetimeMilliseconds)
                current.state = .succeeded(claim, response)
                self.grants[grantID] = current
                self.sessionGrantIDs[response.sessionID] = grantID
                if let authorizationID = current.handoffAuthorizationID {
                    self.handoffAuthorizationIDs.remove(authorizationID)
                }
            }
            return response
        } catch {
            if case let .inFlight(currentClaim, _)? = self.grants[grantID]?.state,
               currentClaim == claim
            {
                if let authorizationID = self.grants[grantID]?.handoffAuthorizationID {
                    self.handoffAuthorizationIDs.remove(authorizationID)
                }
                self.grants.removeValue(forKey: grantID)
            }
            throw error
        }
    }

    private func resolveGrant(
        request: PeekabooBridgeBrowserSessionBootstrapRequest,
        authority: PeekabooBridgeOperationReceiptAuthority,
        caller: PeekabooBridgeBrowserSessionCaller) throws -> (id: UUID, grant: Grant)
    {
        guard let receiptBundle = request.receiptBundle else {
            return try self.resolveEmptyGrant(claimID: request.claimID, caller: caller)
        }
        guard receiptBundle.operationAttestation == authority.attestation else {
            throw PeekabooBridgeErrorEnvelope(
                code: .versionMismatch,
                message: "Browser handoff grant belongs to another Bridge listener generation",
                context: PeekabooBridgeBrowserSessionErrorContext.hostGenerationChanged)
        }
        do {
            try receiptBundle.validate(trustAnchor: .listenerAttestation(authority.attestation))
        } catch {
            throw Self.sessionError(
                code: .invalidRequest,
                context: PeekabooBridgeBrowserSessionErrorContext.invalid,
                message: "Browser handoff receipt bundle is invalid")
        }
        let evidence = try Self.validatedEvidence(receiptBundle)
        guard let pending = self.grants[evidence.requestID] else {
            throw Self.invalidRequest("Browser handoff grant is missing, expired, or already consumed")
        }
        let suppliedBundleSHA256 = try PeekabooBridgeOperationReceiptCoding.sha256(receiptBundle)
        let suppliedTargetSHA256 = try PeekabooBridgeOperationReceiptCoding.sha256(evidence.connectionReceipt)
        guard evidence.completedAtUnixMilliseconds <= self.now(),
              pending.receiptBundleSHA256 == suppliedBundleSHA256,
              pending.connectionReceipt == evidence.connectionReceipt,
              pending.targetReceiptSHA256 == suppliedTargetSHA256,
              pending.issuer.operationClientInstanceID == receiptBundle.receipt.payload.clientInstanceID,
              pending.issuer.process == receiptBundle.receipt.payload.client,
              Self.mayTransfer(from: pending.issuer, to: caller)
        else {
            throw Self.invalidRequest("Browser handoff evidence does not match the pending authenticated grant")
        }
        return (evidence.requestID, pending)
    }

    private func resolveEmptyGrant(
        claimID: UUID,
        caller: PeekabooBridgeBrowserSessionCaller) throws -> (id: UUID, grant: Grant)
    {
        if let ended = self.endedClaims[claimID] {
            guard ended.caller == caller else { throw Self.wrongOwner() }
            throw Self.sessionEnded("Browser session claim has already ended")
        }
        if let existing = self.grants[claimID] {
            guard existing.issuer == caller,
                  existing.receiptBundleSHA256 == nil,
                  existing.connectionReceipt == nil,
                  existing.targetReceiptSHA256 == nil
            else {
                throw Self.invalidRequest("Empty browser session claim belongs to another authenticated caller")
            }
            return (claimID, existing)
        }
        guard self.grants.count + self.pendingCleanupSessionIDs.count < self.capacity else {
            throw PeekabooBridgeErrorEnvelope(
                code: .serverBusy,
                message: "The bounded browser session registry is full")
        }
        let now = self.now()
        let grant = Grant(
            issuer: caller,
            expiresAtUnixMilliseconds: Self.addingClamped(now, self.lifetimeMilliseconds),
            receiptBundleSHA256: nil,
            connectionReceipt: nil,
            targetReceiptSHA256: nil,
            handoffAuthorizationID: nil,
            state: .pending)
        self.grants[claimID] = grant
        return (claimID, grant)
    }

    private func makeBootstrapTask(
        context: PeekabooBridgeBrowserSessionBootstrapContext,
        response: PeekabooBridgeBrowserSessionBootstrapResponse,
        provider: any PeekabooBridgeBrowserSessionBootstrapProviding)
        -> Task<PeekabooBridgeBrowserSessionBootstrapResponse, any Error>
    {
        let waiter = BootstrapWaiter()
        let providerTask = Task { @MainActor in
            do {
                try await provider.bootstrapBrowserSession(context)
                guard !waiter.finish(.success(response)) else { return }
            } catch {
                self.pendingCleanupSessionIDs.insert(context.sessionID)
                await self.cleanupFailedBootstrap(context: context, provider: provider)
                waiter.finish(.failure(error))
                return
            }
            await self.cleanupFailedBootstrap(context: context, provider: provider)
        }
        let timeoutTask = Task { @MainActor [lifetimeMilliseconds] in
            do {
                try await Task.sleep(for: .milliseconds(lifetimeMilliseconds))
            } catch {
                return
            }
            let timeout = PeekabooBridgeErrorEnvelope(
                code: .timeout,
                message: "Browser session bootstrap timed out")
            guard waiter.finish(.failure(timeout)) else { return }
            self.pendingCleanupSessionIDs.insert(context.sessionID)
            providerTask.cancel()
            await self.cleanupFailedBootstrap(context: context, provider: provider)
        }
        return Task { @MainActor in
            let result = await waiter.value()
            timeoutTask.cancel()
            if case .failure = result {
                providerTask.cancel()
            }
            return try result.get()
        }
    }

    private func cleanupFailedBootstrap(
        context: PeekabooBridgeBrowserSessionBootstrapContext,
        provider: any PeekabooBridgeBrowserSessionBootstrapProviding) async
    {
        if await provider.invalidateBrowserSession(context.sessionID) {
            self.pendingCleanupSessionIDs.remove(context.sessionID)
        } else {
            self.pendingCleanupSessionIDs.insert(context.sessionID)
        }
        if let authorizationID = context.handoffAuthorizationID {
            await provider.discardBrowserConnectionHandoffAuthorization(authorizationID)
        }
    }

    @discardableResult
    func authorizeSession(
        _ sessionID: UUID,
        caller: PeekabooBridgeBrowserSessionCaller) async throws -> SessionOperationLease
    {
        try Task.checkCancellation()
        await self.pruneExpired()
        try Task.checkCancellation()
        if let ended = self.endedSessions[sessionID] {
            guard ended.caller == caller else { throw Self.wrongOwner() }
            throw Self.sessionError(
                code: .invalidRequest,
                context: PeekabooBridgeBrowserSessionErrorContext.ended,
                message: "Browser session has ended")
        }
        guard let grantID = self.sessionGrantIDs[sessionID],
              let grant = self.grants[grantID]
        else {
            throw Self.sessionError(
                code: .invalidRequest,
                context: PeekabooBridgeBrowserSessionErrorContext.invalid,
                message: "Browser session is unknown or invalid")
        }
        switch grant.state {
        case let .succeeded(claim, response):
            guard response.sessionID == sessionID else { throw Self.invalidSession() }
            guard claim.caller == caller else { throw Self.wrongOwner() }
            let lease = SessionOperationLease(sessionID: sessionID, token: UUID())
            self.activeOperationTokens[sessionID, default: []].insert(lease.token)
            return lease
        case let .ending(claim, response, _, _):
            guard response.sessionID == sessionID else { throw Self.invalidSession() }
            guard claim.caller == caller else { throw Self.wrongOwner() }
            throw Self.sessionEnded("Browser session is ending")
        case .reserved, .pending, .inFlight:
            throw Self.invalidSession()
        }
    }

    func completeSessionOperation(_ lease: SessionOperationLease) {
        guard var tokens = self.activeOperationTokens[lease.sessionID],
              tokens.remove(lease.token) != nil
        else { return }
        guard tokens.isEmpty else {
            self.activeOperationTokens[lease.sessionID] = tokens
            return
        }
        self.activeOperationTokens.removeValue(forKey: lease.sessionID)
        let waiters = self.operationDrainWaiters.removeValue(forKey: lease.sessionID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForSessionOperationsToDrain(_ sessionID: UUID) async {
        guard self.activeOperationTokens[sessionID]?.isEmpty == false else { return }
        await withCheckedContinuation { continuation in
            self.operationDrainWaiters[sessionID, default: []].append(continuation)
        }
    }

    func endSession(_ sessionID: UUID, caller: PeekabooBridgeBrowserSessionCaller) async throws {
        await self.pruneExpired()
        if let ended = self.endedSessions[sessionID] {
            guard ended.caller == caller else { throw Self.wrongOwner() }
            return
        }
        guard let grantID = self.sessionGrantIDs[sessionID],
              var grant = self.grants[grantID]
        else { throw Self.invalidSession() }

        let claim: Claim
        let response: PeekabooBridgeBrowserSessionBootstrapResponse
        let attemptID: UUID
        let task: Task<Bool, Never>
        switch grant.state {
        case let .succeeded(activeClaim, activeResponse):
            guard activeResponse.sessionID == sessionID else { throw Self.invalidSession() }
            guard activeClaim.caller == caller else { throw Self.wrongOwner() }
            guard let provider else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "This Bridge host has no scoped browser session provider")
            }
            claim = activeClaim
            response = activeResponse
            attemptID = UUID()
            task = Task { @MainActor in
                await self.waitForSessionOperationsToDrain(sessionID)
                return await provider.invalidateBrowserSession(sessionID)
            }
            grant.state = .ending(claim, response, attemptID, task)
            self.grants[grantID] = grant
        case let .ending(activeClaim, activeResponse, activeAttemptID, existingTask):
            guard activeResponse.sessionID == sessionID else { throw Self.invalidSession() }
            guard activeClaim.caller == caller else { throw Self.wrongOwner() }
            claim = activeClaim
            response = activeResponse
            attemptID = activeAttemptID
            task = existingTask
        case .reserved, .pending, .inFlight:
            throw Self.invalidSession()
        }

        let removed = await task.value
        if !removed {
            if case let .ending(currentClaim, currentResponse, currentAttemptID, _)? =
                self.grants[grantID]?.state,
                currentClaim == claim,
                currentResponse == response,
                currentAttemptID == attemptID
            {
                grant.state = .succeeded(claim, response)
                self.grants[grantID] = grant
            }
            throw PeekabooBridgeErrorEnvelope(
                code: .serverBusy,
                message: "Browser session cleanup is not yet confirmed")
        }
        guard case let .ending(currentClaim, currentResponse, currentAttemptID, _)? = self.grants[grantID]?.state,
              currentClaim == claim,
              currentResponse == response,
              currentAttemptID == attemptID
        else { return }
        self.sessionGrantIDs.removeValue(forKey: sessionID)
        self.grants.removeValue(forKey: grantID)
        let expiresAt = Self.addingClamped(self.now(), self.lifetimeMilliseconds)
        self.endedSessions[sessionID] = EndedSession(caller: caller, expiresAtUnixMilliseconds: expiresAt)
        self.endedClaims[claim.claimID] = EndedClaim(caller: caller, expiresAtUnixMilliseconds: expiresAt)
        self.trimEndedTombstones()
    }

    private func trimEndedTombstones() {
        while self.endedSessions.count > self.capacity,
              let oldest = self.endedSessions.min(by: {
                  $0.value.expiresAtUnixMilliseconds < $1.value.expiresAtUnixMilliseconds
              })?.key
        {
            self.endedSessions.removeValue(forKey: oldest)
        }
        while self.endedClaims.count > self.capacity,
              let oldest = self.endedClaims.min(by: {
                  $0.value.expiresAtUnixMilliseconds < $1.value.expiresAtUnixMilliseconds
              })?.key
        {
            self.endedClaims.removeValue(forKey: oldest)
        }
    }

    private func pruneExpired() async {
        let now = self.now()
        self.endedSessions = self.endedSessions.filter { $0.value.expiresAtUnixMilliseconds >= now }
        self.endedClaims = self.endedClaims.filter { $0.value.expiresAtUnixMilliseconds >= now }
        guard let provider else { return }

        for sessionID in Array(self.pendingCleanupSessionIDs) {
            guard await provider.invalidateBrowserSession(sessionID) else { continue }
            self.pendingCleanupSessionIDs.remove(sessionID)
        }

        var expiredAuthorizations: [UUID] = []
        var orphanedSessions: [(grantID: UUID, claim: Claim, response: PeekabooBridgeBrowserSessionBootstrapResponse)] =
            []
        for (grantID, grant) in self.grants.map({ ($0.key, $0.value) }) {
            switch grant.state {
            case .inFlight, .ending:
                continue
            case let .succeeded(claim, response):
                if self.ownerIsGone(claim.caller),
                   self.activeOperationTokens[response.sessionID]?.isEmpty != false
                {
                    orphanedSessions.append((grantID, claim, response))
                }
            case .reserved, .pending:
                guard grant.expiresAtUnixMilliseconds < now else { continue }
                if let authorizationID = grant.handoffAuthorizationID {
                    expiredAuthorizations.append(authorizationID)
                }
                self.grants.removeValue(forKey: grantID)
            }
        }
        self.handoffAuthorizationIDs.subtract(expiredAuthorizations)
        for authorizationID in expiredAuthorizations {
            await provider.discardBrowserConnectionHandoffAuthorization(authorizationID)
        }
        for orphaned in orphanedSessions {
            guard await provider.invalidateBrowserSession(orphaned.response.sessionID),
                  case let .succeeded(currentClaim, currentResponse)? = self.grants[orphaned.grantID]?.state,
                  currentClaim == orphaned.claim,
                  currentResponse == orphaned.response
            else { continue }
            self.sessionGrantIDs.removeValue(forKey: orphaned.response.sessionID)
            self.grants.removeValue(forKey: orphaned.grantID)
        }
    }

    private func ownerIsGone(_ caller: PeekabooBridgeBrowserSessionCaller) -> Bool {
        let processIdentifier = caller.process.processIdentifier
        if let currentStartIdentity = self.processStartIdentity(processIdentifier),
           currentStartIdentity != caller.process.processStartIdentity
        {
            return true
        }
        return self.processPresence(processIdentifier) == false
    }

    private static func validatedEvidence(
        _ bundle: PeekabooBridgeOperationReceiptBundle) throws
        -> (
            requestID: UUID,
            completedAtUnixMilliseconds: Int64,
            connectionReceipt: PeekabooBridgeBrowserConnectionReceipt)
    {
        let decoder = JSONDecoder.peekabooBridgeDecoder()
        let request = try decoder.decode(PeekabooBridgeRequest.self, from: bundle.canonicalRequest)
        let response = try decoder.decode(PeekabooBridgeResponse.self, from: bundle.canonicalResponse)
        guard case let .browserConnect(connectRequest) = request.unwrappedOperationRequest,
              connectRequest.requestsHandoff,
              let status = Self.browserStatus(in: response),
              status.isConnected,
              let connectionReceipt = status.connectionReceipt,
              connectionReceipt.isCanonicalExecutionTarget,
              connectionReceipt.matchesConnectRequest(connectRequest),
              bundle.receipt.payload.target == Self.operationTarget(connectionReceipt),
              let outcome = bundle.receipt.payload.outcome?.outcome,
              outcome.isAccepted(by: .confirmedNoChangeOrDispatched(
                  requiring: .init(mechanism: .browserProtocol, mode: .foreground),
                  unitCount: .exact(.one)))
        else {
            throw Self.invalidRequest("Receipt bundle is not an exact successful handoff-enabled browser connect")
        }
        return (
            bundle.receipt.payload.requestID,
            bundle.receipt.payload.completedAtUnixMilliseconds,
            connectionReceipt)
    }

    private static func browserStatus(in response: PeekabooBridgeResponse) -> PeekabooBridgeBrowserStatus? {
        switch response {
        case let .browserStatus(status):
            status
        case let .projectedAction(projected):
            self.browserStatus(in: projected.response)
        default:
            nil
        }
    }

    private static func operationTarget(
        _ receipt: PeekabooBridgeBrowserConnectionReceipt) -> PeekabooBridgeOperationTargetReceipt
    {
        if receipt.isCanonicalExternalTarget {
            return .browser(receipt)
        }
        guard let processIdentity = receipt.localProcessIdentity else {
            preconditionFailure("A canonical process-bound browser receipt must carry its process identity")
        }
        return .process(processIdentity)
    }

    private static func mayTransfer(
        from issuer: PeekabooBridgeBrowserSessionCaller,
        to caller: PeekabooBridgeBrowserSessionCaller) -> Bool
    {
        issuer.effectiveUserIdentifier == caller.effectiveUserIdentifier &&
            issuer.effectiveUserIdentifier == geteuid() &&
            issuer.bundleIdentifier == caller.bundleIdentifier &&
            issuer.bundleIdentifier == PeekabooBridgeConstants.cliBundleIdentifier &&
            issuer.teamIdentifier == caller.teamIdentifier &&
            PeekabooBridgeConstants.trustedReleaseTeamIDs.contains(caller.teamIdentifier) &&
            issuer.process.codeSignatureHash == caller.process.codeSignatureHash
    }

    private static func addingClamped(_ value: Int64, _ delta: Int64) -> Int64 {
        let (result, overflow) = value.addingReportingOverflow(delta)
        return overflow ? Int64.max : result
    }

    private static let zeroID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    private static func invalidRequest(_ message: String) -> PeekabooBridgeErrorEnvelope {
        self.sessionError(
            code: .invalidRequest,
            context: PeekabooBridgeBrowserSessionErrorContext.invalid,
            message: message)
    }

    private static func wrongOwner() -> PeekabooBridgeErrorEnvelope {
        self.sessionError(
            code: .unauthorizedClient,
            context: PeekabooBridgeBrowserSessionErrorContext.wrongOwner,
            message: "Browser session belongs to another authenticated caller")
    }

    private static func invalidSession() -> PeekabooBridgeErrorEnvelope {
        self.sessionError(
            code: .invalidRequest,
            context: PeekabooBridgeBrowserSessionErrorContext.invalid,
            message: "Browser session is unknown or invalid")
    }

    private static func sessionEnded(_ message: String) -> PeekabooBridgeErrorEnvelope {
        self.sessionError(
            code: .invalidRequest,
            context: PeekabooBridgeBrowserSessionErrorContext.ended,
            message: message)
    }

    private static func sessionError(
        code: PeekabooBridgeErrorCode,
        context: String,
        message: String) -> PeekabooBridgeErrorEnvelope
    {
        PeekabooBridgeErrorEnvelope(code: code, message: message, context: context)
    }
}

extension PeekabooBridgePeer {
    func browserSessionCaller(clientInstanceID: UUID) throws -> PeekabooBridgeBrowserSessionCaller {
        guard let liveIdentity = self.liveIdentity,
              self.processIdentifier > 0,
              self.processIdentifier == liveIdentity.processIdentifier,
              self.auditTokenProcessIdentifierVersion == liveIdentity.processIdentifierVersion,
              self.processStartIdentity == liveIdentity.processStartIdentity,
              self.userIdentifier == liveIdentity.effectiveUserIdentifier,
              self.userIdentifier == geteuid(),
              let codeSignatureHash = self.codeSignatureHash,
              !codeSignatureHash.isEmpty,
              codeSignatureHash == liveIdentity.codeSignatureHash,
              self.bundleIdentifier == PeekabooBridgeConstants.cliBundleIdentifier,
              let bundleIdentifier = self.bundleIdentifier,
              let teamIdentifier = self.teamIdentifier,
              PeekabooBridgeConstants.trustedReleaseTeamIDs.contains(teamIdentifier)
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .unauthorizedClient,
                message: "Browser handoff requires an authenticated release-signed Peekaboo CLI")
        }
        return PeekabooBridgeBrowserSessionCaller(
            operationClientInstanceID: clientInstanceID,
            process: .init(
                processIdentifier: liveIdentity.processIdentifier,
                processStartIdentity: liveIdentity.processStartIdentity,
                codeSignatureHash: codeSignatureHash),
            processIdentifierVersion: liveIdentity.processIdentifierVersion,
            effectiveUserIdentifier: liveIdentity.effectiveUserIdentifier,
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier)
    }

    func isApprovedBrowserHandoffCaller() -> Bool {
        (try? self.browserSessionCaller(clientInstanceID: UUID())) != nil
    }
}

extension PeekabooBridgeServer {
    static func validateBrowserSessionRequest(_ request: PeekabooBridgeRequest) throws {
        switch request.unwrappedOperationRequest {
        case let .browserStatus(payload):
            guard let sessionID = payload.sessionID,
                  sessionID != Self.zeroBrowserSessionID,
                  payload.browserURL == nil,
                  !payload.requestsHandoff
            else { throw self.invalidBrowserSessionRequest() }
        case let .browserConnect(payload):
            if let sessionID = payload.sessionID {
                guard sessionID != Self.zeroBrowserSessionID, !payload.requestsHandoff else {
                    throw self.invalidBrowserSessionRequest()
                }
            } else if !payload.requestsHandoff {
                throw self.invalidBrowserSessionRequest()
            }
        case let .browserExecute(payload):
            if let sessionID = payload.sessionID {
                guard sessionID != Self.zeroBrowserSessionID,
                      let receipt = payload.expectedConnectionReceipt,
                      receipt.isCanonicalExecutionTarget,
                      let epoch = payload.expectedProviderSessionEpoch,
                      epoch != Self.zeroBrowserSessionID,
                      payload.connectionPolicy == .requireExistingLiveReceipt,
                      payload.elementPreflight?.isCanonical != false
                else { throw self.invalidBrowserSessionRequest() }
            } else {
                guard payload.expectedProviderSessionEpoch == nil,
                      payload.elementPreflight == nil
                else { throw self.invalidBrowserSessionRequest() }
            }
        case let .browserSessionBootstrap(payload):
            guard payload.claimID != Self.zeroBrowserSessionID else {
                throw self.invalidBrowserSessionRequest()
            }
        case let .browserSessionControl(payload):
            guard payload.sessionID != Self.zeroBrowserSessionID else {
                throw self.invalidBrowserSessionRequest()
            }
        default:
            throw self.invalidBrowserSessionRequest()
        }
    }

    private static let zeroBrowserSessionID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    private static func invalidBrowserSessionRequest() -> PeekabooBridgeErrorEnvelope {
        PeekabooBridgeErrorEnvelope(
            code: .invalidRequest,
            message: "Scoped browser request is incomplete or mixes root and session authority",
            context: PeekabooBridgeBrowserSessionErrorContext.invalid)
    }
}
