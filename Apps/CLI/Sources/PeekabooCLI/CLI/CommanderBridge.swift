import Commander

protocol CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature
}

struct CommanderCommandDescriptor {
    let metadata: CommandDescriptor
    let type: any ParsableCommand.Type
    let subcommands: [CommanderCommandDescriptor]
}

struct CommanderCommandSummary: Codable {
    struct Argument: Codable {
        let label: String
        let help: String?
        let isOptional: Bool
    }

    struct Option: Codable {
        let names: [String]
        let help: String?
        let parsing: String
    }

    struct Flag: Codable {
        let names: [String]
        let help: String?
    }

    let name: String
    let abstract: String
    let discussion: String?
    let arguments: [Argument]
    let options: [Option]
    let flags: [Flag]
    let subcommands: [CommanderCommandSummary]
}

@MainActor
enum CommanderRegistryBuilder {
    static func buildDescriptors() -> [CommanderCommandDescriptor] {
        CommandRegistry.entries.map { self.buildDescriptor(for: $0.type) }
    }

    private static var descriptorLookup: [ObjectIdentifier: CommandDescriptor]?

    static func descriptor(for type: any ParsableCommand.Type) -> CommandDescriptor? {
        if let cached = self.descriptorLookup {
            return cached[ObjectIdentifier(type)]
        }
        let lookup = self.buildDescriptorLookup()
        self.descriptorLookup = lookup
        return lookup[ObjectIdentifier(type)]
    }

    static func buildCommandSummaries() -> [CommanderCommandSummary] {
        self.buildDescriptors().map { CommanderCommandSummary(descriptor: $0) }
    }

    private static func buildDescriptorLookup() -> [ObjectIdentifier: CommandDescriptor] {
        var lookup: [ObjectIdentifier: CommandDescriptor] = [:]

        func register(_ descriptor: CommanderCommandDescriptor) {
            lookup[ObjectIdentifier(descriptor.type)] = descriptor.metadata
            descriptor.subcommands.forEach(register)
        }

        self.buildDescriptors().forEach(register)
        return lookup
    }

    static func buildDescriptor(for type: any ParsableCommand.Type) -> CommanderCommandDescriptor {
        let description = type.commandDescription
        let commandInstance = type.init()
        let signature = self.resolveSignature(for: type, instance: commandInstance)
            .flattened()
            .withPeekabooRuntimeFlags()
        let childDescriptors = description.subcommands.map { self.buildDescriptor(for: $0) }
        let defaultName = description.defaultSubcommand.map { self.commandName(for: $0) }
        let metadata = CommandDescriptor(
            name: commandName(for: type),
            abstract: description.abstract,
            discussion: description.discussion,
            signature: signature,
            subcommands: childDescriptors.map(\.metadata),
            defaultSubcommandName: defaultName
        )
        return CommanderCommandDescriptor(metadata: metadata, type: type, subcommands: childDescriptors)
    }

    private static func commandName(for type: any ParsableCommand.Type) -> String {
        if let explicit = type.commandDescription.commandName {
            return explicit
        }
        return String(describing: type)
    }

    private static func resolveSignature(
        for type: any ParsableCommand.Type,
        instance: any ParsableCommand
    ) -> CommandSignature {
        if let provider = type as? any CommanderSignatureProviding.Type {
            return provider.commanderSignature()
        }
        return CommandSignature.describe(instance)
    }
}

extension CommanderCommandSummary {
    fileprivate init(descriptor: CommanderCommandDescriptor) {
        let signature = descriptor.metadata.signature
        self.name = descriptor.metadata.name
        self.abstract = descriptor.metadata.abstract
        self.discussion = descriptor.metadata.discussion
        self.arguments = signature.arguments.map { argument in
            Argument(
                label: argument.label,
                help: argument.help,
                isOptional: argument.isOptional
            )
        }
        self.options = signature.options.map { option in
            Option(
                names: option.names
                    .filter { !$0.isAlias }
                    .map(\.cliSpelling),
                help: option.help,
                parsing: option.parsing.displayName
            )
        }
        self.flags = signature.flags.map { flag in
            Flag(
                names: flag.names
                    .filter { !$0.isAlias }
                    .map(\.cliSpelling),
                help: flag.help
            )
        }
        self.subcommands = descriptor.subcommands
            .filter { !$0.metadata.name.hasPrefix("_") }
            .map { CommanderCommandSummary(descriptor: $0) }
    }
}

extension OptionDefinition {
    nonisolated static func commandOption(
        _ label: String,
        help: String? = nil,
        long: String? = nil,
        short: Character? = nil,
        parsing: OptionParsingStrategy = .singleValue
    ) -> OptionDefinition {
        var names: [CommanderName] = []
        if let short {
            names.append(.short(short))
        }
        names.append(.long(long ?? label.commanderized()))
        return OptionDefinition.make(label: label, names: names, help: help, parsing: parsing)
    }
}

extension FlagDefinition {
    nonisolated static func commandFlag(
        _ label: String,
        help: String? = nil,
        long: String? = nil,
        short: Character? = nil
    ) -> FlagDefinition {
        var names: [CommanderName] = []
        if let short {
            names.append(.short(short))
        }
        names.append(.long(long ?? label.commanderized()))
        return FlagDefinition.make(label: label, names: names, help: help)
    }
}

extension String {
    fileprivate nonisolated func commanderized() -> String {
        guard !isEmpty else { return self }
        var scalars: [Character] = []
        for character in self {
            if character.isUppercase {
                scalars.append("-")
                scalars.append(Character(character.lowercased()))
            } else {
                scalars.append(character)
            }
        }
        return String(scalars)
    }
}

extension CommanderName {
    fileprivate var cliSpelling: String {
        switch self {
        case let .short(value), let .aliasShort(value):
            "-\(value)"
        case let .long(value), let .aliasLong(value):
            "--\(value)"
        }
    }
}

extension OptionParsingStrategy {
    fileprivate var displayName: String {
        switch self {
        case .singleValue:
            "singleValue"
        case .upToNextOption:
            "upToNextOption"
        case .remaining:
            "remaining"
        }
    }
}
