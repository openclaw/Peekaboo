import Darwin
import Foundation

enum PeekabooBridgeSocketIO {
    static func peerProcessIdentifier(fd: Int32) throws -> pid_t {
        var processIdentifier: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &processIdentifier, &size) == 0,
              processIdentifier > 0,
              size == MemoryLayout<pid_t>.size
        else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPROTO)
        }
        return processIdentifier
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
