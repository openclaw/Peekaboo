import Foundation

public enum DesktopObservationError: Error, LocalizedError, Equatable {
    case unsupportedTarget(String)
    case targetNotFound(String)
    case ambiguousWindowTitle(String, candidates: String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedTarget(target):
            "Desktop observation target is not supported yet: \(target)"
        case let .targetNotFound(target):
            "Desktop observation target was not found: \(target)"
        case let .ambiguousWindowTitle(title, candidates):
            "Desktop observation window title '\(title)' is ambiguous. Matches: \(candidates). " +
                "Use an exact window ID or index."
        }
    }
}
