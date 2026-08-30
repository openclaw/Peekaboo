import CryptoKit
import Darwin
import Dispatch
import Foundation
import PeekabooAutomationKit
import Security

// MARK: - Closed launch preparation

struct PeekabooBridgeAgentExecutionPaths: Sendable {
    private struct Identity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
    }

    private final class DirectoryCustody: @unchecked Sendable {
        var runRootDescriptor: Int32
        let runRootIdentity: Identity
        let lock = NSLock()
        var operationReceiptDirectoryDescriptor: Int32?
        var operationReceiptDirectoryIdentity: Identity?

        init(
            runRootDescriptor: Int32,
            runRootIdentity: Identity)
        {
            self.runRootDescriptor = runRootDescriptor
            self.runRootIdentity = runRootIdentity
        }

        deinit {
            self.release()
        }

        func release() {
            self.lock.withLock {
                if let operationReceiptDirectoryDescriptor = self.operationReceiptDirectoryDescriptor {
                    close(operationReceiptDirectoryDescriptor)
                    self.operationReceiptDirectoryDescriptor = nil
                    self.operationReceiptDirectoryIdentity = nil
                }
                if self.runRootDescriptor >= 0 {
                    _ = flock(self.runRootDescriptor, LOCK_UN)
                    close(self.runRootDescriptor)
                    self.runRootDescriptor = -1
                }
            }
        }
    }

    let runRoot: URL
    let coordinationReceipt: URL
    let acknowledgement: URL
    let operationReceiptDirectory: URL
    private let directoryCustody: DirectoryCustody

    static func validateAndPrepare(_ request: PeekabooBridgeAgentExecutionTraceRequest) throws -> Self {
        guard !request.task.isEmpty,
              request.task.first != "-",
              request.task.utf8.count <= PeekabooBridgeAgentExecutionPolicy.maximumTaskBytes,
              !request.task.utf8.contains(0),
              (1...100).contains(request.maxSteps),
              (1...120_000).contains(request.startTimeoutMilliseconds),
              (1...7_200_000).contains(request.runTimeoutMilliseconds)
        else {
            throw PeekabooBridgeAgentExecutionPreReleaseError
                .invalidRequest("task, step, or timeout bounds are invalid")
        }

        let runRoot = URL(fileURLWithPath: request.runRootPath, isDirectory: true)
        let coordinationReceipt = URL(fileURLWithPath: request.coordinationReceiptPath)
        let acknowledgement = URL(fileURLWithPath: request.acknowledgementPath)
        guard request.runRootPath.first == "/",
              request.coordinationReceiptPath.first == "/",
              request.acknowledgementPath.first == "/",
              !request.runRootPath.utf8.contains(0),
              !request.coordinationReceiptPath.utf8.contains(0),
              !request.acknowledgementPath.utf8.contains(0),
              Self.canonicalPath(request.runRootPath) == request.runRootPath,
              runRoot.path == request.runRootPath,
              coordinationReceipt.path == request.coordinationReceiptPath,
              acknowledgement.path == request.acknowledgementPath,
              coordinationReceipt.deletingLastPathComponent().path == runRoot.path,
              acknowledgement.deletingLastPathComponent().path == runRoot.path,
              coordinationReceipt.lastPathComponent == PeekabooBridgeAgentExecutionCoding.coordinationBasename,
              acknowledgement.lastPathComponent == PeekabooBridgeAgentExecutionCoding.acknowledgementBasename,
              coordinationReceipt.path != acknowledgement.path
        else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.unsafeRunRoot(request.runRootPath)
        }

        let runRootDescriptor = open(runRoot.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard runRootDescriptor >= 0 else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.unsafeRunRoot(runRoot.path)
        }
        var descriptorTransferred = false
        defer {
            if !descriptorTransferred {
                close(runRootDescriptor)
            }
        }
        guard flock(runRootDescriptor, LOCK_EX | LOCK_NB) == 0,
              let runRootIdentity = Self.privateDirectoryIdentity(descriptor: runRootDescriptor),
              Self.privateDirectoryIdentity(runRoot.path) == runRootIdentity,
              Self.isAbsent(
                  at: runRootDescriptor,
                  basename: PeekabooBridgeAgentExecutionCoding.coordinationBasename),
              Self.isAbsent(
                  at: runRootDescriptor,
                  basename: PeekabooBridgeAgentExecutionCoding.acknowledgementBasename),
              Self.isAbsent(
                  at: runRootDescriptor,
                  basename: PeekabooBridgeAgentExecutionCoding.operationReceiptDirectoryBasename)
        else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.unsafeRunRoot(request.runRootPath)
        }

        let operationReceiptDirectory = runRoot.appendingPathComponent(
            PeekabooBridgeAgentExecutionCoding.operationReceiptDirectoryBasename,
            isDirectory: true)
        let directoryCustody = DirectoryCustody(
            runRootDescriptor: runRootDescriptor,
            runRootIdentity: runRootIdentity)
        descriptorTransferred = true
        return Self(
            runRoot: runRoot,
            coordinationReceipt: coordinationReceipt,
            acknowledgement: acknowledgement,
            operationReceiptDirectory: operationReceiptDirectory,
            directoryCustody: directoryCustody)
    }

    /// The child carries this future path while blocked in its trusted earliest-entry gate. Create
    /// it only after the connected client has acknowledged the coordination receipt.
    func provisionOperationReceiptDirectoryBeforeRelease(
        beforePublishForTesting: ((String) throws -> Void)? = nil) throws
    {
        try self.directoryCustody.lock.withLock {
            guard self.directoryCustody.operationReceiptDirectoryDescriptor == nil,
                  self.directoryCustody.operationReceiptDirectoryIdentity == nil,
                  self.revalidateRunRootLocked(),
                  Self.isExactPrivateRegularFile(
                      at: self.directoryCustody.runRootDescriptor,
                      basename: PeekabooBridgeAgentExecutionCoding.coordinationBasename),
                  Self.isExactPrivateRegularFile(
                      at: self.directoryCustody.runRootDescriptor,
                      basename: PeekabooBridgeAgentExecutionCoding.acknowledgementBasename),
                  Self.isAbsent(
                      at: self.directoryCustody.runRootDescriptor,
                      basename: PeekabooBridgeAgentExecutionCoding.operationReceiptDirectoryBasename)
            else {
                throw PeekabooBridgeAgentExecutionPreReleaseError.unsafeRunRoot(self.runRoot.path)
            }

            // Coordination and acknowledgement are already published here, so this run root is
            // intentionally not retryable. Preserve any later directory or conflict as evidence.
            let stagingChallenge = try PeekabooBridgeAgentExecutionCoding.randomChallenge()
            let stagingBasename = ".agent-operation-receipts.\(stagingChallenge).staging"
            // The retained parent is exact mode 0700. Request all bits only to neutralize the
            // process umask, then bind the random staging inode and fchmod it to exact mode 0700.
            guard mkdirat(
                self.directoryCustody.runRootDescriptor,
                stagingBasename,
                S_IRWXU | S_IRWXG | S_IRWXO) == 0
            else {
                throw PeekabooBridgeAgentExecutionPreReleaseError.unsafeRunRoot(
                    self.operationReceiptDirectory.path)
            }
            let descriptor = openat(
                self.directoryCustody.runRootDescriptor,
                stagingBasename,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else {
                throw PeekabooBridgeAgentExecutionPreReleaseError.unsafeRunRoot(
                    self.operationReceiptDirectory.path)
            }
            do {
                guard let identity = Self.ownedDirectoryIdentity(descriptor: descriptor),
                      Self.ownedDirectoryIdentity(
                          at: self.directoryCustody.runRootDescriptor,
                          basename: stagingBasename) == identity,
                      fchmod(descriptor, S_IRWXU) == 0,
                      Self.privateDirectoryIdentity(descriptor: descriptor) == identity,
                      Self.privateDirectoryIdentity(
                          at: self.directoryCustody.runRootDescriptor,
                          basename: stagingBasename) == identity,
                      self.revalidateRunRootLocked()
                else {
                    throw PeekabooBridgeAgentExecutionPreReleaseError.unsafeRunRoot(
                        self.operationReceiptDirectory.path)
                }
                try beforePublishForTesting?(stagingBasename)
                guard Self.isDirectoryEmpty(descriptor: descriptor) else {
                    throw PeekabooBridgeAgentExecutionPreReleaseError.unsafeRunRoot(
                        self.operationReceiptDirectory.path)
                }
                guard renameatx_np(
                    self.directoryCustody.runRootDescriptor,
                    stagingBasename,
                    self.directoryCustody.runRootDescriptor,
                    PeekabooBridgeAgentExecutionCoding.operationReceiptDirectoryBasename,
                    UInt32(RENAME_EXCL)) == 0,
                    Self.privateDirectoryIdentity(
                        at: self.directoryCustody.runRootDescriptor,
                        basename: PeekabooBridgeAgentExecutionCoding.operationReceiptDirectoryBasename) == identity,
                    Self.isDirectoryEmpty(descriptor: descriptor),
                    self.revalidateRunRootLocked(),
                    fsync(self.directoryCustody.runRootDescriptor) == 0
                else {
                    throw PeekabooBridgeAgentExecutionPreReleaseError.unsafeRunRoot(
                        self.operationReceiptDirectory.path)
                }
                self.directoryCustody.operationReceiptDirectoryDescriptor = descriptor
                self.directoryCustody.operationReceiptDirectoryIdentity = identity
            } catch {
                close(descriptor)
                throw error
            }
        }
    }

    func revalidateBeforeRelease() throws {
        try self.directoryCustody.lock.withLock {
            guard self.revalidateRunRootLocked(),
                  let descriptor = self.directoryCustody.operationReceiptDirectoryDescriptor,
                  let identity = self.directoryCustody.operationReceiptDirectoryIdentity,
                  Self.privateDirectoryIdentity(descriptor: descriptor) == identity,
                  Self.privateDirectoryIdentity(
                      at: self.directoryCustody.runRootDescriptor,
                      basename: PeekabooBridgeAgentExecutionCoding.operationReceiptDirectoryBasename) == identity,
                  Self.isDirectoryEmpty(descriptor: descriptor),
                  Self.isExactPrivateRegularFile(
                      at: self.directoryCustody.runRootDescriptor,
                      basename: PeekabooBridgeAgentExecutionCoding.coordinationBasename),
                  Self.isExactPrivateRegularFile(
                      at: self.directoryCustody.runRootDescriptor,
                      basename: PeekabooBridgeAgentExecutionCoding.acknowledgementBasename)
            else {
                throw PeekabooBridgeAgentExecutionPreReleaseError.unsafeRunRoot(self.runRoot.path)
            }
        }
    }

    #if DEBUG
    func releaseRunRootCustodyForTesting() {
        self.directoryCustody.release()
    }
    #endif

    private func revalidateRunRootLocked() -> Bool {
        flock(self.directoryCustody.runRootDescriptor, LOCK_EX | LOCK_NB) == 0 &&
            Self.canonicalPath(self.runRoot.path) == self.runRoot.path &&
            Self.privateDirectoryIdentity(self.runRoot.path) == self.directoryCustody.runRootIdentity &&
            Self.privateDirectoryIdentity(descriptor: self.directoryCustody.runRootDescriptor) ==
            self.directoryCustody.runRootIdentity
    }

    private static func canonicalPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard path.withCString({ realpath($0, &buffer) }) != nil else { return nil }
        return self.string(fromNullTerminated: buffer)
    }

    private static func privateDirectoryIdentity(_ path: String) -> Identity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return self.privateDirectoryIdentity(info)
    }

    private static func privateDirectoryIdentity(descriptor: Int32) -> Identity? {
        guard let (identity, info) = self.ownedDirectoryIdentityAndInfo(descriptor: descriptor),
              (info.st_mode & 0o777) == 0o700
        else { return nil }
        return identity
    }

    private static func ownedDirectoryIdentity(descriptor: Int32) -> Identity? {
        self.ownedDirectoryIdentityAndInfo(descriptor: descriptor)?.0
    }

    private static func ownedDirectoryIdentityAndInfo(descriptor: Int32) -> (Identity, stat)? {
        var info = stat()
        guard descriptor >= 0, fstat(descriptor, &info) == 0 else { return nil }
        guard let identity = self.ownedDirectoryIdentity(info) else { return nil }
        return (identity, info)
    }

    private static func privateDirectoryIdentity(at descriptor: Int32, basename: String) -> Identity? {
        guard let (identity, info) = self.ownedDirectoryIdentityAndInfo(
            at: descriptor,
            basename: basename),
            (info.st_mode & 0o777) == 0o700
        else { return nil }
        return identity
    }

    private static func ownedDirectoryIdentity(at descriptor: Int32, basename: String) -> Identity? {
        self.ownedDirectoryIdentityAndInfo(at: descriptor, basename: basename)?.0
    }

    private static func ownedDirectoryIdentityAndInfo(
        at descriptor: Int32,
        basename: String) -> (Identity, stat)?
    {
        var info = stat()
        guard descriptor >= 0,
              fstatat(descriptor, basename, &info, AT_SYMLINK_NOFOLLOW) == 0
        else { return nil }
        guard let identity = self.ownedDirectoryIdentity(info) else { return nil }
        return (identity, info)
    }

    private static func privateDirectoryIdentity(_ info: stat) -> Identity? {
        guard let identity = self.ownedDirectoryIdentity(info),
              (info.st_mode & 0o777) == 0o700
        else { return nil }
        return identity
    }

    private static func ownedDirectoryIdentity(_ info: stat) -> Identity? {
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_nlink >= 1
        else { return nil }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    private static func isAbsent(at descriptor: Int32, basename: String) -> Bool {
        var info = stat()
        if fstatat(descriptor, basename, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            return false
        }
        return errno == ENOENT
    }

    private static func isExactPrivateRegularFile(at descriptor: Int32, basename: String) -> Bool {
        var info = stat()
        guard descriptor >= 0,
              fstatat(descriptor, basename, &info, AT_SYMLINK_NOFOLLOW) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o777) == 0o600
        else { return false }
        return true
    }

    private static func isDirectoryEmpty(descriptor: Int32) -> Bool {
        let scanDescriptor = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard scanDescriptor >= 0 else { return false }
        guard let directory = fdopendir(scanDescriptor) else {
            close(scanDescriptor)
            return false
        }
        defer { closedir(directory) }

        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                return false
            }
            errno = 0
        }
        return errno == 0
    }

    private static func string(fromNullTerminated buffer: [CChar]) -> String? {
        String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }
}

