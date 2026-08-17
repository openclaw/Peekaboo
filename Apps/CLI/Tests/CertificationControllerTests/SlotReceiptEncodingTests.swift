import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooCertificationController

@Suite("Certification controller slot receipt encoding")
struct SlotReceiptEncodingTests {
    @Test
    func `type click and observation receipts preserve every nullable contract key`() throws {
        let type = try Self.receipt(
            kind: "type-mutation",
            operation: "exactWindowTargetedTypeActions",
            checkpoint: nil,
            outcome: Self.backgroundOutcome,
            result: .init(
                status: "passed",
                totalCharacters: 13,
                keyPresses: 13,
                observationFile: nil,
                observationSHA256: nil,
                observedBounds: nil
            )
        )
        let click = try Self.receipt(
            kind: "triple-click",
            operation: "exactWindowTargetedClick",
            checkpoint: nil,
            outcome: Self.backgroundOutcome,
            result: .init(
                status: "passed",
                totalCharacters: nil,
                keyPresses: nil,
                observationFile: nil,
                observationSHA256: nil,
                observedBounds: nil
            )
        )
        let observation = try Self.receipt(
            kind: "observation",
            operation: "desktopObservation",
            checkpoint: "post-mutation",
            outcome: nil,
            result: .init(
                status: "passed",
                totalCharacters: nil,
                keyPresses: nil,
                observationFile: "observations/controller-a-checkpoint-001.png",
                observationSHA256: String(repeating: "d", count: 64),
                observedBounds: .init(x: 10, y: 20, width: 640, height: 480)
            )
        )

        let typeObject = try Self.object(type)
        let typeResult = try Self.result(from: typeObject)
        Self.expectClosedReceipt(typeObject)
        Self.expectClosedResult(typeResult)
        #expect(typeObject["checkpoint"] is NSNull)
        #expect(!(typeObject["outcome"] is NSNull))
        #expect(typeResult["total_characters"] as? Int == 13)
        #expect(typeResult["key_presses"] as? Int == 13)
        #expect(typeResult["observation_file"] is NSNull)
        #expect(typeResult["observation_sha256"] is NSNull)
        #expect(typeResult["observed_bounds"] is NSNull)

        let clickObject = try Self.object(click)
        let clickResult = try Self.result(from: clickObject)
        Self.expectClosedReceipt(clickObject)
        Self.expectClosedResult(clickResult)
        #expect(clickObject["checkpoint"] is NSNull)
        #expect(!(clickObject["outcome"] is NSNull))
        #expect(clickResult["total_characters"] is NSNull)
        #expect(clickResult["key_presses"] is NSNull)
        #expect(clickResult["observation_file"] is NSNull)
        #expect(clickResult["observation_sha256"] is NSNull)
        #expect(clickResult["observed_bounds"] is NSNull)

        let observationObject = try Self.object(observation)
        let observationResult = try Self.result(from: observationObject)
        Self.expectClosedReceipt(observationObject)
        Self.expectClosedResult(observationResult)
        #expect(observationObject["checkpoint"] as? String == "post-mutation")
        #expect(observationObject["outcome"] is NSNull)
        #expect(observationResult["total_characters"] is NSNull)
        #expect(observationResult["key_presses"] is NSNull)
        #expect(observationResult["observation_file"] as? String ==
            "observations/controller-a-checkpoint-001.png")
        #expect(observationResult["observation_sha256"] as? String == String(repeating: "d", count: 64))
        #expect(observationResult["observed_bounds"] is [String: Any])
    }

    private static let backgroundOutcome = DesktopActionOutcome.confirmedChange(
        route: .bridge,
        delivery: .init(mechanism: .windowTargetedEvents, mode: .background)
    ).projection

    private static func receipt(
        kind: String,
        operation: String,
        checkpoint: String?,
        outcome: DesktopActionOutcome.Projection?,
        result: CertificationSlotResult
    ) throws -> CertificationSlotReceipt {
        let plan = try CertificationControllerPlan.decode(ControllerPlanTests.validPlanData)
        return CertificationSlotReceipt(
            slotID: "controller-a-fixture",
            kind: kind,
            operation: operation,
            checkpoint: checkpoint,
            marker: "peekaboo-certification-fixture",
            requestID: "019c0000-0000-4000-8000-000000000030",
            sessionID: "019c0000-0000-4000-8000-000000000031",
            sessionSequence: "0",
            listenerInstanceID: "019c0000-0000-4000-8000-000000000032",
            target: CertificationWindowReceipt(target: plan.target),
            interval: .init(startedAtMilliseconds: 100, completedAtMilliseconds: 101),
            controllerInterval: .init(startedAtMilliseconds: 99, completedAtMilliseconds: 102),
            outcome: outcome,
            result: result,
            bundle: .init(
                file: "bundles/019c0000-0000-4000-8000-000000000030.json",
                sha256: String(repeating: "a", count: 64),
                requestSHA256: String(repeating: "b", count: 64),
                responseSHA256: String(repeating: "c", count: 64)
            )
        )
    }

    private static func object(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private static func result(from receipt: [String: Any]) throws -> [String: Any] {
        try #require(receipt["result"] as? [String: Any])
    }

    private static func expectClosedReceipt(_ object: [String: Any]) {
        #expect(Set(object.keys) == [
            "slot_id", "kind", "operation", "checkpoint", "marker", "request_id", "session_id",
            "session_sequence", "listener_instance_id", "target", "interval", "controller_interval",
            "outcome", "result", "bundle",
        ])
    }

    private static func expectClosedResult(_ object: [String: Any]) {
        #expect(Set(object.keys) == [
            "status", "total_characters", "key_presses", "observation_file", "observation_sha256",
            "observed_bounds",
        ])
    }
}
