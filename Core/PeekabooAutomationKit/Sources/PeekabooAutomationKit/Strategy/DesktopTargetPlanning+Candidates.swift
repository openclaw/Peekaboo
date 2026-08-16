import CoreGraphics
import Foundation
import PeekabooFoundation

public enum DesktopTargetPlanningError: LocalizedError, Equatable, Sendable {
    case invalidSelector(InteractionTargetSelector.ValidationError)
    case missingApplicationTarget
    case applicationNotFound(identifier: String, candidatePIDs: [Int32])
    case ambiguousApplication(identifier: String, candidatePIDs: [Int32])
    case unsupportedApplicationIdentifier(identifier: String, candidatePIDs: [Int32])
    case missingProcessIdentity(processIdentifier: Int32)
    case invalidProcessIdentity(processIdentifier: Int32, processStartIdentity: UInt64)
    case staleApplication(expected: ApplicationProcessIdentity)
    case incompleteApplicationInventory(identifier: String, warnings: [String])
    case applicationInventoryUnavailable(identifier: String)
    case windowNotFound(selector: String, candidateWindowIDs: [Int])
    case ambiguousWindow(selector: String, candidateWindowIDs: [Int])
    case conflictingWindowEntries(windowID: Int)
    case missingWindowIdentity(windowID: Int)
    case incompleteWindowIdentity(windowID: Int)
    case windowOwnerMismatch(windowID: Int, expected: ApplicationProcessIdentity)
    case staleWindow(expected: WindowMutationIdentity)
    case incompleteWindowInventory(selector: String, warnings: [String])
    case windowInventoryUnavailable(selector: String)
    case invalidWindowInventory(selector: String, reason: String)
    case unsupportedGlobalWindowTitle
    case unsupportedFrontmostTarget

    public var errorDescription: String? {
        switch self {
        case let .invalidSelector(error):
            Self.selectorMessage(error)
        case .missingApplicationTarget:
            "A mutation-safe application target is required."
        case let .applicationNotFound(identifier, candidatePIDs):
            Self.candidateMessage(
                "No running application exactly matched '\(identifier)'.",
                pids: candidatePIDs)
        case let .ambiguousApplication(identifier, candidatePIDs):
            Self.candidateMessage(
                "Application target '\(identifier)' matched more than one running process.",
                pids: candidatePIDs)
        case let .unsupportedApplicationIdentifier(identifier, candidatePIDs):
            Self.candidateMessage(
                "Application target '\(identifier)' is only an executable-name or fuzzy match, which is not " +
                    "allowed for mutation.",
                pids: candidatePIDs)
        case let .missingProcessIdentity(processIdentifier):
            "Application PID \(processIdentifier) did not include a process-generation receipt."
        case let .invalidProcessIdentity(processIdentifier, processStartIdentity):
            "Application identity PID \(processIdentifier), generation \(processStartIdentity) is invalid."
        case let .staleApplication(expected):
            "Application PID \(expected.processIdentifier) disappeared or changed process generation."
        case let .incompleteApplicationInventory(identifier, warnings):
            Self.inventoryMessage(
                "Application inventory was incomplete while resolving '\(identifier)'.",
                warnings: warnings)
        case let .applicationInventoryUnavailable(identifier):
            "Application inventory was unavailable while resolving '\(identifier)'."
        case let .windowNotFound(selector, candidateWindowIDs):
            Self.windowCandidateMessage("No window matched \(selector).", windowIDs: candidateWindowIDs)
        case let .ambiguousWindow(selector, candidateWindowIDs):
            Self.windowCandidateMessage(
                "Window target \(selector) matched more than one window.",
                windowIDs: candidateWindowIDs)
        case let .conflictingWindowEntries(windowID):
            "Window inventory contained contradictory receipts for window \(windowID)."
        case let .missingWindowIdentity(windowID):
            "Window \(windowID) did not include a process-generation mutation receipt."
        case let .incompleteWindowIdentity(windowID):
            "Window \(windowID) did not include complete ID, owner-generation, and bounds evidence."
        case let .windowOwnerMismatch(windowID, expected):
            "Window \(windowID) is not owned by selected application PID \(expected.processIdentifier) " +
                "and its exact process generation."
        case let .staleWindow(expected):
            "Window \(expected.windowID) disappeared or changed ID, owner generation, or bounds."
        case let .incompleteWindowInventory(selector, warnings):
            Self.inventoryMessage(
                "Window inventory was incomplete while resolving \(selector).",
                warnings: warnings)
        case let .windowInventoryUnavailable(selector):
            "Window inventory was unavailable while resolving \(selector)."
        case let .invalidWindowInventory(selector, reason):
            "Window inventory was invalid while resolving \(selector): \(reason)"
        case .unsupportedGlobalWindowTitle:
            "Window title and index mutations require an application or PID owner."
        case .unsupportedFrontmostTarget:
            "This planner does not permit an implicit frontmost mutation target."
        }
    }

