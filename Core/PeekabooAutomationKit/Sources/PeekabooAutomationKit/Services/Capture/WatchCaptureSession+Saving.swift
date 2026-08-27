import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
extension WatchCaptureSession {
    struct FrameSaveContext {
        let capture: WatchCaptureFrame
        let index: Int
        let timestampMs: Int
        let changePercent: Double
        let reason: CaptureFrameInfo.Reason
        let motionBoxes: [CGRect]?
    }

    /// Returns a bounded video size that preserves aspect ratio while keeping the longest edge under `maxDimension`.
    /// If `maxDimension` is nil or smaller than the current image, the original size is returned.
    public static func scaledVideoSize(for size: CGSize, maxDimension: Int?) -> (width: Int, height: Int) {
        guard let maxDimension, maxDimension > 0 else {
            return (Int(size.width), Int(size.height))
        }
        let currentMax = Int(max(size.width, size.height))
        guard currentMax > maxDimension else {
            return (Int(size.width), Int(size.height))
        }
        let scale = Double(maxDimension) / Double(currentMax)
        let scaledWidth = max(1, Int((Double(size.width) * scale).rounded()))
        let scaledHeight = max(1, Int((Double(size.height) * scale).rounded()))
        return (scaledWidth, scaledHeight)
    }

    func saveFrame(cgImage: CGImage, context: FrameSaveContext) async throws -> CaptureFrameInfo {
        try self.prepareVideoWriterIfNeeded(for: cgImage)
        if let writer = self.videoWriter {
            try await writer.append(image: cgImage)
        }

        let fileName = String(format: "keep-%04d.png", self.frames.count + 1)
        let url = self.outputRoot.appendingPathComponent(fileName)
        let sha256 = try WatchCaptureArtifactWriter.writePNG(
            image: cgImage,
            to: url,
            highlight: self.options.highlightChanges ? context.motionBoxes : nil)

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw PeekabooError.fileIOError("Missing file size after writing \(fileName)")
            }
            self.totalBytes += size.intValue
        } catch let error as PeekabooError {
            throw error
        } catch {
            throw PeekabooError
                .fileIOError("Failed to inspect written frame \(fileName): \(error.localizedDescription)")
        }

        return CaptureFrameInfo(
            index: context.index,
            path: url.path,
            file: fileName,
            timestampMs: context.timestampMs,
            changePercent: context.changePercent,
            reason: context.reason,
            motionBoxes: context.motionBoxes?.isEmpty == false ? context.motionBoxes : nil,
            sha256: sha256,
            captureEngine: context.capture.metadata.diagnostics?.engine)
    }

    func prepareVideoWriterIfNeeded(for cgImage: CGImage) throws {
        guard self.videoOut != nil, self.videoWriter == nil else { return }

        // Create writer lazily on first kept frame so MP4 dimensions match real capture dimensions.
        let fps = self.videoWriterFPS ?? self.options.activeFps
        let size = Self.scaledVideoSize(
            for: CGSize(width: cgImage.width, height: cgImage.height),
            maxDimension: self.options.resolutionCap.map { Int($0) })
        self.videoWriter = try VideoWriter(
            outputPath: self.videoOut ?? self.outputRoot.appendingPathComponent("capture.mp4").path,
            width: size.width,
            height: size.height,
            fps: fps)
    }

    func elapsedMilliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
