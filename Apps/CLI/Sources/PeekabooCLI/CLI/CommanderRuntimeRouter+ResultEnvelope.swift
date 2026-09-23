import Commander

extension CommanderRuntimeRouter {
    /// Classifies the selected command before Commander parses or binds its arguments.
    /// This keeps parse-time and binding-time failures in the same result-envelope context
    /// as failures thrown after the command instance is available.
    static func isActionInvocation(argv: [String]) -> Bool {
        guard let command = self.resultEnvelopeCommand(argv: argv) else { return false }
        return (command.init() as? any ActionOutputFormattable)?.defaultEffect != nil
    }

    private static func resultEnvelopeCommand(argv: [String]) -> (any ParsableCommand.Type)? {
        var arguments = argv[...]
        if arguments.first?.hasSuffix("peekaboo") == true {
            arguments.removeFirst()
        }
        guard let commandName = arguments.first else { return nil }

        // Envelope classification needs command types; signature reflection belongs to parsing.
        guard let command = CommandRegistry.entries.first(where: {
            CommanderRegistryBuilder.commandName(for: $0.type) == commandName
        })?.type else {
            return nil
        }
        arguments.removeFirst()
        return self.resultEnvelopeCommand(command, arguments: &arguments)
    }

    private static func resultEnvelopeCommand(
        _ command: any ParsableCommand.Type,
        arguments: inout ArraySlice<String>
    ) -> (any ParsableCommand.Type)? {
        let description = command.commandDescription
        guard !description.subcommands.isEmpty else { return command }

        let subcommandName: String
        if let argument = arguments.first, !argument.hasPrefix("-") {
            subcommandName = arguments.removeFirst()
        } else {
            guard let defaultCommand = description.defaultSubcommand else { return nil }
            subcommandName = CommanderRegistryBuilder.commandName(for: defaultCommand)
        }

        guard let subcommand = description.subcommands.first(where: {
            CommanderRegistryBuilder.commandName(for: $0) == subcommandName
        }) else {
            return nil
        }
        return self.resultEnvelopeCommand(subcommand, arguments: &arguments)
    }
}
