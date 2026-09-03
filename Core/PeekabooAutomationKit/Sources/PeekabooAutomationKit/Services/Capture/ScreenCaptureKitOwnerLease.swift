import CryptoKit
import Darwin
import Foundation
import Security

/// Claims process-lifetime ownership of Peekaboo's ScreenCaptureKit lane.
///
/// A successful descriptor is intentionally retained in static storage. The lock is released only
/// when the process exits, so rebuilding a capture service cannot create a second SCK owner.
public final class ScreenCaptureKitOwnerLease: Sendable {
    public static let defaultProcessCapabilityPreparationTimeoutSeconds: TimeInterval = 8

    struct OwnerIdentity: Equatable, Sendable {
        let processIdentifier: pid_t
        let processStartIdentity: UInt64
        let buildIdentity: String?
        let codeSignatureHash: String?

        init(
            processIdentifier: pid_t,
            processStartIdentity: UInt64,
            buildIdentity: String? = nil,
            codeSignatureHash: String? = nil)
        {
            self.processIdentifier = processIdentifier
            self.processStartIdentity = processStartIdentity
            self.buildIdentity = buildIdentity
            self.codeSignatureHash = codeSignatureHash
        }

        static func current() throws -> Self {
            let processIdentifier = getpid()
            guard let processStartIdentity = SystemIdentityResolver.processStartIdentity(processIdentifier) else {
                throw LeaseError.invalidOwnerIdentity("the current process generation is unavailable")
            }

            if let codeSignatureHash = ScreenCaptureKitOwnerLease.currentCodeSignatureHash() {
                return Self(
                    processIdentifier: processIdentifier,
                    processStartIdentity: processStartIdentity,
                    codeSignatureHash: codeSignatureHash)
            }

            guard let buildIdentity = try ScreenCaptureKitOwnerLease.currentExecutableBuildIdentity() else {
                throw LeaseError.invalidOwnerIdentity(
                    "neither a code-signature hash nor an executable build identity is available")
            }
            return Self(
                processIdentifier: processIdentifier,
                processStartIdentity: processStartIdentity,
                buildIdentity: buildIdentity)
        }
    }

    public struct OwnerReceipt: Codable, Equatable, Sendable {
        static let currentFormatVersion = 1

        public let formatVersion: Int
        public let processIdentifier: pid_t
        public let processStartIdentity: UInt64
        public let buildIdentity: String?
        public let codeSignatureHash: String?

        public init(
            processIdentifier: pid_t,
            processStartIdentity: UInt64,
            buildIdentity: String? = nil,
            codeSignatureHash: String? = nil)
        {
            self.formatVersion = Self.currentFormatVersion
            self.processIdentifier = processIdentifier
            self.processStartIdentity = processStartIdentity
            self.buildIdentity = buildIdentity
            self.codeSignatureHash = codeSignatureHash
        }

        init(identity: OwnerIdentity) {
            self.init(
                processIdentifier: identity.processIdentifier,
                processStartIdentity: identity.processStartIdentity,
                buildIdentity: identity.buildIdentity,
                codeSignatureHash: identity.codeSignatureHash)
        }
    }

    public struct UncoordinatedProcess: Equatable, Sendable {
        public let processIdentifier: pid_t
        public let processStartIdentity: UInt64
        public let executablePath: String

        public init(
            processIdentifier: pid_t,
            processStartIdentity: UInt64,
            executablePath: String)
        {
            self.processIdentifier = processIdentifier
            self.processStartIdentity = processStartIdentity
            self.executablePath = executablePath
        }
    }

    public struct UncoordinatedHost: Equatable, Sendable {
        public let socketPath: String
        public let processIdentifier: pid_t?
        public let processStartIdentity: UInt64?
        public let buildIdentity: String?

        public init(
            socketPath: String,
            processIdentifier: pid_t?,
            processStartIdentity: UInt64?,
            buildIdentity: String? = nil)
        {
            self.socketPath = socketPath
            self.processIdentifier = processIdentifier
            self.processStartIdentity = processStartIdentity
            self.buildIdentity = buildIdentity
        }
    }

