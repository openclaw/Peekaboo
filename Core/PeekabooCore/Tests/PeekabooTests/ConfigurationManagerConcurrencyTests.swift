import Darwin
import Foundation
import Tachikoma
import Testing
@testable import PeekabooAutomation

@Suite(.serialized)
struct ConfigurationManagerConcurrencyTests {
    private let manager = ConfigurationManager.shared

    /// Hosted CI only: the suite's shared manager may initialize before a test's override.
    @Test
    func `Fresh reads forget deleted keys and failed publication leaves cache unchanged`() async throws {
        try await withIsolatedConfigurationDirectory { configDirectory in
            try self.manager.setCredential(key: "OPENAI_API_KEY", value: "synthetic-original")
            let file = CredentialFile(url: configDirectory.appendingPathComponent("credentials"))
            _ = try file.updateCredentials { $0.removeAll() }
            #expect(self.manager.credentialValue(for: "OPENAI_API_KEY") == nil)
            try self.manager.setCredential(key: "OTHER", value: "synthetic-other")
            #expect(try self.manager.readCredentialSnapshot().count == 1)
            #expect(chmod(configDirectory.path, 0o500) == 0)
            defer { chmod(configDirectory.path, 0o700) }
            #expect(throws: (any Error).self) {
                try self.manager.setCredential(key: "FAILED", value: "synthetic-failed")
            }
            #expect(self.manager.credentials["FAILED"] == nil)
            let redirected = configDirectory.appendingPathComponent("redirected")
            #expect(chmod(configDirectory.path, 0o700) == 0)
            setenv("PEEKABOO_CONFIG_DIR", redirected.path, 1)
            try self.manager.setCredential(key: "REDIRECTED", value: "synthetic-new-root")
            #expect(self.manager.credentialValue(for: "OTHER") == nil)
            #expect(try file.readCredentialSnapshot().count == 1)
        }
    }

    @Test
    func `concurrent distinct credential writes persist every key`() async throws {
        try await withIsolatedConfigurationDirectory { configDirectory in
            let count = 48
            let expected = Dictionary(uniqueKeysWithValues: (0..<count).map { index in
                ("PEEKABOO_CONCURRENCY_KEY_\(index)", "placeholder-value-\(index)")
            })

            let failures = await runConcurrently(count: count) { index in
                try self.manager.setCredential(
                    key: "PEEKABOO_CONCURRENCY_KEY_\(index)",
                    value: "placeholder-value-\(index)")
            }

            #expect(failures.isEmpty, "Concurrent credential failures: \(failures)")

            self.manager.resetForTesting()
            for (key, value) in expected {
                #expect(self.manager.credentialValue(for: key) == value)
            }

            let persisted = try parseCredentials(
                at: configDirectory.appendingPathComponent("credentials"))
            #expect(persisted == expected)
        }
    }

    @Test
    func `concurrent distinct provider writes persist every provider`() async throws {
        try await withIsolatedConfigurationDirectory { configDirectory in
            let count = 32
            let expectedIDs = Set((0..<count).map { "provider-\($0)" })

            let failures = await runConcurrently(count: count) { index in
                let id = "provider-\(index)"
                let provider = Configuration.CustomProvider(
                    name: "Provider \(index)",
                    type: .openai,
                    options: .init(
                        baseURL: "https://provider-\(index).example.com/v1",
                        apiKey: "k\(index)"))
                try self.manager.updateConfiguration { configuration in
                    if configuration.customProviders == nil {
                        configuration.customProviders = [:]
                    }
                    configuration.customProviders?[id] = provider
                }
            }

            #expect(failures.isEmpty, "Concurrent provider failures: \(failures)")

            self.manager.resetForTesting()
            let reloaded = self.manager.loadConfiguration()
            let reloadedIDs = reloaded?.customProviders.map { Set($0.keys) } ?? []
            #expect(reloadedIDs == expectedIDs)

            let data = try Data(contentsOf: configDirectory.appendingPathComponent("config.json"))
            let persisted = try JSONDecoder().decode(Configuration.self, from: data)
            let persistedIDs = persisted.customProviders.map { Set($0.keys) } ?? []
            #expect(persistedIDs == expectedIDs)
        }
    }
}

private actor StartGate {
    private let participantCount: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
            guard self.waiters.count == self.participantCount else { return }

            let ready = self.waiters
            self.waiters.removeAll()
            ready.forEach { $0.resume() }
        }
    }
}

private func runConcurrently(
    count: Int,
    operation: @escaping @Sendable (Int) throws -> Void) async -> [String]
{
    let gate = StartGate(participantCount: count)

    return await withTaskGroup(of: String?.self, returning: [String].self) { group in
        for index in 0..<count {
            group.addTask {
                await gate.wait()
                do {
                    try operation(index)
                    return nil
                } catch {
                    return "\(index): \(error)"
                }
            }
        }

        var failures: [String] = []
        for await failure in group {
            if let failure {
                failures.append(failure)
            }
        }
        return failures
    }
}

private func parseCredentials(at url: URL) throws -> [String: String] {
    let contents = try String(contentsOf: url, encoding: .utf8)
    return contents.split(separator: "\n").reduce(into: [:]) { credentials, line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              let separator = trimmed.firstIndex(of: "=")
        else {
            return
        }

        credentials[String(trimmed[..<separator])] = String(trimmed[trimmed.index(after: separator)...])
    }
}

private func withIsolatedConfigurationDirectory(
    _ body: (URL) async throws -> Void) async throws
{
    let fileManager = FileManager.default
    let configDirectory = fileManager.temporaryDirectory
        .appendingPathComponent("peekaboo-concurrency-tests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)

    let previousConfigDirectory = getenv("PEEKABOO_CONFIG_DIR").map { String(cString: $0) }
    let previousMigrationSetting = getenv("PEEKABOO_CONFIG_DISABLE_MIGRATION").map { String(cString: $0) }
    let previousProfileDirectory = TachikomaConfiguration.profileDirectoryName

    setenv("PEEKABOO_CONFIG_DIR", configDirectory.path, 1)
    setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
    ConfigurationManager.shared.resetForTesting()

    defer {
        if let previousConfigDirectory {
            setenv("PEEKABOO_CONFIG_DIR", previousConfigDirectory, 1)
        } else {
            unsetenv("PEEKABOO_CONFIG_DIR")
        }
        if let previousMigrationSetting {
            setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", previousMigrationSetting, 1)
        } else {
            unsetenv("PEEKABOO_CONFIG_DISABLE_MIGRATION")
        }
        TachikomaConfiguration.profileDirectoryName = previousProfileDirectory
        ConfigurationManager.shared.resetForTesting()
        try? fileManager.removeItem(at: configDirectory)
    }

    try await body(configDirectory)
}
