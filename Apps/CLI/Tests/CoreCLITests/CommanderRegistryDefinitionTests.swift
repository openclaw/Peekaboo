import Commander
import Testing
@testable import PeekabooCLI

struct CommanderRegistryDefinitionTests {
    @Test
    @MainActor
    func `Every registered command has an unambiguous definition`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let program = Program(descriptors: descriptors.map(\.metadata))

        #expect(throws: CommanderProgramError.missingCommand) {
            _ = try program.resolve(arguments: [])
        }
    }
}
