import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

struct ResultEnvelopeTests {
    private struct Payload: Codable { let value: Int }

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

    @Test func `safety refusal carries refused effect and explicit hint`() {
        let error = ActionRefusalError(
            message: "Background coordinate clicks require a fresh snapshot.",
            hint: "Use --foreground for explicit global input."
        )

        #expect(error.envelopeEffect == .refused)
        #expect(error.envelopeHint == "Use --foreground for explicit global input.")
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
