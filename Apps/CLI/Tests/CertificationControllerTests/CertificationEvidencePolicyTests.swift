import CoreGraphics
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooCertificationController

@Suite("Certification controller exact evidence policies")
struct CertificationEvidencePolicyTests {
    @Test
    func `target receipt policy requires the exact optional minimized state`() {
        let planned = Self.identity(isMinimized: false)

        #expect(CertificationTargetReceiptPolicy.matches(Self.identity(isMinimized: false), planned: planned))
        #expect(!CertificationTargetReceiptPolicy.matches(Self.identity(isMinimized: true), planned: planned))
        #expect(!CertificationTargetReceiptPolicy.matches(Self.identity(isMinimized: nil), planned: planned))
    }

    @Test
    func `canonical response policy rejects any signed-local payload drift`() throws {
        let local = ObservationFixture(windowID: 6101, path: "observations/controller-a-checkpoint-001.png")
        let matching = ObservationFixture(windowID: 6101, path: local.path)
        let drifted = ObservationFixture(windowID: 6101, path: "observations/controller-a-final-bounds.png")

        try CertificationCanonicalResponsePolicy.requireMatchingBridgeEncoding(
            signed: matching,
            local: local
        )
        #expect(throws: CertificationControllerError.self) {
            try CertificationCanonicalResponsePolicy.requireMatchingBridgeEncoding(
                signed: drifted,
                local: local
            )
        }
    }

    private static func identity(isMinimized: Bool?) -> WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: 6101,
            ownerProcessIdentifier: 5101,
            ownerProcessStartIdentity: 510_100,
            capturedBounds: CGRect(x: 10, y: 20, width: 640, height: 480),
            isMinimized: isMinimized
        )
    }

    private struct ObservationFixture: Codable {
        let windowID: Int
        let path: String
    }
}
