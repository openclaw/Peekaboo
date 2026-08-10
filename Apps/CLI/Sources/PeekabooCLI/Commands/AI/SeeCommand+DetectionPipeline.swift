import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

@available(macOS 14.0, *)
@MainActor
extension SeeCommand {
    func performCaptureWithDetection(snapshotID: String) async throws -> CaptureAndDetectionResult {
        if self.noScreenshot {
            return try await self.performTreeOnlyDetection(snapshotID: snapshotID)
        }

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
            shouldFocusWebContent: self.webFocus,
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

    private func performTreeOnlyDetection(snapshotID: String) async throws -> CaptureAndDetectionResult {
        if self.app != nil, self.pid != nil {
            throw ValidationError("Use either --app or --pid, not both")
        }
        let appName: String? = if self.app?.lowercased() == "frontmost" {
            nil
        } else {
            self.app
        }
        let result = try await self.services.automation.inspectAccessibilityTree(
            windowContext: WindowContext(
                applicationName: appName,
                applicationProcessId: self.pid,
                windowTitle: self.windowTitle,
                windowID: self.resolvedTreeWindowID(),
                shouldFocusWebContent: self.webFocus,
                traversalBudget: self.axTraversalBudget()
            )
        )
        let bound = ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "",
            elements: result.elements,
            metadata: result.metadata
        )
        try await self.services.snapshots.storeDetectionResult(snapshotId: snapshotID, result: bound)
        return CaptureAndDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "",
            annotatedPath: nil,
            elements: bound.elements,
            metadata: bound.metadata,
            observation: nil
        )
    }

    func resolvedTreeWindowID() async throws -> Int? {
        if let windowId = self.windowId {
            return windowId
        }
        guard let windowIndex = self.windowIndex else {
            return nil
        }
        let identifier: String
        if let pid = self.pid {
            identifier = "PID:\(pid)"
        } else if self.app != nil {
            identifier = try self.resolveApplicationIdentifier()
        } else {
            throw ValidationError("--window-index requires --app or --pid")
        }
        let windows = try await WindowServiceBridge.listWindows(
            windows: self.services.windows,
            target: .index(app: identifier, index: windowIndex)
        )
        guard let windowID = windows.first?.windowID else {
            throw PeekabooError.windowNotFound(
                criteria: "No window at index \(windowIndex) for \(identifier)"
            )
        }
        return windowID
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
            let ocrElements = try await self.ocrElements(
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
            "target": self.observationTargetDescription(target),
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
            "mode": mode.rawValue,
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
