import Darwin
import Foundation
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeSocketIOTests {
    @Test
    func `read times out when peer remains idle`() throws {
        let sockets = try Self.socketPair()
        defer {
            close(sockets.reader)
            close(sockets.writer)
        }
        try PeekabooBridgeSocketIO.configureConnectedSocket(sockets.reader)

        do {
            _ = try PeekabooBridgeSocketIO.readAll(
                fd: sockets.reader,
                maxBytes: 1024,
                deadline: Date().addingTimeInterval(0.05))
            Issue.record("Expected idle read to time out")
        } catch let error as POSIXError {
            #expect(error.code == .ETIMEDOUT)
        }
    }

    @Test
    func `write times out when peer does not drain its socket`() throws {
        let sockets = try Self.socketPair()
        defer {
            close(sockets.reader)
            close(sockets.writer)
        }
        try PeekabooBridgeSocketIO.configureConnectedSocket(sockets.writer)

        var sendBufferBytes: Int32 = 4096
        #expect(setsockopt(
            sockets.writer,
            SOL_SOCKET,
            SO_SNDBUF,
            &sendBufferBytes,
            socklen_t(MemoryLayout.size(ofValue: sendBufferBytes))) == 0)

        do {
            try PeekabooBridgeSocketIO.writeAll(
                fd: sockets.writer,
                data: Data(repeating: 0xAB, count: 8 * 1024 * 1024),
                deadline: Date().addingTimeInterval(0.05))
            Issue.record("Expected undrained write to time out")
        } catch let error as POSIXError {
            #expect(error.code == .ETIMEDOUT)
        }
    }

    @Test
    func `nonblocking transport preserves a complete payload`() throws {
        let sockets = try Self.socketPair()
        defer {
            close(sockets.reader)
            close(sockets.writer)
        }
        try PeekabooBridgeSocketIO.configureConnectedSocket(sockets.reader)
        try PeekabooBridgeSocketIO.configureConnectedSocket(sockets.writer)

        let expected = Data("bridge payload".utf8)
        try PeekabooBridgeSocketIO.writeAll(
            fd: sockets.writer,
            data: expected,
            deadline: Date().addingTimeInterval(1))
        #expect(shutdown(sockets.writer, SHUT_WR) == 0)

        let received = try PeekabooBridgeSocketIO.readAll(
            fd: sockets.reader,
            maxBytes: 1024,
            deadline: Date().addingTimeInterval(1))
        #expect(received == expected)
    }

    private static func socketPair() throws -> (reader: Int32, writer: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (descriptors[0], descriptors[1])
    }
}
