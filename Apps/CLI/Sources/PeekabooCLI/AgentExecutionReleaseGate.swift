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

    public static func waitIfConfigured() throws {
        let descriptorValue = getenv(self.descriptorEnvironmentKey).map { String(cString: $0) }
        let challenge = getenv(self.challengeEnvironmentKey).map { String(cString: $0) }
        guard descriptorValue != nil || challenge != nil else { return }
        unsetenv(self.descriptorEnvironmentKey)
        unsetenv(self.challengeEnvironmentKey)
        guard let descriptorValue,
              let descriptor = Int32(descriptorValue),
              descriptor > STDERR_FILENO,
              descriptor < 1024,
              let challenge,
              self.isChallenge(challenge)
        else {
            throw ReleaseGateError.invalidConfiguration
        }
        try self.wait(descriptor: descriptor, challenge: challenge)
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
        case incompleteRelease
        case trailingBytes
        case challengeMismatch
        case readFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration:
                "invalid inherited descriptor or challenge"
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
}
