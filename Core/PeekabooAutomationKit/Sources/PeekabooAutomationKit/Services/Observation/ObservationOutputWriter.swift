import AppKit
import Foundation
import PeekabooFoundation

@MainActor
public final class ObservationOutputWriter {
    private let snapshotManager: (any SnapshotManagerProtocol)?
    private let annotationRenderer: ObservationAnnotationRenderer

    public init(
        snapshotManager: (any SnapshotManagerProtocol)? = nil,
        annotationRenderer: ObservationAnnotationRenderer = ObservationAnnotationRenderer())
    {
        self.snapshotManager = snapshotManager
        self.annotationRenderer = annotationRenderer
    }

    public func write(
        capture: CaptureResult,
        elements: ElementDetectionResult?,
        options: DesktopObservationOutputOptions) async throws -> DesktopObservationOutputWriteResult
    {
        var spans: [ObservationSpan] = []
        let rawPath = try self.record("output.raw.write", into: &spans) {
            try self.writeRawScreenshotIfNeeded(capture: capture, options: options)
        }
        let effectiveRawPath = rawPath ?? capture.savedPath
        let annotatedPath: String? = if options.saveAnnotatedScreenshot {
            try self.record("annotation.render", into: &spans) {
                try self.writeAnnotatedScreenshotIfNeeded(
                    rawPath: effectiveRawPath,
                    elements: elements,
                    options: options)
            }
        } else {
            nil
        }
        let publishedSnapshotID: String? = if options.saveSnapshot {
            try await self.record("snapshot.write", into: &spans) {
                try await self.writeSnapshotIfNeeded(
                    rawPath: effectiveRawPath,
                    annotatedPath: annotatedPath,
                    capture: capture,
                    elements: elements,
                    options: options)
            }
        } else {
            nil
        }
        return DesktopObservationOutputWriteResult(
            files: DesktopObservationFiles(
                rawScreenshotPath: effectiveRawPath,
                annotatedScreenshotPath: annotatedPath,
                publishedSnapshotID: publishedSnapshotID),
            spans: spans)
    }

    public nonisolated static func annotatedScreenshotPath(forRawScreenshotPath rawPath: String) -> String {
        (rawPath as NSString).deletingPathExtension + "_annotated.png"
    }

    private func writeRawScreenshotIfNeeded(
        capture: CaptureResult,
        options: DesktopObservationOutputOptions) throws -> String?
    {
        guard options.saveRawScreenshot || options.saveAnnotatedScreenshot || options.saveSnapshot else {
            return nil
        }

        let url = self.outputURL(path: options.path, format: options.format)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try self.encodedImageData(capture.imageData, format: options.format).write(to: url, options: .atomic)
        return url.path
    }

    private func writeSnapshotIfNeeded(
        rawPath: String?,
        annotatedPath: String?,
        capture: CaptureResult,
        elements: ElementDetectionResult?,
        options: DesktopObservationOutputOptions) async throws -> String?
    {
        guard options.saveSnapshot, let snapshotManager = self.snapshotManager, let rawPath else {
            return nil
        }

        let snapshotID = options.snapshotID ?? elements?.snapshotId
        guard let snapshotID else {
            return nil
        }

        let windowContext = elements?.metadata.windowContext
        try await snapshotManager.storeScreenshot(SnapshotScreenshotRequest(
            snapshotId: snapshotID,
            screenshotPath: rawPath,
            applicationBundleId: windowContext?.applicationBundleId ?? capture.metadata.applicationInfo?
                .bundleIdentifier,
            applicationProcessId: windowContext?.applicationProcessId ?? capture.metadata.applicationInfo?
                .processIdentifier,
            applicationName: windowContext?.applicationName ?? capture.metadata.applicationInfo?.name,
            windowTitle: windowContext?.windowTitle ?? capture.metadata.windowInfo?.title,
            windowBounds: windowContext?.windowBounds ?? capture.metadata.windowInfo?.bounds,
            windowID: windowContext?.windowID ?? capture.metadata.windowInfo?.windowID,
            windowMutationIdentity: windowContext?.windowMutationIdentity ?? capture.metadata.windowInfo?
                .mutationIdentity,
            captureCoordinateContext: CaptureCoordinateContext(
                metadata: capture.metadata,
                referenceID: snapshotID)))

        if let elements {
            try await snapshotManager.storeDetectionResult(
                snapshotId: snapshotID,
                result: ElementDetectionResult(
                    snapshotId: snapshotID,
                    screenshotPath: rawPath,
                    elements: elements.elements,
                    metadata: elements.metadata))
        }

        if let annotatedPath {
            try await snapshotManager.storeAnnotatedScreenshot(
                snapshotId: snapshotID,
                annotatedScreenshotPath: annotatedPath)
        }
        return snapshotID
    }

    private func writeAnnotatedScreenshotIfNeeded(
        rawPath: String?,
        elements: ElementDetectionResult?,
        options: DesktopObservationOutputOptions) throws -> String?
    {
        guard options.saveAnnotatedScreenshot else {
            return nil
        }
        guard let rawPath, let elements else {
            return nil
        }

        return try self.annotationRenderer.renderAnnotatedScreenshot(
            originalPath: rawPath,
            detectionResult: elements,
            annotatedPath: Self.annotatedScreenshotPath(forRawScreenshotPath: rawPath))
    }

    private func record<T>(
        _ name: String,
        into spans: inout [ObservationSpan],
        operation: () throws -> T) throws -> T
    {
        let start = ContinuousClock.now
        do {
            let value = try operation()
            spans.append(Self.span(name, start: start))
            return value
        } catch {
            spans.append(Self.span(name, start: start, metadata: ["success": "false"]))
            throw error
        }
    }

    private func record<T>(
        _ name: String,
        into spans: inout [ObservationSpan],
        operation: () async throws -> T) async throws -> T
    {
        let start = ContinuousClock.now
        do {
            let value = try await operation()
            spans.append(Self.span(name, start: start))
            return value
        } catch {
            spans.append(Self.span(name, start: start, metadata: ["success": "false"]))
            throw error
        }
    }

    private static func span(
        _ name: String,
        start: ContinuousClock.Instant,
        metadata: [String: String] = [:]) -> ObservationSpan
    {
        let duration = start.duration(to: ContinuousClock.now)
        let milliseconds = Double(duration.components.seconds * 1000)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        return ObservationSpan(name: name, durationMS: milliseconds, metadata: metadata)
    }

    private func outputURL(path: String?, format: ImageFormat) -> URL {
        ObservationOutputPathResolver.resolve(
            path: path,
            format: format,
            defaultFileName: "peekaboo-observation-\(Self.timestamp()).\(format.fileExtension)")
    }

    private func encodedImageData(_ data: Data, format: ImageFormat) throws -> Data {
        switch format {
        case .png:
            return data
        case .jpg:
            guard let image = NSImage(data: data),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
            else {
                throw OperationError.captureFailed(reason: "Failed to convert screenshot to JPEG")
            }
            return jpeg
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return formatter.string(from: Date())
    }
}

extension ImageFormat {
    fileprivate var fileExtension: String {
        switch self {
        case .png:
            "png"
        case .jpg:
            "jpg"
        }
    }
}