struct PeekabooBridgeAgentExecutionEnvironment: Sendable {
    let policyVersion: Int
    let values: [String: String]
    let keys: [String]
    let sha256: String

    static func make(
        operationReceiptDirectoryPath: String,
        releaseGateDescriptor: Int32,
        lockdownReadinessDescriptor: Int32,
        releaseChallenge: String,
        source: [String: String] = ProcessInfo.processInfo.environment) throws -> Self
    {
        let commonKeys = [
            "HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "SSL_CERT_DIR", "SSL_CERT_FILE",
            "TMPDIR", "TZ", "USER",
        ]
        let providerKeys = [
            "ANTHROPIC_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY", "GROK_API_KEY",
            "MINIMAX_API_KEY", "MOONSHOT_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY",
            "X_AI_API_KEY", "XAI_API_KEY",
        ]
        var values = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in commonKeys + providerKeys {
            guard let value = source[key] else { continue }
            guard !value.utf8.contains(0) else {
                throw PeekabooBridgeAgentExecutionPreReleaseError.invalidRequest(
                    "allowlisted environment value contains NUL")
            }
            values[key] = value
        }
        values["PEEKABOO_OPERATION_RECEIPT_DIRECTORY"] = operationReceiptDirectoryPath
        values["PEEKABOO_AGENT_EXECUTION_GATE_FD"] = String(releaseGateDescriptor)
        values["PEEKABOO_AGENT_EXECUTION_GATE_CHALLENGE"] = releaseChallenge
        values["PEEKABOO_AGENT_EXECUTION_LOCKDOWN_FD"] = String(lockdownReadinessDescriptor)
        values["PEEKABOO_AGENT_EXECUTION_PROCESS_LIMIT"] = "0"
        let keys = values.keys.sorted()
        return try Self(
            policyVersion: 3,
            values: values,
            keys: keys,
            sha256: PeekabooBridgeAgentExecutionCoding.sha256Canonical(values))
    }
}

