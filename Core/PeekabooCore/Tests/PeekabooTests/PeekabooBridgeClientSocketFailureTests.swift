import Darwin
import Foundation
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeClientSocketFailureTests {
    @Test(arguments: [false, true])
    func `late response after timeout or cancellation cannot replace the next response`(cancel: Bool) async throws {
        let peer = try ConcurrentGatedBridgePeer()
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 2)
        do {
            async let negotiation = client.handshake(
                client: .init(
                    bundleIdentifier: "dev.peekaboo.closed-peer-tests",
                    teamIdentifier: nil,
                    processIdentifier: getpid()),
                protocolVersion: .init(major: 1, minor: 28))
            let handshakeRequest = try await peer.nextRequest()
            let isHandshake = if case .handshake = try handshakeRequest.decode() {
                true
            } else {
                false
            }
            try #require(isHandshake)
            try await peer.respond(.handshake(BridgeTestFixtures.handshake(
                negotiatedVersion: .init(major: 1, minor: 28),
                supportedOperations: [.getFocusedWindow, .listApplications])), to: handshakeRequest)
            _ = try await negotiation

            let pending = Task { try await client.getFocusedWindow() }
            do {
                let expiredRequest = try await peer.nextRequest()
                #expect(try expiredRequest.decode().operation == .getFocusedWindow)
                if cancel {
                    pending.cancel()
                }
                do {
                    _ = try await pending.value
                    Issue.record("Expected the gated request to time out or be cancelled")
                } catch let error as POSIXError {
                    #expect(!cancel)
                    #expect(error.code == .ETIMEDOUT)
                } catch is CancellationError {
                    #expect(cancel)
                }

                async let applications = client.listApplications()
                let currentRequest = try await peer.nextRequest()
                #expect(try currentRequest.decode().operation == .listApplications)
                // Release the stale connection only after its successor is also waiting for a response.
                try await peer.respond(.window(nil), to: expiredRequest)
                try await peer.respond(.applications([]), to: currentRequest)
                let result = try await applications
                #expect(result.isEmpty)
                #expect(await peer.acceptedConnectionCount == 3)
            } catch {
                pending.cancel()
                _ = await pending.result
                throw error
            }
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

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
