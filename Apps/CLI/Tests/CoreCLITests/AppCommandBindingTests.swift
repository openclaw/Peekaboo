import Commander
import Testing
@testable import PeekabooCLI

@Suite("App command binding")
struct AppCommandBindingTests {
    @Test
    func `hide accepts positional app`() throws {
        let parsed = ParsedValues(positional: ["Preview"], options: [:], flags: [])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.HideSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == "Preview")
    }

    @Test
    func `unhide accepts positional app`() throws {
        let parsed = ParsedValues(positional: ["Preview"], options: [:], flags: ["activate"])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.UnhideSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == "Preview")
        #expect(command.activate == true)
    }

    @Test
    func `hide accepts pid without app`() throws {
        let parsed = ParsedValues(positional: [], options: ["pid": ["123"]], flags: ["foreground"])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.HideSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == nil)
        #expect(command.pid == 123)
    }

    @Test
    func `unhide accepts pid without app`() throws {
        let parsed = ParsedValues(positional: [], options: ["pid": ["123"]], flags: ["activate"])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.UnhideSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == nil)
        #expect(command.pid == 123)
        #expect(command.activate == true)
    }

    @Test
    func `relaunch accepts pid without app`() throws {
        let parsed = ParsedValues(positional: [], options: ["pid": ["123"]], flags: ["foreground"])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.RelaunchSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == nil)
        #expect(command.pid == 123)
    }

    @Test
    func `switch requires foreground and exactly one selector shape`() throws {
        let accepted = ParsedValues(
            positional: ["Preview"],
            options: [:],
            flags: ["foreground"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.SwitchSubcommand.self,
            parsedValues: accepted
        )
        #expect(command.to == "Preview")
        #expect(command.foreground)

        for rejected in [
            ParsedValues(positional: ["Preview"], options: [:], flags: ["cycle", "foreground"]),
            ParsedValues(positional: [" "], options: [:], flags: ["cycle", "foreground"]),
            ParsedValues(positional: [" "], options: [:], flags: ["foreground"]),
            ParsedValues(positional: [], options: [:], flags: ["cycle", "verify", "foreground"]),
            ParsedValues(positional: [], options: [:], flags: ["cycle"]),
        ] {
            #expect(throws: (any Error).self) {
                _ = try CommanderCLIBinder.instantiateCommand(
                    ofType: AppCommand.SwitchSubcommand.self,
                    parsedValues: rejected
                )
            }
        }
    }

    @Test
    func `focus requires foreground consent during binding`() throws {
        let accepted = ParsedValues(
            positional: ["Preview"],
            options: [:],
            flags: ["foreground"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: AppCommand.FocusSubcommand.self,
            parsedValues: accepted
        )
        #expect(command.app == "Preview")
        #expect(command.foreground)

        #expect(throws: (any Error).self) {
            _ = try CommanderCLIBinder.instantiateCommand(
                ofType: AppCommand.FocusSubcommand.self,
                parsedValues: ParsedValues(positional: ["Preview"], options: [:], flags: [])
            )
        }
    }
}
