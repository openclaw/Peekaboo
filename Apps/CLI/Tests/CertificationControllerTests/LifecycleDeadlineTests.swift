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
    func `controller lifecycle inspection errors identify the exact marker`() async throws {
        let parentFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: parentFile)
        defer { try? FileManager.default.removeItem(at: parentFile) }
        let nonce = String(repeating: "9", count: 64)

        let start = parentFile.appendingPathComponent("start.json")
        let startError = await #expect(throws: CertificationControllerError.self) {
            try await CertificationControllerLifecycleGate.waitForStart(
                at: start,
                executionNonce: nonce,
                controllerID: "controller-a"
            )
        }
        #expect(startError == .unsafePrivatePath("Cannot inspect controller start marker at \(start.path)."))

        let finalBounds = parentFile.appendingPathComponent("final-bounds-start.json")
        let finalBoundsError = await #expect(throws: CertificationControllerError.self) {
            try await CertificationControllerLifecycleGate.waitForFinalBoundsStart(
                at: finalBounds,
                executionNonce: nonce,
                monitorInstanceID: "monitor-a",
                controllerID: "controller-a"
            )
        }
        #expect(finalBoundsError == .unsafePrivatePath(
            "Cannot inspect controller final-bounds start marker at \(finalBounds.path)."
        ))

        let release = parentFile.appendingPathComponent("release.json")
        let releaseError = await #expect(throws: CertificationControllerError.self) {
            try await CertificationControllerLifecycleGate.waitForRelease(
                at: release,
                executionNonce: nonce
            )
        }
        #expect(releaseError == .unsafePrivatePath("Cannot inspect controller release marker at \(release.path)."))
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
