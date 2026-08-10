import CoreGraphics
import Foundation
import PeekabooFoundation

extension HotkeyService {
    func makeHotkeyPlan(_ keys: [String]) throws -> HotkeyPlan {
        try HotkeyChord(keys: keys).plan
    }

    func parsedKeys(_ keys: String) throws -> [String] {
        let parsed = keys
            .components(separatedBy: CharacterSet(charactersIn: ",+").union(.whitespacesAndNewlines))
            .map { HotkeyKey.normalizedName(for: $0) }
            .filter { !$0.isEmpty }
        guard !parsed.isEmpty else { throw PeekabooError.invalidInput("Hotkey string is empty") }
        return parsed
    }

    struct HotkeyPlan: Equatable {
        let primaryKey: String
        let keyCode: CGKeyCode
        let modifierFlags: CGEventFlags
    }

    struct HotkeyChord {
        let plan: HotkeyPlan

        init(keys: [String]) throws {
            var modifierFlags: CGEventFlags = []
            var primaryKey: HotkeyPrimaryKey?

            for rawKey in keys {
                let key = HotkeyKey.normalizedName(for: rawKey)
                if let modifierFlag = HotkeyKey.modifierFlag(for: key) {
                    modifierFlags.insert(modifierFlag)
                    continue
                }

                guard let resolvedKey = HotkeyPrimaryKey(key) else {
                    throw PeekabooError.invalidInput("Invalid hotkey: \(keys.joined(separator: "+"))")
                }

                if let existing = primaryKey {
                    throw PeekabooError.invalidInput("Invalid hotkey: \(existing.name)+\(resolvedKey.name)")
                }

                primaryKey = resolvedKey
            }

            guard let primaryKey else {
                throw PeekabooError.invalidInput("Invalid hotkey: \(keys.joined(separator: "+"))")
            }

            self.plan = HotkeyPlan(
                primaryKey: primaryKey.name,
                keyCode: primaryKey.keyCode,
                modifierFlags: modifierFlags)
        }
    }

    enum HotkeyKey {
        static func normalizedName(for rawKey: String) -> String {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return self.aliases[key] ?? key
        }

        static func modifierFlag(for key: String) -> CGEventFlags? {
            switch key {
            case "cmd":
                .maskCommand
            case "shift":
                .maskShift
            case "alt":
                .maskAlternate
            case "ctrl":
                .maskControl
            case "fn":
                .maskSecondaryFn
            default:
                nil
            }
        }

        private static let aliases: [String: String] = [
            "command": "cmd",
            "meta": "cmd",
            "win": "cmd",
            "windows": "cmd",
            "cmdorctrl": "cmd",
            "cmd+ctrl": "cmd",
            "control": "ctrl",
            "option": "alt",
            "opt": "alt",
            "function": "fn",
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
    }

    struct HotkeyPrimaryKey {
        let name: String
        let keyCode: CGKeyCode

        init?(_ key: String) {
            guard let keyCode = Self.keyCodes[key] else {
                return nil
            }

            self.name = key
            self.keyCode = keyCode
        }

        private static let keyCodes: [String: CGKeyCode] = [
            "a": 0x00,
            "s": 0x01,
            "d": 0x02,
            "f": 0x03,
            "h": 0x04,
            "g": 0x05,
            "z": 0x06,
            "x": 0x07,
            "c": 0x08,
            "v": 0x09,
            "b": 0x0B,
            "q": 0x0C,
            "w": 0x0D,
            "e": 0x0E,
            "r": 0x0F,
            "y": 0x10,
            "t": 0x11,
            "1": 0x12,
            "2": 0x13,
            "3": 0x14,
            "4": 0x15,
            "6": 0x16,
            "5": 0x17,
            "equal": 0x18,
            "9": 0x19,
            "7": 0x1A,
            "minus": 0x1B,
            "8": 0x1C,
            "0": 0x1D,
            "rightbracket": 0x1E,
            "o": 0x1F,
            "u": 0x20,
            "leftbracket": 0x21,
            "i": 0x22,
            "p": 0x23,
            "return": 0x24,
            "l": 0x25,
            "j": 0x26,
            "quote": 0x27,
            "k": 0x28,
            "semicolon": 0x29,
            "backslash": 0x2A,
            "comma": 0x2B,
            "slash": 0x2C,
            "n": 0x2D,
            "m": 0x2E,
            "period": 0x2F,
            "tab": 0x30,
            "space": 0x31,
            "grave": 0x32,
            "delete": 0x33,
            "escape": 0x35,
            "capslock": 0x39,
            "clear": 0x47,
            "help": 0x72,
            "home": 0x73,
            "pageup": 0x74,
            "forwarddelete": 0x75,
            "end": 0x77,
            "pagedown": 0x79,
            "f1": 0x7A,
            "left": 0x7B,
            "right": 0x7C,
            "down": 0x7D,
            "up": 0x7E,
            "f2": 0x78,
            "f3": 0x63,
            "f4": 0x76,
            "f5": 0x60,
            "f6": 0x61,
            "f7": 0x62,
            "f8": 0x64,
            "f9": 0x65,
            "f10": 0x6D,
            "f11": 0x67,
            "f12": 0x6F,
        ]
    }
}
