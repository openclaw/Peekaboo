import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
public protocol DesktopObservationServiceProtocol: Sendable {
    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult
}

/// Additive capability for observations that can conditionally mutate desktop state.
public protocol DesktopObservationActionResultProviding: DesktopObservationServiceProtocol {
    func observeActionResult(
        _ request: DesktopObservationRequest) async throws -> UIAutomationActionResult<DesktopObservationResult>
}

extension DesktopObservationServiceProtocol {
    public func observeResult(
        _ request: DesktopObservationRequest) async throws -> UIAutomationActionResult<DesktopObservationResult>
    {
        if let results = self as? any DesktopObservationActionResultProviding {
            return try await results.observeActionResult(request)
        }
        let mutationDelivery = Self.observationMutationDelivery(for: request)
        do {
            return try await UIAutomationActionResult(
                payload: self.observe(request),
                outcome: mutationDelivery.map {
                    .dispatchedUnverified(
                        delivery: $0,
                        evidence: .deliveryAccepted,
                        unitCount: .one)
                })
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch {
            guard let mutationDelivery else { throw error }
            throw DesktopActionFailure.indeterminate(
                delivery: mutationDelivery,
                evidence: .completionUnknown,
                message:
                "Desktop observation failed after a conditional mutation may have been dispatched.",
                hint: "Observe the target before retrying this observation.",
                causeDescription: error.localizedDescription)
        }
    }

    static func observationMutationDelivery(
        for request: DesktopObservationRequest) -> DesktopActionOutcome.Delivery?
    {
        let mayOpenMenuBarPopover =
            if case let .menubarPopover(_, openIfNeeded) = request.target {
                openIfNeeded != nil
            } else {
                false
            }
        guard
            request.capture.focus != .background
            || (request.detection.mode != .none && request.detection.allowWebFocusFallback)
            || mayOpenMenuBarPopover
        else { return nil }
        return .init(
            mechanism: .capturePipeline,
            mode: request.capture.focus == .background ? .background : .foreground)
    }
}

/// Shared success policy for observation result consumers.
public enum ObservationActionResultSemantics {
    public static func requirePublishableOutcome(
        _ outcome: DesktopActionOutcome?,
        targetIdentity: DesktopTargetIdentity?,
        operation: String,
        requiresOutcome: Bool) throws
    {
        try self.requirePublishableOutcome(
            outcome,
            targetReceipt: self.targetReceipt(targetIdentity),
            operation: operation,
            requiresOutcome: requiresOutcome)
    }

    public static func requirePublishableOutcome(
        _ outcome: DesktopActionOutcome?,
        targetReceipt: DesktopActionTargetReceipt?,
        operation: String,
        requiresOutcome: Bool) throws
    {
        guard let outcome else {
            guard requiresOutcome else { return }
            throw DesktopActionFailure.indeterminate(
                evidence: .completionUnknown,
                message: "\(operation) returned without its required canonical observation outcome.",
                hint: "Observe the target before retrying and update the runtime host.")
                .attributed(to: targetReceipt)
        }
        guard !outcome.isAccepted(by: .confirmedOrDispatched) else { return }
        guard
            let failure = DesktopActionFailure(
                outcome: outcome,
                message: "\(operation) did not return a publishable observation outcome.",
                hint: "Follow the canonical escalation metadata before deciding whether to retry.",
                targetReceipt: targetReceipt)
        else {
            preconditionFailure("A non-success observation outcome must construct a failure")
        }
        throw failure
    }

    public static func coalescedTarget(
        actionTarget: DesktopTargetIdentity?,
        payload: DesktopObservationResult,
        outcome: DesktopActionOutcome?,
        operation: String,
        requiresTarget: Bool) throws -> DesktopTargetIdentity?
    {
        try self.coalescedTarget(
            actionTarget: actionTarget,
            payloadEvidence: self.targetEvidence(payload),
            outcome: outcome,
            operation: operation,
            requiresTarget: requiresTarget)
    }

