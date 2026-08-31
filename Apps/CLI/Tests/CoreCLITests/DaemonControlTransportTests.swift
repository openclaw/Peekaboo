import Darwin
import Foundation
import PeekabooBridge
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooCLI

@MainActor
@Suite(.serialized, .tags(.safe))
struct DaemonControlTransportTests {
    @Test
    func `daemon probe failure cannot become confirmed absence`() async throws {
        let peer = try ScriptedBridgePeer(steps: [.idle(seconds: 1)])
        let client = DaemonControlClient(socketPath: peer.socketPath, requestTimeoutSec: 0.05)
        await #expect(throws: (any Error).self) {
            _ = try await client.fetchStatus()
        }
        await peer.stop()
        #expect(await peer.acceptedConnectionCount == 1)
    }

    @Test(arguments: [PeekabooBridgeErrorCode.timeout, .unauthorizedClient, .internalError])
    func `control resolution preserves probe failures in JSON output`(code: PeekabooBridgeErrorCode) async throws {
        let peer = try ScriptedBridgePeer(responses: [.error(.init(code: code, message: "Fixture probe failure"))])
        let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await DaemonControlResolver.targets(explicitSocket: peer.socketPath)
        }
        await peer.stop()
        let failure = try #require(error)
        #expect(failure.code == code)
        let output = Self.captureOutput { handleGenericError(failure, jsonOutput: true, logger: Logger.shared) }
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(envelope["success"] as? Bool == false)
        #expect(envelope["data"] is NSNull)
        #expect((envelope["error"] as? [String: Any])?["message"] as? String == "Fixture probe failure")
    }

    @Test(arguments: [false, true])
    func `failed status response after handshake is not absence`(close: Bool) async throws {
        let peer = try ScriptedBridgePeer(scripts: [
            [.respond(.handshake(Self.handshake))],
            close ? [.close] : [.idle(seconds: 1)],
        ])
        let client = DaemonControlClient(socketPath: peer.socketPath, requestTimeoutSec: 0.1)
        await #expect(throws: (any Error).self) { _ = try await client.fetchStatus() }
        await peer.stop()
        #expect(await peer.acceptedConnectionCount == 2)
    }

    @Test
    func `missing socket remains legitimate absence`() async throws {
        let path = "/tmp/pb-absent-\(UUID().uuidString).sock"
        #expect(try await DaemonControlClient(socketPath: path).fetchStatus() == nil)
        #expect(try await DaemonControlResolver.targets(explicitSocket: path).isEmpty)
    }

    @Test(arguments: [false, true])
    func `confirmed stopped and non daemon endpoints preserve control semantics`(gui: Bool) async throws {
        let response: PeekabooBridgeResponse = gui
            ? .error(.init(code: .operationNotSupported, message: "Not a daemon"))
            : .daemonStatus(.init(running: false))
        let peer = try ScriptedBridgePeer(responses: [.handshake(Self.handshake), response])
        let targets = try await DaemonControlResolver.targets(explicitSocket: peer.socketPath)
        await peer.stop()
        #expect(targets.count == (gui ? 1 : 0))
        if let target = targets.first {
            #expect(target.status.running)
            #expect(target.status.mode == nil)
            #expect(!DaemonControlClient.isControllableDaemonStatus(target.status))
            #expect(DaemonControlPlanner.startAction(
                targets: targets,
                explicitSocket: peer.socketPath,
                defaultSocketPath: peer.socketPath,
                buildScopedSocketPath: nil
            ) == .rejectIncompatible(socketPath: peer.socketPath))
        }
        #expect(await peer.acceptedConnectionCount == 2)
    }

    @Test
    func `failed probe never authorizes an on demand launch`() async throws {
        let peer = try ScriptedBridgePeer(responses: [.error(.init(code: .timeout, message: "Fixture timeout"))])
        defer { try? FileManager.default.removeItem(at: DaemonPaths.daemonStartupLockURL(socketPath: peer.socketPath)) }
        var launches = 0
        await #expect(throws: (any Error).self) {
            _ = try await DaemonLaunchPolicy
                .startOnDemandDaemon(socketPath: peer.socketPath, environment: [:]) { _, _, _ in
                    launches += 1
                    throw CancellationError()
                }
        }
        await peer.stop()
        #expect(launches == 0)
    }

    @Test
    func `failed daemon inventory cannot become an empty mutation barrier`() async {
        var options = CommandRuntimeOptions()
        options.requiresCallerDesktopMutationBarrier = true
        let failure = PeekabooBridgeErrorEnvelope(code: .timeout, message: "Fixture inventory unavailable")
        let dependencies = RuntimeHostResolver.Dependencies(
            makeLocalServices: { _ in fatalError("A failed inventory must not construct local services") },
            claimScreenCaptureKitOwner: { fatalError("This fixture must not claim native capture ownership") },
            inspectScreenCaptureKitOwner: { nil },
            remoteCandidatePlan: { _, _ in throw failure }
        )

        let result = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await RuntimeHostResolver.resolveServices(
                options: options, environment: [:], configurationInput: nil, dependencies: dependencies
            )
        }
        #expect(result?.code == .timeout)
    }

    @Test
    func `replacement cleanup cannot confirm exit after a failed probe`() async throws {
        let peer = try ScriptedBridgePeer(responses: [.error(.init(code: .timeout, message: "Fixture timeout"))])
        let replacement = DaemonLaunchPolicy.LaunchResult(
            status: .init(running: true, pid: getpid(), mode: .auto), processID: getpid()
        )
        #expect(await DaemonLaunchPolicy.stopReplacement(
            client: DaemonControlClient(socketPath: peer.socketPath), replacement: replacement
        ) == false)
        await peer.stop()
        #expect(await peer.acceptedConnectionCount == 1)
    }

    @Test(arguments: [false, true])
    func `stop waits for confirmed absence and preserves unresolved probe errors`(probeFails: Bool) async throws {
        let scripts: [[ScriptedBridgePeer.Step]] = [
            [.respond(.handshake(Self.handshake))], [.respond(.bool(true))],
        ] +
            (probeFails ? [[.respond(.error(.init(code: .timeout, message: "Fixture timeout"))), .idle(seconds: 2)]] :
                [])
        let peer = try ScriptedBridgePeer(scripts: scripts)
        let client = DaemonControlClient(socketPath: peer.socketPath, requestTimeoutSec: 0.1)
        if probeFails {
            await #expect(throws: (any Error).self) {
                _ = try await client.stopAndWait(waitSeconds: 1, expectedPID: nil)
            }
        } else {
            #expect(try await client.stopAndWait(waitSeconds: 1, expectedPID: nil))
        }
        await peer.stop()
    }

    private static var handshake: PeekabooBridgeHandshakeResponse {
        BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 28),
            hostKind: .gui,
            supportedOperations: [.daemonStatus, .daemonStop]
        )
    }

    private static func captureOutput(_ body: () -> Void) -> String {
        let pipe = Pipe()
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        body()
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
        try? pipe.fileHandleForWriting.close()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
