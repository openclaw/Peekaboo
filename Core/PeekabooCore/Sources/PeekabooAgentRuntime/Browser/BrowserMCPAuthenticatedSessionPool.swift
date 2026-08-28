import Foundation
import PeekabooFoundation

/// Version-neutral local owner for independently authenticated browser sessions.
///
/// Each entry owns one Chrome DevTools MCP child, connection receipt, upload workspace, target lock,
/// and FIFO execution gate. A blocked call therefore orders only its own session; another explicitly
/// authenticated session can continue through its separate manager and provider connection.
@MainActor
final class BrowserMCPAuthenticatedSessionPool {
    static let sessionCapacity = 128

    private enum TargetKey: Hashable {
        case process(processIdentifier: Int32, processStartIdentity: UInt64)
        case browserURL(String)
        case devToolsBrowser(String)
        case receipt(BrowserMCPConnectionReceipt)
    }

    private enum TargetOwner: Equatable {
        case root
        case session(SessionID)
    }

    private enum HandoffPhase {
        case pending
        case retryable
        case connected
        case recoveryRequired
    }

    private struct HandoffState {
        let authorization: BrowserMCPConnectionHandoffAuthorization
        let target: BrowserMCPAuthorizedHandoffTarget
        var phase: HandoffPhase
    }

    private struct PendingHandoffClaim {
        let authorization: BrowserMCPConnectionHandoffAuthorization
        var sourceRecoveryRequired = false
    }

    private struct SessionState {
        let manager: BrowserMCPSessionManager
        var capabilities: BrowserToolCapabilitySession
        var mutationGate: MCPToolSnapshotExecutionGate
        let handoffLifecycleGate: MCPToolSnapshotExecutionGate
    }

    struct SessionID: Hashable, Sendable {
        fileprivate let rawValue: UUID

        init() {
            self.rawValue = UUID()
        }
    }

    enum HandoffPreparation {
        case start
        case bootstrap(BrowserMCPAuthorizedHandoffTarget)
        case connected(BrowserMCPAuthorizedHandoffTarget)
    }

    enum HandoffResolution {
        case retryable
        case connected
        case recoveryRequired
    }

    typealias Factory = @MainActor (String) -> BrowserMCPSessionManager

    private let serverNamePrefix: String
    private let factory: Factory
    private var sessions: [SessionID: SessionState] = [:]
    private var endedSessions = Set<SessionID>()
    private var endingSessions: [SessionID: Task<Bool, Never>] = [:]
    private var pendingCleanupSessions = Set<SessionID>()
    private var namedSessions: [String: SessionID] = [:]
    private var targetOwners: [TargetKey: TargetOwner] = [:]
    private var pendingHandoffOwners: [TargetKey: SessionID] = [:]
    private var deferredRootReleaseKeys = Set<TargetKey>()
    private var pendingHandoffClaims: [SessionID: PendingHandoffClaim] = [:]
    private var handoffs: [SessionID: HandoffState] = [:]

    nonisolated init(
        serverNamePrefix: String = "chrome-devtools-session",
        factory: @escaping Factory)
    {
        self.serverNamePrefix = serverNamePrefix
        self.factory = factory
    }

    func manager(for sessionID: SessionID) -> BrowserMCPSessionManager? {
        guard !self.endedSessions.contains(sessionID), self.endingSessions[sessionID] == nil else { return nil }
        if let state = self.sessions[sessionID] {
            return state.manager
        }
        guard self.sessions.count < Self.sessionCapacity else { return nil }
        let name = "\(self.serverNamePrefix)-\(sessionID.rawValue.uuidString.lowercased())"
        let manager = self.factory(name)
        self.sessions[sessionID] = SessionState(
            manager: manager,
            capabilities: BrowserToolCapabilitySession(),
            mutationGate: MCPToolSnapshotExecutionGate(),
            handoffLifecycleGate: MCPToolSnapshotExecutionGate())
        return manager
    }

    func existingSessionID(named name: String) -> SessionID? {
        self.namedSessions[name]
    }

