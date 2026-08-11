import AppKit
import ImageIO
import PeekabooFoundation
import XCTest
@testable import PeekabooAutomationKit

@MainActor
final class ObservationAnnotationRendererTests: XCTestCase {
    func testDirectPNGMatchesLegacyRoundTripByteForByte() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.png")
        let annotatedURL = directory.appendingPathComponent("annotated.png")
        let sourceData = try Self.pngData(from: Self.image(pixelSize: CGSize(width: 320, height: 180)))
        try sourceData.write(to: sourceURL)
        let sourceImage = try XCTUnwrap(NSImage(contentsOf: sourceURL))
        let detection = Self.detection(imageSize: sourceImage.size)
        let renderer = ObservationAnnotationRenderer()

        let renderedImage = try XCTUnwrap(renderer.renderAnnotatedImage(
            from: sourceImage,
            detectionResult: detection))
        let bitmap = try XCTUnwrap(renderedImage.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        let directData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let legacyData = try Self.legacyRoundTripPNGData(from: bitmap)

        XCTAssertEqual(directData, legacyData)
        let outputPath = try XCTUnwrap(renderer.renderAnnotatedScreenshot(
            originalPath: sourceURL.path,
            detectionResult: detection,
            annotatedPath: annotatedURL.path))
        XCTAssertEqual(outputPath, annotatedURL.path)
        XCTAssertEqual(try Data(contentsOf: annotatedURL), directData)
    }

    func testRenderedImagePreservesCurrentDimensionsScaleAndPNGMetadata() throws {
        let logicalSize = CGSize(width: 160, height: 90)
        let sourceImage = try Self.image(
            pixelSize: CGSize(width: 320, height: 180),
            logicalSize: logicalSize)
        let renderer = ObservationAnnotationRenderer()
        let renderedImage = try XCTUnwrap(renderer.renderAnnotatedImage(
            from: sourceImage,
            detectionResult: Self.detection(imageSize: logicalSize)))
        let bitmap = try XCTUnwrap(renderedImage.representations.compactMap { $0 as? NSBitmapImageRep }.first)

        XCTAssertEqual(renderedImage.size, logicalSize)
        XCTAssertEqual(bitmap.size, logicalSize)
        XCTAssertEqual(bitmap.pixelsWide, Int(logicalSize.width))
        XCTAssertEqual(bitmap.pixelsHigh, Int(logicalSize.height))
        XCTAssertEqual(bitmap.bitsPerSample, 8)
        XCTAssertEqual(bitmap.samplesPerPixel, 4)
        XCTAssertTrue(bitmap.hasAlpha)
        XCTAssertEqual(bitmap.colorSpaceName, .calibratedRGB)

        let directData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let legacyData = try Self.legacyRoundTripPNGData(from: bitmap)
        let directProperties = try Self.imageProperties(directData)
        let legacyProperties = try Self.imageProperties(legacyData)
        let metadataKeys: [CFString] = [
            kCGImagePropertyPixelWidth,
            kCGImagePropertyPixelHeight,
            kCGImagePropertyDPIWidth,
            kCGImagePropertyDPIHeight,
            kCGImagePropertyDepth,
            kCGImagePropertyColorModel,
            kCGImagePropertyHasAlpha,
            kCGImagePropertyProfileName,
        ]
        for key in metadataKeys {
            XCTAssertEqual(
                String(describing: directProperties[key]),
                String(describing: legacyProperties[key]),
                "Metadata changed for \(key)")
        }
        XCTAssertEqual(directProperties[kCGImagePropertyPixelWidth] as? Int, Int(logicalSize.width))
        XCTAssertEqual(directProperties[kCGImagePropertyPixelHeight] as? Int, Int(logicalSize.height))
    }

    func testNoEnabledElementsStillProducesNoImageOrArtifact() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.png")
        let annotatedURL = directory.appendingPathComponent("annotated.png")
        let sourceImage = try Self.image(pixelSize: CGSize(width: 80, height: 60))
        try Self.pngData(from: sourceImage).write(to: sourceURL)
        let disabled = DetectedElement(
            id: "B1",
            type: .button,
            bounds: CGRect(x: 10, y: 10, width: 20, height: 20),
            isEnabled: false)
        let detection = Self.detection(imageSize: sourceImage.size, elements: [disabled])
        let renderer = ObservationAnnotationRenderer()

