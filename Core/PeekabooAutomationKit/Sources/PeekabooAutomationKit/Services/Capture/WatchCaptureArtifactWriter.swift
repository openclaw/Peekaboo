import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PeekabooFoundation
import UniformTypeIdentifiers

enum WatchCaptureArtifactWriter {
    static func buildContactSheet(
        frames: [CaptureFrameInfo],
        outputRoot: URL,
        columns: Int,
        thumbSize: CGSize) throws -> WatchContactSheet
    {
        guard !frames.isEmpty else {
            throw PeekabooError.captureFailed(reason: "Cannot build a contact sheet without valid frames")
        }
        let maxCells = columns * columns
        let framesToUse: [CaptureFrameInfo]
        let sampledIndexes: [Int]
        if frames.count <= maxCells {
            framesToUse = frames
            sampledIndexes = frames.map(\.index)
        } else {
            // Sample evenly to keep contact sheets readable when many frames are kept.
            framesToUse = self.sampleFrames(frames, maxCount: maxCells)
            sampledIndexes = framesToUse.map(\.index)
        }

        let rows = Int(ceil(Double(framesToUse.count) / Double(columns)))
        let sheetSize = CGSize(width: CGFloat(columns) * thumbSize.width, height: CGFloat(rows) * thumbSize.height)
        guard let context = CGContext(
            data: nil,
            width: Int(sheetSize.width),
            height: Int(sheetSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw PeekabooError.captureFailed(reason: "Failed to build contact sheet context")
        }

        for (idx, frame) in framesToUse.enumerated() {
            guard let expectedSHA256 = frame.sha256 else {
                throw PeekabooError.fileIOError("Contact sheet source frame lacks digest custody: \(frame.file)")
            }
            let retained: CaptureArtifactIntegrityValidator.RetainedFile
            do {
                retained = try CaptureArtifactIntegrityValidator.retainedRegularFile(
                    path: frame.path,
                    maximumBytes: CaptureArtifactIntegrityValidator.maximumPNGBytes)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PeekabooError.fileIOError("Contact sheet source frame is unreadable: \(frame.file)")
            }
            guard retained.sha256 == expectedSHA256,
                  let image = self.makeCGImage(from: retained.data)
            else {
                throw PeekabooError.fileIOError("Contact sheet source frame is unreadable: \(frame.file)")
            }
            let resized = self.resize(image: image, to: thumbSize) ?? image
            let row = idx / columns
            let col = idx % columns
            let origin = CGPoint(
                x: CGFloat(col) * thumbSize.width,
                y: CGFloat(rows - row - 1) * thumbSize.height)
            context.draw(resized, in: CGRect(origin: origin, size: thumbSize))
        }

        guard let cg = context.makeImage() else {
            throw PeekabooError.captureFailed(reason: "Failed to finalize contact sheet")
        }

        let contactURL = outputRoot.appendingPathComponent("contact.png")
        let sha256 = try self.writePNG(image: cg, to: contactURL, highlight: nil)

        return CaptureContactSheet(
            path: contactURL.path,
            file: "contact.png",
            columns: columns,
            rows: rows,
            thumbSize: thumbSize,
            sampledFrameIndexes: sampledIndexes,
            sha256: sha256)
    }

    static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func resize(image: CGImage, to size: CGSize) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }

        // Decode through a known RGBA surface; some live ScreenCaptureKit frames arrive
        // without color-space metadata, and replaying their bitmap flags can fail silently.
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    @discardableResult
    static func writePNG(image: CGImage, to url: URL, highlight: [CGRect]?) throws -> String {
        let finalImage: CGImage = if let highlight, !highlight.isEmpty,
                                     let annotated = self.annotate(image: image, boxes: highlight)
        {
            annotated
        } else {
            image
        }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            UTType.png.identifier as CFString,
            1,
            nil)
        else {
            throw PeekabooError.fileIOError("Failed to create PNG encoder for: \(url.path)")
        }
        CGImageDestinationAddImage(destination, finalImage, nil)
        if !CGImageDestinationFinalize(destination) {
            throw PeekabooError.fileIOError("Failed to encode PNG for: \(url.path)")
        }
        let data = encoded as Data
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw PeekabooError.fileIOError("Failed to write PNG to \(url.path): \(error.localizedDescription)")
        }
        return self.sha256(data)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sampleFrames(_ frames: [CaptureFrameInfo], maxCount: Int) -> [CaptureFrameInfo] {
        guard frames.count > maxCount else { return frames }
        let step = Double(frames.count - 1) / Double(maxCount - 1)
        var indexes: [Int] = []
        for i in 0..<maxCount {
            let idx = Int(round(Double(i) * step))
            indexes.append(min(idx, frames.count - 1))
        }
        let set = Set(indexes)
        return frames.enumerated()
            .filter { set.contains($0.offset) }
            .map(\.element)
    }

    private static func annotate(image: CGImage, boxes: [CGRect]) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: image.bitmapInfo.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(max(2, CGFloat(image.width) * 0.002))
        for box in boxes {
            context.stroke(box)
        }
        return context.makeImage()
    }
}
