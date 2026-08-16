import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeLifecycleDialogSelectorProofTests {
    @Test
    func `broad launch and relaunch receipts accept proof for the original selector`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let launch = PeekabooBridgeRequest.launchApplicationWithOptions(.init(
            applicationIdentifier: "Safari"))
        try await Self.signedApplicationBundle(
            fixture: fixture,
            sequence: 0,
            rawRequest: launch,
            application: fixture.safariApplication,
            outcome: nil).validate()

        let relaunch = PeekabooBridgeRequest.relaunchApplicationWithOptions(.init(
            targetIdentifier: "PID:\(Self.safariIdentity.processIdentifier)",
            expectedTargetIdentity: Self.safariIdentity,
            launchRequest: .init(applicationIdentifier: "Safari")))
        let relaunchedApplication = Self.application(
            candidate: Self.safariCandidate,
            identity: Self.relaunchedSafariIdentity,
            proof: fixture.safariResolution.proof(
                selectedProcessIdentity: Self.relaunchedSafariIdentity))
        try await Self.signedApplicationBundle(
            fixture: fixture,
            sequence: 1,
            rawRequest: relaunch,
            application: relaunchedApplication,
            outcome: Self.lifecycleOutcome).validate()
    }

    @Test
    func `broad lifecycle receipts reject a substituted fuzzy winner and missing proof`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let launch = PeekabooBridgeRequest.launchApplicationWithOptions(.init(
            applicationIdentifier: "Safari"))
        let relaunch = PeekabooBridgeRequest.relaunchApplicationWithOptions(.init(
            targetIdentifier: "PID:\(Self.safariIdentity.processIdentifier)",
            expectedTargetIdentity: Self.safariIdentity,
            launchRequest: .init(applicationIdentifier: "Safari")))
        let substitutedApplication = Self.application(
            candidate: Self.technologyPreviewCandidate,
            identity: Self.technologyPreviewIdentity,
            proof: fixture.safariProof)
        let missingProofApplication = Self.application(
            candidate: Self.safariCandidate,
            identity: Self.safariIdentity,
            proof: nil)
        let relaunchedMissingProofApplication = Self.application(
            candidate: Self.safariCandidate,
            identity: Self.relaunchedSafariIdentity,
            proof: nil)

        let substitutedLaunch = try await Self.signedApplicationBundle(
            fixture: fixture,
            sequence: 0,
            rawRequest: launch,
            application: substitutedApplication,
            outcome: nil)
        #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
            "application response selector proof application match kind or precedence"))
        {
            try substitutedLaunch.validate()
        }

        let missingLaunch = try await Self.signedApplicationBundle(
            fixture: fixture,
            sequence: 1,
            rawRequest: launch,
            application: missingProofApplication,
            outcome: nil)
        #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
            "application response selector proof missing application selector proof"))
        {
            try missingLaunch.validate()
        }

        let substitutedRelaunch = try await Self.signedApplicationBundle(
            fixture: fixture,
            sequence: 2,
            rawRequest: relaunch,
            application: substitutedApplication,
            outcome: Self.lifecycleOutcome)
        #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
            "application response selector proof application match kind or precedence"))
        {
            try substitutedRelaunch.validate()
        }

        let missingRelaunch = try await Self.signedApplicationBundle(
            fixture: fixture,
            sequence: 3,
            rawRequest: relaunch,
            application: relaunchedMissingProofApplication,
            outcome: Self.lifecycleOutcome)
        #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
            "application response selector proof missing application selector proof"))
        {
            try missingRelaunch.validate()
        }
    }

    @Test
    func `app-only dialog receipt requires a unique automatic window proof`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let selector = try DialogTargetSelector(applicationIdentifier: "Safari")
        let request = try PeekabooBridgeRequest.prepareDialogAction(.init(
            target: selector,
            kind: .clickButton,
            buttonText: "Save"))
        let window = Self.dialogWindow
        let exactTarget = try UIAutomationTarget.ExactWindow(
            identity: Self.dialogIdentity,
            bounds: Self.dialogBounds)
        let application = Self.application(
            candidate: Self.safariCandidate,
            identity: Self.safariIdentity,
            proof: fixture.safariProof)
        let automaticProof = try WindowSelectorResolutionProof.make(
            selection: .automatic,
            candidates: [window],
            selected: window,
            processIdentity: Self.safariIdentity)

        func response(windowProof: SelectorResolutionProof?) throws -> PeekabooBridgeResponse {
            let resolvedTarget = try ResolvedDialogTargetEvidence(
                target: exactTarget,
                application: application,
                window: window,
                windowResolutionProof: windowProof)
            return .preparedDialogAction(.init(
                token: UUID(),
                kind: .clickButton,
                target: exactTarget,
                resolvedTarget: resolvedTarget))
        }

        let valid = try await Self.signedBundle(
            fixture: fixture,
            sequence: 0,
            request: request,
            response: response(windowProof: automaticProof),
            target: .window(Self.dialogIdentity))
        try valid.validate()

        let ambiguousProof = SelectorResolutionProof(
            scope: automaticProof.scope,
            normalizedSelector: automaticProof.normalizedSelector,
            matchKind: automaticProof.matchKind,
            matchPrecedence: automaticProof.matchPrecedence,
            selectedProcessIdentity: automaticProof.selectedProcessIdentity,
            selectedWindowIdentity: automaticProof.selectedWindowIdentity,
            candidateSetSHA256: automaticProof.candidateSetSHA256,
            candidateCount: 2,
            winningCandidateCount: 2,
            hasWinningTie: true)
        let ambiguous = try await Self.signedBundle(
            fixture: fixture,
            sequence: 1,
            request: request,
            response: response(windowProof: ambiguousProof),
            target: .window(Self.dialogIdentity))
        #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
            "resolved dialog selector proof window ambiguous selector"))
        {
            try ambiguous.validate()
        }

        let missing = try await Self.signedBundle(
            fixture: fixture,
            sequence: 2,
            request: request,
            response: response(windowProof: nil),
            target: .window(Self.dialogIdentity))
        #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch(
            "resolved dialog selector proof missing window selector proof"))
        {
            try missing.validate()
        }
    }

    private struct Fixture {
        let root: URL
        let authority: PeekabooBridgeOperationReceiptAuthority
        let session: OperationReceiptSessionFixture
        let safariResolution: ApplicationIdentifierMatcher.Resolution

        var safariProof: SelectorResolutionProof {
            self.safariResolution.proof(selectedProcessIdentity: PeekabooBridgeLifecycleDialogSelectorProofTests
                .safariIdentity)
        }

        var safariApplication: ServiceApplicationInfo {
            PeekabooBridgeLifecycleDialogSelectorProofTests.application(
                candidate: PeekabooBridgeLifecycleDialogSelectorProofTests.safariCandidate,
                identity: PeekabooBridgeLifecycleDialogSelectorProofTests.safariIdentity,
                proof: self.safariProof)
        }
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

    private static let relaunchedSafariIdentity = ApplicationProcessIdentity(
        processIdentifier: 42,
        processStartIdentity: 1002)

    private static let technologyPreviewIdentity = ApplicationProcessIdentity(
        processIdentifier: 43,
        processStartIdentity: 2001)

    private static let dialogBounds = CGRect(x: 40, y: 60, width: 520, height: 320)

    private static let dialogIdentity = WindowMutationIdentity(
        windowID: 71,
        ownerProcessIdentifier: Self.safariIdentity.processIdentifier,
        ownerProcessStartIdentity: Self.safariIdentity.processStartIdentity,
        capturedBounds: Self.dialogBounds)

    private static let dialogWindow = ServiceWindowInfo(
        windowID: Self.dialogIdentity.windowID,
        title: "Save Document",
        bounds: Self.dialogBounds,
        index: 0,
        mutationIdentity: Self.dialogIdentity)

    private static let lifecycleOutcome = DesktopActionOutcome.confirmedChange(
        route: .bridge,
        delivery: .init(mechanism: .nativeFramework, mode: .background),
        unitCount: .one)

    private static func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-lifecycle-dialog-selector-proof-\(UUID().uuidString)",
            isDirectory: true)
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let resolution = try #require(try ApplicationIdentifierMatcher.resolution(
            for: "Safari",
            in: [Self.safariCandidate, Self.technologyPreviewCandidate]))
        return Fixture(
            root: root,
            authority: authority,
            session: session,
            safariResolution: resolution)
    }

    private static func application(
        candidate: ApplicationIdentifierMatcher.Candidate,
        identity: ApplicationProcessIdentity,
        proof: SelectorResolutionProof?) -> ServiceApplicationInfo
    {
        ServiceApplicationInfo(
            processIdentifier: identity.processIdentifier,
            processStartIdentity: identity.processStartIdentity,
            bundleIdentifier: candidate.bundleIdentifier,
            name: candidate.name,
            bundlePath: candidate.bundlePath,
            executablePath: candidate.executablePath,
            activationPolicy: .regular,
            selectorResolutionProofs: proof.map { [$0] })
    }

    private static func signedApplicationBundle(
        fixture: Fixture,
        sequence: UInt64,
        rawRequest: PeekabooBridgeRequest,
        application: ServiceApplicationInfo,
        outcome: DesktopActionOutcome?) async throws -> PeekabooBridgeOperationReceiptBundle
    {
        let request: PeekabooBridgeRequest
        let response: PeekabooBridgeResponse
        if let outcome {
            request = .projectedAction(.init(request: rawRequest))
            response = .projectedAction(.init(
                response: .application(application),
                outcome: outcome.projection))
        } else {
            request = rawRequest
            response = .application(application)
        }
        guard let processIdentity = application.processIdentity else {
            throw FixtureError.missingProcessIdentity
        }
        return try await Self.signedBundle(
            fixture: fixture,
            sequence: sequence,
            request: request,
            response: response,
            target: .process(processIdentity))
    }

    private static func signedBundle(
        fixture: Fixture,
        sequence: UInt64,
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse,
        target: PeekabooBridgeOperationTargetReceipt) async throws -> PeekabooBridgeOperationReceiptBundle
    {
        let claimed = try await fixture.session.acceptedClaim(
            authority: fixture.authority,
            sequence: sequence,
            request: request)
        defer { fixture.authority.complete(claimed.claim) }
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: fixture.authority,
            claim: claimed.claim,
            request: request,
            response: response,
            target: target,
            outcome: PeekabooBridgeOperationReceiptSemantics.outcome(in: response))
        let receipt = try await fixture.authority.signAndArchive(payload, claim: claimed.claim)
        return try OperationReceiptSessionFixture.bundle(
            authority: fixture.authority,
            sessionAttestation: fixture.session.attestation,
            receipt: receipt,
            request: request,
            response: response)
    }

    private enum FixtureError: Error {
        case missingProcessIdentity
    }
}