/// One anonymous host-to-child authorization gate. The challenge is public and signed; authority
/// comes from the unforgeable pipe endpoint, whose only writer remains inside the Bridge host.
final class PeekabooBridgeAgentExecutionReleaseGate: @unchecked Sendable {
    let readDescriptor: Int32
    let writeDescriptor: Int32
    let childDescriptor: Int32
    let readinessReadDescriptor: Int32
    let readinessWriteDescriptor: Int32
    let childReadinessDescriptor: Int32
    private let lock = NSLock()
    private var parentReadClosed = false
    private var parentReadinessWriteClosed = false
    private var readinessReadClosed = false
    private var writeClosed = false

    init(excludingDescriptors: [Int32]) throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.spawnFailed(String(cString: strerror(errno)))
        }
        var readinessDescriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&readinessDescriptors) == 0 else {
            close(descriptors[0])
            close(descriptors[1])
            throw PeekabooBridgeAgentExecutionPreReleaseError.spawnFailed(String(cString: strerror(errno)))
        }
        self.readDescriptor = descriptors[0]
        self.writeDescriptor = descriptors[1]
        self.readinessReadDescriptor = readinessDescriptors[0]
        self.readinessWriteDescriptor = readinessDescriptors[1]
        let excluded = Set(excludingDescriptors + descriptors + readinessDescriptors)
        let available = (198...253).map(Int32.init).filter { !excluded.contains($0) }
        guard available.count >= 2 else {
            (descriptors + readinessDescriptors).forEach { close($0) }
            throw PeekabooBridgeAgentExecutionPreReleaseError.spawnFailed("no release-gate descriptor available")
        }
        self.childDescriptor = available[0]
        self.childReadinessDescriptor = available[1]
        for descriptor in descriptors + readinessDescriptors {
            let flags = fcntl(descriptor, F_GETFD)
            guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                self.closeAll()
                throw PeekabooBridgeAgentExecutionPreReleaseError.spawnFailed(
                    "cannot protect release-gate descriptor")
            }
        }
        guard fcntl(self.writeDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            self.closeAll()
            throw PeekabooBridgeAgentExecutionPreReleaseError.spawnFailed(
                "cannot suppress release-gate SIGPIPE")
        }
        let readinessFlags = fcntl(self.readinessReadDescriptor, F_GETFL)
        guard readinessFlags >= 0,
              fcntl(self.readinessReadDescriptor, F_SETFL, readinessFlags | O_NONBLOCK) == 0
        else {
            self.closeAll()
            throw PeekabooBridgeAgentExecutionPreReleaseError.spawnFailed(
                "cannot configure lockdown readiness")
        }
    }

    func closeParentReadinessWrite() {
        self.lock.lock()
        guard !self.parentReadinessWriteClosed else {
            self.lock.unlock()
            return
        }
        self.parentReadinessWriteClosed = true
        self.lock.unlock()
        close(self.readinessWriteDescriptor)
    }

    func waitForLockdown(challenge: String, deadline: ContinuousClock.Instant) async throws {
        var bytes = Data()
        while ContinuousClock.now < deadline {
            var buffer = [UInt8](repeating: 0, count: 128)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(self.readinessReadDescriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                bytes.append(contentsOf: buffer.prefix(count))
                guard bytes.count <= 64 else {
                    throw PeekabooBridgeAgentExecutionPreReleaseError.invalidAcknowledgement(
                        "Agent child lockdown readiness contained trailing bytes")
                }
                continue
            }
            if count == 0 {
                self.closeReadinessRead()
                guard bytes.elementsEqual(challenge.utf8) else {
                    throw PeekabooBridgeAgentExecutionPreReleaseError.invalidAcknowledgement(
                        "Agent child did not attest process creation lockdown")
                }
                return
            }
            if errno == EINTR {
                continue
            }
            guard errno == EAGAIN || errno == EWOULDBLOCK else {
                throw PeekabooBridgeAgentExecutionPreReleaseError.invalidAcknowledgement(
                    "Agent child lockdown readiness read failed")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw PeekabooBridgeAgentExecutionPreReleaseError.acknowledgementTimedOut
    }

    private func closeReadinessRead() {
        self.lock.lock()
        guard !self.readinessReadClosed else {
            self.lock.unlock()
            return
        }
        self.readinessReadClosed = true
        self.lock.unlock()
        close(self.readinessReadDescriptor)
    }

    func closeParentRead() {
        self.lock.lock()
        guard !self.parentReadClosed else {
            self.lock.unlock()
            return
        }
        self.parentReadClosed = true
        self.lock.unlock()
        close(self.readDescriptor)
    }

    func release(challenge: String) throws {
        let bytes = Array(challenge.utf8)
        guard bytes.count == 64 else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.releaseFailed(EINVAL)
        }
        self.lock.lock()
        guard !self.writeClosed else {
            self.lock.unlock()
            throw PeekabooBridgeAgentExecutionPreReleaseError.releaseFailed(EALREADY)
        }
        self.writeClosed = true
        self.lock.unlock()
        defer { close(self.writeDescriptor) }

        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    self.writeDescriptor,
                    buffer.baseAddress?.advanced(by: written),
                    buffer.count - written)
            }
            if count > 0 {
                written += count
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            throw PeekabooBridgeAgentExecutionPreReleaseError.releaseFailed(errno)
        }
    }

    func closeAll() {
        self.lock.lock()
        let closeRead = !self.parentReadClosed
        let closeReadinessWrite = !self.parentReadinessWriteClosed
        let closeReadinessRead = !self.readinessReadClosed
        let closeWrite = !self.writeClosed
        self.parentReadClosed = true
        self.parentReadinessWriteClosed = true
        self.readinessReadClosed = true
        self.writeClosed = true
        self.lock.unlock()
        if closeRead {
            close(self.readDescriptor)
        }
        if closeWrite {
            close(self.writeDescriptor)
        }
        if closeReadinessWrite {
            close(self.readinessWriteDescriptor)
        }
        if closeReadinessRead {
            close(self.readinessReadDescriptor)
        }
    }
}

