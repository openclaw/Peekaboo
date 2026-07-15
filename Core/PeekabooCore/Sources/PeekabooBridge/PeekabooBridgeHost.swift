import Darwin
import Foundation
import OSLog
import Security

public enum PeekabooBridgeHostError: Error, LocalizedError, Sendable {
    case socketAlreadyOwned(path: String)
    case unsafeLeaseFile(path: String)
    case socketPathIsNotSocket(path: String)
    case socketPathTooLong(path: String)
    case systemCallFailed(operation: String, path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case let .socketAlreadyOwned(path):
            "Bridge socket is already owned by another host: \(path)"
        case let .unsafeLeaseFile(path):
            "Refusing to use an unsafe bridge lease file: \(path)"
        case let .socketPathIsNotSocket(path):
            "Refusing to replace a non-socket bridge path: \(path)"
        case let .socketPathTooLong(path):
            "Bridge socket path is too long: \(path)"
        case let .systemCallFailed(operation, path, code):
            "\(operation) failed for \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// Lightweight UNIX-domain socket host for Peekaboo automation.
///
/// This is a single-request-per-connection protocol: clients write one JSON request then half-close,
/// the host replies with one JSON response and closes.
public final actor PeekabooBridgeHost {
    private struct SocketIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct SocketStatus: Equatable {
        let identity: SocketIdentity
        let mode: mode_t
        let ownerUID: uid_t

        var isSocket: Bool {
            (self.mode & S_IFMT) == S_IFSOCK
        }
    }

    private struct ProcessMetadata {
        let ownerUID: uid_t
        let status: UInt32
    }

    private enum LegacySocketOwnerState {
        case held
        case unheld
        case indeterminate
    }

    private enum LeaseMarkerState {
        case empty
        case identity(SocketIdentity)
        case incomplete
        case invalid
    }

    private struct LeaseMarkerSnapshot {
        let state: LeaseMarkerState
    }

    private struct SocketLease {
        let fd: Int32
        let recordedIdentity: SocketIdentity?
    }

    private actor ConnectionTracker {
        private var activeCount = 0
        private var idleContinuations: [CheckedContinuation<Void, Never>] = []

        func begin() {
            self.activeCount += 1
        }

        func end() {
            self.activeCount = max(0, self.activeCount - 1)
            guard self.activeCount == 0 else { return }
            let continuations = self.idleContinuations
            self.idleContinuations.removeAll()
            continuations.forEach { $0.resume() }
        }

        func waitForIdle() async {
            guard self.activeCount > 0 else { return }
            await withCheckedContinuation { continuation in
                self.idleContinuations.append(continuation)
            }
        }
    }

    private nonisolated static let logger = Logger(subsystem: "boo.peekaboo.bridge", category: "host")
    private nonisolated static let leaseMarkerPrefix = "peekaboo-bridge-lease-v1"

    private var listenFD: Int32 = -1
    private var leaseFD: Int32 = -1
    private var socketIdentity: SocketIdentity?
    private var acceptTask: Task<Void, Never>?
    private let connectionTracker = ConnectionTracker()

    private let socketPath: String
    private let maxMessageBytes: Int
    private let allowedTeamIDs: Set<String>
    private let requestTimeoutSec: TimeInterval
    private let server: PeekabooBridgeServer

    public init(
        socketPath: String = PeekabooBridgeConstants.peekabooSocketPath,
        server: PeekabooBridgeServer,
        maxMessageBytes: Int = 64 * 1024 * 1024,
        allowedTeamIDs: Set<String> = PeekabooBridgeConstants.trustedReleaseTeamIDs,
        requestTimeoutSec: TimeInterval = PeekabooBridgeConstants.defaultRequestTimeoutSeconds)
    {
        self.socketPath = socketPath
        self.server = server
        self.maxMessageBytes = maxMessageBytes
        self.allowedTeamIDs = allowedTeamIDs
        self.requestTimeoutSec = requestTimeoutSec
    }

    public func start() {
        do {
            try self.startChecked()
        } catch {
            Self.logger.error(
                "Failed to start bridge host at \(self.socketPath, privacy: .public): \(error.localizedDescription)")
        }
    }

    public func startChecked() throws {
        guard self.listenFD == -1 else { return }

        let path = self.socketPath
        let fm = FileManager.default

        let parent = (path as NSString).deletingLastPathComponent
        let dir = parent.isEmpty ? "." : parent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let lease = try Self.acquireLease(path: path)
        do {
            try Self.clearLeaseIdentity(fd: lease.fd, path: path)
            let (fd, identity) = try Self.makeListeningSocket(
                path: path,
                recoverableIdentity: lease.recordedIdentity,
                leaseFD: lease.fd)
            self.listenFD = fd
            self.leaseFD = lease.fd
            self.socketIdentity = identity
        } catch {
            flock(lease.fd, LOCK_UN)
            close(lease.fd)
            throw error
        }

        let fd = self.listenFD

        let server = self.server
        let allowedTeamIDs = self.allowedTeamIDs
        let maxMessageBytes = self.maxMessageBytes
        let requestTimeoutSec = self.requestTimeoutSec
        let connectionTracker = self.connectionTracker

        self.acceptTask = Task.detached(priority: .userInitiated) {
            await Self.acceptLoop(
                listenFD: fd,
                server: server,
                allowedTeamIDs: allowedTeamIDs,
                maxMessageBytes: maxMessageBytes,
                requestTimeoutSec: requestTimeoutSec,
                connectionTracker: connectionTracker)
        }
    }

    public func stop() async {
        let acceptTask = self.acceptTask
        acceptTask?.cancel()
        self.acceptTask = nil
        if self.listenFD != -1 {
            close(self.listenFD)
            self.listenFD = -1
        }
        await acceptTask?.value
        await self.connectionTracker.waitForIdle()
        var canClearLeaseIdentity = self.socketIdentity == nil
        if let identity = self.socketIdentity {
            do {
                _ = try Self.removeOwnedSocket(
                    path: self.socketPath,
                    expectedIdentity: identity)
                canClearLeaseIdentity = true
            } catch {
                Self.logger.error(
                    """
                    Failed to remove bridge socket at \(self.socketPath, privacy: .public): \
                    \(error.localizedDescription)
                    """)
            }
        }
        self.socketIdentity = nil
        if self.leaseFD != -1 {
            if canClearLeaseIdentity {
                do {
                    try Self.clearLeaseIdentity(fd: self.leaseFD, path: self.socketPath)
                } catch {
                    Self.logger.error(
                        """
                        Failed to clear bridge lease at \(self.socketPath, privacy: .public): \
                        \(error.localizedDescription)
                        """)
                }
            }
            flock(self.leaseFD, LOCK_UN)
            close(self.leaseFD)
            self.leaseFD = -1
        }
    }

    private nonisolated static func acquireLease(path: String) throws -> SocketLease {
        let leasePath = "\(path).lock"
        var created = true
        var fd = open(
            leasePath,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        if fd < 0, errno == EEXIST {
            created = false
            fd = open(leasePath, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            if errno == ELOOP {
                throw PeekabooBridgeHostError.unsafeLeaseFile(path: leasePath)
            }
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "open",
                path: leasePath,
                code: errno)
        }
        var leaseInfo = stat()
        guard fstat(fd, &leaseInfo) == 0 else {
            let code = errno
            close(fd)
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "fstat",
                path: leasePath,
                code: code)
        }
        guard (leaseInfo.st_mode & S_IFMT) == S_IFREG,
              leaseInfo.st_uid == geteuid(),
              leaseInfo.st_nlink == 1
        else {
            close(fd)
            throw PeekabooBridgeHostError.unsafeLeaseFile(path: leasePath)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK {
                throw PeekabooBridgeHostError.socketAlreadyOwned(path: path)
            }
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "flock",
                path: leasePath,
                code: code)
        }

        let markerSnapshot: LeaseMarkerSnapshot
        do {
            markerSnapshot = try self.readLeaseMarker(fd: fd, path: leasePath)
        } catch {
            flock(fd, LOCK_UN)
            close(fd)
            throw error
        }
        if !created, case .invalid = markerSnapshot.state {
            flock(fd, LOCK_UN)
            close(fd)
            throw PeekabooBridgeHostError.unsafeLeaseFile(path: leasePath)
        }

        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            flock(fd, LOCK_UN)
            close(fd)
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "fchmod",
                path: leasePath,
                code: code)
        }

