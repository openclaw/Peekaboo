import Foundation

/// Version-neutral local owner for independently authenticated browser sessions.
///
/// Each entry owns one Chrome DevTools MCP child, connection receipt, upload workspace, target lock,
/// and FIFO execution gate. A blocked call therefore orders only its own session; another explicitly
/// authenticated session can continue through its separate manager and provider connection.
@MainActor
final class BrowserMCPAuthenticatedSessionPool {
    struct SessionID: Hashable, Sendable {
        fileprivate let rawValue: UUID

        init() {
            self.rawValue = UUID()
        }
    }

    typealias Factory = @MainActor (String) -> BrowserMCPSessionManager

    private let serverNamePrefix: String
    private let factory: Factory
    private var sessions: [SessionID: BrowserMCPSessionManager] = [:]
    private var endedSessions = Set<SessionID>()

    nonisolated init(
        serverNamePrefix: String = "chrome-devtools-session",
        factory: @escaping Factory)
    {
        self.serverNamePrefix = serverNamePrefix
        self.factory = factory
    }

    func manager(for sessionID: SessionID) -> BrowserMCPSessionManager? {
        guard !self.endedSessions.contains(sessionID) else { return nil }
        if let manager = self.sessions[sessionID] {
            return manager
        }
        let name = "\(self.serverNamePrefix)-\(sessionID.rawValue.uuidString.lowercased())"
        let manager = self.factory(name)
        self.sessions[sessionID] = manager
        return manager
    }

    func end(_ sessionID: SessionID) async {
        self.endedSessions.insert(sessionID)
        guard let manager = self.sessions.removeValue(forKey: sessionID) else { return }
        await manager.endSession()
    }

    var count: Int {
        self.sessions.count
    }
}
