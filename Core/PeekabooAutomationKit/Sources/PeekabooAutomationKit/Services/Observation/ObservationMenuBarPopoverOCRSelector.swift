import CoreGraphics
import Foundation

public struct ObservationMenuBarPopoverOCRMatch: Sendable {
    public let captureResult: CaptureResult
    public let bounds: CGRect
    public let windowID: CGWindowID?

    public init(captureResult: CaptureResult, bounds: CGRect, windowID: CGWindowID? = nil) {
        self.captureResult = captureResult
        self.bounds = bounds
        self.windowID = windowID
    }
}

@MainActor
public struct ObservationMenuBarPopoverOCRSelector {
    private let screenCapture: any ScreenCaptureServiceProtocol
    private let screens: [ScreenInfo]
    private let ocrRecognizer: any OCRRecognizing
    private let visualizerMode: CaptureVisualizerMode
    private let scale: CaptureScalePreference

    public init(
        screenCapture: any ScreenCaptureServiceProtocol,
        screens: [ScreenInfo],
        ocrRecognizer: any OCRRecognizing = OCRService(),
        visualizerMode: CaptureVisualizerMode = .none,
        scale: CaptureScalePreference = .logical1x)
    {
        self.screenCapture = screenCapture
        self.screens = screens
        self.ocrRecognizer = ocrRecognizer
        self.visualizerMode = visualizerMode
        self.scale = scale
    }

    public func matchCandidate(
        _ candidate: ObservationMenuBarPopoverCandidate,
        hints: [String]) async throws -> ObservationMenuBarPopoverOCRMatch?
    {
        try await self.matchCandidate(
            windowID: candidate.windowID,
            bounds: candidate.bounds,
            hints: hints)
    }

    public func matchCandidate(
        windowID: CGWindowID,
        bounds: CGRect,
        hints: [String]) async throws -> ObservationMenuBarPopoverOCRMatch?
    {
        let capture = try await self.screenCapture.captureWindow(
            windowID: windowID,
            visualizerMode: self.visualizerMode,
            scale: self.scale)
        return try await self.match(capture: capture, bounds: bounds, windowID: windowID, hints: hints)
    }

    public func matchArea(
        preferredX: CGFloat,
        hints: [String]) async throws -> ObservationMenuBarPopoverOCRMatch?
    {
        guard let rect = Self.popoverAreaRect(preferredX: preferredX, screens: self.screens) else {
            return nil
        }
        let capture = try await self.screenCapture.captureArea(
            rect,
            visualizerMode: self.visualizerMode,
            scale: self.scale)
        return try await self.match(capture: capture, bounds: rect, windowID: nil, hints: hints)
    }

    public func matchFrame(
        _ frame: CGRect,
        hints: [String],
        padding: CGFloat = 8) async throws -> ObservationMenuBarPopoverOCRMatch?
    {
        let padded = frame.insetBy(dx: -padding, dy: -padding)
        guard let clamped = Self.clamp(padded, to: self.screens) else {
            return nil
        }
        let capture = try await self.screenCapture.captureArea(
            clamped,
            visualizerMode: self.visualizerMode,
            scale: self.scale)
        return try await self.match(capture: capture, bounds: clamped, windowID: nil, hints: hints)
    }

    public static func popoverAreaRect(preferredX: CGFloat, screens: [ScreenInfo]) -> CGRect? {
        guard let screen = self.screenForMenuBarX(preferredX, screens: screens) else { return nil }
        let menuBarHeight = self.menuBarHeight(for: screen)
        let maxHeight = max(120, min(700, screen.frame.height - menuBarHeight))
        let width: CGFloat = 420
        let menuBarTop = screen.frame.maxY - menuBarHeight
        var rect = CGRect(
            x: preferredX - (width / 2.0),
            y: menuBarTop - maxHeight,
            width: width,
            height: maxHeight)
        rect.origin.x = max(screen.frame.minX, min(rect.origin.x, screen.frame.maxX - rect.width))
        rect.origin.y = max(screen.frame.minY, rect.origin.y)
        return rect
    }

    public static func clamp(_ rect: CGRect, to screens: [ScreenInfo]) -> CGRect? {
        guard !screens.isEmpty else { return nil }
        for screen in screens where screen.frame.intersects(rect) {
            return rect.intersection(screen.frame)
        }
        return rect
    }

    private func match(
        capture: CaptureResult,
        bounds: CGRect,
        windowID: CGWindowID?,
        hints: [String]) async throws -> ObservationMenuBarPopoverOCRMatch?
    {
        let ocr = try await self.ocrRecognizer.recognizeText(
            in: capture.imageData,
            timeoutSeconds: OCRService.defaultTimeoutSeconds)
        guard ocr.isComplete else {
            throw OCRServiceError.incomplete(ocr.warnings.joined(separator: "; "))
        }
        guard ObservationOCRMapper.matches(ocr, hints: Self.normalizedHints(hints)) else {
            return nil
        }
        return ObservationMenuBarPopoverOCRMatch(
            captureResult: capture,
            bounds: bounds,
            windowID: windowID)
    }

    private static func screenForMenuBarX(_ x: CGFloat, screens: [ScreenInfo]) -> ScreenInfo? {
        if let screen = screens.first(where: { $0.frame.minX <= x && x <= $0.frame.maxX }) {
            return screen
        }
        return screens.first(where: \.isPrimary) ?? screens.first
    }

    private static func menuBarHeight(for screen: ScreenInfo) -> CGFloat {
        let height = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        return height > 0 ? height : 24
    }

    private static func normalizedHints(_ hints: [String]) -> [String] {
        hints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
