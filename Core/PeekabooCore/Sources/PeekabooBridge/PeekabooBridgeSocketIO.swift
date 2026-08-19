import Darwin
import Foundation
import PeekabooAutomationKit

struct PeekabooBridgePeerAuditIdentity {
    let token: audit_token_t
    let processIdentifier: pid_t
    let processIdentifierVersion: Int32
    let effectiveUserIdentifier: uid_t

    var tokenData: Data {
        withUnsafeBytes(of: self.token) { Data($0) }
    }
}

/// Exact kernel identity captured from one connected UNIX-domain socket peer.
///
/// The audit token is deliberately retained only in bounded in-memory operation-session state. It is never encoded,
/// persisted, or logged.
struct PeekabooBridgeLivePeerIdentity: Equatable, Hashable, Sendable {
    let auditToken: Data
    let processIdentifier: pid_t
    let processIdentifierVersion: Int32
    let effectiveUserIdentifier: uid_t
    let processStartIdentity: UInt64
    /// Optional only for cold legacy authorization; protocol 1.29 sessions require a stable nonempty kernel hash.
    let codeSignatureHash: String?

    init(
        auditIdentity: PeekabooBridgePeerAuditIdentity,
        processStartIdentity: UInt64,
        codeSignatureHash: String?)
    {
        self.auditToken = auditIdentity.tokenData
        self.processIdentifier = auditIdentity.processIdentifier
        self.processIdentifierVersion = auditIdentity.processIdentifierVersion
        self.effectiveUserIdentifier = auditIdentity.effectiveUserIdentifier
        self.processStartIdentity = processStartIdentity
        self.codeSignatureHash = codeSignatureHash
    }

    init(
        auditToken: Data,
        processIdentifier: pid_t,
        processIdentifierVersion: Int32,
        effectiveUserIdentifier: uid_t,
        processStartIdentity: UInt64,
        codeSignatureHash: String?)
    {
        self.auditToken = auditToken
        self.processIdentifier = processIdentifier
        self.processIdentifierVersion = processIdentifierVersion
        self.effectiveUserIdentifier = effectiveUserIdentifier
        self.processStartIdentity = processStartIdentity
        self.codeSignatureHash = codeSignatureHash
    }

    var auditIdentity: PeekabooBridgePeerAuditIdentity? {
        guard self.auditToken.count == MemoryLayout<audit_token_t>.size else { return nil }
        var token = audit_token_t()
        _ = withUnsafeMutableBytes(of: &token) { buffer in
            self.auditToken.copyBytes(to: buffer)
        }
        guard audit_token_to_pid(token) == self.processIdentifier,
              audit_token_to_pidversion(token) == self.processIdentifierVersion,
              audit_token_to_euid(token) == self.effectiveUserIdentifier
        else {
            return nil
        }
        return PeekabooBridgePeerAuditIdentity(
            token: token,
            processIdentifier: self.processIdentifier,
            processIdentifierVersion: self.processIdentifierVersion,
            effectiveUserIdentifier: self.effectiveUserIdentifier)
    }
}

enum PeekabooBridgeSocketIO {
    typealias ProcessStartIdentityProvider = @Sendable (pid_t) -> UInt64?

