import Foundation
import PeekabooFoundation

/// Version-neutral local owner for independently authenticated browser sessions.
///
/// Each entry owns one Chrome DevTools MCP child, connection receipt, upload workspace, target lock,
/// and FIFO execution gate. A blocked call therefore orders only its own session; another explicitly
/// authenticated session can continue through its separate manager and provider connection.
@MainActor
final class BrowserMCPAuthenticatedSessionPool {
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

    private struct SessionState {
        let manager: BrowserMCPSessionManager
        let capabilities: BrowserToolCapabilitySession
        let mutationGate: MCPToolSnapshotExecutionGate
    }

    struct SessionID: Hashable, @unchecked Sendable {
        fileprivate let rawValue: UUID
        private let lifetime: SessionLifetime

        init() {
            self.rawValue = UUID()
            self.lifetime = SessionLifetime()
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue == rhs.rawValue
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(self.rawValue)
        }

        fileprivate var hasEnded: Bool {
            self.lifetime.hasEnded
        }

        fileprivate func markEnded() {
            self.lifetime.markEnded()
        }
    }

    private final class SessionLifetime: @unchecked Sendable {
        private let lock = NSLock()
        private var ended = false

        var hasEnded: Bool {
            self.lock.withLock { self.ended }
        }

        func markEnded() {
            self.lock.withLock { self.ended = true }
        }
    }

    typealias Factory = @MainActor (String) -> BrowserMCPSessionManager

    private let serverNamePrefix: String
    private let factory: Factory
    private var sessions: [SessionID: SessionState] = [:]
    private var endingSessions: [SessionID: Task<Void, Never>] = [:]
    private var namedSessions: [String: SessionID] = [:]
    private var targetOwners: [TargetKey: TargetOwner] = [:]

    nonisolated init(
        serverNamePrefix: String = "chrome-devtools-session",
        factory: @escaping Factory)
    {
        self.serverNamePrefix = serverNamePrefix
        self.factory = factory
    }

    func manager(for sessionID: SessionID) -> BrowserMCPSessionManager? {
        guard !sessionID.hasEnded else { return nil }
        if let state = self.sessions[sessionID] {
            return state.manager
        }
        let name = "\(self.serverNamePrefix)-\(sessionID.rawValue.uuidString.lowercased())"
        let manager = self.factory(name)
        self.sessions[sessionID] = SessionState(
            manager: manager,
            capabilities: BrowserToolCapabilitySession(),
            mutationGate: MCPToolSnapshotExecutionGate())
        return manager
    }

    func capabilities(for sessionID: SessionID) -> BrowserToolCapabilitySession? {
        self.sessions[sessionID]?.capabilities
    }

    func mutationGate(for sessionID: SessionID) -> MCPToolSnapshotExecutionGate? {
        self.sessions[sessionID]?.mutationGate
    }

    func sessionID(named name: String) -> SessionID? {
        guard !name.isEmpty else { return nil }
        if let sessionID = self.namedSessions[name] {
            return sessionID
        }
        let sessionID = SessionID()
        self.namedSessions[name] = sessionID
        return sessionID
    }

    func end(_ sessionID: SessionID) async {
        if let ending = self.endingSessions[sessionID] {
            await ending.value
            return
        }
        sessionID.markEnded()
        self.namedSessions = self.namedSessions.filter { $0.value != sessionID }
        guard let state = self.sessions.removeValue(forKey: sessionID) else {
            self.targetOwners = self.targetOwners.filter { $0.value != .session(sessionID) }
            return
        }
        let ending = Task { @MainActor in
            do {
                try await state.mutationGate.acquire()
            } catch {
                return
            }
            // Capability end drains its operation gate, which covers reads through response projection; the mutation
            // gate separately keeps outer snapshot completion and teardown ordered.
            await state.capabilities.end()
            await state.manager.endSession()
            await state.mutationGate.release()
        }
        self.endingSessions[sessionID] = ending
        await ending.value
        self.targetOwners = self.targetOwners.filter { $0.value != .session(sessionID) }
        self.endingSessions.removeValue(forKey: sessionID)
    }

    func bind(_ sessionID: SessionID, to receipt: BrowserMCPConnectionReceipt) throws {
        guard !sessionID.hasEnded, self.sessions[sessionID] != nil else {
            throw BrowserMCPConnectionError.sessionEnded
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
        self.targetOwners = self.targetOwners.filter { $0.value != .session(sessionID) }
    }

    func bindRoot(to receipt: BrowserMCPConnectionReceipt) throws {
        let keys = Self.targetKeys(for: receipt)
        if keys.contains(where: { key in
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
        self.targetOwners = self.targetOwners.filter { $0.value != .root }
    }

    func end(named name: String) async {
        guard let sessionID = self.namedSessions[name] else { return }
        await self.end(sessionID)
    }

    var count: Int {
        self.sessions.count
    }

    var isEmpty: Bool {
        self.sessions.isEmpty
    }

    var retainedSessionIdentityCount: Int {
        Set(self.sessions.keys)
            .union(self.endingSessions.keys)
            .union(self.namedSessions.values)
            .count
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
}