struct PeekabooBridgeAgentExecutionExecutable: Equatable, Sendable {
    let processIdentifier: pid_t
    let processStartIdentity: UInt64
    let path: String
    let sha256: String
    let codeSignatureHash: String

    static func capturePeer(_ peer: PeekabooBridgePeer) throws -> Self {
        guard peer.bundleIdentifier == PeekabooBridgeConstants.cliBundleIdentifier,
              peer.userIdentifier == geteuid(),
              let liveIdentity = peer.liveIdentity,
              let auditIdentity = liveIdentity.auditIdentity,
              liveIdentity.processIdentifier == peer.processIdentifier,
              liveIdentity.processStartIdentity == peer.processStartIdentity,
              let expectedCDHash = peer.codeSignatureHash,
              !expectedCDHash.isEmpty,
              PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(auditIdentity: auditIdentity) == expectedCDHash
        else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.unauthenticatedPeer
        }
        return try self.capture(
            processIdentifier: peer.processIdentifier,
            expectedGeneration: liveIdentity.processStartIdentity,
            expectedCDHash: expectedCDHash)
    }

    static func revalidatePeer(_ peer: PeekabooBridgePeer, expected: Self) throws {
        guard try self.capturePeer(peer) == expected else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.executableIdentityChanged
        }
    }

    static func captureChild(_ processIdentifier: pid_t, expected: Self) throws -> Self {
        let child = try self.capture(
            processIdentifier: processIdentifier,
            expectedGeneration: nil,
            expectedCDHash: expected.codeSignatureHash)
        guard child.path == expected.path,
              child.sha256 == expected.sha256,
              child.codeSignatureHash == expected.codeSignatureHash
        else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.executableIdentityChanged
        }
        return child
    }

    #if DEBUG
    static func captureProcessForTesting(_ processIdentifier: pid_t) throws -> Self {
        guard let processStartIdentity = SystemIdentityResolver.processStartIdentity(processIdentifier),
              let codeSignatureHash = PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(
                  processIdentifier: processIdentifier,
                  expectedProcessStartIdentity: processStartIdentity)
        else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.executableIdentityChanged
        }
        return try self.capture(
            processIdentifier: processIdentifier,
            expectedGeneration: processStartIdentity,
            expectedCDHash: codeSignatureHash)
    }
    #endif

    private static func capture(
        processIdentifier: pid_t,
        expectedGeneration: UInt64?,
        expectedCDHash: String) throws -> Self
    {
        guard processIdentifier > 0,
              let generationBefore = SystemIdentityResolver.processStartIdentity(processIdentifier),
              expectedGeneration == nil || expectedGeneration == generationBefore,
              let pathBefore = self.canonicalProcessPath(processIdentifier),
              let digest = try? self.stableExecutableSHA256(pathBefore),
              let liveCDHash = PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(
                  processIdentifier: processIdentifier,
                  expectedProcessStartIdentity: generationBefore),
              liveCDHash == expectedCDHash,
              PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(executablePath: pathBefore) == expectedCDHash,
              let pathAfter = self.canonicalProcessPath(processIdentifier),
              pathAfter == pathBefore,
              SystemIdentityResolver.processStartIdentity(processIdentifier) == generationBefore
        else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.executableIdentityChanged
        }
        return Self(
            processIdentifier: processIdentifier,
            processStartIdentity: generationBefore,
            path: pathBefore,
            sha256: digest,
            codeSignatureHash: liveCDHash)
    }

    static func canonicalProcessPath(_ processIdentifier: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) * 4)
        let length = proc_pidpath(processIdentifier, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        guard let path = self.string(fromNullTerminated: buffer) else { return nil }
        return self.canonicalPath(path)
    }

    static func canonicalPath(_ path: String) -> String? {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = resolved.withUnsafeMutableBufferPointer { buffer in
            path.withCString { realpath($0, buffer.baseAddress) }
        }
        guard result != nil else { return nil }
        return self.string(fromNullTerminated: resolved)
    }

    static func stableExecutableSHA256(_ path: String) throws -> String {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == geteuid() || before.st_uid == 0,
              before.st_nlink == 1,
              before.st_size > 0,
              before.st_size <= 1024 * 1024 * 1024,
              before.st_mode & 0o022 == 0
        else { throw POSIXError(.EPERM) }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                hasher.update(data: Data(buffer.prefix(count)))
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        var after = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &after) == 0,
              lstat(path, &pathInfo) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              after.st_dev == pathInfo.st_dev,
              after.st_ino == pathInfo.st_ino
        else { throw POSIXError(.ESTALE) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func string(fromNullTerminated buffer: [CChar]) -> String? {
        String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }
}