    public static func preservingFailure(
        _ error: any Error,
        after result: UIAutomationActionResult<some Sendable>,
        operation: String) -> any Error
    {
        self.preservingFailure(
            error,
            after: result.outcome,
            targetReceipt: self.targetReceipt(result.targetIdentity),
            selectedLeafEvidence: result.selectedLeafEvidence,
            operation: operation)
    }

    public static func preservingFailure(
        _ error: any Error,
        after outcome: DesktopActionOutcome?,
        targetIdentity: DesktopTargetIdentity?,
        operation: String) -> any Error
    {
        self.preservingFailure(
            error,
            after: outcome,
            targetReceipt: self.targetReceipt(targetIdentity),
            selectedLeafEvidence: nil,
            operation: operation)
    }

    public static func preservingFailure(
        _ error: any Error,
        after outcome: DesktopActionOutcome?,
        targetReceipt: DesktopActionTargetReceipt?,
        operation: String) -> any Error
    {
        self.preservingFailure(
            error,
            after: outcome,
            targetReceipt: targetReceipt,
            selectedLeafEvidence: nil,
            operation: operation)
    }

    private static func preservingFailure(
        _ error: any Error,
        after outcome: DesktopActionOutcome?,
        targetReceipt: DesktopActionTargetReceipt?,
        selectedLeafEvidence: [DesktopSelectedLeafEvidence]?,
        operation: String) -> any Error
    {
        guard let outcome else { return error }
        if let failure = error as? DesktopActionFailure {
            var sequence = UIAutomationActionResultSequenceAccumulator()
            sequence.record(
                outcome: outcome,
                targetReceipt: targetReceipt,
                selectedLeafEvidence: selectedLeafEvidence,
                attribution: .operationTarget)
            return sequence.failure(
                combining: failure,
                operation: operation,
                message: failure.message,
                hint: failure.hint ?? "Observe the target before retrying \(operation).",
                causeDescription: failure.causeDescription)
        }

        var validation = UIAutomationActionResultSequenceAccumulator()
        validation.record(
            outcome: outcome,
            targetReceipt: targetReceipt,
            selectedLeafEvidence: selectedLeafEvidence,
            attribution: .operationTarget)
        let validationResolution = validation.resolution
        let validatedSelectedLeafEvidence = validationResolution.hasInvalidSelectedLeafEvidence
            ? nil
            : validationResolution.selectedLeafEvidence

        let message = error.localizedDescription
        let hint = "Observe the target before retrying \(operation)."
        let causeDescription = String(describing: error)
        if let failure = DesktopActionFailure(
            outcome: outcome,
            message: message,
            hint: hint,
            causeDescription: causeDescription,
            targetReceipt: targetReceipt)
        {
            return failure.selectingLeaves(validatedSelectedLeafEvidence)
        }
        switch outcome.state {
        case .confirmedChange:
            return DesktopActionFailure.indeterminate(
                route: outcome.route,
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: message,
                hint: hint,
                causeDescription: causeDescription)
                .attributed(to: targetReceipt)
                .selectingLeaves(validatedSelectedLeafEvidence)
        case .confirmedNoChange:
            return DesktopActionFailure.preDispatchRefusal(
                route: outcome.route,
                reason: .targetUnavailable,
                message: message,
                hint: hint,
                causeDescription: causeDescription)
                .attributed(to: targetReceipt)
        case .partial, .dispatchedUnverified, .suspectedNoop, .refused, .indeterminate:
            preconditionFailure("A non-confirmed outcome must construct a desktop action failure")
        }
    }

    public static func coalescedTarget(
        actionTarget: DesktopTargetIdentity?,
        payload: ElementDetectionResult,
        outcome: DesktopActionOutcome?,
        operation: String,
        requiresTarget: Bool) throws -> DesktopTargetIdentity?
    {
        try self.coalescedTarget(
            actionTarget: actionTarget,
            payloadEvidence: self.targetEvidence(payload.metadata.windowContext),
            outcome: outcome,
            operation: operation,
            requiresTarget: requiresTarget)
    }

    public static func targetReceipt(_ identity: DesktopTargetIdentity?)
        -> DesktopActionTargetReceipt?
    {
        identity?.actionTargetReceipt
    }

