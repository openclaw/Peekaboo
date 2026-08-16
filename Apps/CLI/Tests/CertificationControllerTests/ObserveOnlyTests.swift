import CoreGraphics
import Foundation
import PeekabooAutomationKit
import Testing
@testable import PeekabooCertificationController

@Suite("Certification observe-only foreground witness")
struct ObserveOnlyTests {
    @Test
    func `closed plan derives exact foreground token and owner paths`() throws {
        let plan = try CertificationObserveOnlyPlan.decode(Self.validPlanData)

        #expect(plan.mode == .observeOnly)
        #expect(plan.requestMarker == "peekaboo-foreground-postcondition:\(Self.nonce)")
        #expect(plan.expectedValueSHA256 == CertificationPrivateArtifacts.sha256(Data(plan.requestMarker.utf8)))
        #expect(plan.observationURL.lastPathComponent == "foreground-observation.json")
        #expect(plan.restorationURL.lastPathComponent == "foreground-restoration.json")
        #expect(plan.witnessURL.lastPathComponent == "foreground-witness.json")
    }

    @Test
    func `plan rejects open schema wrong token digest and path escape`() throws {
        var object = try #require(JSONSerialization.jsonObject(with: Self.validPlanData) as? [String: Any])
        object["unexpected"] = true
        #expect(throws: CertificationControllerError.self) {
            try CertificationObserveOnlyPlan.decode(JSONSerialization.data(withJSONObject: object))
        }
        object.removeValue(forKey: "unexpected")
        object["expected_value_sha256"] = String(repeating: "0", count: 64)
        #expect(throws: CertificationControllerError.self) {
            try CertificationObserveOnlyPlan.decode(JSONSerialization.data(withJSONObject: object))
        }
        object["expected_value_sha256"] = Self.expectedSHA256
        object["observation_path"] = "/private/tmp/outside-observation.json"
        #expect(throws: CertificationControllerError.self) {
            try CertificationObserveOnlyPlan.decode(JSONSerialization.data(withJSONObject: object))
        }
        object["observation_path"] = "/private/tmp/peekaboo-observer-artifacts/foreground-observation.json"
        object["semantic_element"] = ["role": "AXTextField", "identifier": NSNull(), "title": NSNull()]
        #expect(throws: CertificationControllerError.self) {
            try CertificationObserveOnlyPlan.decode(JSONSerialization.data(withJSONObject: object))
        }
        object["semantic_element"] = ["role": "AXTextField", "identifier": NSNull(), "title": "Fixture"]
        #expect(try CertificationObserveOnlyPlan.decode(
            JSONSerialization.data(withJSONObject: object)
        ).semanticElement.title == "Fixture")

        var host = try #require(object["expected_host"] as? [String: Any])
        host["source_commit"] = String(repeating: "e", count: 40)
        object["expected_host"] = host
        #expect(throws: CertificationControllerError.self) {
            try CertificationObserveOnlyPlan.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test
    func `fresh semantic readback is exact process window and element bound`() throws {
        let plan = try CertificationObserveOnlyPlan.decode(Self.validPlanData)
        let focus = Self.focus(value: plan.requestMarker)
        #expect(try CertificationSemanticReadback.value(from: focus, plan: plan) == plan.requestMarker)

        let rejected: [UIFocusInfo?] = [
            nil,
            Self.focus(value: plan.requestMarker, processID: 5302),
            Self.focus(value: plan.requestMarker, windowID: 6302),
            Self.focus(value: plan.requestMarker, role: "AXButton"),
            Self.focus(value: plan.requestMarker, identifier: "other-field"),
            Self.focus(value: plan.requestMarker, frame: CGRect(x: 5000, y: 5000, width: 10, height: 10)),
            Self.focus(value: nil),
        ]
        for candidate in rejected {
            #expect(throws: CertificationControllerError.self) {
                try CertificationSemanticReadback.value(from: candidate, plan: plan)
            }
        }
    }

    @Test
    func `request readback and witness documents match finalizer schemas`() throws {
        let plan = try CertificationObserveOnlyPlan.decode(Self.validPlanData)
        let process = CertificationProcessReceipt(
            pid: 8001,
            startIdentity: "800100",
            codeSignatureHash: String(repeating: "a", count: 40)
        )
        let target = plan.target
        let focusIdentity = try #require(FocusedElementIdentity(Self.focus(value: plan.requestMarker)))
        let focusedElement = CertificationFocusedElementReceipt(focusIdentity)
        let marker = CertificationObserverRequestMarker(
            version: 1,
            executionNonce: plan.executionNonce,
            requestMarker: plan.requestMarker,
            phase: .observe
        )
        let readback = CertificationForegroundReadbackDocument(
            version: 1,
            executionNonce: plan.executionNonce,
            requestMarker: plan.requestMarker,
            target: target,
            observer: process,
            observedValueSHA256: plan.expectedValueSHA256,
            observedAtMilliseconds: 200
        )
        let ready = CertificationObserverReadyReceipt(
            version: 1,
            mode: .observeOnly,
            executionNonce: plan.executionNonce,
            observerID: plan.observerID,
            observer: process,
            observerBuild: plan.expectedControllerBuild.requirementFixture,
            target: target,
            focusedElement: focusedElement,
            requestMarker: plan.requestMarker,
            baselineValueSHA256: plan.baselineValueSHA256,
            expectedValueSHA256: plan.expectedValueSHA256,
            observationPath: plan.observationPath,
            restorationPath: plan.restorationPath,
            readyAtMilliseconds: 50
        )
        let witness = CertificationForegroundPostconditionWitness(
            version: 1,
            executionNonce: plan.executionNonce,
            target: target,
            observer: process,
            focusedElement: focusedElement,
            interval: .init(startedAtMilliseconds: 100, completedAtMilliseconds: 200),
            requestMarker: plan.requestMarker,
            beforeValueSHA256: plan.baselineValueSHA256,
            expectedValueSHA256: plan.expectedValueSHA256,
            observedValueSHA256: plan.expectedValueSHA256,
            restoredValueSHA256: plan.baselineValueSHA256,
            observationPath: plan.observationPath,
            observationFileSHA256: String(repeating: "3", count: 64),
            restorationPath: plan.restorationPath,
            restorationFileSHA256: String(repeating: "4", count: 64),
            passed: true,
            restored: true
        )

        #expect(try Self.keys(marker) == ["version", "execution_nonce", "request_marker", "phase"])
        #expect(try Self.keys(readback) == [
            "version", "execution_nonce", "request_marker", "target", "observer",
            "observed_value_sha256", "observed_at_milliseconds",
        ])
        #expect(try Self.keys(ready) == [
            "version", "mode", "execution_nonce", "observer_id", "observer", "observer_build", "target",
            "focused_element", "request_marker", "baseline_value_sha256", "expected_value_sha256",
            "observation_path", "restoration_path", "ready_at_milliseconds",
        ])
        #expect(try Self.keys(witness) == [
            "version", "execution_nonce", "target", "observer", "focused_element", "interval", "request_marker",
            "before_value_sha256", "expected_value_sha256", "observed_value_sha256",
            "restored_value_sha256", "observation_path", "observation_file_sha256",
            "restoration_path", "restoration_file_sha256", "passed", "restored",
        ])

        let identifierOnly = try Self.object(focusedElement)
        #expect(Set(identifierOnly.keys) == ["role", "title", "identifier", "frame"])
        #expect(identifierOnly["title"] is NSNull)
        let titleOnlyIdentity = FocusedElementIdentity(
            processIdentifier: 5301,
            windowID: 6301,
            role: "AXTextField",
            title: "Fixture",
            identifier: nil,
            frame: CGRect(x: 1420, y: 50, width: 300, height: 40)
        )
        let titleOnly = try Self.object(CertificationFocusedElementReceipt(titleOnlyIdentity))
        #expect(Set(titleOnly.keys) == ["role", "title", "identifier", "frame"])
        #expect(titleOnly["identifier"] is NSNull)

        let liveBoth = FocusedElementIdentity(
            processIdentifier: 5301,
            windowID: 6301,
            role: "AXTextField",
            title: "Live title",
            identifier: "live-identifier",
            frame: CGRect(x: 1420, y: 50, width: 300, height: 40)
        )
        let identifierPlan = CertificationSemanticElement(
            role: "AXTextField",
            identifier: "live-identifier",
            title: nil
        )
        let canonicalIdentifier = try Self.object(CertificationFocusedElementReceipt(
            identity: liveBoth,
            semanticElement: identifierPlan
        ))
        #expect(canonicalIdentifier["title"] is NSNull)
        let titlePlan = CertificationSemanticElement(
            role: "AXTextField",
            identifier: nil,
            title: "Live title"
        )
        let canonicalTitle = try Self.object(CertificationFocusedElementReceipt(
            identity: liveBoth,
            semanticElement: titlePlan
        ))
        #expect(canonicalTitle["identifier"] is NSNull)
        let bothPlan = CertificationSemanticElement(
            role: "AXTextField",
            identifier: "live-identifier",
            title: "Live title"
        )
        let canonicalBoth = try Self.object(CertificationFocusedElementReceipt(
            identity: liveBoth,
            semanticElement: bothPlan
        ))
        #expect(canonicalBoth["identifier"] as? String == "live-identifier")
        #expect(canonicalBoth["title"] as? String == "Live title")
    }

    private static let nonce = String(repeating: "9", count: 64)
    private static let marker = "peekaboo-foreground-postcondition:\(Self.nonce)"
    private static let expectedSHA256 = CertificationPrivateArtifacts.sha256(Data(Self.marker.utf8))

    static let validPlanData = Data("""
    {
      "version": 1,
      "mode": "observe-only",
      "execution_nonce": "\(Self.nonce)",
      "monitor_instance_id": "019c0000-0000-4000-8000-000000000021",
      "observer_id": "foreground-observer",
      "client_instance_id": "019c0000-0000-4000-8000-000000000020",
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
        "scope": "window",
        "pid": 5301,
        "start_identity": "530100",
        "window_id": 6301,
        "bounds": {"x": 1400, "y": 20, "width": 500, "height": 700},
        "is_minimized": false
      },
      "semantic_element": {"role": "AXTextField", "identifier": "foreground-field", "title": null},
      "request_marker": "\(Self.marker)",
      "expected_value_sha256": "\(Self.expectedSHA256)",
      "baseline_value_sha256": "\(String(repeating: "1", count: 64))",
      "artifacts_directory": "/private/tmp/peekaboo-observer-artifacts",
      "ready_path": "/private/tmp/peekaboo-observer-artifacts/observer-ready.json",
      "observation_request_path": "/private/tmp/peekaboo-observer-artifacts/observe-request.json",
      "restoration_request_path": "/private/tmp/peekaboo-observer-artifacts/restore-request.json",
      "release_path": "/private/tmp/peekaboo-observer-artifacts/release.json",
      "observation_path": "/private/tmp/peekaboo-observer-artifacts/foreground-observation.json",
      "restoration_path": "/private/tmp/peekaboo-observer-artifacts/foreground-restoration.json",
      "witness_path": "/private/tmp/peekaboo-observer-artifacts/foreground-witness.json",
      "attestation_socket_path": "/private/tmp/peekaboo-observer-artifacts/observer-attestation.sock",
      "wait_timeout_seconds": 600,
      "poll_interval_milliseconds": 50
    }
    """.utf8)

    private static func focus(
        value: String?,
        processID: Int = 5301,
        windowID: Int = 6301,
        role: String = "AXTextField",
        identifier: String? = "foreground-field",
        frame: CGRect = CGRect(x: 1420, y: 50, width: 300, height: 40)
    ) -> UIFocusInfo {
        UIFocusInfo(
            role: role,
            title: nil,
            value: value,
            frame: frame,
            applicationName: "Foreground Fixture",
            bundleIdentifier: "boo.peekaboo.foreground-fixture",
            processId: processID,
            windowID: windowID,
            identifier: identifier
        )
    }

    private static func keys(_ value: some Encodable) throws -> Set<String> {
        try Set(self.object(value).keys)
    }

    private static func object(_ value: some Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
}

extension CertificationExpectedControllerBuild {
    fileprivate var requirementFixture: CertificationControllerBuildReceipt {
        CertificationControllerBuildReceipt(
            sourceCommit: self.sourceCommit,
            executablePath: self.executablePath,
            executableSHA256: self.executableSHA256,
            teamID: self.teamID
        )
    }
}
