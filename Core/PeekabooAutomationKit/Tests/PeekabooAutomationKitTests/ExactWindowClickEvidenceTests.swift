import CoreGraphics
import PeekabooAutomationKit
import PeekabooFoundation
import Testing

@MainActor
struct ExactWindowClickEvidenceTests {
    @Test
    func `raw click evidence preserves missing and contradictory captured bounds`() {
        let capturedBoundsCases: [CGRect?] = [nil, CGRect(x: 10, y: 20, width: 300, height: 200)]
        for capturedBounds in capturedBoundsCases {
            let identity = WindowMutationIdentity(
                windowID: 71,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 1001,
                capturedBounds: capturedBounds)
            let evidence = ExactWindowClickEvidence(identity: identity, bounds: .zero)

            #expect(evidence.identity == identity)
            #expect(evidence.identity.capturedBounds == capturedBounds)
            #expect(evidence.bounds == .zero)
        }
    }

    @Test
    func `legacy exact click conformer forwards true once and refuses false before dispatch`() async throws {
        let service = LegacyExactWindowClickConformer()
        let provider: any ExactWindowTargetedClickServiceProtocol = service
        let evidence = Self.evidence

        // Invalid bounds must not preempt the explicit-policy refusal in the protocol default.
        do {
            try await provider.click(
                target: .elementId("field"),
                clickType: .double,
                snapshotId: "legacy-snapshot",
                windowEvidence: evidence,
                allowsAccessibilityValueDelivery: false)
            Issue.record("Expected legacy-provider opt-out refusal")
        } catch let PeekabooError.serviceUnavailable(message) {
            #expect(message == "This automation service cannot enforce an accessibility-value click opt-out")
        }
        #expect(service.clickCalls.isEmpty)
        #expect(service.outcomeCalls.isEmpty)

        try await provider.click(
            target: .elementId("field"),
            clickType: .double,
            snapshotId: "legacy-snapshot",
            windowEvidence: evidence,
            allowsAccessibilityValueDelivery: true)

        let call = try #require(service.clickCalls.only)
        guard case let .elementId(elementID) = call.target else {
            Issue.record("Expected the unchanged element target")
            return
        }
        #expect(elementID == "field")
        #expect(call.clickType == .double)
        #expect(call.snapshotID == "legacy-snapshot")
        #expect(call.identity == evidence.identity)
        #expect(call.bounds == evidence.bounds)
        #expect(service.outcomeCalls.isEmpty)
    }

    @Test
    func `legacy exact outcome conformer forwards true once and preserves its result`() async throws {
        let service = LegacyExactWindowClickConformer()
        let provider: any UIAutomationActionOutcomeProviding = service
        let evidence = Self.evidence

        do {
            _ = try await provider.clickWithOutcome(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: "legacy-snapshot",
                windowEvidence: evidence,
                allowsAccessibilityValueDelivery: false)
            Issue.record("Expected legacy-provider opt-out refusal")
        } catch let PeekabooError.serviceUnavailable(message) {
            #expect(message == "This automation service cannot enforce an accessibility-value click opt-out")
        }
        #expect(service.outcomeCalls.isEmpty)
        #expect(service.clickCalls.isEmpty)

        let result = try await provider.clickWithOutcome(
            target: .elementId("field"),
            clickType: .single,
            snapshotId: "legacy-snapshot",
            windowEvidence: evidence,
            allowsAccessibilityValueDelivery: true)

        let call = try #require(service.outcomeCalls.only)
        guard case let .elementId(elementID) = call.target else {
            Issue.record("Expected the unchanged element target")
            return
        }
        #expect(elementID == "field")
        #expect(call.clickType == .single)
        #expect(call.snapshotID == "legacy-snapshot")
        #expect(call.identity == evidence.identity)
        #expect(call.bounds == evidence.bounds)
        #expect(result.outcome == service.result.outcome)
        #expect(result.targetIdentity == service.result.targetIdentity)
        #expect(service.clickCalls.isEmpty)
    }

    private static var evidence: ExactWindowClickEvidence {
        ExactWindowClickEvidence(
            identity: WindowMutationIdentity(
                windowID: 71,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 1001,
                capturedBounds: CGRect(x: 10, y: 20, width: 300, height: 200)),
            bounds: .zero)
    }
}

extension Array {
    fileprivate var only: Element? {
        self.count == 1 ? self.first : nil
    }
}
