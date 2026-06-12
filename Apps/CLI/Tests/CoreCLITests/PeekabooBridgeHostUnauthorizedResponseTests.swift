import Darwin
import Foundation
import PeekabooBridge
import PeekabooCore
import Testing

struct PeekabooBridgeHostUnauthorizedResponseTests {
    @Test
    func `unauthorized clients receive an error response (not EOF)`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-host-\(UUID().uuidString).sock"

        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                hostKind: .gui,
                allowlistedTeams: ["NOT_A_REAL_TEAM"],
                allowlistedBundles: []
            )
        }

        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: ["NOT_A_REAL_TEAM"],
            requestTimeoutSec: 2
        )

        try await host.startChecked()
        defer { Task { await host.stop() } }

        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(PeekabooBridgeRequest.permissionsStatus)
        let responseData = try Self.sendUnixRequest(path: socketPath, request: requestData)
        let response = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: responseData)

        guard case let .error(envelope) = response else {
            Issue.record("Expected error response, got \(response)")
            return
        }

        #expect(envelope.code == .unauthorizedClient)
    }

    private static func sendUnixRequest(path: String, request: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let copied = path.withCString { cstr -> Int in
            strlcpy(&addr.sun_path.0, cstr, capacity)
        }
        guard copied < capacity else { throw POSIXError(.ENAMETOOLONG) }

        let addrSize = socklen_t(MemoryLayout.size(ofValue: addr))
        var localAddr = addr
        let connectResult = withUnsafePointer(to: &localAddr) { ptr -> Int32 in
            let sockAddr = UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self)
            return Darwin.connect(fd, sockAddr, addrSize)
        }
        if connectResult != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        try Self.writeAll(fd: fd, data: request)
        _ = shutdown(fd, SHUT_WR)

        return try Self.readAll(fd: fd, maxBytes: 1024 * 1024)
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = write(fd, base.advanced(by: written), data.count - written)
                if n > 0 {
                    written += n
                    continue
                }
                if n == -1, errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func readAll(fd: Int32, maxBytes: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            if n > 0 {
                data.append(buffer, count: n)
                if data.count > maxBytes { throw POSIXError(.EMSGSIZE) }
                continue
            }
            if n == 0 { return data }
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
