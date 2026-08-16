import CryptoKit
import Foundation

/// One authoritative application-selector grammar shared by discovery and receipt validation.
public enum ApplicationIdentifierMatcher {
    public static let maximumProofCandidateCount = 512

    public typealias MatchKind = SelectorResolutionProof.MatchKind

    public struct Resolution: Sendable, Equatable {
        public let index: Int
        public let matchKind: MatchKind
        public let candidateSetSHA256: String
        public let candidateCount: Int
        public let winningCandidateCount: Int

        public var hasWinningTie: Bool {
            self.winningCandidateCount > 1
        }

        public func proof(
            selectedProcessIdentity: ApplicationProcessIdentity,
            selectedWindowIdentity: WindowMutationIdentity? = nil) -> SelectorResolutionProof
        {
            SelectorResolutionProof(
                scope: .application,
                normalizedSelector: self.normalizedSelector,
                matchKind: self.matchKind,
                matchPrecedence: self.matchKind.precedence,
                selectedProcessIdentity: selectedProcessIdentity,
                selectedWindowIdentity: selectedWindowIdentity,
                candidateSetSHA256: self.candidateSetSHA256,
                candidateCount: self.candidateCount,
                winningCandidateCount: self.winningCandidateCount,
                hasWinningTie: self.hasWinningTie)
        }

        fileprivate let normalizedSelector: String
    }

    public enum ResolutionError: Error, Sendable, Equatable {
        case candidateSetTooLarge(Int)
        case candidateFieldTooLarge
    }

    public struct Candidate: Sendable, Equatable {
        public let processIdentifier: Int32
        public let bundleIdentifier: String?
        public let name: String
        public let bundlePath: String?
        public let executablePath: String?
        public let allowsFuzzyMatching: Bool
        public let isRegularApplication: Bool

        public init(
            processIdentifier: Int32,
            bundleIdentifier: String?,
            name: String,
            bundlePath: String? = nil,
            executablePath: String? = nil,
            allowsFuzzyMatching: Bool = true,
            isRegularApplication: Bool = false)
        {
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
            self.name = name
            self.bundlePath = bundlePath
            self.executablePath = executablePath
            self.allowsFuzzyMatching = allowsFuzzyMatching
            self.isRegularApplication = isRegularApplication
        }

        public init(_ application: ServiceApplicationInfo) {
            self.init(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                name: application.name,
                bundlePath: application.bundlePath,
                executablePath: application.executablePath,
                allowsFuzzyMatching: application.activationPolicy != .prohibited,
                isRegularApplication: application.activationPolicy == .regular)
        }

        public init(_ application: ApplicationIdentity) {
            self.init(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                name: application.name,
                bundlePath: application.bundlePath,
                executablePath: application.executablePath,
                allowsFuzzyMatching: application.activationPolicy != .prohibited,
                isRegularApplication: application.activationPolicy == .regular)
        }
    }

    /// Selects the same candidate that application discovery would return for the identifier.
    public static func bestMatchIndex(
        for identifier: String,
        in candidates: [Candidate]) -> Int?
    {
        self.selection(for: identifier, in: candidates)?.index
    }

    public static func resolution(
        for identifier: String,
        in candidates: [Candidate]) throws -> Resolution?
    {
        guard candidates.count <= self.maximumProofCandidateCount else {
            throw ResolutionError.candidateSetTooLarge(candidates.count)
        }
        let maximumFieldByteCount = 4096
        guard candidates.allSatisfy({ candidate in
            [candidate.bundleIdentifier, candidate.bundlePath, candidate.executablePath, candidate.name]
                .compactMap(\.self)
                .allSatisfy { $0.utf8.count <= maximumFieldByteCount }
        }) else {
            throw ResolutionError.candidateFieldTooLarge
        }
        guard let selection = self.selection(for: identifier, in: candidates) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonicalRows = try candidates.map(DigestCandidate.init).map(encoder.encode).sorted {
            $0.lexicographicallyPrecedes($1)
        }
        let data = try encoder.encode(canonicalRows)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Resolution(
            index: selection.index,
            matchKind: selection.kind,
            candidateSetSHA256: digest,
            candidateCount: candidates.count,
            winningCandidateCount: selection.winningCandidateCount,
            normalizedSelector: self.normalized(identifier))
    }

    /// Returns whether one independently carried application identity satisfies the selector grammar.
    public static func matches(_ candidate: Candidate, identifier: String) -> Bool {
        self.bestMatchIndex(for: identifier, in: [candidate]) == 0
    }

    public static func matches(_ application: ServiceApplicationInfo, identifier: String) -> Bool {
        self.matches(Candidate(application), identifier: identifier)
    }

