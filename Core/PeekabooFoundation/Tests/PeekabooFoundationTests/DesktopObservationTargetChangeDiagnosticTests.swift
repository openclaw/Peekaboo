import Foundation
import Testing
@testable import PeekabooFoundation

struct DesktopObservationTargetChangeDiagnosticTests {
    @Test(arguments: DesktopObservationTargetChangeDiagnostic.Classification.allCases)
    func `encoding uses only bounded contract keys`(
        classification: DesktopObservationTargetChangeDiagnostic.Classification) throws
    {
        for phase in DesktopObservationTargetChangeDiagnostic.Phase.allCases {
            for status in DesktopObservationTargetChangeDiagnostic.PassiveRecovery.FinalStatus.allCases {
                let diagnostic = DesktopObservationTargetChangeDiagnostic(
                    classification: classification,
                    phase: phase,
                    changedComponents: DesktopObservationTargetChangeDiagnostic.ChangedComponent.allCases,
                    passiveRecovery: .init(attempted: true, attemptCount: 1, finalStatus: status))
                let data = try JSONEncoder().encode(diagnostic)
                let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let keys: Set<String> = classification == .identityMismatch
                    ? ["classification", "phase", "changed_components", "passive_recovery"]
                    : ["classification", "phase", "passive_recovery"]
                #expect(Set(object.keys) == keys)
                let recovery = try #require(object["passive_recovery"] as? [String: Any])
                #expect(Set(recovery.keys) == ["attempted", "attempt_count", "final_status"])
                #expect(object["classification"] as? String == classification.rawValue)
                #expect(object["phase"] as? String == phase.rawValue)
                #expect(recovery["final_status"] as? String == status.rawValue)
                if classification == .identityMismatch {
                    #expect(object["changed_components"] as? [String] ==
                        DesktopObservationTargetChangeDiagnostic.ChangedComponent.allCases.map(\.rawValue))
                }
                #expect(try JSONDecoder()
                    .decode(DesktopObservationTargetChangeDiagnostic.self, from: data) == diagnostic)
            }
        }
    }

    @Test
    func `failure transformations retain diagnostics without changing legacy details`() throws {
        let diagnostic = DesktopObservationTargetChangeDiagnostic(
            classification: .identityMismatch, phase: .afterCapture, changedComponents: [.bounds])
        let original = DesktopActionFailure.preDispatchRefusal(reason: .targetUnavailable, message: "fixture")
        let enriched = original.preservingDesktopObservationTargetChangeDiagnostic(diagnostic)
        let legacy = LegacyFailure(
            outcome: original.outcome,
            message: original.message,
            hint: original.hint,
            causeDescription: original.causeDescription,
            standardErrorCode: original.standardErrorCode,
            targetReceipt: original.targetReceipt,
            selectedLeafEvidence: original.selectedLeafEvidence,
            screenCaptureKitOwnershipDiagnostic: original.screenCaptureKitOwnershipDiagnostic)
        #expect(String(describing: enriched) == String(describing: legacy)
            .replacingOccurrences(of: "LegacyFailure(", with: "DesktopActionFailure("))
        #expect(enriched.routed(to: .bridge).desktopObservationTargetChangeDiagnostic == diagnostic)
        #expect(enriched.removingScreenCaptureKitDiagnostic().desktopObservationTargetChangeDiagnostic == diagnostic)
        #expect(enriched.removingDesktopObservationTargetChangeDiagnostic() == original)
        let data = try JSONEncoder().encode(enriched)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["desktop_observation_target_change_diagnostic"] != nil)
        #expect(try JSONDecoder().decode(DesktopActionFailure.self, from: data) == enriched)
        #expect(try JSONDecoder().decode(DesktopActionFailure.self, from: JSONEncoder().encode(original))
            .desktopObservationTargetChangeDiagnostic == nil)
    }

    private struct LegacyFailure {
        let outcome: DesktopActionOutcome
        let message: String
        let hint: String?
        let causeDescription: String?
        let standardErrorCode: StandardErrorCode?
        let targetReceipt: DesktopActionTargetReceipt?
        let selectedLeafEvidence: [DesktopSelectedLeafEvidence]?
        let screenCaptureKitOwnershipDiagnostic: ScreenCaptureKitOwnershipDiagnostic?
    }

    @Test
    func `unknown values decode and components are unique in contract order`() throws {
        let data = Data(#"""
        {"classification":"identity_mismatch","phase":"future",
         "changed_components":["bounds","future","window_id","bounds","other","owner_pid","owner_process_generation"],
         "passive_recovery":{"attempted":true,"attempt_count":1,"final_status":"future"}}
        """#.utf8)
        let decoded = try JSONDecoder().decode(DesktopObservationTargetChangeDiagnostic.self, from: data)
        #expect(decoded.phase == .unknown)
        #expect(decoded.passiveRecovery.finalStatus == .unknown)
        #expect(decoded.changedComponents == [.windowID, .ownerPID, .ownerProcessGeneration, .bounds, .unknown])
        let future = Data(#"""
        {"classification":"future","phase":"future","changed_components":["bounds"],
         "passive_recovery":{"attempted":false,"attempt_count":0,"final_status":"future"}}
        """#.utf8)
        let unknown = try JSONDecoder().decode(DesktopObservationTargetChangeDiagnostic.self, from: future)
        #expect(unknown.classification == .unknown)
        #expect(unknown.changedComponents == nil)
        let undetermined = DesktopObservationTargetChangeDiagnostic(
            classification: .identityMismatch,
            phase: .afterCapture)
        #expect(undetermined.changedComponents == nil)
        #expect(undetermined.passiveRecovery == .notAttempted)
    }
}
