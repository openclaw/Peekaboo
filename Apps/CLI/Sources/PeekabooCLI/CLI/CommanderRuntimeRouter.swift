import Commander
import Foundation

struct CommanderResolvedCommand {
    let metadata: CommandDescriptor
    let type: any ParsableCommand.Type
    let parsedValues: ParsedValues
}

@MainActor
enum CommanderRuntimeRouter {
    static func resolve(argv: [String]) throws -> CommanderResolvedCommand {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let trimmedArgs = Self.trimmedArguments(from: argv)
        if trimmedArgs.isEmpty {
            self.printRootHelp(descriptors: descriptors)
            throw ExitCode.success
        }
        if Self.handleRootEarlyExitRequest(arguments: trimmedArgs, descriptors: descriptors) {
            throw ExitCode.success
        }
        if let migrationError = CommanderMigrationAdvisor.commandError(for: trimmedArgs) {
            throw migrationError
        }
        if try Self.handleBareInvocation(arguments: trimmedArgs, descriptors: descriptors) {
            throw ExitCode.success
        }
        if try Self.handleHelpRequest(arguments: trimmedArgs, descriptors: descriptors) {
            throw ExitCode.success
        }
        let program = Program(descriptors: descriptors.map(\.metadata))
        let invocation: CommandInvocation
        do {
            invocation = try program.resolve(arguments: self.normalizedDefaultSubcommandArguments(trimmedArgs))
        } catch let error as CommanderProgramError {
            let shouldAdviseOptions = switch error {
            case .parsingError:
                true
            case .missingSubcommand(command: "clipboard"):
                true
            default:
                false
            }
            if shouldAdviseOptions,
               let migrationError = CommanderMigrationAdvisor.optionError(for: trimmedArgs) {
                throw migrationError
            }
            throw error
        }
        guard let descriptor = Self.findDescriptor(in: descriptors, matching: invocation.path) else {
            throw CommanderProgramError.unknownCommand(invocation.path.joined(separator: ":"))
        }
        return CommanderResolvedCommand(
            metadata: descriptor.metadata,
            type: descriptor.type,
            parsedValues: invocation.parsedValues
        )
    }

    private static func findDescriptor(
        in descriptors: [CommanderCommandDescriptor],
        matching path: [String]
    ) -> CommanderCommandDescriptor? {
        guard let head = path.first else { return nil }
        guard let match = descriptors.first(where: { $0.metadata.name == head }) else {
            return nil
        }
        guard path.count > 1 else {
            return match
        }
        let remainder = Array(path.dropFirst())
        return self.findDescriptor(in: match.subcommands, matching: remainder)
    }

    private static func trimmedArguments(from argv: [String]) -> [String] {
        guard !argv.isEmpty else { return [] }
        var args = argv
        if args[0].hasSuffix("peekaboo") {
            args.removeFirst()
        }
        return args
    }

    private static func normalizedDefaultSubcommandArguments(_ argv: [String]) -> [String] {
        var arguments = argv
        // Commander requires the root command before runtime flags; `peekaboo --json agent ...`
        // is invalid independently of agent shorthand, so the command can only be at index 0 or 1.
        let commandIndex = arguments.first?.hasSuffix("peekaboo") == true ? 1 : 0
        guard arguments.indices.contains(commandIndex), arguments[commandIndex] == "agent" else {
            return arguments
        }
        let nextIndex = commandIndex + 1
        guard arguments.indices.contains(nextIndex) else { return arguments }
        let token = arguments[nextIndex]
        let explicitSubcommands = Set(["run", "resume", "sessions", "chat"])
        guard !token.hasPrefix("-"), !explicitSubcommands.contains(token) else { return arguments }
        arguments.insert("run", at: nextIndex)
        return arguments
    }

