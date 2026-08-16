import Foundation
import ImageIO
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

enum RemoteDesktopObservationCapabilityPolicy {
    /// `preferOCR` predates the additive enum case and remains compatible with older hosts.
    static func requiresOCRCapability(_ request: DesktopObservationRequest) -> Bool {
        request.detection.mode == .accessibilityAndOCR
    }

    static func ocrUnavailableError() -> PeekabooBridgeErrorEnvelope {
        PeekabooBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: """
            Remote Bridge host does not advertise desktopObservationOCR. Update and relaunch Peekaboo on that host, \
            or use --no-remote to explicitly run Vision OCR in the caller process.
            """)
    }

    static func requiresCaptureEnginePreferenceCapability(_ request: DesktopObservationRequest)
        -> Bool
    {
        request.capture.engine != .auto
    }

    static func captureEnginePreferenceUnavailableError() -> PeekabooBridgeErrorEnvelope {
        PeekabooBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: """
            Remote Bridge host does not advertise desktopObservationCaptureEngine. Update and relaunch Peekaboo on \
            that host, or use --no-remote to explicitly run the selected capture engine in the caller process.
            """)
    }
}

@MainActor
public final class RemoteDesktopObservationService: DesktopObservationActionResultProviding {
    private let client: PeekabooBridgeClient
    private let supportsDesktopObservationOCR: Bool
    private let supportsDesktopObservationCaptureEngine: Bool
    private let supportsExactWindowROIObservation: Bool
    private let artifactInstallationPreflight: @MainActor @Sendable () throws -> Void

    public convenience init(
        client: PeekabooBridgeClient,
        supportsDesktopObservationOCR: Bool = false,
        supportsDesktopObservationCaptureEngine: Bool = false,
        supportsExactWindowROIObservation: Bool = false)
    {
        self.init(
            client: client,
            supportsDesktopObservationOCR: supportsDesktopObservationOCR,
            supportsDesktopObservationCaptureEngine: supportsDesktopObservationCaptureEngine,
            supportsExactWindowROIObservation: supportsExactWindowROIObservation,
            artifactInstallationPreflight: {})
    }

    package init(
        client: PeekabooBridgeClient,
        supportsDesktopObservationOCR: Bool = false,
        supportsDesktopObservationCaptureEngine: Bool = false,
        supportsExactWindowROIObservation: Bool,
        artifactInstallationPreflight: @escaping @MainActor @Sendable () throws -> Void)
    {
        self.client = client
        self.supportsDesktopObservationOCR = supportsDesktopObservationOCR
        self.supportsDesktopObservationCaptureEngine = supportsDesktopObservationCaptureEngine
        self.supportsExactWindowROIObservation = supportsExactWindowROIObservation
        self.artifactInstallationPreflight = artifactInstallationPreflight
    }