enum PeekabooBridgeAgentExecutionCoding {
    static let coordinationBasename = "agent-execution-coordination.json"
    static let acknowledgementBasename = "agent-execution-ack.json"
    static let operationReceiptDirectoryBasename = "agent-operation-receipts"

    static func arguments(task: String, maxSteps: Int, socketPath: String) -> [String] {
        [
            "agent", "run", task, "--no-cache", "--max-steps", String(maxSteps),
            "--bridge-socket", socketPath, "--json",
        ]
    }

    static func argumentsSHA256(task: String, maxSteps: Int, socketPath: String) -> String {
        (try? self.sha256Canonical(self.arguments(task: task, maxSteps: maxSteps, socketPath: socketPath))) ?? ""
    }

    static func canonicalData(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder.peekabooBridgeEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func sha256Canonical(_ value: some Encodable) throws -> String {
        try self.sha256(self.canonicalData(value))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func randomChallenge() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.receiptPublicationFailed(
                "secure random challenge generation failed")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func nowMilliseconds() -> Int64 {
        var value = timespec()
        guard clock_gettime(CLOCK_REALTIME, &value) == 0 else { return 0 }
        return Int64(value.tv_sec) * 1000 + Int64(value.tv_nsec) / 1_000_000
    }
}

// MARK: - Spawn, pipes, and terminal wait

enum PeekabooBridgeAgentExecutionCStringVector {
    static func make(
        _ strings: [String],
        duplicate: (String) -> UnsafeMutablePointer<CChar>? = { strdup($0) }) throws
        -> [UnsafeMutablePointer<CChar>?]
    {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        pointers.reserveCapacity(strings.count + 1)
        for string in strings {
            guard let pointer = duplicate(string) else {
                self.free(pointers)
                throw PeekabooBridgeAgentExecutionPreReleaseError.spawnFailed(
                    "allocate launch arguments: \(String(cString: strerror(ENOMEM)))")
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return pointers
    }

    static func free(_ pointers: [UnsafeMutablePointer<CChar>?]) {
        pointers.forEach { Darwin.free($0) }
    }
}

final class PeekabooBridgeAgentExecutionPipes: @unchecked Sendable {
    let stdoutRead: Int32
    let stdoutWrite: Int32
    let stderrRead: Int32
    let stderrWrite: Int32
    private let lock = NSLock()
    private var parentWritesClosed = false
    private var allClosed = false

    init() throws {
        var stdout = [Int32](repeating: -1, count: 2)
        var stderr = [Int32](repeating: -1, count: 2)
        guard pipe(&stdout) == 0 else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.spawnFailed(String(cString: strerror(errno)))
        }
        guard pipe(&stderr) == 0 else {
            close(stdout[0])
            close(stdout[1])
            throw PeekabooBridgeAgentExecutionPreReleaseError.spawnFailed(String(cString: strerror(errno)))
        }
        self.stdoutRead = stdout[0]
        self.stdoutWrite = stdout[1]
        self.stderrRead = stderr[0]
        self.stderrWrite = stderr[1]
        for descriptor in stdout + stderr {
            let flags = fcntl(descriptor, F_GETFD)
            guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                self.closeAll()
                throw PeekabooBridgeAgentExecutionPreReleaseError.spawnFailed("cannot set close-on-exec")
            }
        }
    }

    func closeParentWrites() {
        self.lock.lock()
        guard !self.parentWritesClosed, !self.allClosed else {
            self.lock.unlock()
            return
        }
        self.parentWritesClosed = true
        self.lock.unlock()
        close(self.stdoutWrite)
        close(self.stderrWrite)
    }

    func closeAll() {
        self.lock.lock()
        guard !self.allClosed else {
            self.lock.unlock()
            return
        }
        self.allClosed = true
        let writesWereOpen = !self.parentWritesClosed
        self.parentWritesClosed = true
        self.lock.unlock()
        close(self.stdoutRead)
        close(self.stderrRead)
        if writesWereOpen {
            close(self.stdoutWrite)
            close(self.stderrWrite)
        }
    }
}

enum PeekabooBridgeAgentExecutionSpawn {
    static func spawnSuspended(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        pipes: PeekabooBridgeAgentExecutionPipes,
        releaseGate: PeekabooBridgeAgentExecutionReleaseGate) throws -> pid_t
    {
        let argumentStrings = [executablePath] + arguments
        let environmentStrings = environment.keys.sorted().compactMap { key in
            environment[key].map { "\(key)=\($0)" }
        }
        try self.validateLaunchPayload(arguments: argumentStrings, environment: environmentStrings)

        var actions: posix_spawn_file_actions_t?
        try self.check(posix_spawn_file_actions_init(&actions), "initialize file actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try self.check(
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            "redirect stdin")
        try self.check(
            posix_spawn_file_actions_adddup2(&actions, pipes.stdoutWrite, STDOUT_FILENO),
            "redirect stdout")
        try self.check(
            posix_spawn_file_actions_adddup2(&actions, pipes.stderrWrite, STDERR_FILENO),
            "redirect stderr")
        try self.check(
            posix_spawn_file_actions_adddup2(
                &actions,
                releaseGate.readDescriptor,
                releaseGate.childDescriptor),
            "inherit release gate")
        try self.check(
            posix_spawn_file_actions_adddup2(
                &actions,
                releaseGate.readinessWriteDescriptor,
                releaseGate.childReadinessDescriptor),
            "inherit lockdown readiness")
        for descriptor in [pipes.stdoutRead, pipes.stderrRead, pipes.stdoutWrite, pipes.stderrWrite] {
            if descriptor != STDOUT_FILENO, descriptor != STDERR_FILENO {
                try self.check(posix_spawn_file_actions_addclose(&actions, descriptor), "close child pipe")
            }
        }
        try self.check(
            posix_spawn_file_actions_addclose(&actions, releaseGate.writeDescriptor),
            "close child release writer")
        try self.check(
            posix_spawn_file_actions_addclose(&actions, releaseGate.readinessReadDescriptor),
            "close child lockdown reader")
        if releaseGate.readDescriptor != releaseGate.childDescriptor {
            try self.check(
                posix_spawn_file_actions_addclose(&actions, releaseGate.readDescriptor),
                "close child release source")
        }
        if releaseGate.readinessWriteDescriptor != releaseGate.childReadinessDescriptor {
            try self.check(
                posix_spawn_file_actions_addclose(&actions, releaseGate.readinessWriteDescriptor),
                "close child lockdown source")
        }

        var attributes: posix_spawnattr_t?
        try self.check(posix_spawnattr_init(&attributes), "initialize spawn attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID)
        try self.check(posix_spawnattr_setflags(&attributes, flags), "set suspended spawn flags")

        var argv = try PeekabooBridgeAgentExecutionCStringVector.make(argumentStrings)
        defer { PeekabooBridgeAgentExecutionCStringVector.free(argv) }
        var envp = try PeekabooBridgeAgentExecutionCStringVector.make(environmentStrings)
        defer { PeekabooBridgeAgentExecutionCStringVector.free(envp) }

        var processIdentifier: pid_t = 0
        let result = executablePath.withCString {
            posix_spawn(&processIdentifier, $0, &actions, &attributes, &argv, &envp)
        }
        pipes.closeParentWrites()
        releaseGate.closeParentRead()
        releaseGate.closeParentReadinessWrite()
        try self.check(result, "launch authenticated CLI")
        guard processIdentifier > 0 else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.spawnFailed("spawn returned no child PID")
        }
        return processIdentifier
    }

    private static func validateLaunchPayload(arguments: [String], environment: [String]) throws {
        let strings = arguments + environment
        guard strings.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.invalidRequest(
                "Agent launch arguments and environment must be NUL-free")
        }

        let pointerCount = arguments.count + 1 + environment.count + 1
        let (pointerBytes, pointerOverflow) = pointerCount.multipliedReportingOverflow(
            by: MemoryLayout<UnsafePointer<CChar>?>.stride)
        guard !pointerOverflow else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.invalidRequest(
                "Agent launch arguments and environment are too large")
        }
        var totalBytes = pointerBytes
        for string in strings {
            let (terminatedBytes, terminatorOverflow) = string.utf8.count.addingReportingOverflow(1)
            let (nextTotal, totalOverflow) = totalBytes.addingReportingOverflow(terminatedBytes)
            guard !terminatorOverflow, !totalOverflow else {
                throw PeekabooBridgeAgentExecutionPreReleaseError.invalidRequest(
                    "Agent launch arguments and environment are too large")
            }
            totalBytes = nextTotal
        }
        guard totalBytes <= PeekabooBridgeAgentExecutionPolicy.maximumArgumentEnvironmentBytes else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.invalidRequest(
                "Agent launch arguments and environment exceed the 512 KiB preflight budget")
        }
    }

    private static func check(_ code: Int32, _ operation: String) throws {
        guard code != 0 else { return }
        throw PeekabooBridgeAgentExecutionPreReleaseError.spawnFailed(
            "\(operation): \(String(cString: strerror(code)))")
    }
}

