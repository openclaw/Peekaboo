import CoreGraphics
import XCTest
@testable import PeekabooAutomationKit

@MainActor
final class ObservationAllScreensFailClosedTests: XCTestCase {
    func testResolverRefusesCompositeAllScreensTarget() async throws {
        let resolver = ObservationTargetResolver(
            applications: RecordingApplicationService(applications: [], windows: []))

        do {
            _ = try await resolver.resolve(.allScreens, snapshot: DesktopStateSnapshot())
            XCTFail("Expected all-screens resolution to fail closed")
        } catch let error as DesktopObservationError {
            XCTAssertEqual(error, .unsupportedTarget("all screens require multi-artifact output"))
        }
    }

    func testCaptureBoundaryRefusesAllScreensFromCustomResolver() async throws {
        let capture = RecordingScreenCaptureService(result: CaptureResult(
            imageData: Data([1]),
            metadata: CaptureMetadata(size: CGSize(width: 1, height: 1), mode: .screen)))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: Self.automation(),
            targetResolver: AllScreensAsPrimaryScreenResolver())

        do {
            _ = try await service.observe(DesktopObservationRequest(
                target: .allScreens,
                detection: DesktopDetectionOptions(mode: .none)))
            XCTFail("Expected all-screens capture to fail before selecting the primary screen")
        } catch let error as DesktopObservationError {
            XCTAssertEqual(error, .unsupportedTarget("all screens require multi-artifact output"))
        }

        XCTAssertTrue(capture.operations.isEmpty)
    }

    func testPrimaryScreenRequestStillCapturesDisplayWithNilIndex() async throws {
        let capture = RecordingScreenCaptureService(result: CaptureResult(
            imageData: Data([1]),
            metadata: CaptureMetadata(size: CGSize(width: 1, height: 1), mode: .screen)))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: Self.automation(),
            applications: RecordingApplicationService(applications: [], windows: []))

        let result = try await service.observe(DesktopObservationRequest(
            target: .screen(index: nil),
            detection: DesktopDetectionOptions(mode: .none)))

        XCTAssertEqual(result.target.kind, .screen(index: nil))
        XCTAssertEqual(capture.operations, [.screen(nil, .logical1x, .auto)])
    }

    private static func automation() -> RecordingUIAutomationService {
        RecordingUIAutomationService(fixedResult: ElementDetectionResult(
            snapshotId: "unused",
            screenshotPath: "",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 0,
                method: "unused")))
    }
}

@MainActor
private final class AllScreensAsPrimaryScreenResolver: ObservationTargetResolving {
    func resolve(
        _: DesktopObservationTargetRequest,
        snapshot _: DesktopStateSnapshot) async throws -> ResolvedObservationTarget
    {
        ResolvedObservationTarget(kind: .screen(index: nil))
    }
}