    private static func coalescedTarget(
        actionTarget: DesktopTargetIdentity?,
        payloadEvidence: [DesktopTargetIdentity.Evidence],
        outcome: DesktopActionOutcome?,
        operation: String,
        requiresTarget: Bool) throws -> DesktopTargetIdentity?
    {
        let evidence = actionTarget.map { [DesktopTargetIdentity.Evidence(target: $0)] } ?? []
        let target: DesktopTargetIdentity?
        do {
            target = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve(
                evidence + payloadEvidence)
        } catch {
            throw self.targetFailure(outcome: outcome, operation: operation, cause: error)
        }
        guard !requiresTarget || target != nil else {
            throw self.targetFailure(
                outcome: outcome,
                operation: operation,
                cause: DesktopTargetIdentityError.missingProcessGeneration)
        }
        return target
    }

    private static func targetEvidence(_ result: DesktopObservationResult) -> [DesktopTargetIdentity
        .Evidence]
    {
        if let mutationTarget = result.target.mutationTargetIdentity {
            return [DesktopTargetEvidenceAdapter.evidence(
                processIdentity: mutationTarget.processIdentity,
                windowIdentity: mutationTarget.windowIdentity,
                windowBounds: mutationTarget.windowBounds)]
        }
        var evidence: [DesktopTargetIdentity.Evidence] = []
        if let application = self.targetEvidence(result.target.app) {
            evidence.append(application)
        }
        evidence.append(contentsOf: self.targetEvidence(result.target.detectionContext))
        if let application = self.targetEvidence(result.capture.metadata.applicationInfo) {
            evidence.append(application)
        }
        if let window = result.capture.metadata.windowInfo.flatMap(self.targetEvidence) {
            evidence.append(window)
        }
        evidence.append(contentsOf: self.targetEvidence(result.elements?.metadata.windowContext))
        return evidence
    }

    private static func targetEvidence(_ application: ApplicationIdentity?) -> DesktopTargetIdentity
        .Evidence?
    {
        guard let application,
              application.processStartIdentity != nil
        else { return nil }
        return DesktopTargetEvidenceAdapter.evidence(application: application)
    }

    private static func targetEvidence(_ application: ServiceApplicationInfo?)
        -> DesktopTargetIdentity.Evidence?
    {
        guard let application,
              application.processIdentity != nil
        else { return nil }
        return DesktopTargetEvidenceAdapter.evidence(application: application)
    }

    private static func targetEvidence(_ window: ServiceWindowInfo) -> DesktopTargetIdentity.Evidence? {
        guard let identity = window.mutationIdentity else { return nil }
        return DesktopTargetEvidenceAdapter.evidence(
            windowIdentity: identity,
            bounds: window.bounds)
    }

    private static func targetEvidence(_ context: WindowContext?) -> [DesktopTargetIdentity.Evidence] {
        guard let context,
              let identity = context.windowMutationIdentity,
              let bounds = context.windowBounds
        else { return [] }
        return [
            DesktopTargetEvidenceAdapter.evidence(
                windowIdentity: identity,
                bounds: bounds,
                focusedElement: context.focusedElement),
        ]
    }

    private static func targetFailure(
        outcome: DesktopActionOutcome?,
        operation: String,
        cause: any Error) -> DesktopActionFailure
    {
        if let outcome, outcome.dispatchState.mutationDispatched {
            return .indeterminate(
                route: outcome.route,
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "\(operation) returned contradictory or missing stable target evidence.",
                hint: "Observe the intended target before retrying and update the runtime host.",
                causeDescription: cause.localizedDescription)
        }
        return .preDispatchRefusal(
            route: outcome?.route ?? .local,
            reason: .targetUnavailable,
            message: "\(operation) returned contradictory or missing stable target evidence.",
            hint: "Refresh the target before retrying and update the runtime host.",
            causeDescription: cause.localizedDescription)
    }
}

@MainActor
public final class DesktopObservationService: DesktopObservationActionResultProviding {
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
        exactWindowMetadataProvider: any ExactWindowMetadataProviding =
            SystemExactWindowMetadataProvider(),
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
        try await self.observeActionResult(request).payload
    }

