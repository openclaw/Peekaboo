import PeekabooCore
import Testing

struct PeekabooPermissionOnboardingPolicyTests {
    @Test
    func `Signing migration notice appears once for existing users`() {
        #expect(PeekabooPermissionOnboardingPolicy.currentVersion == 2)
        #expect(
            PeekabooPermissionOnboardingPolicy.decision(
                seenVersion: 1,
                hasSeen: true,
                hasRequiredPermissions: false) == .show)
        #expect(
            PeekabooPermissionOnboardingPolicy.decision(
                seenVersion: 1,
                hasSeen: true,
                hasRequiredPermissions: true) == .show)
        #expect(
            PeekabooPermissionOnboardingPolicy.decision(
                seenVersion: 0,
                hasSeen: false,
                hasRequiredPermissions: true) == .markComplete)
        #expect(
            PeekabooPermissionOnboardingPolicy.decision(
                seenVersion: 2,
                hasSeen: true,
                hasRequiredPermissions: false) == .skip)
        #expect(
            PeekabooPermissionOnboardingPolicy.decision(
                seenVersion: 2,
                hasSeen: false,
                hasRequiredPermissions: false) == .show)
    }
}
