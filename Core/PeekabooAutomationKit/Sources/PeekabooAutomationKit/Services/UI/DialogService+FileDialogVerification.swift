import AppKit
import AXorcist
import Foundation

@MainActor
extension DialogService {
    struct SavedFileVerification {
        let path: String
        let foundVia: String
    }

    struct SavedFileVerificationRequest {
        let appName: String?
        let priorDocumentPath: String?
        let expectedPath: String?
        let expectedBaseName: String?
        let startedAt: Date
        let timeout: TimeInterval
    }

    func enforceExpectedDirectoryIfNeeded(
        actualSavedPath: String,
        expectedPath: String?,
        details: inout [String: String]) throws
    {
        guard let expectedPath else { return }
        let expectedDirectory = URL(fileURLWithPath: expectedPath)
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let actualDirectory = URL(fileURLWithPath: actualSavedPath)
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        details["saved_path_expected_directory"] = expectedDirectory
        details["saved_path_directory"] = actualDirectory
        details["saved_path_matches_expected_directory"] = String(expectedDirectory == actualDirectory)

        guard expectedDirectory == actualDirectory else {
            throw DialogError.fileSavedToUnexpectedDirectory(
                expectedDirectory: expectedDirectory,
                actualDirectory: actualDirectory,
                actualPath: actualSavedPath)
        }
    }

