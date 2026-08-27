import Commander
import Foundation
import Testing
@testable import PeekabooCLI

struct CommanderBinderAppConfigTests {
    @Test
    func `App launch binding`() throws {
        let parsed = ParsedValues(
            positional: ["Visual Studio Code"],
            options: [:],
            flags: ["waitUntilReady", "waitForWindow", "newInstance", "foreground"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.LaunchSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == "Visual Studio Code")
        #expect(command.bundleId == nil)
        #expect(command.waitUntilReady == true)
        #expect(command.newInstance == true)
        #expect(command.waitForWindow == true)
        #expect(command.foreground == true)
        #expect(command.noFocus == false)
    }

    @Test
    func `App launch new-instance requires a current bridge host`() throws {
        let parsed = ParsedValues(
            positional: ["TextEdit"],
            options: [:],
            flags: ["newInstance", "foreground"]
        )

        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: AppCommand.LaunchSubcommand.self
        )

        #expect(options.requiresApplicationLaunchOptions)
        #expect(options.requiresNewApplicationInstanceLaunch)
        #expect(!options.requiresApplicationWindowReadiness)
    }

    @Test
    func `App launch binding with --foreground`() throws {
        let parsed = ParsedValues(positional: ["Calendar"], options: [:], flags: ["foreground"])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.LaunchSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.foreground == true)
        #expect(command.noFocus == false)
    }

    @Test
    func `Background app launch requires a host that proves read-only no-op semantics`() throws {
        let background = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: ["Finder"], options: [:], flags: []),
            commandType: AppCommand.LaunchSubcommand.self
        )
        let foreground = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: ["Finder"], options: [:], flags: ["foreground"]),
            commandType: AppCommand.LaunchSubcommand.self
        )

        #expect(background.requiresSafeBackgroundApplicationLaunchNoOp)
        #expect(!foreground.requiresSafeBackgroundApplicationLaunchNoOp)
    }

    @Test
    func `Unsafe background lifecycle shapes refuse before runtime host resolution`() throws {
        let parsedValues = [
            ParsedValues(
                positional: ["TextEdit"],
                options: [:],
                flags: ["newInstance"]
            ),
            ParsedValues(
                positional: ["Safari"],
                options: ["open": ["https://example.com"]],
                flags: []
            ),
        ]

        for parsed in parsedValues {
            do {
                _ = try CommanderCLIBinder.makeRuntimeOptions(
                    from: parsed,
                    commandType: AppCommand.LaunchSubcommand.self
                )
                Issue.record("Expected pre-runtime lifecycle refusal")
            } catch let error as PreDispatchActionError {
                #expect(error.envelopeCode == .INTERACTION_FAILED)
                #expect(error.envelopeEffect == .refused)
                #expect(error.envelopeRetrySafe == true)
                #expect(error.envelopeMutationDispatched == false)
                #expect(error.envelopeHint?.contains("--foreground") == true)
            }
        }

        do {
            _ = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(positional: ["Calculator"], options: [:], flags: []),
                commandType: AppCommand.RelaunchSubcommand.self
            )
            Issue.record("Expected pre-runtime relaunch refusal")
        } catch let error as PreDispatchActionError {
            #expect(error.envelopeCode == .INTERACTION_FAILED)
            #expect(error.envelopeMutationDispatched == false)
        }

        do {
            _ = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(positional: ["Calculator"], options: [:], flags: []),
                commandType: AppCommand.UnhideSubcommand.self
            )
            Issue.record("Expected pre-runtime unhide refusal")
        } catch let error as PreDispatchActionError {
            #expect(error.envelopeCode == .INTERACTION_FAILED)
            #expect(error.envelopeHint?.contains("--activate") == true)
            #expect(error.envelopeMutationDispatched == false)
        }
    }

    @Test
    func `Foreground app activation requires a generation-pinned host`() throws {
        let unhide = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: ["Calculator"],
                options: [:],
                flags: ["activate"]
            ),
            commandType: AppCommand.UnhideSubcommand.self
        )
        let focus = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: ["Calculator"], options: [:], flags: []),
            commandType: AppCommand.FocusSubcommand.self
        )

        #expect(unhide.requiresProcessGenerationPinnedApplicationActivation)
        #expect(focus.requiresProcessGenerationPinnedApplicationActivation)
    }

    @Test
    func `Background app hide requires a generation-pinned host`() throws {
        let hide = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: ["Calculator"], options: [:], flags: []),
            commandType: AppCommand.HideSubcommand.self
        )

        #expect(hide.requiresProcessGenerationPinnedApplicationHide)
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
                "open": ["https://example.com", "~/Documents/report.pdf"],
            ],
            flags: ["foreground"]
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
                "bundleId": ["com.apple.Notes"],
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
    func `App quit positional binding`() throws {
        let parsed = ParsedValues(
            positional: ["Safari"],
            options: [
                "pid": ["123"],
                "expectedProcessStartIdentity": ["456789"],
                "except": ["Finder,Terminal"],
            ],
            flags: ["all", "force"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.QuitSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == "Safari")
        #expect(command.pid == 123)
        #expect(command.expectedProcessStartIdentity?.value == 456_789)
        #expect(command.all == true)
        #expect(command.except == "Finder,Terminal")
        #expect(command.force == true)
    }

    @Test
    func `App quit binding accepts the full UInt64 process generation`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "pid": ["123"],
                "expectedProcessStartIdentity": [String(UInt64.max)],
            ],
            flags: []
        )

        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.QuitSubcommand.self,
            parsedValues: parsed
        )

        #expect(command.expectedProcessStartIdentity?.value == UInt64.max)
    }

    @Test
    func `App quit rejects conflicting positional and flag targets`() {
        let parsed = ParsedValues(
            positional: ["Safari"],
            options: ["app": ["TextEdit"]],
            flags: []
        )
        #expect(throws: CommanderBindingError.invalidArgument(
            label: "app",
            value: "Safari, TextEdit",
            reason: "Provide the app either positionally or with --app, not both"
        )) {
            _ = try CommanderCLIBinder.instantiateCommand(
                ofType: AppCommand.QuitSubcommand.self,
                parsedValues: parsed
            )
        }
    }

    @Test
    func `App switch binding`() throws {
        let parsed = ParsedValues(
            positional: ["Slack"],
            options: [:],
            flags: ["foreground"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.SwitchSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.to == "Slack")
        #expect(command.cycle == false)
        #expect(command.foreground == true)
    }

    @Test
    func `App focus accepts positional app`() throws {
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.FocusSubcommand.self,
            parsedValues: ParsedValues(positional: ["Safari"], options: [:], flags: ["foreground"])
        )
        #expect(command.app == "Safari")
        #expect(command.pid == nil)
        #expect(command.foreground == true)
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
        #expect(AppCommand.ListSubcommand.schemaCapabilities == ["processStartIdentityDecimal"])
    }

    @Test
    func `App relaunch binding`() throws {
        let parsed = ParsedValues(
            positional: ["Safari"],
            options: [
                "pid": ["456"],
                "wait": ["3.5s"],
            ],
            flags: ["force", "waitUntilReady", "foreground"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.RelaunchSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == "Safari")
        #expect(command.pid == 456)
        #expect(command.wait.seconds == 3.5)
        #expect(command.force == true)
        #expect(command.waitUntilReady == true)
        #expect(command.foreground == true)
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
        let parsed = ParsedValues(positional: [], options: ["timeout": ["5s"]], flags: [])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: ConfigCommand.StatusCommand.self,
            parsedValues: parsed
        )
        #expect(command.timeout.seconds == 5)
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
            ),
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
    func `Config credential set binding`() throws {
        let parsed = ParsedValues(
            positional: ["OPENAI_API_KEY"],
            options: ["credentialFile": ["/secure/key"]],
            flags: ["noInput"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: ConfigCommand.CredentialSetCommand.self,
            parsedValues: parsed
        )
        #expect(command.keyOrProvider == "OPENAI_API_KEY")
        #expect(command.value == nil)
        #expect(command.credentialFile == "/secure/key")
        #expect(command.credentialStdin == false)
        #expect(command.noInput == true)
    }

    @Test
    func `Config add provider binding`() throws {
        let parsed = ParsedValues(
            positional: ["openrouter"],
            options: [
                "type": ["openai"],
                "name": ["OpenRouter"],
                "baseUrl": ["https://openrouter.ai"],
                "credentialReference": ["${OPENROUTER_API_KEY}"],
                "description": ["Multi-provider"],
                "headers": ["x-demo:yes"],
            ],
            flags: ["force", "dryRun", "noInput"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: ConfigCommand.AddProviderCommand.self,
            parsedValues: parsed
        )
        #expect(command.providerId == "openrouter")
        #expect(command.type == "openai")
        #expect(command.name == "OpenRouter")
        #expect(command.baseUrl == "https://openrouter.ai")
        #expect(command.credentialReference == "${OPENROUTER_API_KEY}")
        #expect(command.apiKey == nil)
        #expect(command.noInput == true)
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
        let parsed = ParsedValues(positional: [], options: ["to": ["3"]], flags: ["foreground"])
        let command = try CommanderCLIBinder.instantiateCommand(ofType: SwitchSubcommand.self, parsedValues: parsed)
        #expect(command.to == 3)
        #expect(command.foreground == true)
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
                "to": ["2"],
            ],
            flags: ["toCurrent", "follow", "foreground"]
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
        #expect(command.foreground == true)
    }

    @Test
    func `Agent command binding`() throws {
        let parsed = ParsedValues(
            positional: ["Open Notes and write summary"],
            options: [
                "maxSteps": ["7"],
                "model": ["gpt-5.5"],
                "resumeSession": ["sess-42"],
                "audioFile": ["/tmp/input.wav"],
            ],
            flags: [
                "debugTerminal",
                "quiet",
                "dryRun",
                "resume",
                "listSessions",
                "noCache",
                "allowForeground",
                "audio",
                "simple",
                "noColor",
            ]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AgentRunSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.task == "Open Notes and write summary")
        #expect(command.options.debugTerminal == true)
        #expect(command.options.quiet == true)
        #expect(command.options.dryRun == true)
        #expect(command.options.maxSteps == 7)
        #expect(command.options.model == "gpt-5.5")
        #expect(command.options.noCache == true)
        #expect(command.options.allowForeground == true)
        #expect(command.options.audio == true)
        #expect(command.options.audioFile == "/tmp/input.wav")
        #expect(command.options.simple == true)
        #expect(command.options.noColor == true)
    }
}
