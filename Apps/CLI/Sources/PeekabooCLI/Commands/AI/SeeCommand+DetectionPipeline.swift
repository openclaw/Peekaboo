import Foundation
import PeekabooCore

@available(macOS 14.0, *)
@MainActor
extension SeeCommand {
    func performCaptureWithDetection(snapshotID: String) async throws -> CaptureAndDetectionResult {
        if let observationResult = try await self.performObservationCaptureWithDetectionIfPossible(
            snapshotID: snapshotID
        ) {
            return observationResult
        }

        let captureContext = try await self.resolveCaptureContext()
        let captureResult = captureContext.captureResult

        self.logger.startTimer("file_write")
        let outputPath = try saveScreenshot(captureResult.imageData, snapshotID: snapshotID)
        self.logger.stopTimer("file_write")

        let windowContext = WindowContext(
            applicationName: captureResult.metadata.applicationInfo?.name,
            applicationBundleId: captureResult.metadata.applicationInfo?.bundleIdentifier,
            applicationProcessId: captureResult.metadata.applicationInfo?.processIdentifier,
            windowTitle: captureResult.metadata.windowInfo?.title,
            windowID: captureContext.windowIdOverride ?? captureResult.metadata.windowInfo?.windowID,
            windowBounds: captureContext.captureBounds ?? captureResult.metadata.windowInfo?.bounds,
            shouldFocusWebContent: self.noWebFocus ? false : true,
            traversalBudget: self.axTraversalBudget()
        )

        let detectionResult = try await self.detectElements(
            for: captureContext,
            windowContext: windowContext,
            snapshotID: snapshotID
        )

        let resultWithPath = ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: outputPath,
            elements: detectionResult.elements,
            metadata: detectionResult.metadata
        )

        try await self.services.snapshots.storeScreenshot(
            SnapshotScreenshotRequest(
                snapshotId: snapshotID,
                screenshotPath: outputPath,
                applicationBundleId: captureResult.metadata.applicationInfo?.bundleIdentifier,
                applicationProcessId: captureResult.metadata.applicationInfo.map { Int32($0.processIdentifier) },
                applicationName: windowContext.applicationName,
                windowTitle: windowContext.windowTitle,
                windowBounds: windowContext.windowBounds
            )
        )

        try await self.services.snapshots.storeDetectionResult(
            snapshotId: snapshotID,
            result: resultWithPath
        )

        return CaptureAndDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: outputPath,
            annotatedPath: nil,
            elements: detectionResult.elements,
            metadata: detectionResult.metadata,
            observation: nil
        )
    }

    private func detectElements(
        for captureContext: CaptureContext,
        windowContext: WindowContext,
        snapshotID: String
    ) async throws -> ElementDetectionResult {
        let captureResult = captureContext.captureResult
        let detectionStart = Date()

        if captureContext.prefersOCR {
            self.logger.verbose("Running OCR for menu bar popover", category: "Capture")
            let ocrElements = try self.ocrElements(
                imageData: captureResult.imageData,
                windowBounds: captureContext.captureBounds ?? captureResult.metadata.windowInfo?.bounds
            )

            let warnings = ocrElements.isEmpty ? ["OCR produced no elements"] : []
            let metadata = DetectionMetadata(
                detectionTime: Date().timeIntervalSince(detectionStart),
                elementCount: ocrElements.count,
                method: captureContext.ocrMethod ?? "OCR",
                warnings: warnings,
                windowContext: windowContext,
                isDialog: false
            )
            return ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: "",
                elements: DetectedElements(other: ocrElements),
                metadata: metadata
            )
        }

        let detectionResult = try await self.detectElements(
            imageData: captureResult.imageData,
            windowContext: windowContext,
            snapshotID: snapshotID
        )
        return ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: detectionResult.screenshotPath,
            elements: detectionResult.elements,
            metadata: detectionResult.metadata
        )
    }

    private func performObservationCaptureWithDetectionIfPossible(
        snapshotID: String
    ) async throws -> CaptureAndDetectionResult? {
        guard let target = try self.observationTargetForCaptureWithDetectionIfPossible() else {
            return nil
        }

        self.logger.verbose("Using desktop observation pipeline", category: "Capture", metadata: [
            "target": self.observationTargetDescription(target)
        ])
        let mode = self.determineMode()
        self.logger.operationStart("capture_phase", metadata: ["mode": mode.rawValue])

        let observation: DesktopObservationResult
        do {
            observation = try await self.services.desktopObservation
                .observe(self.makeObservationRequest(target: target, snapshotID: snapshotID))
        } catch DesktopObservationError.targetNotFound(_) where self.menubar {
            self.logger.verbose("No observation-backed menu bar popover found; falling back", category: "Capture")
            self.logger.operationComplete("capture_phase", success: false, metadata: [
                "mode": mode.rawValue,
                "fallback": "legacy_menubar",
            ])
            return nil
        }

        self.logger.operationComplete("capture_phase", metadata: [
            "mode": mode.rawValue
        ])

        self.logObservationSpans(observation.timings)

        guard let outputPath = observation.files.rawScreenshotPath else {
            throw CaptureError.captureFailure("Observation completed without a saved screenshot path")
        }
        guard let detectionResult = observation.elements else {
            throw CaptureError.captureFailure("Observation completed without element detection")
        }

        return CaptureAndDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: outputPath,
            annotatedPath: observation.files.annotatedScreenshotPath,
            elements: detectionResult.elements,
            metadata: detectionResult.metadata,
            observation: SeeObservationDiagnostics(
                timings: observation.timings,
                diagnostics: observation.diagnostics
            )
        )
    }

    private func logObservationSpans(_ timings: ObservationTimings) {
        for span in timings.spans {
            self.logger.verbose("Desktop observation span", category: "Performance", metadata: [
                "span": span.name,
                "duration_ms": Int(span.durationMS.rounded()),
            ])
        }
    }
}
