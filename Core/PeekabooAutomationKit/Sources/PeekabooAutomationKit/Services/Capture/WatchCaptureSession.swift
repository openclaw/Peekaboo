import CoreGraphics
import Foundation
import PeekabooFoundation

public struct WatchCaptureDependencies {
    public let screenCapture: any ScreenCaptureServiceProtocol
    public let screenService: (any ScreenServiceProtocol)?
    public let frameSource: (any CaptureFrameSource)?
    public let clock: any WatchCaptureMonotonicClock

    public init(
        screenCapture: any ScreenCaptureServiceProtocol,
        screenService: (any ScreenServiceProtocol)? = nil,
        frameSource: (any CaptureFrameSource)? = nil,
        clock: any WatchCaptureMonotonicClock = SystemWatchCaptureMonotonicClock())
    {
        self.screenCapture = screenCapture
        self.screenService = screenService
        self.frameSource = frameSource
        self.clock = clock
    }
}

public struct WatchAutocleanConfig {
    public let minutes: Int
    public let managed: Bool

    public init(minutes: Int, managed: Bool) {
        self.minutes = minutes
        self.managed = managed
    }
}

public struct WatchCaptureConfiguration {
    public let scope: CaptureScope
    public let options: CaptureOptions
    public let outputRoot: URL
    public let autoclean: WatchAutocleanConfig
    public let sourceKind: CaptureSessionResult.Source
    public let videoIn: String?
    public let videoOut: String?
    public let keepAllFrames: Bool
    public let videoOptions: CaptureVideoOptionsSnapshot?

    public init(
        scope: CaptureScope,
        options: CaptureOptions,
        outputRoot: URL,
        autoclean: WatchAutocleanConfig,
        sourceKind: CaptureSessionResult.Source = .live,
        videoIn: String? = nil,
        videoOut: String? = nil,
        keepAllFrames: Bool = false,
        videoOptions: CaptureVideoOptionsSnapshot? = nil)
    {
        self.scope = scope
        self.options = options
        self.outputRoot = outputRoot
        self.autoclean = autoclean
        self.sourceKind = sourceKind
        self.videoIn = videoIn
        self.videoOut = videoOut
        self.keepAllFrames = keepAllFrames
        self.videoOptions = videoOptions
    }
}

private final class WatchCaptureStopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    func request() {
        self.lock.lock()
        guard !self.requested else {
            self.lock.unlock()
            return
        }
        self.requested = true
        let continuations = self.continuations.values
        self.continuations.removeAll()
        self.lock.unlock()

        for continuation in continuations {
            continuation.resume()
        }
    }

    func isRequested() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.requested
    }

    func wait() async {
        if self.isRequested() {
            return
        }

        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResume: Bool
                self.lock.lock()
                if self.requested || Task.isCancelled {
                    shouldResume = true
                } else {
                    shouldResume = false
                    self.continuations[id] = continuation
                }
                self.lock.unlock()

                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.cancelWait(id)
        }
    }

    private func cancelWait(_ id: UUID) {
        self.lock.lock()
        let continuation = self.continuations.removeValue(forKey: id)
        self.lock.unlock()
        continuation?.resume()
    }
}

/// Adaptive PNG capture session for agents.
@MainActor
public final class WatchCaptureSession {
    private var retiringCaptureTasks: [UUID: Task<CaptureAttemptCompletion, Never>] = [:]

    var retiringCaptureTaskCount: Int {
        self.retiringCaptureTasks.count
    }

    enum Constants {
        static let diffScaleWidth: CGFloat = 256
        static let motionDelta: UInt8 = 18 // luma delta threshold (0-255)
        static let contactMaxColumns = 6
        static let contactThumb: CGFloat = 200
    }

    let frameProvider: WatchCaptureFrameProvider
    let scope: CaptureScope
    let options: CaptureOptions
    let outputRoot: URL
    let store: WatchCaptureSessionStore
    let frameSource: (any CaptureFrameSource)?
    let sourceKind: CaptureSessionResult.Source
    let videoIn: String?
    let videoOut: String?
    let keepAllFrames: Bool
    let videoOptions: CaptureVideoOptionsSnapshot?
    let clock: any WatchCaptureMonotonicClock
    let videoWriterFPS: Double?
    let sessionId = UUID().uuidString
    var videoWriter: VideoWriter?

    var frames: [CaptureFrameInfo] = []
    var warnings: [CaptureWarning] = []
    var framesDropped: Int = 0
    var frameAttempts: Int = 0
    var totalBytes: Int = 0
    var lastCaptureErrorDescription: String?
    public private(set) var samplingEndedAtMonotonicNanoseconds: UInt64?
    private let stopSignal = WatchCaptureStopSignal()

