import Darwin
import Foundation
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeClientSocketFailureTests {
    @Test
    func `client write after peer close returns EPIPE with socket scoped SIGPIPE protection`() async throws {
        let socketPath = "/tmp/pb-closed-peer-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer {
            Darwin.close(listener)
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout.size(ofValue: address))
        let copied = socketPath.withCString {
            strlcpy(&address.sun_path.0, $0, MemoryLayout.size(ofValue: address.sun_path))
        }
        try #require(copied < MemoryLayout.size(ofValue: address.sun_path))
        let length = socklen_t(MemoryLayout.size(ofValue: address))
        let bound = withUnsafePointer(to: &address) {
            Darwin.bind(listener, UnsafePointer<sockaddr>(OpaquePointer($0)), length)
        }
        try #require(bound == 0)
        try #require(listen(listener, 1) == 0)
        let flags = fcntl(listener, F_GETFL)
        try #require(flags >= 0)
        try #require(fcntl(listener, F_SETFL, flags | O_NONBLOCK) == 0)

        let client = PeekabooBridgeClient(
            socketPath: socketPath,
            requestTimeoutSec: 2,
            trustedHostTeamIDs: [TrustedBridgeClientFixture.teamIdentifier],
            hostAuthentication: .init(
                liveIdentity: { fd in
                    let identity = try PeekabooBridgeSocketIO.livePeerIdentity(fd: fd)
                    var noSigPipe: Int32 = 0
                    var optionLength = socklen_t(MemoryLayout.size(ofValue: noSigPipe))
                    try #require(getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, &optionLength) == 0)
                    #expect(noSigPipe == 1)

                    // This hook runs after connect and before writeAll: no sleep or close/write race.
                    let peer = accept(listener, nil, nil)
                    try #require(peer >= 0)
                    try #require(Darwin.close(peer) == 0)
                    return identity
                },
                signingIdentity: { _ in nil }))

        do {
            _ = try await client.handshake(client: .init(
                bundleIdentifier: "dev.peekaboo.closed-peer-tests",
                teamIdentifier: nil,
                processIdentifier: getpid()))
            Issue.record("Expected the request write to fail after its peer closed")
        } catch let error as POSIXError {
            #expect(error.code == .EPIPE)
        }
    }
}