    func existingManager(for sessionID: SessionID) -> BrowserMCPSessionManager? {
        guard !self.endedSessions.contains(sessionID), self.endingSessions[sessionID] == nil else { return nil }
        return self.sessions[sessionID]?.manager
    }

    func capabilities(for sessionID: SessionID) -> BrowserToolCapabilitySession? {
        guard !self.endedSessions.contains(sessionID), self.endingSessions[sessionID] == nil else { return nil }
        return self.sessions[sessionID]?.capabilities
    }

    func mutationGate(for sessionID: SessionID) -> MCPToolSnapshotExecutionGate? {
        guard !self.endedSessions.contains(sessionID), self.endingSessions[sessionID] == nil else { return nil }
        return self.sessions[sessionID]?.mutationGate
    }

    func withHandoffLifecycle<T>(
        _ sessionID: SessionID,
        operation: @MainActor () async throws -> T) async throws -> T
    {
        guard let state = self.sessions[sessionID],
              !self.endedSessions.contains(sessionID),
              self.endingSessions[sessionID] == nil
        else { throw BrowserMCPConnectionError.sessionEnded }
        let gate = state.handoffLifecycleGate
        try await gate.acquire()
        guard self.sessions[sessionID]?.handoffLifecycleGate === gate,
              !self.endedSessions.contains(sessionID),
              self.endingSessions[sessionID] == nil
        else {
            await gate.release()
            throw BrowserMCPConnectionError.sessionEnded
        }
        do {
            let result = try await operation()
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    func sessionID(named name: String) -> SessionID? {
        guard !name.isEmpty else { return nil }
        if let sessionID = self.namedSessions[name] {
            return sessionID
        }
        guard self.sessions.count < Self.sessionCapacity else { return nil }
        let sessionID = SessionID()
        self.namedSessions[name] = sessionID
        return sessionID
    }

    func end(_ sessionID: SessionID) async {
        _ = await self.endAndConfirm(sessionID)
    }

    func endAndConfirm(_ sessionID: SessionID) async -> Bool {
        if let ending = self.endingSessions[sessionID] {
            return await ending.value
        }
        guard let initialState = self.sessions[sessionID] else {
            self.endedSessions.insert(sessionID)
            let sourceRecoveryRequired = self.pendingHandoffClaims[sessionID]?.sourceRecoveryRequired == true
            if !sourceRecoveryRequired {
                self.cancelPendingHandoff(for: sessionID)
                self.pendingCleanupSessions.remove(sessionID)
                self.namedSessions = self.namedSessions.filter { $0.value != sessionID }
                self.releaseOwnership(for: sessionID)
                self.handoffs.removeValue(forKey: sessionID)
            } else {
                self.pendingCleanupSessions.insert(sessionID)
            }
            return !sourceRecoveryRequired
        }
        let handoffLifecycleGate = initialState.handoffLifecycleGate
        let ending = Task { @MainActor in
            do {
                try await handoffLifecycleGate.acquire()
            } catch {
                self.pendingCleanupSessions.insert(sessionID)
                self.endingSessions.removeValue(forKey: sessionID)
                return false
            }
            guard let state = self.sessions[sessionID],
                  state.handoffLifecycleGate === handoffLifecycleGate
            else {
                self.pendingCleanupSessions.insert(sessionID)
                self.endingSessions.removeValue(forKey: sessionID)
                await handoffLifecycleGate.release()
                return false
            }
            self.endedSessions.insert(sessionID)
            let sourceRecoveryRequired = self.pendingHandoffClaims[sessionID]?.sourceRecoveryRequired == true
            if !sourceRecoveryRequired {
                self.cancelPendingHandoff(for: sessionID)
            }
            do {
                try await state.mutationGate.acquire()
            } catch {
                let recoveryRequired = self.pendingHandoffClaims[sessionID]?.sourceRecoveryRequired == true
                self.finishEnd(
                    sessionID,
                    cleanupConfirmed: false,
                    sourceRecoveryRequired: recoveryRequired)
                await handoffLifecycleGate.release()
                return false
            }
            // Capability end drains its operation gate, which covers reads through response projection; the mutation
            // gate separately keeps outer snapshot completion and teardown ordered.
            await state.capabilities.end()
            let cleanupConfirmed = await state.manager.endSession()
            await state.mutationGate.release()
            let recoveryRequired = self.pendingHandoffClaims[sessionID]?.sourceRecoveryRequired == true
            let fullyRecovered = cleanupConfirmed && !recoveryRequired
            self.finishEnd(
                sessionID,
                cleanupConfirmed: fullyRecovered,
                sourceRecoveryRequired: recoveryRequired)
            await handoffLifecycleGate.release()
            return fullyRecovered
        }
        self.endingSessions[sessionID] = ending
        return await ending.value
    }

    private func finishEnd(
        _ sessionID: SessionID,
        cleanupConfirmed: Bool,
        sourceRecoveryRequired: Bool)
    {
        if cleanupConfirmed, !sourceRecoveryRequired {
            self.pendingCleanupSessions.remove(sessionID)
            self.namedSessions = self.namedSessions.filter { $0.value != sessionID }
            self.sessions.removeValue(forKey: sessionID)
            self.releaseOwnership(for: sessionID)
            self.handoffs.removeValue(forKey: sessionID)
        } else if var handoff = self.handoffs[sessionID] {
            handoff.phase = .recoveryRequired
            self.handoffs[sessionID] = handoff
        }
        if !cleanupConfirmed {
            self.pendingCleanupSessions.insert(sessionID)
        }
        self.endingSessions.removeValue(forKey: sessionID)
    }

    func retryPendingCleanup() async -> Bool {
        let cleanupSessions = self.pendingCleanupSessions.union(self.endingSessions.keys)
        for sessionID in cleanupSessions {
            _ = await self.endAndConfirm(sessionID)
        }
        return self.pendingCleanupSessions.isEmpty && self.endingSessions.isEmpty
    }

    var pendingCleanupNames: [String] {
        self.namedSessions.compactMap { name, sessionID in
            self.pendingCleanupSessions.contains(sessionID) ? name : nil
        }.sorted()
    }

    var pendingCleanupCount: Int {
        self.pendingCleanupSessions.count
    }

    func bind(_ sessionID: SessionID, to receipt: BrowserMCPConnectionReceipt) throws {
        guard !self.endedSessions.contains(sessionID), self.sessions[sessionID] != nil else {
            throw BrowserMCPConnectionError.sessionEnded
        }
        guard !self.pendingHandoffOwners.values.contains(sessionID) else {
            throw BrowserMCPConnectionError.targetLocked
        }
        guard self.handoffs[sessionID] == nil else {
            throw BrowserMCPConnectionError.targetLocked
        }
        let keys = Self.targetKeys(for: receipt)
        if keys.contains(where: { key in
            self.targetOwners[key].map { $0 != .session(sessionID) } ?? false
        }) {
            throw BrowserMCPConnectionError.targetLocked
        }
        self.targetOwners = self.targetOwners.filter { $0.value != .session(sessionID) }
        for key in keys {
            self.targetOwners[key] = .session(sessionID)
        }
    }

    func unbind(_ sessionID: SessionID) {
        guard self.endingSessions[sessionID] == nil else { return }
        if let handoff = self.handoffs[sessionID] {
            guard case .connected = handoff.phase else { return }
        }
        self.targetOwners = self.targetOwners.filter { $0.value != .session(sessionID) }
    }

    func bindRoot(to receipt: BrowserMCPConnectionReceipt) throws {
        let keys = Self.targetKeys(for: receipt)
        if !self.pendingHandoffOwners.isEmpty || keys.contains(where: { key in
            self.targetOwners[key].map { $0 != .root } ?? false
        }) {
            throw BrowserMCPConnectionError.targetLocked
        }
        self.targetOwners = self.targetOwners.filter { $0.value != .root }
        for key in keys {
            self.targetOwners[key] = .root
        }
    }

    func unbindRoot() {
        let pendingRootKeys = self.targetOwners.compactMap { key, owner in
            owner == .root && self.pendingHandoffOwners[key] != nil ? key : nil
        }
        self.deferredRootReleaseKeys.formUnion(pendingRootKeys)
        self.targetOwners = self.targetOwners.filter { key, owner in
            owner != .root || self.pendingHandoffOwners[key] != nil
        }
    }

    func prepareHandoff(
        _ sessionID: SessionID,
        authorization: BrowserMCPConnectionHandoffAuthorization) throws -> HandoffPreparation
    {
        guard !self.endedSessions.contains(sessionID), self.sessions[sessionID] != nil else {
            throw BrowserMCPConnectionError.sessionEnded
        }
        if var handoff = self.handoffs[sessionID] {
            guard handoff.authorization == authorization else { throw BrowserMCPConnectionError.targetLocked }
            switch handoff.phase {
            case .retryable:
                handoff.phase = .pending
                self.handoffs[sessionID] = handoff
                return .bootstrap(handoff.target)
            case .connected:
                return .connected(handoff.target)
            case .pending, .recoveryRequired:
                throw BrowserMCPConnectionError.targetLocked
            }
        }

        let keys = Self.targetKeys(for: authorization.connectionReceipt)
        guard !keys.isEmpty,
              keys.allSatisfy({ self.targetOwners[$0] == .root && self.pendingHandoffOwners[$0] == nil })
        else {
            throw BrowserMCPConnectionError.targetLocked
        }
        for key in keys {
            self.pendingHandoffOwners[key] = sessionID
        }
        self.pendingHandoffClaims[sessionID] = PendingHandoffClaim(authorization: authorization)
        return .start
    }

    func commitRootHandoff(
        to sessionID: SessionID,
        authorization: BrowserMCPConnectionHandoffAuthorization,
        target: BrowserMCPAuthorizedHandoffTarget) async throws
    {
        guard !self.endedSessions.contains(sessionID), var state = self.sessions[sessionID] else {
            throw BrowserMCPConnectionError.sessionEnded
        }
        let keys = Self.targetKeys(for: target.receipt)
        guard target.receipt == authorization.connectionReceipt,
              self.pendingHandoffClaims[sessionID]?.authorization == authorization,
              !keys.isEmpty,
              keys.allSatisfy({ self.targetOwners[$0] == .root && self.pendingHandoffOwners[$0] == sessionID })
        else {
            throw BrowserMCPConnectionError.targetLocked
        }
        let previousCapabilities = state.capabilities
        let previousMutationGate = state.mutationGate
        let namespaceDrain = Task { @MainActor in
            do {
                try await previousMutationGate.acquire()
            } catch {
                return false
            }
            await previousCapabilities.end()
            await previousMutationGate.release()
            return true
        }
        guard await namespaceDrain.value,
              !self.endedSessions.contains(sessionID),
              self.sessions[sessionID]?.manager === state.manager,
              self.pendingHandoffClaims[sessionID]?.authorization == authorization,
              keys.allSatisfy({ self.targetOwners[$0] == .root && self.pendingHandoffOwners[$0] == sessionID })
        else {
            throw BrowserMCPConnectionError.targetLocked
        }
        self.targetOwners = self.targetOwners.filter { $0.value != .root }
        for key in keys {
            self.targetOwners[key] = .session(sessionID)
        }
        self.cancelPendingHandoff(for: sessionID)
        state.capabilities = BrowserToolCapabilitySession()
        state.mutationGate = MCPToolSnapshotExecutionGate()
        self.sessions[sessionID] = state
        self.handoffs[sessionID] = HandoffState(
            authorization: authorization,
            target: target,
            phase: .pending)
    }

    func cancelPendingHandoff(for sessionID: SessionID) {
        let claimedKeys = self.pendingHandoffOwners.compactMap { key, owner in
            owner == sessionID ? key : nil
        }
        self.pendingHandoffOwners = self.pendingHandoffOwners.filter { $0.value != sessionID }
        self.pendingHandoffClaims.removeValue(forKey: sessionID)
        for key in claimedKeys where self.deferredRootReleaseKeys.remove(key) != nil {
            if self.targetOwners[key] == .root {
                self.targetOwners.removeValue(forKey: key)
            }
        }
    }

    func requireSourceRecovery(for sessionID: SessionID) {
        guard var claim = self.pendingHandoffClaims[sessionID] else { return }
        claim.sourceRecoveryRequired = true
        self.pendingHandoffClaims[sessionID] = claim
    }

    func sourceRecovery(named name: String) -> (
        sessionID: SessionID,
        authorization: BrowserMCPConnectionHandoffAuthorization)?
    {
        guard let sessionID = self.namedSessions[name],
              let claim = self.pendingHandoffClaims[sessionID],
              claim.sourceRecoveryRequired
        else { return nil }
        return (sessionID, claim.authorization)
    }

    func confirmSourceRecovery(for sessionID: SessionID) {
        if let claim = self.pendingHandoffClaims[sessionID] {
            for key in Self.targetKeys(for: claim.authorization.connectionReceipt)
                where self.targetOwners[key] == .root
            {
                self.targetOwners.removeValue(forKey: key)
            }
        }
        self.cancelPendingHandoff(for: sessionID)
    }

    func resolveHandoff(for sessionID: SessionID, as resolution: HandoffResolution) throws {
        guard var handoff = self.handoffs[sessionID], handoff.phase == .pending else {
            throw BrowserMCPConnectionError.targetLocked
        }
        switch resolution {
        case .retryable: handoff.phase = .retryable
        case .connected: handoff.phase = .connected
        case .recoveryRequired: handoff.phase = .recoveryRequired
        }
        self.handoffs[sessionID] = handoff
    }

    func resolveRetryableHandoffIfNotEnding(for sessionID: SessionID) -> Bool {
        guard self.endingSessions[sessionID] == nil else { return false }
        do {
            try self.resolveHandoff(for: sessionID, as: .retryable)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func end(named name: String) async -> Bool {
        guard let sessionID = self.namedSessions[name] else { return true }
        return await self.endAndConfirm(sessionID)
    }

    var count: Int {
        self.sessions.count
    }

    var isEmpty: Bool {
        self.sessions.isEmpty
    }

    func isEnding(named name: String) -> Bool {
        guard let sessionID = self.namedSessions[name] else { return false }
        return self.endingSessions[sessionID] != nil
    }

    private static func targetKeys(for receipt: BrowserMCPConnectionReceipt) -> Set<TargetKey> {
        var keys = Set<TargetKey>()
        if let processIdentifier = receipt.processIdentifier,
           let processStartIdentity = receipt.processStartIdentity
        {
            keys.insert(.process(
                processIdentifier: processIdentifier,
                processStartIdentity: processStartIdentity))
        }
        if let devToolsBrowserID = receipt.devToolsBrowserID,
           !devToolsBrowserID.isEmpty
        {
            keys.insert(.devToolsBrowser(devToolsBrowserID))
        }
        if let browserURL = receipt.browserURL,
           let endpoint = BrowserLoopbackEndpoint(browserURL: browserURL)
        {
            keys.insert(.browserURL(endpoint.canonicalBrowserURL))
        }
        if keys.isEmpty, Self.isIsolatedSessionReceipt(receipt) {
            return []
        }
        if keys.isEmpty {
            keys.insert(.receipt(receipt))
        }
        return keys
    }

    private static func isIsolatedSessionReceipt(_ receipt: BrowserMCPConnectionReceipt) -> Bool {
        receipt.channel != nil &&
            receipt.processIdentifier == nil &&
            receipt.processStartIdentity == nil &&
            receipt.bundleIdentifier == nil &&
            receipt.browserURL == nil &&
            receipt.webSocketDebuggerURL == nil &&
            receipt.devToolsBrowserID == nil &&
            receipt.browserVersion == nil &&
            receipt.protocolVersion == nil
    }

    private func releaseOwnership(for sessionID: SessionID) {
        self.targetOwners = self.targetOwners.filter { $0.value != .session(sessionID) }
    }
}
