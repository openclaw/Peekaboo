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
}
