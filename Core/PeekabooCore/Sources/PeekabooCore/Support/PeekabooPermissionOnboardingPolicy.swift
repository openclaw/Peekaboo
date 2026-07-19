public enum PeekabooPermissionOnboardingDecision: Sendable, Equatable {
    case show
    case markComplete
    case skip
}

public enum PeekabooPermissionOnboardingPolicy {
    /// Version 2 reopens the checklist for the 3.9.6 Foundation signing migration.
    public static let currentVersion = 2

    public static func decision(
        seenVersion: Int,
        hasSeen: Bool,
        hasRequiredPermissions: Bool) -> PeekabooPermissionOnboardingDecision
    {
        // The GUI app was already Foundation-signed before version 2, so its grants may remain
        // valid even though direct CLI grants were reset by the CLI's signing-team migration.
        if hasSeen, seenVersion < self.currentVersion {
            return .show
        }
        guard seenVersion < self.currentVersion || !hasSeen else { return .skip }
        return hasRequiredPermissions ? .markComplete : .show
    }
}
