import Darwin
import Foundation

/// Earliest-process authorization latch for a Bridge-owned Agent child.
///
/// `POSIX_SPAWN_START_SUSPENDED` lets the host attest the child before it runs, but any process
/// with signal authority can send `SIGCONT`. The anonymous pipe remains the actual gate: only the
/// Bridge retains its write end, and the CLI performs no command routing until it receives the
/// exact run challenge and EOF.
public enum AgentExecutionReleaseGate {
    public static let descriptorEnvironmentKey = "PEEKABOO_AGENT_EXECUTION_GATE_FD"
    public static let challengeEnvironmentKey = "PEEKABOO_AGENT_EXECUTION_GATE_CHALLENGE"
    public static let lockdownDescriptorEnvironmentKey = "PEEKABOO_AGENT_EXECUTION_LOCKDOWN_FD"
    public static let processCreationLimitEnvironmentKey = "PEEKABOO_AGENT_EXECUTION_PROCESS_LIMIT"
    public static let processCreationLimit: rlim_t = 0

    @discardableResult
    public static func waitIfConfigured() throws -> Bool {
        let descriptorValue = getenv(self.descriptorEnvironmentKey).map { String(cString: $0) }
        let challenge = getenv(self.challengeEnvironmentKey).map { String(cString: $0) }
        let lockdownDescriptorValue = getenv(self.lockdownDescriptorEnvironmentKey).map { String(cString: $0) }
        let processCreationLimitValue = getenv(self.processCreationLimitEnvironmentKey).map { String(cString: $0) }
        guard descriptorValue != nil || challenge != nil || lockdownDescriptorValue != nil ||
            processCreationLimitValue != nil
        else { return false }
        unsetenv(self.descriptorEnvironmentKey)
        unsetenv(self.challengeEnvironmentKey)
        unsetenv(self.lockdownDescriptorEnvironmentKey)
        unsetenv(self.processCreationLimitEnvironmentKey)
        guard let descriptorValue,
              let descriptor = Int32(descriptorValue),
              descriptor > STDERR_FILENO,
              descriptor < 1024,
              let lockdownDescriptorValue,
              let lockdownDescriptor = Int32(lockdownDescriptorValue),
              lockdownDescriptor > STDERR_FILENO,
              lockdownDescriptor < 1024,
              lockdownDescriptor != descriptor,
              let challenge,
              self.isChallenge(challenge),
              processCreationLimitValue == String(self.processCreationLimit)
        else {
            throw ReleaseGateError.invalidConfiguration
        }
        try self.applyProcessCreationLimit()
        try self.announceLockdown(
            descriptor: lockdownDescriptor,
            challenge: challenge
        )
        try self.wait(descriptor: descriptor, challenge: challenge)
        return true
    }

