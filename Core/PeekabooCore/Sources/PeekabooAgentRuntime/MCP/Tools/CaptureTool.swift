import Foundation
import MCP
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

/// MCP tool for live/video capture (frames + contact sheet).
public struct CaptureTool: MCPTool {
    private let context: MCPToolContext

    public let name = "capture"

    public var description: String {
        """
        Capture live screens/windows/regions or ingest a video file and return kept PNG frames,
        a contact sheet, and metadata (diff stats, warnings, grid info).
        """
    }

    public var inputSchema: Value {
        // Source selection + options split by source
        SchemaBuilder.object(
            properties: [
                "source": SchemaBuilder.string(
                    description: "live|video (default live)",
                    enum: ["live", "video"],
                    default: "live"),

                // Live targeting
                "mode": SchemaBuilder.string(
                    description: "screen|window|frontmost|area (region alias)",
                    enum: ["screen", "window", "frontmost", "area", "region"]),
                "app": SchemaBuilder.string(description: "Optional app/bundle/PID target for window mode"),
                "pid": SchemaBuilder.integer(description: "Optional process ID target for window mode"),
                "window_title": SchemaBuilder.string(description: "Optional window title filter"),
                "window_index": SchemaBuilder.integer(description: "Optional window index; requires app or pid"),
                "screen_index": SchemaBuilder.integer(description: "Optional screen index"),
                "region": SchemaBuilder.string(description: "x,y,width,height for area mode"),
                "capture_focus": SchemaBuilder.string(
                    description: "background (default)|foreground (activate target)|auto (legacy)",
                    enum: ["background", "foreground", "auto"],
                    default: "background"),

                // Live cadence
                "duration_seconds": SchemaBuilder.number(description: "Duration seconds (default 60, max 180)"),
                "idle_fps": SchemaBuilder.number(
                    description: "Idle FPS; must be finite (default 2, range 0.1...5)",
                    minimum: 0.1,
                    maximum: 5,
                    default: 2),
                "active_fps": SchemaBuilder.number(
                    description: "Active FPS; must be finite and >= idle_fps (default 8, range 0.5...15)",
                    minimum: 0.5,
                    maximum: 15,
                    default: 8),
                "threshold_percent": SchemaBuilder.number(
                    description: "Whole-frame change percent to keep motion frames (default 2.5; 0 keeps all)"),
                "heartbeat_sec": SchemaBuilder
                    .number(description: "Heartbeat interval seconds (default 5, 0 disables)"),
                "quiet_ms": SchemaBuilder.integer(description: "Calm period before returning to idle (default 1000)"),

                // Video sampling
                "input": SchemaBuilder.string(description: "Video file path (required for source=video)"),
                "sample_fps": SchemaBuilder.number(description: "Sample FPS (default 2). Exclusive with every_ms."),
                "every_ms": SchemaBuilder.integer(description: "Sample every N ms. Exclusive with sample_fps."),
                "start_ms": SchemaBuilder.integer(description: "Trim start in ms"),
                "end_ms": SchemaBuilder.integer(description: "Trim end in ms"),
                "no_diff": SchemaBuilder.boolean(description: "Keep all sampled frames (disable diff filtering)"),

                // Shared caps/output
                "highlight_changes": SchemaBuilder.boolean(description: "Overlay motion boxes on frames"),
                "max_frames": SchemaBuilder.integer(description: "Soft frame cap (default 800)"),
                "max_mb": SchemaBuilder.integer(description: "Soft size cap MB (optional)"),
                "resolution_cap": SchemaBuilder.number(description: "Cap longest side px (default 1440)"),
                "diff_strategy": SchemaBuilder.string(
                    description: "fast|quality (default fast)",
                    enum: ["fast", "quality"],
                    default: "fast"),
                "diff_budget_ms": SchemaBuilder
                    .integer(description: "Diff time budget ms before falling back to fast (default 30 for quality)"),
                "output_dir": SchemaBuilder.string(description: "Optional absolute directory for outputs"),
                "autoclean_minutes": SchemaBuilder.integer(description: "Minutes to keep temp outputs (default 120)"),
                "video_out": SchemaBuilder.string(description: "Optional MP4 output path"),
            ],
            required: [])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        let focusReceipt = CaptureFocusDispatchReceipt()
        do {
            let request = try await CaptureRequest(arguments: arguments, windows: self.context.windows)
            try await self.prepareCaptureFocus(request, receipt: focusReceipt)
            let targetIdentity = try Self.exactTargetIdentity(for: request.scope)
            let dependencies = WatchCaptureDependencies(
                screenCapture: self.context.screenCapture,
                screenService: self.context.screens,
                frameSource: request.frameSource)
            let configuration = WatchCaptureConfiguration(
                scope: request.scope,
                options: request.options,
                outputRoot: request.outputDirectory,
                autoclean: WatchAutocleanConfig(
                    minutes: request.autocleanMinutes,
                    managed: request.usesDefaultOutput),
                sourceKind: request.source,
                videoIn: request.videoIn,
                videoOut: request.videoOut,
                keepAllFrames: request.keepAllFrames,
                videoOptions: request.videoOptions)
            let session = WatchCaptureSession(
                dependencies: dependencies,
                configuration: configuration)
            let result = try await session.run()

            var summaryLines = [
                "capture sampled \(result.stats.framesSampled) frames at " +
                    "\(String(format: "%.2f", result.stats.sampledFps)) FPS; " +
                    "kept \(result.stats.framesKept) at \(String(format: "%.2f", result.stats.keptFps)) FPS",
                "contact: \(result.contactSheet.path)",
                "metadata: \(result.metadataFile)",
                "frames: \(result.frames.count) files",
            ]
            if let videoOut = result.videoOut {
                summaryLines.insert("video: \(videoOut)", at: 3)
            }
            if !result.warnings.isEmpty {
                let warnings = result.warnings.map(\.message).joined(separator: "; ")
                summaryLines.append("warnings: \(warnings)")
            }
            let summary = summaryLines.joined(separator: "\n")
            let meta = ToolEventSummary(
                actionDescription: "Capture",
                notes: summary)

            return try Self.successResponse(
                summary: summary,
                eventSummary: meta,
                result: result,
                focusResult: focusReceipt.result,
                targetIdentity: targetIdentity)
        } catch let error as CaptureArtifactCleanupError {
            return Self.failureResponse(error, focusResult: focusReceipt.result)
        } catch let error as CancellationError {
            if focusReceipt.result != nil {
                return Self.failureResponse(error, focusResult: focusReceipt.result)
            }
            throw error
        } catch {
            try Task.checkCancellation()
            return Self.failureResponse(error, focusResult: focusReceipt.result)
        }
    }

