import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PeekabooFoundation
import Testing
import UniformTypeIdentifiers
@testable import PeekabooAutomationKit

struct WatchCapturePNGTests {
    @Test(arguments: [CGFloat?.none, 50, 100])
    @MainActor
    func `Untransformed live sessions preserve PNG bytes and enforce actual byte cap`(cap: CGFloat?) async throws {
        let size = CGSize(width: 50, height: 50)
        let png = try CapturePNGTestFixtures.pngData(
            image: CapturePNGTestFixtures.makeImage(width: 50, height: 50),
            marker: String(repeating: "capture-byte-custody-", count: 60000))
        #expect(png.count > 1024 * 1024)
        let options = CaptureOptions(
            duration: 2,
            idleFps: 5,
            activeFps: 5,
            changeThresholdPercent: 0,
            heartbeatSeconds: 0,
            quietMsToIdle: 0,
            maxFrames: 100,
            maxMegabytes: 1,
            highlightChanges: false,
            captureFocus: .background,
            resolutionCap: cap,
            diffStrategy: .fast,
            diffBudgetMs: nil)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-source-png-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let session = WatchCaptureSession(
            dependencies: WatchCaptureDependencies(
                screenCapture: RecordingScreenCaptureService(result: CaptureResult(
                    imageData: png, metadata: CaptureMetadata(size: size, mode: .screen)))),
            configuration: WatchCaptureConfiguration(
                scope: CaptureScope(kind: .screen),
                options: options,
                outputRoot: output,
                autoclean: WatchAutocleanConfig(minutes: 1, managed: false)))

        let result = try await session.run()

        #expect(result.frames.count == 1)
        #expect(result.warnings.contains { $0.code == .sizeCap })
        #expect(session.totalBytes == png.count)
        let frame = try #require(result.frames.first)
        #expect(try Data(contentsOf: URL(fileURLWithPath: frame.path)) == png)
        try CaptureArtifactIntegrityValidator.validate(result)
    }

    @Test(arguments: [false, true])
    func `unchanged PNG saves retain exact bytes and custody`(emptyHighlight: Bool) throws {
        let data = try Self.markedPNG()
        let frame = Self.frame(data)
        let image = try #require(frame.cgImage)
        #expect(frame.sourcePNG(for: image) == data)
        let output = try self.save(frame, image: image, highlight: emptyHighlight ? [] : nil)
        #expect(output.data == data)
        #expect(output.sha256 == Self.sha256(data))
    }

    @Test(arguments: [false, true])
    func `transformed images do not inherit original bytes even at equal dimensions`(sameSize: Bool) throws {
        let data = try Self.markedPNG()
        let frame = Self.frame(data) { image in
            WatchCaptureArtifactWriter.resize(
                image: image,
                to: sameSize ? CGSize(width: 64, height: 48) : CGSize(width: 32, height: 24))!
        }
        let image = try #require(frame.cgImage)
        #expect(frame.sourcePNG(for: image) == nil)
        let output = try self.save(frame, image: image)
        #expect(output.data != data)
        #expect(output.data.range(of: Data(Self.marker.utf8)) == nil)
        let decoded = try CapturePNGTestFixtures.decodedImage(output.data)
        #expect(decoded.width == (sameSize ? 64 : 32))
        #expect(decoded.height == (sameSize ? 48 : 24))
    }

    @Test
    func `save-time replacement and highlights bypass original PNG bytes`() throws {
        let data = try Self.markedPNG()
        let frame = Self.frame(data)
        let image = try #require(frame.cgImage)
        let replacement = try CapturePNGTestFixtures.makeImage(width: 64, height: 48)
        #expect(frame.sourcePNG(for: replacement) == nil)
        let replaced = try self.save(frame, image: replacement)
        #expect(replaced.data != data)
        #expect(replaced.data.range(of: Data(Self.marker.utf8)) == nil)

        let boxes = [CGRect(x: 4, y: 4, width: 20, height: 16)]
        let highlighted = try self.save(frame, image: image, highlight: boxes)
        let imageOnly = WatchCaptureFrame(cgImage: image, metadata: frame.metadata, motionBoxes: nil)
        let disabled = WatchCaptureFrame(
            imageData: data, metadata: frame.metadata, preservePNG: false, transform: { $0 })
        #expect(try disabled.sourcePNG(for: #require(disabled.cgImage)) == nil)
        let expected = try self.save(imageOnly, image: image, highlight: boxes)
        #expect(highlighted.data == expected.data)
        #expect(highlighted.data != data)
        #expect(imageOnly.sourcePNG(for: image) == nil)
    }

