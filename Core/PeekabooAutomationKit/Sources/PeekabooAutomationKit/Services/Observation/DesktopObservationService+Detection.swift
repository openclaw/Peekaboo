import CoreGraphics
import Foundation
import PeekabooFoundation

extension DesktopObservationService {
    func detectIfNeeded(
        capture: CaptureResult,
        target: ResolvedObservationTarget,
        request: DesktopObservationRequest,
        tracer: DesktopObservationTraceRecorder) async throws -> ElementDetectionResult?
    {
        guard request.detection.mode != .none else {
            return nil
        }

        var context = target.detectionContext ?? Self.windowContext(from: capture)
        context = WindowContext(
            applicationName: context?.applicationName,
            applicationBundleId: context?.applicationBundleId,
            applicationProcessId: context?.applicationProcessId,
            windowTitle: context?.windowTitle,
            windowID: context?.windowID,
            windowBounds: context?.windowBounds,
            shouldFocusWebContent: request.detection.allowWebFocusFallback,
            includeMenuBarElements: request.detection.includeMenuBarElements,
            traversalBudget: request.detection.traversalBudget)

        return try await tracer.span("detection.ax") {
            try await self.detectElements(
                in: capture.imageData,
                snapshotID: request.output.snapshotID,
                windowContext: context,
                timeout: request.timeout.detection)
        }
    }

    func recognizeOCRIfNeeded(
        capture: CaptureResult,
        request: DesktopObservationRequest,
        tracer: DesktopObservationTraceRecorder) async throws -> OCRTextResult?
    {
        guard request.detection.mode == .accessibilityAndOCR || request.detection.preferOCR else {
            return nil
        }

        return try await tracer.span("detection.ocr") {
            try self.ocrRecognizer.recognizeText(in: capture.imageData)
        }
    }

    func combineDetectionAndOCR(
        detection: ElementDetectionResult?,
        ocr: OCRTextResult?,
        capture: CaptureResult,
        target: ResolvedObservationTarget,
        request: DesktopObservationRequest) -> ElementDetectionResult?
    {
        guard let ocr else { return detection }

        let context = target.detectionContext ?? Self.windowContext(from: capture)
        guard let ocrDetection = self.ocrDetectionResult(
            from: ocr,
            capture: capture,
            context: context,
            request: request)
        else {
            return detection
        }

        guard !request.detection.preferOCR, let detection else {
            return ocrDetection
        }

        return ObservationOCRMapper.merge(
            ocrElements: ocrDetection.elements.other,
            into: detection)
    }

    func ocrDetectionResult(
        from ocr: OCRTextResult,
        capture: CaptureResult,
        context: WindowContext?,
        request: DesktopObservationRequest) -> ElementDetectionResult?
    {
        let windowBounds = context?.windowBounds ?? Self.captureBounds(from: capture)
        let normalizedContext = WindowContext(
            applicationName: context?.applicationName,
            applicationBundleId: context?.applicationBundleId,
            applicationProcessId: context?.applicationProcessId,
            windowTitle: context?.windowTitle,
            windowID: context?.windowID,
            windowBounds: windowBounds,
            shouldFocusWebContent: context?.shouldFocusWebContent)

        return ObservationOCRMapper.detectionResult(
            from: ocr,
            snapshotID: request.output.snapshotID,
            screenshotPath: capture.savedPath ?? "",
            windowContext: normalizedContext,
            detectionTime: 0)
    }

    func detectElements(
        in imageData: Data,
        snapshotID: String?,
        windowContext: WindowContext?,
        timeout: TimeInterval?) async throws -> ElementDetectionResult
    {
        let automation = self.automation
        let operation: @MainActor @Sendable () async throws -> ElementDetectionResult = {
            try await automation.detectElements(
                in: imageData,
                snapshotId: snapshotID,
                windowContext: windowContext)
        }

        guard let timeout else {
            return try await operation()
        }

        return try await self.withDetectionTimeout(seconds: timeout, operation: operation)
    }

    func withDetectionTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T
    {
        try await ElementDetectionTimeoutRunner.run(seconds: seconds, operation: operation)
    }

    static func windowContext(from capture: CaptureResult) -> WindowContext? {
        guard capture.metadata.applicationInfo != nil || capture.metadata.windowInfo != nil else {
            return nil
        }

        return WindowContext(
            applicationName: capture.metadata.applicationInfo?.name,
            applicationBundleId: capture.metadata.applicationInfo?.bundleIdentifier,
            applicationProcessId: capture.metadata.applicationInfo?.processIdentifier,
            windowTitle: capture.metadata.windowInfo?.title,
            windowID: capture.metadata.windowInfo?.windowID,
            windowBounds: capture.metadata.windowInfo?.bounds)
    }

    static func captureBounds(from capture: CaptureResult) -> CGRect {
        if let windowBounds = capture.metadata.windowInfo?.bounds {
            return windowBounds
        }
        if let displayBounds = capture.metadata.displayInfo?.bounds {
            return displayBounds
        }
        return CGRect(origin: .zero, size: capture.metadata.size)
    }
}