final class PeekabooBridgeAgentExecutionPipeControl: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumCombinedBytes: Int
    private var retainedBytes = 0
    private var stopped = false
    private var overflowed = false
    private var stoppedBeforeEOF = false
    private var finishedReaders = 0

    init(maximumCombinedBytes: Int) {
        self.maximumCombinedBytes = maximumCombinedBytes
    }

    var shouldStop: Bool {
        self.lock.withLock { self.stopped }
    }

    var didOverflow: Bool {
        self.lock.withLock { self.overflowed }
    }

    var captureWasTruncated: Bool {
        self.lock.withLock { self.overflowed || self.stoppedBeforeEOF }
    }

    var allReadersFinished: Bool {
        self.lock.withLock { self.finishedReaders == 2 }
    }

    func reserve(_ requested: Int) -> Int {
        self.lock.withLock {
            guard !self.stopped else { return 0 }
            let remaining = max(0, self.maximumCombinedBytes - self.retainedBytes)
            let accepted = min(requested, remaining)
            self.retainedBytes += accepted
            if accepted < requested {
                self.overflowed = true
                self.stoppedBeforeEOF = true
                self.stopped = true
            }
            return accepted
        }
    }

    func stop(markTruncated: Bool = true) {
        self.lock.withLock {
            self.stopped = true
            self.stoppedBeforeEOF = self.stoppedBeforeEOF || markTruncated
        }
    }

    func readerFinished() {
        self.lock.withLock { self.finishedReaders += 1 }
    }
}