        XCTAssertNil(try renderer.renderAnnotatedImage(from: sourceImage, detectionResult: detection))
        XCTAssertNil(try renderer.renderAnnotatedScreenshot(
            originalPath: sourceURL.path,
            detectionResult: detection,
            annotatedPath: annotatedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: annotatedURL.path))
    }

    func testMissingSourceKeepsCaptureFailureMessage() throws {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-missing-annotation-\(UUID().uuidString).png")
            .path
        let renderer = ObservationAnnotationRenderer()

        XCTAssertThrowsError(try renderer.renderAnnotatedScreenshot(
            originalPath: missingPath,
            detectionResult: Self.detection(imageSize: CGSize(width: 80, height: 60))))
        { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Capture failed: Failed to load screenshot for annotation: \(missingPath)")
        }
    }

    func testDirectAnnotationEncodingBenchmark1080p() throws {
        let imageSize = CGSize(width: 1920, height: 1080)
        let sourceImage = try Self.image(pixelSize: imageSize)
        let detection = Self.detection(
            imageSize: imageSize,
            elements: Self.benchmarkElements(imageSize: imageSize))
        let renderer = ObservationAnnotationRenderer()
        let renderedImage = try XCTUnwrap(renderer.renderAnnotatedImage(
            from: sourceImage,
            detectionResult: detection))
        let bitmap = try XCTUnwrap(
            renderedImage.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        var encodedByteCount = 0

        self.measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            autoreleasepool {
                encodedByteCount = bitmap.representation(using: .png, properties: [:])?.count ?? 0
            }
        }

        XCTAssertGreaterThan(encodedByteCount, 0)
    }
}

@MainActor
extension ObservationAnnotationRendererTests {
    fileprivate static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-annotation-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    fileprivate static func image(pixelSize: CGSize, logicalSize: CGSize? = nil) throws -> NSImage {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0),
            let bytes = bitmap.bitmapData
        else {
            throw TestError.imageCreationFailed
        }

        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = UInt8(truncatingIfNeeded: x &* 13 &+ y &* 7)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: x &* 3 &+ y &* 17)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: x &* 19 &+ y &* 5)
                bytes[offset + 3] = 255
            }
        }

        let imageSize = logicalSize ?? pixelSize
        bitmap.size = imageSize
        let image = NSImage(size: imageSize)
        image.addRepresentation(bitmap)
        return image
    }

    fileprivate static func pngData(from image: NSImage) throws -> Data {
        guard let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              let data = bitmap.representation(using: .png, properties: [:])
        else {
            throw TestError.imageEncodingFailed
        }
        return data
    }

    fileprivate static func legacyRoundTripPNGData(from bitmap: NSBitmapImageRep) throws -> Data {
        guard let firstPNG = bitmap.representation(using: .png, properties: [:]),
              let image = NSImage(data: firstPNG),
              let tiff = image.tiffRepresentation,
              let decodedBitmap = NSBitmapImageRep(data: tiff),
              let finalPNG = decodedBitmap.representation(using: .png, properties: [:])
        else {
            throw TestError.imageEncodingFailed
        }
        return finalPNG
    }

    fileprivate static func imageProperties(_ data: Data) throws -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            throw TestError.imageDecodingFailed
        }
        return properties
    }

    fileprivate static func detection(
        imageSize: CGSize,
        elements: [DetectedElement]? = nil) -> ElementDetectionResult
    {
        let resolvedElements = elements ?? [
            DetectedElement(
                id: "B1",
                type: .button,
                label: "Continue",
                bounds: CGRect(x: 20, y: 24, width: 72, height: 28)),
            DetectedElement(
                id: "T1",
                type: .textField,
                label: "Name",
                bounds: CGRect(x: 112, y: 70, width: 124, height: 30)),
        ]
        return ElementDetectionResult(
            snapshotId: "annotation-test",
            screenshotPath: "",
            elements: DetectedElements(other: resolvedElements),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: resolvedElements.count,
                method: "fixture",
                windowContext: WindowContext(
                    windowBounds: CGRect(origin: .zero, size: imageSize)),
                truncationInfo: nil))
    }

    fileprivate static func benchmarkElements(imageSize: CGSize) -> [DetectedElement] {
        (0..<24).map { index in
            let column = index % 6
            let row = index / 6
            return DetectedElement(
                id: "B\(index + 1)",
                type: index.isMultiple(of: 2) ? .button : .textField,
                label: "Fixture \(index + 1)",
                bounds: CGRect(
                    x: 80 + CGFloat(column) * 290,
                    y: 100 + CGFloat(row) * 220,
                    width: min(180, imageSize.width - 80),
                    height: 52))
        }
    }

    fileprivate enum TestError: Error {
        case imageCreationFailed
        case imageEncodingFailed
        case imageDecodingFailed
    }
}
