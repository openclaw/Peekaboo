import CoreGraphics
import Foundation
import ImageIO
import MCP
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import UniformTypeIdentifiers

struct ImageCaptureSet {
    let captures: [CaptureResult]
    let observation: DesktopObservationResult?
}

extension ImageTool {
    func captureImages(for request: ImageRequest) async throws -> ImageCaptureSet {
        switch request.target {
        case .menubar:
            let observation = try await self.captureObservation(for: request)
            return ImageCaptureSet(captures: [observation.capture], observation: observation)
        default:
            let result = try await self.captureObservation(for: request)
            return ImageCaptureSet(captures: [result.capture], observation: result)
        }
    }

    func captureObservation(for request: ImageRequest) async throws -> DesktopObservationResult {
        if request.captureFocus == .foreground, let identifier = request.focusIdentifier {
            try await self.context.applications.activateApplication(identifier: identifier)
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let outputPath = request.outputPath ?? self.temporaryOutputPathIfNeeded(for: request)
        return try await self.context.desktopObservation.observe(DesktopObservationRequest(
            target: request.target.observationTarget,
            capture: DesktopCaptureOptions(
                scale: request.scale,
                focus: request.captureFocus,
                visualizerMode: .screenshotFlash),
            detection: DesktopDetectionOptions(mode: .none),
            output: DesktopObservationOutputOptions(
                path: outputPath,
                format: request.format.imageFormat,
                saveRawScreenshot: outputPath != nil)))
    }

    func savedFiles(for captureSet: ImageCaptureSet, request: ImageRequest) throws -> [MCPSavedFile] {
        guard let result = captureSet.captures.first else { return [] }
        guard let path = captureSet.observation?.files.rawScreenshotPath else {
            if request.outputPath != nil || request.question != nil || request.format == .data {
                throw OperationError.captureFailed(reason: "Observation completed without a saved screenshot path")
            }
            return []
        }

        return [
            MCPSavedFile(
                path: path,
                item_label: describeCapture(result.metadata),
                window_title: result.metadata.windowInfo?.title,
                window_id: result.metadata.windowInfo.map { String($0.windowID) },
                window_index: result.metadata.windowInfo?.index,
                mime_type: request.format.mimeType),
        ]
    }

    func temporaryOutputPathIfNeeded(for request: ImageRequest) -> String? {
        guard request.question != nil || request.format == .data else {
            return nil
        }

        return FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-\(UUID().uuidString).\(request.format.fileExtension)")
            .path
    }

    func downscaledCaptureSetIfNeeded(_ captureSet: ImageCaptureSet, request: ImageRequest) throws -> ImageCaptureSet {
        guard let maxDimension = request.effectiveMaxDimension else {
            return captureSet
        }

        var downscaledCaptures: [CaptureResult] = []
        downscaledCaptures.reserveCapacity(captureSet.captures.count)

        for capture in captureSet.captures {
            let savedPath = capture.savedPath ?? captureSet.observation?.files.rawScreenshotPath
            let imageData = if capture.imageData.isEmpty, let savedPath {
                (try? Data(contentsOf: URL(fileURLWithPath: savedPath))) ?? capture.imageData
            } else {
                capture.imageData
            }

            guard !imageData.isEmpty else {
                downscaledCaptures.append(capture)
                continue
            }

            guard let result = self.downscale(
                imageData: imageData,
                maxDimension: maxDimension,
                format: request.format)
            else {
                throw OperationError.captureFailed(
                    reason: "Failed to downscale image to max_dimension \(maxDimension)")
            }

            if result.resized, let savedPath {
                try result.data.write(to: URL(fileURLWithPath: savedPath), options: .atomic)
            }

            downscaledCaptures.append(CaptureResult(
                imageData: result.data,
                savedPath: capture.savedPath,
                metadata: capture.metadata,
                warning: capture.warning))
        }

        return ImageCaptureSet(captures: downscaledCaptures, observation: captureSet.observation)
    }

    func performAnalysis(
        question: String,
        savedFiles: [MCPSavedFile],
        captureResults: [CaptureResult],
        observation: DesktopObservationResult?) async throws -> ToolResponse
    {
        guard let firstCapture = captureResults.first else {
            throw OperationError.captureFailed(reason: "No capture data available")
        }

        let imagePath = try savedFiles.first?.path ?? saveTemporaryImage(firstCapture.imageData)
        let analysis = try await analyzeImage(at: imagePath, question: question)
        let baseMeta = ObservationDiagnosticsMetadata.merge(observation, into: .object([
            "model": .string(analysis.modelUsed),
            "savedFiles": .array(savedFiles.map { Value.string($0.path) }),
            "question": .string(question),
        ]))
        let summary = ToolEventSummary(
            actionDescription: "Image Analyze",
            notes: question)

        return ToolResponse.text(
            analysis.text,
            meta: ToolEventSummary.merge(summary: summary, into: baseMeta))
    }

    func buildCaptureResponse(
        format: ImageFormatOption,
        savedFiles: [MCPSavedFile],
        captureResults: [CaptureResult],
        observation: DesktopObservationResult?) -> ToolResponse
    {
        let baseMeta = ObservationDiagnosticsMetadata.merge(observation, into: .object([
            "savedFiles": .array(savedFiles.map { Value.string($0.path) }),
        ]))
        let captureNote: String = if savedFiles.isEmpty {
            "Captured image"
        } else if savedFiles.count == 1, let label = savedFiles.first?.item_label {
            label
        } else {
            "Captured \(savedFiles.count) images"
        }
        let summary = ToolEventSummary(
            actionDescription: "Image Capture",
            notes: captureNote)
        let meta = ToolEventSummary.merge(summary: summary, into: baseMeta)

        if format == .data, let capture = captureResults.first, captureResults.count == 1 {
            let data = if capture.imageData.isEmpty, let path = savedFiles.first?.path {
                (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? capture.imageData
            } else {
                capture.imageData
            }
            if data.isEmpty {
                return ToolResponse.error(
                    "Capture produced no image data and no saved file could be read",
                    meta: meta)
            }
            return ToolResponse.image(data: data, mimeType: "image/png", meta: meta)
        }

        return ToolResponse.text(
            buildImageSummary(savedFiles: savedFiles, captureCount: captureResults.count),
            meta: meta)
    }

    private func encode(cgImage: CGImage, format: ImageFormatOption) -> Data? {
        let data = NSMutableData()
        let uti: CFString = switch format {
        case .png, .data: UTType.png.identifier as CFString
        case .jpg: UTType.jpeg.identifier as CFString
        }
        guard let destination = CGImageDestinationCreateWithData(
            data,
            uti,
            1,
            nil)
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    func downscale(imageData: Data, maxDimension: Int, format: ImageFormatOption) -> (data: Data, resized: Bool)? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else {
            return nil
        }

        let longest = max(width, height)
        guard longest > CGFloat(maxDimension) else {
            return (imageData, false)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        guard let encodedData = self.encode(cgImage: thumbnail, format: format) else {
            return nil
        }

        return (encodedData, true)
    }
}
