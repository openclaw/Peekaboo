import CoreGraphics
import PeekabooFoundation
import XCTest
@testable import PeekabooAutomationKit

@MainActor
final class DesktopObservationCacheDiagnosticsTests: XCTestCase {
    func testObservationPreservesWindowPlanCacheDiagnosticsThroughNormalizationAndCaptureSpan() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 123,
            processStartIdentity: 456,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            windowCount: 1)
        let bounds = CGRect(x: 100, y: 100, width: 400, height: 300)
        let resolvedWindow = Self.window(title: "Resolved Document", bounds: bounds, index: 0)
        let capturedWindow = Self.window(title: "Captured Document", bounds: bounds, index: 5)
        let capture = RecordingScreenCaptureService(result: CaptureResult(
            imageData: Data([9]),
            metadata: CaptureMetadata(
                size: bounds.size,
                mode: .window,
                applicationInfo: app,
                windowInfo: capturedWindow,
                diagnostics: CaptureDiagnostics(
                    requestedScale: .logical1x,
                    nativeScale: 2,
                    outputScale: 1,
                    scaleSource: "test",
                    finalPixelSize: bounds.size,
                    windowPlanCacheStatus: .hit,
                    windowPlanCacheGeneration: 17))))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: RecordingUIAutomationService(fixedResult: ElementDetectionResult(
                snapshotId: "unused",
                screenshotPath: "/tmp/unused.png",
                elements: DetectedElements(),
                metadata: DetectionMetadata(detectionTime: 0, elementCount: 0, method: "fixture"))),
            applications: RecordingApplicationService(applications: [app], windows: [resolvedWindow]))

        let result = try await service.observe(DesktopObservationRequest(
            target: .app(identifier: "Fixture", window: .automatic),
            detection: DesktopDetectionOptions(mode: .none)))

        XCTAssertEqual(result.capture.metadata.windowInfo?.title, "Resolved Document")
        XCTAssertEqual(result.capture.metadata.windowInfo?.index, 0)
        XCTAssertEqual(
            result.capture.metadata.diagnostics?.windowPlanCacheStatus,
            CaptureWindowPlanCacheStatus.hit)
        XCTAssertEqual(result.capture.metadata.diagnostics?.windowPlanCacheGeneration, 17)
        let captureSpan = try XCTUnwrap(result.timings.spans.first { $0.name == "capture.window" })
        XCTAssertEqual(captureSpan.metadata["window_plan_cache"], "hit")
        XCTAssertEqual(captureSpan.metadata["window_plan_cache_generation"], "17")
    }

    private static func window(title: String, bounds: CGRect, index: Int) -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: 42,
            title: title,
            bounds: bounds,
            windowLevel: 0,
            alpha: 1,
            index: index,
            layer: 0,
            isOnScreen: true,
            sharingState: .readOnly,
            mutationIdentity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: 123,
                ownerProcessStartIdentity: 456,
                capturedBounds: bounds))
    }
}
