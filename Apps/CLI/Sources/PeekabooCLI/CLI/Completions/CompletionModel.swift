import Commander
import Foundation

/// Shell-completion document rendered from Commander metadata.
///
/// `CompletionScriptDocument` is the single source of truth for completion
/// generation. It is derived from `CommanderCommandDescriptor` values, which are
/// already the canonical source for help output and command discovery.
struct CompletionScriptDocument {
    let commandName: String
    let commands: [CompletionCommand]
    let rootOptions: [CompletionOption]

    var topLevelChoices: [CompletionChoice] {
        self.commands.map { command in
            CompletionChoice(value: command.name, help: command.abstract)
        }
    }

    var flattenedPaths: [CompletionPath] {
        self.commands.flatMap { command in
            command.flattenedPaths(prefix: [])
        }
    }

    var pathsIncludingRoot: [CompletionPath] {
        [
            CompletionPath(
                path: [],
                subcommands: self.topLevelChoices,
                options: self.rootOptions,
                arguments: []
            ),
        ] + self.flattenedPaths
    }

    static func make(
        commandName: String = "peekaboo",
        descriptors: [CommanderCommandDescriptor]
    ) -> CompletionScriptDocument {
        let commands = descriptors
            .sorted { $0.metadata.name < $1.metadata.name }
            .map { CompletionCommand(descriptor: $0, path: [$0.metadata.name]) }

        let helpMirror = CompletionCommand.helpMirror(commands: commands)
        return CompletionScriptDocument(
            commandName: commandName,
            commands: [helpMirror] + commands,
            rootOptions: [
                .flag(names: ["-h", "--help"], help: "Show help information"),
                .flag(names: ["-V", "--version"], help: "Show version information"),
            ]
        )
    }
}

struct CompletionCommand {
    let name: String
    let abstract: String
    let arguments: [CompletionArgument]
    let options: [CompletionOption]
    let subcommands: [CompletionCommand]

    var subcommandChoices: [CompletionChoice] {
        self.subcommands.map { command in
            CompletionChoice(value: command.name, help: command.abstract)
        }
    }

    init(descriptor: CommanderCommandDescriptor, path: [String]) {
        self.name = descriptor.metadata.name
        self.abstract = descriptor.metadata.abstract
        self.arguments = descriptor.metadata.signature.arguments.enumerated().map { index, argument in
            CompletionArgument(
                label: argument.label,
                isOptional: argument.isOptional,
                choices: CompletionValueCatalog.argumentChoices(for: path, index: index, label: argument.label)
            )
        }
        self.options = Self.makeOptions(from: descriptor.metadata.signature, path: path)
        self.subcommands = descriptor.subcommands
            .filter { !$0.metadata.name.hasPrefix("_") }
            .sorted { $0.metadata.name < $1.metadata.name }
            .map { subcommand in
                CompletionCommand(descriptor: subcommand, path: path + [subcommand.metadata.name])
            }
    }

    private init(
        name: String,
        abstract: String,
        arguments: [CompletionArgument],
        options: [CompletionOption],
        subcommands: [CompletionCommand]
    ) {
        self.name = name
        self.abstract = abstract
        self.arguments = arguments
        self.options = options
        self.subcommands = subcommands
    }

    func flattenedPaths(prefix: [String]) -> [CompletionPath] {
        let path = prefix + [self.name]
        let current = CompletionPath(
            path: path,
            subcommands: self.subcommandChoices,
            options: self.options,
            arguments: self.arguments
        )
        return [current] + self.subcommands.flatMap { subcommand in
            subcommand.flattenedPaths(prefix: path)
        }
    }

    static func helpMirror(commands: [CompletionCommand]) -> CompletionCommand {
        CompletionCommand(
            name: "help",
            abstract: "Show help for commands",
            arguments: [],
            options: [],
            subcommands: commands.map { command in
                CompletionCommand(
                    name: command.name,
                    abstract: command.abstract,
                    arguments: [],
                    options: [],
                    subcommands: self.helpSubcommands(from: command.subcommands)
                )
            }
        )
    }

