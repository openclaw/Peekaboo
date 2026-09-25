import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
extension SeeCommand {
    static func observedFocusSummary(elements: [DetectedElement], metadata: DetectionMetadata) -> String {
        // ROI retains the original focus metadata while filtering the candidate population.
        guard metadata.captureCoordinateContext?.viewport == nil else {
            return "scope=roi_filtered rawResolver=not_evaluated"
        }
        var focusedTypes: [String: Int] = [:]
        var falseCount = 0
        var unknownCount = 0
        for element in elements {
            switch element.isFocused {
            case true?: focusedTypes[element.type.rawValue, default: 0] += 1
            case false?: falseCount += 1
            case nil: unknownCount += 1
            }
        }
        let resolution: String
        if let context = metadata.windowContext {
            do {
                _ = try FocusedElementReceiptResolver.uniqueReceipt(elements: elements, context: context)
                resolution = "unique"
            } catch let error as FocusedElementReceiptError {
                resolution = String(describing: error)
            } catch {
                resolution = "unavailable"
            }
        } else {
            resolution = "noWindowContext"
        }
        let types = focusedTypes.sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }.joined(separator: ",")
        return "rawTrue=\(focusedTypes.values.reduce(0, +)) rawFalse=\(falseCount) rawUnknown=\(unknownCount) " +
            "rawFocusedTypes=[\(types)] rawResolver=\(resolution) " +
            "cached=\(metadata.method.contains("cached")) " +
            "partial=\(metadata.isApplicationScopedAccessibilityFallback) " +
            "truncated=\(metadata.truncationInfo?.isTruncated == true) " +
            "attached=\(metadata.windowContext?.focusedElement != nil)"
    }

    var usesTemporaryScreenshotOutput: Bool {
        self.jsonOutput && self.path == nil
    }

    func screenshotOutputPath(snapshotID: String? = nil) -> String {
        if self.usesTemporaryScreenshotOutput {
            return self.temporaryScreenshotDirectory(snapshotID: snapshotID)
                .appendingPathComponent("raw.\(self.format.fileExtension)")
                .path
        }

        let timestamp = Date().timeIntervalSince1970
        let filename = "peekaboo_see_\(Int(timestamp)).\(self.format.fileExtension)"
        return ObservationCommandSupport.outputPath(
            path: self.path,
            format: self.format,
            defaultDirectory: ConfigurationManager.shared.getDefaultSavePath(cliValue: nil),
            defaultFileName: filename
        )
    }

    func saveScreenshot(_ imageData: Data, snapshotID: String) throws -> String {
        let outputPath = self.screenshotOutputPath(snapshotID: snapshotID)

        let directory = (outputPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )

        try imageData.write(to: URL(fileURLWithPath: outputPath))
        self.logger.verbose("Saved screenshot to: \(outputPath)")

        return outputPath
    }

    func cleanupTemporaryScreenshotOutput(snapshotID: String) {
        guard self.usesTemporaryScreenshotOutput else { return }
        try? FileManager.default.removeItem(at: self.temporaryScreenshotDirectory(snapshotID: snapshotID))
    }

    private func temporaryScreenshotDirectory(snapshotID: String?) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-see", isDirectory: true)
            .appendingPathComponent(snapshotID ?? UUID().uuidString, isDirectory: true)
    }

    func generateAnnotatedScreenshot(
        snapshotId: String,
        originalPath: String
    ) async throws -> String? {
        guard let detectionResult = try await self.services.snapshots.getDetectionResult(snapshotId: snapshotId)
        else {
            self.logger.info("No detection result found for snapshot")
            return nil
        }

        let renderer = ObservationAnnotationRenderer(debugMode: self.verbose)
        let annotatedPath = try renderer.renderAnnotatedScreenshot(
            originalPath: originalPath,
            detectionResult: detectionResult
        )
        guard let annotatedPath else {
            return nil
        }
        self.logger.verbose("Created annotated screenshot: \(annotatedPath)")

        return annotatedPath
    }
}
