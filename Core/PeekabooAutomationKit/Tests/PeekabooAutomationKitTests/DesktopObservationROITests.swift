import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PeekabooAutomationKit

struct DesktopObservationROITests {
    @Test
    func `ROI parser accepts window local logical bounds and rejects malformed input`() throws {
        #expect(try CaptureRegionOfInterest.parse("10,20,30,40").bounds == CGRect(x: 10, y: 20, width: 30, height: 40))
        #expect(throws: CaptureROIError.invalidFormat) {
            _ = try CaptureRegionOfInterest.parse("10,20,30")
        }
        #expect(throws: CaptureROIError.invalidBounds) {
            try DesktopObservationROIProcessor.validateRequest(
                CaptureRegionOfInterest(bounds: CGRect(x: -1, y: 0, width: 10, height: 10)),
                target: .windowID(42))
        }
        #expect(throws: CaptureROIError.invalidBounds) {
            try DesktopObservationROIProcessor.validateRequest(
                CaptureRegionOfInterest(bounds: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)),
                target: .windowID(42))
        }
        for error in [
            CaptureROIError.invalidFormat,
            .invalidBounds,
            .exactWindowRequired,
            .missingExactWindowReceipt,
            .outOfBounds,
            .invalidSourceImage,
            .unsupportedScale,
            .outputTooLarge,
            .hostDidNotApplyROI,
        ] {
            #expect(CaptureROIError(code: error.code) == error)
        }
    }

    @Test
    func `ROI requires an exact window target`() throws {
        let roi = CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(throws: CaptureROIError.exactWindowRequired) {
            try DesktopObservationROIProcessor.validateRequest(roi, target: .frontmost)
        }
        try DesktopObservationROIProcessor.validateRequest(roi, target: .windowID(42))
        try DesktopObservationROIProcessor.validateRequest(roi, target: .pid(123, window: .id(42)))
    }

    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func `ROI crops maps filters and preserves the full exact window receipt`(scale: CGFloat) throws {
        let fullBounds = CGRect(x: 200, y: 300, width: 100, height: 80)
        let capture = try Self.capture(bounds: fullBounds, scale: scale)
        let roi = CaptureRegionOfInterest(bounds: CGRect(x: 10, y: 20, width: 30, height: 20))
        let inside = DetectedElement(
            id: "inside",
            type: .button,
            label: "Inside",
            bounds: CGRect(x: 215, y: 325, width: 10, height: 5))
        let partial = DetectedElement(
            id: "partial",
            type: .other,
            label: "Partial",
            bounds: CGRect(x: 235, y: 335, width: 20, height: 20))
        let outside = DetectedElement(
            id: "outside",
            type: .button,
            label: "Outside",
            bounds: CGRect(x: 270, y: 360, width: 10, height: 10))
        let detection = ElementDetectionResult(
            snapshotId: "roi-snapshot",
            screenshotPath: "/tmp/full.png",
            elements: DetectedElements(buttons: [inside, outside], other: [partial]),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 3,
                method: "test",
                windowContext: WindowContext(
                    applicationProcessId: 123,
                    windowID: 42,
                    windowBounds: fullBounds,
                    windowMutationIdentity: capture.metadata.windowInfo?.mutationIdentity)))
        let ocr = OCRTextResult(
            observations: [
                OCRTextObservation(
                    text: "Inside",
                    confidence: 0.9,
                    boundingBox: CGRect(x: 0.15, y: 0.625, width: 0.1, height: 0.0625)),
                OCRTextObservation(
                    text: "Partial",
                    confidence: 0.8,
                    boundingBox: CGRect(x: 0.35, y: 0.3125, width: 0.2, height: 0.25)),
                OCRTextObservation(
                    text: "Outside",
                    confidence: 0.7,
                    boundingBox: CGRect(x: 0.7, y: 0.125, width: 0.1, height: 0.125)),
            ],
            imageSize: capture.metadata.size)

        let result = try DesktopObservationROIProcessor.apply(
            roi,
            target: Self.target(bounds: fullBounds),
            capture: capture,
            elements: detection,
            ocr: ocr)
        try DesktopObservationROIProcessor.validateApplied(
            roi,
            requestTarget: .windowID(42),
            resolvedTarget: Self.target(bounds: fullBounds),
            capture: result.capture)

        #expect(result.capture.metadata.size == CGSize(width: 30 * scale, height: 20 * scale))
        #expect(result.capture.savedPath == nil)
        #expect(result.capture.metadata.windowInfo?.bounds == fullBounds)
        let viewport = try #require(result.capture.metadata.viewport)
        #expect(viewport.sourceLogicalBounds == fullBounds)
        #expect(viewport.requestedWindowRelativeBounds == roi.bounds)
        #expect(viewport.logicalBounds == CGRect(x: 210, y: 320, width: 30, height: 20))
        #expect(result.elements?.elements.all.map(\.id).sorted() == ["inside", "partial"])
        #expect(result.elements?.screenshotPath.isEmpty == true)
        #expect(result.elements?.metadata.captureCoordinateContext?.referenceID == "roi-snapshot")
        let projectedOCR = try #require(result.ocr)
        #expect(projectedOCR.imageSize == result.capture.metadata.size)
        #expect(projectedOCR.observations.map(\.text) == ["Inside", "Partial"])
        let insideOCR = try #require(projectedOCR.observations.first)
        #expect(abs(insideOCR.boundingBox.minX - (1.0 / 6.0)) < 0.000_001)
        #expect(abs(insideOCR.boundingBox.minY - 0.5) < 0.000_001)
        #expect(abs(insideOCR.boundingBox.width - (1.0 / 3.0)) < 0.000_001)
        #expect(abs(insideOCR.boundingBox.height - 0.25) < 0.000_001)

        let presentation = try DesktopObservationROIProcessor.presentationElements(
            #require(result.elements).elements,
            viewport: viewport)
        #expect(presentation.findById("inside")?.bounds == CGRect(x: 5, y: 5, width: 10, height: 5))
        #expect(presentation.findById("partial")?.bounds == CGRect(x: 25, y: 15, width: 5, height: 5))

        let context = CaptureCoordinateContext(metadata: result.capture.metadata, referenceID: "roi-snapshot")
        let mapped = try CaptureCoordinateMapper.globalPoint(
            for: CGPoint(x: 15 * scale, y: 10 * scale),
            in: .imagePixels,
            context: context)
        #expect(mapped == CGPoint(x: 225, y: 330))
    }

    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func `ROI uses top left raster orientation for colored quadrants`(scale: CGFloat) throws {
        let fullBounds = CGRect(x: 200, y: 300, width: 4, height: 4)
        let baseCapture = try Self.capture(bounds: fullBounds, scale: scale)
        let capture = try CaptureResult(
            imageData: Self.quadrantImageData(scale: Int(scale)),
            metadata: baseCapture.metadata)
        let cases: [(CGRect, TestRGB)] = [
            (CGRect(x: 0, y: 0, width: 2, height: 2), TestRGB(red: 1, green: 0, blue: 0)),
            (CGRect(x: 2, y: 0, width: 2, height: 2), TestRGB(red: 0, green: 1, blue: 0)),
            (CGRect(x: 0, y: 2, width: 2, height: 2), TestRGB(red: 0, green: 0, blue: 1)),
            (CGRect(x: 2, y: 2, width: 2, height: 2), TestRGB(red: 1, green: 1, blue: 0)),
        ]

        for (bounds, expectedColor) in cases {
            let result = try DesktopObservationROIProcessor.apply(
                CaptureRegionOfInterest(bounds: bounds),
                target: Self.target(bounds: fullBounds),
                capture: capture,
                elements: nil,
                ocr: nil)

            #expect(result.capture.metadata.size == CGSize(width: 2 * scale, height: 2 * scale))
            let actualColor = try Self.averageRGB(in: result.capture.imageData)
            #expect(abs(actualColor.red - expectedColor.red) < 0.01)
            #expect(abs(actualColor.green - expectedColor.green) < 0.01)
            #expect(abs(actualColor.blue - expectedColor.blue) < 0.01)
        }
    }

    @Test
    func `ROI refuses out of window bounds and missing exact receipt`() throws {
        let fullBounds = CGRect(x: 0, y: 0, width: 100, height: 80)
        let capture = try Self.capture(bounds: fullBounds, scale: 1)
        let target = Self.target(bounds: fullBounds)

        #expect(throws: CaptureROIError.outOfBounds) {
            _ = try DesktopObservationROIProcessor.apply(
                CaptureRegionOfInterest(bounds: CGRect(x: 90, y: 0, width: 20, height: 10)),
                target: target,
                capture: capture,
                elements: nil,
                ocr: nil)
        }

        let missingReceipt = CaptureResult(
            imageData: capture.imageData,
            metadata: CaptureMetadata(
                size: capture.metadata.size,
                mode: .window,
                windowInfo: ServiceWindowInfo(windowID: 42, title: "Fixture", bounds: fullBounds)))
        #expect(throws: CaptureROIError.missingExactWindowReceipt) {
            _ = try DesktopObservationROIProcessor.apply(
                CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 20, height: 10)),
                target: target,
                capture: missingReceipt,
                elements: nil,
                ocr: nil)
        }

        #expect(throws: CaptureROIError.missingExactWindowReceipt) {
            _ = try DesktopObservationROIProcessor.apply(
                CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 20, height: 10)),
                target: ResolvedObservationTarget(
                    kind: .windowID(42),
                    window: WindowIdentity(windowID: 42, title: "Fixture", bounds: fullBounds, index: 0)),
                capture: capture,
                elements: nil,
                ocr: nil)
        }
    }

    @Test
    func `ROI enforces scale and output dimension limits`() throws {
        let regularBounds = CGRect(x: 0, y: 0, width: 100, height: 80)
        let unsupportedScale = try Self.capture(bounds: regularBounds, scale: 5)
        #expect(throws: CaptureROIError.unsupportedScale) {
            _ = try DesktopObservationROIProcessor.apply(
                CaptureRegionOfInterest(bounds: CGRect(x: 0, y: 0, width: 20, height: 10)),
                target: Self.target(bounds: regularBounds),
                capture: unsupportedScale,
                elements: nil,
                ocr: nil)
        }

        let wideBounds = CGRect(x: 0, y: 0, width: 9000, height: 2)
        let wideCapture = try Self.capture(bounds: wideBounds, scale: 1)
        #expect(throws: CaptureROIError.outputTooLarge) {
            _ = try DesktopObservationROIProcessor.apply(
                CaptureRegionOfInterest(bounds: CGRect(origin: .zero, size: wideBounds.size)),
                target: Self.target(bounds: wideBounds),
                capture: wideCapture,
                elements: nil,
                ocr: nil)
        }
    }

    @Test
    func `ROI remote validation rejects a host that returns the full window`() {
        let fullBounds = CGRect(x: 200, y: 300, width: 100, height: 80)
        let roi = CaptureRegionOfInterest(bounds: CGRect(x: 10, y: 20, width: 30, height: 20))
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 456,
            capturedBounds: fullBounds)
        let ignored = CaptureResult(
            imageData: Data(),
            metadata: CaptureMetadata(
                size: fullBounds.size,
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 123,
                    processStartIdentity: 456,
                    bundleIdentifier: "test.roi",
                    name: "ROI Fixture"),
                windowInfo: ServiceWindowInfo(
                    windowID: 42,
                    title: "Fixture",
                    bounds: fullBounds,
                    mutationIdentity: identity),
                viewport: CaptureViewport(
                    sourceLogicalBounds: fullBounds,
                    requestedWindowRelativeBounds: roi.bounds,
                    deliveredWindowRelativeBounds: CGRect(origin: .zero, size: fullBounds.size),
                    logicalBounds: fullBounds,
                    sourceImageSize: fullBounds.size)))

        #expect(throws: CaptureROIError.hostDidNotApplyROI) {
            try DesktopObservationROIProcessor.validateApplied(
                roi,
                requestTarget: .windowID(42),
                resolvedTarget: Self.target(bounds: fullBounds),
                capture: ignored)
        }
    }

    @Test
    func `fractional scale ROI touching right and bottom edges remains valid`() throws {
        let fullBounds = CGRect(x: 100.1, y: 200.2, width: 52.6, height: 52.6)
        let scale = CGFloat(79) / fullBounds.width
        let capture = try Self.capture(bounds: fullBounds, scale: scale)
        let roi = CaptureRegionOfInterest(bounds: CGRect(x: 10.2, y: 9.7, width: 42.4, height: 42.9))

        let result = try DesktopObservationROIProcessor.apply(
            roi,
            target: Self.target(bounds: fullBounds),
            capture: capture,
            elements: nil,
            ocr: nil)
        try DesktopObservationROIProcessor.validateApplied(
            roi,
            requestTarget: .windowID(42),
            resolvedTarget: Self.target(bounds: fullBounds),
            capture: result.capture)

        let viewport = try #require(result.capture.metadata.viewport)
        #expect(abs(viewport.deliveredWindowRelativeBounds.maxX - fullBounds.width) < 0.000_001)
        #expect(abs(viewport.deliveredWindowRelativeBounds.maxY - fullBounds.height) < 0.000_001)
        #expect(abs(viewport.logicalBounds.maxX - fullBounds.maxX) < 0.000_001)
        #expect(abs(viewport.logicalBounds.maxY - fullBounds.maxY) < 0.000_001)
    }

    @Test @MainActor
    func `ROI coordinate context survives in memory snapshot persistence`() async throws {
        let manager = InMemorySnapshotManager()
        let snapshotID = try await manager.createSnapshot()
        let capture = try Self.capture(bounds: CGRect(x: 20, y: 30, width: 100, height: 80), scale: 1)
        let result = try DesktopObservationROIProcessor.apply(
            CaptureRegionOfInterest(bounds: CGRect(x: 10, y: 10, width: 40, height: 20)),
            target: Self.target(bounds: CGRect(x: 20, y: 30, width: 100, height: 80)),
            capture: capture,
            elements: ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: "/tmp/roi.png",
                elements: DetectedElements(),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 0,
                    method: "test")),
            ocr: nil)
        let detection = try #require(result.elements)
        try await manager.storeDetectionResult(snapshotId: snapshotID, result: detection)

        let restoredDetection = try #require(try await manager.getDetectionResult(snapshotId: snapshotID))
        #expect(restoredDetection.metadata.captureCoordinateContext == detection.metadata.captureCoordinateContext)
        let restoredSnapshot = try #require(try await manager.getUIAutomationSnapshot(snapshotId: snapshotID))
        #expect(restoredSnapshot.captureCoordinateContext == detection.metadata.captureCoordinateContext)
    }

    @Test @MainActor
    func `ROI coordinate context survives disk snapshot restart`() async throws {
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-roi-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let manager = SnapshotManager(snapshotStorageURL: storageURL)
        let snapshotID = try await manager.createSnapshot()
        let capture = try Self.capture(bounds: CGRect(x: 20, y: 30, width: 100, height: 80), scale: 2)
        let result = try DesktopObservationROIProcessor.apply(
            CaptureRegionOfInterest(bounds: CGRect(x: 10, y: 10, width: 40, height: 20)),
            target: Self.target(bounds: CGRect(x: 20, y: 30, width: 100, height: 80)),
            capture: capture,
            elements: ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: "/tmp/roi-disk.png",
                elements: DetectedElements(),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 0,
                    method: "test")),
            ocr: nil)
        let detection = try #require(result.elements)
        try await manager.storeDetectionResult(snapshotId: snapshotID, result: detection)

        let restarted = SnapshotManager(snapshotStorageURL: storageURL)
        let restoredDetection = try #require(try await restarted.getDetectionResult(snapshotId: snapshotID))
        #expect(restoredDetection.metadata.captureCoordinateContext == detection.metadata.captureCoordinateContext)
        let restoredSnapshot = try #require(try await restarted.getUIAutomationSnapshot(snapshotId: snapshotID))
        #expect(restoredSnapshot.captureCoordinateContext == detection.metadata.captureCoordinateContext)
    }

    @Test @MainActor
    func `full window refresh clears a reused snapshot ROI viewport`() async throws {
        let screenshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-roi-refresh-\(UUID().uuidString).png")
        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-roi-refresh-store-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: screenshotURL)
            try? FileManager.default.removeItem(at: storageURL)
        }
        try Self.capture(bounds: CGRect(x: 20, y: 30, width: 100, height: 80), scale: 1).imageData
            .write(to: screenshotURL)

        try await Self.verifyFullRefreshClearsROI(
            manager: InMemorySnapshotManager(),
            screenshotPath: screenshotURL.path)
        try await Self.verifyFullRefreshClearsROI(
            manager: SnapshotManager(snapshotStorageURL: storageURL),
            screenshotPath: screenshotURL.path)
    }

    @Test
    @MainActor
    func `atomic observation snapshot preserves the previous entry when artifact staging fails`() async throws {
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-atomic-observation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let originalURL = sourceDirectory.appendingPathComponent("original.png")
        let replacementURL = sourceDirectory.appendingPathComponent("replacement.png")
        let missingAnnotationURL = sourceDirectory.appendingPathComponent("missing-annotation.png")
        let originalData = try Self.capture(
            bounds: CGRect(x: 0, y: 0, width: 8, height: 8),
            scale: 1).imageData
        let replacementData = try Self.capture(
            bounds: CGRect(x: 0, y: 0, width: 4, height: 4),
            scale: 1).imageData
        try originalData.write(to: originalURL)
        try replacementData.write(to: replacementURL)

        let manager = InMemorySnapshotManager(options: .init(copyArtifactsOnStore: true))
        #expect(manager.supportsAtomicObservationSnapshotPublication)
        let snapshotID = try await manager.createSnapshot()
        try await manager.storeScreenshot(SnapshotScreenshotRequest(
            snapshotId: snapshotID,
            screenshotPath: originalURL.path,
            applicationBundleId: "test.original",
            applicationProcessId: 123,
            applicationName: "Original",
            windowTitle: "Original",
            windowBounds: CGRect(x: 0, y: 0, width: 8, height: 8)))
        let originalSnapshot = try #require(try await manager.getUIAutomationSnapshot(snapshotId: snapshotID))
        let storedOriginalPath = try #require(originalSnapshot.screenshotPath)

        await #expect(throws: (any Error).self) {
            try await manager.storeObservationSnapshot(SnapshotObservationPublicationRequest(
                screenshot: SnapshotScreenshotRequest(
                    snapshotId: snapshotID,
                    screenshotPath: replacementURL.path,
                    applicationBundleId: "test.replacement",
                    applicationProcessId: 456,
                    applicationName: "Replacement",
                    windowTitle: "Replacement",
                    windowBounds: CGRect(x: 0, y: 0, width: 4, height: 4)),
                detectionResult: nil,
                annotatedScreenshotPath: missingAnnotationURL.path))
        }

        let retained = try #require(try await manager.getUIAutomationSnapshot(snapshotId: snapshotID))
        #expect(retained.applicationBundleId == "test.original")
        #expect(retained.screenshotPath == storedOriginalPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: storedOriginalPath)) == originalData)
        try await manager.cleanSnapshot(snapshotId: snapshotID)
    }

    @Test
    @MainActor
    func `atomic observation snapshot preserves pending visibility until mutation publication`() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-pending-observation-\(UUID().uuidString).png")
        let imageData = try Self.capture(
            bounds: CGRect(x: 0, y: 0, width: 8, height: 8),
            scale: 1).imageData
        try imageData.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let manager = InMemorySnapshotManager(options: .init(copyArtifactsOnStore: true))
        let startedAt = Date()
        let snapshotID = try await manager.createSnapshot(pendingAt: startedAt)
        try await manager.storeObservationSnapshot(SnapshotObservationPublicationRequest(
            screenshot: SnapshotScreenshotRequest(
                snapshotId: snapshotID,
                screenshotPath: sourceURL.path,
                applicationBundleId: "test.pending",
                applicationProcessId: 123,
                applicationName: "Pending",
                windowTitle: "Pending",
                windowBounds: CGRect(x: 0, y: 0, width: 8, height: 8)),
            detectionResult: nil,
            annotatedScreenshotPath: nil))

        #expect(try await manager.listSnapshots().contains { $0.id == snapshotID } == false)
        _ = try await manager.invalidateImplicitLatestSnapshot(
            through: Date(),
            preserving: snapshotID,
            preservedAt: Date())
        #expect(try await manager.listSnapshots().contains { $0.id == snapshotID })
        try await manager.cleanSnapshot(snapshotId: snapshotID)
    }

    @MainActor
    private static func verifyFullRefreshClearsROI(
        manager: any SnapshotManagerProtocol,
        screenshotPath: String) async throws
    {
        let snapshotID = try await manager.createSnapshot()
        let fullCapture = try Self.capture(bounds: CGRect(x: 20, y: 30, width: 100, height: 80), scale: 1)
        let roiResult = try DesktopObservationROIProcessor.apply(
            CaptureRegionOfInterest(bounds: CGRect(x: 10, y: 10, width: 40, height: 20)),
            target: Self.target(bounds: CGRect(x: 20, y: 30, width: 100, height: 80)),
            capture: fullCapture,
            elements: ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: screenshotPath,
                elements: DetectedElements(),
                metadata: DetectionMetadata(detectionTime: 0, elementCount: 0, method: "roi")),
            ocr: nil)
        let roiDetection = try #require(roiResult.elements)
        try await manager.storeScreenshot(SnapshotScreenshotRequest(
            snapshotId: snapshotID,
            screenshotPath: screenshotPath,
            applicationBundleId: "test.roi",
            applicationProcessId: 123,
            applicationName: "ROI Fixture",
            windowTitle: "Fixture",
            windowBounds: fullCapture.metadata.windowInfo?.bounds,
            windowID: 42,
            windowMutationIdentity: fullCapture.metadata.windowInfo?.mutationIdentity,
            captureCoordinateContext: roiDetection.metadata.captureCoordinateContext))
        try await manager.storeDetectionResult(snapshotId: snapshotID, result: roiDetection)
        try await manager.storeAnnotatedScreenshot(
            snapshotId: snapshotID,
            annotatedScreenshotPath: screenshotPath)

        let fullContext = CaptureCoordinateContext(metadata: fullCapture.metadata, referenceID: snapshotID)
        try await manager.storeScreenshot(SnapshotScreenshotRequest(
            snapshotId: snapshotID,
            screenshotPath: screenshotPath,
            applicationBundleId: "test.roi",
            applicationProcessId: 123,
            applicationName: "ROI Fixture",
            windowTitle: "Fixture",
            windowBounds: fullCapture.metadata.windowInfo?.bounds,
            windowID: 42,
            windowMutationIdentity: fullCapture.metadata.windowInfo?.mutationIdentity,
            captureCoordinateContext: fullContext))
        try await manager.storeDetectionResult(
            snapshotId: snapshotID,
            result: ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: screenshotPath,
                elements: DetectedElements(),
                metadata: DetectionMetadata(detectionTime: 0, elementCount: 0, method: "full")))

        let restored = try #require(try await manager.getUIAutomationSnapshot(snapshotId: snapshotID))
        #expect(restored.captureCoordinateContext == fullContext)
        #expect(restored.captureCoordinateContext?.viewport == nil)
        #expect(restored.annotatedPath == nil)
        let restoredDetection = try #require(try await manager.getDetectionResult(snapshotId: snapshotID))
        #expect(restoredDetection.metadata.captureCoordinateContext == fullContext)
    }

    private static func target(bounds: CGRect) -> ResolvedObservationTarget {
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 456,
            capturedBounds: bounds)
        return ResolvedObservationTarget(
            kind: .windowID(42),
            app: ApplicationIdentity(
                processIdentifier: 123,
                processStartIdentity: 456,
                bundleIdentifier: "test.roi",
                name: "ROI Fixture"),
            window: WindowIdentity(windowID: 42, title: "Fixture", bounds: bounds, index: 0),
            bounds: bounds,
            detectionContext: WindowContext(
                applicationName: "ROI Fixture",
                applicationBundleId: "test.roi",
                applicationProcessId: 123,
                windowTitle: "Fixture",
                windowID: 42,
                windowBounds: bounds,
                windowMutationIdentity: identity))
    }

    private static func capture(bounds: CGRect, scale: CGFloat) throws -> CaptureResult {
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 456,
            capturedBounds: bounds)
        return CaptureResult(
            imageData: data as Data,
            metadata: CaptureMetadata(
                size: CGSize(width: width, height: height),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 123,
                    processStartIdentity: 456,
                    bundleIdentifier: "test.roi",
                    name: "ROI Fixture"),
                windowInfo: ServiceWindowInfo(
                    windowID: 42,
                    title: "Fixture",
                    bounds: bounds,
                    mutationIdentity: identity),
                diagnostics: CaptureDiagnostics(
                    requestedScale: scale == 1 ? .logical1x : .native,
                    nativeScale: scale,
                    outputScale: scale,
                    scaleSource: "test",
                    finalPixelSize: CGSize(width: width, height: height))))
    }

    private static func quadrantImageData(scale: Int) throws -> Data {
        let width = 4 * scale
        let height = 4 * scale
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colors: [TestRGB] = [
            TestRGB(red: 1, green: 0, blue: 0),
            TestRGB(red: 0, green: 1, blue: 0),
            TestRGB(red: 0, green: 0, blue: 1),
            TestRGB(red: 1, green: 1, blue: 0),
        ]
        for y in 0..<height {
            for x in 0..<width {
                let quadrant = (y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)
                let color = colors[quadrant]
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(color.red * 255)
                pixels[offset + 1] = UInt8(color.green * 255)
                pixels[offset + 2] = UInt8(color.blue * 255)
                pixels[offset + 3] = 255
            }
        }

        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            .union(.byteOrder32Big)
        let image = try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func averageRGB(in data: Data) throws -> TestRGB {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            .union(.byteOrder32Big)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue))
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }

        var red = 0
        var green = 0
        var blue = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            red += Int(pixels[offset])
            green += Int(pixels[offset + 1])
            blue += Int(pixels[offset + 2])
        }
        let denominator = CGFloat(image.width * image.height * 255)
        return TestRGB(
            red: CGFloat(red) / denominator,
            green: CGFloat(green) / denominator,
            blue: CGFloat(blue) / denominator)
    }
}

private struct TestRGB {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
}