    private static func helpSubcommands(from commands: [CompletionCommand]) -> [CompletionCommand] {
        commands.map { command in
            CompletionCommand(
                name: command.name,
                abstract: command.abstract,
                arguments: [],
                options: [],
                subcommands: self.helpSubcommands(from: command.subcommands)
            )
        }
    }

    private static func makeOptions(from signature: CommandSignature, path: [String]) -> [CompletionOption] {
        let flags = signature.flags.map { flag in
            CompletionOption.flag(
                names: self.uniqueNames(flag.names.map(\.completionSpelling)),
                help: flag.help ?? "No description provided"
            )
        }

        let options = signature.options.map { option in
            let names = self.uniqueNames(option.names.map(\.completionSpelling))
            return CompletionOption.option(
                names: names,
                valueName: option.label,
                help: option.help ?? "No description provided",
                valueChoices: CompletionValueCatalog.optionChoices(
                    for: path,
                    label: option.label,
                    names: names
                )
            )
        }

        return flags + options + [
            .flag(names: ["-h", "--help"], help: "Show help information"),
        ]
    }

    private static func uniqueNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for name in names where !seen.contains(name) {
            seen.insert(name)
            ordered.append(name)
        }
        return ordered
    }
}

struct CompletionPath {
    let path: [String]
    let subcommands: [CompletionChoice]
    let options: [CompletionOption]
    let arguments: [CompletionArgument]

    var key: String {
        self.path.joined(separator: " ")
    }
}

struct CompletionArgument {
    let label: String
    let isOptional: Bool
    let choices: [CompletionChoice]
}

struct CompletionOption {
    let names: [String]
    let help: String
    let valueName: String?
    let valueChoices: [CompletionChoice]

    var takesValue: Bool {
        self.valueName != nil
    }

    static func flag(names: [String], help: String) -> CompletionOption {
        CompletionOption(names: names, help: help, valueName: nil, valueChoices: [])
    }

    static func option(
        names: [String],
        valueName: String,
        help: String,
        valueChoices: [CompletionChoice]
    ) -> CompletionOption {
        CompletionOption(names: names, help: help, valueName: valueName, valueChoices: valueChoices)
    }
}

/// A single suggested completion value with optional help text.
///
/// `CompletionChoice` is used for subcommands and curated value suggestions for
/// positional arguments or option values.
struct CompletionChoice {
    let value: String
    let help: String?
}

/// Central registry for curated completion values that cannot be inferred from
/// Commander metadata alone.
///
/// Most command structure comes directly from descriptors. This catalog is only
/// for constrained value sets such as `completions [shell]` or `--log-level`.
enum CompletionValueCatalog {
    static func argumentChoices(for path: [String], index: Int, label: String) -> [CompletionChoice] {
        if path == ["completions"], index == 0, label == "shell" {
            return CompletionsCommand.Shell.allCases.map { shell in
                CompletionChoice(value: shell.rawValue, help: shell.helpText)
            }
        }
        return []
    }

    static func optionChoices(for path: [String], label: String, names: [String]) -> [CompletionChoice] {
        if names.contains("--log-level"), label == "logLevel" {
            return LogLevel.allCases.map { level in
                CompletionChoice(value: level.cliValue, help: nil)
            }
        }
        return []
    }
}

/// Dispatches shell-completion rendering to the appropriate shell-specific
/// renderer.
enum CompletionScriptRenderer {
    static func render(document: CompletionScriptDocument, for targetShell: CompletionsCommand.Shell) -> String {
        switch targetShell {
        case .bash:
            BashCompletionRenderer().render(document: document)
        case .zsh:
            ZshCompletionRenderer().render(document: document)
        case .fish:
            FishCompletionRenderer().render(document: document)
        }
    }
}

protocol ShellCompletionRendering {
    func render(document: CompletionScriptDocument) -> String
}

extension CommanderName {
    var completionSpelling: String {
        switch self {
        case let .short(value), let .aliasShort(value):
            "-\(value)"
        case let .long(value), let .aliasLong(value):
            "--\(value)"
        }
    }
}