    private static func handleHelpRequest(
        arguments: [String],
        descriptors: [CommanderCommandDescriptor]
    ) throws -> Bool {
        guard !arguments.isEmpty else { return false }

        if arguments[0].caseInsensitiveCompare("help") == .orderedSame {
            let tokens = Array(arguments.dropFirst())
            let path = self.resolveHelpPath(from: tokens, descriptors: descriptors)
            try self.printHelp(for: path, descriptors: descriptors)
            return true
        }

        let helpSearchArguments = Array(arguments.prefix { $0 != "--" })
        if let index = helpSearchArguments.firstIndex(where: { self.isHelpToken($0) }) {
            let tokens = Array(helpSearchArguments.prefix(index))
            let path = self.resolveHelpPath(from: tokens, descriptors: descriptors)
            try self.printHelp(for: path, descriptors: descriptors)
            return true
        }

        return false
    }

    private static func resolveHelpPath(
        from tokens: [String],
        descriptors: [CommanderCommandDescriptor]
    ) -> [String] {
        let commandTokens = self.droppingLeadingRuntimeOptions(from: tokens)
        guard !commandTokens.isEmpty else { return [] }

        for length in stride(from: commandTokens.count, through: 1, by: -1) {
            let candidate = Array(commandTokens.prefix(length))
            if self.findDescriptor(in: descriptors, matching: candidate) != nil {
                return candidate
            }
        }

        // Preserve previous behavior for unknown paths after discarding only the leading option prefix.
        return commandTokens
    }

    private static func handleRootEarlyExitRequest(
        arguments: [String],
        descriptors: [CommanderCommandDescriptor]
    ) -> Bool {
        let searchable = Array(arguments.prefix { $0 != "--" })
        guard let index = searchable.firstIndex(where: { self.isHelpToken($0) || self.isVersionToken($0) }) else {
            return false
        }
        guard self.containsOnlyLeadingRuntimeOptions(Array(searchable.prefix(index))) else { return false }

        let token = searchable[index]
        if self.isHelpToken(token) {
            self.printRootHelp(descriptors: descriptors)
            return true
        }

        let jsonTokens = Set(["--json", "-j", "--json-output", "--jsonOutput"])
        if searchable.contains(where: jsonTokens.contains) {
            outputSuccessCodable(data: Version.metadata, logger: .shared)
        } else {
            print(Version.fullVersion)
        }
        return true
    }

    private static let runtimeValueOptionNames: Set<String> = {
        let signature = CommandSignature().withPeekabooRuntimeFlags().flattened()
        return Set(signature.options.flatMap { option in
            option.names.map(\.commandLineToken)
        })
    }()

    private static let runtimeFlagNames: Set<String> = {
        let signature = CommandSignature().withPeekabooRuntimeFlags().flattened()
        return Set(signature.flags.flatMap { flag in
            flag.names.map(\.commandLineToken)
        })
    }()

    private static func runtimeOptionConsumesFollowingValue(_ token: String) -> Bool {
        !token.contains("=") && self.runtimeValueOptionNames.contains(token)
    }

