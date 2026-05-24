import AppKit
import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

struct ImageAnalysisData: Codable {
    let provider: String
    let model: String
    let text: String
}

struct ImageCapturedFile {
    let file: SavedFile
    let observation: ImageObservationDiagnostics
}

struct ImageObservationDiagnostics: Codable {
    let spans: [SeeObservationSpan]
    let warnings: [String]
    let state_snapshot: SeeDesktopStateSnapshotSummary?
    let target: SeeObservationTargetDiagnostics?
    let coordinates: ImageCoordinateDiagnostics?

    init(
        timings: ObservationTimings,
        diagnostics: DesktopObservationDiagnostics,
        capture: CaptureResult? = nil,
        rawImagePath: String? = nil
    ) {
        self.spans = timings.spans.map(SeeObservationSpan.init)
        self.warnings = diagnostics.warnings + ImageBlankCaptureDiagnostics.warnings(
            rawImagePath: rawImagePath,
            capture: capture
        )
        self.state_snapshot = diagnostics.stateSnapshot.map(SeeDesktopStateSnapshotSummary.init)
        self.target = diagnostics.target.map(SeeObservationTargetDiagnostics.init)
        self.coordinates = capture.map(ImageCoordinateDiagnostics.init)
    }
}

struct ImageCoordinateDiagnostics: Codable {
    let coordinate_space: String
    let logical_bounds: CGRect?
    let image_size_pixels: ImageSizeDiagnostics
    let scale_factor: CGFloat?
    let screen_index: Int?
    let screen_name: String?

    init(capture: CaptureResult) {
        let metadata = capture.metadata
        self.coordinate_space = "global_display_points"
        self.logical_bounds = metadata.windowInfo?.bounds ?? metadata.displayInfo?.bounds
        self.image_size_pixels = ImageSizeDiagnostics(metadata.size)
        self.scale_factor = metadata.diagnostics?.outputScale
            ?? metadata.displayInfo?.scaleFactor
            ?? Self.inferredScale(imageSize: metadata.size, bounds: self.logical_bounds)
        self.screen_index = metadata.windowInfo?.screenIndex ?? metadata.displayInfo?.index
        self.screen_name = metadata.windowInfo?.screenName ?? metadata.displayInfo?.name
    }

    private static func inferredScale(imageSize: CGSize, bounds: CGRect?) -> CGFloat? {
        guard let bounds, bounds.width > .zero else {
            return nil
        }
        return imageSize.width / bounds.width
    }
}

struct ImageSizeDiagnostics: Codable {
    let width: Double
    let height: Double

    init(_ size: CGSize) {
        self.width = size.width
        self.height = size.height
    }
}

enum ImageBlankCaptureDiagnostics {
    static func warnings(rawImagePath: String?, capture: CaptureResult?) -> [String] {
        guard let rawImagePath,
              let capture,
              capture.metadata.mode == .window,
              let data = try? Data(contentsOf: URL(fileURLWithPath: rawImagePath)),
              let bitmap = NSBitmapImageRep(data: data)
        else {
            return []
        }

        return self.blankWarning(bitmap: bitmap).map { [$0] } ?? []
    }

    private static func blankWarning(bitmap: NSBitmapImageRep) -> String? {
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 1, height > 1 else {
            return nil
        }

        let sampleCount = min(width, 20) * min(height, 20)
        guard sampleCount > 0 else { return nil }

        var alphaSum = 0.0
        var luminanceSum = 0.0
        var luminanceSquaredSum = 0.0

        let xStep = max(1, width / min(width, 20))
        let yStep = max(1, height / min(height, 20))
        var actualSamples = 0

        for y in stride(from: 0, to: height, by: yStep) {
            for x in stride(from: 0, to: width, by: xStep) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let alpha = Double(color.alphaComponent)
                let luminance = Double(0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color
                    .blueComponent)
                alphaSum += alpha
                luminanceSum += luminance
                luminanceSquaredSum += luminance * luminance
                actualSamples += 1
            }
        }

        guard actualSamples > 0 else { return nil }