    public func observeActionResult(
        _ request: DesktopObservationRequest) async throws -> UIAutomationActionResult<DesktopObservationResult>
    {
        let actionProgress = DesktopObservationActionProgressContext.current ?? DesktopObservationActionProgress()
        let operation: @MainActor @Sendable () async throws -> UIAutomationActionResult<DesktopObservationResult> = {
            try await self.observeWithinOverallDeadline(request)
        }
        do {
            return try await DesktopObservationActionProgressContext.$current.withValue(actionProgress) {
                guard let overallTimeout = request.timeout.overall else {
                    return try await operation()
                }
                return try await ElementDetectionTimeoutRunner.run(
                    seconds: overallTimeout,
                    operation: operation)
            }
        } catch {
            throw Self.failurePreservingConditionalTimeout(
                error,
                request: request,
                progress: actionProgress.latestReceipt)
        }
    }

    private func observeWithinOverallDeadline(
        _ request: DesktopObservationRequest) async throws -> UIAutomationActionResult<DesktopObservationResult>
    {
        try DesktopObservationROIProcessor.validateRequest(request.capture.roi, target: request.target)
        let tracer = DesktopObservationTraceRecorder()
        let observeStart = ContinuousClock.now
        let serializesDetection =
            request.detection.mode != .none && request.detection.allowWebFocusFallback

        let coordinatedCapture:
            @MainActor @Sendable (DesktopObservationLanePlan?) async throws
            -> (
                DesktopStateSnapshot,
                UIAutomationActionResult<ResolvedObservationTarget>,
                CaptureResult,
                UIAutomationActionResult<ElementDetectionResult>?) = { lanePlan in
                try await self.coordinatedCapture(
                    request: request,
                    tracer: tracer,
                    serializesDetection: serializesDetection,
                    lanePlan: lanePlan)
            }
        let (stateSnapshot, captureResolution, capture, serializedDetection) =
            try await self.withPassiveCaptureReceiptRecovery(
                for: request)
            {
                try await self.withDesktopOperationLane(
                    for: request,
                    operation: coordinatedCapture)
            }
        let target = captureResolution.payload
        do {
            // Web-focus fallback can AXPress hidden web content, so keep that mutating detection atomic with capture.
            // Read-only AX traversal and OCR can be slow without touching ScreenCaptureKit; let unrelated captures run.
            let detection =
                if serializesDetection {
                    serializedDetection?.payload
                } else {
                    try await self.detectIfNeeded(
                        capture: capture,
                        target: target,
                        request: request,
                        tracer: tracer)?.payload
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
            let evidenceError = DesktopObservationEvidencePolicy.accessibilityEvidenceError(
                roiResult.elements,
                target: target,
                capture: roiResult.capture,
                request: request)
            var outputOptions = request.output
            if evidenceError != nil {
                // Preserve the valid raster for callers that requested it, but never publish an unusable element map.
                outputOptions.saveRawScreenshot =
                    outputOptions.saveRawScreenshot || outputOptions.saveAnnotatedScreenshot
                        || outputOptions.saveSnapshot
                outputOptions.saveSnapshot = false
            }
            let files = try await self.writeOutputIfNeeded(
                capture: roiResult.capture,
                elements: roiResult.elements,
                options: outputOptions,
                tracer: tracer)
            try Task.checkCancellation()
            if let evidenceError {
                throw evidenceError
            }
            tracer.record("desktop.observe", start: observeStart)

            var warnings = roiResult.capture.warning.map { [$0] } ?? []
            warnings.append(contentsOf: roiResult.ocr?.warnings ?? [])
            warnings.append(contentsOf: roiResult.elements?.metadata.warnings ?? [])
            warnings = warnings.reduce(into: []) { unique, warning in
                if !unique.contains(warning) {
                    unique.append(warning)
                }
            }

            let result = try DesktopObservationResult(
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
                .attestingCaptureContent()
            return UIAutomationActionResult(
                payload: result,
                outcome: captureResolution.outcome,
                targetIdentity: captureResolution.targetIdentity,
                selectedLeafEvidence: captureResolution.selectedLeafEvidence)
        } catch {
            throw Self.failurePreservingResolution(error, resolution: captureResolution)
        }
    }

    private func coordinatedCapture(
        request: DesktopObservationRequest,
        tracer: DesktopObservationTraceRecorder,
        serializesDetection: Bool,
        lanePlan: DesktopObservationLanePlan?) async throws -> (
        DesktopStateSnapshot,
        UIAutomationActionResult<ResolvedObservationTarget>,
        CaptureResult,
        UIAutomationActionResult<ElementDetectionResult>?)
    {
        try await self.withCaptureTransaction {
            let stateSnapshot = try await tracer.span("state.snapshot") {
                try await self.stateSnapshotProvider.snapshot(for: request.target)
            }

            let rawResolution = try await tracer.span("target.resolve") {
                try await self.targetResolver.resolveActionResult(request.target, snapshot: stateSnapshot)
            }
            let resolution = Self.resolutionActionContext(rawResolution, request: request)
            let target = resolution.payload
            try self.validateResolvedTarget(target, for: lanePlan)
            try Self.validatePreCaptureObservationTarget(target)
            let foregroundCaptureFailureResolution = try Self.composingForegroundCapture(
                with: resolution,
                target: target,
                request: request,
                requireCompatibleTarget: false)
            DesktopObservationActionProgressContext.record(foregroundCaptureFailureResolution)
            let captureSpanName = "capture.\(Self.captureSpanName(for: target.kind))"
            let rawCapture: CaptureResult
            do {
                rawCapture = try await tracer.span(captureSpanName) {
                    try await self.capture(
                        target,
                        requestedTarget: request.target,
                        options: request.capture,
                        snapshot: stateSnapshot)
                }
                tracer.annotateLastSpan(
                    named: captureSpanName,
                    metadata: rawCapture.metadata.diagnostics?.observationSpanMetadata ?? [:])
                try Self.validateCaptureReceipt(rawCapture, for: target)
                try self.validateCurrentLaneIdentity(lanePlan)
            } catch {
                throw Self.failurePreservingResolution(
                    error,
                    resolution: foregroundCaptureFailureResolution)
            }
            let capture = Self.normalize(capture: rawCapture, for: target)
            let captureBoundTarget = Self.bindingCaptureReceipt(to: target, capture: capture)
            let captureBoundResolution = UIAutomationActionResult(
                payload: captureBoundTarget,
                outcome: resolution.outcome,
                targetIdentity: resolution.targetIdentity,
                selectedLeafEvidence: resolution.selectedLeafEvidence)
            let captureResolution = try Self.composingForegroundCapture(
                with: captureBoundResolution,
                target: captureBoundTarget,
                request: request,
                requireCompatibleTarget: true)
            let potentialWebFocusResolution = try Self.composingPotentialWebFocus(
                with: captureResolution,
                target: captureBoundTarget,
                request: request)
            DesktopObservationActionProgressContext.record(potentialWebFocusResolution)
            let detection: UIAutomationActionResult<ElementDetectionResult>?
            do {
                detection = if serializesDetection {
                    try await self.detectIfNeeded(
                        capture: capture,
                        target: captureBoundTarget,
                        request: request,
                        tracer: tracer)
                } else {
                    nil
                }
            } catch let failure as DesktopActionFailure {
                let projected = Self.projectingPipelineFailure(
                    failure,
                    request: request,
                    fallbackTarget: Self.observationTargetIdentity(captureBoundTarget))
                throw Self.failurePreservingResolution(
                    projected,
                    resolution: captureResolution)
            } catch {
                throw Self.failurePreservingResolution(
                    error,
                    resolution: potentialWebFocusResolution)
            }
            let finalResolution = try Self.composingDetection(
                detection,
                with: captureResolution,
                target: captureBoundTarget,
                request: request)
            DesktopObservationActionProgressContext.record(finalResolution)
            return (stateSnapshot, finalResolution, capture, detection)
        }
    }

    private static func failurePreservingConditionalTimeout(
        _ error: any Error,
        request: DesktopObservationRequest,
        progress: DesktopObservationActionProgressReceipt?) -> any Error
    {
        guard let captureError = error as? CaptureError,
              case .detectionTimedOut = captureError,
              let conditionalDelivery = observationMutationDelivery(for: request)
        else { return error }

        let mayOpenMenuBarPopover = if case let .menubarPopover(_, openIfNeeded) = request.target {
            openIfNeeded != nil
        } else {
            false
        }
        if progress == nil, request.capture.focus == .background, !mayOpenMenuBarPopover {
            return error
        }
        if let progress, !progress.outcome.dispatchState.mutationDispatched {
            return error
        }

        let outcome = progress?.outcome
        let failure = DesktopActionFailure.indeterminate(
            route: outcome?.route ?? .local,
            delivery: outcome?.delivery ?? conditionalDelivery,
            evidence: .completionUnknown,
            unitCount: outcome?.dispatchState.unitCount ?? .one,
            message: "Desktop observation timed out after a conditional mutation may have been dispatched.",
            hint: "Observe the exact target before deciding whether to retry this observation.",
            causeDescription: error.localizedDescription)
            .attributed(to: progress?.targetReceipt)
        return failure.selectingLeaves(progress?.selectedLeafEvidence)
    }

    private static func resolutionActionContext(
        _ resolution: UIAutomationActionResult<ResolvedObservationTarget>,
        request: DesktopObservationRequest) -> UIAutomationActionResult<ResolvedObservationTarget>
    {
        guard resolution.outcome == nil else { return resolution }
        if case let .menubarPopover(_, openIfNeeded) = request.target,
           openIfNeeded != nil
        {
            return UIAutomationActionResult(
                payload: resolution.payload,
                outcome: .confirmedNoChange())
        }
        return resolution
    }

    private static func composingForegroundCapture(
        with resolution: UIAutomationActionResult<ResolvedObservationTarget>,
        target: ResolvedObservationTarget,
        request: DesktopObservationRequest,
        requireCompatibleTarget: Bool) throws -> UIAutomationActionResult<ResolvedObservationTarget>
    {
        guard request.capture.focus != .background else { return resolution }
        let capture = UIAutomationActionResult(
            payload: (),
            outcome: DesktopActionOutcome.dispatchedUnverified(
                delivery: self.pipelineDelivery(for: request),
                evidence: .deliveryAccepted,
                unitCount: .one),
            targetIdentity: self.observationTargetIdentity(target))
        return try self.composingAction(
            capture,
            with: resolution,
            operation: "foreground observation capture",
            requireCompatibleTarget: requireCompatibleTarget)
    }

    private static func composingPotentialWebFocus(
        with resolution: UIAutomationActionResult<ResolvedObservationTarget>,
        target: ResolvedObservationTarget,
        request: DesktopObservationRequest) throws -> UIAutomationActionResult<ResolvedObservationTarget>
    {
        guard request.capture.focus == .background,
              request.detection.mode != .none,
              request.detection.allowWebFocusFallback
        else { return resolution }
        let webFocus = UIAutomationActionResult(
            payload: (),
            outcome: DesktopActionOutcome.dispatchedUnverified(
                delivery: self.pipelineDelivery(for: request),
                evidence: .deliveryAccepted,
                unitCount: .one),
            targetIdentity: self.observationTargetIdentity(target))
        return try self.composingAction(
            webFocus,
            with: resolution,
            operation: "potential web-focus detection",
            requireCompatibleTarget: false)
    }

    private static func composingDetection(
        _ detection: UIAutomationActionResult<ElementDetectionResult>?,
        with resolution: UIAutomationActionResult<ResolvedObservationTarget>,
        target: ResolvedObservationTarget,
        request: DesktopObservationRequest) throws -> UIAutomationActionResult<ResolvedObservationTarget>
    {
        guard let detection, let outcome = detection.outcome else {
            guard !request.detection.allowWebFocusFallback else {
                throw self.failurePreservingResolution(
                    DesktopActionFailure.indeterminate(
                        delivery: self.pipelineDelivery(for: request),
                        evidence: .completionUnknown,
                        message: "Web-focus detection returned without its required mutation outcome.",
                        hint: "Observe the target before retrying and update the automation service."),
                    resolution: resolution)
            }
            return resolution
        }
        let expectedTarget = self.observationTargetIdentity(target)
        let projectedOutcome = self.pipelineOutcome(outcome, request: request)
        let actionTarget: DesktopTargetIdentity?
        do {
            let candidate = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.coalesce([
                expectedTarget,
                detection.targetIdentity,
            ])
            actionTarget = try ObservationActionResultSemantics.coalescedTarget(
                actionTarget: candidate,
                payload: detection.payload,
                outcome: projectedOutcome,
                operation: "web-focus detection",
                requiresTarget: expectedTarget != nil)
        } catch {
            throw self.failurePreservingResolution(
                self.incompatiblePipelineFailure(
                    outcome: projectedOutcome,
                    selectedLeafEvidence: detection.selectedLeafEvidence,
                    operation: "web-focus detection",
                    cause: error),
                resolution: resolution)
        }
        let projected = UIAutomationActionResult(
            payload: detection.payload,
            outcome: projectedOutcome,
            targetIdentity: actionTarget,
            selectedLeafEvidence: detection.selectedLeafEvidence)
        return try self.composingAction(
            projected,
            with: resolution,
            operation: "web-focus detection",
            requireCompatibleTarget: true)
    }

    private static func composingAction(
        _ action: UIAutomationActionResult<some Sendable>,
        with resolution: UIAutomationActionResult<ResolvedObservationTarget>,
        operation: String,
        requireCompatibleTarget: Bool) throws -> UIAutomationActionResult<ResolvedObservationTarget>
    {
        guard let actionOutcome = action.outcome else { return resolution }
        var sequence = UIAutomationActionResultSequenceAccumulator()
        sequence.record(resolution, attribution: .mutationTarget)
        sequence.record(action, attribution: .mutationTarget)
        let sequenceResolution = sequence.resolution
        let fallbackOutcome = DesktopActionOutcome.indeterminate(
            route: actionOutcome.route,
            delivery: nil,
            evidence: .completionUnknown,
            unitCount: sequenceResolution.mutationDisposition.unitCount)
        return try sequence.result(
            payload: resolution.payload,
            fallbackOutcome: fallbackOutcome,
            operation: operation,
            requiresOutcome: true,
            requiresCompatibleTarget: requireCompatibleTarget,
            failureMessage: "Desktop observation could not safely compose its setup and \(operation) targets.",
            failureHint: "Observe both targets before retrying this observation.")
    }

    private static func incompatiblePipelineFailure(
        outcome: DesktopActionOutcome,
        selectedLeafEvidence: [DesktopSelectedLeafEvidence]?,
        operation: String,
        cause: any Error) -> DesktopActionFailure
    {
        let failure = DesktopActionFailure(
            outcome: outcome,
            message: "Desktop observation could not safely compose its setup and \(operation) targets.",
            hint: "Observe both targets before retrying this observation.",
            causeDescription: cause.localizedDescription) ?? .indeterminate(
            route: outcome.route,
            delivery: outcome.delivery,
            evidence: .completionUnknown,
            unitCount: outcome.dispatchState.unitCount,
            message: "Desktop observation could not safely compose its setup and \(operation) targets.",
            hint: "Observe both targets before retrying this observation.",
            causeDescription: cause.localizedDescription)
        return failure.selectingLeaves(selectedLeafEvidence)
    }

    private static func observationTargetIdentity(
        _ target: ResolvedObservationTarget) -> DesktopTargetIdentity?
    {
        if let identity = target.detectionContext?.windowMutationIdentity,
           let bounds = target.detectionContext?.windowBounds,
           identity.capturedBounds == bounds
        {
            guard let exactWindow = try? UIAutomationTarget.ExactWindow(
                identity: identity,
                bounds: bounds)
            else { return nil }
            return DesktopTargetIdentity(exactWindow: exactWindow)
        }
        guard let application = target.app,
              let processStartIdentity = application.processStartIdentity
        else { return nil }
        return try? DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: application.processIdentifier,
            processStartIdentity: processStartIdentity))
    }

