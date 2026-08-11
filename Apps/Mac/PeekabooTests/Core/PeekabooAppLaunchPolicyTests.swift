import Testing
@testable import Peekaboo

@Suite(.tags(.unit, .fast))
struct PeekabooAppLaunchPolicyTests {
    @Test
    func `ordinary launch remains interactive`() {
        let policy = PeekabooAppLaunchPolicy(arguments: ["Peekaboo"])

        #expect(policy.mode == .interactive)
        #expect(policy.allowsPresentation(.automatic))
        #expect(policy.allowsPresentation(.reopen))
        #expect(policy.allowsPresentation(.explicitUser))
        #expect(policy.allowsAPIKeyNudge)
        #expect(policy.allowsPermissionsOnboarding)
        #expect(!policy.suppressesAutomaticScenePresentation)
        #expect(!policy.disablesSceneRestoration)
        #expect(policy.maximumBridgeOwnershipRetries == nil)
        #expect(!policy.terminatesOnPermanentBridgeFailure)
    }

    @Test
    func `background Bridge host launch is unattended and fail closed`() {
        let policy = PeekabooAppLaunchPolicy(arguments: [
            "/Applications/Peekaboo.app/Contents/MacOS/Peekaboo",
            PeekabooAppLaunchPolicy.backgroundBridgeHostArgument,
        ])

        #expect(policy.mode == .backgroundBridgeHost)
        #expect(!policy.allowsPresentation(.automatic))
        #expect(!policy.allowsPresentation(.reopen))
        #expect(policy.allowsPresentation(.explicitUser))
        #expect(!policy.allowsAPIKeyNudge)
        #expect(!policy.allowsPermissionsOnboarding)
        #expect(policy.suppressesAutomaticScenePresentation)
        #expect(policy.disablesSceneRestoration)
        #expect(policy.maximumBridgeOwnershipRetries == 6)
        #expect(policy.terminatesOnPermanentBridgeFailure)
    }

    @Test
    func `background Bridge host argument must be exact`() {
        let policy = PeekabooAppLaunchPolicy(arguments: [
            "Peekaboo",
            "--background-bridge-host=true",
        ])

        #expect(policy.mode == .interactive)
    }
}
