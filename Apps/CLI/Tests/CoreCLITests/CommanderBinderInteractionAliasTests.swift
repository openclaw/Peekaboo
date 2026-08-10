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
    func `Press command rejects positional chords with key option`() {
        let parsed = ParsedValues(positional: ["cmd+c"], options: ["key": ["return"]], flags: [])
        #expect(throws: ValidationError.self) {
            _ = try CommanderCLIBinder.instantiateCommand(ofType: PressCommand.self, parsedValues: parsed)
        }
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
