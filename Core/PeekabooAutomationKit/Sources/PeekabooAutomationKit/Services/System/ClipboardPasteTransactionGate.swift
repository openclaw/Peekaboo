import Darwin
import Foundation

/// A Cmd+V request crossed the point where the receiver may have consumed it,
/// but Peekaboo cannot truthfully claim a verified paste result.
public struct ClipboardPasteOutcomeError: LocalizedError, Sendable {
    public enum Kind: String, Sendable {
        case indeterminate
        case unverified
    }

    public let kind: Kind
    public let causeDescription: String?
    public let clipboardRestoreAttempted: Bool
    public let clipboardRestoreErrorDescription: String?
    public let targetProcessIdentifier: pid_t?

    public init(
        kind: Kind,
        causeDescription: String? = nil,
        clipboardRestoreAttempted: Bool,
        clipboardRestoreErrorDescription: String? = nil,
        targetProcessIdentifier: pid_t? = nil)
    {
        self.kind = kind
        self.causeDescription = causeDescription
        self.clipboardRestoreAttempted = clipboardRestoreAttempted
        self.clipboardRestoreErrorDescription = clipboardRestoreErrorDescription
        self.targetProcessIdentifier = targetProcessIdentifier
    }

    public var errorDescription: String? {
        let headline = switch self.kind {
        case .indeterminate:
            "Paste outcome is indeterminate: Cmd+V may have pasted; do not retry this paste."
        case .unverified:
            "Background paste delivery could not be verified: Cmd+V may have pasted; do not retry this paste."
        }
        let cause = self.causeDescription.map { " Delivery detail: \($0)" } ?? ""
        let restoration = if let clipboardRestoreErrorDescription {
            " Clipboard restoration failed: \(clipboardRestoreErrorDescription)"
        } else if self.clipboardRestoreAttempted {
            " The prior clipboard state was restored before the transaction lock was released."
        } else {
            " The clipboard was not changed by this transaction."
        }
        return headline + cause + restoration + " Observe the target before taking another action."
    }
}

/// Prevents clipboard-backed paste operations in independent clients from observing
/// or overwriting another client's temporary pasteboard payload.
public enum ClipboardPasteTransactionGate {
    static let lockName = "clipboard-paste-transaction"

    enum GateError: LocalizedError, Sendable {
        case fileSystem(operation: String, path: String, message: String)
        case systemCall(operation: String, path: String, code: Int32)
        case unsafeDirectory(path: String)
        case unsafeLockFile(path: String)

        var errorDescription: String? {
            switch self {
            case let .fileSystem(operation, path, message):
                return "Clipboard paste transaction lock failed during \(operation) at \(path): \(message)"
            case let .systemCall(operation, path, code):
                let message = String(cString: strerror(code))
                return "Clipboard paste transaction lock failed during \(operation) at \(path): \(message)"
            case let .unsafeDirectory(path):
                return "Clipboard paste transaction lock directory is unsafe: \(path)"
            case let .unsafeLockFile(path):
                return "Clipboard paste transaction lock is not a regular file owned by the current user: \(path)"
            }
        }
    }

    /// Serializes callers in a shared host before they enter the file-lock wait loop.
    @MainActor private static var isActive = false

    @MainActor
    public static func withExclusiveTransaction<T: Sendable>(
        _ operation: () async throws -> T) async throws -> T
    {
        try await self.withExclusiveTransaction(lockPath: self.defaultLockPath, operation)
    }

    @MainActor
    static func withExclusiveTransaction<T: Sendable>(
        lockPath: String,
        _ operation: () async throws -> T) async throws -> T
    {
        try Task.checkCancellation()
        while self.isActive {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        self.isActive = true
        defer { self.isActive = false }

        let standardizedLockPath = URL(fileURLWithPath: lockPath).standardizedFileURL.path
        try self.prepareLockDirectory(for: standardizedLockPath)

        let fd = open(
            standardizedLockPath,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw GateError.systemCall(operation: "open", path: standardizedLockPath, code: errno)
        }
        defer { close(fd) }

        var fileInfo = stat()
        guard fstat(fd, &fileInfo) == 0 else {
            throw GateError.systemCall(operation: "inspect", path: standardizedLockPath, code: errno)
        }
        guard fileInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fileInfo.st_uid == geteuid()
        else {
            throw GateError.unsafeLockFile(path: standardizedLockPath)
        }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else {
            throw GateError.systemCall(operation: "secure", path: standardizedLockPath, code: errno)
        }

        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                throw GateError.systemCall(operation: "flock", path: standardizedLockPath, code: errno)
            }

            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        defer { flock(fd, LOCK_UN) }

        try Task.checkCancellation()
        return try await operation()
    }

    static var defaultLockPath: String {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("Peekaboo", isDirectory: true)
            .appendingPathComponent("\(self.lockName).lock", isDirectory: false)
            .standardizedFileURL.path
    }

    private static func prepareLockDirectory(for lockPath: String) throws {
        let directory = URL(fileURLWithPath: lockPath).deletingLastPathComponent().standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: S_IRWXU)])
        } catch {
            throw GateError.fileSystem(
                operation: "prepare",
                path: directory.path,
                message: error.localizedDescription)
        }

        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0 else {
            throw GateError.systemCall(operation: "inspect", path: directory.path, code: errno)
        }
        let writableByAnotherUser = directoryInfo.st_mode & mode_t(S_IWGRP | S_IWOTH) != 0
        guard directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryInfo.st_uid == geteuid(),
              !writableByAnotherUser
        else {
            throw GateError.unsafeDirectory(path: directory.path)
        }
    }

    /// Compatibility entry point for callers that predate `SystemIdentityResolver`.
    public static func processStartIdentity(_ processIdentifier: pid_t) -> UInt64? {
        SystemIdentityResolver.processStartIdentity(processIdentifier)
    }

    /// Waits for the receiving application to consume Cmd+V without inheriting caller cancellation.
    public static func waitForPasteConsumption(milliseconds: Int) async {
        guard milliseconds > 0 else { return }
        let settle = Task.detached {
            try? await Task.sleep(for: .milliseconds(milliseconds))
        }
        await settle.value
    }
}
