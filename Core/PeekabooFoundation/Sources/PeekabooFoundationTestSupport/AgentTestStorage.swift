import Darwin
import Foundation

/// Process-owned storage for serial synthetic Agent tests. Never redirects HOME or uses saved user configuration.
@MainActor
public enum AgentTestStorage {
    private static var root: URL?

    public enum IsolationError: Error {
        case credentialEnvironmentPresent
        case notPrepared
        case realProviderForbidden
        case environmentSetupFailed
    }

    /// Call before the first service/configuration construction and run participating tests with --no-parallel.
    /// The owning test process retains its directory for post-run inspection and cleanup.
    public static func prepare(
        forbiddenEnvironmentKeys: [String],
        installProviderConfiguration: () -> Void) throws
    {
        guard self.root == nil else { return }
        guard !forbiddenEnvironmentKeys.contains(where: { getenv($0) != nil }) else {
            throw IsolationError.credentialEnvironmentPresent
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-agent-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"), options: .atomic)
        // A present empty primary credentials file also closes Tachikoma's legacy-file fallback.
        try Data().write(to: directory.appendingPathComponent("credentials"), options: .atomic)
        guard setenv("PEEKABOO_CONFIG_DIR", directory.path, 1) == 0,
              setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1) == 0
        else { throw IsolationError.environmentSetupFailed }
        installProviderConfiguration()
        self.root = directory
        fputs("Synthetic Agent test storage: \(directory.path)\n", stderr)
    }

    public static func sessionDirectory() throws -> URL {
        guard let root else { throw IsolationError.notPrepared }
        return root.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