    func expectedSavedPath(path: String?, filename: String?) -> String? {
        guard let filename else { return nil }
        guard let path else { return nil }

        let expandedPath = (path as NSString).expandingTildeInPath
        let baseURL = URL(fileURLWithPath: expandedPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        if baseURL.lastPathComponent == filename {
            return baseURL.path
        }

        return baseURL.appendingPathComponent(filename).path
    }

    func expectedSavedBaseName(filename: String?, expectedPath: String?) -> String? {
        if let filename {
            return URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        }
        if let expectedPath {
            return URL(fileURLWithPath: expectedPath).deletingPathExtension().lastPathComponent
        }
        return nil
    }

    func verifySavedFile(_ request: SavedFileVerificationRequest) async throws -> SavedFileVerification {
        let deadline = request.startedAt.addingTimeInterval(request.timeout)
        let fileManager = FileManager.default

        let expectedURL = request.expectedPath.map { URL(fileURLWithPath: $0) }
        let expectedDirectory = expectedURL?.deletingLastPathComponent()
        let expectedFileBaseName = expectedURL?.deletingPathExtension().lastPathComponent

        var lastDirectoryScan: Date?

        while Date() < deadline {
            if let appName = request.appName,
               let current = self.documentPathForApp(appName: appName)
            {
                let matchesName: Bool = if let expectedBaseName = request.expectedBaseName {
                    URL(fileURLWithPath: current)
                        .deletingPathExtension()
                        .lastPathComponent
                        .hasPrefix(expectedBaseName)
                } else {
                    true
                }

                if matchesName,
                   fileManager.fileExists(atPath: current),
                   self.fileWasModified(atPath: current, since: request.startedAt)
                {
                    return SavedFileVerification(path: current, foundVia: "document_path")
                }

                if matchesName,
                   let priorDocumentPath = request.priorDocumentPath,
                   current != priorDocumentPath,
                   fileManager.fileExists(atPath: current)
                {
                    return SavedFileVerification(path: current, foundVia: "document_path")
                }
            }

            if let expectedPath = request.expectedPath,
               fileManager.fileExists(atPath: expectedPath)
            {
                return SavedFileVerification(path: expectedPath, foundVia: "expected_path")
            }

            let shouldScanDirectory = lastDirectoryScan == nil ||
                Date().timeIntervalSince(lastDirectoryScan ?? Date.distantPast) > 0.5

            if shouldScanDirectory,
               let expectedDirectory,
               let expectedBaseName = expectedFileBaseName ?? request.expectedBaseName,
               let candidate = self.findRecentlyWrittenFile(
                   in: expectedDirectory,
                   fileNamePrefix: expectedBaseName,
                   startedAt: request.startedAt)
            {
                return SavedFileVerification(path: candidate, foundVia: "expected_directory_scan")
            }

            if shouldScanDirectory {
                lastDirectoryScan = Date()
            }

            try await Task.sleep(nanoseconds: 125_000_000)
        }

        if let expectedBaseName = request.expectedBaseName,
           let fallback = self.fallbackFindRecentlyWrittenFile(
               filenamePrefix: expectedBaseName,
               startedAt: request.startedAt)
        {
            return SavedFileVerification(path: fallback, foundVia: "fallback_search")
        }

        let expectedDescription: String = if let expectedPath = request.expectedPath {
            expectedPath
        } else if let expectedBaseName = request.expectedBaseName {
            "(unknown directory; name prefix: \(expectedBaseName))"
        } else {
            "(unknown path)"
        }

        throw DialogError.fileVerificationFailed(expectedPath: expectedDescription)
    }

    func clickReplaceIfPresent(appName: String?) async -> Bool {
        guard let dialog = try? await self.resolveDialogElement(windowTitle: nil, appName: appName) else {
            return false
        }

        let buttons = self.collectButtons(from: dialog)
        guard let replace = buttons.first(where: { btn in
            let normalized = (btn.title() ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "…", with: "")
                .replacingOccurrences(of: "...", with: "")
                .lowercased()
            return normalized == "replace" || normalized.contains("replace")
        }) else {
            return false
        }

        do {
            try self.pressOrClick(replace, allowGlobalFallback: true)
            return true
        } catch {
            return false
        }
    }

    func documentPathForApp(appName: String?) -> String? {
        guard let appName, let running = self.runningApplication(matching: appName) else { return nil }
        let appElement = AXApp(running).element

        let windows = appElement.windowsWithTimeout() ?? []
        let preferredWindows: [Element] = [
            appElement.mainWindow(),
            appElement.focusedWindow(),
        ].compactMap(\.self)

        let candidates = (preferredWindows + windows)

        func isDialogLike(_ window: Element) -> Bool {
            let subrole = window.subrole() ?? ""
            if subrole == "AXDialog" || subrole == "AXSystemDialog" || subrole == "AXAlert" {
                return true
            }

            let roleDescription = window.attribute(Attribute<String>("AXRoleDescription")) ?? ""
            if roleDescription.localizedCaseInsensitiveContains("dialog") {
                return true
            }

            let identifier = window.attribute(Attribute<String>("AXIdentifier")) ?? ""
            if identifier.contains("NSOpenPanel") || identifier.contains("NSSavePanel") {
                return true
            }

            return false
        }

        for window in candidates where !isDialogLike(window) {
            let document = window.attribute(Attribute<String>(AXAttributeNames.kAXDocumentAttribute))
            if let normalized = self.normalizeDocumentAttributeToPath(document) {
                return normalized
            }
        }

        return nil
    }

    private func fallbackFindRecentlyWrittenFile(filenamePrefix: String, startedAt: Date) -> String? {
        let fileManager = FileManager.default

        let candidates: [URL] = [
            URL(fileURLWithPath: "/private/tmp"),
            URL(fileURLWithPath: "/tmp"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath),
        ]
            .map(\.standardizedFileURL)
            .filter { fileManager.fileExists(atPath: $0.path) }

        for directory in candidates {
            if let match = self.findRecentlyWrittenFile(
                in: directory,
                fileNamePrefix: filenamePrefix,
                startedAt: startedAt)
            {
                return match
            }
        }

        return nil
    }

    private func findRecentlyWrittenFile(
        in directory: URL,
        fileNamePrefix: String,
        startedAt: Date) -> String?
    {
        let fileManager = FileManager.default

        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else {
            return nil
        }

        let earliest = startedAt.addingTimeInterval(-2.0)

        let candidates: [(url: URL, modifiedAt: Date)] = urls.compactMap { url in
            guard url.lastPathComponent.hasPrefix(fileNamePrefix) else { return nil }
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date.distantPast
            guard modifiedAt >= earliest else { return nil }
            return (url: url, modifiedAt: modifiedAt)
        }

        guard let best = candidates.max(by: { $0.modifiedAt < $1.modifiedAt }) else {
            return nil
        }

        return best.url.path
    }

    private func normalizeDocumentAttributeToPath(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }

        if raw.hasPrefix("file://"),
           let url = URL(string: raw),
           url.isFileURL
        {
            return url.path
        }

        return raw
    }

    private func fileWasModified(atPath path: String, since date: Date) -> Bool {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]),
              let modifiedAt = values.contentModificationDate
        else {
            return false
        }

        return modifiedAt >= date.addingTimeInterval(-2.0)
    }
}