    public var refusalReason: DesktopActionOutcome.RefusalReason {
        switch self {
        case .invalidSelector, .missingApplicationTarget, .unsupportedGlobalWindowTitle, .unsupportedFrontmostTarget:
            .invalidRequest
        default:
            .targetUnavailable
        }
    }

    public var hint: String {
        switch self {
        case .invalidSelector, .missingApplicationTarget, .unsupportedGlobalWindowTitle, .unsupportedFrontmostTarget:
            "Correct the target selector before retrying."
        case .ambiguousApplication, .unsupportedApplicationIdentifier:
            "Choose one exact PID from a fresh application inventory."
        case .ambiguousWindow:
            "Choose one exact window ID from a fresh window inventory."
        default:
            "Refresh the target inventory and retry with its exact PID, process generation, and window ID."
        }
    }

    public var desktopActionFailure: DesktopActionFailure {
        .preDispatchRefusal(
            reason: self.refusalReason,
            message: self.localizedDescription,
            hint: self.hint)
    }

    private static func selectorMessage(_ error: InteractionTargetSelector.ValidationError) -> String {
        switch error {
        case .applicationAndProcessIdentifier:
            "Provide an application either by identifier or PID, not both."
        case let .conflictingProcessIdentifiers(application, explicit):
            "Application PID \(application) conflicts with explicit PID \(explicit)."
        case .invalidApplicationProcessIdentifier:
            "The application PID selector is invalid."
        case .multipleWindowSelectors:
            "Provide only one of window ID, title, or index."
        case .windowSelectorRequiresApplication:
            "Window title and index mutations require an application or PID owner."
        case .missingTarget:
            "A mutation target is required."
        case .emptyApplication:
            "Application must not be empty."
        case .emptyWindowTitle:
            "Window title must not be empty."
        case .invalidProcessIdentifier:
            "PID must be a positive 32-bit integer."
        case .invalidWindowID:
            "Window ID must be a positive 32-bit integer."
        case .invalidWindowIndex:
            "Window index must be zero or greater."
        }
    }

    private static func candidateMessage(_ message: String, pids: [Int32]) -> String {
        guard !pids.isEmpty else { return message + " Use an exact PID target." }
        return message + " Candidate PIDs: " + pids.map(String.init).joined(separator: ", ") + "."
    }

    private static func windowCandidateMessage(_ message: String, windowIDs: [Int]) -> String {
        guard !windowIDs.isEmpty else { return message + " Use an exact window ID." }
        return message + " Candidate window IDs: " + windowIDs.map(String.init).joined(separator: ", ") + "."
    }

    private static func inventoryMessage(_ message: String, warnings: [String]) -> String {
        guard !warnings.isEmpty else { return message }
        return message + " " + warnings.joined(separator: "; ")
    }
}

extension DesktopTargetPlanning {
    /// Inventory rows plus the provider's completeness evidence.
    ///
    /// Mutation planners must not infer uniqueness from a partial catalog. Exact PID and window-ID
    /// selectors can bypass a partial catalog only when their provider performed a direct lookup.
    public struct Inventory<Element: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
        public enum Completeness: String, Codable, Equatable, Sendable {
            case complete
            case partial
        }

        public let items: [Element]
        public let completeness: Completeness
        public let warnings: [String]

        public init(
            items: [Element],
            completeness: Completeness,
            warnings: [String] = [])
        {
            self.items = items
            self.completeness = completeness
            self.warnings = warnings
        }

