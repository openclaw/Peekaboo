import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAutomationKit

struct ObservationCaptureReceiptBindingTests {
    private let bounds = CGRect(x: 40, y: 60, width: 800, height: 600)

    @Test
    func `valid same-target capture binds to the resolved receipt`() throws {
        try DesktopObservationService.validateCaptureReceipt(
            self.capture(),
            for: self.target())
    }

    @Test
    func `capture rejects an owner generation change`() {
        #expect(throws: DesktopObservationError.self) {
            try DesktopObservationService.validateCaptureReceipt(
                self.capture(ownerProcessIdentifier: 99, ownerProcessStartIdentity: 8),
                for: self.target())
        }
    }

    @Test
    func `capture rejects an exact window ID mismatch`() {
        #expect(throws: DesktopObservationError.self) {
            try DesktopObservationService.validateCaptureReceipt(
                self.capture(windowID: 925),
                for: self.target())
        }
    }

    @Test
    func `capture rejects bounds drift`() {
        #expect(throws: DesktopObservationError.self) {
            try DesktopObservationService.validateCaptureReceipt(
                self.capture(bounds: CGRect(x: 41, y: 60, width: 800, height: 600)),
                for: self.target())
        }
    }

    @Test
    func `screen and area captures without exact receipts stay valid`() throws {
        let capture = CaptureResult(
            imageData: Data([0]),
            metadata: CaptureMetadata(size: CGSize(width: 1, height: 1), mode: .screen))

        try DesktopObservationService.validateCaptureReceipt(
            capture,
            for: ResolvedObservationTarget(kind: .screen(index: 0)))
        try DesktopObservationService.validateCaptureReceipt(
            capture,
            for: ResolvedObservationTarget(kind: .area(CGRect(x: 0, y: 0, width: 1, height: 1))))
    }

    private func target() -> ResolvedObservationTarget {
        let identity = self.identity()
        return ResolvedObservationTarget(
            kind: .windowID(924),
            app: ApplicationIdentity(
                processIdentifier: 42,
                processStartIdentity: 7,
                bundleIdentifier: "com.example.fixture",
                name: "Fixture"),
            window: WindowIdentity(windowID: 924, title: "Fixture", bounds: self.bounds, index: 0),
            bounds: self.bounds,
            detectionContext: WindowContext(
                applicationName: "Fixture",
                applicationBundleId: "com.example.fixture",
                applicationProcessId: 42,
                windowTitle: "Fixture",
                windowID: 924,
                windowBounds: self.bounds,
                windowMutationIdentity: identity))
    }

    private func capture(
        windowID: Int = 924,
        ownerProcessIdentifier: Int32 = 42,
        ownerProcessStartIdentity: UInt64 = 7,
        bounds: CGRect? = nil) -> CaptureResult
    {
        let bounds = bounds ?? self.bounds
        let identity = WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: ownerProcessIdentifier,
            ownerProcessStartIdentity: ownerProcessStartIdentity,
            capturedBounds: bounds)
        return CaptureResult(
            imageData: Data([0]),
            metadata: CaptureMetadata(
                size: bounds.size,
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: ownerProcessIdentifier,
                    processStartIdentity: ownerProcessStartIdentity,
                    bundleIdentifier: "com.example.fixture",
                    name: "Fixture"),
                windowInfo: ServiceWindowInfo(
                    windowID: windowID,
                    title: "Fixture",
                    bounds: bounds,
                    mutationIdentity: identity)))
    }

    private func identity() -> WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: 924,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 7,
            capturedBounds: self.bounds)
    }
}
