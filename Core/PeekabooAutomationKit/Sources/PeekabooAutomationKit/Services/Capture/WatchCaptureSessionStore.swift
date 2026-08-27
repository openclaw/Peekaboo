import Foundation
import PeekabooFoundation

struct WatchCaptureSessionStore {
    let outputRoot: URL
    let autocleanMinutes: Int
    let managedAutoclean: Bool
    let sessionId: String
    var fileManager: FileManager = .default

    func prepareOutputRoot() throws {
        try self.fileManager.createDirectory(
            at: self.outputRoot,
            withIntermediateDirectories: true)
        let contents = try self.fileManager.contentsOfDirectory(
            at: self.outputRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        let staleArtifacts = contents.filter { url in
            url.lastPathComponent == "contact.png" ||
                url.lastPathComponent == "metadata.json" ||
                url.lastPathComponent == "action.json" ||
                (url.lastPathComponent.hasPrefix("keep-") && url.pathExtension.lowercased() == "png")
        }
        guard staleArtifacts.isEmpty else {
            let names = staleArtifacts.map(\.lastPathComponent).sorted().prefix(5).joined(separator: ", ")
            throw PeekabooError.fileIOError(
                "Capture output directory already contains capture artifacts (\(names)); choose an empty directory")
        }
    }

    func performAutoclean() -> WatchWarning? {
        guard self.managedAutoclean else { return nil }
        guard self.autocleanMinutes > 0 else { return nil }
        let root = self.outputRoot.deletingLastPathComponent()
        guard Self.autocleanRootNames.contains(root.lastPathComponent) else { return nil }
        guard let contents = try? self.fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles)
        else { return nil }

        let deadline = Date().addingTimeInterval(TimeInterval(-self.autocleanMinutes) * 60)
        var removed = 0
        for url in contents {
            guard url.standardizedFileURL != self.outputRoot.standardizedFileURL else { continue }
            guard let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = attrs.contentModificationDate else { continue }
            if modified < deadline {
                if (try? self.fileManager.removeItem(at: url)) != nil {
                    removed += 1
                }
            }
        }

        guard removed > 0 else { return nil }
        return WatchWarning(
            code: .autoclean,
            message: "Autoclean removed \(removed) old capture sessions",
            details: ["session": self.sessionId])
    }

    func writeJSON(_ value: some Encodable, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static let autocleanRootNames: Set<String> = ["watch-sessions", "capture-sessions"]
}
