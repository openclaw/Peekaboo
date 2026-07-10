import Darwin
import Foundation

enum SnapshotPathValidator {
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
}
