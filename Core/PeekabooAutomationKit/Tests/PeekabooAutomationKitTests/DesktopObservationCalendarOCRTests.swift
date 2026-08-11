import CoreGraphics
import Foundation
import XCTest
@testable import PeekabooAutomationKit

@MainActor
final class DesktopObservationCalendarOCRTests: XCTestCase {
    func testIncompleteAccessibilityObservationSucceedsWithOCR() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 858,
            processStartIdentity: 4242,
            bundleIdentifier: "com.apple.iCal",
            name: "Calendar",
            windowCount: 1)
        let bounds = CGRect(x: 200, y: 300, width: 800, height: 600)
        let identity = WindowMutationIdentity(
            windowID: 119,
            ownerProcessIdentifier: 858,
            ownerProcessStartIdentity: 4242,
            capturedBounds: bounds)
        let window = ServiceWindowInfo(
            windowID: 119,
            title: "Calendar",
            bounds: bounds,
            mutationIdentity: identity)
        let context = WindowContext(
            applicationName: "Calendar",
            applicationBundleId: "com.apple.iCal",
            applicationProcessId: 858,
            windowTitle: "Calendar",
            windowID: 119,
            windowBounds: bounds,
            windowMutationIdentity: identity)
        let incompleteAX = ElementDetectionResult(
            snapshotId: "calendar-ocr",
            screenshotPath: "/tmp/calendar.png",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0.1,
                elementCount: 0,
                method: "AXorcist",
                warnings: ["ax_incomplete_read"],
                windowContext: context,
                truncationInfo: DetectionTruncationInfo(incompleteAccessibilityRead: true)))
        let automation = RecordingUIAutomationService(fixedResult: incompleteAX)
        let ocr = RecordingOCRRecognizer(result: OCRTextResult(
            observations: [OCRTextObservation(
                text: "August 10, 2026",
                confidence: 0.93,
                boundingBox: CGRect(x: 0.05, y: 0.85, width: 0.225, height: 0.04))],
            imageSize: CGSize(width: 1600, height: 1200)))
        let capture = CaptureResult(
            imageData: Data([1]),
            metadata: CaptureMetadata(
                size: bounds.size,
                mode: .window,
                applicationInfo: app,
                windowInfo: window))
        let service = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(result: capture),
            automation: automation,
            applications: RecordingApplicationService(applications: [app], windows: [window]),
            ocrRecognizer: ocr,
            exactWindowMetadataProvider: CalendarExactWindowMetadataProvider(bounds: bounds),
            processStartIdentityProvider: { _ in 4242 },
            windowMutationIdentityProvider: { _ in identity })

        let result = try await service.observe(DesktopObservationRequest(
            target: .app(identifier: "Calendar", window: .automatic),
            detection: DesktopDetectionOptions(mode: .accessibilityAndOCR, preferOCR: false),
            output: DesktopObservationOutputOptions(snapshotID: "calendar-ocr")))

        let element = try XCTUnwrap(result.elements?.elements.other.first)
        XCTAssertEqual(element.label, "August 10, 2026")
        XCTAssertEqual(element.type, .staticText)
        XCTAssertEqual(element.attributes["confidence"], "0.93")
        XCTAssertFalse(element.isActionable)
        XCTAssertEqual(result.elements?.metadata.warnings, ["ax_incomplete_read"])
        XCTAssertEqual(result.elements?.metadata.truncationInfo?.incompleteAccessibilityRead, true)
        XCTAssertEqual(result.elements?.metadata.windowContext?.windowMutationIdentity, identity)
        XCTAssertEqual(result.diagnostics.warnings, ["ax_incomplete_read"])
        XCTAssertEqual(ocr.qualities, [.fast])
    }
}

private struct CalendarExactWindowMetadataProvider: ExactWindowMetadataProviding {
    let bounds: CGRect

    func metadata(for windowID: CGWindowID) -> ExactWindowObservationMetadata? {
        guard windowID == 119 else { return nil }
        return ExactWindowObservationMetadata(
            ownerProcessIdentifier: 858,
            ownerProcessStartIdentity: 4242,
            title: "Calendar",
            bounds: self.bounds,
            applicationName: "Calendar")
    }

    func processStartIdentity(for _: Int32) -> UInt64? {
        4242
    }
}