    private static func containsOnlyLeadingRuntimeOptions(_ tokens: [String]) -> Bool {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            guard token.hasPrefix("-") else { return false }
            index += 1
            if self.runtimeOptionConsumesFollowingValue(token) {
                guard index < tokens.count else { return false }
                index += 1
            }
        }
        return true
    }

    /// Empty-input detection must not inherit root help/version's intentional tolerance for unknown options.
    private static func containsOnlyRecognizedRuntimeOptions(_ tokens: [String]) -> Bool {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let components = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(components[0])
            if self.runtimeFlagNames.contains(name) {
                guard components.count == 1 else { return false }
                index += 1
                continue
            }
            guard self.runtimeValueOptionNames.contains(name) else { return false }
            if components.count == 2 {
                guard !components[1].isEmpty else { return false }
                index += 1
                continue
            }
            index += 1
            guard index < tokens.count, !tokens[index].hasPrefix("-") else { return false }
            index += 1
        }
        return true
    }

    private static func droppingLeadingRuntimeOptions(from tokens: [String]) -> [String] {
        var index = 0
        while index < tokens.count, tokens[index].hasPrefix("-") {
            let token = tokens[index]
            index += 1
            if self.runtimeOptionConsumesFollowingValue(token), index < tokens.count {
                index += 1
            }
        }
        return Array(tokens.dropFirst(index))
    }

    private static func handleBareInvocation(
        arguments: [String],
        descriptors: [CommanderCommandDescriptor]
    ) throws -> Bool {
        guard let token = arguments.first else { return false }
        guard let descriptor = descriptors.first(where: { $0.metadata.name == token }) else {
            return false
        }
        let description = descriptor.type.commandDescription
        guard description.showHelpOnEmptyInvocation else { return false }
        let trailingArguments = Array(arguments.dropFirst())
        if let emptyInvocationError = CommanderEmptyInvocationPolicy.error(for: descriptor) {
            guard !trailingArguments.contains(where: Self.isHelpToken) else { return false }
            guard self.containsOnlyRecognizedRuntimeOptions(trailingArguments) else { return false }
            if !trailingArguments.contains(where: Self.isJSONOutputToken) {
                self.printCommandHelp(descriptor, path: [token])
            }
            throw emptyInvocationError
        }
        guard trailingArguments.isEmpty else { return false }
        self.printCommandHelp(descriptor, path: [token])
        if !descriptor.metadata.subcommands.isEmpty {
            throw CommanderProgramError.missingSubcommand(command: token)
        }
        return true
    }

    private static func isHelpToken(_ token: String) -> Bool {
        token == "--help" || token == "-h"
    }

    private static func isVersionToken(_ token: String) -> Bool {
        token == "--version" || token == "-V"
    }

    private static func isJSONOutputToken(_ token: String) -> Bool {
        token == "--json" || token == "-j" || token == "--json-output" || token == "--jsonOutput"
    }

    private static func printHelp(
        for path: [String],
        descriptors: [CommanderCommandDescriptor]
    ) throws {
        if path.isEmpty {
            self.printRootHelp(descriptors: descriptors)
            return
        }
        guard let descriptor = self.findDescriptor(in: descriptors, matching: path) else {
            throw CommanderProgramError.unknownCommand(path.joined(separator: " "))
        }
        self.printCommandHelp(descriptor, path: path)
    }

    private static func printRootHelp(descriptors: [CommanderCommandDescriptor]) {
        let theme = self.makeHelpTheme()
        print(self.renderRootUsageCard(theme: theme))
        print("")

        let groupedByCategory = Dictionary(grouping: descriptors) { descriptor in
            Self.categoryLookup[ObjectIdentifier(descriptor.type)] ?? .core
        }

        for category in CommandRegistryEntry.Category.allCases {
            guard let commands = groupedByCategory[category], !commands.isEmpty else { continue }
            print(theme.heading(category.displayName))
            let rows = self.renderCommandList(for: commands, theme: theme)
            rows.forEach { print($0) }
            print("")
        }

        print(self.renderGlobalFlagsSection(theme: theme))
        print("")
        print(theme.dim("Use `peekaboo help <command>` or `peekaboo <command> --help` for detailed options."))
    }

    private static func printCommandHelp(_ descriptor: CommanderCommandDescriptor, path: [String]) {
        let theme = self.makeHelpTheme()
        let usageCard = self.renderUsageCard(for: descriptor, path: path, theme: theme)
        let helpText = CommandHelpRenderer.renderHelp(for: descriptor.type, theme: theme)
        print(usageCard)
        print("")
        print(helpText)
        print("")
        print(self.renderGlobalFlagsSection(theme: theme))
        guard !descriptor.subcommands.isEmpty else { return }
        print("\nSubcommands:")
        let subcommandRows = self.renderCommandList(for: descriptor.subcommands, theme: theme)
        subcommandRows.forEach { print($0) }
        if let defaultName = descriptor.metadata.defaultSubcommandName {
            print("\nDefault subcommand: \(theme.command(defaultName))")
        }
    }
}