    private static func announceLockdown(descriptor: Int32, challenge: String) throws {
        guard descriptor > STDERR_FILENO,
              fcntl(descriptor, F_GETFD) >= 0,
              self.isChallenge(challenge)
        else { throw ReleaseGateError.invalidConfiguration }
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0,
              fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0
        else { throw ReleaseGateError.invalidConfiguration }
        defer { close(descriptor) }
        let bytes = Array(challenge.utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: written),
                    buffer.count - written
                )
            }
            if count > 0 {
                written += count
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            throw ReleaseGateError.lockdownReadinessFailed(errno)
        }
    }

    private static func applyProcessCreationLimit() throws {
        guard getuid() != 0, geteuid() == getuid(), issetugid() == 0 else {
            throw ReleaseGateError.unsupportedEffectiveUser
        }
        var requested = rlimit(
            rlim_cur: self.processCreationLimit,
            rlim_max: self.processCreationLimit
        )
        guard setrlimit(RLIMIT_NPROC, &requested) == 0 else {
            throw ReleaseGateError.processCreationLimitFailed(errno)
        }
        var observed = rlimit()
        guard getrlimit(RLIMIT_NPROC, &observed) == 0 else {
            throw ReleaseGateError.processCreationLimitReadbackFailed(errno)
        }
        guard observed.rlim_cur == self.processCreationLimit,
              observed.rlim_max == self.processCreationLimit
        else {
            throw ReleaseGateError.processCreationLimitMismatch
        }
    }

    static func wait(descriptor: Int32, challenge: String) throws {
        guard descriptor > STDERR_FILENO,
              fcntl(descriptor, F_GETFD) >= 0,
              self.isChallenge(challenge)
        else {
            throw ReleaseGateError.invalidConfiguration
        }
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw ReleaseGateError.invalidConfiguration
        }
        defer { close(descriptor) }

        var bytes = [UInt8](repeating: 0, count: challenge.utf8.count)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset
                )
            }
            if count > 0 {
                offset += count
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            throw ReleaseGateError.incompleteRelease
        }

        var trailingByte: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &trailingByte, 1)
            if count == 0 {
                break
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count < 0 else { throw ReleaseGateError.trailingBytes }
            throw ReleaseGateError.readFailed(errno)
        }
        guard bytes.elementsEqual(challenge.utf8) else {
            throw ReleaseGateError.challengeMismatch
        }
    }

    private static func isChallenge(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) ||
                (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    enum ReleaseGateError: LocalizedError {
        case invalidConfiguration
        case unsupportedEffectiveUser
        case processCreationLimitFailed(Int32)
        case processCreationLimitReadbackFailed(Int32)
        case processCreationLimitMismatch
        case lockdownReadinessFailed(Int32)
        case incompleteRelease
        case trailingBytes
        case challengeMismatch
        case readFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration:
                "invalid inherited descriptor or challenge"
            case .unsupportedEffectiveUser:
                "Agent execution cannot enforce process creation denial for the root user"
            case let .processCreationLimitFailed(code):
                "cannot deny Agent child process creation (errno \(code))"
            case let .processCreationLimitReadbackFailed(code):
                "cannot verify Agent child process creation denial (errno \(code))"
            case .processCreationLimitMismatch:
                "Agent child process creation denial did not retain its hard limit"
            case let .lockdownReadinessFailed(code):
                "cannot attest Agent child process creation denial (errno \(code))"
            case .incompleteRelease:
                "the Bridge closed the release gate before authorization completed"
            case .trailingBytes:
                "the Bridge release gate contained unexpected trailing bytes"
            case .challengeMismatch:
                "the Bridge release challenge did not match this execution"
            case let .readFailed(code):
                "release gate read failed with errno \(code)"
            }
        }
    }

    #if DEBUG
    public struct ProcessCreationProbe: Codable {
        public let limitReadback: Bool
        public let hardLimitCannotRaise: Bool
        public let forkDenied: Bool
        public let vforkDenied: Bool
        public let posixSpawnDenied: Bool

        public var success: Bool {
            self.limitReadback && self.hardLimitCannotRaise && self.forkDenied &&
                self.vforkDenied && self.posixSpawnDenied
        }
    }

    public static func processCreationProbe() -> ProcessCreationProbe {
        var observed = rlimit()
        let limitReadback = getrlimit(RLIMIT_NPROC, &observed) == 0 &&
            observed.rlim_cur == self.processCreationLimit &&
            observed.rlim_max == self.processCreationLimit

        var raised = rlimit(rlim_cur: 1, rlim_max: 1)
        errno = 0
        let hardLimitCannotRaise = setrlimit(RLIMIT_NPROC, &raised) == -1 && errno == EPERM

        typealias ForkFunction = @convention(c) () -> pid_t
        let handle = dlopen(nil, RTLD_NOW)
        defer {
            if let handle {
                dlclose(handle)
            }
        }
        let forkFunction = handle.flatMap { dlsym($0, "fork") }.map {
            unsafeBitCast($0, to: ForkFunction.self)
        }
        errno = 0
        let forkResult = forkFunction?() ?? -1
        let forkDenied = forkResult == -1 && errno == EAGAIN
        if forkResult == 0 {
            Darwin._exit(90)
        }
        if forkResult > 0 {
            var status: Int32 = 0
            _ = Darwin.waitpid(forkResult, &status, 0)
        }

        let vforkFunction = handle.flatMap { dlsym($0, "vfork") }.map {
            unsafeBitCast($0, to: ForkFunction.self)
        }
        errno = 0
        let vforkResult = vforkFunction?() ?? -1
        let vforkDenied = vforkResult == -1 && errno == EAGAIN
        if vforkResult == 0 {
            Darwin._exit(91)
        }
        if vforkResult > 0 {
            var status: Int32 = 0
            _ = Darwin.waitpid(vforkResult, &status, 0)
        }

        var spawnedPID: pid_t = 0
        let arguments = [strdup("/usr/bin/true"), nil]
        defer { free(arguments[0]) }
        let spawnResult = arguments.withUnsafeBufferPointer { buffer in
            posix_spawn(&spawnedPID, "/usr/bin/true", nil, nil, buffer.baseAddress, environ)
        }
        if spawnResult == 0 {
            var status: Int32 = 0
            _ = Darwin.waitpid(spawnedPID, &status, 0)
        }
        return .init(
            limitReadback: limitReadback,
            hardLimitCannotRaise: hardLimitCannotRaise,
            forkDenied: forkDenied,
            vforkDenied: vforkDenied,
            posixSpawnDenied: spawnResult == EAGAIN
        )
    }
    #endif
}
