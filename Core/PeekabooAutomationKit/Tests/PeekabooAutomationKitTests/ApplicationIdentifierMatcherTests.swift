import Foundation
import PeekabooAutomationKit
import Testing

struct ApplicationIdentifierMatcherTests {
    @Test
    func `Matcher accepts every application discovery selector form`() {
        let candidate = ApplicationIdentifierMatcher.Candidate(
            processIdentifier: 42,
            bundleIdentifier: "org.openclaw.desktop-test",
            name: "OpenClaw Desktop Test",
            bundlePath: "/Applications/OpenClaw Desktop Test.app",
            executablePath: "/Applications/OpenClaw Desktop Test.app/Contents/MacOS/openclaw-desktop",
            isRegularApplication: true)

        for selector in [
            "PID:42",
            "org.openclaw.desktop-test",
            "/Applications/OpenClaw Desktop Test.app",
            "openclaw desktop test",
            "openclaw-desktop",
            "claw desk",
            "claw-desk",
        ] {
            #expect(ApplicationIdentifierMatcher.matches(candidate, identifier: selector))
        }
        #expect(!ApplicationIdentifierMatcher.matches(candidate, identifier: "PID:43"))
        #expect(!ApplicationIdentifierMatcher.matches(candidate, identifier: "Other App"))
    }

    @Test
    func `Matcher retains discovery precedence and fuzzy eligibility`() {
        let prohibitedExact = ApplicationIdentifierMatcher.Candidate(
            processIdentifier: 10,
            bundleIdentifier: "org.example.helper",
            name: "Example Helper",
            executablePath: "/Applications/Example.app/Contents/MacOS/example-helper",
            allowsFuzzyMatching: false)
        let regularFuzzy = ApplicationIdentifierMatcher.Candidate(
            processIdentifier: 11,
            bundleIdentifier: "org.example.app",
            name: "Example",
            executablePath: "/Applications/Example.app/Contents/MacOS/example",
            isRegularApplication: true)

        let candidates = [prohibitedExact, regularFuzzy]
        #expect(ApplicationIdentifierMatcher.bestMatchIndex(for: "org.example.helper", in: candidates) == 0)
        #expect(ApplicationIdentifierMatcher.bestMatchIndex(for: "Exam", in: candidates) == 1)
        #expect(ApplicationIdentifierMatcher.bestMatchIndex(for: "   ", in: candidates) == nil)
    }

    @Test
    func `Prohibited helpers reject fuzzy selectors but retain exact selectors`() {
        let helper = ApplicationIdentifierMatcher.Candidate(
            processIdentifier: 42,
            bundleIdentifier: "org.openclaw.fixture.helper",
            name: "OpenClaw Fixture Helper",
            bundlePath: "/Applications/OpenClaw Fixture.app",
            executablePath: "/Applications/OpenClaw Fixture.app/Contents/MacOS/openclaw-fixture-helper",
            allowsFuzzyMatching: false)

        for fuzzySelector in ["Fixture", "fixture-helper"] {
            #expect(!ApplicationIdentifierMatcher.matches(helper, identifier: fuzzySelector))
        }

        for exactSelector in [
            "PID:42",
            "org.openclaw.fixture.helper",
            "/Applications/OpenClaw Fixture.app",
            "openclaw fixture helper",
            "openclaw-fixture-helper",
        ] {
            #expect(ApplicationIdentifierMatcher.matches(helper, identifier: exactSelector))
        }
    }

    @Test
    func `Resolution proof binds the exact Safari winner independent of inventory order`() throws {
        let safari = ApplicationIdentifierMatcher.Candidate(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            name: "Safari",
            executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
            isRegularApplication: true)
        let technologyPreview = ApplicationIdentifierMatcher.Candidate(
            processIdentifier: 43,
            bundleIdentifier: "com.apple.SafariTechnologyPreview",
            name: "Safari Technology Preview",
            executablePath: "/Applications/Safari Technology Preview.app/Contents/MacOS/Safari Technology Preview",
            isRegularApplication: true)

        let forwardResolution = try ApplicationIdentifierMatcher.resolution(
            for: "Safari",
            in: [safari, technologyPreview])
        let reversedResolution = try ApplicationIdentifierMatcher.resolution(
            for: "Safari",
            in: [technologyPreview, safari])
        let forward = try #require(forwardResolution)
        let reversed = try #require(reversedResolution)
        #expect(forward.matchKind == .exactName)
        #expect(forward.index == 0)
        #expect(reversed.index == 1)
        #expect(forward.candidateSetSHA256 == reversed.candidateSetSHA256)

        let processIdentity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 1001)
        let proof = forward.proof(selectedProcessIdentity: processIdentity)
        #expect(proof.applicationMismatch(
            identifier: "Safari",
            selectedCandidate: safari,
            processIdentity: processIdentity) == nil)
        #expect(proof.applicationMismatch(
            identifier: "Safari",
            selectedCandidate: technologyPreview,
            processIdentity: .init(processIdentifier: 43, processStartIdentity: 1002)) != nil)
    }

    @Test
    func `Tied fuzzy winners are explicit and fail closed`() throws {
        let candidates = [
            ApplicationIdentifierMatcher.Candidate(
                processIdentifier: 42,
                bundleIdentifier: "org.example.alpha",
                name: "Fixture Alpha",
                isRegularApplication: true),
            ApplicationIdentifierMatcher.Candidate(
                processIdentifier: 43,
                bundleIdentifier: "org.example.bravo",
                name: "Fixture Bravo",
                isRegularApplication: true),
        ]
        let optionalResolution = try ApplicationIdentifierMatcher.resolution(
            for: "Fixture",
            in: candidates)
        let resolution = try #require(optionalResolution)
        #expect(resolution.matchKind == .fuzzyNameOrExecutable)
        #expect(resolution.winningCandidateCount == 2)
        #expect(resolution.hasWinningTie)
        let selected = candidates[resolution.index]
        let identity = ApplicationProcessIdentity(
            processIdentifier: selected.processIdentifier,
            processStartIdentity: 1001)
        #expect(resolution.proof(selectedProcessIdentity: identity).applicationMismatch(
            identifier: "Fixture",
            selectedCandidate: selected,
            processIdentity: identity) == "ambiguous selector")
    }

    @Test
    func `Resolution proof candidate set is bounded`() {
        let candidates = (0...ApplicationIdentifierMatcher.maximumProofCandidateCount).map { index in
            ApplicationIdentifierMatcher.Candidate(
                processIdentifier: Int32(index + 1),
                bundleIdentifier: "org.example.\(index)",
                name: "Fixture \(index)")
        }
        #expect(throws: ApplicationIdentifierMatcher.ResolutionError.self) {
            try ApplicationIdentifierMatcher.resolution(for: "Fixture", in: candidates)
        }
    }

    @Test
    func `Legacy application evidence decodes without selector proof`() throws {
        let serviceJSON = Data(
            #"{"processIdentifier":42,"name":"Fixture","isActive":false,"isHidden":false,"windowCount":0}"#.utf8)
        let service = try JSONDecoder().decode(ServiceApplicationInfo.self, from: serviceJSON)
        #expect(service.selectorResolutionProofs == nil)

        let identityJSON = Data(#"{"processIdentifier":42,"name":"Fixture"}"#.utf8)
        let identity = try JSONDecoder().decode(ApplicationIdentity.self, from: identityJSON)
        #expect(identity.selectorResolutionProofs == nil)
        #expect(identity.activationPolicy == nil)
    }
}
