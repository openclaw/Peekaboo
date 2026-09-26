import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
@MainActor
struct BridgeExplicitSocketUnavailableErrorTests {
    @Test(arguments: [false, true], [false, true])
    func `Explicit socket refusal emits action metadata only for an action owner`(
        isAction: Bool,
        customDiagnostic: Bool
    ) async throws {
        let error = BridgeExplicitSocketUnavailableError(
            socketPath: "/synthetic/selected.sock",
            failureMessage: customDiagnostic ? "selected host cannot carry caller-local policy" : nil,
            failureHint: customDiagnostic ? "Remove the conflicting policy or explicitly use --no-remote." : nil
        )
        let data = try await captureStandardOutputBytes {
            defer { Logger.shared.setJsonOutputMode(false) }
            ResultEnvelopeContext.$isActionCommand.withValue(isAction) {
                printGenericError(error, jsonOutput: true)
            }
        }
        let response = try JSONDecoder().decode(JSONResponse.self, from: data)

        #expect(!response.success)
        #expect(response.error?.code == "BRIDGE_UNAVAILABLE")
        #expect(response.error?.message == error.localizedDescription)
        #expect(response.error?.hint == error.envelopeHint)
        #expect(response.effect == (isAction ? .refused : nil))
        #expect(response.error?.retry_safe == (isAction ? true : nil))
        #expect(response.error?.mutation_dispatched == (isAction ? false : nil))
        #expect(response.outcome == (isAction ? error.envelopeActionOutcome?.projection : nil))
        #expect(response.outcome?.refusalReason == (isAction ? .runtimeIncompatible : nil))
        #expect(response.target_identity == nil)
        #expect(response.target_receipt == nil)
        if customDiagnostic {
            #expect(error.errorDescription ==
                "Explicit Bridge socket '/synthetic/selected.sock' is unavailable: " +
                "selected host cannot carry caller-local policy")
            #expect(error.envelopeHint == "Remove the conflicting policy or explicitly use --no-remote.")
        } else {
            #expect(error.errorDescription ==
                "Explicit Bridge socket '/synthetic/selected.sock' is unavailable: " +
                "the host did not satisfy Peekaboo runtime requirements")
            #expect(error.envelopeHint ==
                "Start or relaunch the requested Bridge host, correct --bridge-socket, " +
                "or pass --no-remote to explicitly use the local runtime.")
        }
    }

    @Test
    func `Explicit socket refusal cannot overwrite an already accepted action result`() async throws {
        let error = BridgeExplicitSocketUnavailableError(socketPath: "/synthetic/selected.sock")
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: 42,
            processStartIdentity: 73,
            windowID: 9
        )
        let preserved = postResultProcessingError(
            error,
            outcome: outcome,
            targetReceipt: receipt,
            operation: "Synthetic post-result processing"
        )
        let data = try await captureStandardOutputBytes {
            defer { Logger.shared.setJsonOutputMode(false) }
            ResultEnvelopeContext.$isActionCommand.withValue(true) {
                printGenericError(preserved, jsonOutput: true)
            }
        }
        let response = try JSONDecoder().decode(JSONResponse.self, from: data)

        #expect(response.outcome == outcome.projection)
        #expect(response.effect == .unverifiable)
        #expect(response.error?.mutation_dispatched == true)
        #expect(response.error?.retry_safe == false)
        #expect(response.target_receipt == receipt)
    }
}
