import Commander
import Foundation

struct CLIProcessStartIdentity: ExpressibleFromArgument, Equatable, Sendable {
    let value: UInt64

    init?(argument: String) {
        let raw = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = UInt64(raw), value > 0 else { return nil }
        self.value = value
    }
}

struct CLIDuration: ExpressibleFromArgument, Equatable, Sendable {
    let milliseconds: Double

    var seconds: TimeInterval {
        self.milliseconds / 1000
    }

    var roundedMilliseconds: Int {
        Int(self.milliseconds.rounded())
    }

    init?(argument: String) {
        let value = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        let number: Substring
        let multiplier: Double

        if value.hasSuffix("ms") {
            number = value.dropLast(2)
            multiplier = 1
        } else if value.hasSuffix("s") {
            number = value.dropLast()
            multiplier = 1000
        } else {
            number = value[...]
            multiplier = 1
        }

        guard !number.isEmpty,
              let parsed = Double(number),
              parsed.isFinite,
              parsed >= 0
        else { return nil }

        let milliseconds = parsed * multiplier
        guard milliseconds.isFinite, Int(exactly: milliseconds.rounded()) != nil else { return nil }
        self.milliseconds = milliseconds
    }

    static func milliseconds(_ value: Double) -> Self {
        Self(milliseconds: value)
    }

    static func seconds(_ value: TimeInterval) -> Self {
        Self(milliseconds: value * 1000)
    }

    private init(milliseconds: Double) {
        self.milliseconds = milliseconds
    }
}

struct CLIModifierList: ExpressibleFromArgument, Equatable, Sendable, CustomStringConvertible {
    let values: [String]

    var description: String {
        self.values.joined(separator: ",")
    }

    init?(argument: String) {
        let aliases = [
            "cmd": "cmd",
            "command": "cmd",
            "shift": "shift",
            "option": "option",
            "alt": "option",
            "ctrl": "ctrl",
            "control": "ctrl",
            "fn": "fn",
        ]
        let parts = argument.split(separator: ",", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var values: [String] = []
        for part in parts {
            let name = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let canonical = aliases[name], !values.contains(canonical) else { return nil }
            values.append(canonical)
        }
        self.values = values
    }
}
