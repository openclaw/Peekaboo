import Foundation

public enum PeekabooBridgeConstants {
    public static let socketName = "bridge.sock"

    /// Socket hosted by Peekaboo.app (primary host).
    public static var peekabooSocketPath: String {
        self.applicationSupportSocketPath(appDirectoryName: "Peekaboo", socketName: self.socketName)
    }

    /// Socket hosted by the reusable on-demand or manually started daemon.
    public static var daemonSocketPath: String {
        self.applicationSupportSocketPath(appDirectoryName: "Peekaboo", socketName: "daemon.sock")
    }

    /// Socket hosted by Claude.app (fallback host; piggyback on Claude Desktop TCC grants).
    public static var claudeSocketPath: String {
        self.applicationSupportSocketPath(appDirectoryName: "Claude", socketName: self.socketName)
    }

    /// Socket hosted by Clawdbot.app (fallback host).
    public static var clawdbotSocketPath: String {
        self.applicationSupportSocketPath(appDirectoryName: "clawdbot", socketName: self.socketName)
    }

    /// Current protocol version supported by this build.
    public static let protocolVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 8)

    /// Oldest protocol version this build can serve without changing request semantics.
    public static let minimumProtocolVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 0)

    /// Compatible protocol range for negotiation. Update when introducing breaking changes.
    public static let supportedProtocolRange: ClosedRange<PeekabooBridgeProtocolVersion> =
        minimumProtocolVersion...protocolVersion

    /// Default deadline for one Bridge request or response.
    public static let defaultRequestTimeoutSeconds: TimeInterval = 10

    /// Build identifier advertised during handshake (falls back to "dev").
    public static var buildIdentifier: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleVersion"] as? String
        let short = info?["CFBundleShortVersionString"] as? String
        switch (short, version) {
        case let (short?, version?):
            return "\(short) (\(version))"
        case let (nil, version?):
            return version
        default:
            return "dev"
        }
    }

    private static func applicationSupportSocketPath(appDirectoryName: String, socketName: String) -> String {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = baseDirectory.appendingPathComponent(appDirectoryName, isDirectory: true)
        return directory.appendingPathComponent(socketName, isDirectory: false).path
    }
}

extension JSONEncoder {
    public static func peekabooBridgeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static func peekabooBridgeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