    public enum ClaimResult: Equatable, Sendable {
        case acquired(OwnerReceipt)
        case alreadyOwnedByCurrentProcess(OwnerReceipt)

        public var receipt: OwnerReceipt {
            switch self {
            case let .acquired(receipt), let .alreadyOwnedByCurrentProcess(receipt):
                receipt
            }
        }
    }

    public enum LeaseError: LocalizedError, Equatable, Sendable {
        case fileSystem(operation: String, path: String, message: String)
        case systemCall(operation: String, path: String, code: Int32)
        case unsafeDirectory(path: String)
        case unsafeLockFile(path: String)
        case invalidOwnerIdentity(String)
        case invalidOwnerReceipt(path: String, reason: String)
        case ownedByAnotherProcess(path: String, receipt: OwnerReceipt)
        case uncoordinatedProcesses([UncoordinatedProcess])
        case uncoordinatedHosts([UncoordinatedHost])
        case preparationTimedOut(seconds: TimeInterval)

        public var errorDescription: String? {
            switch self {
            case let .fileSystem(operation, path, message):
                "ScreenCaptureKit owner lease failed to \(operation) \(path): \(message)"
            case let .systemCall(operation, path, code):
                "ScreenCaptureKit owner lease failed to \(operation) \(path): " +
                    String(cString: strerror(code))
            case let .unsafeDirectory(path):
                "ScreenCaptureKit owner lease directory is not private and owned by the current user: \(path)"
            case let .unsafeLockFile(path):
                "ScreenCaptureKit owner lease is not a private, single-link regular file owned by the current user: " +
                    path
            case let .invalidOwnerIdentity(reason):
                "ScreenCaptureKit owner identity is invalid: \(reason)"
            case let .invalidOwnerReceipt(path, reason):
                "Another process holds the ScreenCaptureKit owner lease at \(path), but its receipt is invalid: " +
                    reason
            case let .ownedByAnotherProcess(path, receipt):
                "ScreenCaptureKit is already owned by PID \(receipt.processIdentifier) " +
                    "(generation \(receipt.processStartIdentity)) via \(path)"
            case let .uncoordinatedProcesses(processes):
                "ScreenCaptureKit coordination cannot be proven for potential host processes: " + processes.map {
                    "PID \($0.processIdentifier) (generation \($0.processStartIdentity))"
                }.joined(separator: ", ")
            case let .uncoordinatedHosts(hosts):
                "ScreenCaptureKit coordination cannot be proven for Bridge hosts: " + hosts.map {
                    if let processIdentifier = $0.processIdentifier,
                       let processStartIdentity = $0.processStartIdentity
                    {
                        return "\($0.socketPath) (PID \(processIdentifier), generation \(processStartIdentity))"
                    }
                    if let processIdentifier = $0.processIdentifier {
                        return "\($0.socketPath) (PID \(processIdentifier))"
                    }
                    return $0.socketPath
                }.joined(separator: ", ")
            case let .preparationTimedOut(seconds):
                "ScreenCaptureKit owner preparation timed out after \(seconds) seconds"
            }
        }
    }

    typealias ProcessStartIdentityProvider = @Sendable (pid_t) -> UInt64?
    typealias ProcessCapabilityRegistrar = @Sendable () throws -> Void
    typealias UncoordinatedProcessProvider = @Sendable () throws -> [UncoordinatedProcess]
    typealias UncoordinatedHostProvider = @Sendable () -> [UncoordinatedHost]
    typealias ProcessCapabilityReceipt = ScreenCaptureKitProcessCapabilityRegistry.ProcessCapabilityReceipt
    typealias CodeSignatureIdentity = ScreenCaptureKitProcessCapabilityRegistry.CodeSignatureIdentity

