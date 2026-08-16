import CoreGraphics
import CryptoKit
import Foundation

/// Signed evidence for the concrete UI leaf selected by a name or index.
public struct DesktopSelectedLeafEvidence: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, Equatable {
        case dockItem
        case dockContextMenuItem
        case menuBarItem
    }

    public enum MatchKind: String, Sendable, Codable, Equatable {
        case index
        case exact
        case normalizedExact
        case punctuationFolded
        case partial

        public var precedence: Int {
            switch self {
            case .index: 0
            case .exact: 1
            case .normalizedExact: 2
            case .punctuationFolded: 3
            case .partial: 4
            }
        }
    }

    private struct LeafDescriptor {
        let kind: Kind
        let target: DesktopActionTargetReceipt
        let index: Int
        let title: String
        let identifier: String?
        let role: String
        let subrole: String?
        let frame: CGRect
    }

    public let kind: Kind
    public let normalizedSelector: String
    public let matchKind: MatchKind
    public let matchPrecedence: Int
    public let selectedTargetReceipt: DesktopActionTargetReceipt
    public let selectedIndex: Int
    public let selectedTitle: String
    public let selectedIdentifier: String?
    public let selectedRole: String
    public let selectedSubrole: String?
    public let selectedFrame: CGRect
    public let selectedLeafSHA256: String
    public let candidateSetSHA256: String
    public let candidateCount: Int
    public let winningCandidateCount: Int
    public let hasWinningTie: Bool

    public init(
        kind: Kind,
        normalizedSelector: String,
        matchKind: MatchKind,
        selectedTargetReceipt: DesktopActionTargetReceipt,
        selectedIndex: Int,
        selectedTitle: String,
        selectedIdentifier: String? = nil,
        selectedRole: String,
        selectedSubrole: String? = nil,
        selectedFrame: CGRect,
        candidateSetSHA256: String,
        candidateCount: Int,
        winningCandidateCount: Int = 1,
        hasWinningTie: Bool = false) throws
    {
        self.kind = kind
        self.normalizedSelector = normalizedSelector
        self.matchKind = matchKind
        self.matchPrecedence = matchKind.precedence
        self.selectedTargetReceipt = selectedTargetReceipt
        self.selectedIndex = selectedIndex
        self.selectedTitle = selectedTitle
        self.selectedIdentifier = selectedIdentifier
        self.selectedRole = selectedRole
        self.selectedSubrole = selectedSubrole
        self.selectedFrame = selectedFrame
        self.selectedLeafSHA256 = Self.selectedLeafDigest(LeafDescriptor(
            kind: kind,
            target: selectedTargetReceipt,
            index: selectedIndex,
            title: selectedTitle,
            identifier: selectedIdentifier,
            role: selectedRole,
            subrole: selectedSubrole,
            frame: selectedFrame))
        self.candidateSetSHA256 = candidateSetSHA256
        self.candidateCount = candidateCount
        self.winningCandidateCount = winningCandidateCount
        self.hasWinningTie = hasWinningTie
        try self.validate()
    }

    public func selecting(
        normalizedSelector: String,
        matchKind: MatchKind,
        winningCandidateCount: Int = 1,
        hasWinningTie: Bool = false) throws -> Self
    {
        try Self(
            kind: self.kind,
            normalizedSelector: normalizedSelector,
            matchKind: matchKind,
            selectedTargetReceipt: self.selectedTargetReceipt,
            selectedIndex: self.selectedIndex,
            selectedTitle: self.selectedTitle,
            selectedIdentifier: self.selectedIdentifier,
            selectedRole: self.selectedRole,
            selectedSubrole: self.selectedSubrole,
            selectedFrame: self.selectedFrame,
            candidateSetSHA256: self.candidateSetSHA256,
            candidateCount: self.candidateCount,
            winningCandidateCount: winningCandidateCount,
            hasWinningTie: hasWinningTie)
    }

    public func hasSameResolvedLeaf(as other: Self) -> Bool {
        let titleIsIdentity = self.selectedIdentifier == nil && self.selectedTargetReceipt.windowID == nil
        let titleMatches = !titleIsIdentity || self.selectedTitle == other.selectedTitle
        return self.kind == other.kind &&
            self.selectedTargetReceipt == other.selectedTargetReceipt &&
            self.selectedIndex == other.selectedIndex &&
            titleMatches &&
            self.selectedIdentifier == other.selectedIdentifier &&
            self.selectedRole == other.selectedRole &&
            self.selectedSubrole == other.selectedSubrole &&
            self.selectedFrame == other.selectedFrame &&
            self.selectedLeafSHA256 == other.selectedLeafSHA256 &&
            self.candidateSetSHA256 == other.candidateSetSHA256 &&
            self.candidateCount == other.candidateCount
    }

    public var isCanonical: Bool {
        (try? self.validate()) != nil
    }

    private enum CodingKeys: String, CodingKey {
        case kind, normalizedSelector, matchKind, matchPrecedence, selectedTargetReceipt
        case selectedIndex, selectedTitle, selectedIdentifier, selectedRole, selectedSubrole, selectedFrame
        case selectedLeafSHA256, candidateSetSHA256, candidateCount, winningCandidateCount, hasWinningTie
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(Kind.self, forKey: .kind)
        self.normalizedSelector = try container.decode(String.self, forKey: .normalizedSelector)
        self.matchKind = try container.decode(MatchKind.self, forKey: .matchKind)
        self.matchPrecedence = try container.decode(Int.self, forKey: .matchPrecedence)
        self.selectedTargetReceipt = try container.decode(
            DesktopActionTargetReceipt.self,
            forKey: .selectedTargetReceipt)
        self.selectedIndex = try container.decode(Int.self, forKey: .selectedIndex)
        self.selectedTitle = try container.decode(String.self, forKey: .selectedTitle)
        self.selectedIdentifier = try container.decodeIfPresent(String.self, forKey: .selectedIdentifier)
        self.selectedRole = try container.decode(String.self, forKey: .selectedRole)
        self.selectedSubrole = try container.decodeIfPresent(String.self, forKey: .selectedSubrole)
        self.selectedFrame = try container.decode(CGRect.self, forKey: .selectedFrame)
        self.selectedLeafSHA256 = try container.decode(String.self, forKey: .selectedLeafSHA256)
        self.candidateSetSHA256 = try container.decode(String.self, forKey: .candidateSetSHA256)
        self.candidateCount = try container.decode(Int.self, forKey: .candidateCount)
        self.winningCandidateCount = try container.decode(Int.self, forKey: .winningCandidateCount)
        self.hasWinningTie = try container.decode(Bool.self, forKey: .hasWinningTie)
        do {
            try self.validate()
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .selectedLeafSHA256,
                in: container,
                debugDescription: error.localizedDescription)
        }
    }

    private func validate() throws {
        let descriptor = LeafDescriptor(
            kind: self.kind,
            target: self.selectedTargetReceipt,
            index: self.selectedIndex,
            title: self.selectedTitle,
            identifier: self.selectedIdentifier,
            role: self.selectedRole,
            subrole: self.selectedSubrole,
            frame: self.selectedFrame)
        guard !self.normalizedSelector.isEmpty,
              self.matchPrecedence == self.matchKind.precedence,
              self.selectedTargetReceipt.processIdentifier > 0,
              self.selectedTargetReceipt.processStartIdentity > 0,
              self.selectedTargetReceipt.windowID.map({ $0 > 0 }) ?? true,
              self.selectedIndex >= 0,
              !self.selectedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !self.selectedRole.isEmpty,
              !self.selectedFrame.isEmpty,
              Self.isFiniteFrame(self.selectedFrame),
              Self.isCanonicalDigest(self.selectedLeafSHA256),
              Self.isCanonicalDigest(self.candidateSetSHA256),
              self.candidateCount > 0,
              self.winningCandidateCount > 0,
              self.winningCandidateCount <= self.candidateCount,
              self.hasWinningTie == (self.winningCandidateCount > 1),
              self.selectedLeafSHA256 == Self.selectedLeafDigest(descriptor)
        else {
            throw DesktopSelectedLeafEvidenceError.invalidEvidence
        }
    }

    private static func selectedLeafDigest(_ descriptor: LeafDescriptor) -> String {
        let stableTitle = descriptor.identifier == nil && descriptor.target.windowID == nil
            ? descriptor.title
            : ""
        return Self.sha256([
            descriptor.kind.rawValue,
            String(descriptor.target.processIdentifier),
            String(descriptor.target.processStartIdentity),
            descriptor.target.windowID.map { String($0) } ?? "-",
            String(descriptor.index),
            stableTitle,
            descriptor.identifier ?? "",
            descriptor.role,
            descriptor.subrole ?? "",
            Self.canonical(descriptor.frame.origin.x),
            Self.canonical(descriptor.frame.origin.y),
            Self.canonical(descriptor.frame.size.width),
            Self.canonical(descriptor.frame.size.height),
        ])
    }

    public static func digestCandidateSet(_ components: [String]) -> String {
        self.sha256(components)
    }

    private static func sha256(_ components: [String]) -> String {
        var data = Data()
        for component in components {
            let encoded = Data(component.utf8)
            var length = UInt64(encoded.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(encoded)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonical(_ value: CGFloat) -> String {
        String(format: "%016llx", Double(value).bitPattern)
    }

    private static func isFiniteFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite &&
            frame.origin.y.isFinite &&
            frame.size.width.isFinite &&
            frame.size.height.isFinite
    }

    private static func isCanonicalDigest(_ value: String) -> Bool {
        value.count == 64 && value == value.lowercased() && value.allSatisfy(\.isHexDigit)
    }
}

public enum DesktopSelectedLeafEvidenceError: LocalizedError, Equatable, Sendable {
    case invalidEvidence

    public var errorDescription: String? {
        "Selected desktop leaf evidence is incomplete or internally inconsistent."
    }
}
