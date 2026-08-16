import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeDockVisibilityResultTests {
    @Test
    @MainActor
    func `Bridge preserves partial Dock restart progress and retry safety`() throws {
        let localFailure = DesktopActionFailure.partial(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one,
            message: "The Dock autohide preference was written, but Dock could not be restarted.")

        let envelope = PeekabooBridgeServer.bridgeErrorEnvelope(
            for: localFailure,
            operation: .hideDock)
        let failure = try #require(envelope.desktopActionFailure)

        #expect(failure.outcome == .partial(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one))
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.outcome.escalation == .recoverSideEffect)
        #expect(failure.message == localFailure.message)
    }
}