    public static let defaultLockURL = canonicalUserTemporaryDirectoryURL()
        .appendingPathComponent("boo.peekaboo.sckit-owner.lock", isDirectory: false)
        .standardizedFileURL
    public static let processCapabilityDirectoryURL = ScreenCaptureKitProcessCapabilityRegistry.directoryURL

    private static let maximumReceiptBytes = 4096
    static let closeOnForkOpenFlag: Int32 = {
        #if compiler(>=6.4)
        O_CLOFORK
        #else
        0
        #endif
    }()

    private static let registryLock = NSLock()
    private static let preparationLock = NSLock()
    private nonisolated(unsafe) static var heldDescriptorsByPath: [String: HeldDescriptor] = [:]
    private nonisolated(unsafe) static var cachedOwnerIdentity: OwnerIdentity?
    private nonisolated(unsafe) static var registeredUncoordinatedHostsBySocket: [String: UncoordinatedHost] = [:]
    private nonisolated(unsafe) static var processCapabilityPreparation: ProcessCapabilityPreparation?

    private struct ProcessCapabilityPreparation {
        let ownerIdentity: OwnerIdentity
        let task: Task<Void, any Error>
    }

    private let lockPath: String
    private let ownerIdentity: OwnerIdentity
    private let processStartIdentity: ProcessStartIdentityProvider
    private let registerProcessCapability: ProcessCapabilityRegistrar
    private let uncoordinatedProcesses: UncoordinatedProcessProvider
    private let uncoordinatedHosts: UncoordinatedHostProvider

    public convenience init(lockURL: URL = ScreenCaptureKitOwnerLease.defaultLockURL) throws {
        let ownerIdentity = try Self.currentOwnerIdentity()
        self.init(
            lockURL: lockURL,
            ownerIdentity: ownerIdentity,
            registerProcessCapability: { try Self.registerCurrentProcessCapability() },
            uncoordinatedProcesses: {
                try Self.liveUncoordinatedProcesses(excluding: ownerIdentity)
            },
            uncoordinatedHosts: {
                Self.registeredUncoordinatedHosts()
            })
    }

    init(
        lockURL: URL,
        ownerIdentity: OwnerIdentity,
        processStartIdentity: @escaping ProcessStartIdentityProvider = SystemIdentityResolver.processStartIdentity,
        registerProcessCapability: @escaping ProcessCapabilityRegistrar = {},
        uncoordinatedProcesses: @escaping UncoordinatedProcessProvider = { [] },
        uncoordinatedHosts: @escaping UncoordinatedHostProvider = { [] })
    {
        self.lockPath = lockURL.standardizedFileURL.path
        self.ownerIdentity = ownerIdentity
        self.processStartIdentity = processStartIdentity
        self.registerProcessCapability = registerProcessCapability
        self.uncoordinatedProcesses = uncoordinatedProcesses
        self.uncoordinatedHosts = uncoordinatedHosts
    }

    /// Reads a credible live owner without acquiring or changing the lease.
    public static func currentOwnerReceiptIfHeld(
        lockURL: URL = ScreenCaptureKitOwnerLease.defaultLockURL) throws -> OwnerReceipt?
    {
        try self.currentOwnerReceiptIfHeld(
            lockURL: lockURL,
            processStartIdentity: SystemIdentityResolver.processStartIdentity)
    }