    @Test
    func `non-PNG and animated PNG sources keep first-image encoding`() throws {
        let image = try CapturePNGTestFixtures.makeImage(width: 64, height: 48)
        let inputs = try [
            CapturePNGTestFixtures.encodedData(images: [image], type: .jpeg),
            CapturePNGTestFixtures.encodedData(images: [image, image], type: .png),
        ]
        let animated = try #require(CGImageSourceCreateWithData(inputs[1] as CFData, nil))
        #expect(CGImageSourceGetCount(animated) == 2)
        for input in inputs {
            let frame = Self.frame(input)
            let decoded = try #require(frame.cgImage)
            #expect(frame.sourcePNG(for: decoded) == nil)
            let output = try self.save(frame, image: decoded)
            let saved = try #require(CGImageSourceCreateWithData(output.data as CFData, nil))
            #expect(CGImageSourceGetCount(saved) == 1)
            #expect(CGImageSourceGetType(saved) as String? == UTType.png.identifier)
        }
    }

    @Test
    func `incomplete corrupt and invalid pixel PNGs are never retained verbatim`() throws {
        let data = try Self.markedPNG()
        let chunks = CapturePNGTestFixtures.chunks(ofType: CapturePNGTestFixtures.idat, in: data)
        let first = try #require(chunks.first)
        let end = try #require(CapturePNGTestFixtures.chunks(ofType: CapturePNGTestFixtures.iend, in: data).first)
        var badCRC = data
        badCRC[first.crcOffset] ^= 1
        let damaged = Self.frame(badCRC)
        let reencoded = try self.save(damaged, image: #require(damaged.cgImage))
        #expect(reencoded.data != badCRC)
        #expect(LegacyPNGValidator.hasValidStructureAndCRC(reencoded.data))
        var badPixels = data
        for chunk in chunks {
            for index in chunk.dataRange {
                badPixels[index] = 0
            }
            CapturePNGTestFixtures.rewriteCRC(for: chunk, in: &badPixels)
        }
        #expect(LegacyPNGValidator.hasValidStructureAndCRC(badPixels))
        for invalid in [badCRC, badPixels, Data(data[..<end.offset]), data + Data([0])] {
            let frame = Self.frame(invalid)
            if let image = frame.cgImage {
                #expect(frame.sourcePNG(for: image) == nil)
            }
        }
    }

    private static let marker = "peekaboo-watch-preserved-PNG"

    private static func markedPNG() throws -> Data {
        try CapturePNGTestFixtures.pngData(
            image: CapturePNGTestFixtures.makeImage(width: 64, height: 48),
            marker: self.marker)
    }

    private static func frame(_ data: Data, transform: (CGImage) -> CGImage = { $0 }) -> WatchCaptureFrame {
        WatchCaptureFrame(
            imageData: data,
            metadata: CaptureMetadata(size: CGSize(width: 64, height: 48), mode: .screen),
            transform: transform)
    }

    private func save(
        _ frame: WatchCaptureFrame,
        image: CGImage,
        highlight: [CGRect]? = nil) throws -> (data: Data, sha256: String)
    {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("watch-png-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: path) }
        let digest = try WatchCaptureArtifactWriter.writePNG(
            image: image, to: path, highlight: highlight, sourceFrame: frame)
        let data = try Data(contentsOf: path)
        #expect(digest == Self.sha256(data))
        return (data, digest)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
