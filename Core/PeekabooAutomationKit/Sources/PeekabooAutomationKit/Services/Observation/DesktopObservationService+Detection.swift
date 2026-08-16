import CoreGraphics
import Foundation
import PeekabooFoundation

extension DesktopObservationService {
    func detectIfNeeded(
        capture: CaptureResult,
        target: ResolvedObservationTarget,
        request: DesktopObservationRequest,
        tracer: DesktopObservationTraceRecorder) async throws
        -> UIAutomationActionResult<ElementDetectionResult>?
    {
        guard request.detection.mode != .none else {
            return nil
        }

        var context = Self.windowContext(for: target, capture: capture)
        context = WindowContext(
            applicationName: context?.applicationName,
            applicationBundleId: context?.applicationBundleId,
            applicationProcessId: context?.applicationProcessId,
            windowTitle: context?.windowTitle,
            windowID: context?.windowID,
            windowBounds: context?.windowBounds,
            windowMutationIdentity: context?.windowMutationIdentity,
            shouldFocusWebContent: request.detection.allowWebFocusFallback,
            includeMenuBarElements: request.detection.includeMenuBarElements,
            traversalBudget: request.detection.traversalBudget,
            requiresFreshAccessibilityTree: context?.requiresFreshAccessibilityTree ?? false,
            accessibilityTimeoutSeconds: request.timeout.detection)

        return try await tracer.span("detection.ax") {
            try await self.detectElementsResult(
                in: capture.imageData,
                snapshotID: request.output.snapshotID,
                windowContext: context,
                timeout: request.timeout.detection)
        }
    }

    func recognizeOCRIfNeeded(
        capture: CaptureResult,
        detection: ElementDetectionResult?,
        request: DesktopObservationRequest,
        tracer: DesktopObservationTraceRecorder) async throws -> OCRTextResult?
    {
        let explicitlyRequested = request.detection.mode == .accessibilityAndOCR || request.detection.preferOCR
        let needsSemanticRepair = ObservationOCRMapper.needsSemanticLabelRecovery(in: detection)
        guard explicitlyRequested || needsSemanticRepair else {
            return nil
        }
        let semanticRegions = needsSemanticRepair && !explicitlyRequested
            ? ObservationOCRMapper.semanticLabelRecognitionRegions(
                in: detection,
                windowBounds: Self.captureBounds(from: capture))
            : []
        guard explicitlyRequested || !semanticRegions.isEmpty else { return nil }

        return try await tracer.span("detection.ocr") {
            let timeout = request.timeout.ocr ?? request.timeout.detection ?? OCRService.defaultTimeoutSeconds
            do {
                let recognizer = self.ocrRecognizer
                let imageData = capture.imageData
                return try await OCRExecutionRunner.runAsync(seconds: timeout) {
                    if !semanticRegions.isEmpty {
                        return try await recognizer.recognizeText(
                            in: imageData,
                            timeoutSeconds: timeout,
                            regions: semanticRegions)
                    }
                    return try await recognizer.recognizeText(
                        in: imageData,
                        timeoutSeconds: timeout,
                        quality: .fast)
                }
            } catch let CaptureError.detectionTimedOut(seconds) {
                return OCRTextResult.incomplete(
                    imageSize: capture.metadata.size,
                    deadlineReached: true,
                    reason: "OCR incomplete: deadline reached after \(seconds)s; missing text does not prove absence")
            } catch let OCRServiceError.incomplete(reason) {
                return OCRTextResult.incomplete(
                    imageSize: capture.metadata.size,
                    deadlineReached: false,
                    reason: "OCR incomplete: \(reason); missing text does not prove absence")
            }
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

        let context = Self.windowContext(for: target, capture: capture)
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
            ocrResult: ocr,
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
            windowMutationIdentity: context?.windowMutationIdentity,
            shouldFocusWebContent: context?.shouldFocusWebContent)

        return ObservationOCRMapper.detectionResult(
            from: ocr,
            snapshotID: request.output.snapshotID,
            screenshotPath: capture.savedPath ?? "",
            windowContext: normalizedContext,
            detectionTime: 0)
    }

    func detectElementsResult(
        in imageData: Data,
        snapshotID: String?,
        windowContext: WindowContext?,
        timeout: TimeInterval?) async throws -> UIAutomationActionResult<ElementDetectionResult>
    {
        let automation = self.automation
        let operation: @MainActor @Sendable () async throws -> UIAutomationActionResult<ElementDetectionResult> = {
            try await automation.detectElementsResult(
                in: imageData,
                snapshotId: snapshotID,
                windowContext: windowContext,
                requestTimeoutSec: timeout)
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

        let windowID = capture.metadata.windowInfo?.windowID
        let windowBounds = capture.metadata.windowInfo?.bounds
        let capturedIdentity = capture.metadata.windowInfo?.mutationIdentity
        let mutationIdentity: WindowMutationIdentity? = if let capturedIdentity,
                                                           let windowID,
                                                           capturedIdentity.windowID == windowID,
                                                           capture.metadata.applicationInfo?.processIdentifier == nil ||
                                                           capture.metadata.applicationInfo?.processIdentifier ==
                                                           capturedIdentity.ownerProcessIdentifier
        {
            capturedIdentity
        } else {
            nil
        }
        let processIdentifier = capture.metadata.applicationInfo?.processIdentifier ??
            mutationIdentity?.ownerProcessIdentifier
        return WindowContext(
            applicationName: capture.metadata.applicationInfo?.name,
            applicationBundleId: capture.metadata.applicationInfo?.bundleIdentifier,
            applicationProcessId: processIdentifier,
            windowTitle: capture.metadata.windowInfo?.title,
            windowID: windowID,
            windowBounds: windowBounds,
            windowMutationIdentity: mutationIdentity)
    }

    static func windowContext(
        for target: ResolvedObservationTarget,
        capture: CaptureResult) -> WindowContext?
    {
        let targetContext = target.detectionContext
        let captureContext = self.windowContext(from: capture)
        guard targetContext != nil || captureContext != nil else { return nil }
        return WindowContext(
            applicationName: targetContext?.applicationName ?? captureContext?.applicationName,
            applicationBundleId: targetContext?.applicationBundleId ?? captureContext?.applicationBundleId,
            applicationProcessId: targetContext?.applicationProcessId ?? captureContext?.applicationProcessId,
            windowTitle: targetContext?.windowTitle ?? captureContext?.windowTitle,
            windowID: captureContext?.windowID ?? targetContext?.windowID,
            windowBounds: captureContext?.windowBounds ?? targetContext?.windowBounds,
            windowMutationIdentity: captureContext?.windowMutationIdentity,
            requiresFreshAccessibilityTree: targetContext?.requiresFreshAccessibilityTree ?? false)
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
