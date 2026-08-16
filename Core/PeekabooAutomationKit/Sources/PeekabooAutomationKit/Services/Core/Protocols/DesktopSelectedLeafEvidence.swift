import CoreGraphics
import PeekabooFoundation

extension DesktopSelectedLeafEvidence {
    public init(
        kind: Kind,
        normalizedSelector: String,
        matchKind: MatchKind,
        selectedProcessIdentity: ApplicationProcessIdentity,
        selectedWindowIdentity: WindowMutationIdentity? = nil,
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
        try self.init(
            kind: kind,
            normalizedSelector: normalizedSelector,
            matchKind: matchKind,
            selectedTargetReceipt: DesktopActionTargetReceipt(
                processIdentifier: selectedProcessIdentity.processIdentifier,
                processStartIdentity: selectedProcessIdentity.processStartIdentity,
                windowID: selectedWindowIdentity?.windowID),
            selectedIndex: selectedIndex,
            selectedTitle: selectedTitle,
            selectedIdentifier: selectedIdentifier,
            selectedRole: selectedRole,
            selectedSubrole: selectedSubrole,
            selectedFrame: selectedFrame,
            candidateSetSHA256: candidateSetSHA256,
            candidateCount: candidateCount,
            winningCandidateCount: winningCandidateCount,
            hasWinningTie: hasWinningTie)
    }

    public var selectedProcessIdentity: ApplicationProcessIdentity {
        ApplicationProcessIdentity(
            processIdentifier: self.selectedTargetReceipt.processIdentifier,
            processStartIdentity: self.selectedTargetReceipt.processStartIdentity)
    }

    public func selects(window identity: WindowMutationIdentity?) -> Bool {
        guard let windowID = self.selectedTargetReceipt.windowID else { return identity == nil }
        guard let identity else { return false }
        return windowID == identity.windowID &&
            self.selectedTargetReceipt.processIdentifier == identity.ownerProcessIdentifier &&
            self.selectedTargetReceipt.processStartIdentity == identity.ownerProcessStartIdentity
    }
}