    static func peerAuditIdentity(fd: Int32) throws -> PeekabooBridgePeerAuditIdentity {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPROTO)
        }
        let processIdentifier = audit_token_to_pid(token)
        let processIdentifierVersion = audit_token_to_pidversion(token)
        guard size == MemoryLayout<audit_token_t>.size,
              processIdentifier > 0
        else {
            throw POSIXError(.EPROTO)
        }
        return PeekabooBridgePeerAuditIdentity(
            token: token,
            processIdentifier: processIdentifier,
            processIdentifierVersion: processIdentifierVersion,
            effectiveUserIdentifier: audit_token_to_euid(token))
    }

    /// Captures the exact peer generation without consulting executable-path metadata.
    static func livePeerIdentity(
        fd: Int32,
        processStartIdentityProvider: ProcessStartIdentityProvider = {
            SystemIdentityResolver.processStartIdentity($0)
        },
        codeSignatureHashProvider: (PeekabooBridgePeerAuditIdentity) -> String? = {
            PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(auditIdentity: $0)
        }) throws -> PeekabooBridgeLivePeerIdentity
    {
        let auditIdentity = try self.peerAuditIdentity(fd: fd)
        guard let processStartIdentityBefore = processStartIdentityProvider(auditIdentity.processIdentifier),
              processStartIdentityBefore > 0
        else {
            throw POSIXError(.EPROTO)
        }
        let capturedCodeSignatureHash = codeSignatureHashProvider(auditIdentity)
        let codeSignatureHash = capturedCodeSignatureHash?.isEmpty == false
            ? capturedCodeSignatureHash
            : nil
        guard processStartIdentityProvider(auditIdentity.processIdentifier) == processStartIdentityBefore else {
            throw POSIXError(.EPROTO)
        }
        return PeekabooBridgeLivePeerIdentity(
            auditIdentity: auditIdentity,
            processStartIdentity: processStartIdentityBefore,
            codeSignatureHash: codeSignatureHash)
    }

    static func configureConnectedSocket(_ fd: Int32) throws {
        try self.setCloseOnExec(fd)

        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func setCloseOnExec(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func finishConnect(fd: Int32, deadline: Date) throws {
        _ = try self.wait(fd: fd, events: Int16(POLLOUT), deadline: deadline)

        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout.size(ofValue: socketError))
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard socketError == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: socketError) ?? .EIO)
        }
    }

    static func readAll(fd: Int32, maxBytes: Int, deadline: Date) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            _ = try self.wait(fd: fd, events: Int16(POLLIN), deadline: deadline)

            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            if count > 0 {
                data.append(buffer, count: count)
                if data.count > maxBytes {
                    throw POSIXError(.EMSGSIZE)
                }
                continue
            }
            if count == 0 {
                return data
            }
            if errno == EINTR || errno == EAGAIN {
                continue
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func writeAll(fd: Int32, data: Data, deadline: Date) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var written = 0

            while written < data.count {
                guard deadline.timeIntervalSinceNow > 0 else {
                    throw POSIXError(.ETIMEDOUT)
                }

                let count = write(fd, baseAddress.advanced(by: written), data.count - written)
                if count > 0 {
                    written += count
                    continue
                }
                if count == -1, errno == EINTR {
                    continue
                }
                if count == -1, errno == EAGAIN {
                    _ = try self.wait(fd: fd, events: Int16(POLLOUT), deadline: deadline)
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    /// Checks whether the peer can still receive the response without writing or consuming protocol bytes.
    ///
    /// Bridge clients intentionally half-close their write side after sending one request. That makes the server's
    /// read side report EOF for the entire response wait, so read readiness cannot distinguish a waiting client from
    /// a fully closed one. Darwin's write-side poll reports `POLLOUT` while the peer can receive and a terminal event
    /// after its receive side disappears.
    static func peerCanReceiveResponse(fd: Int32) -> Bool {
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let result = poll(&descriptor, 1, 0)
            if result == 0 {
                // A full send buffer is not a disconnect.
                return true
            }
            if result < 0 {
                if errno == EINTR {
                    continue
                }
                return false
            }

            let terminalEvents = Int16(POLLERR | POLLHUP | POLLNVAL)
            return descriptor.revents & terminalEvents == 0
        }
    }

    private static func wait(fd: Int32, events: Int16, deadline: Date) throws -> Int16 {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw POSIXError(.ETIMEDOUT)
            }

            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let timeoutMs = Int32(ceil(max(1.0, min(remaining, 0.25) * 1000.0)))
            let result = poll(&descriptor, 1, timeoutMs)
            if result == 0 {
                continue
            }
            if result < 0 {
                if errno == EINTR {
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if descriptor.revents & Int16(POLLNVAL) != 0 {
                throw POSIXError(.EBADF)
            }
            return descriptor.revents
        }
    }
}
