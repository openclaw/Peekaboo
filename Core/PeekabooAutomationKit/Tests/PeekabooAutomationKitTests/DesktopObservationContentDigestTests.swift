import Foundation
import Testing
@testable import PeekabooAutomationKit

struct DesktopObservationContentDigestTests {
    @Test
    func `legacy desktop observation files decode without publication receipt`() throws {
        let files = try JSONDecoder().decode(
            DesktopObservationFiles.self,
            from: Data(#"{"rawScreenshotPath":"/tmp/legacy.png","annotatedScreenshotPath":null}"#.utf8))

        #expect(files.rawScreenshotPath == "/tmp/legacy.png")
        #expect(files.publishedSnapshotID == nil)
    }

    @Test
    func `stripped result retains digest and rejects same-size file replacement`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-observation-digest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let imageURL = root.appendingPathComponent("capture.png")
        let original = Data("signed-pixels-1".utf8)
        let replacement = Data("forged-pixels-1".utf8)
        #expect(original.count == replacement.count)
        try original.write(to: imageURL, options: .atomic)

        let result = try DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: original,
                savedPath: imageURL.path,
                metadata: CaptureMetadata(size: .init(width: 1, height: 1), mode: .screen)),
            elements: nil,
            files: DesktopObservationFiles(rawScreenshotPath: imageURL.path))
            .attestingCaptureContent()
            .withoutImageData()

        #expect(result.capture.imageData.isEmpty)
        #expect(result.captureContentDigest?.captureImageSHA256 == DesktopObservationContentDigest.sha256(original))
        #expect(try result.verifiedRawScreenshotData(requirement: .requireDigest) == original)

        try replacement.write(to: imageURL, options: .atomic)
        #expect(throws: DesktopObservationContentVerificationError.digestMismatch) {
            try result.verifiedRawScreenshotData(requirement: .requireDigest)
        }
    }

    @Test
    func `required verification rejects a receiptless legacy result`() throws {
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-legacy-observation-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let pixels = Data("legacy-pixels".utf8)
        try pixels.write(to: imageURL, options: .atomic)
        let result = DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: pixels,
                savedPath: imageURL.path,
                metadata: CaptureMetadata(size: .init(width: 1, height: 1), mode: .screen)),
            elements: nil,
            files: DesktopObservationFiles(rawScreenshotPath: imageURL.path))

        #expect(try result.verifiedRawScreenshotData() == pixels)
        #expect(throws: DesktopObservationContentVerificationError.missingDigest) {
            try result.verifiedRawScreenshotData(requirement: .requireDigest)
        }
    }

    @Test
    func `required verification rejects missing digest before reading artifact path`() {
        let missingPath = "/tmp/peekaboo-missing-digest-\(UUID().uuidString)"
        let result = DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: Data("pixels".utf8),
                metadata: CaptureMetadata(size: .init(width: 1, height: 1), mode: .screen)),
            elements: nil,
            files: DesktopObservationFiles(rawScreenshotPath: missingPath))

        #expect(throws: DesktopObservationContentVerificationError.missingDigest) {
            try result.verifiedRawScreenshotData(requirement: .requireDigest)
        }
    }

    @Test
    func `required verification rejects missing artifact digest before reading path`() {
        let pixels = Data("pixels".utf8)
        let missingPath = "/tmp/peekaboo-missing-artifact-digest-\(UUID().uuidString)"
        let result = DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: pixels,
                metadata: CaptureMetadata(size: .init(width: 1, height: 1), mode: .screen)),
            elements: nil,
            files: DesktopObservationFiles(rawScreenshotPath: missingPath),
            captureContentDigest: DesktopObservationContentDigest(
                captureImageData: pixels,
                rawScreenshotData: nil,
                annotatedScreenshotData: nil))

        #expect(throws: DesktopObservationContentVerificationError.missingArtifactDigest("raw screenshot")) {
            try result.verifiedRawScreenshotData(requirement: .requireDigest)
        }
    }
}
