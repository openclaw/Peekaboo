import Commander
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooCLI

struct CommanderBinderMenuDockTests {
    @Test
    func `Scroll command binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "direction": ["down"],
                "amount": ["7"],
                "on": ["B4"],
                "snapshot": [SnapshotReferenceFixtures.first.rawValue],
                "delay": ["5"],
                "app": ["Mail"]
            ],
            flags: ["smooth", "spaceSwitch"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: ScrollCommand.self,
            parsedValues: parsed
        )
        #expect(command.direction == "down")
        #expect(command.amount == 7)
        #expect(command.on == "B4")
        #expect(command.snapshot == SnapshotReferenceFixtures.first.rawValue)
        #expect(command.delay.roundedMilliseconds == 5)
        #expect(command.target.app == "Mail")
        #expect(command.smooth == true)
        #expect(command.focusOptions.spaceSwitch == true)
    }

    @Test
    func `Menu click binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "app": ["Safari"],
                "item": ["File"],
                "path": ["File>New Window"]
            ],
            flags: ["spaceSwitch"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: MenuCommand.ClickSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.target.app == "Safari")
        #expect(command.item == "File")
        #expect(command.path == "File>New Window")
        #expect(command.focusOptions.spaceSwitch == true)
    }

    @Test
    func `Menu click binding without app`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: MenuCommand.ClickSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.target.app == nil)
    }

    @Test
    func `Menu list binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "app": ["Safari"]
            ],
            flags: ["includeDisabled", "noAutoFocus"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: MenuCommand.ListSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.target.app == "Safari")
        #expect(command.includeDisabled == true)
    }

    @Test
    func `Menu list binding without app`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: MenuCommand.ListSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.target.app == nil)
    }

    @Test
    func `Dock launch binding`() throws {
        let parsed = ParsedValues(positional: ["Safari"], options: [:], flags: ["foreground"])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: DockCommand.LaunchSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == "Safari")
        #expect(command.foreground)
    }

    @Test
    func `Dock right-click binding`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: [
                "app": ["Finder"],
                "select": ["New Window"]
            ],
            flags: ["foreground"]
        )
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: DockCommand.RightClickSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.app == "Finder")
        #expect(command.select == "New Window")
        #expect(command.foreground)
    }

    @Test
    func `Dock right-click requires app`() {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        #expect(throws: CommanderBindingError.missingArgument(label: "app")) {
            _ = try CommanderCLIBinder.instantiateCommand(
                ofType: DockCommand.RightClickSubcommand.self,
                parsedValues: parsed
            )
        }
    }

    @Test
    func `Dock list binding`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: ["includeAll"])
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: DockCommand.ListSubcommand.self,
            parsedValues: parsed
        )
        #expect(command.includeAll == true)
    }
}
