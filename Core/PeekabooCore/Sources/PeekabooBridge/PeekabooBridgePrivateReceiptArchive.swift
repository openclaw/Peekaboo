import Darwin
import Foundation

enum PeekabooBridgePrivateReceiptArchive {
    static func prepareDirectory(
        _ url: URL,
        createDirectory: (String, mode_t) -> Int32 = { mkdir($0, $1) }) throws
    {
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else {
            throw PeekabooBridgeOperationReceiptError.unsafeArchive(url.path)
        }
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            guard self.isPrivateDirectory(existing) else {
                throw PeekabooBridgeOperationReceiptError.unsafeArchive(url.path)
            }
            try self.fsyncDirectory(
                self.resolvedDirectory(parent),
                errorPath: url.path)
            return
        }
        guard errno == ENOENT else {
            throw PeekabooBridgeOperationReceiptError.unsafeArchive(url.path)
        }

        var parentIsDirectory = ObjCBool(false)
        if !FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory) {
            try self.prepareDirectory(parent, createDirectory: createDirectory)
            parentIsDirectory = false
            guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory) else {
                throw PeekabooBridgeOperationReceiptError.unsafeArchive(parent.path)
            }
        }
        guard parentIsDirectory.boolValue else {
            throw PeekabooBridgeOperationReceiptError.unsafeArchive(parent.path)
        }
        let resolvedParent = try self.resolvedDirectory(parent)
        let creationResult = createDirectory(url.path, S_IRWXU)
        let creationError = errno
        if creationResult != 0 {
            var racedDirectory = stat()
            guard creationError == EEXIST,
                  lstat(url.path, &racedDirectory) == 0,
                  self.isPrivateDirectory(racedDirectory)
            else {
                throw PeekabooBridgeOperationReceiptError.unsafeArchive(url.path)
            }
            try self.fsyncDirectory(resolvedParent, errorPath: url.path)
            return
        }
        guard chmod(url.path, S_IRWXU) == 0 else {
            throw PeekabooBridgeOperationReceiptError.unsafeArchive(url.path)
        }

        var info = stat()
        guard lstat(url.path, &info) == 0,
              self.isPrivateDirectory(info)
        else {
            throw PeekabooBridgeOperationReceiptError.unsafeArchive(url.path)
        }
        try self.fsyncDirectory(resolvedParent, errorPath: url.path)
    }

    static func writeAtomically(_ data: Data, to destination: URL) throws {
        try self.prepareDirectory(destination.deletingLastPathComponent())
        let temporary = self.temporaryURL(for: destination)
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw PeekabooBridgeOperationReceiptError.archiveWriteFailed(String(cString: strerror(errno)))
        }
        var shouldRemoveTemporary = true
        defer {
            close(descriptor)
            if shouldRemoveTemporary {
                unlink(temporary.path)
            }
        }

        do {
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw PeekabooBridgeOperationReceiptError.archiveWriteFailed(String(cString: strerror(errno)))
            }
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                    if count > 0 {
                        offset += count
                    } else if count == -1, errno == EINTR {
                        continue
                    } else {
                        throw PeekabooBridgeOperationReceiptError.archiveWriteFailed(
                            String(cString: strerror(errno)))
                    }
                }
            }
            guard fsync(descriptor) == 0 else {
                throw PeekabooBridgeOperationReceiptError.archiveWriteFailed(String(cString: strerror(errno)))
            }
            guard renameatx_np(
                AT_FDCWD,
                temporary.path,
                AT_FDCWD,
                destination.path,
                UInt32(RENAME_EXCL)) == 0
            else {
                throw PeekabooBridgeOperationReceiptError.archiveWriteFailed(String(cString: strerror(errno)))
            }
            shouldRemoveTemporary = false
            try self.fsyncDirectory(
                destination.deletingLastPathComponent(),
                errorPath: destination.path)
        } catch let error as PeekabooBridgeOperationReceiptError {
            throw error
        } catch {
            throw PeekabooBridgeOperationReceiptError.archiveWriteFailed(error.localizedDescription)
        }
    }

    static func temporaryURL(for destination: URL, nonce: UUID = UUID()) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(nonce.uuidString.lowercased()).tmp")
    }

    private static func fsyncDirectory(_ directory: URL, errorPath: String) throws {
        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw PeekabooBridgeOperationReceiptError.archiveWriteFailed(
                "\(errorPath): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw PeekabooBridgeOperationReceiptError.archiveWriteFailed(
                "\(errorPath): \(String(cString: strerror(errno)))")
        }
    }

    private static func resolvedDirectory(_ directory: URL) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = directory.path.withCString { path in
            buffer.withUnsafeMutableBufferPointer { realpath(path, $0.baseAddress) }
        }
        guard resolved != nil else {
            throw PeekabooBridgeOperationReceiptError.unsafeArchive(directory.path)
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let path = String(bytes: bytes, encoding: .utf8) else {
            throw PeekabooBridgeOperationReceiptError.unsafeArchive(directory.path)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func isPrivateDirectory(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR &&
            info.st_uid == geteuid() &&
            info.st_mode & 0o077 == 0
    }
}
