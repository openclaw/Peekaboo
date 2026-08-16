import CoreGraphics
import Foundation
import ImageIO
import MCP
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import UniformTypeIdentifiers

struct ImageCaptureSet {
    let captures: [CaptureResult]
    let actionResult: UIAutomationActionResult<DesktopObservationResult>

    var observation: DesktopObservationResult {
        self.actionResult.payload
    }
}

private struct ImageCaptureFocusSetup {
    let result: UIAutomationActionResult<Void>
    let processIdentity: ApplicationProcessIdentity
}

extension ImageTool {
    func captureImages(for request: ImageRequest, outputPath: String? = nil) async throws -> ImageCaptureSet {
        let result = try await self.captureObservation(for: request, outputPath: outputPath)
        return ImageCaptureSet(captures: [result.payload.capture], actionResult: result)
    }

    func captureObservation(
        for request: ImageRequest,
        outputPath: String? = nil) async throws -> UIAutomationActionResult<DesktopObservationResult>
    {
        var sequence = DesktopActionSequenceAccumulator()
        let focusSetup = try await self.prepareCaptureFocus(for: request)
        if let outcome = focusSetup?.result.outcome {
            sequence.record(.reportedOutcome(outcome, defaultDispatchedUnitCount: .one))
        }
        let activationTarget = focusSetup?.result.targetIdentity
        let activatedIdentity = focusSetup?.processIdentity

        let result: UIAutomationActionResult<DesktopObservationResult>
        do {
            result = try await self.context.desktopObservation.observeResult(DesktopObservationRequest(
                target: request.observationTarget(pinnedTo: activatedIdentity),
                capture: DesktopCaptureOptions(
                    scale: request.scale,
                    focus: request.captureFocus,
                    visualizerMode: .resolved(for: request.captureFocus, visibleMode: .screenshotFlash)),
                detection: DesktopDetectionOptions(mode: .none),
                output: DesktopObservationOutputOptions(
                    path: outputPath,
                    format: request.format.imageFormat,
                    saveRawScreenshot: outputPath != nil)))
        } catch {
            let presentedError: any Error = if request.captureFocus != .background,
                                               !(error is DesktopActionFailure)
            {
                DesktopActionFailure.indeterminate(
                    route: .local,
                    delivery: .init(mechanism: .capturePipeline, mode: .foreground),
                    evidence: .completionUnknown,
                    unitCount: .one,
                    message: "Visible image capture failed without a canonical action result.",
                    hint: "Observe the target before retrying image capture.",
                    causeDescription: error.localizedDescription)
            } else {
                error
            }
            throw Self.failure(
                preserving: presentedError,
                after: sequence,
                targetIdentity: activationTarget)
        }

        let observationTarget: DesktopTargetIdentity?
        do {
            observationTarget = try ObservationActionResultSemantics.coalescedTarget(
                actionTarget: result.targetIdentity,
                payload: result.payload,
                outcome: result.outcome,
                operation: "Image capture",
                requiresTarget: request.requiresExactWindowTarget)
        } catch {
            throw Self.failure(
                preserving: error,
                after: sequence,
                targetIdentity: activationTarget)
        }

        let observationOutcome: DesktopActionOutcome?
        do {
            observationOutcome = try Self.requireCanonicalObservationOutcome(
                result.outcome,
                captureFocus: request.captureFocus,
                targetReceipt: ObservationActionResultSemantics.targetReceipt(observationTarget))
        } catch {
            throw Self.failure(
                preserving: error,
                after: sequence,
                targetIdentity: activationTarget)
        }
        if let observationOutcome {
            sequence.record(.reportedOutcome(observationOutcome, defaultDispatchedUnitCount: .one))
        }
        let resolution = sequence.successResolution()
        guard !resolution.mutationDispatched || resolution.outcome != nil else {
            let failure = DesktopActionFailure.indeterminate(
                route: .local,
                evidence: .completionUnknown,
                unitCount: resolution.mutationDisposition.unitCount,
                message: "Image capture could not compose its dispatched action results.",
                hint: "Observe the target before retrying and update the runtime host.")
            throw failure.attributed(to: ObservationActionResultSemantics.targetReceipt(
                observationTarget ?? activationTarget))
        }

        let targetIdentity: DesktopTargetIdentity?
        do {
            targetIdentity = try Self.coalescedTarget(
                request: request,
                activationTarget: activationTarget,
                observationTarget: observationTarget,
                aggregateOutcome: resolution.outcome)
        } catch {
            throw error
        }
        return UIAutomationActionResult(
            payload: result.payload,
            outcome: resolution.outcome,
            targetIdentity: targetIdentity)
    }

