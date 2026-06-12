import Darwin
import Foundation
import PeekabooFoundation

extension PeekabooBridgeClient {
    func send(
        _ request: PeekabooBridgeRequest,
        timeoutSec: TimeInterval? = nil) async throws -> PeekabooBridgeResponse
    {
        let payload = try self.encoder.encode(request)
        let op = request.operation
        let start = Date()
        self.logger.debug("Sending bridge request \(op.rawValue, privacy: .public)")

        let effectiveTimeoutSec = timeoutSec ?? self.requestTimeoutSec
        let (socketPath, maxResponseBytes, requestTimeoutSec) =
            (self.socketPath, self.maxResponseBytes, effectiveTimeoutSec)
        let responseData = try await Task.detached(priority: .userInitiated) {
            try Self.sendBlocking(
                socketPath: socketPath,
                requestData: payload,
                maxResponseBytes: maxResponseBytes,
                timeoutSec: requestTimeoutSec)
        }.value

        guard !responseData.isEmpty else {
            let details = """
            EOF while reading response for \(op.rawValue).

            This usually means the host closed the socket before replying \
            (often due to an authorization/TeamID check). \
            Update Peekaboo.app / ClawdBot.app to a host build that returns a structured \
            `unauthorizedClient` response, or launch the host with \
            PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS=1 for local development.
            """

            throw PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: "Bridge host returned no response",
                details: details)
        }

        let response: PeekabooBridgeResponse
        do {
            response = try self.decoder.decode(PeekabooBridgeResponse.self, from: responseData)
        } catch {
            throw PeekabooBridgeErrorEnvelope(
                code: .decodingFailed,
                message: "Bridge host returned an invalid response",
                details: "\(error)")
        }
        let duration = Date().timeIntervalSince(start)
        self.logger.debug(
            "bridge \(op.rawValue, privacy: .public) completed in \(duration, format: .fixed(precision: 3))s")
        return response
    }

    func sendExpectOK(_ request: PeekabooBridgeRequest) async throws {
        let response = try await self.send(request)
        switch response {
        case .ok:
            return
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected response for void request")
        }
    }

    private nonisolated static func disableSigPipe(fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
    }

    private nonisolated static func sendBlocking(
        socketPath: String,
        requestData: Data,
        maxResponseBytes: Int,
        timeoutSec: TimeInterval) throws -> Data
    {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }

        Self.disableSigPipe(fd: fd)
        try PeekabooBridgeSocketIO.configureConnectedSocket(fd)
        let deadline = Date().addingTimeInterval(timeoutSec)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let copied = socketPath.withCString { cstr -> Int in
            strlcpy(&addr.sun_path.0, cstr, capacity)
        }
        guard copied < capacity else { throw POSIXError(.ENAMETOOLONG) }
        addr.sun_len = UInt8(MemoryLayout.size(ofValue: addr))

        let len = socklen_t(MemoryLayout.size(ofValue: addr))
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            connect(fd, UnsafePointer<sockaddr>(OpaquePointer(ptr)), len)
        }
        if connectResult != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN || errno == EALREADY else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
            }
            try PeekabooBridgeSocketIO.finishConnect(fd: fd, deadline: deadline)
        }

        try PeekabooBridgeSocketIO.writeAll(fd: fd, data: requestData, deadline: deadline)
        _ = shutdown(fd, SHUT_WR)

        return try PeekabooBridgeSocketIO.readAll(fd: fd, maxBytes: maxResponseBytes, deadline: deadline)
    }
}
