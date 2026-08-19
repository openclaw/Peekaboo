import CryptoKit
import Foundation

public enum WindowSelectorResolutionProof {
    public static let maximumCandidateCount = 512

    public enum ResolutionError: Error, Sendable, Equatable {
        case candidateSetTooLarge(Int)
        case candidateFieldTooLarge
        case selectedWindowMissingIdentity
        case selectedWindowNotInCandidateSet
        case selectedWindowDoesNotMatchSelector
    }

    public static func make(
        selection: WindowSelection,
        candidates: [ServiceWindowInfo],
        selected: ServiceWindowInfo,
        processIdentity: ApplicationProcessIdentity) throws -> SelectorResolutionProof
    {
        guard candidates.count <= self.maximumCandidateCount else {
            throw ResolutionError.candidateSetTooLarge(candidates.count)
        }
        guard candidates.allSatisfy({ $0.title.utf8.count <= 4096 }) else {
            throw ResolutionError.candidateFieldTooLarge
        }
        guard candidates.contains(where: { $0.windowID == selected.windowID }) else {
            throw ResolutionError.selectedWindowNotInCandidateSet
        }
        guard let selectedIdentity = selected.mutationIdentity,
              selectedIdentity.processIdentity == processIdentity
        else {
            throw ResolutionError.selectedWindowMissingIdentity
        }

        guard let match = self.match(selection: selection, candidates: candidates, selected: selected) else {
            throw ResolutionError.selectedWindowDoesNotMatchSelector
        }
        let selector = self.normalizedSelector(selection)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonicalRows = try candidates.map(DigestCandidate.init).map(encoder.encode).sorted {
            $0.lexicographicallyPrecedes($1)
        }
        let data = try encoder.encode(canonicalRows)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return SelectorResolutionProof(
            scope: .window,
            normalizedSelector: selector,
            matchKind: match.kind,
            matchPrecedence: match.kind.precedence,
            selectedProcessIdentity: processIdentity,
            selectedWindowIdentity: selectedIdentity,
            candidateSetSHA256: digest,
            candidateCount: candidates.count,
            winningCandidateCount: match.winningCandidateCount,
            hasWinningTie: match.winningCandidateCount > 1)
    }

    public static func normalizedSelector(_ selection: WindowSelection) -> String {
        switch selection {
        case .automatic: "automatic"
        case let .index(index): "index:\(index)"
        case let .title(title): "title:\(title.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .id(windowID): "id:\(windowID)"
        }
    }

    private static func match(
        selection: WindowSelection,
        candidates: [ServiceWindowInfo],
        selected: ServiceWindowInfo) -> (kind: SelectorResolutionProof.MatchKind, winningCandidateCount: Int)?
    {
        switch selection {
        case .automatic:
            // Automatic is a provenance label shared by capture and dialog callers with different
            // route-specific rankers. The mutation planner therefore never emits an automatic proof;
            // it retains the exact selected identity and revalidates that target directly instead.
            return (.automaticWindowRank, 1)
        case let .index(index):
            let explicit = candidates.filter { $0.index == index }
            guard explicit.contains(where: { $0.windowID == selected.windowID }) else { return nil }
            return (.windowIndex, explicit.count)
        case let .id(windowID):
            let exact = candidates.filter { $0.windowID == Int(windowID) }
            guard exact.contains(where: { $0.windowID == selected.windowID }) else { return nil }
            return (.windowID, exact.count)
        case let .title(title):
            let exact = candidates.filter {
                $0.title.compare(title, options: .caseInsensitive) == .orderedSame
            }
            if !exact.isEmpty {
                guard exact.contains(where: { $0.windowID == selected.windowID }) else { return nil }
                return (.exactWindowTitle, exact.count)
            }
            let partial = candidates.filter { $0.title.localizedCaseInsensitiveContains(title) }
            guard partial.contains(where: { $0.windowID == selected.windowID }) else { return nil }
            return (.partialWindowTitle, partial.count)
        }
    }

    fileprivate static func selectedMatchKind(
        selection: WindowSelection,
        selected: ServiceWindowInfo) -> SelectorResolutionProof.MatchKind?
    {
        switch selection {
        case .automatic:
            .automaticWindowRank
        case let .index(index):
            selected.index == index ? .windowIndex : nil
        case let .id(windowID):
            selected.windowID == Int(windowID) ? .windowID : nil
        case let .title(title):
            if selected.title.compare(title, options: .caseInsensitive) == .orderedSame {
                .exactWindowTitle
            } else if selected.title.localizedCaseInsensitiveContains(title) {
                .partialWindowTitle
            } else {
                nil
            }
        }
    }

    private struct DigestCandidate: Codable {
        let windowID: Int
        let title: String
        let bounds: CGRect
        let index: Int
        let mutationIdentity: WindowMutationIdentity?

        init(_ candidate: ServiceWindowInfo) {
            self.windowID = candidate.windowID
            self.title = candidate.title
            self.bounds = candidate.bounds
            self.index = candidate.index
            self.mutationIdentity = candidate.mutationIdentity
        }
    }
}

extension SelectorResolutionProof {
    public func windowMismatch(
        selection: WindowSelection,
        selectedWindow: ServiceWindowInfo,
        processIdentity: ApplicationProcessIdentity?) -> String?
    {
        guard self.scope == .window else { return "selector scope" }
        guard self.normalizedSelector == WindowSelectorResolutionProof.normalizedSelector(selection) else {
            return "normalized selector"
        }
        guard let expectedKind = WindowSelectorResolutionProof.selectedMatchKind(
            selection: selection,
            selected: selectedWindow)
        else {
            return "selected window selector"
        }
        guard self.matchKind == expectedKind, self.matchPrecedence == expectedKind.precedence else {
            return "match kind or precedence"
        }
        guard self.candidateSetSHA256.count == 64,
              self.candidateSetSHA256.allSatisfy(\.isHexDigit),
              self.candidateSetSHA256 == self.candidateSetSHA256.lowercased(),
              self.candidateCount > 0,
              self.candidateCount <= WindowSelectorResolutionProof.maximumCandidateCount,
              self.winningCandidateCount > 0,
              self.winningCandidateCount <= self.candidateCount,
              self.hasWinningTie == (self.winningCandidateCount > 1)
        else {
            return "candidate set"
        }
        guard !self.hasWinningTie, self.winningCandidateCount == 1 else {
            return "ambiguous selector"
        }
        guard let processIdentity,
              self.selectedProcessIdentity == processIdentity,
              let selectedWindowIdentity = selectedWindow.mutationIdentity,
              self.selectedWindowIdentity?.hasSameStableReceipt(as: selectedWindowIdentity) == true,
              selectedWindowIdentity.processIdentity == processIdentity
        else {
            return "selected window identity"
        }
        return nil
    }
}
