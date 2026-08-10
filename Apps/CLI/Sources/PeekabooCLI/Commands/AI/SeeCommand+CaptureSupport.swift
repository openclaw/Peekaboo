import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
extension SeeCommand {
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
