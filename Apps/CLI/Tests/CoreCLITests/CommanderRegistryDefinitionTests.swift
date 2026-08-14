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
                try descriptor.metadata.signature.validate()
            } catch {
                switch error {
                case .invalidArgumentOrder,
                     .requiredArgumentAfterOptional,
                     .duplicateArgumentLabel,
                     .duplicateOptionLabel,
                     .duplicateFlagLabel,
                     .optionHasNoNames,
                     .emptyOptionName,
                     .unreachableOptionName,
                     .undeclaredJoinedShortName,
                     .flagHasNoNames,
                     .emptyFlagName,
                     .unreachableFlagName,
                     .duplicateOptionName,
                     .duplicateFlagName,
                     .conflictingName:
                    failures.append("\(commandPath.joined(separator: " ")): \(error.description)")
                case .unknownOption,
                     .missingValue,
                     .missingArgument,
                     .unexpectedArgument,
                     .invalidValue:
                    failures.append("\(commandPath.joined(separator: " ")): \(error.description)")
                }
            }
            Self.validateSignatures(descriptor.subcommands, path: commandPath, failures: &failures)
        }
    }
}
