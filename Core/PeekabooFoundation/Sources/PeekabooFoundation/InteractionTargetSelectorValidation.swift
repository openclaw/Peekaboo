public enum InteractionTargetSelectorValidationError: Error, Equatable, Sendable {
    case applicationAndProcessIdentifier
    case multipleWindowSelectors
    case windowSelectorRequiresApplication
}

public enum InteractionTargetSelectorValidator {
    public static func validate(
        hasApplication: Bool,
        hasProcessIdentifier: Bool,
        hasWindowID: Bool,
        hasWindowTitle: Bool,
        hasWindowIndex: Bool) throws
    {
        if hasApplication, hasProcessIdentifier {
            throw InteractionTargetSelectorValidationError.applicationAndProcessIdentifier
        }

        let windowSelectorCount = [hasWindowID, hasWindowTitle, hasWindowIndex].count(where: { $0 })
        if windowSelectorCount > 1 {
            throw InteractionTargetSelectorValidationError.multipleWindowSelectors
        }

        if hasWindowTitle || hasWindowIndex, !hasApplication, !hasProcessIdentifier {
            throw InteractionTargetSelectorValidationError.windowSelectorRequiresApplication
        }
    }
}
