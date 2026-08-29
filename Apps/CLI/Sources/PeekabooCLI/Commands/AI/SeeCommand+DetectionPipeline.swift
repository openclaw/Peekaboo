import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

@available(macOS 14.0, *)
@MainActor
extension SeeCommand {
    func performCaptureWithDetection(
        snapshotID: String,
        observationTimeoutSeconds: TimeInterval
    ) async throws -> CaptureAndDetectionResult {
        if self.noScreenshot {
            return try await self.performTreeOnlyDetection(
                snapshotID: snapshotID,
                observationTimeoutSeconds: observationTimeoutSeconds
            )
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

        let detectionActionResult = try await self.detectElements(
            for: captureContext,
            windowContext: windowContext,
            snapshotID: snapshotID
        )
        let detectionResult = detectionActionResult.payload
        let receipt = try SeeExecutionReceipt.validated(
            detectionActionResult,
            operation: "See element detection",
            requiresOutcome: self.webFocus || self.menubar,
            requiresTarget: (self.webFocus || self.menubar) && self.requiresExactObservationTarget
        )

        do {
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
                    applicationProcessId: captureResult.metadata.applicationInfo.map {
                        Int32($0.processIdentifier)
                    },
                    applicationName: windowContext.applicationName,
                    windowTitle: windowContext.windowTitle,
                    windowBounds: windowContext.windowBounds,
                    captureCoordinateContext: CaptureCoordinateContext(
                        metadata: captureResult.metadata,
                        referenceID: snapshotID
                    )
                )
            )

            try await self.services.snapshots.storeDetectionResult(
                snapshotId: snapshotID,
                result: resultWithPath
            )

            return CaptureAndDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: outputPath,
                screenshotData: captureResult.imageData,
                annotatedPath: nil,
                annotatedData: nil,
                elements: detectionResult.elements,
                metadata: detectionResult.metadata,
                observation: nil,
                coordinateContext: captureResult.metadata.viewport.map { _ in
                    CaptureCoordinateContext(metadata: captureResult.metadata, referenceID: snapshotID)
                },
                receipt: receipt
            )
        } catch {
            throw receipt.preservingFailure(error, operation: "see snapshot publication")
        }
    }

    private func performTreeOnlyDetection(
        snapshotID: String,
        observationTimeoutSeconds: TimeInterval
    ) async throws -> CaptureAndDetectionResult {
        let observationDeadline = Date().addingTimeInterval(max(observationTimeoutSeconds, 0.001))
        if self.app != nil, self.pid != nil {
            throw ValidationError("Use either --app or --pid, not both")
        }
        let appName: String? =
            if self.app?.lowercased() == "frontmost" {
                nil
            } else {
                self.app
            }
        let windowID = try await self.resolvedTreeWindowID()
        let accessibilityTimeoutSeconds = max(0.001, observationDeadline.timeIntervalSinceNow)
        let actionResult = try await self.services.automation.inspectAccessibilityTreeResult(
            windowContext: WindowContext(
                applicationName: appName,
                applicationProcessId: self.pid,
                windowTitle: self.windowTitle,
                windowID: windowID,
                shouldFocusWebContent: self.webFocus,
                traversalBudget: self.axTraversalBudget(),
                accessibilityTimeoutSeconds: accessibilityTimeoutSeconds,
                allowApplicationScopedAccessibilityFallback: windowID != nil && !self.webFocus
            )
        )
        let result = actionResult.payload
        let receipt = try SeeExecutionReceipt.validated(
            actionResult,
            operation: "Tree-only See",
            requiresOutcome: self.webFocus,
            requiresTarget: self.webFocus && self.requiresExactObservationTarget
        )
        do {
            try self.requireUsableTreeOnlyEvidence(result)
            try self.requireBoundTreeOnlyEvidence(
                result,
                receipt: receipt.targetReceipt,
                expectedWindowID: windowID
            )
            let bound = ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: "",
                elements: result.elements,
                metadata: result.metadata
            )
            if !bound.metadata.isApplicationScopedAccessibilityFallback {
                try await self.services.snapshots.storeDetectionResult(snapshotId: snapshotID, result: bound)
            }
            return CaptureAndDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: "",
                screenshotData: nil,
                annotatedPath: nil,
                annotatedData: nil,
                elements: bound.elements,
                metadata: bound.metadata,
                observation: nil,
                coordinateContext: nil,
                receipt: receipt
            )
        } catch {
            throw receipt.preservingFailure(error, operation: "tree-only see")
        }
    }

    private func requireUsableTreeOnlyEvidence(_ result: ElementDetectionResult) throws {
        guard result.elements.all.isEmpty,
              let truncationInfo = result.metadata.truncationInfo,
              truncationInfo.isTruncated
        else { return }

        if truncationInfo.deadlineReached {
            throw CaptureError.detectionTimedOut(self.overallTimeoutSeconds)
        }
        let message = truncationInfo.remediationMessage(
            budget: result.metadata.windowContext?.traversalBudget,
            applicationScopedFallback: result.metadata.isApplicationScopedAccessibilityFallback
        )
        if truncationInfo.incompleteAccessibilityRead,
           result.metadata.windowContext?.windowID != nil ||
           result.metadata.isApplicationScopedAccessibilityFallback {
            throw PeekabooError.accessibilityIncomplete(message)
        }
        throw PeekabooError.operationError(message: message)
    }

    private func requireBoundTreeOnlyEvidence(
        _ result: ElementDetectionResult,
        receipt: DesktopActionTargetReceipt?,
        expectedWindowID: Int?
    ) throws {
        guard let context = result.metadata.windowContext,
              let processIdentifier = context.applicationProcessId,
              processIdentifier > 0,
              let processStartIdentity = context.applicationProcessStartIdentity ??
              context.windowMutationIdentity?.ownerProcessStartIdentity,
              processStartIdentity > 0,
              receipt?.processIdentifier == processIdentifier,
              receipt?.processStartIdentity == processStartIdentity
        else {
            throw PeekabooError.snapshotStale(
                "AX-only see could not bind its elements to an exact process-generation receipt. "
                    + "Run see again before background input."
            )
        }
        if result.metadata.isApplicationScopedAccessibilityFallback {
            guard let expectedWindowID,
                  let origin = result.metadata.applicationScopedAccessibilityFallbackOrigin,
                  origin.windowID == expectedWindowID,
                  origin.processIdentifier == processIdentifier,
                  origin.processStartIdentity == processStartIdentity,
                  context.windowID == nil,
                  context.windowBounds == nil,
                  context.windowMutationIdentity == nil,
                  receipt?.windowID == nil
            else {
                throw PeekabooError.snapshotStale(
                    "Application-partial AX evidence did not retain its exact WindowServer origin receipt."
                )
            }
            return
        }
        guard receipt?.windowID != nil else { return }
        guard
            let windowID = context.windowID,
            windowID > 0,
            let bounds = context.windowBounds,
            bounds.width > 0,
            bounds.height > 0,
            let identity = context.windowMutationIdentity,
            identity.windowID == windowID,
            identity.ownerProcessIdentifier == processIdentifier,
            identity.ownerProcessStartIdentity == processStartIdentity,
            receipt?.windowID == windowID,
            identity.capturedBounds == bounds
        else {
            throw PeekabooError.snapshotStale(
                "AX-only see could not bind its elements to an exact process-generation, window, and bounds "
                    + "receipt. Run see again before background input."
            )
        }
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
    ) async throws -> UIAutomationActionResult<ElementDetectionResult> {
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
            return Self.legacyMenuBarOCRDetectionResult(
                snapshotID: snapshotID,
                elements: ocrElements,
                metadata: metadata
            )
        }

        let detectionResult = try await self.detectElements(
            imageData: captureResult.imageData,
            windowContext: windowContext,
            snapshotID: snapshotID
        )
        return UIAutomationActionResult(
            payload: ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: detectionResult.payload.screenshotPath,
                elements: detectionResult.payload.elements,
                metadata: detectionResult.payload.metadata
            ),
            outcome: detectionResult.outcome,
            targetIdentity: detectionResult.targetIdentity
        )
    }

    static func legacyMenuBarOCRDetectionResult(
        snapshotID: String,
        elements: [DetectedElement],
        metadata: DetectionMetadata
    ) -> UIAutomationActionResult<ElementDetectionResult> {
        UIAutomationActionResult(
            payload: ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: "",
                elements: DetectedElements(other: elements),
                metadata: metadata
            ),
            // A post-click resolution failure is canonicalized before this read-only fallback is reached.
            outcome: .confirmedNoChange()
        )
    }

    private func performObservationCaptureWithDetectionIfPossible(
        snapshotID: String
    ) async throws -> CaptureAndDetectionResult? {
        guard let target = try self.observationTargetForCaptureWithDetectionIfPossible() else {
            return nil
        }

        self.logger.verbose(
            "Using desktop observation pipeline",
            category: "Capture",
            metadata: [
                "target": self.observationTargetDescription(target),
            ]
        )
        let mode = self.determineMode()
        self.logger.operationStart("capture_phase", metadata: ["mode": mode.rawValue])

        let observationActionResult: UIAutomationActionResult<DesktopObservationResult>
        do {
            observationActionResult = try await self.services.desktopObservation
                .observeResult(self.makeObservationRequest(target: target, snapshotID: snapshotID))
        } catch DesktopObservationError.targetNotFound(_) where self.menubar {
            self.logger.verbose(
                "No observation-backed menu bar popover found; falling back", category: "Capture"
            )
            self.logger.operationComplete(
                "capture_phase",
                success: false,
                metadata: [
                    "mode": mode.rawValue,
                    "fallback": "legacy_menubar",
                ]
            )
            return nil
        }
        let observation = observationActionResult.payload
        let receipt = try SeeExecutionReceipt.validated(
            observationActionResult,
            operation: "See observation",
            requiresOutcome: self.webFocus || self.menubar,
            requiresTarget: (self.webFocus || self.menubar) && self.requiresExactObservationTarget
        )

        self.logger.operationComplete(
            "capture_phase",
            metadata: [
                "mode": mode.rawValue,
            ]
        )

        self.logObservationSpans(observation.timings)

        do {
            guard let outputPath = observation.files.rawScreenshotPath else {
                throw CaptureError.captureFailure("Observation completed without a saved screenshot path")
            }
            guard let detectionResult = observation.elements else {
                throw CaptureError.captureFailure("Observation completed without element detection")
            }
            let screenshotData = try observation.verifiedRawScreenshotData()
            let annotatedData = try observation.files.annotatedScreenshotPath.map { _ in
                try observation.verifiedAnnotatedScreenshotData()
            }

            return CaptureAndDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: outputPath,
                screenshotData: screenshotData,
                annotatedPath: observation.files.annotatedScreenshotPath,
                annotatedData: annotatedData,
                elements: detectionResult.elements,
                metadata: detectionResult.metadata,
                observation: SeeObservationDiagnostics(
                    timings: observation.timings,
                    diagnostics: observation.diagnostics
                ),
                coordinateContext: CaptureCoordinateContext(
                    metadata: observation.capture.metadata,
                    referenceID: snapshotID
                ),
                receipt: receipt
            )
        } catch {
            throw receipt.preservingFailure(error, operation: "see observation result preparation")
        }
    }

    private func logObservationSpans(_ timings: ObservationTimings) {
        for span in timings.spans {
            self.logger.verbose(
                "Desktop observation span",
                category: "Performance",
                metadata: [
                    "span": span.name,
                    "duration_ms": Int(span.durationMS.rounded()),
                ]
            )
        }
    }
}
