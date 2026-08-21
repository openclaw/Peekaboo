import Commander
import Foundation

extension CommanderRuntimeRouter {
    static let categoryLookup: [ObjectIdentifier: CommandRegistryEntry.Category] = {
        var lookup: [ObjectIdentifier: CommandRegistryEntry.Category] = [:]
        for entry in CommandRegistry.entries {
            lookup[ObjectIdentifier(entry.type)] = entry.category
        }
        return lookup
    }()

    static func makeHelpTheme() -> HelpTheme {
        let capabilities = TerminalDetector.detectCapabilities()
        if let forcedMode = TerminalDetector.shouldForceOutputMode() {
            return HelpTheme(useColors: forcedMode.supportsColors)
        }
        return HelpTheme(useColors: capabilities.supportsColors)
    }

    static func renderRootUsageCard(theme: HelpTheme) -> String {
        var lines: [String] = []
        lines.append(theme.heading("Usage"))
        lines.append("  \(theme.accent("peekaboo <command> [options] [runtime flags]"))")
        return lines.joined(separator: "\n")
    }

    static func renderUsageCard(
        for descriptor: CommanderCommandDescriptor,
        path: [String],
        signature: CommandSignature? = nil,
        theme: HelpTheme
    ) -> String {
        let usageLine = self.buildUsageLine(path: path, signature: signature ?? descriptor.metadata.signature)
        var lines: [String] = []
        lines.append(theme.heading("Usage"))
        lines.append("  \(theme.accent(usageLine))")

        let abstract = descriptor.metadata.abstract.trimmingCharacters(in: .whitespacesAndNewlines)
        if !abstract.isEmpty {
            lines.append("")
            lines.append(theme.heading("Summary"))
            lines.append("  \(abstract)")
        }

        return lines.joined(separator: "\n")
    }

