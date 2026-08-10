import Algorithms
import Foundation
import PeekabooCore

@MainActor
extension SeeCommand {
    func performScreenCapture() async throws -> CaptureResult {
        if self.annotate {
            self.logger.info("Annotation is disabled for full screen captures due to performance constraints")
        }

        self.logger.verbose("Initiating screen capture", category: "Capture")
        self.logger.startTimer("screen_capture")

        defer {
            self.logger.stopTimer("screen_capture")
        }

        if let index = self.screenIndex ?? (self.analyze != nil ? 0 : nil) {
            self.logger.verbose("Capturing specific screen", category: "Capture", metadata: ["screenIndex": index])
            let result = try await self.services.screenCapture.captureScreen(
                displayIndex: index,
                visualizerMode: .none,
                scale: self.retina ? .native : .logical1x
            )

            if !self.jsonOutput, let displayInfo = result.metadata.displayInfo {
                self.printScreenDisplayInfo(index: index, displayInfo: displayInfo)
            }

            self.logger.verbose("Screen capture completed", category: "Capture", metadata: [
                "mode": "screen-index",
                "screenIndex": index,
                "imageBytes": result.imageData.count,
            ])
            return result
        }

        self.logger.verbose("Capturing all screens", category: "Capture")
        let results = try await self.captureAllScreens()

        if results.isEmpty {
            throw CaptureError.captureFailure("Failed to capture any screens")
        }

        if !self.jsonOutput {
            print("📸 Captured \(results.count) screen(s):")
        }

        for (index, result) in results.indexed() {
            if index > 0 {
                let screenPath = self.screenOutputPath(for: index)
                try result.imageData.write(to: URL(fileURLWithPath: screenPath))

                if !self.jsonOutput, let displayInfo = result.metadata.displayInfo {
                    let fileSize = self.getFileSize(screenPath) ?? 0
                    let suffix = "\(screenPath) (\(self.formatFileSize(Int64(fileSize))))"
                    self.printScreenDisplayInfo(
                        index: index,
                        displayInfo: displayInfo,
                        indent: "   ",
                        suffix: suffix
                    )
                }
            } else if !self.jsonOutput, let displayInfo = result.metadata.displayInfo {
                self.printScreenDisplayInfo(
                    index: index,
                    displayInfo: displayInfo,
                    indent: "   ",
                    suffix: "(primary)"
                )
            }
        }

        self.logger.verbose("Multi-screen capture completed", category: "Capture", metadata: [
            "count": results.count,
            "primaryBytes": results.first?.imageData.count ?? 0,
        ])
        return results[0]
    }

    func captureAllScreens() async throws -> [CaptureResult] {
        var results: [CaptureResult] = []

        let displays = self.services.screens.listScreens()

        self.logger.info("Found \(displays.count) display(s) to capture")

        for display in displays {
            self.logger.verbose("Capturing display \(display.index)", category: "MultiScreen", metadata: [
                "displayID": display.displayID,
                "width": display.frame.width,
                "height": display.frame.height,
            ])

            do {
                let result = try await self.services.screenCapture.captureScreen(
                    displayIndex: display.index,
                    visualizerMode: .none,
                    scale: self.retina ? .native : .logical1x
                )
                results.append(result)
            } catch {
                self.logger.error("Failed to capture display \(display.index): \(error)")
                // Continue capturing other screens even if one fails
            }
        }

        if results.isEmpty {
            throw CaptureError.captureFailure("Failed to capture any screens")
        }

        return results
    }

    func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func screenOutputPath(for index: Int) -> String {
        if let basePath = self.path {
            let expanded = (basePath as NSString).expandingTildeInPath
            if ObservationOutputPathResolver.isDirectoryLike(expanded) {
                return URL(fileURLWithPath: expanded, isDirectory: true)
                    .appendingPathComponent(self.defaultScreenOutputFilename(for: index))
                    .path
            }

            let directory = (expanded as NSString).deletingLastPathComponent
            let filename = (expanded as NSString).lastPathComponent
            let nameWithoutExt = (filename as NSString).deletingPathExtension
            let ext = (filename as NSString).pathExtension
            let fileExtension = ext.isEmpty ? "png" : ext

            return (directory as NSString)
                .appendingPathComponent("\(nameWithoutExt)_screen\(index).\(fileExtension)")
        }

        return self.defaultScreenOutputFilename(for: index)
    }

    private func defaultScreenOutputFilename(for index: Int) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return "screenshot_\(timestamp)_screen\(index).png"
    }

    private func screenDisplayBaseText(index: Int, displayInfo: DisplayInfo) -> String {
        let displayName = displayInfo.name ?? "Display \(index)"
        let bounds = displayInfo.bounds
        let resolution = "(\(Int(bounds.width))×\(Int(bounds.height)))"
        return "[scrn]️  Display \(index): \(displayName) \(resolution)"
    }

    private func printScreenDisplayInfo(
        index: Int,
        displayInfo: DisplayInfo,
        indent: String = "",
        suffix: String? = nil
    ) {
        var line = self.screenDisplayBaseText(index: index, displayInfo: displayInfo)
        if let suffix {
            line += " → \(suffix)"
        }
        print("\(indent)\(line)")
    }
}