    public func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        try await self.observeActionResult(request).payload
    }

    public func observeActionResult(
        _ request: DesktopObservationRequest) async throws -> UIAutomationActionResult<DesktopObservationResult>
    {
        guard
            !RemoteDesktopObservationCapabilityPolicy.requiresOCRCapability(request)
            || self.supportsDesktopObservationOCR
        else {
            throw RemoteDesktopObservationCapabilityPolicy.ocrUnavailableError()
        }
        guard
            !RemoteDesktopObservationCapabilityPolicy.requiresCaptureEnginePreferenceCapability(request)
            || self.supportsDesktopObservationCaptureEngine
        else {
            throw RemoteDesktopObservationCapabilityPolicy.captureEnginePreferenceUnavailableError()
        }
        guard request.capture.roi != nil else {
            let actionResult = try await self.client.desktopObservationWithOutcome(request)
            do {
                if actionResult.payload.files.rawScreenshotPath != nil {
                    _ = try actionResult.payload.verifiedRawScreenshotData()
                }
                if actionResult.payload.files.annotatedScreenshotPath != nil {
                    _ = try actionResult.payload.verifiedAnnotatedScreenshotData()
                }
                try DesktopObservationEvidencePolicy.requireUsableAccessibilityEvidence(
                    actionResult.payload.elements,
                    target: actionResult.payload.target,
                    capture: actionResult.payload.capture,
                    request: request)
                return actionResult
            } catch {
                throw Self.failurePreservingOutcome(error, from: actionResult)
            }
        }
        guard self.supportsExactWindowROIObservation else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge host lacks protocol 1.21 exact-window ROI observation support")
        }
        let overallTimeout = request.timeout.overall
        let deadline = try Self.postProcessingDeadline(timeout: overallTimeout)
        try Self.checkPostProcessingAllowance(deadline: deadline, timeout: overallTimeout)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-remote-roi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let quarantinePath =
            directory
                .appendingPathComponent("capture.\(request.output.format.rawValue)")
                .path
        var remoteRequest = request
        remoteRequest.output.path = quarantinePath
        // The client owns ROI validation and publication. Force one quarantined raster for proof,
        // and defer snapshot publication until the receipt and every requested artifact pass.
        remoteRequest.output.saveRawScreenshot = true
        remoteRequest.output.saveSnapshot = false

        let remoteResult: UIAutomationActionResult<DesktopObservationResult>
        do {
            remoteResult = try await self.client.desktopObservationWithOutcome(remoteRequest)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            if let context = envelope.context,
               context.hasPrefix("capture_roi:"),
               let error = CaptureROIError(code: String(context.dropFirst("capture_roi:".count)))
            {
                throw error
            }
            throw envelope
        }
        do {
            let result = remoteResult.payload
            let evidenceError = DesktopObservationEvidencePolicy.accessibilityEvidenceError(
                result.elements,
                target: result.target,
                capture: result.capture,
                request: request)
            try DesktopObservationROIProcessor.validateApplied(
                request.capture.roi,
                requestTarget: request.target,
                resolvedTarget: result.target,
                capture: result.capture)
            try Self.checkPostProcessingAllowance(deadline: deadline, timeout: overallTimeout)
            let prepared = try self.prepareROIResult(
                result,
                request: request,
                quarantinePath: quarantinePath,
                deadline: deadline,
                timeout: overallTimeout)
            let stagedArtifacts = try Self.stageArtifacts(
                prepared.artifacts,
                deadline: deadline,
                timeout: overallTimeout)
            defer { Self.discardStagedArtifacts(stagedArtifacts) }
            try Self.checkPostProcessingAllowance(deadline: deadline, timeout: overallTimeout)
            let commitTask = Task { @MainActor in
                if evidenceError == nil {
                    try await self.storeSnapshotIfNeeded(
                        prepared,
                        request: request,
                        deadline: deadline,
                        timeout: overallTimeout)
                }
                let installedArtifacts: [ArtifactPublication]
                try self.artifactInstallationPreflight()
                do {
                    installedArtifacts = try Self.installArtifacts(stagedArtifacts)
                } catch is ArtifactPublicationError {
                    if let evidenceError {
                        throw evidenceError
                    }
                    guard request.output.saveSnapshot else {
                        throw CaptureROIError.invalidSourceImage
                    }
                    return Self.snapshotOnlyResult(prepared.result)
                }
                Self.finalizeArtifacts(installedArtifacts)
                if let evidenceError {
                    throw evidenceError
                }
                return prepared.result
            }
            return try await UIAutomationActionResult(
                payload: commitTask.value,
                outcome: remoteResult.outcome,
                targetIdentity: remoteResult.targetIdentity)
        } catch {
            throw Self.failurePreservingOutcome(error, from: remoteResult)
        }
    }

    static func failurePreservingOutcome(
        _ error: any Error,
        from result: UIAutomationActionResult<some Sendable>) -> any Error
    {
        ObservationActionResultSemantics.preservingFailure(
            error,
            after: result.outcome,
            targetIdentity: result.targetIdentity,
            operation: "remote desktop observation post-processing")
    }

    private struct PreparedROIResult {
        let result: DesktopObservationResult
        let artifacts: [(data: Data, path: String)]
        let quarantineRawPath: String
        let quarantineAnnotatedPath: String?
    }

    private func prepareROIResult(
        _ result: DesktopObservationResult,
        request: DesktopObservationRequest,
        quarantinePath: String,
        deadline: ContinuousClock.Instant?,
        timeout: TimeInterval?) throws -> PreparedROIResult
    {
        try Self.checkPostProcessingAllowance(deadline: deadline, timeout: timeout)
        guard Self.sameFile(result.files.rawScreenshotPath, quarantinePath) else {
            throw CaptureROIError.hostDidNotApplyROI
        }
        let rawData = try Self.validatedRasterData(
            result.verifiedRawScreenshotData(),
            expectedPixelSize: result.capture.metadata.size)
        try Self.checkPostProcessingAllowance(deadline: deadline, timeout: timeout)
        let expectsRawArtifact =
            request.output.saveRawScreenshot || request.output.saveAnnotatedScreenshot
                || request.output.saveSnapshot
        let outputBasePath =
            expectsRawArtifact
                ? ObservationOutputPathResolver.resolve(
                    path: request.output.path,
                    format: request.output.format,
                    defaultFileName: "peekaboo-roi-\(UUID().uuidString).\(request.output.format.rawValue)")
                .standardizedFileURL
                .path
                : nil
        let rawPath = request.output.saveRawScreenshot ? outputBasePath : nil

        var annotatedPath: String?
        var annotatedData: Data?
        var quarantineAnnotatedPath: String?
        if request.output.saveAnnotatedScreenshot {
            guard let outputBasePath else {
                throw CaptureROIError.hostDidNotApplyROI
            }
            annotatedPath = ObservationOutputWriter.annotatedScreenshotPath(forRawScreenshotPath: outputBasePath)
            quarantineAnnotatedPath = ObservationOutputWriter.annotatedScreenshotPath(
                forRawScreenshotPath: quarantinePath)
            guard let quarantineAnnotatedPath,
                  Self.sameFile(result.files.annotatedScreenshotPath, quarantineAnnotatedPath)
            else {
                throw CaptureROIError.hostDidNotApplyROI
            }
            annotatedData = try Self.validatedRasterData(
                result.verifiedAnnotatedScreenshotData(),
                expectedPixelSize: result.capture.metadata.size)
            try Self.checkPostProcessingAllowance(deadline: deadline, timeout: timeout)
        }

        var artifacts: [(data: Data, path: String)] = []
        if request.output.saveRawScreenshot, let rawPath {
            artifacts.append((rawData, rawPath))
        }
        if let annotatedPath, let annotatedData {
            artifacts.append((annotatedData, annotatedPath))
        }
        let capture = CaptureResult(
            imageData: rawData,
            savedPath: rawPath,
            metadata: result.capture.metadata,
            warning: result.capture.warning)
        let elements = result.elements.map {
            ElementDetectionResult(
                snapshotId: $0.snapshotId,
                screenshotPath: rawPath ?? "",
                elements: $0.elements,
                metadata: $0.metadata)
        }
        let preparedResult = DesktopObservationResult(
            target: result.target,
            capture: capture,
            elements: elements,
            ocr: result.ocr,
            files: DesktopObservationFiles(
                rawScreenshotPath: rawPath,
                annotatedScreenshotPath: annotatedPath),
            timings: result.timings,
            diagnostics: result.diagnostics)
            .withCaptureContentDigest(
                rawScreenshotData: rawData,
                annotatedScreenshotData: annotatedData)
        return PreparedROIResult(
            result: preparedResult,
            artifacts: artifacts,
            quarantineRawPath: quarantinePath,
            quarantineAnnotatedPath: quarantineAnnotatedPath)
    }

    private func storeSnapshotIfNeeded(
        _ prepared: PreparedROIResult,
        request: DesktopObservationRequest,
        deadline: ContinuousClock.Instant?,
        timeout: TimeInterval?) async throws
    {
        let result = prepared.result
        guard request.output.saveSnapshot,
              let snapshotID = request.output.snapshotID ?? result.elements?.snapshotId
        else { return }

        try Self.checkPostProcessingAllowance(deadline: deadline, timeout: timeout)
        let windowContext = result.elements?.metadata.windowContext
        let detectionResult = result.elements.map {
            ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: "",
                elements: $0.elements,
                metadata: $0.metadata)
        }
        try await self.client.storeObservationSnapshot(
            SnapshotObservationPublicationRequest(
                screenshot: SnapshotScreenshotRequest(
                    snapshotId: snapshotID,
                    screenshotPath: prepared.quarantineRawPath,
                    applicationBundleId: windowContext?.applicationBundleId
                        ?? result.capture.metadata.applicationInfo?
                        .bundleIdentifier,
                    applicationProcessId: windowContext?.applicationProcessId
                        ?? result.capture.metadata
                        .applicationInfo?
                        .processIdentifier,
                    applicationName: windowContext?.applicationName
                        ?? result.capture.metadata.applicationInfo?.name,
                    windowTitle: windowContext?.windowTitle ?? result.capture.metadata.windowInfo?.title,
                    windowBounds: windowContext?.windowBounds ?? result.capture.metadata.windowInfo?.bounds,
                    windowID: windowContext?.windowID ?? result.capture.metadata.windowInfo?.windowID,
                    windowMutationIdentity: windowContext?.windowMutationIdentity
                        ?? result.capture.metadata.windowInfo?
                        .mutationIdentity,
                    captureCoordinateContext: CaptureCoordinateContext(
                        metadata: result.capture.metadata,
                        referenceID: snapshotID)),
                detectionResult: detectionResult,
                annotatedScreenshotPath: prepared.quarantineAnnotatedPath),
            timeoutSec: Self.remainingPostProcessingTime(deadline: deadline, timeout: timeout))
        try Self.checkPostProcessingAllowance(deadline: deadline, timeout: timeout)
    }

    private static func postProcessingDeadline(
        timeout: TimeInterval?) throws -> ContinuousClock.Instant?
    {
        guard let timeout else { return nil }
        guard timeout.isFinite, timeout > 0 else {
            throw CaptureError.detectionTimedOut(timeout)
        }
        return ContinuousClock.now.advanced(by: .seconds(timeout))
    }

    private static func checkPostProcessingAllowance(
        deadline: ContinuousClock.Instant?,
        timeout: TimeInterval?) throws
    {
        try Task.checkCancellation()
        guard let deadline, ContinuousClock.now >= deadline else { return }
        throw CaptureError.detectionTimedOut(timeout ?? 0)
    }

    private static func remainingPostProcessingTime(
        deadline: ContinuousClock.Instant?,
        timeout: TimeInterval?) throws -> TimeInterval?
    {
        try self.checkPostProcessingAllowance(deadline: deadline, timeout: timeout)
        guard let deadline else { return nil }
        let duration = ContinuousClock.now.duration(to: deadline)
        let components = duration.components
        let seconds =
            Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
        guard seconds > 0 else {
            throw CaptureError.detectionTimedOut(timeout ?? 0)
        }
        return seconds
    }

    private static func sameFile(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        return URL(fileURLWithPath: lhs).standardizedFileURL
            == URL(fileURLWithPath: rhs).standardizedFileURL
    }

    private static func validatedRasterData(_ data: Data, expectedPixelSize: CGSize) throws -> Data {
        guard expectedPixelSize.width.isFinite,
              expectedPixelSize.height.isFinite,
              expectedPixelSize.width > 0,
              expectedPixelSize.height > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              CGFloat(image.width) == expectedPixelSize.width,
              CGFloat(image.height) == expectedPixelSize.height
        else {
            throw CaptureROIError.hostDidNotApplyROI
        }
        return data
    }

    private struct ArtifactPublication {
        let destinationURL: URL
        let stagedURL: URL
        let backupURL: URL
        var backedUp = false
        var installed = false
    }

    private enum ArtifactPublicationError: Error {
        case installFailedAfterRollback
    }

    private static func stageArtifacts(
        _ artifacts: [(data: Data, path: String)],
        deadline: ContinuousClock.Instant?,
        timeout: TimeInterval?) throws -> [ArtifactPublication]
    {
        var publications: [ArtifactPublication] = []
        do {
            for artifact in artifacts {
                try self.checkPostProcessingAllowance(deadline: deadline, timeout: timeout)
                let destinationURL = URL(fileURLWithPath: artifact.path).standardizedFileURL
                let directory = destinationURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                _ = try self.regularFileExists(at: destinationURL)
                let token = UUID().uuidString
                let stagedURL = directory.appendingPathComponent(".peekaboo-stage-\(token)")
                let backupURL = directory.appendingPathComponent(".peekaboo-backup-\(token)")
                try artifact.data.write(to: stagedURL, options: .atomic)
                publications.append(
                    ArtifactPublication(
                        destinationURL: destinationURL,
                        stagedURL: stagedURL,
                        backupURL: backupURL))
            }
            return publications
        } catch {
            for publication in publications {
                try? FileManager.default.removeItem(at: publication.stagedURL)
            }
            if error is CancellationError || error is CaptureError {
                throw error
            }
            throw CaptureROIError.invalidSourceImage
        }
    }

    private static func installArtifacts(_ stagedArtifacts: [ArtifactPublication]) throws
        -> [ArtifactPublication]
    {
        var publications = stagedArtifacts
        do {
            for index in publications.indices {
                if try self.regularFileExists(at: publications[index].destinationURL) {
                    try FileManager.default.moveItem(
                        at: publications[index].destinationURL,
                        to: publications[index].backupURL)
                    publications[index].backedUp = true
                    guard try self.regularFileExists(at: publications[index].backupURL) else {
                        throw CaptureROIError.invalidSourceImage
                    }
                }
                try FileManager.default.moveItem(
                    at: publications[index].stagedURL,
                    to: publications[index].destinationURL)
                publications[index].installed = true
            }

            return publications
        } catch {
            do {
                try self.rollbackArtifacts(publications)
            } catch {
                throw CaptureROIError.invalidSourceImage
            }
            throw ArtifactPublicationError.installFailedAfterRollback
        }
    }

    private static func finalizeArtifacts(_ publications: [ArtifactPublication]) {
        for publication in publications where publication.backedUp {
            try? FileManager.default.removeItem(at: publication.backupURL)
        }
    }

    private static func discardStagedArtifacts(_ publications: [ArtifactPublication]) {
        for publication in publications {
            try? FileManager.default.removeItem(at: publication.stagedURL)
        }
    }

    private static func snapshotOnlyResult(_ result: DesktopObservationResult)
        -> DesktopObservationResult
    {
        let warning =
            "Snapshot publication succeeded, but caller-visible ROI artifacts could not be published"
        var warnings = result.diagnostics.warnings
        if !warnings.contains(warning) {
            warnings.append(warning)
        }
        let capture = CaptureResult(
            imageData: result.capture.imageData,
            savedPath: nil,
            metadata: result.capture.metadata,
            warning: result.capture.warning)
        let elements = result.elements.map {
            ElementDetectionResult(
                snapshotId: $0.snapshotId,
                screenshotPath: "",
                elements: $0.elements,
                metadata: $0.metadata)
        }
        return DesktopObservationResult(
            target: result.target,
            capture: capture,
            elements: elements,
            ocr: result.ocr,
            files: DesktopObservationFiles(),
            timings: result.timings,
            diagnostics: DesktopObservationDiagnostics(
                warnings: warnings,
                stateSnapshot: result.diagnostics.stateSnapshot,
                target: result.diagnostics.target,
                desktopMutationCompletedAt: result.diagnostics.desktopMutationCompletedAt,
                desktopMutationPreservationAllowed: result.diagnostics.desktopMutationPreservationAllowed))
            .withCaptureContentDigest(rawScreenshotData: nil, annotatedScreenshotData: nil)
    }

    private static func rollbackArtifacts(_ publications: [ArtifactPublication]) throws {
        var rollbackError: (any Error)?
        for publication in publications.reversed() {
            do {
                if publication.installed,
                   FileManager.default.fileExists(atPath: publication.destinationURL.path)
                {
                    try FileManager.default.removeItem(at: publication.destinationURL)
                }
                if publication.backedUp {
                    try FileManager.default.moveItem(
                        at: publication.backupURL,
                        to: publication.destinationURL)
                }
                if FileManager.default.fileExists(atPath: publication.stagedURL.path) {
                    try FileManager.default.removeItem(at: publication.stagedURL)
                }
            } catch {
                rollbackError = rollbackError ?? error
            }
        }
        if let rollbackError {
            throw rollbackError
        }
    }

    private static func regularFileExists(at url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CaptureROIError.invalidSourceImage
        }
        return true
    }
}
