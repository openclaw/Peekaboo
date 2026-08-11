import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

struct CaptureRequest {
    let source: CaptureSessionResult.Source
    let scope: CaptureScope
    let options: CaptureOptions
    let outputDirectory: URL
    let autocleanMinutes: Int
    let usesDefaultOutput: Bool
    let frameSource: (any CaptureFrameSource)?
    let keepAllFrames: Bool
    let videoOptions: CaptureVideoOptionsSnapshot?
    let videoIn: String?
    let videoOut: String?

    init(arguments: ToolArguments, windows: any WindowManagementServiceProtocol) async throws {
        let input = try CaptureInput(arguments: arguments)
        self.source = try CaptureToolArgumentResolver.source(from: input.source)

        let constraints = try CaptureRequest.constraints(from: input)
        let outputDir = if let dir = input.outputDir {
            CaptureToolPathResolver.outputDirectory(from: dir)
        } else {
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("peekaboo/capture-sessions/capture-\(UUID().uuidString)", isDirectory: true)
        }
        self.outputDirectory = outputDir
        self.autocleanMinutes = input.autocleanMinutes ?? 120
        self.usesDefaultOutput = input.outputDir == nil
        self.videoOut = CaptureToolPathResolver.filePath(from: input.videoOut)

        switch self.source {
        case .live:
            let scope = try await CaptureRequest.resolveScope(from: input, windows: windows)
            self.scope = scope
            self.frameSource = nil
            self.options = try CaptureRequest.buildLiveOptions(
                from: input,
                constraints: constraints)
            self.keepAllFrames = false
            self.videoOptions = nil
            self.videoIn = nil
        case .video:
            guard let inputPath = input.input else {
                throw PeekabooError.invalidInput("input is required when source=video")
            }
            let videoURL = CaptureToolPathResolver.fileURL(from: inputPath)
            let sampleFps = input.sampleFps
            let everyMs = input.everyMs
            if sampleFps != nil, everyMs != nil {
                throw PeekabooError.invalidInput("sample_fps and every_ms are mutually exclusive")
            }
            let frameSource = try await VideoFrameSource(
                url: videoURL,
                sampleFps: sampleFps,
                everyMs: everyMs,
                startMs: input.startMs,
                endMs: input.endMs,
                resolutionCap: constraints.resolutionCap)
            self.frameSource = frameSource
            self.scope = CaptureScope(kind: .frontmost)
            self.keepAllFrames = input.noDiff ?? false
            self.videoIn = videoURL.path
            self.videoOptions = CaptureVideoOptionsSnapshot(
                sampleFps: everyMs == nil ? sampleFps ?? 2.0 : nil,
                everyMs: everyMs,
                effectiveFps: frameSource.effectiveFPS,
                startMs: input.startMs,
                endMs: input.endMs,
                keepAllFrames: self.keepAllFrames)
            self.options = CaptureRequest.buildVideoOptions(constraints: constraints)
        }
    }
}

private struct CaptureInput: Codable {
    let source: String?
    let mode: String?
    let app: String?
    let pid: Int?
    let windowTitle: String?
    let windowIndex: Int?
    let screenIndex: Int?
    let region: String?
    let captureFocus: String?

    let durationSeconds: Double?
    let idleFps: Double?
    let activeFps: Double?
    let thresholdPercent: Double?
    let heartbeatSec: Double?
    let quietMs: Int?

    let input: String?
    let sampleFps: Double?
    let everyMs: Int?
    let startMs: Int?
    let endMs: Int?
    let noDiff: Bool?

    let highlightChanges: Bool?
    let maxFrames: Int?
    let maxMb: Int?
    let resolutionCap: Double?
    let diffStrategy: String?
    let diffBudgetMs: Int?
    let outputDir: String?
    let autocleanMinutes: Int?
    let videoOut: String?

    init(arguments: ToolArguments) throws {
        let data = try JSONEncoder().encode(arguments.rawValue)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self = try decoder.decode(Self.self, from: data)
    }
}

extension CaptureRequest {
    fileprivate static func constraints(from input: CaptureInput) throws -> CaptureConstraints {
        let diffStrategy = try CaptureToolArgumentResolver.diffStrategy(from: input.diffStrategy)
        return CaptureConstraints(
            highlight: input.highlightChanges ?? false,
            maxFrames: input.maxFrames ?? 800,
            maxMb: input.maxMb,
            resolutionCap: input.resolutionCap ?? 1440,
            diffStrategy: diffStrategy,
            diffBudget: input.diffBudgetMs ?? (diffStrategy == .quality ? 30 : nil))
    }

