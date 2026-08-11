import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
struct PeekabooBridgeClientTransportOutcomeTests {
    @Test
    func `mutation response timeout is indeterminate and retry unsafe`() async throws {
        let peer = try ScriptedBridgePeer(behavior: .idle(seconds: 0.15))
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 0.05)

        do {
            try await client.sendExpectOK(Self.clickRequest)
            Issue.record("Expected the response read to time out")
        } catch let error as PeekabooBridgeErrorEnvelope {
            #expect(error.code == .timeout)
            #expect(error.operationMayHaveCompleted)
            #expect(error.message.contains("indeterminate"))
            #expect(error.message.contains("do not retry"))
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `read-only response timeout remains an ordinary transport failure`() async throws {
        let peer = try ScriptedBridgePeer(behavior: .idle(seconds: 0.15))
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 0.05)

        do {
            _ = try await client.send(.permissionsStatus)
            Issue.record("Expected the response read to time out")
        } catch let error as POSIXError {
            #expect(error.code == .ETIMEDOUT)
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `handshake timeout is shared across protocol fallback attempts`() async throws {
        let peer = try VersionMismatchBridgePeer(firstResponseDelay: 0.3)
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil)
        let startedAt = ContinuousClock.now

        do {
            _ = try await client.handshake(client: identity, overallTimeoutSec: 1)
            Issue.record("Expected the negotiated handshake to exhaust its shared deadline")
        } catch let error as POSIXError {
            #expect(error.code == .ETIMEDOUT)
        }

        let elapsed = startedAt.duration(to: .now)
        #expect(elapsed >= .milliseconds(850))
        #expect(elapsed < .milliseconds(1200))
        #expect(await peer.acceptedConnectionCount == 2)
        await peer.stop()
    }

    @Test
    func `mutation response EOF is indeterminate and retry unsafe`() async throws {
        let peer = try ScriptedBridgePeer(behavior: .closeWithoutResponse)
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)

        do {
            try await client.sendExpectOK(Self.clickRequest)
            Issue.record("Expected response EOF")
        } catch let error as PeekabooBridgeErrorEnvelope {
            #expect(error.code == .internalError)
            #expect(error.operationMayHaveCompleted)
            #expect(error.message.contains("indeterminate"))
            #expect(error.message.contains("do not retry"))
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `read-only response EOF remains retry safe`() async throws {
        let peer = try ScriptedBridgePeer(behavior: .closeWithoutResponse)
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)

        do {
            _ = try await client.send(.permissionsStatus)
            Issue.record("Expected response EOF")
        } catch let error as PeekabooBridgeErrorEnvelope {
            #expect(error.code == .internalError)
            #expect(!error.operationMayHaveCompleted)
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `mutation malformed response is indeterminate and retry unsafe`() async throws {
        let peer = try ScriptedBridgePeer(behavior: .respond(Data("not-json".utf8)))
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)

        do {
            try await client.sendExpectOK(Self.clickRequest)
            Issue.record("Expected response decoding failure")
        } catch let error as PeekabooBridgeErrorEnvelope {
            #expect(error.code == .decodingFailed)
            #expect(error.operationMayHaveCompleted)
            #expect(error.message.contains("indeterminate"))
            #expect(error.message.contains("do not retry"))
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `mutation connect failure remains retry safe`() async {
        let socketPath = "/tmp/pb-missing-\(UUID().uuidString).sock"
        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 0.05)

        do {
            try await client.sendExpectOK(Self.clickRequest)
            Issue.record("Expected connect failure")
        } catch let error as PeekabooBridgeErrorEnvelope {
            Issue.record("Pre-send failure must not become an indeterminate envelope: \(error)")
        } catch let error as POSIXError {
            #expect(error.code == .ENOENT || error.code == .ECONNREFUSED)
        } catch {
            Issue.record("Expected POSIX connect failure, got \(error)")
        }
    }

    @Test
    @MainActor
    func `remote targeted click maps response loss to retry-unsafe delivery`() async throws {
        let peer = try ScriptedBridgePeer(behavior: .idle(seconds: 0.15))
        let remote = RemoteUIAutomationService(
            client: PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 0.05),
            supportsTargetedClicks: true)

        do {
            try await remote.click(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                targetProcessIdentifier: 42)
            Issue.record("Expected indeterminate targeted click delivery")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.operation == .click)
            #expect(error.operationMayHaveCompleted)
            #expect(!error.retrySafe)
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `desktop mutation classifier covers input delivery but not read-only status`() {
        #expect(Self.clickRequest.mayMutateDesktop)
        #expect(PeekabooBridgeRequest.typeActions(.init(
            actions: [.text("x")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil)).mayMutateDesktop)
        #expect(PeekabooBridgeRequest.hotkey(.init(keys: "cmd,a", holdDuration: 0)).mayMutateDesktop)
        #expect(!PeekabooBridgeRequest.permissionsStatus.mayMutateDesktop)
    }

    private static let clickRequest = PeekabooBridgeRequest.click(.init(
        target: .coordinates(CGPoint(x: 10, y: 20)),
        clickType: .single))
}

private final class ScriptedBridgePeer: @unchecked Sendable {
    enum Behavior: Sendable {
        case idle(seconds: TimeInterval)
        case closeWithoutResponse
        case respond(Data)
    }

