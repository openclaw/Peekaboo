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

    public init(
        screenCapture: any ScreenCaptureServiceProtocol,
        automation: any UIAutomationServiceProtocol,
        applications: any ApplicationServiceProtocol,
        menu: (any MenuServiceProtocol)? = nil,
        screens: any ScreenServiceProtocol = ScreenService(),
        snapshotManager: (any SnapshotManagerProtocol)? = nil,
        ocrRecognizer: any OCRRecognizing = OCRService(),
        exactWindowMetadataProvider: any ExactWindowMetadataProviding = SystemExactWindowMetadataProvider(),
        operationLaneCoordinator: DesktopOperationLaneCoordinator = .shared)
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
    }

    public init(
        screenCapture: any ScreenCaptureServiceProtocol,
        automation: any UIAutomationServiceProtocol,
        targetResolver: any ObservationTargetResolving,
        outputWriter: ObservationOutputWriter = ObservationOutputWriter(),
        stateSnapshotProvider: any DesktopStateSnapshotProviding = EmptyDesktopStateSnapshotProvider(),
        ocrRecognizer: any OCRRecognizing = OCRService(),
        operationLaneCoordinator: DesktopOperationLaneCoordinator = .shared)
    {
        self.screenCapture = screenCapture
        self.automation = automation
        self.targetResolver = targetResolver
        self.outputWriter = outputWriter
        self.stateSnapshotProvider = stateSnapshotProvider
        self.ocrRecognizer = ocrRecognizer
        self.operationLaneCoordinator = operationLaneCoordinator
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
        let tracer = DesktopObservationTraceRecorder()
        let observeStart = ContinuousClock.now
        let serializesDetection = request.detection.mode != .none && request.detection.allowWebFocusFallback

        let coordinatedCapture: @MainActor @Sendable () async throws
            -> (DesktopStateSnapshot, ResolvedObservationTarget, CaptureResult, ElementDetectionResult?) = {
                try await self.withCaptureTransaction {
                    let stateSnapshot = try await tracer.span("state.snapshot") {
                        try await self.stateSnapshotProvider.snapshot(for: request.target)
                    }

                    let target = try await tracer.span("target.resolve") {
                        try await self.targetResolver.resolve(request.target, snapshot: stateSnapshot)
                    }

                    let rawCapture = try await tracer.span("capture.\(Self.captureSpanName(for: target.kind))") {
                        try await self.capture(target, options: request.capture, snapshot: stateSnapshot)
                    }
                    try Self.validateCaptureReceipt(rawCapture, for: target)
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
        let (stateSnapshot, target, capture, serializedDetection) = try await self.withDesktopOperationLane(
            coordinatedCapture)
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
            request: request,
            tracer: tracer)
        try Task.checkCancellation()
        let elements = self.combineDetectionAndOCR(
            detection: detection,
            ocr: ocr,
            capture: capture,
            target: target,
            request: request)
        try Task.checkCancellation()
        let files = try await self.writeOutputIfNeeded(
            capture: capture,
            elements: elements,
            options: request.output,
            tracer: tracer)
        try Task.checkCancellation()
        tracer.record("desktop.observe", start: observeStart)

        var warnings = capture.warning.map { [$0] } ?? []
        warnings.append(contentsOf: ocr?.warnings ?? [])
        warnings.append(contentsOf: elements?.metadata.warnings ?? [])
        warnings = warnings.reduce(into: []) { unique, warning in
            if !unique.contains(warning) {
                unique.append(warning)
            }
        }

        return DesktopObservationResult(
            target: target,
            capture: capture,
            elements: elements,
            ocr: ocr,
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

    private func withDesktopOperationLane<T: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T
    {
        switch self.screenCapture.captureTransactionGateOwner {
        case .caller:
            try await self.operationLaneCoordinator.run(scope: .global, access: .write, operation: operation)
        case .service:
            // IPC-backed services acquire desktop and capture lanes in the execution host. Holding
            // either client-side lane across the RPC would make the host wait on its own caller.
            try await operation()
        }
    }
}
