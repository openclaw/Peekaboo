import Darwin
import Foundation

@MainActor
enum DaemonStartupGate {
    /// Allows normal promotion, shutdown, and rollback phases to finish while still bounding stale holders.
    static let defaultAcquisitionTimeout: Duration = .seconds(60)

    enum GateError: LocalizedError {
        case fileSystem(operation: String, path: String, message: String)
        case systemCall(operation: String, path: String, code: Int32)
        case unsafeLockFile(path: String)
        case timedOut(path: String)

        var errorDescription: String? {
            switch self {
            case let .fileSystem(operation, path, message):
                "Could not \(operation) daemon startup lock at \(path): \(message)"
            case let .systemCall(operation, path, code):
                "Could not \(operation) daemon startup lock at \(path) (errno \(code))"
            case let .unsafeLockFile(path):
                "Daemon startup lock is not a regular file owned by the current user: \(path)"
            case let .timedOut(path):
                "Timed out waiting for another Peekaboo daemon startup to finish (\(path))"
            }
        }
    }

    private static var activeLockPaths: Set<String> = []

    static func withExclusiveStartup<T: Sendable>(
        lockURL: URL = DaemonPaths.daemonStartupLockURL(),
        timeout: Duration = DaemonStartupGate.defaultAcquisitionTimeout,
        retryInterval: Duration = .milliseconds(20),
        operation: (Int32) async throws -> T
    ) async throws -> T {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let lockPath = lockURL.standardizedFileURL.path

        while self.activeLockPaths.contains(lockPath) {
            try await self.waitToRetry(
                clock: clock,
                deadline: deadline,
                retryInterval: retryInterval,
                lockURL: lockURL
            )
        }
        try Task.checkCancellation()
        guard clock.now < deadline else {
            throw GateError.timedOut(path: lockURL.path)
        }
        self.activeLockPaths.insert(lockPath)
        defer { self.activeLockPaths.remove(lockPath) }

        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw GateError.fileSystem(
                operation: "prepare",
                path: lockURL.path,
                message: error.localizedDescription
            )
        }

        let fd = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            S_IRUSR | S_IWUSR
        )
        guard fd >= 0 else {
            throw GateError.systemCall(operation: "open", path: lockURL.path, code: errno)
        }
        defer { close(fd) }

        var fileInfo = stat()
        guard fstat(fd, &fileInfo) == 0 else {
            throw GateError.systemCall(operation: "inspect", path: lockURL.path, code: errno)
        }
        guard fileInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fileInfo.st_uid == geteuid()
        else {
            throw GateError.unsafeLockFile(path: lockURL.path)
        }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else {
            throw GateError.systemCall(operation: "secure", path: lockURL.path, code: errno)
        }

        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR else {
                throw GateError.systemCall(operation: "lock", path: lockURL.path, code: code)
            }
            try await self.waitToRetry(
                clock: clock,
                deadline: deadline,
                retryInterval: retryInterval,
                lockURL: lockURL
            )
        }
        defer { flock(fd, LOCK_UN) }

        try Task.checkCancellation()
        return try await operation(fd)
    }

    private static func waitToRetry(
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant,
        retryInterval: Duration,
        lockURL: URL
    ) async throws {
        try Task.checkCancellation()
        let now = clock.now
        guard now < deadline else {
            throw GateError.timedOut(path: lockURL.path)
        }
        try await Task.sleep(for: min(retryInterval, now.duration(to: deadline)))
        try Task.checkCancellation()
    }
}
