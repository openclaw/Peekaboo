import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

struct ExactWindowSelectorResolutionError: Error, LocalizedError, Sendable, Equatable {
    let message: String

    var errorDescription: String? {
        self.message
    }
}

/// Resolves compatibility window selectors without silently choosing among ambiguous matches.
enum ExactWindowSelectorResolver {
    enum Selection: Sendable, Equatable {
        case automatic
        case id(Int)
        case title(String)
        case index(Int)

        var explicitSelector: InteractionTargetSelector.WindowSelector? {
            switch self {
            case .automatic: nil
            case let .id(windowID): .id(windowID)
            case let .title(title): .title(title)
            case let .index(index): .index(index)
            }
        }
    }

    static func select(
        from windows: [ServiceWindowInfo],
        selection: Selection,
        operation: String) throws -> ServiceWindowInfo
    {
        guard let explicitSelector = selection.explicitSelector else {
            guard let window = ObservationTargetResolver.bestWindow(from: windows) else {
                throw ExactWindowSelectorResolutionError(
                    message: "\(operation) found no eligible window. Refresh the window inventory before retrying.")
            }
            return window
        }
        if case let .index(index) = explicitSelector, index < 0 {
            throw ExactWindowSelectorResolutionError(
                message: "\(operation) window index must be zero or greater.")
        }
        do {
            return try DesktopTargetPlanning.WindowCandidateSelector.selectExplicitCandidate(
                candidates: windows,
                selector: explicitSelector)
        } catch let error as DesktopTargetPlanningError {
            throw self.presentationError(
                error,
                selector: explicitSelector,
                windows: windows,
                operation: operation)
        }
    }

    static func selection(for target: WindowTarget) -> Selection {
        switch target {
        case .application, .frontmost:
            .automatic
        case let .title(title), let .applicationAndTitle(_, title):
            .title(title)
        case let .index(_, index):
            .index(index)
        case let .windowId(windowID):
            .id(windowID)
        }
    }

    private static func presentationError(
        _ error: DesktopTargetPlanningError,
        selector: InteractionTargetSelector.WindowSelector,
        windows: [ServiceWindowInfo],
        operation: String) -> ExactWindowSelectorResolutionError
    {
        if case let .conflictingWindowEntries(windowID) = error {
            return self.inventoryConflictError(
                windowID: windowID,
                windows: windows,
                operation: operation)
        }
        return switch (selector, error) {
        case let (.id(windowID), .windowNotFound):
            ExactWindowSelectorResolutionError(
                message: "\(operation) window_id \(windowID) does not identify a window. " +
                    "Refresh the window inventory before retrying.")
        case let (.id(windowID), .ambiguousWindow):
            ExactWindowSelectorResolutionError(
                message: "\(operation) window_id \(windowID) identifies multiple windows. " +
                    "Refresh the window inventory before retrying.")
        case let (.title(title), .windowNotFound):
            ExactWindowSelectorResolutionError(
                message: "\(operation) found no window whose title matches '\(title)'. " +
                    "Refresh the inventory and select a window_id or valid index.")
        case let (.title(title), .ambiguousWindow(_, windowIDs)):
            self.titleAmbiguityError(
                title: title,
                windowIDs: windowIDs,
                windows: windows,
                operation: operation)
        case let (.index(index), .windowNotFound):
            ExactWindowSelectorResolutionError(
                message: "\(operation) window index \(index) is not present. " +
                    "Refresh the inventory and select a window_id.")
        case let (.index(index), .ambiguousWindow):
            ExactWindowSelectorResolutionError(
                message: "\(operation) window index \(index) is ambiguous. " +
                    "Refresh the inventory and select a window_id.")
        default:
            ExactWindowSelectorResolutionError(
                message: "\(operation) could not resolve one exact window. \(error.localizedDescription)")
        }
    }

    private static func titleAmbiguityError(
        title: String,
        windowIDs: [Int],
        windows: [ServiceWindowInfo],
        operation: String) -> ExactWindowSelectorResolutionError
    {
        let candidates = self.candidateSummary(windowIDs: windowIDs, windows: windows)
        return ExactWindowSelectorResolutionError(
            message: "\(operation) window title '\(title)' is ambiguous (\(candidates)). " +
                "Select one window_id or index explicitly.")
    }

    private static func inventoryConflictError(
        windowID: Int,
        windows: [ServiceWindowInfo],
        operation: String) -> ExactWindowSelectorResolutionError
    {
        let candidates = self.candidateSummary(windowIDs: [windowID], windows: windows)
        return ExactWindowSelectorResolutionError(
            message: "\(operation) found conflicting inventory rows for window ID \(windowID) (\(candidates)). " +
                "Refresh the window inventory before retrying.")
    }

    private static func candidateSummary(
        windowIDs: [Int],
        windows: [ServiceWindowInfo]) -> String
    {
        let candidateIDs = Set(windowIDs)
        return windows.lazy.filter { candidateIDs.contains($0.windowID) }
            .sorted { lhs, rhs in
                if lhs.windowID != rhs.windowID {
                    return lhs.windowID < rhs.windowID
                }
                if lhs.index != rhs.index {
                    return lhs.index < rhs.index
                }
                return lhs.title < rhs.title
            }
            .prefix(5)
            .map { "id=\($0.windowID) index=\($0.index) '\($0.title)'" }
            .joined(separator: "; ")
    }
}