    static func successResponse(
        summary: String,
        eventSummary: ToolEventSummary,
        result: CaptureSessionResult,
        focusResult: UIAutomationActionResult<Void>?,
        targetIdentity: DesktopTargetIdentity?) throws -> ToolResponse
    {
        var fields = CaptureMetaBuilder.buildMeta(
            from: result,
            mutationDispatched: focusResult?.outcome?.dispatchState.mutationDispatched ?? false).objectValue ?? [:]
        fields["scope"] = try Value(result.scope)
        fields = try MCPDesktopTargetMetadataProjector.fields(targetIdentity, merging: fields)
        let actionMeta = try MCPToolResponseMetadataProjector.metadata(
            merging: fields,
            outcome: focusResult?.outcome)
        return ToolResponse.text(
            summary,
            meta: ToolEventSummary.merge(summary: eventSummary, into: actionMeta))
    }

    static func failureResponse(
        _ error: any Error,
        focusResult: UIAutomationActionResult<Void>?) -> ToolResponse
    {
        let preserved = ObservationActionResultSupport.preservingFailure(
            error,
            after: focusResult,
            operation: "live capture after foreground focus")
        if let failure = preserved as? DesktopActionFailure {
            let fields = CaptureMetaBuilder.failureMeta(
                error,
                mutationDispatched: failure.outcome.dispatchState.mutationDispatched).objectValue ?? [:]
            return (try? MCPToolResponseMetadataProjector.errorResponse(
                for: failure,
                invalidatedSnapshotID: nil,
                additionalFields: fields)) ?? ToolResponse.error(failure.message)
        }
        return ToolResponse.error(
            error.localizedDescription,
            meta: CaptureMetaBuilder.failureMeta(error, mutationDispatched: false))
    }

    static func failureResponse(
        _ error: any Error,
        mutationDispatched: Bool) -> ToolResponse
    {
        if mutationDispatched {
            let outcome = DesktopActionOutcome.indeterminate(
                delivery: .init(mechanism: .capturePipeline, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .one)
            return self.failureResponse(
                error,
                focusResult: UIAutomationActionResult(payload: (), outcome: outcome))
        }
        return self.failureResponse(error, focusResult: nil)
    }

    @MainActor
    private func prepareCaptureFocus(
        _ request: CaptureRequest,
        receipt: CaptureFocusDispatchReceipt) async throws
    {
        guard request.source == .live, request.options.captureFocus != .background else { return }

        guard let identity = request.scope.windowMutationIdentity,
              let windowID = request.scope.windowId,
              identity.windowID == Int(windowID)
        else { return }
        do {
            let focusResult = try await self.context.windows.focusWindowResult(
                target: .windowId(identity.windowID),
                expectedIdentity: identity)
            receipt.result = try self.context.windows.validatedWindowMutationResult(
                focusResult,
                expectedIdentity: identity,
                operation: "Live capture focus")
        } catch let failure as DesktopActionFailure {
            throw failure.attributed(to: DesktopActionTargetReceipt(
                processIdentifier: identity.ownerProcessIdentifier,
                processStartIdentity: identity.ownerProcessStartIdentity,
                windowID: identity.windowID))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    private static func exactTargetIdentity(for scope: CaptureScope) throws -> DesktopTargetIdentity? {
        guard scope.kind == .window else { return nil }
        guard let identity = scope.windowMutationIdentity,
              let windowID = scope.windowId,
              identity.windowID == Int(windowID),
              let bounds = identity.capturedBounds
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Live window capture lost its exact target receipt.",
                hint: "Refresh the window inventory before retrying.")
        }
        return try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds))
    }
}

@MainActor
final class CaptureFocusDispatchReceipt {
    var result: UIAutomationActionResult<Void>?
}
