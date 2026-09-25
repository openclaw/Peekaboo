import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
@MainActor
struct DesktopActionErrorCodeTests {
    @Test(arguments: [false, true], ["command", "generic", "render", "entrypoint"])
    func `Timeout code survives CLI rendering without losing prior effects`(
        priorFocus: Bool,
        emitter: String
    ) async throws {
        let timeout = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Synthetic admission deadline expired",
            standardErrorCode: .timeout
        )
        let sequence = CommandActionSequenceAccumulator()
        if priorFocus {
            try sequence.record(outcome: .confirmedChange(
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                unitCount: .one
            ))
        }
        let failure = try #require(sequence.preservingFailure(
            timeout,
            fallbackRoute: .local,
            message: timeout.message,
            hint: "Observe before retrying an action that already dispatched."
        ) as? DesktopActionFailure)
        #expect(failure.standardErrorCode == .timeout)
        #expect(failure.outcome.state == (priorFocus ? .indeterminate : .refused))
        #expect(failure.outcome.retrySafety == (priorFocus ? .unsafe : .safe))
        #expect(OutputCommand().mapErrorToCode(failure) == .TIMEOUT)
        #expect(genericErrorCode(for: failure) == .TIMEOUT)

        let output = try await Self.emit(failure, using: emitter)
        #expect(output.error?.code == "TIMEOUT")
        #expect(output.outcome == failure.outcome.projection)
        #expect(output.error?.retry_safe == !priorFocus)
        #expect(output.error?.mutation_dispatched == priorFocus)
    }

    @Test(arguments: [
        (StandardErrorCode?.none, ErrorCode.INTERACTION_FAILED),
        (.some(.snapshotStale), .SNAPSHOT_STALE),
        (.some(.snapshotNotFound), .SNAPSHOT_NOT_FOUND),
        (.some(.elementNotFound), .ELEMENT_NOT_FOUND),
        (.some(.captureFailed), .CAPTURE_FAILED),
    ], ["command", "generic", "render", "entrypoint"])
    func `Known action codes and unclassified failures have consistent CLI rendering`(
        code: (StandardErrorCode?, ErrorCode),
        emitter: String
    ) async throws {
        let failure = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Synthetic action refusal",
            standardErrorCode: code.0
        )
        #expect(OutputCommand().mapErrorToCode(failure) == code.1)
        #expect(genericErrorCode(for: failure) == code.1)
        let output = try await Self.emit(failure, using: emitter)
        #expect(output.error?.code == code.1.rawValue)
        #expect(output.outcome == failure.outcome.projection)
        #expect(output.error?.retry_safe == true)
        #expect(output.error?.mutation_dispatched == false)
    }

    private static func emit(_ failure: DesktopActionFailure, using emitter: String) async throws -> JSONResponse {
        let data = try await captureStandardOutputBytes {
            defer { Logger.shared.setJsonOutputMode(false) }
            switch emitter {
            case "command":
                OutputCommand().handleError(failure)
            case "generic":
                handleGenericError(failure, jsonOutput: true, logger: .shared)
            case "entrypoint":
                ResultEnvelopeContext.$isActionCommand.withValue(true) {
                    printGenericError(failure, jsonOutput: true)
                }
            default:
                renderDesktopActionFailure(failure, jsonOutput: true, logger: .shared)
            }
        }
        return try JSONDecoder().decode(JSONResponse.self, from: data)
    }

    private struct OutputCommand: ErrorHandlingCommand, ActionOutputFormattable {
        let jsonOutput = true
        let defaultEffect: ActionEffect? = .unverifiable
    }
}
