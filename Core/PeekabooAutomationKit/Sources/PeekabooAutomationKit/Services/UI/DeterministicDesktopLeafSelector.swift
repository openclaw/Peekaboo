import Foundation
import PeekabooFoundation

public enum DesktopLeafSelectionError: LocalizedError, Equatable, Sendable {
    case notFound(selector: String)
    case ambiguous(selector: String, candidates: [String])
    case invalidIndex(Int)

    public var errorDescription: String? {
        switch self {
        case let .notFound(selector):
            "No desktop leaf matches '\(selector)'."
        case let .ambiguous(selector, candidates):
            "Desktop leaf selector '\(selector)' is ambiguous: \(candidates.joined(separator: ", "))."
        case let .invalidIndex(index):
            "Desktop leaf index \(index) is not present in the current inventory."
        }
    }
}

/// Shared deterministic selector for Dock items, menu-bar status items, and CLI preflight.
public enum DeterministicDesktopLeafSelector {
    public struct Candidate<Value> {
        public let value: Value
        public let index: Int
        public let displayName: String
        public let matchFields: [String]
        public let stableIdentity: String

        public init(
            value: Value,
            index: Int,
            displayName: String,
            matchFields: [String],
            stableIdentity: String)
        {
            self.value = value
            self.index = index
            self.displayName = displayName
            self.matchFields = matchFields
            self.stableIdentity = stableIdentity
        }
    }

    public struct Selection<Value> {
        public let candidate: Candidate<Value>
        public let normalizedSelector: String
        public let matchKind: DesktopSelectedLeafEvidence.MatchKind
        public let candidateSetSHA256: String
        public let candidateCount: Int
    }

    public static func select<Value>(
        named selector: String,
        from candidates: [Candidate<Value>],
        allowPartial: Bool = true) throws -> Selection<Value>
    {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSelector = self.normalized(trimmed)
        guard !trimmed.isEmpty, !normalizedSelector.isEmpty else {
            throw DesktopLeafSelectionError.notFound(selector: selector)
        }

        let permittedKinds: [DesktopSelectedLeafEvidence.MatchKind] = allowPartial
            ? [.exact, .normalizedExact, .punctuationFolded, .partial]
            : [.exact, .normalizedExact, .punctuationFolded]
        for kind in permittedKinds {
            let winners = candidates.filter { candidate in
                candidate.matchFields.contains { field in
                    self.matches(field, selector: trimmed, normalizedSelector: normalizedSelector, kind: kind)
                }
            }
            guard !winners.isEmpty else { continue }
            guard winners.count == 1, let winner = winners.first else {
                throw DesktopLeafSelectionError.ambiguous(
                    selector: selector,
                    candidates: winners.map(\.displayName).sorted())
            }
            return Selection(
                candidate: winner,
                normalizedSelector: normalizedSelector,
                matchKind: kind,
                candidateSetSHA256: self.candidateSetDigest(candidates),
                candidateCount: candidates.count)
        }

        throw DesktopLeafSelectionError.notFound(selector: selector)
    }

    public static func select<Value>(
        index: Int,
        from candidates: [Candidate<Value>]) throws -> Selection<Value>
    {
        let winners = candidates.filter { $0.index == index }
        guard winners.count == 1, let winner = winners.first else {
            if winners.isEmpty {
                throw DesktopLeafSelectionError.invalidIndex(index)
            }
            throw DesktopLeafSelectionError.ambiguous(
                selector: String(index),
                candidates: winners.map(\.displayName).sorted())
        }
        return Selection(
            candidate: winner,
            normalizedSelector: String(index),
            matchKind: .index,
            candidateSetSHA256: self.candidateSetDigest(candidates),
            candidateCount: candidates.count)
    }

    public static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func stableIdentity(_ components: [String?]) -> String {
        components.map { $0 ?? "" }.joined(separator: "\u{1f}")
    }

    private static func matches(
        _ candidate: String,
        selector: String,
        normalizedSelector: String,
        kind: DesktopSelectedLeafEvidence.MatchKind) -> Bool
    {
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCandidate = self.normalized(trimmedCandidate)
        return switch kind {
        case .index:
            false
        case .exact:
            trimmedCandidate == selector
        case .normalizedExact:
            normalizedCandidate == normalizedSelector
        case .punctuationFolded:
            self.foldingPunctuation(normalizedCandidate) == self.foldingPunctuation(normalizedSelector)
        case .partial:
            normalizedCandidate.contains(normalizedSelector)
        }
    }

    private static func foldingPunctuation(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"[-‐‑‒–—]"#,
            with: "",
            options: .regularExpression)
    }

    private static func candidateSetDigest(_ candidates: [Candidate<some Any>]) -> String {
        DesktopSelectedLeafEvidence.digestCandidateSet(candidates.map { candidate in
            Self.stableIdentity([
                String(candidate.index),
                candidate.displayName,
                candidate.stableIdentity,
            ])
        })
    }
}

/// Canonical menu-bar matcher shared by the native service and CLI preflight.
public enum MenuBarItemSelector {
    public static func select(
        named name: String,
        from items: [MenuBarItemInfo]) throws
        -> DeterministicDesktopLeafSelector.Selection<MenuBarItemInfo>
    {
        try DeterministicDesktopLeafSelector.select(
            named: name,
            from: self.candidates(items))
    }

    public static func select(
        index: Int,
        from items: [MenuBarItemInfo]) throws
        -> DeterministicDesktopLeafSelector.Selection<MenuBarItemInfo>
    {
        try DeterministicDesktopLeafSelector.select(index: index, from: self.candidates(items))
    }

    private static func candidates(_ items: [MenuBarItemInfo])
        -> [DeterministicDesktopLeafSelector.Candidate<MenuBarItemInfo>]
    {
        items.map { item in
            let fields = [
                item.title,
                item.rawTitle,
                item.identifier,
                item.axDescription,
                item.ownerName,
            ].compactMap { value -> String? in
                guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !trimmed.isEmpty
                else { return nil }
                return trimmed
            }
            let stableIdentity = if let evidence = item.selectionEvidence {
                evidence.selectedLeafSHA256
            } else {
                DeterministicDesktopLeafSelector.stableIdentity([
                    item.title,
                    item.rawTitle,
                    item.bundleIdentifier,
                    item.ownerName,
                    item.identifier,
                    item.rawWindowID.map { String($0) },
                    item.rawOwnerPID.map { String($0) },
                ])
            }
            return DeterministicDesktopLeafSelector.Candidate(
                value: item,
                index: item.index,
                displayName: item.title ?? item.rawTitle ?? "Menu Bar Item #\(item.index)",
                matchFields: fields,
                stableIdentity: stableIdentity)
        }
    }
}
