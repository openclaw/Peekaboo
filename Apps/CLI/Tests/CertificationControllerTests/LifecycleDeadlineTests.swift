import Foundation
import Testing
@testable import PeekabooCertificationController

@Suite("Certification controller monotonic lifecycle deadlines")
struct LifecycleDeadlineTests {
    @Test
    func `controller lifecycle wait honors an injected continuous timeout`() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("start.json")

        await #expect(throws: CertificationControllerError.self) {
            try await CertificationControllerLifecycleGate.waitForStart(
                at: missing,
                executionNonce: String(repeating: "9", count: 64),
                controllerID: "controller-a",
                timeout: .milliseconds(10),
                pollInterval: .milliseconds(1)
            )
        }
    }

    @Test
    func `observe-only marker wait honors an injected continuous timeout`() async throws {
        let plan = try CertificationObserveOnlyPlan.decode(ObserveOnlyTests.validPlanData)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("observe.json")

        await #expect(throws: CertificationControllerError.self) {
            try await CertificationObserveOnlyRunner.waitForMarker(
                .observe,
                at: missing,
                plan: plan,
                timeout: .milliseconds(10),
                pollInterval: .milliseconds(1)
            )
        }
    }
}