        let recordedIdentity: SocketIdentity? = switch markerSnapshot.state {
        case .empty, .incomplete, .invalid:
            nil
        case let .identity(identity):
            identity
        }
        return SocketLease(
            fd: fd,
            recordedIdentity: recordedIdentity)
    }

    private nonisolated static func makeListeningSocket(
        path: String,
        recoverableIdentity: SocketIdentity?,
        leaseFD: Int32) throws -> (Int32, SocketIdentity)
    {
        _ = try self.socketAddress(path: path)
        let recoverableStatus = try self.recoverableSocketStatus(
            path: path,
            recoverableIdentity: recoverableIdentity)

        let temporaryPath = try self.temporarySocketPath(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "socket",
                path: path,
                code: errno)
        }

        var boundIdentity: SocketIdentity?
        do {
            try PeekabooBridgeSocketIO.setCloseOnExec(fd)
            let address = try self.socketAddress(path: temporaryPath)
            var localAddress = address
            let length = socklen_t(MemoryLayout.size(ofValue: localAddress))
            let bindResult = withUnsafePointer(to: &localAddress) {
                Darwin.bind(fd, UnsafePointer<sockaddr>(OpaquePointer($0)), length)
            }
            guard bindResult == 0 else {
                throw PeekabooBridgeHostError.systemCallFailed(
                    operation: "bind",
                    path: temporaryPath,
                    code: errno)
            }

            guard let temporaryStatus = self.socketStatus(path: temporaryPath),
                  temporaryStatus.isSocket
            else {
                throw PeekabooBridgeHostError.systemCallFailed(
                    operation: "lstat",
                    path: temporaryPath,
                    code: errno)
            }
            boundIdentity = temporaryStatus.identity

            guard chmod(temporaryPath, S_IRUSR | S_IWUSR) == 0 else {
                throw PeekabooBridgeHostError.systemCallFailed(
                    operation: "chmod",
                    path: temporaryPath,
                    code: errno)
            }
            guard let permissionedStatus = self.socketStatus(path: temporaryPath),
                  permissionedStatus.isSocket,
                  permissionedStatus.identity == temporaryStatus.identity
            else {
                throw PeekabooBridgeHostError.socketAlreadyOwned(path: temporaryPath)
            }
            guard listen(fd, SOMAXCONN) == 0 else {
                throw PeekabooBridgeHostError.systemCallFailed(
                    operation: "listen",
                    path: temporaryPath,
                    code: errno)
            }
            try self.publishSocket(
                temporaryPath: temporaryPath,
                finalPath: path,
                temporaryStatus: temporaryStatus,
                replacing: recoverableStatus)

            guard let publishedStatus = self.socketStatus(path: path),
                  publishedStatus.isSocket,
                  publishedStatus.identity == temporaryStatus.identity
            else {
                throw PeekabooBridgeHostError.socketAlreadyOwned(path: path)
            }
            try self.recordLeaseIdentity(
                temporaryStatus.identity,
                fd: leaseFD,
                path: path)
            return (fd, temporaryStatus.identity)
        } catch {
            try? self.clearLeaseIdentity(fd: leaseFD, path: path)
            if let boundIdentity {
                for candidate in [temporaryPath, path] {
                    _ = try? self.removeOwnedSocket(
                        path: candidate,
                        expectedIdentity: boundIdentity)
                }
            }
            close(fd)
            throw error
        }
    }

    private nonisolated static func recoverableSocketStatus(
        path: String,
        recoverableIdentity: SocketIdentity?) throws -> SocketStatus?
    {
        guard let status = self.socketStatus(path: path) else {
            let code = errno
            if code == ENOENT {
                return nil
            }
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "lstat",
                path: path,
                code: code)
        }
        guard status.isSocket else {
            throw PeekabooBridgeHostError.socketPathIsNotSocket(path: path)
        }
        let canRecoverLegacySocket = recoverableIdentity == nil &&
            status.ownerUID == geteuid() &&
            self.legacySocketOwnerState(
                path: path,
                targetIdentity: status.identity,
                ownerUID: status.ownerUID) == .unheld
        guard status.identity == recoverableIdentity || canRecoverLegacySocket else {
            throw PeekabooBridgeHostError.socketAlreadyOwned(path: path)
        }
        return status
    }

    private nonisolated static func temporarySocketPath(for path: String) throws -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let directory = parent.isEmpty ? "." : parent
        let separatorBytes = directory == "/" ? 0 : 1
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        let availableBytes = capacity - 1 - directory.utf8.count - separatorBytes
        guard availableBytes > 0 else {
            throw PeekabooBridgeHostError.socketPathTooLong(path: path)
        }

        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let filenameLength = min(16, availableBytes)
        let finalFilename = (path as NSString).lastPathComponent
        for _ in 0..<128 {
            let filename = String((0..<filenameLength).map { _ in alphabet.randomElement()! })
            guard filename != finalFilename else { continue }
            let candidate = (directory as NSString).appendingPathComponent(filename)
            guard self.socketStatus(path: candidate) == nil, errno == ENOENT else { continue }
            _ = try self.socketAddress(path: candidate)
            return candidate
        }

        throw PeekabooBridgeHostError.systemCallFailed(
            operation: "temporary socket path",
            path: path,
            code: EEXIST)
    }

    private nonisolated static func throwExistingSocketError(path: String) throws -> Never {
        guard let status = self.socketStatus(path: path) else {
            let code = errno
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "lstat",
                path: path,
                code: code)
        }
        guard status.isSocket else {
            throw PeekabooBridgeHostError.socketPathIsNotSocket(path: path)
        }
        throw PeekabooBridgeHostError.socketAlreadyOwned(path: path)
    }

    private nonisolated static func publishSocket(
        temporaryPath: String,
        finalPath: String,
        temporaryStatus: SocketStatus,
        replacing recoverableStatus: SocketStatus?) throws
    {
        guard let recoverableStatus else {
            let publishResult = renameatx_np(
                AT_FDCWD,
                temporaryPath,
                AT_FDCWD,
                finalPath,
                UInt32(RENAME_EXCL))
            guard publishResult == 0 else {
                let code = errno
                if code == EEXIST {
                    try self.throwExistingSocketError(path: finalPath)
                }
                throw PeekabooBridgeHostError.systemCallFailed(
                    operation: "renameatx_np",
                    path: finalPath,
                    code: code)
            }
            return
        }

        let swapResult = renameatx_np(
            AT_FDCWD,
            temporaryPath,
            AT_FDCWD,
            finalPath,
            UInt32(RENAME_SWAP))
        if swapResult != 0 {
            let swapCode = errno
            if swapCode == ENOENT {
                let publishResult = renameatx_np(
                    AT_FDCWD,
                    temporaryPath,
                    AT_FDCWD,
                    finalPath,
                    UInt32(RENAME_EXCL))
                if publishResult == 0 {
                    return
                }
                let publishCode = errno
                if publishCode == EEXIST {
                    try self.throwExistingSocketError(path: finalPath)
                }
                throw PeekabooBridgeHostError.systemCallFailed(
                    operation: "renameatx_np",
                    path: finalPath,
                    code: publishCode)
            }
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "renameatx_np",
                path: finalPath,
                code: swapCode)
        }

        let publishedStatus = self.socketStatus(path: finalPath)
        let displacedStatus = self.socketStatus(path: temporaryPath)
        guard publishedStatus?.isSocket == true,
              publishedStatus?.identity == temporaryStatus.identity,
              displacedStatus == recoverableStatus
        else {
            let restoreResult = renameatx_np(
                AT_FDCWD,
                temporaryPath,
                AT_FDCWD,
                finalPath,
                UInt32(RENAME_SWAP))
            guard restoreResult == 0 else {
                throw PeekabooBridgeHostError.systemCallFailed(
                    operation: "renameatx_np restore",
                    path: finalPath,
                    code: errno)
            }
            try self.throwExistingSocketError(path: finalPath)
        }

        guard unlink(temporaryPath) == 0 else {
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "unlink quarantined socket",
                path: temporaryPath,
                code: errno)
        }
        self.logger.info(
            """
            Replaced stale bridge socket path=\(finalPath, privacy: .public) \
            inode=\(recoverableStatus.identity.inode, privacy: .public)
            """)
    }

    @discardableResult
    private nonisolated static func removeOwnedSocket(
        path: String,
        expectedIdentity: SocketIdentity) throws -> Bool
    {
        guard self.socketStatus(path: path) != nil else {
            let code = errno
            if code == ENOENT {
                return true
            }
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "lstat",
                path: path,
                code: code)
        }

        let (placeholderPath, placeholderIdentity) = try self.createPlaceholder(for: path)
        var placeholderLocation: String? = placeholderPath
        defer {
            if let placeholderLocation,
               self.socketStatus(path: placeholderLocation)?.identity == placeholderIdentity
            {
                unlink(placeholderLocation)
            }
        }

        let swapResult = renameatx_np(
            AT_FDCWD,
            placeholderPath,
            AT_FDCWD,
            path,
            UInt32(RENAME_SWAP))
        guard swapResult == 0 else {
            let code = errno
            if code == ENOENT {
                return true
            }
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "renameatx_np",
                path: path,
                code: code)
        }
        placeholderLocation = path

        guard self.socketStatus(path: placeholderPath)?.identity == expectedIdentity else {
            let restoreResult = renameatx_np(
                AT_FDCWD,
                placeholderPath,
                AT_FDCWD,
                path,
                UInt32(RENAME_SWAP))
            guard restoreResult == 0 else {
                throw PeekabooBridgeHostError.systemCallFailed(
                    operation: "renameatx_np restore",
                    path: path,
                    code: errno)
            }
            placeholderLocation = placeholderPath
            return false
        }

        let cleanupPath = try self.temporarySocketPath(for: path)
        let movePlaceholderResult = renameatx_np(
            AT_FDCWD,
            path,
            AT_FDCWD,
            cleanupPath,
            UInt32(RENAME_EXCL))
        guard movePlaceholderResult == 0 else {
            let code = errno
            let restoreResult = renameatx_np(
                AT_FDCWD,
                placeholderPath,
                AT_FDCWD,
                path,
                UInt32(RENAME_SWAP))
            if restoreResult == 0 {
                placeholderLocation = placeholderPath
            }
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "renameatx_np quarantine",
                path: path,
                code: code)
        }
        placeholderLocation = cleanupPath

        guard unlink(placeholderPath) == 0 else {
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "unlink quarantined socket",
                path: placeholderPath,
                code: errno)
        }
        guard unlink(cleanupPath) == 0 else {
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "unlink socket placeholder",
                path: cleanupPath,
                code: errno)
        }
        placeholderLocation = nil
        return true
    }

    private nonisolated static func createPlaceholder(
        for path: String) throws -> (path: String, identity: SocketIdentity)
    {
        for _ in 0..<128 {
            let placeholderPath = try self.temporarySocketPath(for: path)
            let fd = open(
                placeholderPath,
                O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR)
            if fd < 0, errno == EEXIST {
                continue
            }
            guard fd >= 0 else {
                throw PeekabooBridgeHostError.systemCallFailed(
                    operation: "open placeholder",
                    path: placeholderPath,
                    code: errno)
            }
            close(fd)

            guard let status = self.socketStatus(path: placeholderPath),
                  !status.isSocket,
                  status.ownerUID == geteuid()
            else {
                unlink(placeholderPath)
                throw PeekabooBridgeHostError.unsafeLeaseFile(path: placeholderPath)
            }
            return (placeholderPath, status.identity)
        }

        throw PeekabooBridgeHostError.systemCallFailed(
            operation: "create placeholder",
            path: path,
            code: EEXIST)
    }

    private nonisolated static func socketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = path.withCString { strlcpy(&address.sun_path.0, $0, capacity) }
        guard copied < capacity else {
            throw PeekabooBridgeHostError.socketPathTooLong(path: path)
        }
        address.sun_len = UInt8(MemoryLayout.size(ofValue: address))
        return address
    }

    private nonisolated static func readLeaseMarker(fd: Int32, path: String) throws -> LeaseMarkerSnapshot {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "fstat",
                path: path,
                code: errno)
        }
        guard info.st_size > 0 else {
            return LeaseMarkerSnapshot(state: .empty)
        }
        guard info.st_size <= 64 * 1024 else {
            return LeaseMarkerSnapshot(state: .invalid)
        }

        var buffer = [UInt8](repeating: 0, count: Int(info.st_size))
        var bytesRead = 0
        while bytesRead < buffer.count {
            let result = buffer.withUnsafeMutableBytes { bytes in
                pread(
                    fd,
                    bytes.baseAddress!.advanced(by: bytesRead),
                    bytes.count - bytesRead,
                    off_t(bytesRead))
            }
            if result > 0 {
                bytesRead += result
                continue
            }
            if result == -1, errno == EINTR {
                continue
            }
            if result == 0 {
                return LeaseMarkerSnapshot(state: .invalid)
            }
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "pread",
                path: path,
                code: errno)
        }

        guard let contents = String(bytes: buffer, encoding: .utf8) else {
            return LeaseMarkerSnapshot(state: .invalid)
        }

        var lastIdentity: SocketIdentity?
        var sawIncompleteRecord = false
        let records = contents.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, record) in records.enumerated() {
            if record.isEmpty {
                continue
            }
            if let identity = self.parseLeaseIdentity(record) {
                lastIdentity = identity
                continue
            }
            if index == records.indices.last, self.isIncompleteLeaseRecord(record) {
                sawIncompleteRecord = true
                continue
            }
            return LeaseMarkerSnapshot(state: .invalid)
        }
        if let lastIdentity {
            return LeaseMarkerSnapshot(state: .identity(lastIdentity))
        }
        return LeaseMarkerSnapshot(state: sawIncompleteRecord ? .incomplete : .empty)
    }

    private nonisolated static func parseLeaseIdentity(_ record: Substring) -> SocketIdentity? {
        let fields = record.split(whereSeparator: \.isWhitespace)
        guard fields.count == 3,
              fields[0] == Substring(self.leaseMarkerPrefix),
              let device = UInt64(fields[1]),
              let inode = UInt64(fields[2]),
              let convertedDevice = dev_t(exactly: device),
              let convertedInode = ino_t(exactly: inode)
        else {
            return nil
        }
        return SocketIdentity(device: convertedDevice, inode: convertedInode)
    }

    private nonisolated static func isIncompleteLeaseRecord(_ record: Substring) -> Bool {
        let prefix = Substring(self.leaseMarkerPrefix)
        if prefix.starts(with: record) {
            return true
        }
        guard record.hasPrefix(prefix) else { return false }

        let suffix = record.dropFirst(prefix.count)
        guard suffix.allSatisfy({ $0.isWhitespace || $0.isNumber }) else { return false }
        let fields = suffix.split(whereSeparator: \.isWhitespace)
        guard fields.count <= 2 else { return false }
        if let deviceField = fields.first {
            guard let device = UInt64(deviceField), dev_t(exactly: device) != nil else { return false }
        }
        if fields.count == 2 {
            guard let inode = UInt64(fields[1]), ino_t(exactly: inode) != nil else { return false }
        }
        return true
    }

    private nonisolated static func recordLeaseIdentity(
        _ identity: SocketIdentity,
        fd: Int32,
        path: String) throws
    {
        let marker = "\(self.leaseMarkerPrefix) \(UInt64(identity.device)) \(UInt64(identity.inode))\n"
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "fstat",
                path: "\(path).lock",
                code: errno)
        }
        guard info.st_size == 0 else {
            throw PeekabooBridgeHostError.unsafeLeaseFile(path: "\(path).lock")
        }

        let bytes = Array(marker.utf8)

        var written = 0
        while written < bytes.count {
            let result = bytes.withUnsafeBytes { buffer in
                pwrite(
                    fd,
                    buffer.baseAddress!.advanced(by: written),
                    bytes.count - written,
                    off_t(written))
            }
            if result > 0 {
                written += result
                continue
            }
            if result == -1, errno == EINTR {
                continue
            }
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "pwrite",
                path: "\(path).lock",
                code: errno)
        }

        guard fsync(fd) == 0 else {
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "fsync",
                path: "\(path).lock",
                code: errno)
        }
    }

    private nonisolated static func clearLeaseIdentity(fd: Int32, path: String) throws {
        guard ftruncate(fd, 0) == 0 else {
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "ftruncate",
                path: "\(path).lock",
                code: errno)
        }
        guard fsync(fd) == 0 else {
            throw PeekabooBridgeHostError.systemCallFailed(
                operation: "fsync",
                path: "\(path).lock",
                code: errno)
        }
    }

    private nonisolated static func socketStatus(path: String) -> SocketStatus? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return SocketStatus(
            identity: SocketIdentity(device: info.st_dev, inode: info.st_ino),
            mode: info.st_mode,
            ownerUID: info.st_uid)
    }

    private nonisolated static func legacySocketOwnerState(
        path: String,
        targetIdentity: SocketIdentity,
        ownerUID: uid_t) -> LegacySocketOwnerState
    {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return .indeterminate }

        var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 64)
        let listedCount = proc_listallpids(
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard listedCount > 0, Int(listedCount) < pids.count else { return .indeterminate }

        var inspectionWasIncomplete = false
        for pid in pids.prefix(Int(listedCount)) where pid > 0 {
            guard let process = self.processMetadata(pid: pid) else {
                if kill(pid, 0) == 0 {
                    inspectionWasIncomplete = true
                }
                continue
            }
            guard process.ownerUID == ownerUID, process.status != UInt32(SZOMB) else { continue }

            let descriptorBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard descriptorBytes > 0 else {
                if let current = self.processMetadata(pid: pid),
                   current.ownerUID == ownerUID,
                   current.status != UInt32(SZOMB)
                {
                    inspectionWasIncomplete = true
                }
                continue
            }

            let descriptorCapacity = Int(descriptorBytes) / MemoryLayout<proc_fdinfo>.stride + 16
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: descriptorCapacity)
            let descriptorBufferBytes = Int32(descriptors.count * MemoryLayout<proc_fdinfo>.stride)
            let listedDescriptorBytes = proc_pidinfo(
                pid,
                PROC_PIDLISTFDS,
                0,
                &descriptors,
                descriptorBufferBytes)
            guard listedDescriptorBytes > 0 else {
                if let current = self.processMetadata(pid: pid),
                   current.ownerUID == ownerUID,
                   current.status != UInt32(SZOMB)
                {
                    inspectionWasIncomplete = true
                }
                continue
            }
            guard listedDescriptorBytes < descriptorBufferBytes else {
                inspectionWasIncomplete = true
                continue
            }

            let descriptorCount = Int(listedDescriptorBytes) / MemoryLayout<proc_fdinfo>.stride
            for descriptor in descriptors.prefix(descriptorCount)
                where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET
            {
                var socketInfo = socket_fdinfo()
                let socketInfoSize = Int32(MemoryLayout<socket_fdinfo>.stride)
                let socketInfoResult = proc_pidfdinfo(
                    pid,
                    descriptor.proc_fd,
                    PROC_PIDFDSOCKETINFO,
                    &socketInfo,
                    socketInfoSize)
                guard socketInfoResult == socketInfoSize else {
                    if self.processStillHasSocketDescriptor(pid: pid, fd: descriptor.proc_fd) != false {
                        inspectionWasIncomplete = true
                    }
                    continue
                }
                guard socketInfo.psi.soi_family == AF_UNIX,
                      socketInfo.psi.soi_kind == SOCKINFO_UN
                else {
                    continue
                }

                var address = socketInfo.psi.soi_proto.pri_un.unsi_addr.ua_sun
                let boundPath = withUnsafePointer(to: &address.sun_path.0) {
                    String(cString: $0)
                }
                if boundPath == path {
                    return .held
                }
                if boundPath.hasPrefix("/") {
                    if self.socketStatus(path: boundPath)?.identity == targetIdentity {
                        return .held
                    }
                    continue
                }

                if let currentDirectory = self.processCurrentDirectory(pid: pid) {
                    let baseURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
                    let resolvedPath = URL(
                        fileURLWithPath: boundPath,
                        relativeTo: baseURL).standardizedFileURL.path
                    if self.socketStatus(path: resolvedPath)?.identity == targetIdentity {
                        return .held
                    }
                }

                // The kernel retains a relative UNIX socket name but not the process's bind-time cwd.
                // If the process changed directories, matching the final component is the strongest safe
                // signal available. Treat it as incomplete inspection instead of deleting a possibly live socket.
                if (boundPath as NSString).lastPathComponent == (path as NSString).lastPathComponent {
                    inspectionWasIncomplete = true
                }
            }
        }
        return inspectionWasIncomplete ? .indeterminate : .unheld
    }

    private nonisolated static func processCurrentDirectory(pid: pid_t) -> String? {
        var pathInfo = proc_vnodepathinfo()
        let pathInfoSize = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let result = proc_pidinfo(
            pid,
            PROC_PIDVNODEPATHINFO,
            0,
            &pathInfo,
            pathInfoSize)
        guard result == pathInfoSize else { return nil }

        var path = pathInfo.pvi_cdir.vip_path
        return withUnsafePointer(to: &path.0) { pointer in
            let value = String(cString: pointer)
            return value.isEmpty ? nil : value
        }
    }

    private nonisolated static func processMetadata(pid: pid_t) -> ProcessMetadata? {
        var processInfo = proc_bsdinfo()
        let processInfoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let processInfoResult = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &processInfo,
            processInfoSize)
        if processInfoResult == processInfoSize {
            return ProcessMetadata(ownerUID: processInfo.pbi_uid, status: processInfo.pbi_status)
        }

        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kernelInfo = kinfo_proc()
        var kernelInfoSize = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(
            &mib,
            u_int(mib.count),
            &kernelInfo,
            &kernelInfoSize,
            nil,
            0)
        guard result == 0, kernelInfoSize == MemoryLayout<kinfo_proc>.stride else {
            return nil
        }
        return ProcessMetadata(
            ownerUID: kernelInfo.kp_eproc.e_ucred.cr_uid,
            status: UInt32(kernelInfo.kp_proc.p_stat))
    }

    private nonisolated static func processStillHasSocketDescriptor(pid: pid_t, fd: Int32) -> Bool? {
        let descriptorBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard descriptorBytes > 0 else {
            return self.processMetadata(pid: pid)?.status == UInt32(SZOMB) ? false : nil
        }

        let capacity = Int(descriptorBytes) / MemoryLayout<proc_fdinfo>.stride + 16
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let descriptorBufferBytes = Int32(descriptors.count * MemoryLayout<proc_fdinfo>.stride)
        let listedBytes = proc_pidinfo(
            pid,
            PROC_PIDLISTFDS,
            0,
            &descriptors,
            descriptorBufferBytes)
        guard listedBytes > 0, listedBytes < descriptorBufferBytes else {
            return self.processMetadata(pid: pid)?.status == UInt32(SZOMB) ? false : nil
        }

        let count = Int(listedBytes) / MemoryLayout<proc_fdinfo>.stride
        return descriptors.prefix(count).contains {
            $0.proc_fd == fd && $0.proc_fdtype == PROX_FDTYPE_SOCKET
        }
    }

    private nonisolated static func acceptLoop(
        listenFD: Int32,
        server: PeekabooBridgeServer,
        allowedTeamIDs: Set<String>,
        maxMessageBytes: Int,
        requestTimeoutSec: TimeInterval,
        connectionTracker: ConnectionTracker) async
    {
        while !Task.isCancelled {
            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listenFD, &addr, &len)
            if client < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EBADF || errno == EINVAL {
                    return
                }
                self.logger.error("accept failed: \(errno, privacy: .public)")
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }

            Self.disableSigPipe(fd: client)
            do {
                try PeekabooBridgeSocketIO.configureConnectedSocket(client)
            } catch {
                self.logger.error("failed to configure bridge client socket: \(error.localizedDescription)")
                close(client)
                continue
            }
            await connectionTracker.begin()
            Task.detached(priority: .userInitiated) {
                defer { close(client) }
                await Self.handleClient(
                    fd: client,
                    server: server,
                    allowedTeamIDs: allowedTeamIDs,
                    maxMessageBytes: maxMessageBytes,
                    requestTimeoutSec: requestTimeoutSec)
                await connectionTracker.end()
            }
        }
    }

    private nonisolated static func handleClient(
        fd: Int32,
        server: PeekabooBridgeServer,
        allowedTeamIDs: Set<String>,
        maxMessageBytes: Int,
        requestTimeoutSec: TimeInterval) async
    {
        let peer = self.peerInfoIfAllowed(fd: fd, allowedTeamIDs: allowedTeamIDs)

        do {
            let requestData = try PeekabooBridgeSocketIO.readAll(
                fd: fd,
                maxBytes: maxMessageBytes,
                deadline: Date().addingTimeInterval(requestTimeoutSec))

            guard let peer else {
                let envelope = PeekabooBridgeErrorEnvelope(
                    code: .unauthorizedClient,
                    message: "Bridge client is not authorized",
                    details: """
                    The host rejected the client before processing the request. Ensure the client is signed by an \
                    allowlisted TeamID (\(allowedTeamIDs.sorted().joined(separator: ", "))) or launch the host with \
                    PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS=1 for local development.
                    """)

                let responseData = PeekabooBridgeResponse.encodeError(envelope)
                try PeekabooBridgeSocketIO.writeAll(
                    fd: fd,
                    data: responseData,
                    deadline: Date().addingTimeInterval(requestTimeoutSec))
                return
            }

            let responseData = await server.decodeAndHandle(requestData, peer: peer)

            try PeekabooBridgeSocketIO.writeAll(
                fd: fd,
                data: responseData,
                deadline: Date().addingTimeInterval(requestTimeoutSec))
        } catch {
            self.logger.error("bridge socket request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static func disableSigPipe(fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
    }

    private nonisolated static func peerInfoIfAllowed(fd: Int32, allowedTeamIDs: Set<String>) -> PeekabooBridgePeer? {
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        let r = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize)
        guard r == 0, pid > 0 else { return nil }

        if allowedTeamIDs.isEmpty, let callerUID = self.uid(for: pid), callerUID == getuid() {
            let bundleID = self.bundleIdentifier(pid: pid)
            let teamID = self.teamID(pid: pid)
            return PeekabooBridgePeer(
                processIdentifier: pid,
                userIdentifier: callerUID,
                bundleIdentifier: bundleID,
                teamIdentifier: teamID)
        }

        let teamID = self.teamID(pid: pid)
        if let teamID, allowedTeamIDs.contains(teamID) {
            let bundleID = self.bundleIdentifier(pid: pid)
            let uid = self.uid(for: pid)
            return PeekabooBridgePeer(
                processIdentifier: pid,
                userIdentifier: uid,
                bundleIdentifier: bundleID,
                teamIdentifier: teamID)
        }

        #if DEBUG
        let env = ProcessInfo.processInfo.environment["PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS"]
        if env == "1", let callerUID = self.uid(for: pid), callerUID == getuid() {
            self.logger.warning(
                "allowing unsigned bridge client pid=\(pid, privacy: .public) (debug override)")
            let bundleID = self.bundleIdentifier(pid: pid)
            return PeekabooBridgePeer(
                processIdentifier: pid,
                userIdentifier: callerUID,
                bundleIdentifier: bundleID,
                teamIdentifier: nil)
        }
        #endif

        if let callerUID = self.uid(for: pid) {
            self.logger.error("bridge client rejected pid=\(pid, privacy: .public) uid=\(callerUID, privacy: .public)")
        } else {
            self.logger.error("bridge client rejected pid=\(pid, privacy: .public) (uid unknown)")
        }
        return nil
    }

    private nonisolated static func uid(for pid: pid_t) -> uid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout.size(ofValue: info)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let ok = mib.withUnsafeMutableBufferPointer { mibPtr -> Bool in
            sysctl(mibPtr.baseAddress, u_int(mibPtr.count), &info, &size, nil, 0) == 0
        }
        return ok ? info.kp_eproc.e_ucred.cr_uid : nil
    }

    private nonisolated static func bundleIdentifier(pid: pid_t) -> String? {
        let attrs: NSDictionary = [kSecGuestAttributePid: pid]
        var secCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, SecCSFlags(), &secCode) == errSecSuccess,
              let code = secCode
        else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let sCode = staticCode
        else { return nil }

        var infoCF: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(sCode, flags, &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any]
        else { return nil }

        return info[kSecCodeInfoIdentifier as String] as? String
    }

    private nonisolated static func teamID(pid: pid_t) -> String? {
        let attrs: NSDictionary = [kSecGuestAttributePid: pid]
        var secCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, SecCSFlags(), &secCode) == errSecSuccess,
              let code = secCode
        else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let sCode = staticCode
        else { return nil }

        var infoCF: CFDictionary?
        // `kSecCodeInfoTeamIdentifier` is only included when requesting signing information.
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(sCode, flags, &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any]
        else { return nil }

        if let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String {
            return teamID
        }

        if let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
           let appIdentifier = entitlements["application-identifier"] as? String,
           let prefix = appIdentifier.split(separator: ".").first
        {
            return String(prefix)
        }

        return nil
    }
}
