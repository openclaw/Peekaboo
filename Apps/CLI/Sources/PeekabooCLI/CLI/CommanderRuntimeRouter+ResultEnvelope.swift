extension CommanderRuntimeRouter {
    /// Classifies the selected command before Commander parses or binds its arguments.
    /// This keeps parse-time and binding-time failures in the same result-envelope context
    /// as failures thrown after the command instance is available.
    static func isActionInvocation(argv: [String]) -> Bool {
        guard let descriptor = self.resultEnvelopeDescriptor(argv: argv) else { return false }
        return (descriptor.type.init() as? any ActionOutputFormattable)?.defaultEffect != nil
    }

    private static func resultEnvelopeDescriptor(argv: [String]) -> CommanderCommandDescriptor? {
        var arguments = argv
        if arguments.first?.hasSuffix("peekaboo") == true {
            arguments.removeFirst()
        }
        guard let commandName = arguments.first else { return nil }

        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        guard let descriptor = descriptors.first(where: { $0.metadata.name == commandName }) else {
            return nil
        }
        arguments.removeFirst()
        return self.resultEnvelopeDescriptor(descriptor, arguments: &arguments)
    }

    private static func resultEnvelopeDescriptor(
        _ descriptor: CommanderCommandDescriptor,
        arguments: inout [String]
    ) -> CommanderCommandDescriptor? {
        guard !descriptor.subcommands.isEmpty else { return descriptor }

        if arguments.isEmpty || arguments[0].hasPrefix("-") {
            guard let defaultName = descriptor.metadata.defaultSubcommandName,
                  let defaultDescriptor = descriptor.subcommands.first(where: { $0.metadata.name == defaultName })
            else {
                return nil
            }
            return self.resultEnvelopeDescriptor(defaultDescriptor, arguments: &arguments)
        }

        let subcommandName = arguments.removeFirst()
        guard let subcommand = descriptor.subcommands.first(where: { $0.metadata.name == subcommandName }) else {
            return nil
        }
        return self.resultEnvelopeDescriptor(subcommand, arguments: &arguments)
    }
}