    private static func pipelineDelivery(
        for request: DesktopObservationRequest) -> DesktopActionOutcome.Delivery
    {
        .init(
            mechanism: .capturePipeline,
            mode: request.capture.focus == .background ? .background : .foreground)
    }

    private static func pipelineOutcome(
        _ outcome: DesktopActionOutcome,
        request: DesktopObservationRequest) -> DesktopActionOutcome
    {
        let delivery = self.pipelineDelivery(for: request)
        switch outcome.state {
        case .confirmedChange:
            return .confirmedChange(
                route: outcome.route,
                delivery: delivery,
                unitCount: outcome.dispatchState.unitCount)
        case .confirmedNoChange:
            return .confirmedNoChange(route: outcome.route)
        case .partial:
            return .partial(
                route: outcome.route,
                delivery: delivery,
                unitCount: outcome.dispatchState.unitCount)
        case .dispatchedUnverified:
            return .dispatchedUnverified(
                route: outcome.route,
                delivery: delivery,
                evidence: outcome.evidence == .operationStillRunning ? .operationStillRunning : .deliveryAccepted,
                unitCount: outcome.dispatchState.unitCount)
        case .suspectedNoop:
            return .suspectedNoop(
                route: outcome.route,
                delivery: delivery,
                unitCount: outcome.dispatchState.unitCount)
        case .refused:
            return .refused(
                route: outcome.route,
                reason: outcome.refusalReason ?? .operationUnsupported)
        case .indeterminate:
            return .indeterminate(
                route: outcome.route,
                delivery: outcome.delivery == nil ? nil : delivery,
                evidence: outcome.evidence == .responseLost ? .responseLost : .completionUnknown,
                unitCount: outcome.dispatchState.unitCount)
        }
    }

