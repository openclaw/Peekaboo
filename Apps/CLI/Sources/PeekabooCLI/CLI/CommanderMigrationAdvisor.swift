import Commander
import Foundation

struct CommanderUsageError: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? {
        self.message
    }
}

enum CommanderMigrationAdvisor {
    private static let runtimeFlags: Set<String> = {
        let signature = CommandSignature().withPeekabooRuntimeFlags().flattened()
        return Set(
            signature.options.flatMap { $0.names.map(\.commandLineToken) } +
                signature.flags.flatMap { $0.names.map(\.commandLineToken) }
        )
    }()

    private static let removedRootReplacements: [String: String] = [
        "hotkey": "peekaboo press",
        "swipe": "peekaboo drag",
        "image": "peekaboo see --no-elements",
        "inspect-ui": "peekaboo see --tree --no-screenshot",
        "perform-action": "peekaboo action",
        "sleep": "/bin/sleep",
        "open": "/usr/bin/open, or peekaboo app launch --open <path-or-url> when readiness receipts are needed",
        "run": "a shell script that chains peekaboo commands",
        "commander": "peekaboo --help",
    ]

    private static let removedPathReplacements: [String: String] = [
        "capture watch": "peekaboo capture live",
        "menu click-extra": "peekaboo menubar click",
        "menu list-all": "peekaboo menubar list",
        "agent permission": "peekaboo permissions",
        "config add": "peekaboo config credential set",
        "config add-provider": "peekaboo config provider add",
        "config list-providers": "peekaboo config provider list",
        "config test-provider": "peekaboo config provider test",
        "config remove-provider": "peekaboo config provider remove",
        "config models-provider": "peekaboo config provider models",
        "config set-credential": "peekaboo config credential set",
        "permissions request-accessibility": "peekaboo permissions request accessibility",
        "permissions request-screen-recording": "peekaboo permissions request screen-recording",
        "permissions request-event-synthesizing": "peekaboo permissions request event-synthesizing",
    ]

    private static let removedOptionReplacements: [String: String] = [
        "--app-target": "--app",
        "--autoclean-minutes": "--autoclean",
        "--coords": "--at",
        "--delay-ms": "--delay",
        "--diff-budget-ms": "--diff-budget",
        "--end-ms": "--end",
        "--every-ms": "--every",
        "--focus-timeout-seconds": "--focus-timeout",
        "--from-coords": "--from",
        "--global-coords": "--global",
        "--heartbeat-sec": "--heartbeat",
        "--hold-duration": "--hold",
        "--id": "--on",
        "--idle-timeout-seconds": "--idle-timeout",
        "--image-path": "--file-path",
        "--keys": "positional xdotool chord syntax (for example, peekaboo press cmd+c --foreground)",
        "--label": "positional query text or --on",
        "--max-depth": "--depth",
        "--poll-interval-ms": "--poll-interval",
        "--post-roll-ms": "--post-roll",
        "--pre-roll-ms": "--pre-roll",
        "--quiet-ms": "--quiet",
        "--repeat": "--count",
        "--restore-delay-ms": "--restore-delay",
        "--start-ms": "--start",
        "--ticks": "--amount",
        "--timeout-seconds": "--timeout",
        "--to-coords": "--to",
        "--wait-seconds": "--wait",
    ]

    private static let removedAgentModeReplacements: [String: String] = [
        "--chat": "peekaboo agent chat",
        "--list-sessions": "peekaboo agent sessions",
        "--resume": "peekaboo agent resume",
        "--resume-session": "peekaboo agent resume <session-id>",
    ]

    private static let removedTypeKeyReplacements = Set(["--delete", "--escape", "--return", "--tab"])

    static func commandError(for arguments: [String]) -> CommanderUsageError? {
        guard !arguments.isEmpty else { return nil }

        if self.runtimeFlags.contains(arguments[0]) {
            return CommanderUsageError(
                message: "Runtime flags must follow the leaf command. " +
                    "Use 'peekaboo see --json' or 'peekaboo window list --json'."
            )
        }

        let commandTokens = arguments[0] == "help" ? Array(arguments.dropFirst()) : arguments
        guard let root = commandTokens.first else { return nil }

        if root == "list" {
            return Self.removedListError(tokens: commandTokens)
        }

        if let replacement = Self.removedRootReplacements[root] {
            return Self.removedSyntaxError(syntax: "peekaboo \(root)", replacement: replacement)
        }

        if commandTokens.count >= 2 {
            let path = commandTokens.prefix(2).joined(separator: " ")
            if let replacement = Self.removedPathReplacements[path] {
                return Self.removedSyntaxError(syntax: "peekaboo \(path)", replacement: replacement)
            }
        }

        return nil
    }

    static func optionError(for arguments: [String]) -> CommanderUsageError? {
        let tokens = Array(arguments.prefix { $0 != "--" })
        guard let root = tokens.first else { return nil }

        if root == "clipboard", tokens.contains("--action") || tokens.contains("-a") {
            return CommanderUsageError(
                message: "Clipboard action options were removed in v4. " +
                    "Use 'peekaboo clipboard get|set|clear|save|restore'."
            )
        }

        if root == "agent" {
            for token in tokens {
                let option = Self.optionName(from: token)
                if let replacement = Self.removedAgentModeReplacements[option] {
                    return Self.removedOptionError(option: option, replacement: replacement)
                }
            }
        }

        if root == "type" {
            for token in tokens {
                let option = Self.optionName(from: token)
                if Self.removedTypeKeyReplacements.contains(option) {
                    let key = String(option.dropFirst(2)).capitalized
                    return Self.removedOptionError(
                        option: option,
                        replacement: "peekaboo press \(key) --foreground"
                    )
                }
            }
        }

        for token in tokens {
            let option = Self.optionName(from: token)
            if let replacement = Self.removedOptionReplacements[option] {
                return Self.removedOptionError(option: option, replacement: replacement)
            }
        }

        return nil
    }

    private static func removedListError(tokens: [String]) -> CommanderUsageError {
        let replacement = switch tokens.dropFirst().first {
        case "apps": "peekaboo app list"
        case "windows": "peekaboo window list"
        case "screens": "peekaboo screen list"
        case "menubar": "peekaboo menubar list"
        case "permissions": "peekaboo permissions status"
        default: "peekaboo app list, peekaboo window list, or peekaboo screen list"
        }
        return Self.removedSyntaxError(syntax: "peekaboo list", replacement: replacement)
    }

    private static func removedSyntaxError(syntax: String, replacement: String) -> CommanderUsageError {
        CommanderUsageError(message: "Command '\(syntax)' was removed in v4. Use '\(replacement)'.")
    }

    private static func removedOptionError(option: String, replacement: String) -> CommanderUsageError {
        CommanderUsageError(message: "Option '\(option)' was removed in v4. Use '\(replacement)'.")
    }

    private static func optionName(from token: String) -> String {
        String(token.prefix { $0 != "=" })
    }
}