        public static func complete(_ items: [Element]) -> Self {
            Self(items: items, completeness: .complete)
        }

        public static func partial(_ items: [Element], warnings: [String]) -> Self {
            Self(items: items, completeness: .partial, warnings: warnings)
        }

        public var isComplete: Bool {
            self.completeness == .complete && self.warnings.isEmpty
        }
    }

    struct ApplicationSelection: Equatable, Sendable {
        let index: Int
        let resolution: ApplicationIdentifierMatcher.Resolution
    }

    enum ApplicationMutationSelector {
        static func normalizedIdentifier(_ rawIdentifier: String) throws -> String {
            let identifier = ApplicationIdentifierMatcher.normalized(rawIdentifier)
            guard !identifier.isEmpty else {
                throw DesktopTargetPlanningError.invalidSelector(.emptyApplication)
            }
            if identifier.uppercased().hasPrefix("PID:") {
                guard let pid = Int32(identifier.dropFirst(4)), pid > 0 else {
                    throw DesktopTargetPlanningError.invalidSelector(.invalidApplicationProcessIdentifier)
                }
            }
            return identifier
        }

        static func select(
            identifier: String,
            applications: [ServiceApplicationInfo]) throws -> ApplicationSelection
        {
            let identifier = try self.normalizedIdentifier(identifier)

            let candidates = applications.map(ApplicationIdentifierMatcher.Candidate.init)
            let resolution: ApplicationIdentifierMatcher.Resolution?
            do {
                resolution = try ApplicationIdentifierMatcher.resolution(
                    for: identifier,
                    in: candidates)
            } catch {
                throw DesktopTargetPlanningError.applicationInventoryUnavailable(identifier: identifier)
            }
            guard let resolution else {
                throw DesktopTargetPlanningError.applicationNotFound(identifier: identifier, candidatePIDs: [])
            }
            let matchingPIDs = candidates.enumerated().compactMap { index, candidate -> Int32? in
                guard ApplicationIdentifierMatcher.matchKind(for: candidate, identifier: identifier) ==
                    resolution.matchKind
                else { return nil }
                return candidates[index].processIdentifier
            }
            let candidatePIDs = Array(Set(matchingPIDs)).sorted()

            switch resolution.matchKind {
            case .processIdentifier:
                break
            case .bundleIdentifier:
                break
            case .exactName:
                break
            case .bundlePath, .exactExecutable, .fuzzyNameOrExecutable:
                throw DesktopTargetPlanningError.unsupportedApplicationIdentifier(
                    identifier: identifier,
                    candidatePIDs: candidatePIDs)
            case .windowID, .windowIndex, .exactWindowTitle, .partialWindowTitle, .automaticWindowRank:
                throw DesktopTargetPlanningError.applicationInventoryUnavailable(identifier: identifier)
            }
            guard !resolution.hasWinningTie else {
                throw DesktopTargetPlanningError.ambiguousApplication(
                    identifier: identifier,
                    candidatePIDs: candidatePIDs)
            }
            return ApplicationSelection(index: resolution.index, resolution: resolution)
        }
    }

    public enum WindowMutationIntent: Equatable, Sendable {
        case general
        case restore
    }

    public enum WindowSelectionPolicy: Equatable, Sendable {
        case explicit
        case preferredMutationWindow(WindowMutationIntent)
    }

    public enum WindowMutationSelection: Equatable, Sendable {
        case automatic
        case id(Int)
        case title(String)
        case index(Int)
    }

    public enum WindowCandidateSelector {
        public static func select(
            candidates: [ServiceWindowInfo],
            selector: InteractionTargetSelector.WindowSelector?,
            policy: WindowSelectionPolicy,
            expectedOwner: ApplicationProcessIdentity? = nil) throws -> ServiceWindowInfo
        {
            let canonical = try self.canonicalizedCandidates(candidates)
            let selected: ServiceWindowInfo
            switch selector {
            case let .id(windowID):
                selected = try self.selectUniqueID(
                    windowID,
                    from: canonical,
                    selector: "window ID \(windowID)")
            case let .title(title):
                selected = try self.selectTitle(title, from: canonical)
            case let .index(index):
                selected = try self.selectIndex(index, from: canonical)
            case nil:
                guard case let .preferredMutationWindow(intent) = policy else {
                    throw DesktopTargetPlanningError.windowNotFound(
                        selector: "an explicit window selector",
                        candidateWindowIDs: self.windowIDs(canonical))
                }
                guard let best = canonical.min(by: { lhs, rhs in
                    self.isPreferredMutationWindow(lhs, rhs, intent: intent)
                }) else {
                    throw DesktopTargetPlanningError.windowNotFound(
                        selector: "the application's best window",
                        candidateWindowIDs: self.windowIDs(canonical))
                }
                selected = best
            }
            try self.validate(selected, expectedOwner: expectedOwner)
            return selected
        }

        private static func selectTitle(
            _ title: String,
            from candidates: [ServiceWindowInfo]) throws -> ServiceWindowInfo
        {
            let exact = candidates.filter {
                $0.title.compare(title, options: .caseInsensitive) == .orderedSame
            }
            if !exact.isEmpty {
                return try self.selectOneWindowID(exact, selector: "title '\(title)'")
            }
            let partial = candidates.filter { $0.title.localizedCaseInsensitiveContains(title) }
            return try self.selectOneWindowID(partial, selector: "title containing '\(title)'")
        }

        private static func selectIndex(
            _ index: Int,
            from candidates: [ServiceWindowInfo]) throws -> ServiceWindowInfo
        {
            let normalizedMatches = candidates.filter { $0.index == index }
            if !normalizedMatches.isEmpty {
                return try self.selectOneWindowID(normalizedMatches, selector: "index \(index)")
            }
            throw DesktopTargetPlanningError.windowNotFound(
                selector: "index \(index)",
                candidateWindowIDs: self.windowIDs(candidates))
        }

        private static func selectOneWindowID(
            _ candidates: [ServiceWindowInfo],
            selector: String) throws -> ServiceWindowInfo
        {
            let ids = self.windowIDs(candidates)
            guard let id = ids.first else {
                throw DesktopTargetPlanningError.windowNotFound(selector: selector, candidateWindowIDs: [])
            }
            guard ids.count == 1 else {
                throw DesktopTargetPlanningError.ambiguousWindow(
                    selector: selector,
                    candidateWindowIDs: ids)
            }
            return try self.selectUniqueID(id, from: candidates, selector: selector)
        }

        private static func selectUniqueID(
            _ windowID: Int,
            from candidates: [ServiceWindowInfo],
            selector: String) throws -> ServiceWindowInfo
        {
            let matches = candidates.filter { $0.windowID == windowID }
            guard !matches.isEmpty else {
                throw DesktopTargetPlanningError.windowNotFound(
                    selector: selector,
                    candidateWindowIDs: self.windowIDs(candidates))
            }
            return try self.canonical(matches)
        }

        static func canonicalizedCandidates(_ candidates: [ServiceWindowInfo]) throws -> [ServiceWindowInfo] {
            let grouped = Dictionary(grouping: candidates, by: \.windowID)
            return try grouped.keys.sorted().map { windowID in
                guard let group = grouped[windowID] else {
                    preconditionFailure("Grouped window inventory lost window \(windowID)")
                }
                return try self.canonical(group)
            }
        }

        private static func canonical(_ candidates: [ServiceWindowInfo]) throws -> ServiceWindowInfo {
            guard let windowID = candidates.first?.windowID,
                  candidates.allSatisfy({ $0.windowID == windowID })
            else {
                preconditionFailure("Window canonicalization requires one window ID")
            }
            let identities = candidates.compactMap(\.mutationIdentity)
            if identities.count != candidates.count, !identities.isEmpty {
                throw DesktopTargetPlanningError.conflictingWindowEntries(windowID: windowID)
            }
            if candidates.count > 1,
               let firstIdentity = identities.first,
               candidates.contains(where: { candidate in
                   guard let identity = candidate.mutationIdentity else { return true }
                   return !identity.hasSameStableReceipt(as: firstIdentity) ||
                       identity.windowID != candidate.windowID ||
                       identity.capturedBounds != candidate.bounds
               })
            {
                throw DesktopTargetPlanningError.conflictingWindowEntries(windowID: windowID)
            }
            if let first = candidates.first,
               candidates.contains(where: { $0.title != first.title || $0.index != first.index })
            {
                throw DesktopTargetPlanningError.conflictingWindowEntries(windowID: windowID)
            }
            return candidates.sorted(by: self.isPreferredCanonicalWindow)[0]
        }

        private static func isPreferredCanonicalWindow(
            _ lhs: ServiceWindowInfo,
            _ rhs: ServiceWindowInfo) -> Bool
        {
            if (lhs.mutationIdentity != nil) != (rhs.mutationIdentity != nil) {
                return lhs.mutationIdentity != nil
            }
            if lhs.isMinimized != rhs.isMinimized {
                return !lhs.isMinimized
            }
            if lhs.index != rhs.index {
                return lhs.index < rhs.index
            }
            if lhs.title != rhs.title {
                return lhs.title < rhs.title
            }
            return lhs.windowID < rhs.windowID
        }

        private static func isPreferredMutationWindow(
            _ lhs: ServiceWindowInfo,
            _ rhs: ServiceWindowInfo,
            intent: WindowMutationIntent) -> Bool
        {
            var preferences: [(Bool, Bool)] = []
            if intent == .restore {
                preferences.append((lhs.isMinimized, rhs.isMinimized))
            }
            preferences.append(contentsOf: [
                (lhs.isKeyWindow == true, rhs.isKeyWindow == true),
                (lhs.isMainWindow, rhs.isMainWindow),
                (lhs.isFrontmost == true, rhs.isFrontmost == true),
                (!lhs.isMinimized, !rhs.isMinimized),
                (!lhs.isOffScreen, !rhs.isOffScreen),
                (lhs.isOnScreen, rhs.isOnScreen),
                (lhs.windowLevel == 0, rhs.windowLevel == 0),
                (!lhs.title.isEmpty, !rhs.title.isEmpty),
            ])
            for (left, right) in preferences where left != right {
                return left
            }
            let leftArea = lhs.bounds.width * lhs.bounds.height
            let rightArea = rhs.bounds.width * rhs.bounds.height
            if leftArea != rightArea {
                return leftArea > rightArea
            }
            if lhs.index != rhs.index {
                return lhs.index < rhs.index
            }
            return lhs.windowID < rhs.windowID
        }

        static func validate(
            _ window: ServiceWindowInfo,
            expectedOwner: ApplicationProcessIdentity?) throws
        {
            guard let identity = window.mutationIdentity else {
                throw DesktopTargetPlanningError.missingWindowIdentity(windowID: window.windowID)
            }
            guard window.windowID > 0,
                  CGWindowID(exactly: window.windowID) != nil,
                  identity.windowID == window.windowID,
                  CGWindowID(exactly: identity.windowID) != nil,
                  identity.ownerProcessIdentifier > 0,
                  identity.ownerProcessStartIdentity > 0,
                  let capturedBounds = identity.capturedBounds,
                  capturedBounds == window.bounds
            else {
                throw DesktopTargetPlanningError.incompleteWindowIdentity(windowID: window.windowID)
            }
            if let expectedOwner, identity.processIdentity != expectedOwner {
                throw DesktopTargetPlanningError.windowOwnerMismatch(
                    windowID: window.windowID,
                    expected: expectedOwner)
            }
        }

        private static func windowIDs(_ candidates: [ServiceWindowInfo]) -> [Int] {
            Array(Set(candidates.map(\.windowID))).sorted()
        }
    }
}

extension DesktopTargetPlanning.Inventory where Element == ServiceWindowInfo {
    public static func windowOutput(_ output: UnifiedToolOutput<ServiceWindowListData>) -> Self {
        var warnings = output.metadata.warnings
        for window in output.data.windows {
            do {
                try DesktopTargetPlanning.WindowCandidateSelector.validate(window, expectedOwner: nil)
            } catch {
                warnings.append(error.localizedDescription)
            }
        }
        warnings = Array(Set(warnings)).sorted()
        return Self(
            items: output.data.windows,
            completeness: output.summary.status == .success && warnings.isEmpty
                ? .complete
                : .partial,
            warnings: warnings)
    }
}