    static func currentOwnerReceiptIfHeld(
        lockURL: URL,
        processStartIdentity: @escaping ProcessStartIdentityProvider) throws -> OwnerReceipt?
    {
        let lockPath = lockURL.standardizedFileURL.path
        return try self.registryLock.withLock {
            if let held = self.heldDescriptorsByPath[lockPath], held.processIdentifier == getpid() {
                try self.validateHeldDescriptor(held.descriptor, path: lockPath)
                return held.receipt
            }

            let descriptor = open(
                lockPath,
                O_RDONLY | O_CLOEXEC | self.closeOnForkOpenFlag | O_NOFOLLOW | O_NONBLOCK)
            if descriptor < 0, errno == ENOENT {
                return nil
            }
            guard descriptor >= 0 else {
                throw LeaseError.systemCall(operation: "open", path: lockPath, code: errno)
            }
            defer { close(descriptor) }

            try self.validateHeldDescriptor(descriptor, path: lockPath)
            // Darwin F_GETLK reports whole-file flock locks with l_pid = -1. Querying preserves
            // the process-lifetime lease; a nonblocking flock probe would acquire and change it.
            var lockQuery = Darwin.flock()
            lockQuery.l_start = 0
            lockQuery.l_len = 0
            lockQuery.l_pid = 0
            lockQuery.l_type = Int16(F_WRLCK)
            lockQuery.l_whence = Int16(SEEK_SET)
            guard fcntl(descriptor, F_GETLK, &lockQuery) == 0 else {
                throw LeaseError.systemCall(operation: "probe", path: lockPath, code: errno)
            }
            guard lockQuery.l_type != Int16(F_UNLCK) else { return nil }
            return try self.readValidatedReceipt(
                descriptor: descriptor,
                path: lockPath,
                processStartIdentity: processStartIdentity)
        }
    }

    /// Publishes a generation- and build-bound capability receipt held for this process's lifetime.
    /// Rolling-upgrade scans use it to distinguish current cooperative binaries from pre-lease ones.
    public static func registerCurrentProcessCapability() throws {
        try ScreenCaptureKitProcessCapabilityRegistry.register(ownerIdentity: self.currentOwnerIdentity())
    }

    /// Starts the expensive first owner-safety scan before a Bridge request can inherit its latency.
    /// Preparation does not claim the process-lifetime owner lease, so runtime routing remains free to
    /// select a newer exact-build host. Every actual ScreenCaptureKit leaf still rescans before dispatch.
    public static func beginCurrentProcessCapabilityPreparation() {
        _ = try? self.currentProcessCapabilityPreparationTask()
    }

    /// Waits a bounded amount of time for the first owner-safety scan. A Bridge host must suppress
    /// ScreenCaptureKit ownership capability publication if this throws. The single detached scan may
    /// finish warming its cache after a caller timeout, but it never acquires the owner lease or enters SCK.
    public static func prepareCurrentProcessCapability(
        timeoutSeconds: TimeInterval = ScreenCaptureKitOwnerLease
            .defaultProcessCapabilityPreparationTimeoutSeconds) async throws
    {
        let task = try self.currentProcessCapabilityPreparationTask()
        try await self.waitForProcessCapabilityPreparation(task, timeoutSeconds: timeoutSeconds)
    }

