import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
final class MockScreenCaptureService: ScreenCaptureServiceProtocol {
    private let screenRecordingGranted: Bool
    private let imageData: Data
    private let metadata: CaptureMetadata?
    private let windowMetadata: [CGWindowID: CaptureMetadata]
    private(set) var captureAttemptCount = 0
    private(set) var lastWindowID: CGWindowID?
    private(set) var lastAppIdentifier: String?
    private(set) var lastArea: CGRect?
    private(set) var lastScale: CaptureScalePreference?

    init(screenRecordingGranted: Bool) {
        self.screenRecordingGranted = screenRecordingGranted
        self.imageData = Self.validPNGData
        self.metadata = nil
        self.windowMetadata = [:]
    }

    init(screenRecordingGranted: Bool, metadata: CaptureMetadata) {
        self.screenRecordingGranted = screenRecordingGranted
        self.imageData = Self.validPNGData
        self.metadata = metadata
        self.windowMetadata = [:]
    }

    init(screenRecordingGranted: Bool, imageData: Data, metadata: CaptureMetadata? = nil) {
        self.screenRecordingGranted = screenRecordingGranted
        self.imageData = imageData
        self.metadata = metadata
        self.windowMetadata = [:]
    }

    init(screenRecordingGranted: Bool, windowMetadata: [CGWindowID: CaptureMetadata]) {
        self.screenRecordingGranted = screenRecordingGranted
        self.imageData = Self.validPNGData
        self.metadata = nil
        self.windowMetadata = windowMetadata
    }

    func captureScreen(
        displayIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.captureAttemptCount += 1
        self.lastScale = scale
        return self.makeResult(mode: .screen)
    }

    func captureWindow(
        appIdentifier: String,
        windowIndex: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.captureAttemptCount += 1
        self.lastAppIdentifier = appIdentifier
        self.lastScale = scale
        return self.makeResult(
            mode: .window,
            window: ServiceWindowInfo(
                windowID: windowIndex ?? 0,
                title: appIdentifier,
                bounds: .zero,
                index: windowIndex ?? 0))
    }

    func captureWindow(
        windowID: CGWindowID,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.captureAttemptCount += 1
        self.lastWindowID = windowID
        self.lastScale = scale
        if let metadata = self.windowMetadata[windowID] {
            return CaptureResult(imageData: self.imageData, metadata: metadata)
        }
        return self.makeResult(
            mode: .window,
            window: ServiceWindowInfo(
                windowID: Int(windowID),
                title: "Window \(windowID)",
                bounds: .zero,
                index: Int(windowID)))
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.captureAttemptCount += 1
        self.lastScale = scale
        return self.makeResult(mode: .frontmost)
    }

    func captureArea(
        _ rect: CGRect,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.captureAttemptCount += 1
        self.lastArea = rect
        self.lastScale = scale
        return self.makeResult(mode: .area)
    }

    func hasScreenRecordingPermission() async -> Bool {
        self.screenRecordingGranted
    }

    private func makeResult(mode: CaptureMode, window: ServiceWindowInfo? = nil) -> CaptureResult {
        CaptureResult(
            imageData: self.imageData,
            metadata: self.metadata ?? CaptureMetadata(size: .zero, mode: mode, windowInfo: window))
    }

    private static let validPNGData = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
        0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D,
        0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    ])
}

@MainActor
final class MockScreenService: ScreenServiceProtocol {
    private let screens: [ScreenInfo]

    init(screens: [ScreenInfo]) {
        self.screens = screens
    }

    func listScreens() -> [ScreenInfo] {
        self.screens
    }

    func screenContainingWindow(bounds: CGRect) -> ScreenInfo? {
        self.screens.first { $0.frame.intersects(bounds) }
    }

    func screen(at index: Int) -> ScreenInfo? {
        self.screens.first { $0.index == index }
    }

    var primaryScreen: ScreenInfo? {
        self.screens.first { $0.isPrimary } ?? self.screens.first
    }
}