    public static func matches(_ application: ApplicationIdentity, identifier: String) -> Bool {
        self.matches(Candidate(application), identifier: identifier)
    }

    public static func normalized(_ identifier: String) -> String {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func matchKind(for candidate: Candidate, identifier: String) -> MatchKind? {
        self.selection(for: identifier, in: [candidate])?.kind
    }

    private static func processIdentifier(in identifier: String) -> Int32? {
        guard identifier.uppercased().hasPrefix("PID:") else { return nil }
        return Int32(identifier.dropFirst("PID:".count))
    }

    private struct Selection {
        let index: Int
        let kind: MatchKind
        let winningCandidateCount: Int
    }

    private static func selection(for rawIdentifier: String, in candidates: [Candidate]) -> Selection? {
        let identifier = self.normalized(rawIdentifier)
        guard !identifier.isEmpty else { return nil }

        if identifier.uppercased().hasPrefix("PID:") {
            guard let processIdentifier = self.processIdentifier(in: identifier) else { return nil }
            return self.exactSelection(
                kind: .processIdentifier,
                in: candidates,
                matches: { $0.processIdentifier == processIdentifier })
        }
        if let selection = self.exactSelection(
            kind: .bundleIdentifier,
            in: candidates,
            matches: { $0.bundleIdentifier == identifier })
        {
            return selection
        }
        if let selection = self.exactSelection(
            kind: .bundlePath,
            in: candidates,
            matches: { $0.bundlePath == identifier })
        {
            return selection
        }
        if let selection = self.exactSelection(
            kind: .exactName,
            in: candidates,
            matches: { $0.name.compare(identifier, options: .caseInsensitive) == .orderedSame })
        {
            return selection
        }
        if let selection = self.exactSelection(
            kind: .exactExecutable,
            in: candidates,
            matches: { self.executablePath($0.executablePath, exactlyMatches: identifier) })
        {
            return selection
        }

        let scored = candidates.indices.compactMap { index -> (index: Int, score: Int)? in
            guard let score = self.fuzzyScore(for: identifier, candidate: candidates[index]) else { return nil }
            return (index, score)
        }
        guard let selected = scored.max(by: { $0.score < $1.score }) else { return nil }
        return Selection(
            index: selected.index,
            kind: .fuzzyNameOrExecutable,
            winningCandidateCount: scored.count(where: { $0.score == selected.score }))
    }

    private static func exactSelection(
        kind: MatchKind,
        in candidates: [Candidate],
        matches: (Candidate) -> Bool) -> Selection?
    {
        let indices = candidates.indices.filter { matches(candidates[$0]) }
        guard let index = indices.first else { return nil }
        return Selection(index: index, kind: kind, winningCandidateCount: indices.count)
    }

    private struct DigestCandidate: Codable {
        let processIdentifier: Int32
        let bundleIdentifier: String?
        let name: String
        let bundlePath: String?
        let executablePath: String?
        let allowsFuzzyMatching: Bool
        let isRegularApplication: Bool

        init(_ candidate: Candidate) {
            self.processIdentifier = candidate.processIdentifier
            self.bundleIdentifier = candidate.bundleIdentifier
            self.name = candidate.name
            self.bundlePath = candidate.bundlePath
            self.executablePath = candidate.executablePath
            self.allowsFuzzyMatching = candidate.allowsFuzzyMatching
            self.isRegularApplication = candidate.isRegularApplication
        }
    }

    private static func executablePath(_ path: String?, exactlyMatches identifier: String) -> Bool {
        guard let path else { return false }
        return path.compare(identifier, options: .caseInsensitive) == .orderedSame ||
            URL(fileURLWithPath: path).lastPathComponent.compare(
                identifier,
                options: .caseInsensitive) == .orderedSame
    }

    private static func fuzzyScore(for identifier: String, candidate: Candidate) -> Int? {
        guard candidate.allowsFuzzyMatching else { return nil }
        let executable = candidate.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        let nameMatches = candidate.name.localizedCaseInsensitiveContains(identifier)
        let executableMatches = executable?.localizedCaseInsensitiveContains(identifier) ?? false
        guard nameMatches || executableMatches else { return nil }

        let lowercaseIdentifier = identifier.lowercased()
        var score = 0
        if candidate.name.compare(identifier, options: .caseInsensitive) == .orderedSame {
            score += 1000
        }
        if executable?.compare(identifier, options: .caseInsensitive) == .orderedSame {
            score += 800
        }
        if candidate.name.lowercased().hasPrefix(lowercaseIdentifier) {
            score += 100
        }
        if executable?.lowercased().hasPrefix(lowercaseIdentifier) == true {
            score += 80
        }
        if candidate.isRegularApplication {
            score += 50
        }
        score -= candidate.name.count
        return score
    }
}
