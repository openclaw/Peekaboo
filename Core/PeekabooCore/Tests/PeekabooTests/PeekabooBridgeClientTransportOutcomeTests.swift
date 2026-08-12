import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
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
        } catch let failure as DesktopActionFailure {
            Self.expectResponseLostFailure(failure)
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
        } catch let failure as DesktopActionFailure {
            Self.expectResponseLostFailure(failure)
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
        } catch let failure as DesktopActionFailure {
            Self.expectResponseLostFailure(failure)
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
        } catch let failure as DesktopActionFailure {
            Self.expectResponseLostFailure(failure)
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `canonical action failures reconstruct exactly once in shared transport`() async throws {
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: .accessibilityAction,
            mode: .background)
        let twoUnits = try #require(DesktopActionOutcome.DispatchUnitCount(2))
        let failures = [
            DesktopActionFailure.refused(
                route: .bridge,
                reason: .permissionDenied,
                message: "Accessibility permission was refused",
                hint: "Grant Accessibility permission.",
                causeDescription: "AX is not trusted"),
            DesktopActionFailure.dispatchedUnverified(
                route: .bridge,
                delivery: delivery,
                evidence: .deliveryAccepted,
                unitCount: twoUnits,
                message: "Delivery was accepted but not verified",
                hint: "Observe before retrying.",
                causeDescription: "post-dispatch verification timed out"),
            DesktopActionFailure.partial(
                route: .bridge,
                delivery: delivery,
                unitCount: twoUnits,
                message: "The action changed the target but cleanup failed",
                hint: "Recover the remaining side effect.",
                causeDescription: "cleanup receipt was unavailable"),
            DesktopActionFailure.indeterminate(
                route: .bridge,
                delivery: delivery,
                evidence: .completionUnknown,
                unitCount: twoUnits,
                message: "The final action state is unknown",
                hint: "Observe before retrying.",
                causeDescription: "the host lost its verification receipt"),
        ]

        for expected in failures {
            let response = BridgeTestFixtures.actionFailureResponse(failure: expected)
            let data = try JSONEncoder.peekabooBridgeEncoder().encode(response)
            let peer = try ScriptedBridgePeer(behavior: .respond(data))
            let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)

            do {
                try await client.sendExpectOK(Self.clickRequest)
                Issue.record("Expected canonical desktop action failure")
            } catch let actual as DesktopActionFailure {
                #expect(actual == expected)
            }
            await peer.waitUntilFinished()
        }
    }

    @Test
    func `legacy may-have-completed response becomes completion-unknown`() async throws {
        let response = BridgeTestFixtures.errorResponse(
            code: .internalError,
            message: "Legacy host could not verify completion",
            details: "legacy detail",
            operationMayHaveCompleted: true)
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(response)
        let peer = try ScriptedBridgePeer(behavior: .respond(data))
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)

        do {
            try await client.sendExpectOK(Self.clickRequest)
            Issue.record("Expected conservative legacy desktop action failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.projection.requiresFreshObservation)
            #expect(failure.message == "Legacy host could not verify completion")
            #expect(failure.causeDescription == "legacy detail")
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `read-only request never reconstructs a desktop action failure`() async throws {
        let failure = DesktopActionFailure.indeterminate(
            route: .bridge,
            evidence: .completionUnknown,
            message: "Fixture action failure on a read-only request")
        let response = BridgeTestFixtures.actionFailureResponse(failure: failure)
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(response)
        let peer = try ScriptedBridgePeer(behavior: .respond(data))
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)

        let actual = try await client.send(.permissionsStatus)
        guard case let .error(envelope) = actual else {
            Issue.record("Expected the read-only request to retain its Bridge error envelope")
            await peer.waitUntilFinished()
            return
        }
        #expect(envelope.desktopActionFailure == failure)
        await peer.waitUntilFinished()
    }

    @Test
    func `error envelope rejects compatibility Boolean contradicting canonical outcome`() throws {
        let failure = DesktopActionFailure.indeterminate(
            route: .bridge,
            evidence: .completionUnknown,
            message: "Completion unknown")
        let envelope = PeekabooBridgeErrorEnvelope(code: .internalError, actionFailure: failure)
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(envelope)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["operationMayHaveCompleted"] = false
        let forged = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeErrorEnvelope.self, from: forged)
        }
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

    private static func expectResponseLostFailure(_ failure: DesktopActionFailure) {
        #expect(failure.outcome.route == .bridge)
        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.evidence == .responseLost)
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.outcome.projection.requiresFreshObservation)
        #expect(failure.message.contains("indeterminate"))
        #expect(failure.message.contains("do not retry"))
        #expect(PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: failure))
    }
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
