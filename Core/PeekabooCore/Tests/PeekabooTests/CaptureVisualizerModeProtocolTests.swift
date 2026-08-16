import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooBridgeTestSupport
import Testing

struct CaptureVisualizerModeProtocolTests {
    @Test
    func `Bridge capture visualizer modes round trip`() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for mode in [
            CaptureVisualizerMode.none,
            .screenshotFlash,
            .watchCapture,
        ] {
            let payload = PeekabooBridgeCaptureFrontmostRequest(
                visualizerMode: mode,
                scale: .logical1x)
            let encoded = try encoder.encode(payload)
            let decoded = try decoder.decode(PeekabooBridgeCaptureFrontmostRequest.self, from: encoded)
            #expect(decoded.visualizerMode == mode)
        }
    }

    @Test
    func `Silent capture is a protocol 1_12 contract`() {
        #expect(PeekabooBridgeConstants.protocolVersion >= .init(major: 1, minor: 12))
        #expect(DesktopCaptureOptions().visualizerMode == .none)
        #expect(CaptureVisualizerMode.resolved(for: .background, visibleMode: .screenshotFlash) == .none)
        #expect(CaptureVisualizerMode.resolved(for: .foreground, visibleMode: .screenshotFlash) == .screenshotFlash)
    }

    @Test
    @MainActor
    func `Screen capture protocol conveniences default every operation to silent`() async throws {
        let recorder = CaptureVisualizerModeRecorder()
        let service: any ScreenCaptureServiceProtocol = recorder

        _ = try await service.captureScreen(displayIndex: nil)
        _ = try await service.captureWindow(appIdentifier: "Fixture", windowIndex: nil)
        _ = try await service.captureWindow(windowID: 42)
        _ = try await service.captureFrontmost()
        _ = try await service.captureArea(CGRect(x: 1, y: 2, width: 3, height: 4))

        #expect(recorder.visualizerModes == [.none, .none, .none, .none, .none])
    }

    @Test
    func `Bridge capture client defaults every wire request to silent`() async throws {
        let version = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: version,
            supportedOperations: [.captureScreen, .captureWindow, .captureFrontmost, .captureArea])
        let capture = CaptureResult(
            imageData: Data(),
            metadata: .init(size: CGSize(width: 1, height: 1), mode: .screen))
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(handshake),
            .capture(capture),
            .capture(capture),
            .capture(capture),
            .capture(capture),
            .capture(capture),
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.capture-defaults",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: version)

        _ = try await client.captureScreen(displayIndex: nil)
        _ = try await client.captureWindow(appIdentifier: "Fixture", windowIndex: nil)
        _ = try await client.captureWindow(windowID: 42)
        _ = try await client.captureFrontmost()
        _ = try await client.captureArea(CGRect(x: 1, y: 2, width: 3, height: 4))
        await peer.waitUntilFinished()

        let requests = try await peer.requests.dropFirst().map {
            try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: $0)
        }
        #expect(requests.count == 5)
        for request in requests {
            let visualizerMode: CaptureVisualizerMode? = switch request {
            case let .captureScreen(payload): payload.visualizerMode
            case let .captureWindow(payload): payload.visualizerMode
            case let .captureFrontmost(payload): payload.visualizerMode
            case let .captureArea(payload): payload.visualizerMode
            default: nil
            }
            #expect(visualizerMode == CaptureVisualizerMode.none)
        }
    }
}

@MainActor
private final class CaptureVisualizerModeRecorder: ScreenCaptureServiceProtocol {
    private(set) var visualizerModes: [CaptureVisualizerMode] = []

    func captureScreen(
        displayIndex _: Int?,
        visualizerMode: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.result(mode: .screen, recording: visualizerMode)
    }

    func captureWindow(
        appIdentifier _: String,
        windowIndex _: Int?,
        visualizerMode: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.result(mode: .window, recording: visualizerMode)
    }

    func captureWindow(
        windowID _: CGWindowID,
        visualizerMode: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.result(mode: .window, recording: visualizerMode)
    }

    func captureFrontmost(
        visualizerMode: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.result(mode: .frontmost, recording: visualizerMode)
    }

    func captureArea(
        _: CGRect,
        visualizerMode: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.result(mode: .area, recording: visualizerMode)
    }

    func hasScreenRecordingPermission() async -> Bool {
        true
    }

    private func result(
        mode: CaptureMode,
        recording visualizerMode: CaptureVisualizerMode) -> CaptureResult
    {
        self.visualizerModes.append(visualizerMode)
        return CaptureResult(
            imageData: Data(),
            metadata: .init(size: CGSize(width: 1, height: 1), mode: mode))
    }
}