    fileprivate static func resolveScope(
        from input: CaptureInput,
        windows: any WindowManagementServiceProtocol) async throws -> CaptureScope
    {
        let modeStr = input.mode
        let explicitApp = input.app
        let windowTitle = input.windowTitle
        let windowIndex = input.windowIndex

        let mode = try CaptureToolArgumentResolver.mode(
            from: modeStr,
            hasRegion: input.region != nil,
            hasWindowTarget: explicitApp != nil || input.pid != nil || windowTitle != nil || windowIndex != nil)

        switch mode {
        case .screen:
            let screenIndex = input.screenIndex
            return CaptureScope(
                kind: .screen,
                screenIndex: screenIndex,
                displayUUID: nil,
                windowId: nil,
                applicationIdentifier: nil,
                windowIndex: nil,
                region: nil)
        case .frontmost:
            return CaptureScope(kind: .frontmost)
        case .window:
            return try await CaptureToolWindowResolver.scope(
                app: explicitApp,
                pid: input.pid,
                windowTitle: windowTitle,
                windowIndex: windowIndex,
                windows: windows)
        case .area:
            let region = try CaptureToolArgumentResolver.region(from: input.region)
            return CaptureScope(
                kind: .region,
                region: region)
        case .multi:
            throw PeekabooError.invalidInput("mode multi not supported for capture")
        }
    }

    fileprivate struct CaptureConstraints {
        let highlight: Bool
        let maxFrames: Int
        let maxMb: Int?
        let resolutionCap: CGFloat
        let diffStrategy: CaptureOptions.DiffStrategy
        let diffBudget: Int?
    }

    fileprivate static func buildLiveOptions(
        from input: CaptureInput,
        constraints: CaptureConstraints) throws -> CaptureOptions
    {
        let duration = max(1, min(input.durationSeconds ?? 60, 180))
        let cadence: CaptureCadence
        do {
            cadence = try CaptureCadence.validated(idleFps: input.idleFps, activeFps: input.activeFps)
        } catch let error as CaptureCadenceValidationError {
            throw PeekabooError.invalidInput(error.localizedDescription)
        }
        let threshold = min(max(input.thresholdPercent ?? 2.5, 0), 100)
        let heartbeat = max(input.heartbeatSec ?? 5, 0)
        let quiet = max(input.quietMs ?? 1000, 0)
        let maxFrames = max(constraints.maxFrames, 1)
        let maxMbAdjusted = constraints.maxMb.flatMap { $0 > 0 ? $0 : nil }
        let focus = try CaptureToolArgumentResolver.captureFocus(from: input.captureFocus)

        return CaptureOptions(
            duration: duration,
            idleFps: cadence.idleFps,
            activeFps: cadence.activeFps,
            changeThresholdPercent: threshold,
            heartbeatSeconds: heartbeat,
            quietMsToIdle: quiet,
            maxFrames: maxFrames,
            maxMegabytes: maxMbAdjusted,
            highlightChanges: constraints.highlight,
            captureFocus: focus,
            resolutionCap: constraints.resolutionCap,
            diffStrategy: constraints.diffStrategy,
            diffBudgetMs: constraints.diffBudget)
    }

    fileprivate static func buildVideoOptions(
        constraints: CaptureConstraints) -> CaptureOptions
    {
        let maxFrames = max(constraints.maxFrames, 1)
        let maxMbAdjusted = constraints.maxMb.flatMap { $0 > 0 ? $0 : nil }
        return CaptureOptions(
            duration: 3600,
            idleFps: 60,
            activeFps: 60,
            changeThresholdPercent: 2.5,
            heartbeatSeconds: 5,
            quietMsToIdle: 1000,
            maxFrames: maxFrames,
            maxMegabytes: maxMbAdjusted,
            highlightChanges: constraints.highlight,
            captureFocus: .background,
            resolutionCap: constraints.resolutionCap,
            diffStrategy: constraints.diffStrategy,
            diffBudgetMs: constraints.diffBudget)
    }
}
