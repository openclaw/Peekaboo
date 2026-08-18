import Testing
@testable import PeekabooFoundation

struct RawPressPolicyTests {
    @Test
    func `raw press foreground refusal owns one canonical outcome`() {
        let outcome = RawPressPolicy.foregroundConsentRefusal

        #expect(RawPressPolicy.errorCode == .interactionFailed)
        #expect(outcome.state == .refused)
        #expect(outcome.effect == .refused)
        #expect(outcome.dispatchState == .none)
        #expect(outcome.retrySafety == .safe)
        #expect(outcome.escalation == .correctRequest)
        #expect(outcome.refusalReason == .foregroundConsentRequired)
        #expect(RawPressPolicy.foregroundConsentRequiredMessage.contains("fresh exact receipt"))
        #expect(RawPressPolicy.foregroundConsentRequiredHint.contains("non-dialog snapshot"))
        #expect(RawPressPolicy.foregroundConsentRequiredHint.contains("--foreground"))
        #expect(RawPressPolicy.foregroundConsentRequiredHint.contains("foreground=true"))
        #expect(RawPressPolicy.foregroundConsentRequiredHint.contains("semantic action"))
    }
}