    let socketPath: String
    private var task: Task<Void, Never>?

    init(behavior: Behavior) throws {
        self.socketPath = "/tmp/pb-client-transport-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout.size(ofValue: address))
            let copied = self.socketPath.withCString { source in
                strlcpy(&address.sun_path.0, source, MemoryLayout.size(ofValue: address.sun_path))
            }
            guard copied < MemoryLayout.size(ofValue: address.sun_path) else {
                throw POSIXError(.ENAMETOOLONG)
            }
            let length = socklen_t(MemoryLayout.size(ofValue: address))
            let bindResult = withUnsafePointer(to: &address) { pointer in
                Darwin.bind(listener, UnsafePointer<sockaddr>(OpaquePointer(pointer)), length)
            }
            guard bindResult == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard listen(listener, 1) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            Darwin.close(listener)
            try? FileManager.default.removeItem(atPath: self.socketPath)
            throw error
        }

        let socketPath = self.socketPath
        self.task = Task.detached {
            defer {
                Darwin.close(listener)
                try? FileManager.default.removeItem(atPath: socketPath)
            }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }

            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(client, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                break
            }

            switch behavior {
            case let .idle(seconds):
                try? await Task.sleep(for: .seconds(seconds))
            case .closeWithoutResponse:
                return
            case let .respond(data):
                _ = data.withUnsafeBytes { bytes in
                    Darwin.write(client, bytes.baseAddress, bytes.count)
                }
            }
        }
    }

    func waitUntilFinished() async {
        await self.task?.value
        self.task = nil
    }
}

private actor VersionMismatchBridgePeerState {
    private(set) var acceptedConnectionCount = 0

    func recordConnection() {
        self.acceptedConnectionCount += 1
    }
}

private final class VersionMismatchBridgePeer: @unchecked Sendable {
    let socketPath: String
    private let listener: Int32
    private let state = VersionMismatchBridgePeerState()
    private var task: Task<Void, Never>?

    var acceptedConnectionCount: Int {
        get async { await self.state.acceptedConnectionCount }
    }

    init(firstResponseDelay: TimeInterval) throws {
        self.socketPath = "/tmp/pb-handshake-fallback-\(UUID().uuidString).sock"
        self.listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard self.listener >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout.size(ofValue: address))
            let copied = self.socketPath.withCString { source in
                strlcpy(&address.sun_path.0, source, MemoryLayout.size(ofValue: address.sun_path))
            }
            guard copied < MemoryLayout.size(ofValue: address.sun_path) else {
                throw POSIXError(.ENAMETOOLONG)
            }
            let length = socklen_t(MemoryLayout.size(ofValue: address))
            let bindResult = withUnsafePointer(to: &address) { pointer in
                Darwin.bind(self.listener, UnsafePointer<sockaddr>(OpaquePointer(pointer)), length)
            }
            guard bindResult == 0, listen(self.listener, 2) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            Darwin.close(self.listener)
            try? FileManager.default.removeItem(atPath: self.socketPath)
            throw error
        }

        let listener = self.listener
        let socketPath = self.socketPath
        let state = self.state
        self.task = Task.detached {
            defer {
                Darwin.close(listener)
                try? FileManager.default.removeItem(atPath: socketPath)
            }
            for attempt in 0..<2 {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                await state.recordConnection()
                Self.drainRequest(client)
                if attempt == 0 {
                    try? await Task.sleep(for: .seconds(firstResponseDelay))
                    let response = BridgeTestFixtures.errorResponse(
                        code: .versionMismatch,
                        message: "scripted version mismatch")
                    if let data = try? JSONEncoder.peekabooBridgeEncoder().encode(response) {
                        _ = data.withUnsafeBytes { bytes in
                            Darwin.write(client, bytes.baseAddress, bytes.count)
                        }
                    }
                } else {
                    try? await Task.sleep(for: .seconds(5))
                }
                Darwin.close(client)
            }
        }
    }

    func stop() async {
        self.task?.cancel()
        _ = shutdown(self.listener, SHUT_RDWR)
        await self.task?.value
        self.task = nil
    }

    private nonisolated static func drainRequest(_ descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            return
        }
    }
}
