import PeekabooFoundation
import Testing
@testable import PeekabooCertificationController

@Suite("Certification controller mutation outcome policy")
struct OutcomePolicyTests {
    private let background = DesktopActionOutcome.Delivery(
        mechanism: .windowTargetedEvents,
        mode: .background
    )

    @Test
    func `policy accepts confirmed or unverified background dispatch`() throws {
        try CertificationMutationOutcomePolicy.requireSuccessfulBackgroundDispatch(
            DesktopActionOutcome.confirmedChange(
                route: .bridge,
                delivery: self.background
            ).projection,
            operation: "fixture"
        )
        try CertificationMutationOutcomePolicy.requireSuccessfulBackgroundDispatch(
            DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: self.background,
                evidence: .deliveryAccepted
            ).projection,
            operation: "fixture"
        )
    }

    @Test
    func `policy rejects noop failure foreground and local outcomes`() {
        let rejected = [
            DesktopActionOutcome.suspectedNoop(route: .bridge, delivery: self.background),
            DesktopActionOutcome.refused(route: .bridge, reason: .targetUnavailable),
            DesktopActionOutcome.partial(route: .bridge, delivery: self.background),
            DesktopActionOutcome.indeterminate(
                route: .bridge,
                delivery: self.background,
                evidence: .completionUnknown
            ),
            DesktopActionOutcome.confirmedNoChange(route: .bridge),
            DesktopActionOutcome.confirmedChange(
                route: .bridge,
                delivery: .init(mechanism: .globalEvents, mode: .foreground)
            ),
            DesktopActionOutcome.confirmedChange(route: .local, delivery: self.background),
        ]

        for outcome in rejected {
            #expect(throws: CertificationControllerError.self) {
                try CertificationMutationOutcomePolicy.requireSuccessfulBackgroundDispatch(
                    outcome.projection,
                    operation: "fixture"
                )
            }
        }
    }
}
