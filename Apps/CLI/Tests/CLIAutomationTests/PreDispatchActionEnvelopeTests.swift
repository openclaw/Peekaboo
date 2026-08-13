import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized)
struct PreDispatchActionEnvelopeTests {
    private struct FailureEnvelope: Decodable {
        let success: Bool
        let effect: ActionEffect?
        let outcome: DesktopActionOutcome.Projection?
        let data: Empty?
        let error: ErrorInfo?
    }

    struct ValidationCase {
        let name: String
        let arguments: [String]
        let errorCode: ErrorCode
    }

    @Test
    func `action validation before dispatch returns refused JSON`() async throws {
        let cases = [
            ValidationCase(
                name: "set-value binding validation",
                arguments: [
                    "set-value", "value", "--on", "field", "--app", "Example", "--pid", "123", "--json",
                ],
                errorCode: .VALIDATION_ERROR
            ),
            ValidationCase(
                name: "action binding validation",
                arguments: [
                    "action", "AXPress", "--on", "button", "--app", "Example", "--pid", "123", "--json",
                ],
                errorCode: .VALIDATION_ERROR
            ),
            ValidationCase(
                name: "action window selector binding validation",
                arguments: [
                    "action", "AXPress", "--on", "button", "--app", "Example",
                    "--window-title", "Main", "--window-index", "0", "--json",
                ],
                errorCode: .VALIDATION_ERROR
            ),
            ValidationCase(
                name: "click parser validation",
                arguments: ["click", "--not-a-click-option", "--json"],
                errorCode: .INVALID_ARGUMENT
            ),
            ValidationCase(
                name: "press binding validation",
                arguments: ["press", "return", "--app", "Example", "--pid", "123", "--json"],
                errorCode: .VALIDATION_ERROR
            ),
            ValidationCase(
                name: "drag binding validation",
                arguments: [
                    "drag", "--from", "1,1", "--to", "2,2", "--app", "Example", "--pid", "123", "--json",
                ],
                errorCode: .VALIDATION_ERROR
            ),
        ]

        for testCase in cases {
            let result = try await InProcessCommandRunner.runShared(
                testCase.arguments,
                allowedExitCodes: [1]
            )
            let data = Data(result.stdout.utf8)
            let envelope = try JSONDecoder().decode(FailureEnvelope.self, from: data)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

            #expect(envelope.success == false, "Expected failure for \(testCase.name)")
            #expect(envelope.effect == .refused, "Action was not refused for \(testCase.name)")
            #expect(envelope.data == nil)
            #expect(envelope.error?.code == testCase.errorCode.rawValue)
            Self.expectCanonicalRefusal(envelope, reason: .invalidRequest, name: testCase.name)
            #expect(object["effect"] as? String == ActionEffect.refused.rawValue)
            #expect(object["data"] is NSNull)
            #expect(result.stderr.isEmpty)
        }
    }

    @Test
    func `source-blind refusal fixtures carry canonical zero-dispatch outcomes`() async throws {
        let cases: [(name: String, arguments: [String], code: ErrorCode, reason: DesktopActionOutcome.RefusalReason)] =
            [
                (
                    "background coordinate click without receipt",
                    ["click", "--at", "10,10", "--json"],
                    .VALIDATION_ERROR,
                    .invalidRequest
                ),
                (
                    "snapshotless action",
                    ["action", "AXPress", "--on", "B1", "--json"],
                    .SNAPSHOT_NOT_FOUND,
                    .targetUnavailable
                ),
                (
                    "snapshotless set-value",
                    ["set-value", "hello", "--on", "T1", "--json"],
                    .SNAPSHOT_NOT_FOUND,
                    .targetUnavailable
                ),
                (
                    "targetless background scroll",
                    ["scroll", "--direction", "down", "--json"],
                    .VALIDATION_ERROR,
                    .invalidRequest
                ),
                (
                    "targetless background type",
                    ["type", "hello", "--json"],
                    .VALIDATION_ERROR,
                    .invalidRequest
                ),
                (
                    "malformed coordinate click",
                    ["click", "--at", ",", "--json"],
                    .VALIDATION_ERROR,
                    .invalidRequest
                ),
            ]

        for testCase in cases {
            let result = try await InProcessCommandRunner.runShared(
                testCase.arguments,
                allowedExitCodes: [1]
            )
            let envelope = try JSONDecoder().decode(FailureEnvelope.self, from: Data(result.stdout.utf8))

            #expect(envelope.success == false, "Expected failure for \(testCase.name)")
            #expect(envelope.error?.code == testCase.code.rawValue)
            Self.expectCanonicalRefusal(envelope, reason: testCase.reason, name: testCase.name)
            #expect(result.stderr.isEmpty)
        }
    }

