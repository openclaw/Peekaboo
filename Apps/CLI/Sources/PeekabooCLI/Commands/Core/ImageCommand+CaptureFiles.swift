import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
extension ImageCommand {
    func capturedFile(
        from observation: DesktopObservationResult,
        preferredName: String?,
        windowIndex: Int?
    ) throws -> ImageCapturedFile {
        try ImageCapturedFile(
            file: self.savedFile(
                from: observation,
                preferredName: preferredName,
                windowIndex: windowIndex
            ),
            observation: ImageObservationDiagnostics(
                timings: observation.timings,
                diagnostics: observation.diagnostics,
                capture: observation.capture,
                rawImagePath: observation.files.rawScreenshotPath
            )
        )
    }

    func makeOutputURL(preferredName: String?, index: Int?) -> URL {
        if self.streamsImageToStdout {
            let suffix = index.map { "-\($0)" } ?? ""
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("peekaboo-stdout-\(UUID().uuidString)\(suffix)")
                .appendingPathExtension(self.format.fileExtension)
        }

        if let explicit = self.path {
            let expanded = (explicit as NSString).expandingTildeInPath
            if ObservationOutputPathResolver.isDirectoryLike(expanded) {
                return URL(fileURLWithPath: expanded, isDirectory: true)
                    .appendingPathComponent(self.defaultOutputFilename(preferredName: preferredName, index: index))
            }

            var url = URL(fileURLWithPath: expanded)
            let directory = url.deletingLastPathComponent()
            var stem = url.deletingPathExtension().lastPathComponent
            var ext = url.pathExtension

            if ext.isEmpty {
                ext = self.format.fileExtension
            }

            if let index, index > 0 {
                stem += "_\(index)"
            }

            url = directory.appendingPathComponent(stem).appendingPathExtension(ext)
            return url
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(self.defaultOutputFilename(preferredName: preferredName, index: index))
    }

    private func savedFile(
        from observation: DesktopObservationResult,
        preferredName: String?,
        windowIndex: Int?
    ) throws -> SavedFile {
        guard let path = observation.files.rawScreenshotPath else {
            throw CaptureError.captureFailure("Observation completed without a saved screenshot path")
        }

        let windowInfo = observation.capture.metadata.windowInfo
        return SavedFile(
            path: path,
            item_label: preferredName ?? windowInfo?.title,
            window_title: windowInfo?.title,
            window_id: windowInfo.map { UInt32($0.windowID) },
            window_index: windowIndex ?? windowInfo?.index,
            mime_type: self.format.mimeType
        )
    }

    private func defaultOutputFilename(preferredName: String?, index: Int?) -> String {
        let timestamp = Self.imageFilenameDateFormatter.string(from: Date())
        var components: [String] = []
        if let preferred = preferredName {
            components.append(self.sanitizeFilenameComponent(preferred))
        } else if let appName = self.app {
            components.append(self.sanitizeFilenameComponent(appName))
        } else if let mode = self.mode {
            components.append(mode.rawValue)
        } else {
            components.append("capture")
        }
        components.append(timestamp)
        if let index, index > 0 {
            components.append(String(index))
        }

        return components.joined(separator: "_") + ".\(self.format.fileExtension)"
    }

    private func sanitizeFilenameComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    private static let imageFilenameDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
