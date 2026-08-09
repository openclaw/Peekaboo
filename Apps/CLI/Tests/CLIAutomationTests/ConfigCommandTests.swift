import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
struct ConfigCommandTests {
    // MARK: - Helpers

    private func makeRuntime(json: Bool = false) -> CommandRuntime {
        CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: json, logLevel: nil),
            services: PeekabooServices()
        )
    }

    private func withTempConfigDir(_ body: @escaping (URL) async throws -> Void) async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        setenv("PEEKABOO_CONFIG_NONINTERACTIVE", "1", 1)
        setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
        #if DEBUG
        PeekabooCore.ConfigurationManager.shared.resetForTesting()
        #endif

        defer {
            unsetenv("PEEKABOO_CONFIG_DIR")
            unsetenv("PEEKABOO_CONFIG_NONINTERACTIVE")
            unsetenv("PEEKABOO_CONFIG_DISABLE_MIGRATION")
            #if DEBUG
            PeekabooCore.ConfigurationManager.shared.resetForTesting()
            #endif
            try? FileManager.default.removeItem(at: tempDir)
        }

        try await body(tempDir)
    }

    @Test
    func `ConfigCommand exists and has correct subcommands`() {
        // Verify the command exists
        let command = ConfigCommand.self

        // Check command configuration
        #expect(command.commandDescription.commandName == "config")
        #expect(command.commandDescription.abstract == "Manage Peekaboo configuration")

        // Key-path map / closures over existential metatypes trip SILGen on the
        // CI toolchain; keep the explicit loop (same idiom as MenuCommandTests).
        let subcommands = command.commandDescription.subcommands
        #expect(subcommands.count == 8)
        var subcommandNames: [String] = []
        subcommandNames.reserveCapacity(subcommands.count)
        for descriptor in subcommands {
            guard let name = descriptor.commandDescription.commandName else { continue }
            subcommandNames.append(name)
        }
        for expected in ["init", "show", "status", "edit", "validate", "login", "provider", "credential"] {
            #expect(subcommandNames.contains(expected), "missing config subcommand \(expected)")
        }

        var providerNames: [String] = []
        for descriptor in ConfigCommand.ProviderCommand.commandDescription.subcommands {
            guard let name = descriptor.commandDescription.commandName else { continue }
            providerNames.append(name)
        }
        #expect(providerNames == ["add", "remove", "list", "test", "models"])

        var credentialNames: [String] = []
        for descriptor in ConfigCommand.CredentialCommand.commandDescription.subcommands {
            guard let name = descriptor.commandDescription.commandName else { continue }
            credentialNames.append(name)
        }
        #expect(credentialNames == ["set"])
    }

    @Test
    func `InitCommand has correct configuration`() {
        let command = ConfigCommand.InitCommand.self
        #expect(command.commandDescription.commandName == "init")
        #expect(command.commandDescription.abstract == "Create a default configuration file")
    }

    @Test
    func `ShowCommand has correct configuration`() {
        let command = ConfigCommand.ShowCommand.self
        #expect(command.commandDescription.commandName == "show")
        #expect(command.commandDescription.abstract == "Display current configuration")
    }

    @Test
    func `EditCommand has correct configuration`() {
        let command = ConfigCommand.EditCommand.self
        #expect(command.commandDescription.commandName == "edit")
        #expect(command.commandDescription.abstract == "Open configuration file in your default editor")
    }

    @Test
    func `ValidateCommand has correct configuration`() {
        let command = ConfigCommand.ValidateCommand.self
        #expect(command.commandDescription.commandName == "validate")
        #expect(command.commandDescription.abstract == "Validate configuration file syntax")
    }

    @Test
    func `CredentialSetCommand has correct configuration`() {
        let command = ConfigCommand.CredentialSetCommand.self
        #expect(command.commandDescription.commandName == "set")
    }

    @Test
    func `Set credential writes to overridden credentials path`() async throws {
        try await self.withTempConfigDir { dir in
            var command = ConfigCommand.CredentialSetCommand()
            command.keyOrProvider = "OPENAI_API_KEY"
            command.value = "test-openai-key"

            try await command.run(using: self.makeRuntime())

            let credentialsPath = dir.appendingPathComponent("credentials")
            #expect(FileManager.default.fileExists(atPath: credentialsPath.path))

            let contents = try String(contentsOf: credentialsPath, encoding: .utf8)
            #expect(contents.contains("OPENAI_API_KEY=test-openai-key"))
        }
    }

    @Test
    func `AddProviderCommand validates provider IDs`() {
        #expect(ConfigCommand.AddProviderCommand.isValidProviderId("openrouter"))
        #expect(ConfigCommand.AddProviderCommand.isValidProviderId("acme-123"))
        #expect(!ConfigCommand.AddProviderCommand.isValidProviderId("spaces not-allowed"))
        #expect(!ConfigCommand.AddProviderCommand.isValidProviderId("🥸"))
    }

    @Test
    func `AddProviderCommand parses headers and rejects invalid formats`() throws {
        let parsed = try ConfigCommand.AddProviderCommand.parseHeaders("X-Key:one,Auth: Bearer")
        #expect(parsed?["x-key"] == "one")
        #expect(parsed?["auth"] == "Bearer")

        #expect(throws: ConfigCommand.AddProviderCommand.HeaderParseError.self) {
            _ = try ConfigCommand.AddProviderCommand.parseHeaders("missingColon")
        }
    }

    @Test
    func `Init command creates config file at overridden path`() async throws {
        try await self.withTempConfigDir { dir in
            var command = ConfigCommand.InitCommand()
            try await command.run(using: self.makeRuntime())

            let configPath = dir.appendingPathComponent("config.json")
            #expect(FileManager.default.fileExists(atPath: configPath.path))
        }
    }

    @Test
    func `Add provider dry-run does not write`() async throws {
        try await self.withTempConfigDir { dir in
            var command = ConfigCommand.AddProviderCommand()
            command.providerId = "openrouter"
            command.type = "openai"
            command.name = "OpenRouter"
            command.baseUrl = "https://openrouter.ai/api/v1"
            command.apiKey = "{env:OPENROUTER_API_KEY}"
            command.dryRun = true

            try await command.run(using: self.makeRuntime())

            let configPath = dir.appendingPathComponent("config.json")
            #expect(!FileManager.default.fileExists(atPath: configPath.path))
        }
    }

    @Test
    func `Add provider rejects invalid URL`() async throws {
        try await self.withTempConfigDir { _ in
            var command = ConfigCommand.AddProviderCommand()
            command.providerId = "bad"
            command.type = "openai"
            command.name = "Bad"
            command.baseUrl = "localhost"
            command.apiKey = "{env:BAD_API_KEY}"

            await #expect(throws: (any Error).self) {
                try await command.run(using: self.makeRuntime())
            }
        }
    }

    @Test
    func `Remove provider dry-run leaves config intact`() async throws {
        try await self.withTempConfigDir { _ in
            var add = ConfigCommand.AddProviderCommand()
            add.providerId = "keep"
            add.type = "openai"
            add.name = "Keep"
            add.baseUrl = "https://api.keep/v1"
            add.apiKey = "{env:KEEP_API_KEY}"
            try await add.run(using: self.makeRuntime())

            var remove = ConfigCommand.RemoveProviderCommand()
            remove.providerId = "keep"
            remove.dryRun = true
            try await remove.run(using: self.makeRuntime())

            let providersAfter = PeekabooCore.ConfigurationManager.shared.listCustomProviders()
            #expect(providersAfter["keep"] != nil)
        }
    }

    @Test
    func `Validate command fails on malformed config`() async throws {
        try await self.withTempConfigDir { dir in
            let badConfig = dir.appendingPathComponent("config.json")
            try "{ invalid json".write(to: badConfig, atomically: true, encoding: .utf8)

            var command = ConfigCommand.ValidateCommand()
            await #expect(throws: (any Error).self) {
                try await command.run(using: self.makeRuntime())
            }
        }
    }

    @Test
    func `Add/remove provider persists to config`() async throws {
        try await self.withTempConfigDir { _ in
            var add = ConfigCommand.AddProviderCommand()
            add.providerId = "local"
            add.type = "openai"
            add.name = "Local"
            add.baseUrl = "https://api.local/v1"
            add.apiKey = "{env:LOCAL_API_KEY}"
            try await add.run(using: self.makeRuntime())

            let providersAfterAdd = PeekabooCore.ConfigurationManager.shared.listCustomProviders()
            #expect(providersAfterAdd["local"] != nil)
            #expect(providersAfterAdd["local"]?.options.baseURL == "https://api.local/v1")

            var remove = ConfigCommand.RemoveProviderCommand()
            remove.providerId = "local"
            remove.force = true
            try await remove.run(using: self.makeRuntime())

            let providersAfterRemove = PeekabooCore.ConfigurationManager.shared.listCustomProviders()
            #expect(providersAfterRemove["local"] == nil)
        }
    }

    @Test
    func `Edit print-path leaves filesystem untouched`() async throws {
        try await self.withTempConfigDir { dir in
            let configPath = dir.appendingPathComponent("config.json").path

            var command = ConfigCommand.EditCommand()
            command.printPath = true
            try await command.run(using: self.makeRuntime())

            #expect(!FileManager.default.fileExists(atPath: configPath))
        }
    }
}
