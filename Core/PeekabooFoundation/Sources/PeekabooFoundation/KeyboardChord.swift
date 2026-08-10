import Foundation

/// A single xdotool-style keyboard chord such as `cmd+shift+t` or `Return`.
public struct KeyboardChord: Sendable, Equatable {
    public let keys: [String]

    public var serviceKeys: String {
        self.keys.joined(separator: ",")
    }

    public var displayValue: String {
        self.keys.joined(separator: "+")
    }

    public init(parsing value: String) throws {
        let parts = value
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else {
            throw KeyboardChordError.invalid(value)
        }

        let primary = Self.normalizedPrimaryKey(parts[parts.count - 1])
        guard Self.primaryKeys.contains(primary) else {
            throw KeyboardChordError.invalid(value)
        }

        var modifiers: [String] = []
        for rawModifier in parts.dropLast() {
            guard let modifier = Self.modifierAliases[rawModifier], !modifiers.contains(modifier) else {
                throw KeyboardChordError.invalid(value)
            }
            modifiers.append(modifier)
        }

        self.keys = modifiers + [primary]
    }

    private static func normalizedPrimaryKey(_ value: String) -> String {
        self.primaryAliases[value] ?? value
    }

    private static let modifierAliases: [String: String] = [
        "cmd": "cmd",
        "command": "cmd",
        "shift": "shift",
        "option": "alt",
        "alt": "alt",
        "ctrl": "ctrl",
        "control": "ctrl",
        "fn": "fn",
    ]

    private static let primaryAliases: [String: String] = [
        "enter": "return",
        "esc": "escape",
        "backspace": "delete",
        "del": "delete",
        "spacebar": "space",
        "page_up": "pageup",
        "page_down": "pagedown",
        "forward_delete": "forwarddelete",
        "arrow_left": "left",
        "arrow_right": "right",
        "arrow_down": "down",
        "arrow_up": "up",
        "left_bracket": "leftbracket",
        "[": "leftbracket",
        "right_bracket": "rightbracket",
        "]": "rightbracket",
        "=": "equal",
        "-": "minus",
        "'": "quote",
        ";": "semicolon",
        "\\": "backslash",
        ",": "comma",
        "/": "slash",
        ".": "period",
        "`": "grave",
        "caps_lock": "capslock",
    ]

    private static let primaryKeys: Set<String> = {
        var keys = Set([
            "return", "tab", "space", "delete", "escape", "capslock", "clear", "help", "home", "pageup",
            "forwarddelete", "end", "pagedown", "left", "right", "down", "up", "equal", "minus",
            "rightbracket", "leftbracket", "quote", "semicolon", "backslash", "comma", "slash", "period", "grave",
        ])
        keys.formUnion((1...12).map { "f\($0)" })
        keys.formUnion("abcdefghijklmnopqrstuvwxyz".map(String.init))
        keys.formUnion((0...9).map(String.init))
        return keys
    }()
}

public enum KeyboardChordError: LocalizedError, Sendable, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(value):
            "Invalid chord '\(value)'. Use xdotool key syntax such as cmd+shift+t or Return."
        }
    }
}
