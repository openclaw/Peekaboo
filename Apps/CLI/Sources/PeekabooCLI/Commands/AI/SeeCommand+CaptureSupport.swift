import CoreGraphics
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
                .appendingPathComponent("raw.png")
                .path
        }

        let timestamp = Date().timeIntervalSince1970
        let filename = "peekaboo_see_\(Int(timestamp)).png"
        return ObservationCommandSupport.outputPath(
            path: self.path,
            format: .png,
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

    func resolveSeeWindowIndex(appIdentifier: String, titleFragment: String?) async throws -> Int? {
        guard let fragment = titleFragment, !fragment.isEmpty else {
            return nil
        }

        let appInfo = try await self.services.applications.findApplication(identifier: appIdentifier)
        let snapshot = try await WindowListMapper.shared.snapshot()
        let appWindows = WindowListMapper.scWindows(
            for: appInfo.processIdentifier,
            in: snapshot.scWindows
        )

        guard !appWindows.isEmpty else {
            throw CaptureError.windowNotFound
        }

        if let index = WindowListMapper.scWindowIndex(
            for: appInfo.processIdentifier,
            titleFragment: fragment,
            in: snapshot
        ) {
            return index
        }

        if let index = WindowListMapper.scWindowIndex(for: fragment, in: appWindows) {
            return index
        }

        throw CaptureError.windowNotFound
    }

    func resolveWindowId(appIdentifier: String, titleFragment: String?) async throws -> Int? {
        guard let fragment = titleFragment, !fragment.isEmpty else {
            return nil
        }

        let windows = try await self.services.windows.listWindows(
            target: .applicationAndTitle(app: appIdentifier, title: fragment)
        )
        return windows.first?.windowID
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
