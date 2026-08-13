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
        let peer = try ScriptedBridgePeer(steps: [.idle(seconds: 0.15)])
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
        let peer = try ScriptedBridgePeer(steps: [.idle(seconds: 0.15)])
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
        let versionMismatch = BridgeTestFixtures.errorResponse(
            code: .versionMismatch,
            message: "scripted version mismatch")
        let peer = try ScriptedBridgePeer(scripts: [
            [.delay(seconds: 0.3), .respond(versionMismatch)],
            [.idle(seconds: 5)],
        ])
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
    func `stop unblocks an accepted client before request EOF and is idempotent`() async throws {
        let peer = try ScriptedBridgePeer(steps: [.idle(seconds: 5)])
        let client = try Self.connectRawClient(to: peer.socketPath)
        defer { Darwin.close(client) }
        #expect(await Self.waitUntilAccepted(peer))

        let startedAt = ContinuousClock.now
        await peer.stop()
        #expect(startedAt.duration(to: .now) < .seconds(1))
        await peer.stop()
    }

    @Test
    func `deinit unblocks an accepted client before request EOF`() async throws {
        var peer: ScriptedBridgePeer? = try ScriptedBridgePeer(steps: [.idle(seconds: 5)])
        let client = try Self.connectRawClient(to: #require(peer).socketPath)
        defer { Darwin.close(client) }
        let accepted = try await Self.waitUntilAccepted(#require(peer))
        #expect(accepted)

        peer = nil
        var descriptor = pollfd(fd: client, events: Int16(POLLIN | POLLHUP), revents: 0)
        #expect(Darwin.poll(&descriptor, 1, 1000) == 1)
        #expect(descriptor.revents & Int16(POLLIN | POLLHUP) != 0)
    }

    @Test
    func `mutation response EOF is indeterminate and retry unsafe`() async throws {
        let peer = try ScriptedBridgePeer(steps: [.close])
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
        let peer = try ScriptedBridgePeer(steps: [.close])
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
        let peer = try ScriptedBridgePeer(steps: [.respondData(Data("not-json".utf8))])
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
        let peer = try ScriptedBridgePeer(steps: [.idle(seconds: 0.15)])
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
            let peer = try ScriptedBridgePeer(steps: [.respond(response)])
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
        let peer = try ScriptedBridgePeer(steps: [.respond(response)])
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
        let peer = try ScriptedBridgePeer(steps: [.respond(response)])
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

    private static func connectRawClient(to socketPath: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout.size(ofValue: address))
            let copied = socketPath.withCString { source in
                strlcpy(&address.sun_path.0, source, MemoryLayout.size(ofValue: address.sun_path))
            }
            guard copied < MemoryLayout.size(ofValue: address.sun_path) else {
                throw POSIXError(.ENAMETOOLONG)
            }
            let length = socklen_t(MemoryLayout.size(ofValue: address))
            let result = withUnsafePointer(to: &address) { pointer in
                Darwin.connect(descriptor, UnsafePointer<sockaddr>(OpaquePointer(pointer)), length)
            }
            guard result == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func waitUntilAccepted(_ peer: ScriptedBridgePeer) async -> Bool {
        for _ in 0..<200 {
            if await peer.acceptedConnectionCount == 1 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}