        let alphaMean = alphaSum / Double(actualSamples)
        if alphaMean < 0.01 {
            return "Captured window image appears transparent; target may be hidden or non-renderable."
        }

        let luminanceMean = luminanceSum / Double(actualSamples)
        let variance = max(0, luminanceSquaredSum / Double(actualSamples) - luminanceMean * luminanceMean)
        if variance < 0.0001, luminanceMean < 0.02 {
            return "Captured window image appears solid black; target may be occluded, transparent, or non-renderable."
        }
        if variance < 0.0001, luminanceMean > 0.98 {
            return "Captured window image appears blank white; target may be empty or non-renderable."
        }

        return nil
    }
}

struct ImageCaptureResult: Codable {
    let files: [SavedFile]
    let observations: [ImageObservationDiagnostics]
}

struct ImageAnalyzeResult: Codable {
    let files: [SavedFile]
    let analysis: ImageAnalysisData
    let observations: [ImageObservationDiagnostics]
}

@MainActor
extension ImageCommand {
    var streamsImageToStdout: Bool {
        self.path?.trimmingCharacters(in: .whitespacesAndNewlines) == "-"
    }

    func validateStdoutStreamingOptions() throws {
        guard self.streamsImageToStdout else { return }

        if self.jsonOutput {
            throw ValidationError("Cannot combine --json with --path - because stdout is reserved for image bytes")
        }

        if self.analyze != nil {
            throw ValidationError("Cannot combine --analyze with --path - because stdout is reserved for image bytes")
        }
    }

    func outputImageToStdout(_ captures: [ImageCapturedFile]) throws {
        defer {
            for capture in captures {
                try? FileManager.default.removeItem(atPath: capture.file.path)
            }
        }

        guard captures.count == 1, let capture = captures.first else {
            throw ValidationError(
                "--path - supports exactly one captured image; add --screen-index or capture a single target"
            )
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: capture.file.path))
        FileHandle.standardOutput.write(data)
    }

    func outputResults(_ captures: [ImageCapturedFile]) {
        let output = ImageCaptureResult(
            files: captures.map(\.file),
            observations: captures.map(\.observation)
        )
        if self.jsonOutput {
            outputSuccessCodable(data: output, logger: self.outputLogger)
        } else {
            for capture in captures {
                print("📸 \(self.describeSavedFile(capture.file))")
                self.printWarnings(capture.observation.warnings)
            }
        }
    }

    func outputResultsWithAnalysis(_ captures: [ImageCapturedFile], analysis: ImageAnalysisData) {
        let output = ImageAnalyzeResult(
            files: captures.map(\.file),
            analysis: analysis,
            observations: captures.map(\.observation)
        )
        if self.jsonOutput {
            outputSuccessCodable(data: output, logger: self.outputLogger)
        } else {
            for capture in captures {
                print("📸 \(self.describeSavedFile(capture.file))")
                self.printWarnings(capture.observation.warnings)
            }
            print("\n🤖 Analysis (\(analysis.provider)) - \(analysis.model):")
            print(analysis.text)
        }
    }

    func analyzeImage(at path: String, with prompt: String) async throws -> ImageAnalysisData {
        let aiService = PeekabooAIService()
        let response = try await aiService.analyzeImageFileDetailed(at: path, question: prompt, model: nil)
        return ImageAnalysisData(provider: response.provider, model: response.model, text: response.text)
    }

    private func describeSavedFile(_ file: SavedFile) -> String {
        var segments: [String] = []
        if let label = file.item_label ?? file.window_title {
            segments.append(label)
        } else if let index = file.window_index {
            segments.append("window \(index)")
        }
        segments.append("→ \(file.path)")
        return segments.joined(separator: " ")
    }

    private func printWarnings(_ warnings: [String]) {
        warnings.forEach { print("⚠️  \($0)") }
    }
}

extension ImageFormat {
    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpg: "jpg"
        }
    }

    var mimeType: String {
        switch self {
        case .png: "image/png"
        case .jpg: "image/jpeg"
        }
    }
}
