import CoreGraphics
import PeekabooAutomationKit
import Testing

struct WindowSelectorResolutionProofTests {
    @Test
    func `Exact title wins over partial title and digest ignores inventory order`() throws {
        let process = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 1001)
        let safari = Self.window(id: 70, title: "Safari", index: 0, process: process)
        let preview = Self.window(id: 71, title: "Safari Technology Preview", index: 1, process: process)
        let selection = WindowSelection.title("Safari")

        let forward = try WindowSelectorResolutionProof.make(
            selection: selection,
            candidates: [safari, preview],
            selected: safari,
            processIdentity: process)
        let reversed = try WindowSelectorResolutionProof.make(
            selection: selection,
            candidates: [preview, safari],
            selected: safari,
            processIdentity: process)

        #expect(forward.matchKind == .exactWindowTitle)
        #expect(forward.candidateSetSHA256 == reversed.candidateSetSHA256)
        #expect(forward.windowMismatch(
            selection: selection,
            selectedWindow: safari,
            processIdentity: process) == nil)
        #expect(forward.windowMismatch(
            selection: selection,
            selectedWindow: preview,
            processIdentity: process) != nil)
    }

    @Test
    func `Ambiguous partial title proof fails closed`() throws {
        let process = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 1001)
        let first = Self.window(id: 70, title: "Document A", index: 0, process: process)
        let second = Self.window(id: 71, title: "Document B", index: 1, process: process)
        let selection = WindowSelection.title("Document")
        let proof = try WindowSelectorResolutionProof.make(
            selection: selection,
            candidates: [first, second],
            selected: first,
            processIdentity: process)

        #expect(proof.matchKind == .partialWindowTitle)
        #expect(proof.winningCandidateCount == 2)
        #expect(proof.hasWinningTie)
        #expect(proof.windowMismatch(
            selection: selection,
            selectedWindow: first,
            processIdentity: process) == "ambiguous selector")
    }

    @Test
    func `Proof creation rejects a candidate that did not win the selector`() {
        let process = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 1001)
        let safari = Self.window(id: 70, title: "Safari", index: 0, process: process)
        let preview = Self.window(id: 71, title: "Safari Technology Preview", index: 1, process: process)
        let mail = Self.window(id: 72, title: "Mail", index: 2, process: process)
        let candidates = [safari, preview, mail]

        for (selection, selected) in [
            (WindowSelection.id(70), preview),
            (.index(0), preview),
            (.title("Safari"), preview),
            (.title("Safari Technology"), mail),
        ] {
            #expect(throws: WindowSelectorResolutionProof.ResolutionError.selectedWindowDoesNotMatchSelector) {
                try WindowSelectorResolutionProof.make(
                    selection: selection,
                    candidates: candidates,
                    selected: selected,
                    processIdentity: process)
            }
        }
    }

    @Test
    func `Receipt validation rejects a forged wrong selected candidate for every selector kind`() throws {
        let process = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 1001)
        let safari = Self.window(id: 70, title: "Safari", index: 0, process: process)
        let document = Self.window(id: 71, title: "Document A", index: 1, process: process)
        let mail = Self.window(id: 72, title: "Mail", index: 2, process: process)
        let preview = Self.window(id: 73, title: "Safari Technology Preview", index: 3, process: process)
        let candidates = [safari, document, mail, preview]

        for (selection, selected, forged) in [
            (WindowSelection.id(70), safari, document),
            (.index(0), safari, document),
            (.title("Document"), document, mail),
        ] {
            let valid = try WindowSelectorResolutionProof.make(
                selection: selection,
                candidates: candidates,
                selected: selected,
                processIdentity: process)
            let forgedProof = Self.selecting(valid, window: forged)

            #expect(forgedProof.windowMismatch(
                selection: selection,
                selectedWindow: forged,
                processIdentity: process) == "selected window selector")
        }

        let exactTitleProof = try WindowSelectorResolutionProof.make(
            selection: .title("Safari"),
            candidates: candidates,
            selected: safari,
            processIdentity: process)
        let forgedExactTitleProof = Self.selecting(
            exactTitleProof,
            window: preview)
        #expect(forgedExactTitleProof.windowMismatch(
            selection: .title("Safari"),
            selectedWindow: preview,
            processIdentity: process) == "match kind or precedence")
    }

    private static func selecting(
        _ proof: SelectorResolutionProof,
        window: ServiceWindowInfo) -> SelectorResolutionProof
    {
        SelectorResolutionProof(
            scope: proof.scope,
            normalizedSelector: proof.normalizedSelector,
            matchKind: proof.matchKind,
            matchPrecedence: proof.matchPrecedence,
            selectedProcessIdentity: proof.selectedProcessIdentity,
            selectedWindowIdentity: window.mutationIdentity,
            candidateSetSHA256: proof.candidateSetSHA256,
            candidateCount: proof.candidateCount,
            winningCandidateCount: proof.winningCandidateCount,
            hasWinningTie: proof.hasWinningTie)
    }

    private static func window(
        id: Int,
        title: String,
        index: Int,
        process: ApplicationProcessIdentity) -> ServiceWindowInfo
    {
        let bounds = CGRect(x: 20 + index * 10, y: 30, width: 640, height: 480)
        return ServiceWindowInfo(
            windowID: id,
            title: title,
            bounds: bounds,
            index: index,
            mutationIdentity: WindowMutationIdentity(
                windowID: id,
                ownerProcessIdentifier: process.processIdentifier,
                ownerProcessStartIdentity: process.processStartIdentity,
                capturedBounds: bounds))
    }
}