    public init(dependencies: WatchCaptureDependencies, configuration: WatchCaptureConfiguration) {
        let regionValidator = WatchCaptureRegionValidator(screenService: dependencies.screenService)
        self.frameSource = dependencies.frameSource
        self.scope = configuration.scope
        self.options = configuration.options
        self.outputRoot = configuration.outputRoot
        self.store = WatchCaptureSessionStore(
            outputRoot: configuration.outputRoot,
            autocleanMinutes: configuration.autoclean.minutes,
            managedAutoclean: configuration.autoclean.managed,
            sessionId: self.sessionId)
        self.sourceKind = configuration.sourceKind
        self.videoIn = configuration.videoIn
        self.videoOut = configuration.videoOut
        self.keepAllFrames = configuration.keepAllFrames
        self.videoOptions = configuration.videoOptions
        self.clock = dependencies.clock
        if let videoSource = dependencies.frameSource as? VideoFrameSource {
            self.videoWriterFPS = videoSource.effectiveFPS
        } else {
            self.videoWriterFPS = configuration.options.activeFps
        }
        self.frameProvider = WatchCaptureFrameProvider(
            screenCapture: dependencies.screenCapture,
            frameSource: dependencies.frameSource,
            scope: configuration.scope,
            options: configuration.options,
            regionValidator: regionValidator)
    }

    public func run() async throws -> CaptureSessionResult {
        do {
            // Validate public API options before creating or cleaning any artifacts.
            let validatedTiming = try self.validateTiming()
            try self.store.prepareOutputRoot()
            if let autocleanWarning = self.store.performAutoclean() {
                self.warnings.append(autocleanWarning)
            }
            // videoWriter is created lazily on first saved frame to match actual dimensions.

            let timing = self.makeTiming(from: validatedTiming)
            let sampling = try await self.captureFrames(timing: timing)
            self.samplingEndedAtMonotonicNanoseconds = self.clock.nowNanoseconds()
            try Task.checkCancellation()

            let sourceDiagnostics = self.captureSourceDiagnostics
            guard !self.frames.isEmpty else {
                throw CaptureNoValidFramesError(
                    source: self.sourceKind,
                    framesDropped: self.framesDropped,
                    decodeFailures: sourceDiagnostics.decodeFailures,
                    firstDecodeError: sourceDiagnostics.firstDecodeError,
                    lastDecodeError: sourceDiagnostics.lastDecodeError,
                    lastCaptureError: self.lastCaptureErrorDescription)
            }

            let videoArtifactCustody: CaptureVideoArtifactCustody? = if let writer = self.videoWriter {
                try await writer.finish()
            } else {
                nil
            }

            let contact = try WatchCaptureArtifactWriter.buildContactSheet(
                frames: self.frames,
                outputRoot: self.outputRoot,
                columns: Constants.contactMaxColumns,
                thumbSize: CGSize(width: Constants.contactThumb, height: Constants.contactThumb))
            let totalDurationMs = Int(Self.elapsedNanoseconds(
                since: timing.monotonicStartNs,
                now: self.clock.nowNanoseconds()) / 1_000_000)
            let metadataURL = self.outputRoot.appendingPathComponent("metadata.json")
            let metadata = WatchCaptureResultBuilder(
                sourceKind: self.sourceKind,
                videoIn: self.videoIn,
                videoOut: self.videoWriter?.finalURL.path,
                videoArtifactCustody: videoArtifactCustody,
                scope: self.scope,
                options: self.options,
                videoOptions: self.videoOptions,
                diffScale: "w\(Int(Constants.diffScaleWidth))")
                .build(.init(
                    frames: self.frames,
                    contactSheet: contact,
                    metadataURL: metadataURL,
                    totalDurationMs: totalDurationMs,
                    sampling: sampling,
                    returnedFrameAttempts: self.frameAttempts,
                    totalBytes: self.totalBytes,
                    warnings: self.warnings,
                    sourceDiagnostics: sourceDiagnostics))

            try self.store.writeJSON(metadata, to: metadataURL)
            try await Self.performFinalArtifactValidation {
                try CaptureArtifactIntegrityValidator.validate(metadata)
            }
            return metadata
        } catch {
            let primaryError = error
            if let videoWriter = self.videoWriter {
                do {
                    try videoWriter.abortAndRemovePartialOutput()
                } catch {
                    self.videoWriter = nil
                    throw CaptureArtifactCleanupError(
                        primaryError: primaryError,
                        cleanupError: error,
                        artifactPath: videoWriter.finalURL.path)
                }
            }
            self.videoWriter = nil
            throw primaryError
        }
    }

    nonisolated static func performFinalArtifactValidation(
        _ operation: @escaping @Sendable () throws -> Void) async throws
    {
        let validationTask = Task.detached(priority: .utility) {
            try operation()
        }
        try await withTaskCancellationHandler {
            try await validationTask.value
        } onCancel: {
            validationTask.cancel()
        }
        try Task.checkCancellation()
    }

    public func requestStop() {
        self.stopSignal.request()
    }

    func hasStopRequest() -> Bool {
        self.stopSignal.isRequested()
    }

    func waitForStopRequest() async {
        await self.stopSignal.wait()
    }

    func requireNoRetiringCaptureTask() throws {
        guard self.retiringCaptureTasks.isEmpty else {
            throw PeekabooError.captureFailed(
                reason: "A previous capture request is still retiring after cancellation")
        }
    }

    func retireCaptureTask(_ task: Task<CaptureAttemptCompletion, Never>) {
        let identifier = UUID()
        self.retiringCaptureTasks[identifier] = task
        Task { @MainActor in
            _ = await task.value
            self.retiringCaptureTasks.removeValue(forKey: identifier)
        }
    }

    var captureSourceDiagnostics: CaptureFrameSourceDiagnostics {
        (self.frameSource as? any CaptureFrameSourceDiagnosticsProviding)?.captureDiagnostics ??
            CaptureFrameSourceDiagnostics()
    }
}
