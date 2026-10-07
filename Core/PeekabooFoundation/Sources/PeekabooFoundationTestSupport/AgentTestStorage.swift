import Darwin
import Foundation

/// Scoped storage for synthetic Agent tests. Never redirects HOME or uses saved user configuration.
/// The environment is process-global, so run participating tests with --no-parallel.
@MainActor
public enum AgentTestStorage {
    private static var root: URL?

    public enum IsolationError: Error, Equatable {
        case credentialEnvironmentPresent
        case notPrepared
        case realProviderForbidden
        case environmentSetupFailed
    }

    /// Opaque saved state. Restore scopes in reverse installation order.
    public struct Scope: Sendable {
        fileprivate let directory: URL
        fileprivate let previousRoot: URL?
        fileprivate let previousConfigDirectory: String?
        fileprivate let previousDisableMigration: String?
    }

    /// Install a fresh private root before constructing services or configuration. Pair every install with restore.
    public static func install(forbiddenEnvironmentKeys: [String]) throws -> Scope {
        guard !forbiddenEnvironmentKeys.contains(where: { getenv($0) != nil }) else {
            throw IsolationError.credentialEnvironmentPresent
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-agent-test-\(UUID().uuidString)", isDirectory: true)
        let scope = Scope(
            directory: directory,
            previousRoot: self.root,
            previousConfigDirectory: getenv("PEEKABOO_CONFIG_DIR").map { String(cString: $0) },
            previousDisableMigration: getenv("PEEKABOO_CONFIG_DISABLE_MIGRATION").map { String(cString: $0) })
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"), options: .atomic)
            // A present empty primary credentials file also closes Tachikoma's legacy-file fallback.
            try Data().write(to: directory.appendingPathComponent("credentials"), options: .atomic)
            guard setenv("PEEKABOO_CONFIG_DIR", directory.path, 1) == 0,
                  setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1) == 0
            else { throw IsolationError.environmentSetupFailed }
            self.root = directory
            return scope
        } catch {
            try? self.restore(scope)
            throw error
        }
    }

    /// Restore the previous environment and storage root, then remove this scope's directory.
    public static func restore(_ scope: Scope) throws {
        let configResult = Self.restoreEnvironment("PEEKABOO_CONFIG_DIR", value: scope.previousConfigDirectory)
        let migrationResult = Self.restoreEnvironment(
            "PEEKABOO_CONFIG_DISABLE_MIGRATION", value: scope.previousDisableMigration)
        self.root = scope.previousRoot
        try FileManager.default.removeItem(at: scope.directory)
        guard configResult == 0, migrationResult == 0 else { throw IsolationError.environmentSetupFailed }
    }

    private static func restoreEnvironment(_ key: String, value: String?) -> Int32 {
        if let value {
            return setenv(key, value, 1)
        }
        return unsetenv(key)
    }

    /// Return a unique session path inside the active scope, or throw notPrepared outside one.
    public static func sessionDirectory() throws -> URL {
        guard let root else { throw IsolationError.notPrepared }
        return root.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
