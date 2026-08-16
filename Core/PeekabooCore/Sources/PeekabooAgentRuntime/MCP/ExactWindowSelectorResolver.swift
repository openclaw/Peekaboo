import Foundation
import PeekabooAutomationKit

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
    }

    static func select(
        from windows: [ServiceWindowInfo],
        selection: Selection,
        operation: String) throws -> ServiceWindowInfo
    {
        switch selection {
        case .automatic:
            guard let window = ObservationTargetResolver.bestWindow(from: windows) else {
                throw ExactWindowSelectorResolutionError(
                    message: "\(operation) found no eligible window. Refresh the window inventory before retrying.")
            }
            return window

        case let .id(windowID):
            let matches = windows.filter { $0.windowID == windowID }
            guard matches.count == 1, let window = matches.first else {
                let detail = matches.isEmpty ? "does not identify a window" : "identifies multiple windows"
                throw ExactWindowSelectorResolutionError(
                    message: "\(operation) window_id \(windowID) \(detail). " +
                        "Refresh the window inventory before retrying.")
            }
            return window

        case let .title(title):
            let exactMatches = windows.filter {
                $0.title.compare(title, options: .caseInsensitive) == .orderedSame
            }
            if exactMatches.count == 1, let window = exactMatches.first {
                return window
            }
            if exactMatches.count > 1 {
                throw self.ambiguousTitle(title, matches: exactMatches, operation: operation)
            }

            let partialMatches = windows.filter { $0.title.localizedCaseInsensitiveContains(title) }
            guard partialMatches.count == 1, let window = partialMatches.first else {
                if partialMatches.isEmpty {
                    throw ExactWindowSelectorResolutionError(
                        message: "\(operation) found no window whose title matches '\(title)'. " +
                            "Refresh the inventory and select a window_id or valid index.")
                }
                throw self.ambiguousTitle(title, matches: partialMatches, operation: operation)
            }
            return window

        case let .index(index):
            guard index >= 0 else {
                throw ExactWindowSelectorResolutionError(
                    message: "\(operation) window index must be zero or greater.")
            }
            let matches = windows.filter { $0.index == index }
            guard matches.count == 1, let window = matches.first else {
                let detail = matches.isEmpty ? "is not present" : "is ambiguous"
                throw ExactWindowSelectorResolutionError(
                    message: "\(operation) window index \(index) \(detail). " +
                        "Refresh the inventory and select a window_id.")
            }
            return window
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

    private static func ambiguousTitle(
        _ title: String,
        matches: [ServiceWindowInfo],
        operation: String) -> ExactWindowSelectorResolutionError
    {
        let candidates = matches.prefix(5).map { "id=\($0.windowID) index=\($0.index) '\($0.title)'" }
            .joined(separator: "; ")
        return ExactWindowSelectorResolutionError(
            message: "\(operation) window title '\(title)' is ambiguous (\(candidates)). " +
                "Select one window_id or index explicitly.")
    }
}