    static func renderCommandHelp(
        _ descriptor: CommanderCommandDescriptor,
        path: [String],
        theme: HelpTheme
    ) -> String {
        let helpSignature = self.helpSignature(for: descriptor)
        var sections = [
            self.renderUsageCard(for: descriptor, path: path, signature: helpSignature, theme: theme),
            CommandHelpRenderer.renderHelp(for: descriptor.type, signature: helpSignature, theme: theme),
        ]

        // Registry descriptors already inject the runtime signature into OPTIONS and FLAGS.
        // Keep the standalone section only for descriptors that do not expose those entries.
        if !self.signatureContainsRuntimeOptions(helpSignature) {
            sections.append(self.renderGlobalFlagsSection(theme: theme))
        }

        if !descriptor.subcommands.isEmpty {
            var lines = ["Subcommands:"]
            lines.append(contentsOf: self.renderCommandList(for: descriptor.subcommands, theme: theme))
            if let defaultName = descriptor.metadata.defaultSubcommandName {
                lines.append("")
                lines.append("Default subcommand: \(theme.command(defaultName))")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    /// Parent help for a default-subcommand tree must describe the forms accepted by the bare parent invocation.
    /// Merge only for presentation: parsing still resolves through Commander's normal default-subcommand path.
    static func helpSignature(for descriptor: CommanderCommandDescriptor) -> CommandSignature {
        guard let defaultName = descriptor.metadata.defaultSubcommandName,
              let defaultDescriptor = descriptor.subcommands.first(where: { $0.metadata.name == defaultName })
        else {
            return descriptor.metadata.signature
        }
        return self.mergingHelpSignatures(
            parent: descriptor.metadata.signature,
            defaultLeaf: defaultDescriptor.metadata.signature
        )
    }

    private static func mergingHelpSignatures(
        parent: CommandSignature,
        defaultLeaf: CommandSignature
    ) -> CommandSignature {
        let parent = parent.flattened()
        let defaultLeaf = defaultLeaf.flattened()
        var arguments = parent.arguments
        var options = parent.options
        var flags = parent.flags
        var argumentLabels = Set(arguments.map(\.label))
        var optionTokens = Set(options.flatMap { $0.names.map(\.commandLineToken) })
        var flagTokens = Set(flags.flatMap { $0.names.map(\.commandLineToken) })

        for argument in defaultLeaf.arguments where argumentLabels.insert(argument.label).inserted {
            arguments.append(argument)
        }
        for option in defaultLeaf.options {
            let tokens = Set(option.names.map(\.commandLineToken))
            guard optionTokens.isDisjoint(with: tokens) else { continue }
            options.append(option)
            optionTokens.formUnion(tokens)
        }
        for flag in defaultLeaf.flags {
            let tokens = Set(flag.names.map(\.commandLineToken))
            guard flagTokens.isDisjoint(with: tokens) else { continue }
            flags.append(flag)
            flagTokens.formUnion(tokens)
        }

        return CommandSignature(arguments: arguments, options: options, flags: flags)
    }

    static func signatureContainsRuntimeOptions(_ signature: CommandSignature) -> Bool {
        let runtimeSignature = CommandSignature().withPeekabooRuntimeFlags().flattened()
        let optionLabels = Set(signature.options.map(\.label))
        let flagLabels = Set(signature.flags.map(\.label))
        return Set(runtimeSignature.options.map(\.label)).isSubset(of: optionLabels) &&
            Set(runtimeSignature.flags.map(\.label)).isSubset(of: flagLabels)
    }

    static func globalFlagSummaries(theme: HelpTheme) -> [String] {
        [
            theme.bullet(label: "--json/-j (alias: --json-output)", description: "Emit machine-readable JSON output"),
            theme.bullet(label: "--verbose/-v", description: "Enable verbose logging"),
            theme.bullet(
                label: "--log-level <level>",
                description: "trace | verbose | debug | info | warning | error | critical"
            ),
            theme.bullet(
                label: "--no-remote",
                description: "Force local services; skip remote bridge hosts even if available"
            ),
            theme.bullet(
                label: "--bridge-socket <path>",
                description: "Override the Peekaboo Bridge socket path"
            ),
            theme.bullet(
                label: "--input-strategy <mode>",
                description: "Override UI input strategy: actionFirst | synthFirst | actionOnly | synthOnly"
            )
        ]
    }

    static func renderGlobalFlagsSection(theme: HelpTheme) -> String {
        var lines: [String] = []
        lines.append(theme.heading("Global Runtime Flags"))
        lines.append("  Place these after the leaf command, e.g. `peekaboo see --json`.")
        for entry in self.globalFlagSummaries(theme: theme) {
            lines.append("  \(entry)")
        }
        return lines.joined(separator: "\n")
    }

    static func renderCommandList(
        for commands: [CommanderCommandDescriptor],
        theme: HelpTheme,
        indent: String = "  "
    ) -> [String] {
        let sorted = commands
            .filter { !$0.metadata.name.hasPrefix("_") }
            .sorted { $0.metadata.name < $1.metadata.name }
        let maxNameLength = sorted.map(\.metadata.name.count).max() ?? 0
        let columnWidth = min(max(maxNameLength, 8), 24)
        return sorted.map { descriptor in
            let name = descriptor.metadata.name
            let summary = descriptor.metadata.abstract.isEmpty ? "No description provided." : descriptor.metadata
                .abstract
            let paddedName: String = if name.count >= columnWidth {
                name
            } else {
                name + String(repeating: " ", count: columnWidth - name.count)
            }
            let displayName = theme.command(paddedName)
            return "\(indent)\(displayName)  \(summary)"
        }
    }

    static func buildUsageLine(path: [String], signature: CommandSignature) -> String {
        var tokens = ["peekaboo"]
        let commandPath = path.isEmpty ? ["<command>"] : path
        tokens.append(contentsOf: commandPath)

        for argument in signature.arguments {
            let placeholder = self.argumentPlaceholder(for: argument)
            let rendered = argument.label.hasSuffix("...") ? "<\(placeholder)> ..." : "<\(placeholder)>"
            tokens.append(argument.isOptional ? "[\(rendered)]" : rendered)
        }

        if !signature.options.isEmpty || !signature.flags.isEmpty {
            tokens.append("[options]")
        }

        return tokens.joined(separator: " ")
    }

    static func argumentPlaceholder(for argument: ArgumentDefinition) -> String {
        let label = argument.label.hasSuffix("...") ? String(argument.label.dropLast(3)) : argument.label
        let lowered = label.replacingOccurrences(of: "_", with: "-")
        return Self.kebabCased(lowered)
    }

    static func kebabCased(_ value: String) -> String {
        guard !value.isEmpty else { return value }
        var scalars: [Character] = []
        for character in value {
            if character.isUppercase {
                if !scalars.isEmpty && scalars.last != "-" {
                    scalars.append("-")
                }
                scalars.append(contentsOf: character.lowercased())
            } else if character == " " || character == "-" {
                if scalars.last != "-" {
                    scalars.append("-")
                }
            } else {
                scalars.append(character)
            }
        }
        return String(scalars)
    }
}

struct HelpTheme {
    let useColors: Bool

    func heading(_ text: String) -> String {
        guard self.useColors else { return text }
        return "\(TerminalColor.bold)\(TerminalColor.cyan)\(text)\(TerminalColor.reset)"
    }

    func accent(_ text: String) -> String {
        guard self.useColors else { return text }
        return "\(TerminalColor.magenta)\(text)\(TerminalColor.reset)"
    }

    func command(_ text: String) -> String {
        guard self.useColors else { return text }
        return "\(TerminalColor.bold)\(text)\(TerminalColor.reset)"
    }

    func dim(_ text: String) -> String {
        guard self.useColors else { return text }
        return "\(TerminalColor.gray)\(text)\(TerminalColor.reset)"
    }

    func bullet(label: String, description: String) -> String {
        let prefix = self.useColors ? "\(TerminalColor.gray)•\(TerminalColor.reset)" : "-"
        let labelText = self.useColors ? "\(TerminalColor.bold)\(label)\(TerminalColor.reset)" : label
        return "\(prefix) \(labelText) \(description)"
    }
}

extension CommandRegistryEntry.Category {
    var displayName: String {
        switch self {
        case .core:
            "Core Commands"
        case .interaction:
            "Interaction"
        case .system:
            "System"
        case .vision:
            "Vision"
        case .ai:
            "AI"
        case .mcp:
            "MCP"
        }
    }
}
