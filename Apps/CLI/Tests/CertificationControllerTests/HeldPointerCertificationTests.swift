import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooCertificationController

@Suite("Held-pointer certification")
struct HeldPointerCertificationTests {
    @Test
    func `closed plan accepts one exact visible target`() throws {
        let plan = try HeldPointerCertificationPlan.decode(Self.validPlanData)

        #expect(plan.clientUUID == HeldPointerCertificationPlan.derivedClientInstanceID(
            executionNonce: String(repeating: "9", count: 64)
        ))
        #expect(plan.clientUUID != HeldPointerCertificationPlan.derivedClientInstanceID(
            executionNonce: String(repeating: "8", count: 64)
        ))
        #expect(plan.clientUUID?.uuidString.lowercased().split(separator: "-")[2].first == "8")
        #expect(plan.target.processIdentifier == 5101)
        #expect(plan.target.processStartIdentityDecimal == "510100")
        #expect(plan.target.windowID == 6101)
        #expect(plan.holdMilliseconds == 500)
        #expect(plan.bundleDirectoryURL.lastPathComponent == "bundles")
        #expect(plan.receiptURL.lastPathComponent == "held-pointer-receipt.json")
    }

    @Test
    func `plan rejects open schema stale target and flexible duration`() throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: Self.validPlanData) as? [String: Any]
        )
        object["unexpected"] = true
        #expect(throws: CertificationControllerError.self) {
            try HeldPointerCertificationPlan.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        }

        object.removeValue(forKey: "unexpected")
        object["client_instance_id"] = "019c0000-0000-4000-8000-000000000002"
        #expect(throws: CertificationControllerError.self) {
            try HeldPointerCertificationPlan.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        }

        object.removeValue(forKey: "client_instance_id")
        object["hold_milliseconds"] = 499
        #expect(throws: CertificationControllerError.self) {
            try HeldPointerCertificationPlan.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        }

        object["hold_milliseconds"] = 500
        var target = try #require(object["target"] as? [String: Any])
        target["is_minimized"] = true
        object["target"] = target
        #expect(throws: CertificationControllerError.self) {
            try HeldPointerCertificationPlan.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        }

        target["is_minimized"] = false
        target["process_identifier"] = 9001
        object["target"] = target
        #expect(throws: CertificationControllerError.self) {
            try HeldPointerCertificationPlan.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test
    func `held pointer artifacts require a fresh closed root`() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-held-pointer-plan-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        var object = try #require(
            JSONSerialization.jsonObject(with: Self.validPlanData) as? [String: Any]
        )
        object["artifacts_directory"] = parent.path
        let plan = try HeldPointerCertificationPlan.decode(
            JSONSerialization.data(withJSONObject: object)
        )

        try CertificationPrivateArtifacts.prepareHeldPointer(for: plan)
        #expect(try CertificationPrivateArtifacts.inventory(plan.bundleDirectoryURL).isEmpty)
        #expect(throws: CertificationControllerError.self) {
            try CertificationPrivateArtifacts.prepareHeldPointer(for: plan)
        }
    }

    @Test
    func `lifecycle semantics require exact background two one three sequence`() throws {
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let point = CGPoint(x: 30, y: 40)
        let identity = WindowMutationIdentity(
            windowID: 6101,
            ownerProcessIdentifier: 5101,
            ownerProcessStartIdentity: 510_100,
            capturedBounds: bounds,
            isMinimized: false
        )
        let target = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds
        ))
        let begin = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .init(2)
        ).routed(to: .bridge)
        let release = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one
        ).routed(to: .bridge)

        try HeldPointerCertificationSemantics.requireBegin(
            outcome: begin,
            targetIdentity: target,
            plannedIdentity: identity,
            plannedBounds: bounds
        )
        try HeldPointerCertificationSemantics.requireRelease(
            .init(
                outcome: release,
                targetIdentity: target,
                reason: .released,
                receiptIdentity: identity,
                receiptBounds: bounds,
                receiptPoint: point,
                receiptButton: .left,
                lifecycleDispatchedUnits: 3
            ),
            expected: .init(identity: identity, bounds: bounds, point: point)
        )
        try HeldPointerCertificationSemantics.requireDisconnect(
            outcome: .confirmedNoChange(route: .bridge),
            hasPayload: false,
            targetIdentity: nil
        )

        let oneUnitBegin = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one
        ).routed(to: .bridge)
        #expect(throws: CertificationControllerError.self) {
            try HeldPointerCertificationSemantics.requireBegin(
                outcome: oneUnitBegin,
                targetIdentity: target,
                plannedIdentity: identity,
                plannedBounds: bounds
            )
        }
        #expect(throws: CertificationControllerError.self) {
            try HeldPointerCertificationSemantics.requireRelease(
                .init(
                    outcome: release,
                    targetIdentity: target,
                    reason: .ownerDisconnected,
                    receiptIdentity: identity,
                    receiptBounds: bounds,
                    receiptPoint: point,
                    receiptButton: .left,
                    lifecycleDispatchedUnits: 3
                ),
                expected: .init(identity: identity, bounds: bounds, point: point)
            )
        }
        #expect(throws: CertificationControllerError.self) {
            try HeldPointerCertificationSemantics.requireDisconnect(
                outcome: .refused(route: .bridge, reason: .invalidRequest),
                hasPayload: false,
                targetIdentity: nil
            )
        }

        try HeldPointerCertificationSemantics.requireFailureDisconnect(
            .init(
                outcome: .confirmedNoChange(route: .bridge),
                targetIdentity: nil,
                terminalReason: nil,
                lifecycleDispatchedUnits: nil,
                hasPayload: false
            ),
            expected: .init(identity: identity, bounds: bounds, point: point)
        )
        try HeldPointerCertificationSemantics.requireFailureDisconnect(
            .init(
                outcome: release,
                targetIdentity: target,
                terminalReason: .ownerDisconnected,
                lifecycleDispatchedUnits: 3,
                hasPayload: true
            ),
            expected: .init(identity: identity, bounds: bounds, point: point)
        )
        #expect(throws: CertificationControllerError.self) {
            try HeldPointerCertificationSemantics.requireFailureDisconnect(
                .init(
                    outcome: release,
                    targetIdentity: target,
                    terminalReason: .released,
                    lifecycleDispatchedUnits: 3,
                    hasPayload: true
                ),
                expected: .init(identity: identity, bounds: bounds, point: point)
            )
        }
        try HeldPointerCertificationSemantics.requireReceiptTarget(nil, expected: .absent)
        try HeldPointerCertificationSemantics.requireReceiptTarget(.window(identity), expected: .exact(identity))
        #expect(throws: CertificationControllerError.self) {
            try HeldPointerCertificationSemantics.requireReceiptTarget(.window(identity), expected: .absent)
        }
    }

    @Test
    func `cancelled lifecycle performs explicit cleanup before returning`() async {
        let probe = HeldPointerCleanupProbe()
        let identity = WindowMutationIdentity(
            windowID: 6101,
            ownerProcessIdentifier: 5101,
            ownerProcessStartIdentity: 510_100,
            capturedBounds: CGRect(x: 10, y: 20, width: 640, height: 480),
            isMinimized: false
        )
        let original = CertificationControllerError.runtimeRefusal("primary failure")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await HeldPointerCertificationSemantics.performFailureCleanup(
                    originalError: original,
                    expected: .init(
                        identity: identity,
                        bounds: CGRect(x: 10, y: 20, width: 640, height: 480),
                        point: CGPoint(x: 30, y: 40)
                    )
                ) {
                    await probe.cleanup()
                }
            } catch {
                return error.localizedDescription
            }
        }

        #expect(await task.value == original.localizedDescription)
        #expect(await probe.callCount == 1)
        #expect(await probe.observedCancellation == false)
    }

    static let validPlanData = Data("""
    {
      "version": 1,
      "execution_nonce": "\(String(repeating: "9", count: 64))",
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
      "hold_milliseconds": 500,
      "artifacts_directory": "/private/tmp/peekaboo-held-pointer-artifacts"
    }
    """.utf8)
}

private actor HeldPointerCleanupProbe {
    private(set) var callCount = 0
    private(set) var observedCancellation = false

    func cleanup() -> HeldPointerCertificationSemantics.FailureDisconnectEvidence {
        self.callCount += 1
        self.observedCancellation = Task.isCancelled
        return .init(
            outcome: .confirmedNoChange(route: .bridge),
            targetIdentity: nil,
            terminalReason: nil,
            lifecycleDispatchedUnits: nil,
            hasPayload: false
        )
    }
}
