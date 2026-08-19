import Foundation

/// One signed stage of authoritative selector resolution.
public struct SelectorResolutionProof: Sendable, Codable, Equatable {
    public enum Scope: String, Sendable, Codable, Equatable {
        case application
        case window
    }

    public enum MatchKind: String, Sendable, Codable, Equatable {
        case processIdentifier
        case bundleIdentifier
        case bundlePath
        case exactName
        case exactExecutable
        case fuzzyNameOrExecutable
        case windowID
        case windowIndex
        case exactWindowTitle
        case partialWindowTitle
        case automaticWindowRank

        public var precedence: Int {
            switch self {
            case .processIdentifier, .windowID: 0
            case .bundleIdentifier, .windowIndex: 1
            case .bundlePath, .exactWindowTitle: 2
            case .exactName, .partialWindowTitle: 3
            case .exactExecutable, .automaticWindowRank: 4
            case .fuzzyNameOrExecutable: 5
            }
        }
    }

    public let scope: Scope
    public let normalizedSelector: String
    public let matchKind: MatchKind
    public let matchPrecedence: Int
    public let selectedProcessIdentity: ApplicationProcessIdentity
    public let selectedWindowIdentity: WindowMutationIdentity?
    public let candidateSetSHA256: String
    public let candidateCount: Int
    /// Candidates tied at the winning precedence/score, not every lower-ranked partial match.
    public let winningCandidateCount: Int
    public let hasWinningTie: Bool

    public init(
        scope: Scope,
        normalizedSelector: String,
        matchKind: MatchKind,
        matchPrecedence: Int,
        selectedProcessIdentity: ApplicationProcessIdentity,
        selectedWindowIdentity: WindowMutationIdentity? = nil,
        candidateSetSHA256: String,
        candidateCount: Int,
        winningCandidateCount: Int,
        hasWinningTie: Bool)
    {
        self.scope = scope
        self.normalizedSelector = normalizedSelector
        self.matchKind = matchKind
        self.matchPrecedence = matchPrecedence
        self.selectedProcessIdentity = selectedProcessIdentity
        self.selectedWindowIdentity = selectedWindowIdentity
        self.candidateSetSHA256 = candidateSetSHA256
        self.candidateCount = candidateCount
        self.winningCandidateCount = winningCandidateCount
        self.hasWinningTie = hasWinningTie
    }

    public func selecting(windowIdentity: WindowMutationIdentity?) -> Self {
        Self(
            scope: self.scope,
            normalizedSelector: self.normalizedSelector,
            matchKind: self.matchKind,
            matchPrecedence: self.matchPrecedence,
            selectedProcessIdentity: self.selectedProcessIdentity,
            selectedWindowIdentity: windowIdentity,
            candidateSetSHA256: self.candidateSetSHA256,
            candidateCount: self.candidateCount,
            winningCandidateCount: self.winningCandidateCount,
            hasWinningTie: self.hasWinningTie)
    }

    /// Returns a stable mismatch label suitable for live signing and offline receipt validation.
    public func applicationMismatch(
        identifier: String,
        selectedCandidate: ApplicationIdentifierMatcher.Candidate,
        processIdentity: ApplicationProcessIdentity?,
        windowIdentity: WindowMutationIdentity? = nil) -> String?
    {
        guard self.scope == .application else { return "selector scope" }
        guard !self.normalizedSelector.isEmpty,
              self.normalizedSelector == ApplicationIdentifierMatcher.normalized(identifier)
        else {
            return "normalized selector"
        }
        guard self.matchPrecedence == self.matchKind.precedence,
              ApplicationIdentifierMatcher.matchKind(
                  for: selectedCandidate,
                  identifier: self.normalizedSelector) == self.matchKind
        else {
            return "match kind or precedence"
        }
        guard self.candidateSetSHA256.count == 64,
              self.candidateSetSHA256.allSatisfy(\.isHexDigit),
              self.candidateSetSHA256 == self.candidateSetSHA256.lowercased(),
              self.candidateCount > 0,
              self.candidateCount <= ApplicationIdentifierMatcher.maximumProofCandidateCount,
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
              processIdentity == self.selectedProcessIdentity,
              processIdentity.processIdentifier == selectedCandidate.processIdentifier
        else {
            return "selected process identity"
        }
        let windowIdentityMatches = switch (self.selectedWindowIdentity, windowIdentity) {
        case (nil, nil): true
        case let (selected?, current?): selected.hasSameStableReceipt(as: current)
        default: false
        }
        guard windowIdentityMatches else {
            return "selected window identity"
        }
        if let windowIdentity,
           windowIdentity.processIdentity != processIdentity
        {
            return "selected window owner"
        }
        return nil
    }
}