    static func waitForProcessCapabilityPreparation(
        _ task: Task<Void, any Error>,
        timeoutSeconds: TimeInterval) async throws
    {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
            throw LeaseError.preparationTimedOut(seconds: max(timeoutSeconds, 0))
        }
        let race = ScreenCaptureKitTimeoutRace<Void>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard race.setContinuation(continuation) else { return }
                Task.detached {
                    await race.resume(task.result)
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                    } catch {
                        return
                    }
                    race.resume(.failure(LeaseError.preparationTimedOut(seconds: timeoutSeconds)))
                }
                race.setTimeoutTask(timeoutTask)
            }
        } onCancel: {
            race.cancel()
        }
    }

    /// Keeps dynamic local runtimes useful while making every later SCK leaf fail closed if an
    /// owner-unaware Bridge was discovered. The tombstone is intentionally irreversible for this
    /// process lifetime so transient PID lookup failures, multiple old hosts, and socket reuse cannot
    /// reopen SCK after only one unsafe host disappears.
    public static func registerPotentialUncoordinatedHost(
        socketPath: String,
        processIdentifier: pid_t?,
        processStartIdentity: UInt64?,
        buildIdentity: String? = nil)
    {
        let standardizedPath = NSString(string: socketPath).standardizingPath
        guard !standardizedPath.isEmpty else { return }
        let host = UncoordinatedHost(
            socketPath: standardizedPath,
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            buildIdentity: buildIdentity)
        self.registryLock.withLock {
            self.registeredUncoordinatedHostsBySocket[standardizedPath] = host
        }
    }

    /// Makes exactly one nonblocking `flock` attempt. A live contender is reported immediately.
    public func claim() throws -> ClaimResult {
        try self.validateNoUncoordinatedOwners()
        if let receipt = try Self.currentProcessHeldReceipt(path: self.lockPath) {
            return .alreadyOwnedByCurrentProcess(receipt)
        }
        if let receipt = try Self.currentOwnerReceiptIfHeld(
            lockURL: URL(fileURLWithPath: self.lockPath),
            processStartIdentity: self.processStartIdentity)
        {
            throw LeaseError.ownedByAnotherProcess(path: self.lockPath, receipt: receipt)
        }
        try self.registerProcessCapability()

        return try Self.registryLock.withLock {
            if let held = Self.heldDescriptorsByPath[self.lockPath], held.processIdentifier == getpid() {
                try Self.validateHeldDescriptor(held.descriptor, path: self.lockPath)
                return .alreadyOwnedByCurrentProcess(held.receipt)
            }

            try self.validateOwnerIdentity()
            try Self.prepareLockDirectory(for: self.lockPath)
            let descriptor = open(
                self.lockPath,
                O_CREAT | O_RDWR | O_CLOEXEC | Self.closeOnForkOpenFlag | O_NOFOLLOW,
                S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw LeaseError.systemCall(operation: "open", path: self.lockPath, code: errno)
            }

            var shouldClose = true
            defer {
                if shouldClose {
                    close(descriptor)
                }
            }

            try Self.secureAndValidateLockFile(descriptor: descriptor, path: self.lockPath)

            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                guard code == EWOULDBLOCK || code == EAGAIN else {
                    throw LeaseError.systemCall(operation: "claim", path: self.lockPath, code: code)
                }
                try Self.validateHeldDescriptor(descriptor, path: self.lockPath)
                let receipt = try Self.readValidatedReceipt(
                    descriptor: descriptor,
                    path: self.lockPath,
                    processStartIdentity: self.processStartIdentity)
                throw LeaseError.ownedByAnotherProcess(path: self.lockPath, receipt: receipt)
            }

            do {
                try Self.validateHeldDescriptor(descriptor, path: self.lockPath)
                let receipt = OwnerReceipt(identity: self.ownerIdentity)
                try Self.persist(receipt: receipt, descriptor: descriptor, path: self.lockPath)
                Self.heldDescriptorsByPath[self.lockPath] = HeldDescriptor(
                    descriptor: descriptor,
                    processIdentifier: getpid(),
                    receipt: receipt)
                shouldClose = false
                return .acquired(receipt)
            } catch {
                _ = flock(descriptor, LOCK_UN)
                throw error
            }
        }
    }

    func prepareForClaim() throws {
        try self.validateNoUncoordinatedOwners()
    }

    private func validateNoUncoordinatedOwners() throws {
        let uncoordinatedHosts = self.uncoordinatedHosts()
        guard uncoordinatedHosts.isEmpty else {
            throw LeaseError.uncoordinatedHosts(uncoordinatedHosts)
        }
        let uncoordinatedProcesses = try self.uncoordinatedProcesses()
        guard uncoordinatedProcesses.isEmpty else {
            throw LeaseError.uncoordinatedProcesses(uncoordinatedProcesses)
        }
    }

    private static func currentProcessCapabilityPreparationTask() throws -> Task<Void, any Error> {
        let ownerIdentity = try self.currentOwnerIdentity()
        return self.preparationLock.withLock {
            if let preparation = self.processCapabilityPreparation,
               preparation.ownerIdentity == ownerIdentity
            {
                return preparation.task
            }
            let task = Task.detached(priority: .userInitiated) {
                try self.registerCurrentProcessCapability()
                try ScreenCaptureKitOwnerLease().prepareForClaim()
            }
            self.processCapabilityPreparation = ProcessCapabilityPreparation(
                ownerIdentity: ownerIdentity,
                task: task)
            return task
        }
    }

    private static func registeredUncoordinatedHosts() -> [UncoordinatedHost] {
        self.registryLock.withLock {
            self.registeredUncoordinatedHostsBySocket.values.sorted {
                $0.socketPath < $1.socketPath
            }
        }
    }

    private static func currentProcessHeldReceipt(path: String) throws -> OwnerReceipt? {
        try self.registryLock.withLock {
            guard let held = self.heldDescriptorsByPath[path], held.processIdentifier == getpid() else {
                return nil
            }
            try self.validateHeldDescriptor(held.descriptor, path: path)
            return held.receipt
        }
    }

    private func validateOwnerIdentity() throws {
        guard self.ownerIdentity.processIdentifier == getpid() else {
            throw LeaseError.invalidOwnerIdentity("the receipt PID is not the current process")
        }
        guard self.ownerIdentity.processStartIdentity > 0,
              self.processStartIdentity(self.ownerIdentity.processIdentifier) ==
              self.ownerIdentity.processStartIdentity
        else {
            throw LeaseError.invalidOwnerIdentity("the receipt process generation is not current")
        }
        try Self.validateExecutableIdentity(
            buildIdentity: self.ownerIdentity.buildIdentity,
            codeSignatureHash: self.ownerIdentity.codeSignatureHash,
            error: LeaseError.invalidOwnerIdentity)
    }

    private static func readValidatedReceipt(
        descriptor: Int32,
        path: String,
        processStartIdentity: ProcessStartIdentityProvider) throws -> OwnerReceipt
    {
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0 else {
            throw LeaseError.systemCall(operation: "inspect receipt", path: path, code: errno)
        }
        guard fileInfo.st_size > 0, fileInfo.st_size <= off_t(Self.maximumReceiptBytes) else {
            throw LeaseError.invalidOwnerReceipt(path: path, reason: "unexpected receipt size")
        }

        var data = Data(count: Int(fileInfo.st_size))
        let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            return pread(descriptor, baseAddress, buffer.count, 0)
        }
        guard bytesRead == data.count else {
            if bytesRead < 0 {
                throw LeaseError.systemCall(operation: "read receipt", path: path, code: errno)
            }
            throw LeaseError.invalidOwnerReceipt(path: path, reason: "truncated receipt")
        }

        let receipt: OwnerReceipt
        do {
            receipt = try JSONDecoder().decode(OwnerReceipt.self, from: data)
        } catch {
            throw LeaseError.invalidOwnerReceipt(path: path, reason: "malformed receipt")
        }
        guard receipt.formatVersion == OwnerReceipt.currentFormatVersion else {
            throw LeaseError.invalidOwnerReceipt(path: path, reason: "unsupported receipt format")
        }
        guard receipt.processIdentifier > 0, receipt.processStartIdentity > 0 else {
            throw LeaseError.invalidOwnerReceipt(path: path, reason: "invalid process identity")
        }
        do {
            try Self.validateExecutableIdentity(
                buildIdentity: receipt.buildIdentity,
                codeSignatureHash: receipt.codeSignatureHash)
        } catch {
            throw LeaseError.invalidOwnerReceipt(path: path, reason: "invalid executable identity")
        }
        guard processStartIdentity(receipt.processIdentifier) == receipt.processStartIdentity else {
            throw LeaseError.invalidOwnerReceipt(path: path, reason: "stale process generation")
        }
        return receipt
    }

    static func prepareLockDirectory(for lockPath: String) throws {
        let directory = URL(fileURLWithPath: lockPath)
            .deletingLastPathComponent()
            .standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: S_IRWXU)])
        } catch {
            throw LeaseError.fileSystem(
                operation: "prepare directory",
                path: directory.path,
                message: error.localizedDescription)
        }

        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0 else {
            throw LeaseError.systemCall(operation: "inspect directory", path: directory.path, code: errno)
        }
        let otherUserPermissions = directoryInfo.st_mode & mode_t(S_IRWXG | S_IRWXO)
        guard directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryInfo.st_uid == geteuid(),
              otherUserPermissions == 0
        else {
            throw LeaseError.unsafeDirectory(path: directory.path)
        }
    }

    static func canonicalUserTemporaryDirectoryURL() -> URL {
        let byteCount = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        if byteCount > 0 {
            var buffer = [CChar](repeating: 0, count: byteCount)
            if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, byteCount) > 0 {
                let pathBytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                if let path = String(bytes: pathBytes, encoding: .utf8) {
                    return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                }
            }
        }
        return FileManager.default.temporaryDirectory.standardizedFileURL
    }

    private static func currentOwnerIdentity() throws -> OwnerIdentity {
        try self.registryLock.withLock {
            if let identity = self.cachedOwnerIdentity, identity.processIdentifier == getpid() {
                return identity
            }
            let identity = try OwnerIdentity.current()
            self.cachedOwnerIdentity = identity
            return identity
        }
    }

    static func secureAndValidateLockFile(descriptor: Int32, path: String) throws {
        var descriptorInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0 else {
            throw LeaseError.systemCall(operation: "inspect", path: path, code: errno)
        }
        guard descriptorInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              descriptorInfo.st_uid == geteuid(),
              descriptorInfo.st_nlink == 1
        else {
            throw LeaseError.unsafeLockFile(path: path)
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw LeaseError.systemCall(operation: "secure", path: path, code: errno)
        }

        guard fstat(descriptor, &descriptorInfo) == 0 else {
            throw LeaseError.systemCall(operation: "verify", path: path, code: errno)
        }
        var pathInfo = stat()
        guard lstat(path, &pathInfo) == 0 else {
            throw LeaseError.systemCall(operation: "verify path", path: path, code: errno)
        }
        let permissions = descriptorInfo.st_mode & mode_t(S_IRWXU | S_IRWXG | S_IRWXO)
        guard descriptorInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              descriptorInfo.st_uid == geteuid(),
              descriptorInfo.st_nlink == 1,
              permissions == mode_t(S_IRUSR | S_IWUSR),
              pathInfo.st_dev == descriptorInfo.st_dev,
              pathInfo.st_ino == descriptorInfo.st_ino,
              pathInfo.st_nlink == 1
        else {
            throw LeaseError.unsafeLockFile(path: path)
        }
    }

    static func validateHeldDescriptor(_ descriptor: Int32, path: String) throws {
        var descriptorInfo = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0,
              lstat(path, &pathInfo) == 0
        else {
            throw LeaseError.unsafeLockFile(path: path)
        }
        let permissions = descriptorInfo.st_mode & mode_t(S_IRWXU | S_IRWXG | S_IRWXO)
        guard descriptorInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              descriptorInfo.st_uid == geteuid(),
              descriptorInfo.st_nlink == 1,
              permissions == mode_t(S_IRUSR | S_IWUSR),
              pathInfo.st_dev == descriptorInfo.st_dev,
              pathInfo.st_ino == descriptorInfo.st_ino,
              pathInfo.st_nlink == 1
        else {
            throw LeaseError.unsafeLockFile(path: path)
        }
    }

    static func persist(receipt: some Encodable, descriptor: Int32, path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(receipt)
        } catch {
            throw LeaseError.fileSystem(operation: "encode receipt", path: path, message: error.localizedDescription)
        }
        guard !data.isEmpty, data.count <= self.maximumReceiptBytes else {
            throw LeaseError.invalidOwnerIdentity("the encoded owner receipt is too large")
        }
        guard ftruncate(descriptor, 0) == 0 else {
            throw LeaseError.systemCall(operation: "truncate receipt", path: path, code: errno)
        }

        var written = 0
        while written < data.count {
            let result = data.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return pwrite(descriptor, baseAddress.advanced(by: written), data.count - written, off_t(written))
            }
            if result < 0, errno == EINTR {
                continue
            }
            guard result > 0 else {
                throw LeaseError.systemCall(operation: "write receipt", path: path, code: errno)
            }
            written += result
        }
        guard fsync(descriptor) == 0 else {
            throw LeaseError.systemCall(operation: "persist receipt", path: path, code: errno)
        }
    }

    static func processCapabilityMarkerURL(
        processIdentifier: pid_t,
        processStartIdentity: UInt64,
        directory: URL = processCapabilityDirectoryURL) -> URL
    {
        ScreenCaptureKitProcessCapabilityRegistry.markerURL(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            directory: directory)
    }

    static func liveUncoordinatedProcesses(
        excluding currentIdentity: OwnerIdentity) throws -> [UncoordinatedProcess]
    {
        try ScreenCaptureKitProcessCapabilityRegistry.liveUncoordinatedProcesses(
            excluding: currentIdentity)
    }

    static func hasValidProcessCapability(
        processIdentifier: pid_t,
        processStartIdentity: UInt64,
        executablePath: String,
        signature: CodeSignatureIdentity?,
        directory: URL = processCapabilityDirectoryURL) -> Bool
    {
        ScreenCaptureKitProcessCapabilityRegistry.hasValidCapability(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            executablePath: executablePath,
            signature: signature,
            directory: directory)
    }

    static func isPotentialPeekabooProcess(
        executablePath: String,
        signingIdentifier: String?) -> Bool
    {
        ScreenCaptureKitProcessCapabilityRegistry.isPotentialPeekabooProcess(
            executablePath: executablePath,
            signingIdentifier: signingIdentifier)
    }

    static func removeStaleProcessCapabilityMarkers(
        directory: URL = processCapabilityDirectoryURL,
        excludingPath: String? = nil) throws
    {
        try ScreenCaptureKitProcessCapabilityRegistry.removeStaleMarkers(
            directory: directory,
            excludingPath: excludingPath)
    }

    static func validateExecutableIdentity(
        buildIdentity: String?,
        codeSignatureHash: String?,
        error makeError: (String) -> LeaseError = LeaseError.invalidOwnerIdentity) throws
    {
        let buildIdentity = buildIdentity?.trimmingCharacters(in: .whitespacesAndNewlines)
        let codeSignatureHash = codeSignatureHash?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard buildIdentity?.isEmpty == false || codeSignatureHash?.isEmpty == false else {
            throw makeError("a build or code-signature identity is required")
        }
        guard (buildIdentity?.utf8.count ?? 0) <= 1024,
              (codeSignatureHash?.utf8.count ?? 0) <= 1024
        else {
            throw makeError("the executable identity is too large")
        }
    }

    private static func currentCodeSignatureHash() -> String? {
        ScreenCaptureKitProcessCapabilityRegistry.currentCodeSignatureIdentity()?.codeSignatureHash
    }

    private static func currentExecutableBuildIdentity() throws -> String? {
        let executableURL = Bundle.main.executableURL ?? CommandLine.arguments.first.map(URL.init(fileURLWithPath:))
        guard let executableURL else { return nil }

        return try self.executableBuildIdentity(at: executableURL)
    }

    static func executableBuildIdentity(at executableURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: executableURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private final class HeldDescriptor: @unchecked Sendable {
        // Kept for process lifetime. Never close this descriptor from Swift object teardown.
        let descriptor: Int32
        let processIdentifier: pid_t
        let receipt: OwnerReceipt

        init(descriptor: Int32, processIdentifier: pid_t, receipt: OwnerReceipt) {
            self.descriptor = descriptor
            self.processIdentifier = processIdentifier
            self.receipt = receipt
        }
    }
}
