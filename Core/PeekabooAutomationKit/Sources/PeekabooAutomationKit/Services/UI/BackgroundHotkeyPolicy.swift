import CoreGraphics
import Foundation
import PeekabooFoundation

/// Rejects process-targeted shortcuts whose effects cannot be verified at the keyboard-event boundary.
public enum BackgroundHotkeyPolicy {
    /// Validates that a hotkey is safe to report as delivered in the background.
    ///
    /// Process-targeted CoreGraphics events have no acknowledgement from the receiving app. Lifecycle and
    /// window-management shortcuts therefore use Peekaboo's semantic commands, which can verify their effects.
    public static func validate(keys: String) throws {
        let parsedKeys = try Self.parsedKeys(keys)
        let plan = try HotkeyService.HotkeyChord(keys: parsedKeys).plan

        guard plan.modifierFlags == .maskCommand,
              let alternative = Self.semanticAlternative(for: plan.primaryKey)
        else {
            return
        }

        let chord = "Cmd+\(plan.primaryKey.uppercased())"
        throw PeekabooError.invalidInput(
            "Background \(chord) cannot be verified after process-targeted delivery. " +
                "Use `\(alternative)` for verified background behavior, or add `--foreground` " +
                "to send \(chord) explicitly.")
    }

    private static func parsedKeys(_ keys: String) throws -> [String] {
        let parsed = keys
            .components(separatedBy: CharacterSet(charactersIn: ",+").union(.whitespacesAndNewlines))
            .map { HotkeyService.HotkeyKey.normalizedName(for: $0) }
            .filter { !$0.isEmpty }
        guard !parsed.isEmpty else {
            throw PeekabooError.invalidInput("Hotkey string is empty")
        }
        return parsed
    }

    private static func semanticAlternative(for primaryKey: String) -> String? {
        switch primaryKey {
        case "w":
            "peekaboo window close --app <app>"
        case "q":
            "peekaboo app quit --app <app>"
        case "h":
            "peekaboo app hide --app <app>"
        case "m":
            "peekaboo window minimize --app <app>"
        default:
            nil
        }
    }
}
