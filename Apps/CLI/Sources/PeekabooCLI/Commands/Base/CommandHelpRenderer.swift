import Commander
import Foundation

@MainActor
struct CommandHelpRenderer {
    static func renderHelp(for type: (some ParsableCommand).Type, theme: HelpTheme? = nil) -> String {
        let description = type.commandDescription
        if let descriptor = CommanderRegistryBuilder.descriptor(for: type) {
            return self.renderHelp(
                abstract: description.abstract,
                discussion: description.discussion,
                signature: descriptor.signature,
                usageExamples: description.usageExamples,
                theme: theme
            )
        }

        let fallbackSignature = CommandSignature.describe(type.init())
            .flattened()
            .withPeekabooRuntimeFlags()
        return self.renderHelp(
            abstract: description.abstract,
            discussion: description.discussion,
            signature: fallbackSignature,
            usageExamples: description.usageExamples,
            theme: theme
        )
    }

    private static func renderHelp(
        abstract: String,
        discussion: String?,
        signature: CommandSignature,
        usageExamples: [CommandUsageExample],
        theme: HelpTheme?
    ) -> String {
        var sections: [String] = []

        if let descriptionSection = self.renderDescription(abstract: abstract, discussion: discussion, theme: theme) {
            sections.append(descriptionSection)
        }

        if let argumentsSection = self.renderArguments(signature.arguments, theme: theme) {
            sections.append(argumentsSection)
        }

        if let optionsSection = self.renderOptions(signature.options, theme: theme) {
            sections.append(optionsSection)
        }

        if let flagsSection = self.renderFlags(signature.flags, theme: theme) {
            sections.append(flagsSection)
        }

        if let examplesSection = self.renderExamples(usageExamples, theme: theme) {
            sections.append(examplesSection)
        }

        return sections.joined(separator: "\n\n")
    }

    private static func renderDescription(abstract: String, discussion: String?, theme: HelpTheme?) -> String? {
        var body: [String] = []
        if !abstract.isEmpty {
            body.append(abstract)
        }
        if let discussion, !discussion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body.append(discussion)
        }
        guard !body.isEmpty else { return nil }
        return self.makeSection(title: "DESCRIPTION", lines: body, theme: theme)
    }

    private static func renderArguments(_ arguments: [ArgumentDefinition], theme: HelpTheme?) -> String? {
        guard !arguments.isEmpty else { return nil }
        let rows = arguments.map { argument -> (String, String?) in
            let rawLabel = argument.label.hasSuffix("...") ? String(argument.label.dropLast(3)) : argument.label
            let placeholder = self.kebabCased(rawLabel)
            let rendered = if argument.label.hasSuffix("...") {
                "<\(placeholder)> ..."
            } else if argument.isOptional {
                placeholder
            } else {
                "<\(placeholder)>"
            }
            let label = argument.isOptional ? "[\(rendered)]" : rendered
            return (label, argument.help)
        }
        return self.makeSection(title: "ARGUMENTS", lines: self.renderKeyValueRows(rows, theme: theme), theme: theme)
    }

    private static func renderOptions(_ options: [OptionDefinition], theme: HelpTheme?) -> String? {
        guard !options.isEmpty else { return nil }
        let rows = options.map { option -> (String, String?) in
            let names = option.names
                .filter { !$0.isAlias }
                .map(\.cliSpelling)
                .joined(separator: ", ")
            let valuePlaceholder = " <\(self.optionValuePlaceholder(for: option))>"
            return (names + valuePlaceholder, option.help)
        }
        return self.makeSection(title: "OPTIONS", lines: self.renderKeyValueRows(rows, theme: theme), theme: theme)
    }

    private static func optionValuePlaceholder(for option: OptionDefinition) -> String {
        if let longName = option.names.compactMap(\.primaryLongComponent).first {
            return longName
        }
        return self.kebabCased(self.optionLabel(option.label))
    }

    private static func optionLabel(_ label: String) -> String {
        let suffix = "Option"
        guard label.hasSuffix(suffix), label.count > suffix.count else {
            return label
        }
        return String(label.dropLast(suffix.count))
    }

    private static func kebabCased(_ value: String) -> String {
        guard !value.isEmpty else { return value }
        var output = ""

        for character in value {
            if character.isUppercase {
                if !output.isEmpty, output.last != "-" {
                    output.append("-")
                }
                output.append(contentsOf: character.lowercased())
            } else if character == "_" || character == " " {
                if !output.isEmpty, output.last != "-" {
                    output.append("-")
                }
            } else {
                output.append(character)
            }
        }
        return output
    }

    private static func renderFlags(_ flags: [FlagDefinition], theme: HelpTheme?) -> String? {
        guard !flags.isEmpty else { return nil }
        let rows = flags.map { flag -> (String, String?) in
            let names = flag.names
                .filter { !$0.isAlias }
                .map(\.cliSpelling)
                .joined(separator: ", ")
            return (names, flag.help)
        }
        return self.makeSection(title: "FLAGS", lines: self.renderKeyValueRows(rows, theme: theme), theme: theme)
    }

    private static func renderExamples(_ examples: [CommandUsageExample], theme: HelpTheme?) -> String? {
        guard !examples.isEmpty else { return nil }
        let rows = examples.map { ("$ \($0.command)", $0.description) }
        return self.makeSection(
            title: "USAGE EXAMPLES",
            lines: self.renderKeyValueRows(rows, theme: theme),
            theme: theme
        )
    }

    private static func makeSection(title: String, lines: [String], theme: HelpTheme?) -> String {
        let heading = theme?.heading(title) ?? title
        return ([heading] + lines.map { "  \($0)" }).joined(separator: "\n")
    }

    private static func renderKeyValueRows(_ rows: [(String, String?)], theme: HelpTheme?) -> [String] {
        guard !rows.isEmpty else { return [] }
        let padding = min(max(rows.map(\.0.count).max() ?? 0, 12), 32)
        return rows.map { key, value in
            guard let value, !value.isEmpty else {
                return theme?.command(key) ?? key
            }
            let paddedKey: String = if key.count >= padding {
                key
            } else {
                key + String(repeating: " ", count: padding - key.count)
            }
            let displayKey = theme?.command(paddedKey) ?? paddedKey
            return "\(displayKey)  \(value)"
        }
    }
}

extension ParsableCommand {
    static func helpMessage() -> String {
        MainActor.assumeIsolated {
            CommandHelpRenderer.renderHelp(for: Self.self)
        }
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

    fileprivate var primaryLongComponent: String? {
        switch self {
        case let .long(value):
            value
        case .short, .aliasShort, .aliasLong:
            nil
        }
    }
}
