import Foundation
import PeekabooFoundation

public enum DesktopObservationError: Error, LocalizedError, Equatable, CustomStringConvertible {
    case unsupportedTarget(String)
    case targetNotFound(String)
    case targetChanged(String, diagnostic: DesktopObservationTargetChangeDiagnostic? = nil)
    case ambiguousWindowTitle(String, candidates: String)

    public var description: String {
        switch self {
        case let .unsupportedTarget(target):
            "unsupportedTarget(\(String(reflecting: target)))"
        case let .targetNotFound(target):
            "targetNotFound(\(String(reflecting: target)))"
        case let .targetChanged(reason, _):
            "targetChanged(\(String(reflecting: reason)))"
        case let .ambiguousWindowTitle(title, candidates):
            "ambiguousWindowTitle(\(String(reflecting: title)), candidates: \(String(reflecting: candidates)))"
        }
    }

    public var targetChangeDiagnostic: DesktopObservationTargetChangeDiagnostic? {
        guard case let .targetChanged(_, diagnostic) = self else { return nil }
        return diagnostic
    }

    func withPassiveRecovery(_ recovery: DesktopObservationTargetChangeDiagnostic.PassiveRecovery) -> Self {
        guard case let .targetChanged(reason, diagnostic) = self else { return self }
        return .targetChanged(
            reason,
            diagnostic: (diagnostic ?? .init(classification: .unknown, phase: .unknown))
                .withPassiveRecovery(recovery))
    }

    public var errorDescription: String? {
        switch self {
        case let .unsupportedTarget(target):
            "Desktop observation target is not supported yet: \(target)"
        case let .targetNotFound(target):
            "Desktop observation target was not found: \(target)"
        case let .targetChanged(reason, _):
            "Desktop observation target changed during capture: \(reason)"
        case let .ambiguousWindowTitle(title, candidates):
            "Desktop observation window title '\(title)' is ambiguous. Matches: \(candidates). " +
                "Use an exact window ID or index."
        }
    }
}