    private static func projectingPipelineFailure(
        _ error: any Error,
        request: DesktopObservationRequest,
        fallbackTarget: DesktopTargetIdentity?) -> any Error
    {
        guard let failure = error as? DesktopActionFailure else {
            guard request.detection.mode != .none,
                  request.detection.allowWebFocusFallback
            else { return error }
            return DesktopActionFailure.indeterminate(
                delivery: self.pipelineDelivery(for: request),
                evidence: .completionUnknown,
                message: "Web-focus detection failed after mutation dispatch became possible.",
                hint: "Observe the target before retrying with web focus enabled.",
                causeDescription: error.localizedDescription)
                .attributed(to: fallbackTarget?.actionTargetReceipt)
        }
        let outcome = self.pipelineOutcome(failure.outcome, request: request)
        guard let projected = DesktopActionFailure(
            outcome: outcome,
            message: failure.message,
            hint: failure.hint,
            causeDescription: failure.causeDescription,
            targetReceipt: failure.targetReceipt ?? fallbackTarget?.actionTargetReceipt,
            selectedLeafEvidence: failure.selectedLeafEvidence)
        else { return error }
        return projected
    }

    private static func validatePreCaptureObservationTarget(_ target: ResolvedObservationTarget) throws {
        guard case .menubarPopover = target.kind, target.window != nil else { return }
        guard let identity = target.detectionContext?.windowMutationIdentity,
              let application = target.app,
              application.processIdentifier == identity.ownerProcessIdentifier,
              application.processStartIdentity == identity.ownerProcessStartIdentity,
              target.window?.windowID == identity.windowID,
              target.window?.bounds == identity.capturedBounds
        else {
            throw DesktopObservationError.targetChanged(
                "the window-backed menu-bar popover had no exact pre-capture owner-generation receipt")
        }
    }

    private static func failurePreservingResolution(
        _ error: any Error,
        resolution: UIAutomationActionResult<ResolvedObservationTarget>) -> any Error
    {
        ObservationActionResultSemantics.preservingFailure(
            error,
            after: resolution,
            operation: "desktop observation")
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

extension CaptureDiagnostics {
    fileprivate var observationSpanMetadata: [String: String] {
        var metadata: [String: String] = [:]
        if let engine {
            metadata["engine"] = engine
        }
        if let fallbackReason {
            metadata["fallback_reason"] = fallbackReason
        }
        if let windowPlanCacheStatus {
            metadata["window_plan_cache"] = windowPlanCacheStatus.rawValue
        }
        if let windowPlanCacheGeneration {
            metadata["window_plan_cache_generation"] = String(windowPlanCacheGeneration)
        }
        return metadata
    }
}