    @Test
    func `read-only parser and binding validation omit effect`() async throws {
        let cases = [
            ValidationCase(
                name: "see parser validation",
                arguments: ["see", "--not-a-see-option", "--json"],
                errorCode: .INVALID_ARGUMENT
            ),
            ValidationCase(
                name: "see binding validation",
                arguments: ["see", "--app", "Example", "--pid", "123", "--json"],
                errorCode: .VALIDATION_ERROR
            ),
            ValidationCase(
                name: "clipboard get parser validation",
                arguments: ["clipboard", "get", "--not-a-clipboard-option", "--json"],
                errorCode: .INVALID_ARGUMENT
            ),
            ValidationCase(
                name: "capture live app and pid parser validation",
                arguments: [
                    "capture", "live", "--app", "Example", "--pid", "123",
                    "--not-a-capture-option", "--json",
                ],
                errorCode: .INVALID_ARGUMENT
            ),
            ValidationCase(
                name: "capture live title and index parser validation",
                arguments: [
                    "capture", "live", "--window-title", "Main", "--window-index", "0",
                    "--not-a-capture-option", "--json",
                ],
                errorCode: .INVALID_ARGUMENT
            ),
            ValidationCase(
                name: "capture live screen and app parser validation",
                arguments: [
                    "capture", "live", "--mode", "screen", "--screen-index", "0", "--app", "Example",
                    "--not-a-capture-option", "--json",
                ],
                errorCode: .INVALID_ARGUMENT
            ),
        ]

        for testCase in cases {
            let result = try await InProcessCommandRunner.runShared(
                testCase.arguments,
                allowedExitCodes: [1]
            )
            let data = Data(result.stdout.utf8)
            let envelope = try JSONDecoder().decode(FailureEnvelope.self, from: data)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

            #expect(envelope.success == false, "Expected failure for \(testCase.name)")
            #expect(envelope.effect == nil, "Read-only command gained an effect for \(testCase.name)")
            #expect(envelope.outcome == nil, "Read-only command gained an outcome for \(testCase.name)")
            #expect(envelope.data == nil)
            #expect(envelope.error?.code == testCase.errorCode.rawValue)
            #expect(envelope.error?.retry_safe == nil)
            #expect(envelope.error?.mutation_dispatched == nil)
            #expect(object["effect"] == nil, "Read-only command emitted an effect key for \(testCase.name)")
            #expect(object["data"] is NSNull)
            #expect(result.stderr.isEmpty)
        }
    }

    @Test
    func `plain-text validation remains plain text`() async throws {
        let parserResult = try await InProcessCommandRunner.runShared(
            ["click", "--not-a-click-option"],
            allowedExitCodes: [1]
        )
        #expect(parserResult.stdout.isEmpty)
        #expect(parserResult.stderr.hasPrefix("Error: Unknown option --not-a-click-option"))
        #expect(!parserResult.stderr.contains("\"effect\""))
        #expect(!parserResult.stderr.contains("{"))

        let bindingResult = try await InProcessCommandRunner.runShared(
            ["set-value", "value", "--on", "field", "--app", "Example", "--pid", "123"],
            allowedExitCodes: [1]
        )
        #expect(bindingResult.stdout.isEmpty)
        #expect(bindingResult.stderr.hasPrefix("Error: "))
        #expect(!bindingResult.stderr.contains("\"effect\""))
        #expect(!bindingResult.stderr.contains("{"))
    }

    private static func expectCanonicalRefusal(
        _ envelope: FailureEnvelope,
        reason: DesktopActionOutcome.RefusalReason,
        name: String
    ) {
        #expect(envelope.effect == .refused, "Action was not refused for \(name)")
        #expect(envelope.outcome?.state == .refused, "Missing canonical refusal for \(name)")
        #expect(envelope.outcome?.refusalReason == reason, "Wrong refusal reason for \(name)")
        #expect(
            envelope.outcome?.dispatchState == DesktopActionOutcome.DispatchState.none,
            "Dispatch was claimed for \(name)"
        )
        #expect(envelope.outcome?.retrySafe == true, "Retry was not safe for \(name)")
        #expect(envelope.outcome?.requiresFreshObservation == false, "Fresh observation was requested for \(name)")
        #expect(envelope.error?.retry_safe == true, "Legacy retry field disagreed for \(name)")
        #expect(envelope.error?.mutation_dispatched == false, "Legacy dispatch field disagreed for \(name)")
    }
}