struct PeekabooBridgeAgentExecutionPipeCapture: Sendable {
    let bytes: Data
    let truncated: Bool
    let readErrorCode: Int32?
}

enum PeekabooBridgeAgentExecutionPipeReader {
    static func read(
        _ descriptor: Int32,
        control: PeekabooBridgeAgentExecutionPipeControl) -> PeekabooBridgeAgentExecutionPipeCapture
    {
        defer {
            close(descriptor)
            control.readerFinished()
        }
        let flags = fcntl(descriptor, F_GETFL)
        if flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != 0 {
            return .init(bytes: Data(), truncated: false, readErrorCode: errno)
        }

        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !control.shouldStop {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let pollResult = Darwin.poll(&pollDescriptor, 1, 50)
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                return .init(bytes: bytes, truncated: false, readErrorCode: errno)
            }
            if pollResult == 0 {
                continue
            }
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    let accepted = control.reserve(count)
                    if accepted > 0 {
                        bytes.append(contentsOf: buffer.prefix(accepted))
                    }
                    if accepted < count {
                        return .init(bytes: bytes, truncated: true, readErrorCode: nil)
                    }
                    continue
                }
                if count == 0 {
                    return .init(bytes: bytes, truncated: false, readErrorCode: nil)
                }
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                }
                return .init(bytes: bytes, truncated: false, readErrorCode: errno)
            }
        }
        return .init(bytes: bytes, truncated: control.captureWasTruncated, readErrorCode: nil)
    }
}

enum PeekabooBridgeAgentExecutionAcknowledgementReader {
    struct ReadResult: Sendable {
        let value: PeekabooBridgeAgentExecutionAcknowledgement
        let bytes: Data
    }

    static func wait(at url: URL, deadline: ContinuousClock.Instant) async throws -> ReadResult {
        while ContinuousClock.now < deadline {
            if Task.isCancelled {
                throw PeekabooBridgeAgentExecutionPreReleaseError.cancelledBeforeRelease
            }
            var info = stat()
            if lstat(url.path, &info) == 0 {
                let bytes = try self.stableRead(url)
                try self.validateExactKeys(bytes)
                do {
                    return try ReadResult(
                        value: JSONDecoder.peekabooBridgeDecoder().decode(
                            PeekabooBridgeAgentExecutionAcknowledgement.self,
                            from: bytes),
                        bytes: bytes)
                } catch {
                    throw PeekabooBridgeAgentExecutionPreReleaseError.invalidAcknowledgement(
                        error.localizedDescription)
                }
            }
            guard errno == ENOENT else {
                throw PeekabooBridgeAgentExecutionPreReleaseError.invalidAcknowledgement(
                    String(cString: strerror(errno)))
            }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                throw PeekabooBridgeAgentExecutionPreReleaseError.cancelledBeforeRelease
            }
        }
        throw PeekabooBridgeAgentExecutionPreReleaseError.acknowledgementTimedOut
    }

    static func validate(
        _ acknowledgement: PeekabooBridgeAgentExecutionAcknowledgement,
        bytes _: Data,
        receipt: PeekabooBridgeAgentExecutionCoordinationReceipt,
        receiptBytes: Data) throws
    {
        guard acknowledgement.version == 1,
              acknowledgement.challenge == receipt.challenge,
              acknowledgement.coordinationReceiptSHA256 == PeekabooBridgeAgentExecutionCoding.sha256(receiptBytes),
              acknowledgement.requestingPeer == receipt.requestingPeer,
              acknowledgement.process == receipt.process,
              acknowledgement.taskSHA256 == receipt.taskSHA256,
              acknowledgement.argumentsSHA256 == receipt.argumentsSHA256,
              acknowledgement.environmentSHA256 == receipt.environmentSHA256,
              acknowledgement.acknowledgedAt >= receipt.publishedAt,
              acknowledgement.acknowledgedAt <= PeekabooBridgeAgentExecutionCoding.nowMilliseconds()
        else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.invalidAcknowledgement(
                "challenge or launch commitments differ")
        }
    }

    static func stableRead(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.invalidAcknowledgement(
                String(cString: strerror(errno)))
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == geteuid(),
              before.st_nlink == 1,
              (before.st_mode & 0o777) == 0o600,
              before.st_size > 0,
              before.st_size <= 1024 * 1024
        else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.invalidAcknowledgement("file is not exact private data")
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw PeekabooBridgeAgentExecutionPreReleaseError.invalidAcknowledgement(
                    String(cString: strerror(errno)))
            }
        }
        var after = stat()
        var pathInfo = stat()
        guard off_t(data.count) == before.st_size,
              fstat(descriptor, &after) == 0,
              lstat(url.path, &pathInfo) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              after.st_dev == pathInfo.st_dev,
              after.st_ino == pathInfo.st_ino
        else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.invalidAcknowledgement("file changed during read")
        }
        return data
    }

    static func validateExactKeys(_ data: Data) throws {
        try PeekabooBridgeRequestPreflight.validate(data)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys) == [
                  "version", "challenge", "coordinationReceiptSHA256", "requestingPeer", "process",
                  "taskSHA256", "argumentsSHA256", "environmentSHA256", "acknowledgedAt",
              ],
              let requestingPeer = dictionary["requestingPeer"] as? [String: Any],
              Set(requestingPeer.keys) == [
                  "processIdentifier", "processStartIdentity", "codeSignatureHash",
              ],
              let process = dictionary["process"] as? [String: Any],
              Set(process.keys) == ["processIdentity", "executablePath", "executableSHA256"],
              let processIdentity = process["processIdentity"] as? [String: Any],
              Set(processIdentity.keys) == [
                  "processIdentifier", "processStartIdentity", "codeSignatureHash",
              ]
        else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.invalidAcknowledgement(
                "top-level fields are not the protocol-1.31 acknowledgement schema")
        }
    }
}

