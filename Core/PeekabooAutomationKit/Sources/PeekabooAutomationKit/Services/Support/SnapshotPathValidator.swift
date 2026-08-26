import Darwin
import Foundation
import PeekabooFoundation

enum SnapshotPathValidator {
    static let producerOwnerMarkerName = ".producer-bound-reference"
    static let snapshotPayloadName = "snapshot.json"

    static func directChildURL(for snapshotID: String, in rootURL: URL) -> URL? {
        guard !snapshotID.isEmpty,
              snapshotID != ".",
              snapshotID != "..",
              !snapshotID.contains("/"),
              !snapshotID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }

        let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let candidate = canonicalRoot.appendingPathComponent(snapshotID).standardizedFileURL
        guard candidate.deletingLastPathComponent().path == canonicalRoot.path else { return nil }

        var info = stat()
        if lstat(candidate.path, &info) == 0 {
            // Snapshot IDs name directories. This also rejects terminal and dangling symlinks
            // before resolving them, so an alias can never redirect cleanup to a sibling.
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return nil }
        } else if errno != ENOENT {
            return nil
        }

        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedCandidate.deletingLastPathComponent().path == canonicalRoot.path else { return nil }

        // Keep the lexical child. Returning a resolved URL could make a later delete target a
        // symlink destination instead of the user-supplied cache entry.
        return candidate
    }

    static func producerOwnedDirectChildURL(for snapshotID: String, in rootURL: URL) -> URL? {
        guard SnapshotReference(rawValue: snapshotID) != nil,
              let candidate = self.directChildURL(for: snapshotID, in: rootURL)
        else { return nil }

        let markerURL = candidate.appendingPathComponent(self.producerOwnerMarkerName)
        var markerInfo = stat()
        guard lstat(markerURL.path, &markerInfo) == 0,
              markerInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              let marker = try? Data(contentsOf: markerURL),
              marker == Data(snapshotID.utf8)
        else { return nil }
        return candidate
    }

    static func producerOwnedSnapshotPayloadURL(
        for snapshotID: String,
        in rootURL: URL,
        allowMissing: Bool) -> URL?
    {
        guard let candidate = self.producerOwnedDirectChildURL(for: snapshotID, in: rootURL) else {
            return nil
        }
        let payloadURL = candidate.appendingPathComponent(self.snapshotPayloadName)
        var payloadInfo = stat()
        if lstat(payloadURL.path, &payloadInfo) == 0 {
            guard payloadInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        } else if !allowMissing || errno != ENOENT {
            return nil
        }
        return payloadURL
    }

    static func cleanupEligibleDirectChildURL(for snapshotID: String, in rootURL: URL) -> URL? {
        if let owned = self.producerOwnedDirectChildURL(for: snapshotID, in: rootURL) {
            return owned
        }
        if self.isLegacyPendingSnapshotDirectoryName(snapshotID) {
            return self.directChildURL(for: snapshotID, in: rootURL)
        }
        guard self.isLegacyTimestampSnapshotID(snapshotID),
              let candidate = self.directChildURL(for: snapshotID, in: rootURL)
        else { return nil }

        var payloadInfo = stat()
        let payloadURL = candidate.appendingPathComponent(self.snapshotPayloadName)
        guard lstat(payloadURL.path, &payloadInfo) == 0,
              payloadInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else { return nil }
        return candidate
    }

    static func isLegacyTimestampSnapshotID(_ snapshotID: String) -> Bool {
        let bytes = Array(snapshotID.utf8)
        guard bytes.count == 18, bytes[13] == 45 else { return false }
        return bytes.enumerated().allSatisfy { index, byte in
            index == 13 || (48...57).contains(byte)
        }
    }

    static func isLegacyPendingSnapshotDirectoryName(_ name: String) -> Bool {
        let prefix = ".pending-"
        guard name.hasPrefix(prefix) else { return false }
        let suffix = String(name.dropFirst(prefix.count))
        guard let identifier = UUID(uuidString: suffix) else { return false }
        return identifier.uuidString == suffix
    }
}
