import Foundation

/// Classifies named Accessibility actions that can surface or raise foreground UI.
public enum AccessibilityActionPolicy {
    public enum Classification: Equatable, Sendable {
        case backgroundSafe
        case foregroundCapable
        case unclassified

        public var requiresForegroundConsent: Bool {
            self != .backgroundSafe
        }
    }

    public static func classification(_ actionName: String) -> Classification {
        let canonical = self.canonicalActionName(actionName)
        if self.backgroundSafeActions.contains(canonical) {
            return .backgroundSafe
        }
        if self.foregroundCapableActions.contains(canonical) {
            return .foregroundCapable
        }
        return .unclassified
    }

    public static func requiresForegroundConsent(_ actionName: String) -> Bool {
        self.classification(actionName).requiresForegroundConsent
    }

    private static func canonicalActionName(_ actionName: String) -> String {
        let normalized = actionName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("ax") ? String(normalized.dropFirst(2)) : normalized
    }

    private static let backgroundSafeActions: Set<String> = [
        "decrement",
        "increment",
    ]

    private static let foregroundCapableActions: Set<String> = [
        "cancel",
        "confirm",
        "open",
        "pick",
        "press",
        "raise",
        "scrolltovisible",
        "showalternateui",
        "showdefaultui",
        "showmenu",
    ]
}
