import Darwin
import Foundation
import PeekabooAgentRuntimeTestSupport
import PeekabooFoundationTestSupport
import Tachikoma
import Testing
@testable import PeekabooAutomation

@Suite(.serialized)
@MainActor
struct AuthorityTestIsolationTests {
    @Test(arguments: [false, true], [false, true])
    func `restores sentinel state`(environmentWasSet: Bool, bodyThrows: Bool) async throws {
        let previous = ProcessState()
        let sentinelRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("authority-isolation-sentinel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sentinelRoot, withIntermediateDirectories: true)
        defer {
            previous.restore()
            try? FileManager.default.removeItem(at: sentinelRoot)
        }
        try Data("{}".utf8).write(to: sentinelRoot.appendingPathComponent("config.json"))
        try Data().write(to: sentinelRoot.appendingPathComponent("credentials"))
        setenv("PEEKABOO_CONFIG_DIR", sentinelRoot.path, 1)
        setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
        ConfigurationManager.shared.configuration = Configuration(agent: .init(defaultModel: "sentinel"))
        ConfigurationManager.shared.credentials = ["AUTHORITY_TEST_FIXTURE": "sentinel"]

        let configDirectory = environmentWasSet ? sentinelRoot.path : nil
        let disableMigration = environmentWasSet ? "sentinel-migration" : nil
        Self.setEnvironment("PEEKABOO_CONFIG_DIR", value: configDirectory)
        Self.setEnvironment("PEEKABOO_CONFIG_DISABLE_MIGRATION", value: disableMigration)
        let sentinel = TachikomaConfiguration(loadFromEnvironment: false)
        TachikomaConfiguration.default = sentinel
        let profile = sentinelRoot.appendingPathComponent("sentinel-profile").path
        TachikomaConfiguration.profileDirectoryName = profile
        let observation = ScopeObservation()

        do {
            try await AuthorityTestIsolation().provideScope(
                for: #require(Test.current), testCase: Test.Case.current)
            {
                try await MainActor.run {
                    observation.directory = try Self.verifyInstalledScope(previousConfiguration: sentinel)
                    #expect(ConfigurationManager.shared.configuration == nil)
                    #expect(ConfigurationManager.shared.credentials.isEmpty)
                    #expect(ConfigurationManager.shared.getConfiguration()?.agent == nil)
                    #expect(TachikomaConfiguration.profileDirectoryName == observation.directory?.path)
                    ConfigurationManager.shared.credentials = ["AUTHORITY_TEST_FIXTURE": "synthetic"]
                }
                if bodyThrows {
                    throw BodyError.expected
                }
            }
            #expect(!bodyThrows)
        } catch BodyError.expected {
            #expect(bodyThrows)
        }

        #expect(TachikomaConfiguration.default === sentinel)
        #expect(Self.environment("PEEKABOO_CONFIG_DIR") == configDirectory)
        #expect(Self.environment("PEEKABOO_CONFIG_DISABLE_MIGRATION") == disableMigration)
        #expect(TachikomaConfiguration.profileDirectoryName == profile)
        #expect(ConfigurationManager.shared.configuration == nil)
        #expect(ConfigurationManager.shared.credentials.isEmpty)
        let directory = try #require(observation.directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(throws: AgentTestStorage.IsolationError.notPrepared) {
            try AgentTestStorage.sessionDirectory()
        }
    }

    @Test
    func `restores absent default`() async throws {
        let previous = ProcessState()
        defer { previous.restore() }
        TachikomaConfiguration.default = nil
        try await AuthorityTestIsolation().provideScope(
            for: #require(Test.current), testCase: Test.Case.current)
        {
            try await MainActor.run {
                _ = try Self.verifyInstalledScope(previousConfiguration: nil)
            }
        }
        #expect(TachikomaConfiguration.default == nil)
    }

    @Test(arguments: [false, true])
    func `nested scopes restore outer state`(innerBodyThrows: Bool) async throws {
        try await AuthorityTestIsolation().provideScope(
            for: #require(Test.current), testCase: Test.Case.current)
        {
            let outer = await MainActor.run { ProcessState() }
            let innerObservation = await MainActor.run { ScopeObservation() }
            do {
                try await AuthorityTestIsolation().provideScope(
                    for: #require(Test.current), testCase: Test.Case.current)
                {
                    try await MainActor.run {
                        innerObservation.directory = try Self.verifyInstalledScope(
                            previousConfiguration: outer.configuration)
                        #expect(innerObservation.directory?.path != outer.configDirectory)
                        _ = ConfigurationManager.shared.loadConfiguration()
                    }
                    if innerBodyThrows {
                        throw BodyError.expected
                    }
                }
                #expect(!innerBodyThrows)
            } catch BodyError.expected {
                #expect(innerBodyThrows)
            }
            try await MainActor.run {
                #expect(TachikomaConfiguration.default === outer.configuration)
                #expect(Self.environment("PEEKABOO_CONFIG_DIR") == outer.configDirectory)
                #expect(Self.environment("PEEKABOO_CONFIG_DISABLE_MIGRATION") == outer.disableMigration)
                #expect(TachikomaConfiguration.profileDirectoryName == outer.profileDirectory)
                let outerDirectory = try #require(outer.configDirectory)
                #expect(FileManager.default.fileExists(atPath: outerDirectory))
                let session = try AgentTestStorage.sessionDirectory()
                #expect(session.deletingLastPathComponent().deletingLastPathComponent().path == outerDirectory)
                let innerDirectory = try #require(innerObservation.directory)
                #expect(!FileManager.default.fileExists(atPath: innerDirectory.path))
                #expect(throws: AgentTestStorage.IsolationError.realProviderForbidden) {
                    try TachikomaConfiguration.resolve(.current).makeProvider(for: .ollama(.custom("fixture")))
                }
            }
        }
        #expect(throws: AgentTestStorage.IsolationError.notPrepared) {
            try AgentTestStorage.sessionDirectory()
        }
    }

    @Test
    func `refuses every credential environment key before installing`() async throws {
        let keys = Provider.standardProviders.flatMap {
            [$0.environmentVariable] + $0.alternativeEnvironmentVariables
        } + ["OPENAI_ACCESS_TOKEN", "ANTHROPIC_ACCESS_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "PEEKABOO_AI_PROVIDERS"]
        for key in Set(keys).sorted() where !key.isEmpty {
            let previous = ProcessState()
            let previousValue = Self.environment(key)
            defer { Self.setEnvironment(key, value: previousValue) }
            #expect(setenv(key, "", 1) == 0)
            do {
                try await AuthorityTestIsolation().provideScope(
                    for: #require(Test.current), testCase: Test.Case.current)
                {
                    Issue.record("Credential-bearing environment must not run the body")
                }
                Issue.record("Expected credentialEnvironmentPresent for \(key)")
            } catch let error as AgentTestStorage.IsolationError {
                #expect(error == .credentialEnvironmentPresent)
            }
            #expect(TachikomaConfiguration.default === previous.configuration)
            #expect(TachikomaConfiguration.profileDirectoryName == previous.profileDirectory)
            #expect(Self.environment("PEEKABOO_CONFIG_DIR") == previous.configDirectory)
            #expect(Self.environment("PEEKABOO_CONFIG_DISABLE_MIGRATION") == previous.disableMigration)
            #expect(throws: AgentTestStorage.IsolationError.notPrepared) {
                try AgentTestStorage.sessionDirectory()
            }
        }
    }

    private static func verifyInstalledScope(previousConfiguration: TachikomaConfiguration?) throws -> URL {
        let configuration = try #require(TachikomaConfiguration.default)
        #expect(configuration !== previousConfiguration)
        #expect(throws: AgentTestStorage.IsolationError.realProviderForbidden) {
            try TachikomaConfiguration.resolve(.current).makeProvider(for: .openai(.gpt55))
        }
        let path = try #require(Self.environment("PEEKABOO_CONFIG_DIR"))
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try String(contentsOf: directory.appendingPathComponent("config.json"), encoding: .utf8) == "{}")
        #expect(try Data(contentsOf: directory.appendingPathComponent("credentials")).isEmpty)
        #expect(Self.environment("PEEKABOO_CONFIG_DISABLE_MIGRATION") == "1")
        #expect(TachikomaConfiguration.profileDirectoryName == directory.path)
        let session = try AgentTestStorage.sessionDirectory()
        #expect(session.deletingLastPathComponent().deletingLastPathComponent() == directory)
        return directory
    }

    private static func environment(_ key: String) -> String? {
        getenv(key).map { String(cString: $0) }
    }

    private static func setEnvironment(_ key: String, value: String?) {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }

    private enum BodyError: Error {
        case expected
    }

    @MainActor
    private final class ScopeObservation {
        var directory: URL?
    }

    @MainActor
    private struct ProcessState {
        let configuration = TachikomaConfiguration.default
        let configDirectory = AuthorityTestIsolationTests.environment("PEEKABOO_CONFIG_DIR")
        let disableMigration = AuthorityTestIsolationTests.environment("PEEKABOO_CONFIG_DISABLE_MIGRATION")
        let profileDirectory = TachikomaConfiguration.profileDirectoryName

        func restore() {
            AuthorityTestIsolationTests.setEnvironment("PEEKABOO_CONFIG_DIR", value: self.configDirectory)
            AuthorityTestIsolationTests.setEnvironment(
                "PEEKABOO_CONFIG_DISABLE_MIGRATION",
                value: self.disableMigration)
            ConfigurationManager.shared.resetForTesting()
            TachikomaConfiguration.default = self.configuration
            TachikomaConfiguration.profileDirectoryName = self.profileDirectory
        }
    }
}
