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
        lines.append("  \(theme.accent("peekaboo <command> [options]"))")
        lines.append("")
        lines.append(theme.heading("Tip"))
        lines.append("  When developing locally, rebuild via \(theme.accent("pnpm run build:cli")) to test fresh bits.")
        return lines.joined(separator: "\n")
    }

    static func renderUsageCard(
        for descriptor: CommanderCommandDescriptor,
        path: [String],
        theme: HelpTheme
    ) -> String {
        let usageLine = self.buildUsageLine(path: path, signature: descriptor.metadata.signature)
        var lines: [String] = []
        lines.append(theme.heading("Usage"))
        lines.append("  \(theme.accent(usageLine))")

        let abstract = descriptor.metadata.abstract.trimmingCharacters(in: .whitespacesAndNewlines)
        if !abstract.isEmpty {
            lines.append("")
            lines.append(theme.heading("Summary"))
            lines.append("  \(abstract)")
        }

        lines.append("")
        lines.append(theme.heading("Tip"))
        lines.append("  When developing locally, rebuild via \(theme.accent("pnpm run build:cli")) to test fresh bits.")
        return lines.joined(separator: "\n")
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
        let sorted = commands.sorted { $0.metadata.name < $1.metadata.name }
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
            tokens.append(argument.isOptional ? "[\(placeholder)]" : "<\(placeholder)>")
        }

        if !signature.options.isEmpty || !signature.flags.isEmpty {
            tokens.append("[options]")
        }

        return tokens.joined(separator: " ")
    }

    static func argumentPlaceholder(for argument: ArgumentDefinition) -> String {
        let lowered = argument.label.replacingOccurrences(of: "_", with: "-")
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
                if scalars.last != "-" { scalars.append("-") }
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
