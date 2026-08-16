import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooCLI

struct ResultEnvelopeTests {
    private struct Payload: Codable { let value: Int }

    @Test func `success envelope round trips every canonical nested outcome`() throws {
        for outcome in DesktopActionOutcomeFixtures.canonicalOutcomes {
            let envelope = makeSuccessEnvelope(
                data: Payload(value: 1),
                effect: .confirmed,
                outcome: outcome
            )
            let data = try JSONEncoder().encode(envelope)
            let decoded = try JSONDecoder().decode(ResultEnvelope<Payload>.self, from: data)

            #expect(decoded.outcome == outcome.projection)
            #expect(decoded.effect == outcome.effect)
        }
    }

    @Test func `nested canonical outcome rejects contradictory derived fields`() throws {
        let outcome = DesktopActionOutcomeFixtures.canonicalOutcomes[0]
        let encoded = try JSONEncoder().encode(makeSuccessEnvelope(data: Payload(value: 1), outcome: outcome))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var projection = try #require(object["outcome"] as? [String: Any])
        projection["retry_safe"] = true
        object["outcome"] = projection
        let tampered = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ResultEnvelope<Payload>.self, from: tampered)
        }
    }

    @Test func `canonical failure drives nested and legacy result fields`() {
        let failures = [
            DesktopActionFailure.refused(
                route: .bridge,
                reason: .permissionDenied,
                message: "Permission was denied"
            ),
            DesktopActionFailure.partial(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                unitCount: DesktopActionOutcome.DispatchUnitCount(2),
                message: "Cleanup failed"
            ),
            DesktopActionFailure.indeterminate(
                route: .bridge,
                evidence: .responseLost,
                unitCount: DesktopActionOutcome.DispatchUnitCount(3),
                message: "Response was lost"
            ),
        ]

        for failure in failures {
            let envelope = makeErrorEnvelope(
                message: failure.message,
                code: .INTERACTION_FAILED,
                effect: .confirmed,
                retrySafe: true,
                mutationDispatched: false,
                actionFailure: failure
            )

            #expect(envelope.outcome == failure.outcome.projection)
            #expect(envelope.effect == failure.outcome.effect)
            #expect(envelope.error?.retry_safe == (failure.outcome.retrySafety == .safe))
            #expect(envelope.error?.mutation_dispatched == failure.outcome.dispatchState.mutationDispatched)
        }
    }

    @Test func `canonical human statuses are state and escalation aware`() {
        let expected = [
            "✅ Click confirmed",
            "✅ Click confirmed; no change was needed",
            "⚠️ Click partially completed; recover the remaining side effect before another attempt",
            "⚠️ Click dispatched but not verified; observe the target before retrying",
            "⚠️ Click may have had no effect; refresh the target before retrying",
            "⛔ Click refused before dispatch; grant the required permission before retrying",
            "⚠️ Click outcome is indeterminate; observe the target before retrying",
        ]

        for (outcome, expectedLine) in zip(DesktopActionOutcomeFixtures.canonicalOutcomes, expected) {
            #expect(ActionOutcomeHumanRenderer.statusLine(for: outcome, operation: "Click") == expectedLine)
        }

        let reconnect = DesktopActionOutcome.refused(
            route: .bridge,
            reason: .transportSessionUnavailable
        )
        #expect(ActionOutcomeHumanRenderer.statusLine(for: reconnect, operation: "Click") ==
            "⛔ Click refused before dispatch; reconnect the Bridge session before retrying")
    }

    @Test func `Space switch human detail never claims unverified dispatch completed`() {
        let dispatched = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one
        )

        let detail = spaceSwitchCompletionMessage(outcome: dispatched, spaceNumber: 3)

        #expect(detail == "Space switch dispatched to Space 3, but completion was not verified")
        #expect(!detail.contains("✓"))
        #expect(!detail.contains("Switched to"))
    }

    @Test func `canonical failure envelope carries resolved target receipt without inference`() {
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: 42,
            processStartIdentity: 9_007_199_254_740_993,
            windowID: 73
        )
        let failure = DesktopActionFailure.dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one,
            message: "Dialog input partially dispatched"
        )
        .attributed(to: receipt)

        let envelope = makeErrorEnvelope(
            message: failure.message,
            code: .INTERACTION_FAILED,
            actionFailure: failure
        )

        #expect(envelope.target_receipt == receipt)
        #expect(envelope.outcome == failure.outcome.projection)
    }

    @Test func `success and error envelopes publish process-only target receipts`() throws {
        let identity = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 9_007_199_254_740_993
        )
        let targetIdentity = try DesktopTargetIdentity(processIdentity: identity)
        let expectedReceipt = DesktopActionTargetReceipt(
            processIdentifier: identity.processIdentifier,
            processStartIdentity: identity.processStartIdentity
        )

        let success = makeSuccessEnvelope(
            data: Payload(value: 1),
            targetIdentity: targetIdentity
        )
        let failure = makeErrorEnvelope(
            message: "Fixture failure",
            code: .INTERACTION_FAILED,
            targetIdentity: targetIdentity
        )

        #expect(success.target_receipt == expectedReceipt)
        #expect(failure.target_receipt == expectedReceipt)
    }

    @Test func `post-result processing preserves every accepted outcome and raw target receipt`() throws {
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: .capturePipeline,
            mode: .background
        )
        let outcomes: [DesktopActionOutcome] = [
            .confirmedChange(route: .bridge, delivery: delivery, unitCount: .one),
            .confirmedNoChange(route: .bridge),
            .dispatchedUnverified(
                route: .bridge,
                delivery: delivery,
                evidence: .deliveryAccepted,
                unitCount: .one
            ),
        ]
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: 42,
            processStartIdentity: 9_007_199_254_740_993,
            windowID: 73
        )

        for outcome in outcomes {
            let error = postResultProcessingError(
                CocoaError(.fileWriteUnknown),
                outcome: outcome,
                targetReceipt: receipt,
                operation: "Fixture publication"
            )
            let envelopeError = try #require(error as? any ResultEnvelopeError)
            let metadata = actionErrorEnvelopeMetadata(for: error, isActionCommand: true)
            let envelope = makeErrorEnvelope(
                message: error.localizedDescription,
                code: .INTERACTION_FAILED,
                retrySafe: metadata.retrySafe,
                mutationDispatched: metadata.mutationDispatched,
                actionOutcome: metadata.outcome,
                actionFailure: metadata.failure,
                targetReceipt: metadata.targetReceipt
            )

            #expect(metadata.outcome == outcome)
            #expect(metadata.targetReceipt == receipt)
            #expect(metadata.failure == (outcome.isConfirmed ? nil : envelopeError.envelopeActionFailure))
            #expect(envelope.outcome == outcome.projection)
            #expect(envelope.target_receipt == receipt)
            #expect(envelope.error?.mutation_dispatched == outcome.dispatchState.mutationDispatched)
        }
    }

    @Test func `action envelope includes effect`() throws {
        let envelope = ResultEnvelope(success: true, effect: .unverifiable, data: Payload(value: 1))
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any]
        )

        #expect(object["success"] as? Bool == true)
        #expect(object["effect"] as? String == "unverifiable")
    }

    @Test func `read envelope omits effect`() throws {
        let envelope = ResultEnvelope(success: true, data: Payload(value: 1))
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any]
        )

        #expect(object["effect"] == nil)
    }

    @Test func `existing next-step sentence becomes error hint`() {
        let error = ErrorInfo(
            message: "Invalid direction. Use up, down, left, or right.",
            code: .INVALID_ARGUMENT
        )

        #expect(error.message == "Invalid direction.")
        #expect(error.hint == "Use up, down, left, or right.")
    }

    @Test func `capture failure carries retry and mutation metadata without an action effect`() throws {
        let error = ErrorInfo(
            message: "Video capture produced no decodable frames.",
            code: .CAPTURE_NO_VALID_FRAMES,
            retrySafe: true,
            mutationDispatched: false
        )
        let envelope = ResultEnvelope<Empty?>(success: false, data: nil, error: error)
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any]
        )
        let encodedError = try #require(object["error"] as? [String: Any])

        #expect(object["effect"] == nil)
        #expect(encodedError["code"] as? String == "CAPTURE_NO_VALID_FRAMES")
        #expect(encodedError["retry_safe"] as? Bool == true)
        #expect(encodedError["mutation_dispatched"] as? Bool == false)
    }

    @Test func `incomplete Accessibility failure is effect free and retry safe`() throws {
        let error = ErrorInfo(
            message: "AX tree incomplete. Retry once to obtain a fresh observation.",
            code: .ACCESSIBILITY_INCOMPLETE,
            retrySafe: true,
            mutationDispatched: false
        )
        let envelope = ResultEnvelope<Empty?>(success: false, data: nil, error: error)
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any]
        )
        let encodedError = try #require(object["error"] as? [String: Any])

        #expect(object["success"] as? Bool == false)
        #expect(object["data"] is NSNull)
        #expect(object["effect"] == nil)
        #expect(encodedError["code"] as? String == "ACCESSIBILITY_INCOMPLETE")
        #expect(encodedError["retry_safe"] as? Bool == true)
        #expect(encodedError["mutation_dispatched"] as? Bool == false)
    }

    @Test func `safety refusal carries refused effect and explicit hint`() {
        let error = PreDispatchActionError(
            message: "Background coordinate clicks require a fresh snapshot.",
            code: .VALIDATION_ERROR,
            hint: "Use --foreground for explicit global input.",
            reason: .invalidRequest
        )

        #expect(error.envelopeEffect == .refused)
        #expect(error.envelopeHint == "Use --foreground for explicit global input.")
        #expect(error.envelopeRetrySafe == true)
        #expect(error.envelopeMutationDispatched == false)
        #expect(error.envelopeActionFailure?.outcome.refusalReason == .invalidRequest)
    }

    @Test func `action metadata is projected only for action owners`() {
        let error = PreDispatchActionError(
            message: "Runtime is incompatible.",
            code: .CAPTURE_FAILED,
            hint: "Update the selected host.",
            reason: .runtimeIncompatible
        )

        let action = actionErrorEnvelopeMetadata(for: error, isActionCommand: true)
        #expect(action.failure?.outcome.refusalReason == .runtimeIncompatible)
        #expect(action.effect == .refused)
        #expect(action.retrySafe == true)
        #expect(action.mutationDispatched == false)

        let readOnly = actionErrorEnvelopeMetadata(for: error, isActionCommand: false)
        #expect(readOnly.failure == nil)
        #expect(readOnly.effect == nil)
        #expect(readOnly.retrySafe == nil)
        #expect(readOnly.mutationDispatched == nil)
    }

    @Test func `encoding fallback remains valid JSON`() throws {
        let fallback = makeJSONEncodingFailureEnvelope(effect: .confirmed)
        let data = try JSONEncoder().encode(fallback)
        let decoded = try JSONDecoder().decode(JSONResponse.self, from: data)
        #expect(decoded.success == false)
        #expect(decoded.effect == .unverifiable)
        #expect(decoded.data == nil)

        let emergencyObject = try #require(
            JSONSerialization.jsonObject(with: Data(jsonEncodingFailureEnvelope.utf8)) as? [String: Any]
        )
        #expect(emergencyObject["success"] as? Bool == false)
        #expect(emergencyObject["data"] is NSNull)
    }

    @Test func `pre-dispatch validation is refused`() {
        #expect(defaultActionErrorEffect(.VALIDATION_ERROR) == .refused)
        #expect(defaultActionErrorEffect(.INTERACTION_FAILED) == .unverifiable)
        #expect(defaultActionRefusalReason(.AMBIGUOUS_APP_IDENTIFIER) == .invalidRequest)
    }

    @Test func `action validation derives one canonical zero-dispatch refusal`() {
        let envelope = ResultEnvelopeContext.$isActionCommand.withValue(true) {
            ResultEnvelopeContext.$isPreDispatchFailure.withValue(true) {
                makeErrorEnvelope(message: "Invalid coordinates", code: .VALIDATION_ERROR)
            }
        }

        #expect(envelope.effect == .refused)
        #expect(envelope.outcome?.state == .refused)
        #expect(envelope.outcome?.refusalReason == .invalidRequest)
        #expect(envelope.outcome?.retrySafe == true)
        #expect(envelope.outcome?.mutationDispatched == false)
        #expect(envelope.outcome?.requiresFreshObservation == false)
        #expect(envelope.error?.retry_safe == true)
        #expect(envelope.error?.mutation_dispatched == false)
    }

    @Test func `definitive legacy no-dispatch receipt derives one canonical refusal`() {
        let envelope = ResultEnvelopeContext.$isActionCommand.withValue(true) {
            makeErrorEnvelope(
                message: "The exact target has no provable focused element.",
                code: .INVALID_INPUT,
                effect: .refused,
                retrySafe: true,
                mutationDispatched: false
            )
        }

        #expect(envelope.effect == .refused)
        #expect(envelope.outcome?.state == .refused)
        #expect(envelope.outcome?.refusalReason == .invalidRequest)
        #expect(envelope.outcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(envelope.outcome?.retrySafety == .safe)
        #expect(envelope.outcome?.requiresFreshObservation == false)
        #expect(envelope.error?.retry_safe == true)
        #expect(envelope.error?.mutation_dispatched == false)
    }

    @Test func `incomplete legacy receipts never invent canonical action evidence`() {
        let receipts: [(retrySafe: Bool?, mutationDispatched: Bool?)] = [
            (nil, nil),
            (true, nil),
            (nil, false),
            (false, false),
            (true, true),
        ]
        for receipt in receipts {
            let envelope = ResultEnvelopeContext.$isActionCommand.withValue(true) {
                makeErrorEnvelope(
                    message: "Fixture failure.",
                    code: .INVALID_INPUT,
                    effect: .refused,
                    retrySafe: receipt.retrySafe,
                    mutationDispatched: receipt.mutationDispatched
                )
            }
            #expect(envelope.outcome == nil)
        }
    }

    @Test func `stale action target derives a canonical target refusal`() {
        let envelope = ResultEnvelopeContext.$isActionCommand.withValue(true) {
            ResultEnvelopeContext.$isPreDispatchFailure.withValue(true) {
                makeErrorEnvelope(message: "Snapshot is stale", code: .SNAPSHOT_STALE)
            }
        }

        #expect(envelope.outcome?.refusalReason == .targetUnavailable)
        #expect(envelope.outcome?.escalation == .refreshTarget)
        #expect(envelope.outcome?.requiresFreshObservation == false)
    }

    @Test func `read-only validation does not acquire an action outcome`() {
        let envelope = ResultEnvelopeContext.$isActionCommand.withValue(false) {
            ResultEnvelopeContext.$isPreDispatchFailure.withValue(true) {
                makeErrorEnvelope(message: "Invalid read request", code: .VALIDATION_ERROR)
            }
        }

        #expect(envelope.effect == nil)
        #expect(envelope.outcome == nil)
        #expect(envelope.error?.retry_safe == nil)
        #expect(envelope.error?.mutation_dispatched == nil)
    }

    @Test func `runtime error code cannot overwrite a dispatched receipt`() {
        let envelope = ResultEnvelopeContext.$isActionCommand.withValue(true) {
            makeErrorEnvelope(
                message: "Validation failed after dispatch",
                code: .VALIDATION_ERROR,
                retrySafe: false,
                mutationDispatched: true
            )
        }

        #expect(envelope.effect == .refused)
        #expect(envelope.outcome == nil)
        #expect(envelope.error?.retry_safe == false)
        #expect(envelope.error?.mutation_dispatched == true)
    }

    @Test @MainActor func `clipboard reads omit action effect`() {
        let get = ClipboardCommand.GetSubcommand()
        let set = ClipboardCommand.SetSubcommand()
        #expect((get as? any ActionOutputFormattable)?.defaultEffect == nil)
        #expect(set.defaultEffect == .unverifiable)
    }

    @Test @MainActor func `typed no-frame error maps to capture code and actual mutation receipt`() {
        let error = CaptureNoValidFramesError(
            source: .live,
            framesDropped: 2,
            decodeFailures: 0,
            firstDecodeError: nil,
            lastDecodeError: nil,
            lastCaptureError: "transient"
        )
        let handler = StubErrorHandlingCommand()
        #expect(handler.mapErrorToCode(error) == .CAPTURE_NO_VALID_FRAMES)

        var live = CaptureLiveCommand()
        #expect(!live.captureMutationDispatched)
        live.captureFocus = .foreground
        #expect(!live.captureMutationDispatched)
        live.captureMutationDispatched = true
        #expect(live.captureMutationDispatched)

        var action = CaptureActionCommand()
        action.captureFocus = .background
        #expect(!action.captureMutationDispatched)
        action.captureMutationDispatched = true
        #expect(action.captureMutationDispatched)
    }

    @Test @MainActor func `all capture failures preserve actual dispatch receipts`() {
        let error = PeekabooError.fileIOError("artifact write failed")
        var live = CaptureLiveCommand()
        #expect(live.captureFailureReceipt(for: error) == CaptureFailureReceipt(
            retrySafe: true,
            mutationDispatched: false
        ))
        live.captureMutationDispatched = true
        #expect(live.captureFailureReceipt(for: error) == CaptureFailureReceipt(
            retrySafe: false,
            mutationDispatched: true
        ))

        let video = CaptureVideoCommand()
        #expect(video.captureFailureReceipt(for: error) == CaptureFailureReceipt(
            retrySafe: true,
            mutationDispatched: false
        ))
        #expect(StubErrorHandlingCommand().captureFailureReceipt(for: error) == nil)

        let combined = CaptureArtifactCleanupError(
            primaryError: error,
            cleanupError: PeekabooError.fileIOError("cleanup failed"),
            artifactPath: "/tmp/capture.mp4"
        )
        #expect(StubErrorHandlingCommand().mapErrorToCode(combined) == .FILE_IO_ERROR)
    }

    @Test @MainActor func `capture focus receipt survives a throwing focus operation`() async {
        enum FocusFailure: Error { case verificationFailed }

        var command = StubCaptureFocusReceiptCommand()
        await #expect(throws: FocusFailure.self) {
            try await command.withCaptureFocusDispatchReceipt {
                throw FocusFailure.verificationFailed
            }
        }
        #expect(command.captureMutationDispatched)
    }
}

@MainActor
private struct StubErrorHandlingCommand: ErrorHandlingCommand {
    let jsonOutput = true
}

@MainActor
private struct StubCaptureFocusReceiptCommand: CaptureFocusReceiptCommand {
    var captureMutationDispatched = false

    func withCaptureFocusMutation(_ operation: () async throws -> Void) async rethrows {
        try await operation()
    }
}
