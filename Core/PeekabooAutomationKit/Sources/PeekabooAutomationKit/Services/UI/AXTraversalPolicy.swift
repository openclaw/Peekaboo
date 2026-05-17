import Foundation

/// Centralized caps for AX-tree traversal during `peekaboo see` and related element lookups.
///
/// The three integer limits below default to values tuned for typical desktop apps, but can be
/// overridden at process start via environment variables:
///
///   - `PEEKABOO_MAX_TRAVERSAL_DEPTH`   (default 12)
///   - `PEEKABOO_MAX_ELEMENT_COUNT`     (default 400)
///   - `PEEKABOO_MAX_CHILDREN_PER_NODE` (default 50)
///
/// Set the children-per-node cap higher when an app uses a flat container layout with many
/// sibling widgets (e.g. Qt or Electron apps where a single panel hosts > 50 direct children
/// — sliders/buttons past the 50th will otherwise be silently dropped from the tree).
///
/// Any non-positive, missing, or unparseable env value falls back to the default. Values are
/// read once on first access (Swift's `static let` is lazy), so set the env before launching
/// the binary that hosts Peekaboo.
@_spi(Testing) public enum AXTraversalPolicy {
    static let maxTraversalDepth: Int = Self.intFromEnv(
        "PEEKABOO_MAX_TRAVERSAL_DEPTH", default: 12)
    static let maxElementCount: Int = Self.intFromEnv(
        "PEEKABOO_MAX_ELEMENT_COUNT", default: 400)
    static let maxChildrenPerNode: Int = Self.intFromEnv(
        "PEEKABOO_MAX_CHILDREN_PER_NODE", default: 50)

    private static let maxWebFocusAttempts = 2
    private static let maxElementsBeforeWebFocusFallback = 20

    public static func shouldAttemptWebFocusFallback(
        attempt: Int,
        allowWebFocus: Bool,
        detectedElementCount: Int,
        hasTextField: Bool) -> Bool
    {
        guard !hasTextField else { return false }

        return attempt < self.maxWebFocusAttempts
            && allowWebFocus
            && detectedElementCount <= self.maxElementsBeforeWebFocusFallback
    }

    /// Reads a positive integer from the environment, falling back to `defaultValue` for any
    /// missing, blank, non-numeric, or non-positive value.
    @_spi(Testing) public static func intFromEnv(_ key: String, default defaultValue: Int) -> Int {
        guard
            let raw = ProcessInfo.processInfo.environment[key],
            let parsed = Int(raw.trimmingCharacters(in: .whitespaces)),
            parsed > 0
        else { return defaultValue }
        return parsed
    }
}
