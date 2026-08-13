import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

struct ActionEnvelopeTestProbe: Decodable {
    let success: Bool
    let effect: ActionEffect?
    let outcome: DesktopActionOutcome.Projection?
    let data: Empty?
    let error: ErrorInfo?

    static func decode(_ output: String) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(output.utf8))
    }
}

enum ActionEnvelopeTestAssertions {
    static func expectCanonicalOutcome(
        _ outcome: DesktopActionOutcome,
        in envelope: ActionEnvelopeTestProbe,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(envelope.effect == outcome.effect, sourceLocation: sourceLocation)
        #expect(envelope.outcome == outcome.projection, sourceLocation: sourceLocation)
        #expect(
            envelope.error?.retry_safe == nil ||
                envelope.error?.retry_safe == (outcome.retrySafety == .safe),
            sourceLocation: sourceLocation
        )
        #expect(
            envelope.error?.mutation_dispatched == nil ||
                envelope.error?.mutation_dispatched == outcome.dispatchState.mutationDispatched,
            sourceLocation: sourceLocation
        )
    }

    static func expectCanonicalRefusal(
        reason: DesktopActionOutcome.RefusalReason,
        in envelope: ActionEnvelopeTestProbe,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        self.expectCanonicalOutcome(
            .refused(reason: reason),
            in: envelope,
            sourceLocation: sourceLocation
        )
        #expect(envelope.success == false, sourceLocation: sourceLocation)
        #expect(envelope.error?.retry_safe == true, sourceLocation: sourceLocation)
        #expect(envelope.error?.mutation_dispatched == false, sourceLocation: sourceLocation)
    }
}
