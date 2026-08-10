import Foundation
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
}
