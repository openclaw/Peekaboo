import Commander
import Testing
@testable import PeekabooCLI

struct CommanderBinderInteractionAliasTests {
    @Test
    func `Type command accepts text option alias`() throws {
        let parsed = ParsedValues(positional: [], options: ["textOption": ["Hello option"]], flags: [])
        let command = try CommanderCLIBinder.instantiateCommand(ofType: TypeCommand.self, parsedValues: parsed)
        #expect(command.text == nil)
        #expect(command.textOption == "Hello option")
    }

    @Test
    func `Press command accepts key option alias`() throws {
        let parsed = ParsedValues(positional: [], options: ["key": ["return"]], flags: [])
        let command = try CommanderCLIBinder.instantiateCommand(ofType: PressCommand.self, parsedValues: parsed)
        #expect(command.chords == ["return"])
    }

    @Test
    func `Set value command accepts value option alias`() throws {
        let parsed = ParsedValues(
            positional: [],
            options: ["value": ["Hello value"], "on": ["elem_2"]],
            flags: []
        )
        let command = try CommanderCLIBinder.instantiateCommand(ofType: SetValueCommand.self, parsedValues: parsed)
        #expect(command.value == "Hello value")
        #expect(command.on == "elem_2")
    }
}
