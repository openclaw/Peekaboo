import Darwin
import Foundation

/// ConfigurationManager supplies the production serialization boundary; direct files are useful for owned fixtures.
public protocol CredentialFileAccess: Sendable {
    func readCredentialSnapshot() throws -> [String: String]
    func updateCredentials(_ edit: (inout [String: String]) throws -> Void) throws -> CredentialFile.Publication
}

/// The existing KEY=value file. This does not serialize independent processes (including Tachikoma).
public struct CredentialFile: CredentialFileAccess {
    public enum Failure: Error, Equatable {
        case unreadable, invalidData, unsafePath, publicationFailed
    }

    public struct Publication: Sendable {
        public let snapshot: [String: String]
        /// Publication happened, but a directory sync failed. Do not retry as though the old file survived.
        public let durabilityWarning: Bool

        public init(snapshot: [String: String], durabilityWarning: Bool = false) {
            self.snapshot = snapshot
            self.durabilityWarning = durabilityWarning
        }
    }

    public let url: URL
    private let synchronizeDirectory: @Sendable (URL) -> Bool

    public init(url: URL) {
        self.url = url
        self.synchronizeDirectory = Self.syncDirectory
    }

    init(url: URL, synchronizeDirectory: @escaping @Sendable (URL) -> Bool) {
        self.url = url
        self.synchronizeDirectory = synchronizeDirectory
    }

    public func readCredentialSnapshot() throws -> [String: String] {
        let descriptor = open(self.url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return [:]
            }
            throw Failure.unreadable
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid()
        else { throw Failure.unsafePath }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw Failure.unreadable
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let contents = String(data: data, encoding: .utf8), !contents.contains("\0") else {
            throw Failure.invalidData
        }
        var snapshot: [String: String] = [:]
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            guard let separator = trimmed.firstIndex(of: "=") else { throw Failure.invalidData }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw Failure.invalidData }
            if !value.isEmpty {
                snapshot[key] = value
            }
        }
        return snapshot
    }

    public func updateCredentials(
        _ edit: (inout [String: String]) throws -> Void) throws -> Publication
    {
        var snapshot = try self.readCredentialSnapshot()
        try edit(&snapshot)
        for (key, value) in snapshot {
            guard !key.isEmpty, !key.contains("="), !key.hasPrefix("#"),
                  key == key.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.contains("\0"), !value.contains("\0"),
                  key.rangeOfCharacter(from: .newlines) == nil,
                  value.rangeOfCharacter(from: .newlines) == nil,
                  value == value.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
            else { throw Failure.invalidData }
        }
        if snapshot.isEmpty {
            if unlink(self.url.path) != 0 {
                if errno == ENOENT {
                    return Publication(snapshot: [:])
                }
                throw Failure.publicationFailed
            }
            return Publication(
                snapshot: [:], durabilityWarning: !self.synchronizeDirectory(self.url.deletingLastPathComponent()))
        }
        try self.prepareDirectory()
        let temporary = self.url.deletingLastPathComponent()
            .appendingPathComponent(".credentials.\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.publicationFailed }
        defer {
            close(descriptor)
            unlink(temporary.path)
        }
        // Restrict permissions before writing any secret bytes, even with an unusual umask.
        guard fchmod(descriptor, 0o600) == 0 else { throw Failure.publicationFailed }
        let header = "# Peekaboo credentials file\n# This file contains sensitive API keys and should not be shared\n\n"
        let body = snapshot.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        try Data((header + body).utf8).withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count == -1, errno == EINTR {
                    continue
                } else {
                    throw Failure.publicationFailed
                }
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, self.url.path) == 0 else {
            throw Failure.publicationFailed
        }
        return Publication(
            snapshot: snapshot, durabilityWarning: !self.synchronizeDirectory(self.url.deletingLastPathComponent()))
    }

    private func prepareDirectory() throws {
        let directory = self.url.deletingLastPathComponent()
        try Self.createMissingDirectory(directory)
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.unsafePath }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid() else { throw Failure.unsafePath }
        // Tighten an existing directory without granting permissions the owner deliberately removed.
        guard fchmod(descriptor, info.st_mode & 0o700) == 0 else { throw Failure.unsafePath }
    }

    private static func createMissingDirectory(_ directory: URL) throws {
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafePath }
            return
        }
        guard errno == ENOENT else { throw Failure.unsafePath }
        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path else { throw Failure.unsafePath }
        // Resolve existing ancestors (for example macOS /tmp) without changing their permissions.
        var parentInfo = stat()
        if stat(parent.path, &parentInfo) != 0 {
            try Self.createMissingDirectory(parent)
        }
        guard mkdir(directory.path, 0o700) == 0 else { throw Failure.publicationFailed }
        guard Self.syncDirectory(parent.resolvingSymlinksInPath()) else { throw Failure.publicationFailed }
    }

    static func syncDirectory(_ directory: URL) -> Bool {
        // Foundation can retain aliases such as /tmp; syncing directory metadata may follow them.
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return fsync(descriptor) == 0
    }
}
