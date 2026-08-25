import Darwin
import Foundation

public enum StableRegularFileReadError: LocalizedError, Equatable, Sendable {
    case invalidLimit
    case unavailable(String)
    case unsafeFile(String)
    case oversized(String, limit: Int)
    case changedDuringRead(String)
    case readFailed(String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidLimit:
            "The stable-file read limit must be positive."
        case let .unavailable(path):
            "The file is unavailable: \(path)"
        case let .unsafeFile(path):
            "The file is not a safe owner-controlled regular file: \(path)"
        case let .oversized(path, limit):
            "The file exceeds the \(limit)-byte stable-read limit: \(path)"
        case let .changedDuringRead(path):
            "The file changed while it was being read: \(path)"
        case let .readFailed(path, code):
            "The file could not be read (errno \(code)): \(path)"
        }
    }
}

/// Race-safe reader for small authority files whose path and bytes must describe one stable inode.
///
/// The live implementation refuses symlinks, special files, foreign ownership, group/world write
/// access, replacement, truncation, growth, and metadata changes during the read. Callers still own
/// the semantic validation of the returned bytes.
public struct StableRegularFileReader: Sendable {
    public typealias Read = @Sendable (_ url: URL, _ maximumByteCount: Int) throws -> Data

    public let read: Read

    public init(read: @escaping Read) {
        self.read = read
    }

    public static let live = StableRegularFileReader { url, maximumByteCount in
        try Self.readStableRegularFile(
            at: url,
            maximumByteCount: maximumByteCount,
            expectedOwner: geteuid())
    }

    static func readStableRegularFile(
        at url: URL,
        maximumByteCount: Int,
        expectedOwner: uid_t,
        afterRead: () -> Void = {}) throws -> Data
    {
        guard maximumByteCount > 0 else {
            throw StableRegularFileReadError.invalidLimit
        }
        let path = url.path
        var pathBefore = stat()
        guard lstat(path, &pathBefore) == 0 else {
            throw StableRegularFileReadError.unavailable(path)
        }
        try Self.requireSafe(pathBefore, path: path, expectedOwner: expectedOwner)
        guard pathBefore.st_size <= maximumByteCount else {
            throw StableRegularFileReadError.oversized(path, limit: maximumByteCount)
        }

        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw StableRegularFileReadError.unsafeFile(path)
            }
            throw StableRegularFileReadError.readFailed(path, code: errno)
        }
        defer { close(descriptor) }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else {
            throw StableRegularFileReadError.readFailed(path, code: errno)
        }
        try Self.requireSafe(opened, path: path, expectedOwner: expectedOwner)
        guard Self.fingerprint(pathBefore) == Self.fingerprint(opened) else {
            throw StableRegularFileReadError.changedDuringRead(path)
        }

        let expectedSize = Int(opened.st_size)
        var data = Data()
        data.reserveCapacity(expectedSize)
        var buffer = [UInt8](repeating: 0, count: min(max(expectedSize, 1), 4096))
        while data.count < expectedSize {
            let requested = min(buffer.count, expectedSize - data.count)
            let count = Darwin.read(descriptor, &buffer, requested)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            if count == 0 {
                throw StableRegularFileReadError.changedDuringRead(path)
            }
            throw StableRegularFileReadError.readFailed(path, code: errno)
        }

        var extraByte: UInt8 = 0
        while true {
            let extraCount = Darwin.read(descriptor, &extraByte, 1)
            if extraCount < 0, errno == EINTR {
                continue
            }
            guard extraCount == 0 else {
                if extraCount > 0 {
                    throw StableRegularFileReadError.changedDuringRead(path)
                }
                throw StableRegularFileReadError.readFailed(path, code: errno)
            }
            break
        }

        afterRead()

        var openedAfter = stat()
        var pathAfter = stat()
        guard fstat(descriptor, &openedAfter) == 0,
              lstat(path, &pathAfter) == 0
        else {
            throw StableRegularFileReadError.changedDuringRead(path)
        }
        guard Self.fingerprint(opened) == Self.fingerprint(openedAfter),
              Self.fingerprint(opened) == Self.fingerprint(pathAfter)
        else {
            throw StableRegularFileReadError.changedDuringRead(path)
        }
        return data
    }

    private static func requireSafe(_ info: stat, path: String, expectedOwner: uid_t) throws {
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == expectedOwner,
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0
        else {
            throw StableRegularFileReadError.unsafeFile(path)
        }
    }

    private struct Fingerprint: Equatable {
        let device: dev_t
        let inode: ino_t
        let owner: uid_t
        let mode: mode_t
        let linkCount: nlink_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }

    private static func fingerprint(_ info: stat) -> Fingerprint {
        Fingerprint(
            device: info.st_dev,
            inode: info.st_ino,
            owner: info.st_uid,
            mode: info.st_mode,
            linkCount: info.st_nlink,
            size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec,
            changedSeconds: info.st_ctimespec.tv_sec,
            changedNanoseconds: info.st_ctimespec.tv_nsec)
    }
}
