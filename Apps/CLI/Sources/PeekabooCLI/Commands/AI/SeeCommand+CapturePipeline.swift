import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
extension SeeCommand {
    func detectElements(
        imageData: Data,
        windowContext: WindowContext?,
        snapshotID: String? = nil
    ) async throws -> UIAutomationActionResult<ElementDetectionResult> {
        self.logger.operationStart("element_detection")
        defer { self.logger.operationComplete("element_detection") }

        let timeoutSeconds = Self.detectionTimeoutSeconds(
            configuredTimeoutSeconds: self.timeout?.seconds,
            analyze: self.analyze
        )

        do {
            return try await Self.detectElementsResult(
                automation: self.services.automation,
                imageData: imageData,
                windowContext: windowContext,
                timeoutSeconds: timeoutSeconds,
                snapshotID: snapshotID,
                interactionMutationTracker: self.resolvedRuntime.observationTimeoutMutationTracker
            )
        } catch is TimeoutError where windowContext?.shouldFocusWebContent == true {
            throw DesktopActionFailure.indeterminate(
                route: self.resolvedRuntime.selectedRemoteSocketPath == nil ? .local : .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                evidence: .completionUnknown,
                message: "Element detection timed out after web-content focus may have been dispatched.",
                hint: "Observe the target before retrying with --web-focus.",
                causeDescription: CaptureError.detectionTimedOut(timeoutSeconds).localizedDescription
            ).attributed(to: SeeExecutionReceipt.targetReceipt(from: windowContext))
        } catch is TimeoutError {
            throw CaptureError.detectionTimedOut(timeoutSeconds)
        }
    }

    static func detectionTimeoutSeconds(
        configuredTimeoutSeconds: TimeInterval?,
        analyze: String?
    ) -> TimeInterval {
        configuredTimeoutSeconds ?? ((analyze == nil) ? 20 : 60)
    }

    static func remoteDetectionRequestTimeoutSeconds(for timeoutSeconds: TimeInterval) -> TimeInterval {
        timeoutSeconds + 5
    }

    static func detectElements(
        automation: any UIAutomationServiceProtocol,
        imageData: Data,
        windowContext: WindowContext?,
        timeoutSeconds: TimeInterval,
        snapshotID: String? = nil,
        interactionMutationTracker: InteractionMutationTracker? = nil
    ) async throws -> ElementDetectionResult {
        try await self.detectElementsResult(
            automation: automation,
            imageData: imageData,
            windowContext: windowContext,
            timeoutSeconds: timeoutSeconds,
            snapshotID: snapshotID,
            interactionMutationTracker: interactionMutationTracker
        ).payload
    }

    static func detectElementsResult(
        automation: any UIAutomationServiceProtocol,
        imageData: Data,
        windowContext: WindowContext?,
        timeoutSeconds: TimeInterval,
        snapshotID: String? = nil,
        interactionMutationTracker: InteractionMutationTracker? = nil
    ) async throws -> UIAutomationActionResult<ElementDetectionResult> {
        try await withWallClockTimeout(
            seconds: timeoutSeconds,
            interactionMutationTracker: interactionMutationTracker
        ) {
            try await automation.detectElementsResult(
                in: imageData,
                snapshotId: snapshotID,
                windowContext: windowContext,
                requestTimeoutSec: Self.remoteDetectionRequestTimeoutSeconds(for: timeoutSeconds)
            )
        }
    }

    func resolveCaptureContext() async throws -> CaptureContext {
        if self.menubar {
            if let popover = try await self.captureMenuBarPopover() {
                return CaptureContext(
                    captureResult: popover.captureResult,
                    captureBounds: popover.windowBounds,
                    prefersOCR: true,
                    ocrMethod: "OCR",
                    windowIdOverride: popover.windowId
                )
            }

            self.logger.verbose("No menu bar popover detected; capturing menu bar area", category: "Capture")
            let rect = try self.menuBarRect()
            let result = try await self.services.screenCapture.captureArea(
                rect,
                visualizerMode: .none,
                scale: .logical1x
            )
            return CaptureContext(
                captureResult: result,
                captureBounds: rect,
                prefersOCR: true,
                ocrMethod: "OCR",
                windowIdOverride: nil
            )
        }

        let result = try await self.performLegacyScreenCapture()
        return CaptureContext(
            captureResult: result,
            captureBounds: nil,
            prefersOCR: false,
            ocrMethod: nil,
            windowIdOverride: nil
        )
    }

    private func performLegacyScreenCapture() async throws -> CaptureResult {
        let effectiveMode = self.determineMode()
        self.logger.verbose(
            "Determined capture mode",
            category: "Capture",
            metadata: ["mode": effectiveMode.rawValue]
        )

        self.logger.operationStart("capture_phase", metadata: ["mode": effectiveMode.rawValue])
        switch effectiveMode {
        case .screen:
            // Handle screen capture with multi-screen support
            let result = try await self.performScreenCapture()
            self.logger.operationComplete("capture_phase", metadata: ["mode": effectiveMode.rawValue])
            return result

        case .multi:
            // Commander currently treats multi captures as multi-display screen grabs
            let result = try await self.performScreenCapture()
            self.logger.operationComplete("capture_phase", metadata: ["mode": effectiveMode.rawValue])
            return result

        case .window, .frontmost, .area:
            throw ValidationError("\(effectiveMode.rawValue) captures must use the desktop observation pipeline")
        }
    }
}
