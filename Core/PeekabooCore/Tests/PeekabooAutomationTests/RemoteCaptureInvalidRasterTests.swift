import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooBridgeTestSupport
import PeekabooCore
import Testing

@MainActor
struct RemoteCaptureInvalidRasterTests {
    @Test
    func `digest verified invalid inline pixels fail live capture before final artifact publication`() async throws {
        let version = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
        let observation = DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: Data("digest-matching bytes that are not an encoded image".utf8),
                metadata: CaptureMetadata(size: CGSize(width: 2, height: 2), mode: .screen)),
            elements: nil)
            .withCaptureContentDigest(rawScreenshotData: nil, annotatedScreenshotData: nil)
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: version,
            supportedOperations: [.desktopObservation],
            hostCapabilities: [
                PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
                PeekabooBridgeHostCapability.desktopObservationInlinePixels,
            ])
        let peer = try ScriptedBridgePeer(responses: [.handshake(handshake), .desktopObservation(observation)])
        defer { Task { await peer.stop() } }
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.invalid-inline-raster-test",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: version)
        let services = RemotePeekabooServices(
            client: client,
            supportsDesktopObservation: true,
            supportsDesktopObservationCaptureEngine: true,
            supportsDesktopObservationInlinePixels: true)
        let capture = try #require(services.screenCapture as? any EngineAwareScreenCaptureServiceProtocol)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-invalid-inline-raster-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let clock = ControlledWatchCaptureClock()
        let session = WatchCaptureSession(
            dependencies: WatchCaptureDependencies(screenCapture: capture, clock: clock),
            configuration: WatchCaptureConfiguration(
                scope: CaptureScope(kind: .screen, screenIndex: 0),
                options: CaptureOptions(
                    duration: 30,
                    idleFps: 5,
                    activeFps: 5,
                    changeThresholdPercent: 0,
                    heartbeatSeconds: 0,
                    quietMsToIdle: 0,
                    maxFrames: 1,
                    maxMegabytes: nil,
                    highlightChanges: false,
                    captureFocus: .background,
                    resolutionCap: nil,
                    diffStrategy: .fast,
                    diffBudgetMs: nil),
                outputRoot: output,
                autoclean: WatchAutocleanConfig(minutes: 120, managed: false)))
        let task = Task {
            try await capture.withCaptureEngine(.modern) { try await session.run() }
        }
        defer { task.cancel() }

        // Cadence sleep starts only after the real frame provider has attempted raster decoding.
        let reachedCadence = await clock.waitUntilSleeping(until: 200_000_000)
        session.requestStop()
        let thrown = await #expect(throws: CaptureNoValidFramesError.self) { try await task.value }
        let error = try #require(thrown)
        await peer.stop()

        #expect(reachedCadence)
        #expect(error.source == .live)
        #expect(error.framesDropped == 1)
        #expect(session.lastSampleStartedAtMonotonicNanoseconds == nil)
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("contact.png").path))
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("metadata.json").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)

        let requests = try await peer.requests.dropFirst().map {
            try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: $0)
        }
        #expect(requests.map(\.operation) == [.desktopObservation])
        guard case let .desktopObservation(request) = try #require(requests.first) else {
            Issue.record("Expected the scoped remote observation request")
            return
        }
        #expect(request.capture.engine == .modern)
        #expect(request.capture.focus == .background)
        #expect(request.detection.mode == .none)
        #expect(request.output.includeImageData)
        #expect(!request.output.saveRawScreenshot)
        #expect(!request.output.saveAnnotatedScreenshot)
        #expect(!request.output.saveSnapshot)
        #expect(request.output.path == nil)
    }
}
