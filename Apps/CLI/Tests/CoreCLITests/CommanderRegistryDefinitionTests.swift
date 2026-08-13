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

        var failures: [String] = []
        Self.validateSignatures(descriptors, path: [], failures: &failures)
        #expect(
            failures.isEmpty,
            "Invalid Commander definitions:\n\(failures.joined(separator: "\n"))"
        )
    }

    private static func validateSignatures(
        _ descriptors: [CommanderCommandDescriptor],
        path: [String],
        failures: inout [String]
    ) {
        for descriptor in descriptors {
            let commandPath = path + [descriptor.metadata.name]
            do {
                _ = try CommandParser(signature: descriptor.metadata.signature).parse(arguments: [])
            } catch let error as CommanderError {
                switch error {
                case .invalidArgumentOrder,
                     .duplicateOptionName,
                     .duplicateFlagName,
                     .conflictingName:
                    failures.append("\(commandPath.joined(separator: " ")): \(error.description)")
                default:
                    break
                }
            } catch {
                failures.append("\(commandPath.joined(separator: " ")): \(error.localizedDescription)")
            }
            Self.validateSignatures(descriptor.subcommands, path: commandPath, failures: &failures)
        }
    }
}
