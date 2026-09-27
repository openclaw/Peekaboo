import Commander
import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

@Suite(.tags(.safe))
@MainActor
struct VerifyCaptureEngineScopeTests {
    @Test(arguments: ["classic", "cg", "modern", "auto"], [false, true])
    func `verification forwards its engine in inline capture and restores the raw route`(
        engine: String,
        throwsAfterCapture: Bool
    ) async throws {
        let fixture = try await Self.fixture(scoped: true)
        let runtime = Self.runtime(capture: fixture.capture, engine: engine)
        let command = try VerifyCommand.parse(["--pid", "123", "--window-exists", "--screenshot", "/unused.png"])
        let operation: @MainActor () async throws -> CaptureResult = {
            let capture = try await fixture.capture.captureWindow(
                windowID: 42,
                visualizerMode: .none,
                scale: .logical1x
            )
            if throwsAfterCapture {
                throw ScopeFailure()
            }
            return capture
        }
        if throwsAfterCapture {
            await #expect(throws: ScopeFailure.self) {
                try await command.withScreenshotCaptureEngine(using: runtime, operation: operation)
            }
        } else {
            let result = try await command.withScreenshotCaptureEngine(using: runtime, operation: operation)
            #expect(result.imageData == Self.result.capture.imageData)
        }
        _ = try await fixture.capture.captureWindow(windowID: 42, visualizerMode: .none, scale: .logical1x)
        await fixture.peer.waitUntilFinished()
        let requests = try await Self.requests(from: fixture.peer)
        #expect(requests.map(\.operation) == [.desktopObservation, .captureWindow])
        guard case let .desktopObservation(request) = try #require(requests.first) else {
            Issue.record("Expected engine-scoped inline observation")
            return
        }
        #expect(request.target == .windowID(42))
        #expect(request.capture.engine == (engine == "modern" ? .modern : engine == "auto" ? .auto : .legacy))
        #expect(request.capture.focus == .background)
        #expect(request.capture.visualizerMode == .none)
        #expect(request.capture.scale == .logical1x)
        #expect(request.detection.mode == .none)
        #expect(request.output.includeImageData)
        #expect(!request.output.saveSnapshot)
        #expect(!request.output.saveRawScreenshot)
        #expect(!request.output.saveAnnotatedScreenshot)
        #expect(request.output.path == nil)
    }

    @Test(arguments: [false, true])
    func `no screenshot or no override preserves the unscoped engine`(screenshot: Bool) async throws {
        let fixture = try await Self.fixture(scoped: false)
        let runtime = Self.runtime(capture: fixture.capture, engine: screenshot ? nil : "classic")
        let arguments = ["--pid", "123", "--window-exists"] + (screenshot ? ["--screenshot", "/unused.png"] : [])
        let command = try VerifyCommand.parse(arguments)
        _ = try await command.withScreenshotCaptureEngine(using: runtime) {
            try await fixture.capture.captureWindow(windowID: 42, visualizerMode: .none, scale: .logical1x)
        }
        _ = try await fixture.capture.captureWindow(windowID: 42, visualizerMode: .none, scale: .logical1x)
        await fixture.peer.waitUntilFinished()
        #expect(try await Self.requests(from: fixture.peer).map(\.operation) == [.captureWindow, .captureWindow])
    }

    @Test
    func `unsupported engine scope refuses without evaluating the operation`() async throws {
        let client = PeekabooBridgeClient(socketPath: "/synthetic/unused-verify.sock")
        let capture = RemoteScreenCaptureService(client: client).unscopedCapture
        let runtime = Self.runtime(capture: capture, engine: "classic")
        let command = try VerifyCommand.parse(["--pid", "123", "--window-exists", "--screenshot", "/unused.png"])
        var calls = 0
        await #expect(throws: ValidationError.self) {
            try await command.withScreenshotCaptureEngine(using: runtime) { calls += 1 }
        }
        #expect(calls == 0)
    }

    private static var result: DesktopObservationResult {
        DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: Data("fixture-pixels".utf8),
                metadata: CaptureMetadata(size: CGSize(width: 1, height: 1), mode: .window)
            ),
            elements: nil
        )
        .withCaptureContentDigest(rawScreenshotData: nil, annotatedScreenshotData: nil)
    }

    private static func fixture(scoped: Bool) async throws
    -> (peer: ScriptedBridgePeer, capture: RemoteScreenCaptureService) {
        let version = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(BridgeTestFixtures.handshake(
                negotiatedVersion: version,
                supportedOperations: [.desktopObservation, .captureWindow],
                hostCapabilities: [
                    PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
                    PeekabooBridgeHostCapability.desktopObservationInlinePixels,
                ]
            )),
            scoped ? .desktopObservation(Self.result) : .capture(Self.result.capture),
            .capture(Self.result.capture),
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(
            client: .init(bundleIdentifier: "synthetic.verify", teamIdentifier: nil, processIdentifier: getpid()),
            protocolVersion: version
        )
        let observation = RemoteDesktopObservationService(
            client: client,
            supportsDesktopObservationCaptureEngine: true,
            supportsDesktopObservationInlinePixels: true,
            supportsExactWindowROIObservation: false,
            artifactInstallationPreflight: { Issue.record("Inline verification must not install artifacts") }
        )
        return (peer, RemoteScreenCaptureService(client: client, desktopObservation: observation))
    }

    private static func runtime(capture: any ScreenCaptureServiceProtocol, engine: String?) -> CommandRuntime {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("unused-verify-\(UUID())")
        return CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: false, logLevel: nil, captureEnginePreference: engine),
            services: VerifyPreflightServices(directory: directory, screenCapture: capture),
            interactionMutationTracker: InteractionMutationTracker(
                desktopMutationWatermarkStore: DesktopMutationWatermarkStore(directoryURL: directory)
            )
        )
    }

    private static func requests(from peer: ScriptedBridgePeer) async throws -> [PeekabooBridgeRequest] {
        try await peer.requests.dropFirst().map {
            try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: $0)
        }
    }
}

private struct ScopeFailure: Error {}
