import Foundation
import Testing
@testable import PeekabooCertificationController

@Suite("Certification controller closed plan")
struct ControllerPlanTests {
    @Test
    func `valid plan derives the exact ordered four-slot catalog`() throws {
        let plan = try CertificationControllerPlan.decode(Self.validPlanData)

        #expect(plan.slots.map(\.id) == [
            "controller-a-mutation-001",
            "controller-a-protocol-130-001",
            "controller-a-checkpoint-001",
            "controller-a-final-bounds",
        ])
        #expect(plan.slots.map(\.operation.rawValue) == [
            "exactWindowTargetedTypeActions",
            "exactWindowTargetedClick",
            "desktopObservation",
            "desktopObservation",
        ])
        #expect(plan.slots.map { plan.marker(for: $0) } == plan.slots.map {
            "peekaboo-certification-run:\(String(repeating: "9", count: 64)):slot:\($0.id)"
        })
        #expect(plan.receiptURL.lastPathComponent == "controller-a-receipt.json")
        #expect(plan.mutationStartedURL.lastPathComponent == "mutation-started.json")
        #expect(plan.mutationCompletedURL.lastPathComponent == "mutation-completed.json")
        #expect(plan.readyURL.lastPathComponent == "ready.json")
        #expect(plan.startURL.lastPathComponent == "start.json")
        #expect(plan.finalBoundsReadyURL.lastPathComponent == "final-bounds-ready.json")
        #expect(plan.finalBoundsStartURL.lastPathComponent == "final-bounds-start.json")
        #expect(plan.releaseURL.lastPathComponent == "release.json")
        #expect(plan.typingDelayMilliseconds == 20)
    }

    @Test
    func `plan rejects unknown keys and noncanonical run binding`() throws {
        var object = try #require(JSONSerialization.jsonObject(with: Self.validPlanData) as? [String: Any])
        object["unexpected"] = true
        let unknownKeyData = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: CertificationControllerError.self) {
            try CertificationControllerPlan.decode(unknownKeyData)
        }

        object.removeValue(forKey: "unexpected")
        object["execution_nonce"] = String(repeating: "A", count: 64)
        let uppercaseNonceData = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: CertificationControllerError.self) {
            try CertificationControllerPlan.decode(uppercaseNonceData)
        }

        object["execution_nonce"] = String(repeating: "9", count: 64)
        object["typing_delay_milliseconds"] = 0
        let zeroDelayData = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: CertificationControllerError.self) {
            try CertificationControllerPlan.decode(zeroDelayData)
        }

        object["typing_delay_milliseconds"] = 20
        var expectedBuild = try #require(object["expected_controller_build"] as? [String: Any])
        expectedBuild["unexpected"] = true
        object["expected_controller_build"] = expectedBuild
        let openBuildSchemaData = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: CertificationControllerError.self) {
            try CertificationControllerPlan.decode(openBuildSchemaData)
        }

        expectedBuild.removeValue(forKey: "unexpected")
        object["expected_controller_build"] = expectedBuild
        object["start_path"] = object["ready_path"]
        #expect(throws: CertificationControllerError.self) {
            try CertificationControllerPlan.decode(JSONSerialization.data(withJSONObject: object))
        }

        object["start_path"] = "/private/tmp/peekaboo-controller-artifacts/start.json"
        object["final_bounds_start_path"] = object["final_bounds_ready_path"]
        #expect(throws: CertificationControllerError.self) {
            try CertificationControllerPlan.decode(JSONSerialization.data(withJSONObject: object))
        }

        object["final_bounds_start_path"] = "/private/tmp/peekaboo-controller-artifacts/final-bounds-start.json"
        var host = try #require(object["expected_host"] as? [String: Any])
        host["source_commit"] = String(repeating: "e", count: 40)
        object["expected_host"] = host
        #expect(throws: CertificationControllerError.self) {
            try CertificationControllerPlan.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    static let validPlanData = Data("""
    {
      "version": 1,
      "execution_nonce": "\(String(repeating: "9", count: 64))",
      "monitor_instance_id": "019c0000-0000-4000-8000-000000000001",
      "controller_id": "controller-a",
      "target_id": "target-a",
      "client_instance_id": "019c0000-0000-4000-8000-000000000002",
      "socket_path": "/private/tmp/peekaboo-certification.sock",
      "trusted_bridge_host_team_ids": ["FWJYW4S8P8"],
      "expected_controller_build": {
        "source_commit": "\(String(repeating: "c", count: 40))",
        "executable_path": "/private/tmp/peekaboo-certification-controller",
        "executable_sha256": "\(String(repeating: "d", count: 64))",
        "team_id": "FWJYW4S8P8"
      },
      "expected_host": {
        "host_kind": "gui",
        "process_identifier": 9001,
        "process_start_identity_decimal": "900100",
        "code_signature_hash": "\(String(repeating: "a", count: 40))",
        "source_commit": "\(String(repeating: "c", count: 40))"
      },
      "target": {
        "process_identifier": 5101,
        "process_start_identity_decimal": "510100",
        "window_id": 6101,
        "bounds": {"x": 10, "y": 20, "width": 640, "height": 480},
        "is_minimized": false,
        "click_point": {"x": 30, "y": 40}
      },
      "type_text": "certification",
      "typing_delay_milliseconds": 20,
      "artifacts_directory": "/private/tmp/peekaboo-controller-artifacts",
      "ready_path": "/private/tmp/peekaboo-controller-artifacts/ready.json",
      "start_path": "/private/tmp/peekaboo-controller-artifacts/start.json",
      "final_bounds_ready_path": "/private/tmp/peekaboo-controller-artifacts/final-bounds-ready.json",
      "final_bounds_start_path": "/private/tmp/peekaboo-controller-artifacts/final-bounds-start.json",
      "release_path": "/private/tmp/peekaboo-controller-artifacts/release.json"
    }
    """.utf8)
}
