import CoreGraphics
import Foundation

@MainActor
public protocol DesktopObservationServiceProtocol: Sendable {
    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult
}

@MainActor
public final class DesktopObservationService: DesktopObservationServiceProtocol {
    let screenCapture: any ScreenCaptureServiceProtocol
    let automation: any UIAutomationServiceProtocol
    let targetResolver: any ObservationTargetResolving
    let outputWriter: ObservationOutputWriter
    let stateSnapshotProvider: any DesktopStateSnapshotProviding
    let ocrRecognizer: any OCRRecognizing
    let operationLaneCoordinator: DesktopOperationLaneCoordinator
    let processStartIdentityProvider: @Sendable (pid_t) -> UInt64?
    let windowMutationIdentityProvider: @Sendable (CGWindowID) -> WindowMutationIdentity?

    public init(
        screenCapture: any ScreenCaptureServiceProtocol,
        automation: any UIAutomationServiceProtocol,
        applications: any ApplicationServiceProtocol,
        menu: (any MenuServiceProtocol)? = nil,
        screens: any ScreenServiceProtocol = ScreenService(),
        snapshotManager: (any SnapshotManagerProtocol)? = nil,
        ocrRecognizer: any OCRRecognizing = OCRService(),
        exactWindowMetadataProvider: any ExactWindowMetadataProviding = SystemExactWindowMetadataProvider(),
        operationLaneCoordinator: DesktopOperationLaneCoordinator = .shared,
        processStartIdentityProvider: @escaping @Sendable (pid_t) -> UInt64? =
            SystemIdentityResolver.processStartIdentity,
        windowMutationIdentityProvider: @escaping @Sendable (CGWindowID) -> WindowMutationIdentity? =
            SystemIdentityResolver.windowMutationIdentity)
    {
        self.screenCapture = screenCapture
        self.automation = automation
        self.targetResolver = ObservationTargetResolver(
            applications: applications,
            menu: menu,
            screens: screens,
            exactWindowMetadataProvider: exactWindowMetadataProvider)
        self.outputWriter = ObservationOutputWriter(snapshotManager: snapshotManager)
        self.stateSnapshotProvider = DesktopStateSnapshotProvider(applications: applications)
        self.ocrRecognizer = ocrRecognizer
        self.operationLaneCoordinator = operationLaneCoordinator
        self.processStartIdentityProvider = processStartIdentityProvider
        self.windowMutationIdentityProvider = windowMutationIdentityProvider
    }

    public init(
        screenCapture: any ScreenCaptureServiceProtocol,
        automation: any UIAutomationServiceProtocol,
        targetResolver: any ObservationTargetResolving,
        outputWriter: ObservationOutputWriter = ObservationOutputWriter(),
        stateSnapshotProvider: any DesktopStateSnapshotProviding = EmptyDesktopStateSnapshotProvider(),
        ocrRecognizer: any OCRRecognizing = OCRService(),
        operationLaneCoordinator: DesktopOperationLaneCoordinator = .shared,
        processStartIdentityProvider: @escaping @Sendable (pid_t) -> UInt64? =
            SystemIdentityResolver.processStartIdentity,
        windowMutationIdentityProvider: @escaping @Sendable (CGWindowID) -> WindowMutationIdentity? =
            SystemIdentityResolver.windowMutationIdentity)
    {
        self.screenCapture = screenCapture
        self.automation = automation
        self.targetResolver = targetResolver
        self.outputWriter = outputWriter
        self.stateSnapshotProvider = stateSnapshotProvider
        self.ocrRecognizer = ocrRecognizer
        self.operationLaneCoordinator = operationLaneCoordinator
        self.processStartIdentityProvider = processStartIdentityProvider
        self.windowMutationIdentityProvider = windowMutationIdentityProvider
    }

