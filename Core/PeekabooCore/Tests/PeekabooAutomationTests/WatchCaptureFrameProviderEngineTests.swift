import CoreGraphics
import Darwin
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct WatchCaptureFrameProviderEngineTests {
    @Test
    func `Service owned area capture preserves explicit scopes and unscoped routing`() async throws {
        try await Self.withoutCaptureEngineEnvironment {
            try await ScreenCaptureService.$captureEnginePreference.withValue(.auto) {
                let capture = EngineRecordingAreaCapture(gateOwner: .service)
                let provider = Self.provider(capture: capture)

                for engine in [CaptureEnginePreference.auto, .modern, .legacy] {
                    try await capture.withCaptureEngine(engine) {
                        _ = try await provider.captureFrame()
                    }
                }
                _ = try await provider.captureFrame()

                #expect(capture.requestedEngines == [.auto, .modern, .legacy])
                #expect(capture.capturedEngines == [.auto, .modern, .legacy, nil])
            }
        }
    }

    @Test(arguments: [CaptureTransactionGateOwner.caller, .service])
    func `Only caller owned auto area capture gets the sampler legacy preference`(
        gateOwner: CaptureTransactionGateOwner) async throws
    {
        try await Self.withoutCaptureEngineEnvironment {
            try await ScreenCaptureService.$captureEnginePreference.withValue(.auto) {
                let capture = EngineRecordingAreaCapture(gateOwner: gateOwner)
                _ = try await Self.provider(capture: capture).captureFrame()

                #expect(capture.requestedEngines == (gateOwner == .caller ? [.legacy] : []))
                #expect(capture.capturedEngines == (gateOwner == .caller ? [.legacy] : [nil]))
            }
        }
    }

    @Test(arguments: [CaptureEnginePreference.modern, .legacy])
    func `Explicit caller area engines are not replaced`(engine: CaptureEnginePreference) async throws {
        try await Self.withoutCaptureEngineEnvironment {
            try await ScreenCaptureService.$captureEnginePreference.withValue(engine) {
                let capture = EngineRecordingAreaCapture(gateOwner: .caller)
                _ = try await Self.provider(capture: capture).captureFrame()

                #expect(capture.requestedEngines.isEmpty)
                #expect(ScreenCaptureService.captureEnginePreference == engine)
            }
        }
    }

    private static func provider(capture: any ScreenCaptureServiceProtocol) -> WatchCaptureFrameProvider {
        WatchCaptureFrameProvider(
            screenCapture: capture,
            frameSource: nil,
            scope: CaptureScope(kind: .region, region: CGRect(x: 10, y: 10, width: 20, height: 20)),
            options: CaptureOptions(
                duration: 1,
                idleFps: 1,
                activeFps: 1,
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
            regionValidator: WatchCaptureRegionValidator(screenService: AreaCaptureScreen()))
    }

    private static func withoutCaptureEngineEnvironment(
        _ operation: @MainActor () async throws -> Void) async rethrows
    {
        let keys = ["PEEKABOO_CAPTURE_ENGINE", "PEEKABOO_USE_MODERN_CAPTURE"]
        let previousValues = keys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        }
        for key in keys {
            unsetenv(key)
        }
        defer {
            for (key, value) in previousValues {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }
        try await operation()
    }
}

@MainActor
private final class EngineRecordingAreaCapture: EngineAwareScreenCaptureServiceProtocol {
    let captureTransactionGateOwner: CaptureTransactionGateOwner
    @TaskLocal private static var engine: CaptureEnginePreference?
    private(set) var requestedEngines: [CaptureEnginePreference] = []
    private(set) var capturedEngines: [CaptureEnginePreference?] = []

    init(gateOwner: CaptureTransactionGateOwner) {
        self.captureTransactionGateOwner = gateOwner
    }

    func withCaptureEngine<T: Sendable>(
        _ engine: CaptureEnginePreference,
        operation: @MainActor () async throws -> T) async rethrows -> T
    {
        self.requestedEngines.append(engine)
        return try await Self.$engine.withValue(engine, operation: operation)
    }

    func captureArea(
        _ rect: CGRect,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        #expect(rect == CGRect(x: 10, y: 10, width: 20, height: 20))
        #expect(visualizerMode == .none)
        #expect(scale == .logical1x)
        self.capturedEngines.append(Self.engine)
        return CaptureResult(imageData: Data(), metadata: CaptureMetadata(size: rect.size, mode: .area))
    }

    func captureScreen(
        displayIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw PeekabooError.captureFailed(reason: "Unexpected screen capture")
    }

    func captureWindow(
        appIdentifier _: String,
        windowIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw PeekabooError.captureFailed(reason: "Unexpected window capture")
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw PeekabooError.captureFailed(reason: "Unexpected frontmost capture")
    }

    func hasScreenRecordingPermission() async -> Bool {
        false
    }
}

@MainActor
private struct AreaCaptureScreen: ScreenServiceProtocol {
    func listScreens() -> [ScreenInfo] {
        [ScreenInfo(
            index: 0,
            name: "Fixture",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isPrimary: true,
            scaleFactor: 1,
            displayID: 1)]
    }

    func screenContainingWindow(bounds _: CGRect) -> ScreenInfo? {
        self.primaryScreen
    }

    func screen(at index: Int) -> ScreenInfo? {
        self.listScreens().first { $0.index == index }
    }

    var primaryScreen: ScreenInfo? {
        self.listScreens().first
    }
}
