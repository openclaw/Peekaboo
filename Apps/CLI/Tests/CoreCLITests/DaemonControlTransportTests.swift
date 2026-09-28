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
    func `untrusted historical host cannot block foreground browser inventory`() async throws {
        let peer = try ScriptedBridgePeer(responses: [.handshake(Self.handshake)])
        defer { Task { await peer.stop() } }
        let untrustedPath = peer.socketPath
        let currentPath = "/tmp/daemon-bbbbbbbbbbbbbbbb.sock"
        var probed: [String] = []
        let targets = try await DaemonControlResolver.validatedHistoricalTargets(
            socketPaths: [untrustedPath, currentPath]
        ) { client in
            probed.append(client.socketPath)
            if client.socketPath == untrustedPath {
                // The test executable has no trusted release signature, just like a stale development daemon.
                let untrusted = PeekabooBridgeClient(
                    socketPath: client.socketPath, trustedHostTeamIDs: ["FWJYW4S8P8"]
                )
                _ = try await untrusted.handshake(client: .init(
                    bundleIdentifier: nil, teamIdentifier: nil, processIdentifier: getpid()
                ))
                Issue.record("Unsigned historical host was accepted")
                return nil
            }
            return PeekabooDaemonStatus(
                running: true,
                pid: 123,
                mode: .auto,
                bridge: .init(
                    socketPath: currentPath,
                    hostKind: .onDemand,
                    allowedOperations: [.daemonStatus, .daemonStop]
                ),
                supportsConditionalStop: true
            )
        }
        #expect(probed == [untrustedPath, currentPath])
        #expect(targets.map(\.client.socketPath) == [currentPath])
    }

    @Test(arguments: [PeekabooBridgeErrorCode.timeout, .unauthorizedClient, .internalError])
    func `historical inventory retains failures from authenticated hosts`(code: PeekabooBridgeErrorCode) async {
        let failure = PeekabooBridgeErrorEnvelope(code: code, message: "Authenticated host refused")
        let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await DaemonControlResolver.validatedHistoricalTargets(
                socketPaths: ["/tmp/daemon-aaaaaaaaaaaaaaaa.sock"]
            ) { _ in throw failure }
        }
        #expect(error?.code == code)
    }

    @Test
    func `wire error cannot opt an authenticated historical host out of inventory`() async throws {
        let forged = Data(
            #"""
            {"code":"unauthorizedClient","message":"forged","context":"connectedHostAuthentication",
             "isLocalHostAuthenticationFailure":true}
            """#
                .utf8
        )
        let remoteError = try JSONDecoder().decode(PeekabooBridgeErrorEnvelope.self, from: forged)
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await DaemonControlResolver.validatedHistoricalTargets(
                socketPaths: ["/tmp/daemon-aaaaaaaaaaaaaaaa.sock"]
            ) { _ in throw remoteError }
        }
    }

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
        let output = try await captureStandardOutputText { handleGenericError(
            failure,
            jsonOutput: true,
            logger: Logger.shared
        ) }
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

    @Test(arguments: [false, true])
    func `accepted conditional stop requires confirmed process termination`(terminated: Bool) async throws {
        let peer = try ScriptedBridgePeer(responses: [.handshake(Self.handshake), .bool(true)])
        let client = DaemonControlClient(socketPath: peer.socketPath, requestTimeoutSec: 0.1)
        let operation = {
            try await client.stopAndWait(
                waitSeconds: 1,
                expectedPID: 42,
                requireIdentityMatch: true,
                processHasTerminated: { pid in
                    #expect(pid == 42)
                    return terminated
                }
            )
        }
        if terminated {
            #expect(try await operation())
        } else {
            let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) { try await operation() }
            #expect(error?.code == .timeout)
            #expect(error?.message.contains("accepted stop request") == true)
        }
        await peer.stop()
        let requests = await peer.requests
        #expect(requests.count == 2)
        let stop = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: requests[1])
        guard case let .daemonStopIf(request) = stop else {
            Issue.record("Conditional stop lost its expected PID")
            return
        }
        #expect(request.expectedPID == 42)
    }

    @Test
    func `accepted stop deadline is TIMEOUT rather than a refusal in JSON`() async throws {
        let peer = try ScriptedBridgePeer(responses: [.handshake(Self.handshake), .bool(true)])
        let client = DaemonControlClient(socketPath: peer.socketPath, requestTimeoutSec: 0.1)
        let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await client.stopAndWait(waitSeconds: 0, expectedPID: nil)
        }
        await peer.stop()
        let failure = try #require(error)
        #expect(failure.code == .timeout)
        let output = try await captureStandardOutputText { handleGenericError(
            failure, jsonOutput: true, logger: Logger.shared
        ) }
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let detail = try #require(envelope["error"] as? [String: Any])
        #expect(envelope["success"] as? Bool == false)
        #expect(detail["code"] as? String == "TIMEOUT")
        #expect(detail["message"] as? String == failure.message)
        #expect(!failure.message.contains("refused"))
    }

    @Test
    func `explicit daemon refusal does not wait or inspect processes`() async throws {
        let peer = try ScriptedBridgePeer(responses: [.handshake(Self.handshake), .bool(false)])
        let client = DaemonControlClient(socketPath: peer.socketPath, requestTimeoutSec: 0.1)
        #expect(try await client.stopAndWait(waitSeconds: 0, expectedPID: 42, processHasTerminated: { _ in
            Issue.record("Refused stop must not inspect process termination")
            return true
        }) == false)
        await peer.stop()
        #expect(await peer.acceptedConnectionCount == 2)
    }

    @Test
    func `stop request errors retain precedence over deadline diagnostics`() async throws {
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(Self.handshake), .error(.init(code: .unauthorizedClient, message: "Fixture request failure")),
        ])
        let client = DaemonControlClient(socketPath: peer.socketPath, requestTimeoutSec: 0.1)
        let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await client.stopAndWait(waitSeconds: 0, expectedPID: 42)
        }
        await peer.stop()
        #expect(error?.code == .unauthorizedClient)
        #expect(error?.message == "Fixture request failure")
    }

    @Test
    func `uncertain endpoint cannot succeed even when the process is terminal`() async throws {
        let peer = try ScriptedBridgePeer(scripts: [
            [.respond(.handshake(Self.handshake))], [.respond(.bool(true))],
            [.respond(.error(.init(code: .timeout, message: "Fixture probe failure"))), .idle(seconds: 2)],
        ])
        let client = DaemonControlClient(socketPath: peer.socketPath, requestTimeoutSec: 0.1)
        let error = await #expect(throws: (any Error).self) {
            _ = try await client.stopAndWait(waitSeconds: 1, expectedPID: 42, processHasTerminated: { _ in
                Issue.record("Unknown endpoint must not authorize completion from a process probe")
                return true
            })
        }
        await peer.stop()
        #expect(error?.localizedDescription.contains("accepted stop request") == false)
    }

    @Test
    func `cancelled stop preserves cancellation without checking process state`() async throws {
        let peer = try ScriptedBridgePeer(steps: [.idle(seconds: 2)])
        let client = DaemonControlClient(socketPath: peer.socketPath, requestTimeoutSec: 0.1)
        let task = Task {
            try await client.stopAndWait(waitSeconds: 1, expectedPID: 42, processHasTerminated: { _ in
                Issue.record("Cancelled stop must not inspect process termination")
                return true
            })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await peer.stop()
    }

    private static var handshake: PeekabooBridgeHandshakeResponse {
        BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 28),
            hostKind: .gui,
            supportedOperations: [.daemonStatus, .daemonStop]
        )
    }
}