    private func prepareCaptureFocus(for request: ImageRequest) async throws -> ImageCaptureFocusSetup? {
        guard request.captureFocus != .background else { return nil }
        if let windowID = request.exactWindowID {
            return try await self.focusExactWindow(windowID)
        }
        guard let identifier = request.focusIdentifier else { return nil }
        return try await self.activateApplication(identifier)
    }

    private func focusExactWindow(_ windowID: Int) async throws -> ImageCaptureFocusSetup {
        let windows = try await self.context.windows.listWindows(target: .windowId(windowID))
        let window = try ExactWindowSelectorResolver.select(
            from: windows,
            selection: .id(windowID),
            operation: "Image foreground capture")
        guard let identity = window.mutationIdentity,
              identity.windowID == window.windowID,
              identity.capturedBounds == window.bounds,
              let bounds = identity.capturedBounds
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Image foreground capture requires a stable exact-window receipt.",
                hint: "Refresh the window inventory before retrying.")
        }
        let expectedTarget = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds))
        let rawResult: UIAutomationActionResult<Void>
        do {
            rawResult = try await self.context.windows.focusWindowResult(
                target: .windowId(windowID),
                expectedIdentity: identity)
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch {
            throw DesktopActionFailure.indeterminate(
                route: .local,
                delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Exact-window focus failed without a canonical action result.",
                hint: "Observe the exact window before retrying image capture.",
                causeDescription: error.localizedDescription)
                .attributed(to: expectedTarget.actionTargetReceipt)
        }
        let result = try self.context.windows.validatedWindowMutationResult(
            rawResult,
            expectedIdentity: identity,
            operation: "Image foreground capture focus")
        try await Self.settleAfterFocus(result, operation: "exact-window image focus")
        return ImageCaptureFocusSetup(result: result, processIdentity: identity.processIdentity)
    }

    private func activateApplication(_ identifier: String) async throws -> ImageCaptureFocusSetup {
        let application = try await self.context.applications.findApplication(identifier: identifier)
        let activationRequest = try ApplicationActivationRequest(application: application)
        guard let expectedIdentity = activationRequest.expectedIdentity else {
            throw PeekabooError.serviceUnavailable(
                "Image target activation did not retain its process-generation identity")
        }
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: expectedIdentity.processIdentifier,
            processStartIdentity: expectedIdentity.processStartIdentity)
        let result: UIAutomationActionResult<Void>
        do {
            result = try await self.context.applications.activateApplicationTargetedResult(
                request: activationRequest)
        } catch let failure as DesktopActionFailure {
            throw failure.attributed(to: receipt)
        } catch {
            throw DesktopActionFailure.indeterminate(
                route: .local,
                delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Image target activation failed without a canonical action result.",
                hint: "Observe the target before retrying image capture.",
                causeDescription: error.localizedDescription)
                .attributed(to: receipt)
        }
        do {
            try ApplicationActionResultSemantics.requireSuccessfulExactProcessResult(
                result,
                expectedIdentity: expectedIdentity,
                operation: "Image target activation")
        } catch let failure as DesktopActionFailure {
            guard result.targetIdentity?.processIdentity == expectedIdentity else { throw failure }
            throw failure.attributed(to: receipt)
        }
        _ = try Self.requireCanonicalActivationOutcome(result.outcome, target: expectedIdentity)
        try await Self.settleAfterFocus(result, operation: "image target activation")
        return ImageCaptureFocusSetup(result: result, processIdentity: expectedIdentity)
    }

    static func settleAfterFocus(
        _ result: UIAutomationActionResult<Void>,
        operation: String) async throws
    {
        do {
            try await Task.sleep(nanoseconds: 50_000_000)
        } catch {
            throw ObservationActionResultSupport.preservingFailure(
                error,
                after: result,
                operation: "\(operation) settle")
        }
    }

    func savedFiles(for captureSet: ImageCaptureSet, request: ImageRequest) throws -> [MCPSavedFile] {
        if request.path == nil, request.format == .data {
            return []
        }
        guard let result = captureSet.captures.first else { return [] }
        guard let path = captureSet.observation.files.rawScreenshotPath else {
            if request.outputPath != nil || request.format == .data {
                throw OperationError.captureFailed(reason: "Observation completed without a saved screenshot path")
            }
            return []
        }

        return [
            MCPSavedFile(
                path: path,
                item_label: describeCapture(result.metadata),
                window_title: result.metadata.windowInfo?.title,
                window_id: result.metadata.windowInfo.map { String($0.windowID) },
                window_index: result.metadata.windowInfo?.index,
                mime_type: request.format.mimeType),
        ]
    }

    func stagingOutputPathIfNeeded(for request: ImageRequest, callerOutputPath: String?) -> String? {
        guard callerOutputPath != nil || request.format == .data else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-\(UUID().uuidString).\(request.format.fileExtension)")
            .path
    }

    func rebindingProcessedCaptureSet(
        _ captureSet: ImageCaptureSet,
        rawPath: String?,
        readFromRawPath: Bool = true) throws -> ImageCaptureSet
    {
        guard captureSet.captures.count == 1, let capture = captureSet.captures.first else {
            throw OperationError.captureFailed(reason: "Image processing requires exactly one capture")
        }
        let data: Data = if readFromRawPath, let rawPath {
            try Data(contentsOf: URL(fileURLWithPath: rawPath))
        } else if !capture.imageData.isEmpty {
            capture.imageData
        } else {
            Data()
        }
        guard !data.isEmpty else {
            throw OperationError.captureFailed(reason: Self.emptyFinalImageReason)
        }
        let updatedCapture = CaptureResult(
            imageData: data,
            savedPath: rawPath,
            metadata: capture.metadata,
            warning: capture.warning)
        let observation = captureSet.observation
        let updatedObservation = DesktopObservationResult(
            target: observation.target,
            capture: updatedCapture,
            elements: observation.elements,
            ocr: observation.ocr,
            files: DesktopObservationFiles(
                rawScreenshotPath: rawPath,
                annotatedScreenshotPath: nil,
                publishedSnapshotID: observation.files.publishedSnapshotID),
            timings: observation.timings,
            diagnostics: observation.diagnostics)
            .withCaptureContentDigest(
                rawScreenshotData: rawPath == nil ? nil : data,
                annotatedScreenshotData: nil)
        return ImageCaptureSet(
            captures: [updatedCapture],
            actionResult: UIAutomationActionResult(
                payload: updatedObservation,
                outcome: captureSet.actionResult.outcome,
                targetIdentity: captureSet.actionResult.targetIdentity))
    }

    func captureSet(_ captureSet: ImageCaptureSet, publishingAt path: String?) throws -> ImageCaptureSet {
        guard let path else { return captureSet }
        return try self.rebindingProcessedCaptureSet(
            captureSet,
            rawPath: path,
            readFromRawPath: false)
    }

    func publishCapture(_ captureSet: ImageCaptureSet, to path: String) throws {
        guard captureSet.captures.count == 1,
              let data = captureSet.captures.first?.imageData,
              !data.isEmpty
        else {
            throw OperationError.captureFailed(reason: "Image publication has no final image bytes")
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func downscaledCaptureSetIfNeeded(_ captureSet: ImageCaptureSet, request: ImageRequest) throws -> ImageCaptureSet {
        guard let maxDimension = request.effectiveMaxDimension else {
            return captureSet
        }

        var downscaledCaptures: [CaptureResult] = []
        downscaledCaptures.reserveCapacity(captureSet.captures.count)

        for capture in captureSet.captures {
            let savedPath = capture.savedPath ?? captureSet.observation.files.rawScreenshotPath
            let imageData = if capture.imageData.isEmpty, let savedPath {
                (try? Data(contentsOf: URL(fileURLWithPath: savedPath))) ?? capture.imageData
            } else {
                capture.imageData
            }

            guard !imageData.isEmpty else {
                downscaledCaptures.append(capture)
                continue
            }

            guard let result = self.downscale(
                imageData: imageData,
                maxDimension: maxDimension,
                format: request.format)
            else {
                throw OperationError.captureFailed(
                    reason: "Failed to downscale image to max_dimension \(maxDimension)")
            }

            if result.resized, let savedPath {
                try result.data.write(to: URL(fileURLWithPath: savedPath), options: .atomic)
            }

            downscaledCaptures.append(CaptureResult(
                imageData: result.data,
                savedPath: capture.savedPath,
                metadata: capture.metadata.withDeliveredPixelSize(result.size),
                warning: capture.warning))
        }

        return ImageCaptureSet(captures: downscaledCaptures, actionResult: captureSet.actionResult)
    }

    func buildCaptureResponse(
        format: ImageFormatOption,
        savedFiles: [MCPSavedFile],
        captureResults: [CaptureResult],
        actionResult: UIAutomationActionResult<DesktopObservationResult>) throws -> ToolResponse
    {
        var metadata: [String: Value] = [
            "savedFiles": .array(savedFiles.map { Value.string($0.path) }),
            "mutation_dispatched": .bool(false),
            "retry_safe": .bool(true),
        ]
        if let firstCapture = captureResults.first {
            metadata["coordinate_context"] = CaptureCoordinateContextMetadata.value(for: firstCapture.metadata)
        }
        let diagnosticsMeta = ObservationDiagnosticsMetadata.merge(actionResult.payload, into: .object(metadata))
        let diagnosticFields = diagnosticsMeta.objectValue ?? metadata
        let baseMeta = try ObservationActionResultSupport.metadata(
            merging: diagnosticFields,
            result: actionResult) ?? diagnosticsMeta
        let captureNote: String = if savedFiles.isEmpty {
            "Captured image"
        } else if savedFiles.count == 1, let label = savedFiles.first?.item_label {
            label
        } else {
            "Captured \(savedFiles.count) images"
        }
        let summary = ToolEventSummary(
            actionDescription: "Image Capture",
            notes: captureNote)
        let meta = ToolEventSummary.merge(summary: summary, into: baseMeta)

        if format == .data, let capture = captureResults.first, captureResults.count == 1 {
            let data = if capture.imageData.isEmpty, let path = savedFiles.first?.path {
                (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? capture.imageData
            } else {
                capture.imageData
            }
            if data.isEmpty {
                return ToolResponse.error(
                    "Capture produced no image data and no saved file could be read",
                    meta: meta)
            }
            return ToolResponse.image(data: data, mimeType: "image/png", meta: meta)
        }

        return ToolResponse.text(
            buildImageSummary(savedFiles: savedFiles, captureCount: captureResults.count),
            meta: meta)
    }

    private static func requireCanonicalActivationOutcome(
        _ outcome: DesktopActionOutcome?,
        target: ApplicationProcessIdentity) throws -> DesktopActionOutcome
    {
        let expectedDelivery = DesktopActionOutcome.Delivery(
            mechanism: .nativeFramework,
            mode: .foreground)
        guard let outcome,
              (outcome.state == .confirmedNoChange && outcome.dispatchState == .none && outcome.delivery == nil) ||
              ([.confirmedChange, .dispatchedUnverified].contains(outcome.state) &&
                  outcome.delivery == expectedDelivery &&
                  outcome.dispatchState.unitCount == .one)
        else {
            throw self.invalidMutationResult(
                outcome,
                expectedDelivery: expectedDelivery,
                message: "Image target activation returned incomplete or contradictory action semantics.")
                .attributed(to: DesktopActionTargetReceipt(
                    processIdentifier: target.processIdentifier,
                    processStartIdentity: target.processStartIdentity))
        }
        return outcome
    }

    private static func requireCanonicalObservationOutcome(
        _ outcome: DesktopActionOutcome?,
        captureFocus: CaptureFocus,
        targetReceipt: DesktopActionTargetReceipt?) throws -> DesktopActionOutcome?
    {
        if captureFocus == .background {
            if let outcome {
                try ObservationActionResultSemantics.requirePublishableOutcome(
                    outcome,
                    targetReceipt: targetReceipt,
                    operation: "Image capture",
                    requiresOutcome: false)
                guard !outcome.dispatchState.mutationDispatched else {
                    throw self.invalidMutationResult(
                        outcome,
                        expectedDelivery: nil,
                        message: "Background image capture reported a desktop mutation.")
                        .attributed(to: targetReceipt)
                }
            }
            return outcome
        }

        let expectedDelivery = DesktopActionOutcome.Delivery(
            mechanism: .capturePipeline,
            mode: .foreground)
        guard let outcome else {
            throw self.invalidMutationResult(
                nil,
                expectedDelivery: expectedDelivery,
                message: "Visible image capture returned without canonical action semantics.")
                .attributed(to: targetReceipt)
        }
        try ObservationActionResultSemantics.requirePublishableOutcome(
            outcome,
            targetReceipt: targetReceipt,
            operation: "Image capture",
            requiresOutcome: true)
        guard [.confirmedChange, .dispatchedUnverified].contains(outcome.state),
              outcome.delivery == expectedDelivery,
              outcome.dispatchState.unitCount == .one
        else {
            throw self.invalidMutationResult(
                outcome,
                expectedDelivery: expectedDelivery,
                message: "Visible image capture returned incomplete or contradictory action semantics.")
                .attributed(to: targetReceipt)
        }
        return outcome
    }

    private static func coalescedTarget(
        request: ImageRequest,
        activationTarget: DesktopTargetIdentity?,
        observationTarget: DesktopTargetIdentity?,
        aggregateOutcome: DesktopActionOutcome?) throws -> DesktopTargetIdentity?
    {
        guard request.requiresExactWindowTarget else { return nil }
        let combinedTarget: DesktopTargetIdentity?
        do {
            let evidence = [activationTarget, observationTarget]
                .compactMap(\.self)
                .map { DesktopTargetIdentity.Evidence(target: $0) }
            combinedTarget = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve(evidence)
        } catch {
            throw self.targetFailure(outcome: aggregateOutcome, cause: error)
        }
        guard let combinedTarget, combinedTarget.exactWindow != nil else {
            throw self.targetFailure(
                outcome: aggregateOutcome,
                cause: DesktopTargetIdentityError.incompleteExactWindow)
        }
        return combinedTarget
    }

    private static func failure(
        preserving error: any Error,
        after sequence: DesktopActionSequenceAccumulator,
        targetIdentity: DesktopTargetIdentity?) -> any Error
    {
        let resolution = sequence.successResolution()
        let result = UIAutomationActionResult(
            payload: (),
            outcome: resolution.outcome,
            targetIdentity: targetIdentity)
        return ObservationActionResultSupport.preservingFailure(
            error,
            after: result,
            operation: "image")
    }

    private static func invalidMutationResult(
        _ outcome: DesktopActionOutcome?,
        expectedDelivery: DesktopActionOutcome.Delivery?,
        message: String) -> DesktopActionFailure
    {
        if let outcome, outcome.dispatchState.mutationDispatched {
            return .indeterminate(
                route: outcome.route,
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: message,
                hint: "Observe the target before retrying and update the runtime host.")
        }
        return .indeterminate(
            route: outcome?.route ?? .local,
            delivery: expectedDelivery,
            evidence: .completionUnknown,
            unitCount: expectedDelivery == nil ? nil : .one,
            message: message,
            hint: "Observe the target before retrying and update the runtime host.")
    }

    private static func targetFailure(
        outcome: DesktopActionOutcome?,
        cause: any Error) -> DesktopActionFailure
    {
        if let outcome, outcome.dispatchState.mutationDispatched {
            return .indeterminate(
                route: outcome.route,
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "Image capture returned contradictory or missing exact-window target evidence.",
                hint: "Observe the intended target before retrying and update the runtime host.",
                causeDescription: cause.localizedDescription)
        }
        return .preDispatchRefusal(
            route: outcome?.route ?? .local,
            reason: .targetUnavailable,
            message: "Image capture returned contradictory or missing exact-window target evidence.",
            hint: "Refresh the target before retrying and update the runtime host.",
            causeDescription: cause.localizedDescription)
    }

    private func encode(cgImage: CGImage, format: ImageFormatOption) -> Data? {
        let data = NSMutableData()
        let uti: CFString = switch format {
        case .png, .data: UTType.png.identifier as CFString
        case .jpg: UTType.jpeg.identifier as CFString
        }
        guard let destination = CGImageDestinationCreateWithData(
            data,
            uti,
            1,
            nil)
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    func downscale(
        imageData: Data,
        maxDimension: Int,
        format: ImageFormatOption) -> (data: Data, resized: Bool, size: CGSize)?
    {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else {
            return nil
        }

        let longest = max(width, height)
        guard longest > CGFloat(maxDimension) else {
            return (imageData, false, CGSize(width: width, height: height))
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        guard let encodedData = self.encode(cgImage: thumbnail, format: format) else {
            return nil
        }

        return (
            encodedData,
            true,
            CGSize(width: thumbnail.width, height: thumbnail.height))
    }
}