// MARK: - Bounded Agent JSON extraction

struct PeekabooBridgeAgentExecutionExtractedOutput: Sendable {
    let disposition: PeekabooBridgeAgentExecutionOutputDisposition
    let trace: PeekabooBridgeJSONValue?
}

enum PeekabooBridgeAgentExecutionOutputExtractor {
    private static let maximumTraceBytes = 8 * 1024 * 1024
    private static let maximumNodes = 65536
    private static let maximumDepth = 64
    private static let maximumStringBytes = 4 * 1024 * 1024

    static func extract(
        _ bytes: Data,
        outputOverflow: Bool,
        streamFailed: Bool) -> PeekabooBridgeAgentExecutionExtractedOutput
    {
        if outputOverflow {
            return .init(disposition: .outputOverflow, trace: nil)
        }
        if streamFailed {
            return .init(disposition: .streamCaptureFailed, trace: nil)
        }
        if bytes.isEmpty {
            return .init(disposition: .emptyOutput, trace: nil)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: bytes)
        } catch {
            return .init(disposition: .malformedOrMultipleJSON, trace: nil)
        }
        guard let root = object as? [String: Any] else {
            return .init(disposition: .nonObjectJSON, trace: nil)
        }
        guard let success = root["success"] as? NSNumber,
              CFGetTypeID(success) == CFBooleanGetTypeID(),
              success.boolValue
        else {
            return .init(disposition: .reportedFailure, trace: nil)
        }
        guard let result = root["result"] as? [String: Any] else {
            return .init(disposition: .missingResult, trace: nil)
        }
        guard let rawTrace = result["executionTrace"] else {
            return .init(disposition: .missingExecutionTrace, trace: nil)
        }
        guard let traceData = try? JSONSerialization.data(
            withJSONObject: rawTrace,
            options: [.sortedKeys, .withoutEscapingSlashes]),
            traceData.count <= self.maximumTraceBytes
        else {
            return .init(disposition: .executionTraceTooLarge, trace: nil)
        }

        var budget = PeekabooBridgeAgentExecutionJSONBudget(
            remainingNodes: self.maximumNodes,
            remainingStringBytes: self.maximumStringBytes)
        guard self.validateTraceShape(rawTrace),
              let trace = try? self.convert(rawTrace, depth: 0, budget: &budget)
        else {
            return .init(disposition: .invalidExecutionTrace, trace: nil)
        }
        return .init(disposition: .validatedExecutionTrace, trace: trace)
    }

    private static func validateTraceShape(_ value: Any) -> Bool {
        guard let object = value as? [String: Any],
              Set(object.keys) == ["entries", "totalCallCount", "truncated"],
              let entries = object["entries"] as? [Any],
              entries.count <= 512,
              let total = self.exactNonnegativeInteger(object["totalCallCount"]),
              total >= entries.count,
              let truncated = object["truncated"] as? NSNumber,
              CFGetTypeID(truncated) == CFBooleanGetTypeID(),
              truncated.boolValue == (total > entries.count)
        else { return false }
        return true
    }

    private static func convert(
        _ value: Any,
        depth: Int,
        budget: inout PeekabooBridgeAgentExecutionJSONBudget) throws -> PeekabooBridgeJSONValue
    {
        guard depth <= self.maximumDepth, budget.remainingNodes > 0 else {
            throw PeekabooBridgeAgentExecutionJSONError.limitExceeded
        }
        budget.remainingNodes -= 1
        if value is NSNull {
            return .null
        }
        if let string = value as? String {
            let count = string.utf8.count
            guard count <= budget.remainingStringBytes else {
                throw PeekabooBridgeAgentExecutionJSONError.limitExceeded
            }
            budget.remainingStringBytes -= count
            return .string(string)
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let double = number.doubleValue
            guard double.isFinite else { throw PeekabooBridgeAgentExecutionJSONError.invalidValue }
            if let integer = Int(exactly: double), NSNumber(value: integer) == number {
                return .int(integer)
            }
            return .double(double)
        }
        if let array = value as? [Any] {
            var converted: [PeekabooBridgeJSONValue] = []
            converted.reserveCapacity(array.count)
            for element in array {
                try converted.append(self.convert(element, depth: depth + 1, budget: &budget))
            }
            return .array(converted)
        }
        if let object = value as? [String: Any] {
            var converted: [String: PeekabooBridgeJSONValue] = [:]
            converted.reserveCapacity(object.count)
            for key in object.keys.sorted() {
                let count = key.utf8.count
                guard count <= budget.remainingStringBytes, let element = object[key] else {
                    throw PeekabooBridgeAgentExecutionJSONError.limitExceeded
                }
                budget.remainingStringBytes -= count
                converted[key] = try self.convert(element, depth: depth + 1, budget: &budget)
            }
            return .object(converted)
        }
        throw PeekabooBridgeAgentExecutionJSONError.invalidValue
    }

    private static func exactNonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(exactly: number.doubleValue),
              integer >= 0,
              NSNumber(value: integer) == number
        else { return nil }
        return integer
    }
}

private struct PeekabooBridgeAgentExecutionJSONBudget {
    var remainingNodes: Int
    var remainingStringBytes: Int
}

private enum PeekabooBridgeAgentExecutionJSONError: Error {
    case limitExceeded
    case invalidValue
}
