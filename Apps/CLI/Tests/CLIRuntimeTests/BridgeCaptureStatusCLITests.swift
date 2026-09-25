import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Subprocess
import Testing
#if canImport(System)
import System
#else
import SystemPackage
#endif
@testable import PeekabooCLI

struct BridgeCaptureStatusCLITests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func `capture preparation is visible without confusing handshake success`(verbose: Bool) async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let peer = try Self.makePeer()
        let result = try await Self.runStatus(peer: peer, flags: verbose ? ["--verbose"] : [])

        #expect(result.status == .exited(0))
        if !verbose {
            #expect(result.standardError.isEmpty)
        }
        #expect(result.standardOutput.contains("Selected: remote gui via \(peer.socketPath)"))
        #expect(result.standardOutput.contains("handshake succeeded"))
        #expect(result.standardOutput.contains("ops: 1/1 enabled"))
        #expect(result.standardOutput.contains("perm: SR=Y AX=Y ES=Y"))
        #expect(result.standardOutput.contains("capture support: SCK ownership=advertised, classic=advertised"))
        #expect(result.standardOutput.contains("desktop observation=enabled"))
        #expect(result.standardOutput.contains("SCK preparation: blocked"))
        #expect(!result.standardOutput.contains("ready to attempt"))
        #expect(!result.standardOutput.contains("— OK"))
        #expect(result.standardOutput.contains("Candidates:") == verbose)
        #expect(result.standardOutput.components(separatedBy: "handshake succeeded").count == (verbose ? 3 : 2))
        try await Self.expectHandshakeOnlyRequests(peer)
    }

    @Test(.timeLimit(.minutes(1)))
    func `capture status JSON retains the existing handshake fields without presentation text`() async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }

        let peer = try Self.makePeer()
        let result = try await Self.runStatus(peer: peer, flags: ["--json"])

        #expect(result.status == .exited(0))
        #expect(result.standardError.isEmpty)
        let object = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        let envelope = try #require(object as? [String: Any])
        let data = try #require(envelope["data"] as? [String: Any])
        let selected = try #require(data["selected"] as? [String: Any])
        let handshake = try #require(selected["handshake"] as? [String: Any])
        let readiness = try #require(handshake["screenCaptureKitReadiness"] as? [String: Any])
        let permissions = try #require(handshake["permissions"] as? [String: Any])
        let candidates = try #require(data["candidates"] as? [[String: Any]])

        #expect(Set(data.keys) == ["remoteSkipped", "selected", "candidates", "client"])
        #expect(Set(selected.keys) == ["source", "socketPath", "handshake"])
        #expect(Set(handshake.keys) == [
            "negotiatedVersion", "hostKind", "build", "supportedOperations", "permissions",
            "enabledOperations", "permissionTags", "hostCapabilities", "screenCaptureKitReadiness",
        ])
        #expect(selected["source"] as? String == "remote")
        #expect(readiness["state"] as? String == "blocked")
        #expect(permissions["screenRecording"] as? Bool == true)
        #expect(handshake["hostCapabilities"] as? [String] == Self.captureCapabilities)
        #expect(candidates.count == 1)
        #expect(!result.standardOutput.contains("handshake succeeded"))
        #expect(!result.standardOutput.contains("capture support:"))
        try await Self.expectHandshakeOnlyRequests(peer)
    }

    private static let captureCapabilities = [
        PeekabooBridgeHostCapability.screenCaptureKitOwnershipEnforcement,
        PeekabooBridgeHostCapability.classicCaptureWithoutScreenCaptureKit,
    ]

    private static func runStatus(peer: ScriptedBridgePeer, flags: [String]) async throws -> TestChildProcess.Result {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("peekaboo-bridge-status-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            try Data("{}\n".utf8).write(to: directory.appendingPathComponent("config.json"))
            let credentials = directory.appendingPathComponent("credentials")
            try Data().write(to: credentials)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentials.path)

            let binary = try TestChildProcess.peekabooBinaryURL()
            // Do not inherit provider credentials or routing overrides that can select local services.
            let result = try await Subprocess.run(
                .path(FilePath(binary.path)),
                arguments: Arguments(
                    executablePathOverride: nil,
                    remainingValues: ["bridge", "status", "--bridge-socket", peer.socketPath] + flags
                ),
                environment: .custom([
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "LANG": "en_US.UTF-8",
                    "PEEKABOO_CONFIG_DIR": directory.path,
                    "PEEKABOO_CONFIG_DISABLE_MIGRATION": "1",
                    "PEEKABOO_CONFIG_NONINTERACTIVE": "1",
                    "PEEKABOO_VISUAL_FEEDBACK": "false",
                    "PEEKABOO_VISUALIZER_STDOUT": "false",
                    "PEEKABOO_LOG_LEVEL": "warning",
                    "PEEKABOO_CHECK_BUILD_STALENESS": "false",
                ]),
                workingDirectory: FilePath(directory.path),
                output: .string(limit: .max),
                error: .string(limit: .max)
            )
            await peer.stop()
            return TestChildProcess.Result(
                standardOutput: result.standardOutput,
                standardError: result.standardError,
                status: result.terminationStatus
            )
        } catch {
            await peer.stop()
            throw error
        }
    }

    private static func makePeer() throws -> ScriptedBridgePeer {
        let handshake = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: .init(major: 1, minor: 28),
            hostKind: .gui,
            build: "capture-status-fixture",
            supportedOperations: [.desktopObservation],
            permissions: .init(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: [.desktopObservation],
            hostCapabilities: Self.captureCapabilities,
            screenCaptureKitReadiness: .init(state: .blocked, failure: .init(
                kind: .uncoordinatedProcesses,
                stage: .preparation,
                message: "Synthetic preparation blocker"
            ))
        )
        return try ScriptedBridgePeer(responses: [.handshake(handshake), .handshake(handshake)])
    }

    private static func expectHandshakeOnlyRequests(_ peer: ScriptedBridgePeer) async throws {
        let requests = await peer.requests
        #expect(requests.count == 2)
        for data in requests {
            let request = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: data)
            guard case .handshake = request else {
                Issue.record("Bridge status unexpectedly dispatched \(request.operation.rawValue)")
                continue
            }
        }
    }
}
