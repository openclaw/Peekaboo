import CoreGraphics
import os
import XCTest
@testable import PeekabooAutomationKit

final class ObservationOCRCoordinateTests: XCTestCase {
    func testVisionRecognitionFallbackRunsOnlyAfterPrimaryFailure() throws {
        var calls: [String] = []

        let result = try OCRService.withRecognitionFallback(
            primary: { () throws -> String in
                calls.append("primary")
                throw OCRFallbackTestError.failed
            },
            fallback: {
                calls.append("fallback")
                return "recovered"
            })

        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(calls, ["primary", "fallback"])
    }

    func testVisionRecognitionFallbackReturnsIncompleteWhenBothModesFail() {
        XCTAssertThrowsError(try OCRService.withRecognitionFallback(
            primary: { throw OCRFallbackTestError.failed },
            fallback: { throw OCRFallbackTestError.failed }))
        { error in
            XCTAssertEqual(
                error as? OCRServiceError,
                .incomplete("Apple Vision text recognition failed in both primary and fast fallback modes"))
        }
    }

    func testVisionRecognitionCancellationAfterPrimaryFailureSkipsFallback() async {
        let fallbackCalled = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            try OCRService.withRecognitionFallback(
                primary: { () throws -> String in
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw OCRFallbackTestError.failed
                },
                fallback: {
                    fallbackCalled.withLock { $0 = true }
                    return "unsafe"
                })
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertFalse(fallbackCalled.withLock { $0 })
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testFastRecognitionUsesOneAttemptAndMapsFailureToIncomplete() throws {
        var attempts = 0
        let value = try OCRService.withSingleRecognitionAttempt {
            attempts += 1
            return "fast"
        }

        XCTAssertEqual(value, "fast")
        XCTAssertEqual(attempts, 1)
        XCTAssertThrowsError(try OCRService.withSingleRecognitionAttempt {
            attempts += 1
            throw OCRFallbackTestError.failed
        }) { error in
            XCTAssertEqual(error as? OCRServiceError, .incomplete("Apple Vision fast text recognition failed"))
        }
        XCTAssertEqual(attempts, 2)
    }

    func testFastRecognitionPreservesCancellationAfterFrameworkFailure() async {
        let task = Task {
            try OCRService.withSingleRecognitionAttempt { () throws -> String in
                withUnsafeCurrentTask { $0?.cancel() }
                throw OCRFallbackTestError.failed
            }
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testOCRGlobalBoundsUseLogicalCaptureBoundsAtRetinaScale() throws {
        let result = OCRTextResult(
            observations: [OCRTextObservation(
                text: "Calendar",
                confidence: 0.93,
                boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.25, height: 0.1))],
            imageSize: CGSize(width: 1600, height: 1200))

        let element = try XCTUnwrap(ObservationOCRMapper.elements(
            from: result,
            windowBounds: CGRect(x: 200, y: 300, width: 800, height: 600)).first)

        XCTAssertEqual(element.bounds, CGRect(x: 280, y: 420, width: 200, height: 60))
        XCTAssertEqual(element.attributes["confidence"], "0.93")
        XCTAssertEqual(element.type, .staticText)
        XCTAssertFalse(element.isActionable)
    }

    func testLegacyOCRMarkerRemainsSemanticEvidenceWithoutConfidence() throws {
        let detected = DetectedElement(
            id: "ocr_legacy",
            type: .staticText,
            label: "August",
            bounds: CGRect(x: 10, y: 20, width: 100, height: 20),
            attributes: ["description": "ocr"])
        let legacyJSON = Data((
            #"{"id":"ocr_legacy","elementId":"ocr_legacy","role":"AXStaticText", "# +
                #""description":"ocr","frame":[[10,20],[100,20]],"isActionable":false,"children":[]}"#).utf8)
        let stored = try JSONDecoder().decode(UIElement.self, from: legacyJSON)

        XCTAssertTrue(detected.isOCRSemanticEvidence)
        XCTAssertNil(stored.confidence)
        XCTAssertTrue(stored.isOCRSemanticEvidence)

        let ordinary = DetectedElement(
            id: "S1",
            type: .staticText,
            label: "OCR",
            bounds: CGRect(x: 10, y: 50, width: 100, height: 20),
            attributes: ["description": "OCR"])
        XCTAssertFalse(ordinary.isOCRSemanticEvidence)
    }

    func testOCRMergePreservesAXWarningAndPublicationReceipts() throws {
        let completedAt = Date(timeIntervalSinceReferenceDate: 123)
        let bounds = CGRect(x: 200, y: 300, width: 800, height: 600)
        let coordinateContext = CaptureCoordinateContext(
            metadata: CaptureMetadata(
                size: CGSize(width: 1600, height: 1200),
                mode: .window,
                windowInfo: ServiceWindowInfo(windowID: 119, title: "Calendar", bounds: bounds),
                diagnostics: CaptureDiagnostics(
                    requestedScale: .native,
                    nativeScale: 2,
                    outputScale: 2,
                    scaleSource: "fixture",
                    finalPixelSize: CGSize(width: 1600, height: 1200))),
            referenceID: "calendar-snapshot")
        let base = ElementDetectionResult(
            snapshotId: "calendar-snapshot",
            screenshotPath: "/tmp/calendar.png",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0.1,
                elementCount: 0,
                method: "AXorcist",
                warnings: ["ax_incomplete_read"],
                truncationInfo: DetectionTruncationInfo(incompleteAccessibilityRead: true),
                desktopMutationCompletedAt: completedAt,
                desktopMutationPreservationAllowed: true,
                captureCoordinateContext: coordinateContext))
        let ocr = OCRTextResult(
            observations: [OCRTextObservation(
                text: "August",
                confidence: 0.9,
                boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.25, height: 0.1))],
            imageSize: CGSize(width: 1600, height: 1200))
        let ocrElements = try ObservationOCRMapper.elements(
            from: ocr,
            windowBounds: XCTUnwrap(coordinateContext.logicalBounds))

        let merged = ObservationOCRMapper.merge(
            ocrResult: ocr,
            ocrElements: ocrElements,
            into: base)

        XCTAssertEqual(merged.metadata.warnings, ["ax_incomplete_read"])
        XCTAssertEqual(merged.metadata.truncationInfo?.incompleteAccessibilityRead, true)
        XCTAssertEqual(merged.metadata.desktopMutationCompletedAt, completedAt)
        XCTAssertEqual(merged.metadata.desktopMutationPreservationAllowed, true)
        XCTAssertEqual(merged.metadata.captureCoordinateContext, coordinateContext)
    }

    @MainActor
    func testOCRConfidenceAndStaticTextRoleRoundTripThroughSnapshotStorage() async throws {
        let manager = InMemorySnapshotManager()
        let snapshotID = try await manager.createSnapshot()
        try await manager.storeScreenshot(SnapshotScreenshotRequest(
            snapshotId: snapshotID,
            screenshotPath: "/tmp/calendar.png",
            applicationBundleId: "com.apple.iCal",
            applicationProcessId: 858,
            applicationName: "Calendar",
            windowTitle: "Calendar",
            windowBounds: CGRect(x: 200, y: 300, width: 800, height: 600)))
        let element = DetectedElement(
            id: "ocr_1",
            type: .staticText,
            label: "August",
            bounds: CGRect(x: 280, y: 420, width: 200, height: 60),
            attributes: [
                "description": "ocr",
                "confidence": "0.93",
            ])
        try await manager.storeDetectionResult(
            snapshotId: snapshotID,
            result: ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: "/tmp/calendar.png",
                elements: DetectedElements(other: [element]),
                metadata: DetectionMetadata(
                    detectionTime: 0.1,
                    elementCount: 1,
                    method: "AXorcist+OCR")))

        let storedSnapshot = try await manager.getUIAutomationSnapshot(snapshotId: snapshotID)
        let stored = try XCTUnwrap(storedSnapshot)
        XCTAssertEqual(stored.uiMap["ocr_1"]?.confidence, 0.93)
        let reloadedDetection = try await manager.getDetectionResult(snapshotId: snapshotID)
        let reloaded = try XCTUnwrap(reloadedDetection)
        let reloadedElement = try XCTUnwrap(reloaded.elements.other.first)
        XCTAssertEqual(reloadedElement.type, .staticText)
        XCTAssertEqual(reloadedElement.attributes["confidence"], "0.93")
        XCTAssertFalse(reloadedElement.isActionable)
    }

    func testROIPresentationPreservesOCRConfidenceAndElementState() throws {
        let sourceBounds = CGRect(x: 200, y: 300, width: 800, height: 600)
        let viewport = CaptureViewport(
            sourceLogicalBounds: sourceBounds,
            requestedWindowRelativeBounds: CGRect(x: 20, y: 30, width: 400, height: 300),
            deliveredWindowRelativeBounds: CGRect(x: 20, y: 30, width: 400, height: 300),
            logicalBounds: CGRect(x: 220, y: 330, width: 400, height: 300),
            sourceImageSize: CGSize(width: 1600, height: 1200))
        let element = UIElement(
            id: "ocr_1",
            elementId: "ocr_1",
            role: "AXStaticText",
            label: "August",
            description: "ocr",
            confidence: 0.93,
            frame: CGRect(x: 280, y: 420, width: 200, height: 60),
            isActionable: false,
            isEnabled: true,
            isSelected: false,
            isValueSettable: false)

        let presented = try XCTUnwrap(DesktopObservationROIProcessor.presentationElements(
            [element],
            viewport: viewport).first)

        XCTAssertEqual(presented.frame, CGRect(x: 60, y: 90, width: 200, height: 60))
        XCTAssertEqual(presented.confidence, 0.93)
        XCTAssertEqual(presented.isEnabled, true)
        XCTAssertEqual(presented.isSelected, false)
        XCTAssertEqual(presented.isValueSettable, false)
    }
}

private enum OCRFallbackTestError: Error {
    case failed
}
