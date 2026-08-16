import Foundation
import PeekabooAutomationKit
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeSelectorResolutionReceiptSecurityTests {
    @Test
    func `signed application receipt rejects a substituted winner and missing proof`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = PeekabooBridgeRequest.findApplication(.init(identifier: "Safari"))

        let validApplication = Self.application(
            candidate: Self.safariCandidate,
            identity: Self.safariIdentity,
            proofs: [fixture.safariProof])
        let validBundle = try await Self.signedBundle(
            authority: fixture.authority,
            session: fixture.session,
            sequence: 0,
            request: request,
            response: .application(validApplication))
        try validBundle.validate()

        let substitutedWinner = Self.application(
            candidate: Self.technologyPreviewCandidate,
            identity: Self.technologyPreviewIdentity,
            proofs: [fixture.safariProof])
        let substitutedBundle = try await Self.signedBundle(
            authority: fixture.authority,
            session: fixture.session,
            sequence: 1,
            request: request,
            response: .application(substitutedWinner))
        #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
            "application response selector proof application match kind or precedence"))
        {
            try substitutedBundle.validate()
        }

        let missingProof = Self.application(
            candidate: Self.safariCandidate,
            identity: Self.safariIdentity,
            proofs: nil)
        let missingProofBundle = try await Self.signedBundle(
            authority: fixture.authority,
            session: fixture.session,
            sequence: 2,
            request: request,
            response: .application(missingProof))
        #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
            "application response selector proof missing application selector proof"))
        {
            try missingProofBundle.validate()
        }
    }

    @Test
    func `signed application receipt rejects forged selector proof metrics`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = PeekabooBridgeRequest.findApplication(.init(identifier: "Safari"))
        let forgeries = [
            Self.replacingProofMetrics(
                fixture.safariProof,
                candidateSetSHA256: String(repeating: "a", count: 63)),
            Self.replacingProofMetrics(fixture.safariProof, candidateCount: 0),
            Self.replacingProofMetrics(fixture.safariProof, hasWinningTie: true),
        ]

        for (sequence, forgedProof) in forgeries.enumerated() {
            let application = Self.application(
                candidate: Self.safariCandidate,
                identity: Self.safariIdentity,
                proofs: [forgedProof])
            let bundle = try await Self.signedBundle(
                authority: fixture.authority,
                session: fixture.session,
                sequence: UInt64(sequence),
                request: request,
                response: .application(application))
            #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
                "application response selector proof application candidate set"))
            {
                try bundle.validate()
            }
        }
    }

    @Test
    func `candidate digest alteration after signing invalidates the receipt`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = PeekabooBridgeRequest.findApplication(.init(identifier: "Safari"))
        let validApplication = Self.application(
            candidate: Self.safariCandidate,
            identity: Self.safariIdentity,
            proofs: [fixture.safariProof])
        let signed = try await Self.signedReceipt(
            authority: fixture.authority,
            session: fixture.session,
            sequence: 0,
            request: request,
            response: .application(validApplication))
        let alteredProof = Self.replacingProofMetrics(
            fixture.safariProof,
            candidateSetSHA256: String(repeating: "f", count: 64))
        let alteredApplication = Self.application(
            candidate: Self.safariCandidate,
            identity: Self.safariIdentity,
            proofs: [alteredProof])
        let alteredBundle = try OperationReceiptSessionFixture.bundle(
            authority: fixture.authority,
            sessionAttestation: fixture.session.attestation,
            receipt: signed,
            request: request,
            response: .application(alteredApplication))

        #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
            "the exported verification bundle"))
        {
            try alteredBundle.validate()
        }
    }

    private struct Fixture {
        let root: URL
        let authority: PeekabooBridgeOperationReceiptAuthority
        let session: OperationReceiptSessionFixture
        let safariProof: SelectorResolutionProof
    }

    private static let safariCandidate = ApplicationIdentifierMatcher.Candidate(
        processIdentifier: 42,
        bundleIdentifier: "com.apple.Safari",
        name: "Safari",
        bundlePath: "/Applications/Safari.app",
        executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
        isRegularApplication: true)

    private static let technologyPreviewCandidate = ApplicationIdentifierMatcher.Candidate(
        processIdentifier: 43,
        bundleIdentifier: "com.apple.SafariTechnologyPreview",
        name: "Safari Technology Preview",
        bundlePath: "/Applications/Safari Technology Preview.app",
        executablePath: "/Applications/Safari Technology Preview.app/Contents/MacOS/Safari Technology Preview",
        isRegularApplication: true)

    private static let safariIdentity = ApplicationProcessIdentity(
        processIdentifier: 42,
        processStartIdentity: 1001)

    private static let technologyPreviewIdentity = ApplicationProcessIdentity(
        processIdentifier: 43,
        processStartIdentity: 1002)

    private static func makeFixture() async throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp/pbor-selector-\(UUID().uuidString)", isDirectory: true)
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let resolution = try #require(try ApplicationIdentifierMatcher.resolution(
            for: "Safari",
            in: [Self.safariCandidate, Self.technologyPreviewCandidate]))
        return Fixture(
            root: root,
            authority: authority,
            session: session,
            safariProof: resolution.proof(selectedProcessIdentity: Self.safariIdentity))
    }

    private static func application(
        candidate: ApplicationIdentifierMatcher.Candidate,
        identity: ApplicationProcessIdentity,
        proofs: [SelectorResolutionProof]?) -> ServiceApplicationInfo
    {
        ServiceApplicationInfo(
            processIdentifier: identity.processIdentifier,
            processStartIdentity: identity.processStartIdentity,
            bundleIdentifier: candidate.bundleIdentifier,
            name: candidate.name,
            bundlePath: candidate.bundlePath,
            executablePath: candidate.executablePath,
            activationPolicy: .regular,
            selectorResolutionProofs: proofs)
    }

    private static func replacingProofMetrics(
        _ proof: SelectorResolutionProof,
        candidateSetSHA256: String? = nil,
        candidateCount: Int? = nil,
        hasWinningTie: Bool? = nil) -> SelectorResolutionProof
    {
        SelectorResolutionProof(
            scope: proof.scope,
            normalizedSelector: proof.normalizedSelector,
            matchKind: proof.matchKind,
            matchPrecedence: proof.matchPrecedence,
            selectedProcessIdentity: proof.selectedProcessIdentity,
            selectedWindowIdentity: proof.selectedWindowIdentity,
            candidateSetSHA256: candidateSetSHA256 ?? proof.candidateSetSHA256,
            candidateCount: candidateCount ?? proof.candidateCount,
            winningCandidateCount: proof.winningCandidateCount,
            hasWinningTie: hasWinningTie ?? proof.hasWinningTie)
    }

    private static func signedBundle(
        authority: PeekabooBridgeOperationReceiptAuthority,
        session: OperationReceiptSessionFixture,
        sequence: UInt64,
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse) async throws -> PeekabooBridgeOperationReceiptBundle
    {
        let receipt = try await Self.signedReceipt(
            authority: authority,
            session: session,
            sequence: sequence,
            request: request,
            response: response)
        return try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: receipt,
            request: request,
            response: response)
    }

    private static func signedReceipt(
        authority: PeekabooBridgeOperationReceiptAuthority,
        session: OperationReceiptSessionFixture,
        sequence: UInt64,
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse) async throws -> PeekabooBridgeOperationReceipt
    {
        guard case let .application(application) = response,
              let target = application.processIdentity
        else {
            throw FixtureError.missingApplicationProcessIdentity
        }
        let claimed = try await session.acceptedClaim(
            authority: authority,
            sequence: sequence,
            request: request)
        defer { authority.complete(claimed.claim) }
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: claimed.claim,
            request: request,
            response: response,
            target: .process(target))
        return try await authority.signAndArchive(payload, claim: claimed.claim)
    }

    private enum FixtureError: Error {
        case missingApplicationProcessIdentity
    }
}
