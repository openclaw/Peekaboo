import Commander
import Foundation
import Testing
@testable import PeekabooCLI

struct CommanderBinderAppConfigTests {
    @Test
    func `App launch binding`() throws {
        let parsed = ParsedValues(
            positional: ["Visual Studio Code"],
            options: [
                "bundleId": ["com.microsoft.VSCode"]
            ],
            flags: ["waitUntilReady"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.LaunchSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == "Visual Studio Code")
        #expect(command.bundleId == "com.microsoft.VSCode")
        #expect(command.waitUntilReady == true)
        #expect(command.noFocus == false)
    }

    @Test
    func `App launch binding with --no-focus`() throws {
        let parsed = ParsedValues(
            positional: ["Calendar"],
            options: [:],
            flags: ["noFocus"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.LaunchSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == "Calendar")
        #expect(command.noFocus == true)
    }

    @Test
    func `App launch binding with open targets`() throws {
        let parsed = ParsedValues(
            positional: ["Safari"],
            options: [
                "open": ["https://example.com", "~/Documents/report.pdf"]
            ],
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.LaunchSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == "Safari")
        #expect(command.openTargets == ["https://example.com", "~/Documents/report.pdf"])
    }

    @Test
    func `App launch binding with --bundle-id only`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "bundleId": ["com.apple.Notes"]
            ],
            flags: ["noFocus"]
        )

        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.LaunchSubcommand.self,
            parsedValues: parsed
        )

        #expect(command.app == nil)
        #expect(command.bundleId == "com.apple.Notes")
        #expect(command.noFocus == true)
    }

    @Test
    func `Open command binding with overrides`() throws {
        let parsed = ParsedValues(
            positional: ["https://example.com"],
            options: [
                "app": ["Safari"],
                "bundleId": ["com.apple.Safari"]
            ],
            flags: ["waitUntilReady", "noFocus"]
        )

        let command = try CommanderCLIBinder.instantiateCommand(ofType: OpenCommand.self, parsedValues: parsed)
        #expect(command.target == "https://example.com")
        #expect(command.app == "Safari")
        #expect(command.bundleId == "com.apple.Safari")
        #expect(command.waitUntilReady == true)
        #expect(command.noFocus == true)
    }

    @Test
    func `Open command binding minimal`() throws {
        let parsed = ParsedValues(
            positional: ["~/Desktop"],
            options: [:],
            flags: []
        )

        let command = try CommanderCLIBinder.instantiateCommand(ofType: OpenCommand.self, parsedValues: parsed)
        #expect(command.target == "~/Desktop")
        #expect(command.app == nil)
        #expect(command.bundleId == nil)
        #expect(command.waitUntilReady == false)
        #expect(command.noFocus == false)
    }

    @Test
    func `App quit binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "app": ["Safari"],
                "pid": ["123"],
                "except": ["Finder,Terminal"]
            ],
            flags: ["all", "force"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.QuitSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == "Safari")
        #expect(command.pid == 123)
        #expect(command.all == true)
        #expect(command.except == "Finder,Terminal")
        #expect(command.force == true)
    }

    @Test
    func `App switch binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: ["to": ["Slack"]],
            flags: ["cycle"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.SwitchSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.to == "Slack")
        #expect(command.cycle == true)
    }

    @Test
    func `App list binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [:],
            flags: ["includeHidden", "includeBackground"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.ListSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.includeHidden == true)
        #expect(command.includeBackground == true)
    }

    @Test
    func `App relaunch binding`() throws {
        let parsed = ParsedValues(
            positional: ["Safari"],
            options: [
                "pid": ["456"],
                "wait": ["3.5"]
            ],
            flags: ["force", "waitUntilReady"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.RelaunchSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == "Safari")
        #expect(command.pid == 456)
        #expect(command.wait == 3.5)
        #expect(command.force == true)
        #expect(command.waitUntilReady == true)
    }

    @Test
    func `Config init binding`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: ["force"])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: ConfigCommand.InitCommand.self,
            parsedValues: parsed
        )
        #expect(command.force == true)
    }

    @Test
    func `Config show binding`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: ["effective"])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: ConfigCommand.ShowCommand.self,
            parsedValues: parsed
        )
        #expect(command.effective == true)
    }

    @Test
    func `Config status binding`() throws {
        let parsed = ParsedValues(positional: [], options: ["timeout": ["5"]], flags: [])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: ConfigCommand.StatusCommand.self,
            parsedValues: parsed
        )
        #expect(command.timeoutSeconds == 5)
    }

    @Test
    func `Config status JSON payload is structured`() throws {
        let summary = ProviderStatusSummary(providers: [
            ProviderCredentialStatus(
                id: "openrouter",
                name: "OpenRouter",
                state: .stored,
                source: ProviderCredentialSource(type: "env", key: "OPENROUTER_API_KEY"),
                validation: .failed,
                message: "stored (env OPENROUTER_API_KEY, validation failed: status 401)"
            )
        ])

        let data = try JSONEncoder().encode(summary)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try #require(json["providers"] as? [[String: Any]])
        let openRouter = try #require(providers.first)
        let source = try #require(openRouter["source"] as? [String: Any])

        #expect(openRouter["id"] as? String == "openrouter")
        #expect(openRouter["state"] as? String == "stored")
        #expect(openRouter["validation"] as? String == "failed")
        #expect(source["type"] as? String == "env")
        #expect(source["key"] as? String == "OPENROUTER_API_KEY")
    }

    @Test
    func `Config set credential binding`() throws {
        let parsed = ParsedValues(positional: ["OPENAI_API_KEY", "sk-123"], options: [:], flags: [])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: ConfigCommand.SetCredentialCommand.self,
            parsedValues: parsed
        )
        #expect(command.key == "OPENAI_API_KEY")
        #expect(command.value == "sk-123")
    }

    @Test
    func `Config add provider binding`() throws {
        let parsed = ParsedValues(
            positional: ["openrouter"],
            options: [
                "type": ["openai"],
                "name": ["OpenRouter"],
                "baseUrl": ["https://openrouter.ai"],
                "apiKey": ["{env:OPENROUTER_API_KEY}"],
                "description": ["Multi-provider"],
                "headers": ["x-demo:yes"]
            ],
            flags: ["force", "dryRun"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: ConfigCommand.AddProviderCommand.self,
            parsedValues: parsed
        )
        #expect(command.providerId == "openrouter")
        #expect(command.type == "openai")
        #expect(command.name == "OpenRouter")
        #expect(command.baseUrl == "https://openrouter.ai")
        #expect(command.apiKey == "{env:OPENROUTER_API_KEY}")
        #expect(command.description == "Multi-provider")
        #expect(command.headers == "x-demo:yes")
        #expect(command.force == true)
        #expect(command.dryRun == true)
    }

    @Test
    func `Config remove provider binding`() throws {
        let parsed = ParsedValues(positional: ["openrouter"], options: [:], flags: ["force", "dryRun"])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: ConfigCommand.RemoveProviderCommand.self,
            parsedValues: parsed
        )
        #expect(command.providerId == "openrouter")
        #expect(command.force == true)
        #expect(command.dryRun == true)
    }

    @Test
    func `Config models provider binding`() throws {
        let parsed = ParsedValues(positional: ["openrouter"], options: [:], flags: ["discover"])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: ConfigCommand.ModelsProviderCommand.self,
            parsedValues: parsed
        )
        #expect(command.providerId == "openrouter")
        #expect(command.discover == true)
    }

    @Test
    func `Space list binding`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: ["detailed"])
        let command = try CommanderCLIBinder.instantiateCommand(ofType: ListSubcommand.self, parsedValues: parsed)
        #expect(command.detailed == true)
    }

    @Test
    func `Space switch binding`() throws {
        let parsed = ParsedValues(positional: [], options: ["to": ["3"]], flags: [])
        let command = try CommanderCLIBinder.instantiateCommand(ofType: SwitchSubcommand.self, parsedValues: parsed)
        #expect(command.to == 3)
    }

    @Test
    func `Space move-window binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "app": ["Safari"],
                "pid": ["123"],
                "windowTitle": ["Inbox"],
                "windowIndex": ["456"],
                "to": ["2"]
            ],
            flags: ["toCurrent", "follow"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: MoveWindowSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == "Safari")
        #expect(command.pid == 123)
        #expect(command.windowTitle == "Inbox")
        #expect(command.windowIndex == 456)
        #expect(command.to == 2)
        #expect(command.toCurrent == true)
        #expect(command.follow == true)
    }

    @Test
    func `Agent command binding`() throws {
        let parsed = ParsedValues(
            positional: ["Open Notes and write summary"],
            options: [
                "maxSteps": ["7"],
                "model": ["gpt-5.5"],
                "resumeSession": ["sess-42"],
                "audioFile": ["/tmp/input.wav"]
            ],
            flags: [
                "debugTerminal",
                "quiet",
                "dryRun",
                "resume",
                "listSessions",
                "noCache",
                "audio",
                "realtime",
                "simple",
                "noColor"
            ]
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: AgentCommand.self, parsedValues: parsed)
        #expect(command.task == "Open Notes and write summary")
        #expect(command.debugTerminal == true)
        #expect(command.quiet == true)
        #expect(command.dryRun == true)
        #expect(command.maxSteps == 7)
        #expect(command.model == "gpt-5.5")
        #expect(command.resume == true)
        #expect(command.resumeSession == "sess-42")
        #expect(command.listSessions == true)
        #expect(command.noCache == true)
        #expect(command.audio == true)
        #expect(command.audioFile == "/tmp/input.wav")
        #expect(command.realtime == true)
        #expect(command.simple == true)
        #expect(command.noColor == true)
    }
}
