import AppKit
import Foundation
import ImageIO
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct CaptureArtifactImageProcessingTests {
    @Test
    func `contact sheet preserves thumbnail pixels and ordering`() throws {
        let directory = try self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = try self.fixtures()
        let frames = try fixtures.enumerated().map { index, fixture in
            let url = directory.appendingPathComponent("frame-\(index).png")
            let digest = try WatchCaptureArtifactWriter.writePNG(image: fixture, to: url, highlight: nil)
            return CaptureFrameInfo(
                index: index * 3,
                path: url.path,
                file: url.lastPathComponent,
                timestampMs: index * 100,
                changePercent: 0,
                reason: .first,
                sha256: digest)
        }
        let thumbnailSize = CGSize(width: 200, height: 200)
        let sheet = try WatchCaptureArtifactWriter.buildContactSheet(
            frames: frames,
            outputRoot: directory,
            columns: 4,
            thumbSize: thumbnailSize)
        let actual = try self.decode(Data(contentsOf: URL(fileURLWithPath: sheet.path)))
        let expected = try self.legacyContactSheet(frames: frames, thumbSize: thumbnailSize)

        #expect(sheet.sampledFrameIndexes == frames.map(\.index))
        #expect(sheet.columns == 4)
        #expect(sheet.rows == 2)
        #expect(actual.width == 800)
        #expect(actual.height == 400)
        #expect(try self.pixels(actual) == self.pixels(expected))
        let retained = try CaptureArtifactIntegrityValidator.retainedRegularFile(
            path: sheet.path,
            maximumBytes: CaptureArtifactIntegrityValidator.maximumPNGBytes)
        #expect(sheet.sha256 == retained.sha256)
    }

    @Test
    func `contact sheet refuses a replaced frame before publishing`() throws {
        let directory = try self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try #require(self.fixtures().first)
        let url = directory.appendingPathComponent("frame.png")
        let digest = try WatchCaptureArtifactWriter.writePNG(image: image, to: url, highlight: nil)
        try Data("replacement".utf8).write(to: url, options: .atomic)
        let frame = CaptureFrameInfo(
            index: 0,
            path: url.path,
            file: url.lastPathComponent,
            timestampMs: 0,
            changePercent: 0,
            reason: .first,
            sha256: digest)

        #expect(throws: PeekabooError.self) {
            try WatchCaptureArtifactWriter.buildContactSheet(
                frames: [frame],
                outputRoot: directory,
                columns: 1,
                thumbSize: CGSize(width: 200, height: 200))
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("contact.png").path))
    }

    @Test
    func `JPEG output preserves pixels dimensions and compression across color spaces and alpha`() async throws {
        let directory = try self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, image) in try self.fixtures().enumerated() {
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            let legacyImage = try #require(NSImage(data: png))
            let tiff = try #require(legacyImage.tiffRepresentation)
            let legacyBitmap = try #require(NSBitmapImageRep(data: tiff))
            let expected = try #require(legacyBitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.92]))
            let url = directory.appendingPathComponent("output-\(index).jpg")

            let result = try await ObservationOutputWriter().write(
                capture: CaptureResult(
                    imageData: png,
                    metadata: CaptureMetadata(size: CGSize(width: image.width, height: image.height), mode: .screen)),
                elements: nil,
                options: DesktopObservationOutputOptions(path: url.path, format: .jpg, saveRawScreenshot: true))

            let encoded = try Data(contentsOf: url)
            let actual = try self.decode(encoded)
            let source = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
            #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
            #expect(result.files.rawScreenshotPath == url.path)
            #expect(actual.width == image.width)
            #expect(actual.height == image.height)
            #expect(try self.pixels(actual) == self.pixels(self.decode(expected)))
        }
    }

    @Test
    func `invalid JPEG input preserves existing output`() async throws {
        let directory = try self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("output.jpg")
        let existing = Data("existing output".utf8)
        try existing.write(to: url)

        await #expect(throws: OperationError.self) {
            try await ObservationOutputWriter().write(
                capture: CaptureResult(
                    imageData: Data("invalid input".utf8),
                    metadata: CaptureMetadata(size: CGSize(width: 1, height: 1), mode: .screen)),
                elements: nil,
                options: DesktopObservationOutputOptions(path: url.path, format: .jpg, saveRawScreenshot: true))
        }
        #expect(try Data(contentsOf: url) == existing)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-artifact-images-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fixtures() throws -> [CGImage] {
        let spaces = try [
            CGColorSpaceCreateDeviceRGB(),
            #require(CGColorSpace(name: CGColorSpace.sRGB)),
            #require(CGColorSpace(name: CGColorSpace.displayP3)),
        ]
        return try spaces.flatMap { space in
            try [false, true].map { alpha in
                let context = try self.context(width: 401, height: 289, colorSpace: space)
                for row in 0..<11 {
                    for column in 0..<13 {
                        context.setFillColor(
                            red: CGFloat(column % 7) / 6,
                            green: CGFloat(row % 9) / 8,
                            blue: CGFloat((column + row) % 11) / 10,
                            alpha: alpha ? CGFloat((column + row) % 6 + 1) / 6 : 1)
                        context.fill(CGRect(x: column * 31, y: row * 27, width: 31, height: 27))
                    }
                }
                return try #require(context.makeImage())
            }
        }
    }

    private func legacyContactSheet(frames: [CaptureFrameInfo], thumbSize: CGSize) throws -> CGImage {
        let context = try self.context(width: 800, height: 400)
        for (index, frame) in frames.enumerated() {
            let image = try self.decode(Data(contentsOf: URL(fileURLWithPath: frame.path)))
            let thumbnail = try #require(WatchCaptureArtifactWriter.resize(image: image, to: thumbSize))
            context.draw(thumbnail, in: CGRect(x: index % 4 * 200, y: (1 - index / 4) * 200, width: 200, height: 200))
        }
        return try #require(context.makeImage())
    }

    private func context(
        width: Int,
        height: Int,
        colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()) throws -> CGContext
    {
        try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func decode(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try self.context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try Data(bytes: #require(context.data), count: context.bytesPerRow * context.height)
    }
}
