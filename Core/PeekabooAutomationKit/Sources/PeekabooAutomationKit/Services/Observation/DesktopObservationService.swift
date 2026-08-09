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

    public init(
        screenCapture: any ScreenCaptureServiceProtocol,
        automation: any UIAutomationServiceProtocol,
        applications: any ApplicationServiceProtocol,
        menu: (any MenuServiceProtocol)? = nil,
        screens: any ScreenServiceProtocol = ScreenService(),
        snapshotManager: (any SnapshotManagerProtocol)? = nil,
        ocrRecognizer: any OCRRecognizing = OCRService())
    {
        self.screenCapture = screenCapture
        self.automation = automation
        self.targetResolver = ObservationTargetResolver(applications: applications, menu: menu, screens: screens)
        self.outputWriter = ObservationOutputWriter(snapshotManager: snapshotManager)
        self.stateSnapshotProvider = DesktopStateSnapshotProvider(applications: applications)
        self.ocrRecognizer = ocrRecognizer
    }

    public init(
        screenCapture: any ScreenCaptureServiceProtocol,
        automation: any UIAutomationServiceProtocol,
        targetResolver: any ObservationTargetResolving,
        outputWriter: ObservationOutputWriter = ObservationOutputWriter(),
        stateSnapshotProvider: any DesktopStateSnapshotProviding = EmptyDesktopStateSnapshotProvider(),
        ocrRecognizer: any OCRRecognizing = OCRService())
    {
        self.screenCapture = screenCapture
        self.automation = automation
        self.targetResolver = targetResolver
        self.outputWriter = outputWriter
        self.stateSnapshotProvider = stateSnapshotProvider
        self.ocrRecognizer = ocrRecognizer
    }

    public func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        let tracer = DesktopObservationTraceRecorder()
        let observeStart = ContinuousClock.now

        let (stateSnapshot, target, capture, elements, ocr) = try await ScreenCaptureKitCaptureGate
            .withExclusiveCaptureOperation(
                operationName: "desktopObservation")
            {
                let stateSnapshot = try await tracer.span("state.snapshot") {
                    try await self.stateSnapshotProvider.snapshot(for: request.target)
                }

                let target = try await tracer.span("target.resolve") {
                    try await self.targetResolver.resolve(request.target, snapshot: stateSnapshot)
                }

                let rawCapture = try await tracer.span("capture.\(Self.captureSpanName(for: target.kind))") {
                    try await self.capture(target, options: request.capture, snapshot: stateSnapshot)
                }
                let capture = Self.normalize(capture: rawCapture, for: target)
                let detection = try await self.detectIfNeeded(
                    capture: capture,
                    target: target,
                    request: request,
                    tracer: tracer)
                let ocr = try await self.recognizeOCRIfNeeded(
                    capture: capture,
                    request: request,
                    tracer: tracer)
                let elements = self.combineDetectionAndOCR(
                    detection: detection,
                    ocr: ocr,
                    capture: capture,
                    target: target,
                    request: request)
                return (stateSnapshot, target, capture, elements, ocr)
            }
        let files = try await self.writeOutputIfNeeded(
            capture: capture,
            elements: elements,
            options: request.output,
            tracer: tracer)
        tracer.record("desktop.observe", start: observeStart)

        return DesktopObservationResult(
            target: target,
            capture: capture,
            elements: elements,
            ocr: ocr,
            files: files,
            timings: tracer.timings(),
            diagnostics: DesktopObservationDiagnostics(
                warnings: capture.warning.map { [$0] } ?? [],
                stateSnapshot: DesktopStateSnapshotSummary(stateSnapshot),
                target: Self.targetDiagnostics(for: request.target, resolved: target)))
    }
}