    public func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        let operation: @MainActor @Sendable () async throws -> DesktopObservationResult = {
            try await self.observeWithinOverallDeadline(request)
        }
        guard let overallTimeout = request.timeout.overall else {
            return try await operation()
        }
        return try await ElementDetectionTimeoutRunner.run(
            seconds: overallTimeout,
            operation: operation)
    }

    private func observeWithinOverallDeadline(
        _ request: DesktopObservationRequest) async throws -> DesktopObservationResult
    {
        try DesktopObservationROIProcessor.validateRequest(request.capture.roi, target: request.target)
        let tracer = DesktopObservationTraceRecorder()
        let observeStart = ContinuousClock.now
        let serializesDetection = request.detection.mode != .none && request.detection.allowWebFocusFallback

        let coordinatedCapture: @MainActor @Sendable (DesktopObservationLanePlan?) async throws
            -> (DesktopStateSnapshot, ResolvedObservationTarget, CaptureResult, ElementDetectionResult?) = { lanePlan in
                try await self.withCaptureTransaction {
                    let stateSnapshot = try await tracer.span("state.snapshot") {
                        try await self.stateSnapshotProvider.snapshot(for: request.target)
                    }

                    let target = try await tracer.span("target.resolve") {
                        try await self.targetResolver.resolve(request.target, snapshot: stateSnapshot)
                    }
                    try self.validateResolvedTarget(target, for: lanePlan)

                    let rawCapture = try await tracer.span("capture.\(Self.captureSpanName(for: target.kind))") {
                        try await self.capture(target, options: request.capture, snapshot: stateSnapshot)
                    }
                    try Self.validateCaptureReceipt(rawCapture, for: target)
                    try self.validateCurrentLaneIdentity(lanePlan)
                    let capture = Self.normalize(capture: rawCapture, for: target)
                    let captureBoundTarget = Self.bindingCaptureReceipt(to: target, capture: capture)
                    let detection: ElementDetectionResult? = if serializesDetection {
                        try await self.detectIfNeeded(
                            capture: capture,
                            target: captureBoundTarget,
                            request: request,
                            tracer: tracer)
                    } else {
                        nil
                    }
                    return (stateSnapshot, captureBoundTarget, capture, detection)
                }
            }
        let (stateSnapshot, target, capture, serializedDetection) = try await self.withPassiveCaptureReceiptRecovery(
            for: request)
        {
            try await self.withDesktopOperationLane(
                for: request,
                operation: coordinatedCapture)
        }
        // Web-focus fallback can AXPress hidden web content, so keep that mutating detection atomic with capture.
        // Read-only AX traversal and OCR can be slow without touching ScreenCaptureKit; let unrelated captures run.
        let detection = if serializesDetection {
            serializedDetection
        } else {
            try await self.detectIfNeeded(
                capture: capture,
                target: target,
                request: request,
                tracer: tracer)
        }
        let ocr = try await self.recognizeOCRIfNeeded(
            capture: capture,
            detection: detection,
            request: request,
            tracer: tracer)
        try Task.checkCancellation()
        let elements = self.combineDetectionAndOCR(
            detection: detection,
            ocr: ocr,
            capture: capture,
            target: target,
            request: request)
        let roiResult = try DesktopObservationROIProcessor.apply(
            request.capture.roi,
            target: target,
            capture: capture,
            elements: elements,
            ocr: ocr)
        try Task.checkCancellation()
        let files = try await self.writeOutputIfNeeded(
            capture: roiResult.capture,
            elements: roiResult.elements,
            options: request.output,
            tracer: tracer)
        try Task.checkCancellation()
        tracer.record("desktop.observe", start: observeStart)

        var warnings = roiResult.capture.warning.map { [$0] } ?? []
        warnings.append(contentsOf: roiResult.ocr?.warnings ?? [])
        warnings.append(contentsOf: roiResult.elements?.metadata.warnings ?? [])
        warnings = warnings.reduce(into: []) { unique, warning in
            if !unique.contains(warning) {
                unique.append(warning)
            }
        }

        return DesktopObservationResult(
            target: target,
            capture: roiResult.capture,
            elements: roiResult.elements,
            ocr: roiResult.ocr,
            files: files,
            timings: tracer.timings(),
            diagnostics: DesktopObservationDiagnostics(
                warnings: warnings,
                stateSnapshot: DesktopStateSnapshotSummary(stateSnapshot),
                target: Self.targetDiagnostics(for: request.target, resolved: target)))
    }

    private func withCaptureTransaction<T: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T
    {
        switch self.screenCapture.captureTransactionGateOwner {
        case .caller:
            try await ScreenCaptureKitCaptureGate.withExclusiveCaptureOperation(
                operationName: "desktopObservation",
                operation)
        case .service:
            // Remote services acquire the cross-process gate in their execution host. Acquiring it here first would
            // make the host wait forever on a lock owned by the client request that is waiting for that host.
            try await operation()
        }
    }

    private func withPassiveCaptureReceiptRecovery<T: Sendable>(
        for request: DesktopObservationRequest,
        operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T
    {
        do {
            return try await operation()
        } catch let error as DesktopObservationError {
            guard Self.allowsPassiveCaptureReceiptRecovery(request), case .targetChanged = error else {
                throw error
            }
            try Task.checkCancellation()
            return try await operation()
        }
    }

    private nonisolated static func allowsPassiveCaptureReceiptRecovery(
        _ request: DesktopObservationRequest) -> Bool
    {
        guard request.capture.focus == .background,
              !request.detection.allowWebFocusFallback
        else {
            return false
        }
        if case let .menubarPopover(_, openIfNeeded) = request.target, openIfNeeded != nil {
            return false
        }
        return true
    }
}
