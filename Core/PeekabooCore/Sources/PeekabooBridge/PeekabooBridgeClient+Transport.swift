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
        let cancellation = PeekabooBridgeClientConnectionCancellation()
        let responseData: Data
        do {
            responseData = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try Self.sendBlocking(
                        socketPath: socketPath,
                        requestData: payload,
                        maxResponseBytes: maxResponseBytes,
                        timeoutSec: requestTimeoutSec,
                        cancellation: cancellation)
                }.value
            } onCancel: {
                cancellation.cancel()
            }
        } catch let failure as PeekabooBridgeResponseReadFailure {
            guard request.mayMutateDesktop else {
                throw failure.underlying
            }
            throw Self.responseLostFailure(
                operation: op,
                causeDescription: "\(failure.underlying)")
        }
        guard !responseData.isEmpty else {
            let details = """
            EOF while reading response for \(op.rawValue).

            This usually means the host closed the socket before replying \
            (often due to an authorization/TeamID check). \
            Update Peekaboo.app / ClawdBot.app to a host build that returns a structured \
            `unauthorizedClient` response, or launch the host with \
            PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS=1 for local development.
            """

            guard request.mayMutateDesktop else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .internalError,
                    message: "Bridge host returned no response",
                    details: details)
            }
            throw Self.responseLostFailure(
                operation: op,
                causeDescription: details)
        }

        let response: PeekabooBridgeResponse
        do {
            response = try self.decoder.decode(PeekabooBridgeResponse.self, from: responseData)
        } catch {
            guard request.mayMutateDesktop else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .decodingFailed,
                    message: "Bridge host returned an invalid response",
                    details: "\(error)")
            }
            throw Self.responseLostFailure(
                operation: op,
                causeDescription: "Bridge response decoding failed: \(error)")
        }
        if case let .error(envelope) = response,
           request.mayMutateDesktop
        {
            if let failure = envelope.desktopActionFailure {
                throw failure
            }
            if envelope.operationMayHaveCompleted {
                throw Self.legacyCompletionUnknownFailure(envelope: envelope)
            }
        }
        let duration = Date().timeIntervalSince(start)
        self.logger.debug(
            "bridge \(op.rawValue, privacy: .public) completed in \(duration, format: .fixed(precision: 3))s")
        return response
    }

    func sendExpectOK(
        _ request: PeekabooBridgeRequest,
        timeoutSec: TimeInterval? = nil) async throws
    {
        let response = try await self.send(request, timeoutSec: timeoutSec)
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
        timeoutSec: TimeInterval,
        cancellation: PeekabooBridgeClientConnectionCancellation) throws -> Data
    {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try cancellation.install(fd: fd)
        defer {
            cancellation.clear(fd: fd)
            close(fd)
        }

        do {
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

            try cancellation.check()
            try PeekabooBridgeSocketIO.writeAll(fd: fd, data: requestData, deadline: deadline)
            do {
                guard shutdown(fd, SHUT_WR) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let response = try PeekabooBridgeSocketIO.readAll(
                    fd: fd,
                    maxBytes: maxResponseBytes,
                    deadline: deadline)
                try cancellation.check()
                return response
            } catch {
                let responseFailure: any Error
                do {
                    try cancellation.check()
                    responseFailure = error
                } catch let cancellationError {
                    responseFailure = cancellationError
                }
                throw PeekabooBridgeResponseReadFailure(underlying: responseFailure)
            }
        } catch let responseFailure as PeekabooBridgeResponseReadFailure {
            throw responseFailure
        } catch {
            try cancellation.check()
            throw error
        }
    }

    private nonisolated static func responseLostFailure(
        operation: PeekabooBridgeOperation,
        causeDescription: String) -> DesktopActionFailure
    {
        let message = "Bridge response was lost after \(operation.rawValue) was dispatched; " +
            "outcome is indeterminate; do not retry"
        return DesktopActionFailure.indeterminate(
            route: .bridge,
            evidence: .responseLost,
            message: message,
            hint: "Observe the target before retrying this operation.",
            causeDescription: causeDescription)
    }

    private nonisolated static func legacyCompletionUnknownFailure(
        envelope: PeekabooBridgeErrorEnvelope) -> DesktopActionFailure
    {
        DesktopActionFailure.indeterminate(
            route: .bridge,
            evidence: .completionUnknown,
            message: envelope.message,
            hint: "Observe the target before retrying this operation.",
            causeDescription: envelope.details)
    }
}

private struct PeekabooBridgeResponseReadFailure: Error {
    let underlying: any Error
}

/// Wakes blocking socket I/O when the Swift caller is cancelled. The blocking worker remains the sole owner of
/// `close(2)` so cancellation cannot close a descriptor that the kernel has already recycled for another request.
final class PeekabooBridgeClientConnectionCancellation: @unchecked Sendable {
    typealias ShutdownHandler = @Sendable (Int32) -> Void

    private let lock = NSLock()
    private let shutdownHandler: ShutdownHandler
    private var fileDescriptor: Int32?
    private var isCancelled = false

    init(shutdownHandler: @escaping ShutdownHandler = { fd in
        _ = shutdown(fd, SHUT_RDWR)
    }) {
        self.shutdownHandler = shutdownHandler
    }

    func install(fd: Int32) throws {
        self.lock.lock()
        if self.isCancelled {
            self.lock.unlock()
            close(fd)
            throw CancellationError()
        }
        self.fileDescriptor = fd
        self.lock.unlock()
    }

    func cancel() {
        self.lock.lock()
        self.isCancelled = true
        if let fd = self.fileDescriptor {
            // `clear(fd:)` cannot release this descriptor for close/reuse until shutdown completes.
            self.shutdownHandler(fd)
        }
        self.lock.unlock()
    }

    func clear(fd: Int32) {
        self.lock.lock()
        if self.fileDescriptor == fd {
            self.fileDescriptor = nil
        }
        self.lock.unlock()
    }

    func check() throws {
        self.lock.lock()
        let isCancelled = self.isCancelled
        self.lock.unlock()
        if isCancelled {
            throw CancellationError()
        }
    }
}
