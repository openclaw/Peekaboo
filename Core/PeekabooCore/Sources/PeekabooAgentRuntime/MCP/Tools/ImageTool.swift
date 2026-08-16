import Foundation
import MCP
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

/// MCP tool for capturing screenshots
public struct ImageTool: MCPTool {
    static let emptyFinalImageReason = "Image processing produced no final image bytes"

    let context: MCPToolContext

    public let name = "image"

    public var description: String {
        """
        Screenshot only; use see for element detection.
        Captures macOS screen content without building an element map or running AI analysis.
        Targets include entire displays, the frontmost window, app-specific windows (`app_target`),
        or the menu bar. Capture is background-only by default. Set `capture_focus` to `foreground`
        for visible capture feedback and exact app/PID activation before an app-targeted capture.
        Output can be written to disk or returned inline as Base64 data (`format: "data"`).
        Window shadows/frames are excluded automatically.
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "path": SchemaBuilder.string(
                    description: "Optional. Base absolute path for saving the image."),
                "format": SchemaBuilder.string(
                    description: "Optional. Output format.",
                    enum: ["png", "jpg", "data"]),
                "app_target": SchemaBuilder.string(
                    description: "Optional. Specifies the capture target."),
                "window_id": SchemaBuilder.integer(
                    description: "Optional. Exact WindowServer window ID; may be combined with an app target."),
                "capture_focus": SchemaBuilder.string(
                    description: "Optional. background (default), foreground (activate target), or legacy auto.",
                    enum: ["background", "auto", "foreground"],
                    default: "background"),
                "scale": SchemaBuilder.string(
                    description: "Optional. Capture scale: logical|1x or native|retina|2x.",
                    enum: ["logical", "1x", "native", "retina", "2x"],
                    default: "logical"),
                "retina": SchemaBuilder.boolean(
                    description: "Optional. Shorthand for scale=native.",
                    default: false),
                "max_dimension": SchemaBuilder.integer(
                    description: """
                    Optional. Downscales the captured image so its longest side does not exceed this value.
                    Defaults to 1500 when format is "data".
                    """),
            ],
            required: [])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        let request = try ImageRequest(arguments: arguments)
        guard await self.context.screenCapture.hasScreenRecordingPermission() else {
            return self.screenRecordingPermissionError()
        }

        var completedActionResult: UIAutomationActionResult<DesktopObservationResult>?
        let callerOutputPath = request.outputPath
        let stagingOutputPath = self.stagingOutputPathIfNeeded(
            for: request,
            callerOutputPath: callerOutputPath)
        defer {
            if let stagingOutputPath {
                try? FileManager.default.removeItem(atPath: stagingOutputPath)
            }
        }
        do {
            var captureSet = try await self.captureImages(
                for: request,
                outputPath: stagingOutputPath)
            completedActionResult = captureSet.actionResult
            captureSet = try self.downscaledCaptureSetIfNeeded(captureSet, request: request)
            captureSet = try self.rebindingProcessedCaptureSet(
                captureSet,
                rawPath: stagingOutputPath,
                readFromRawPath: request.effectiveMaxDimension == nil)
            let responseCaptureSet = try self.captureSet(
                captureSet,
                publishingAt: callerOutputPath)
            let captureResults = captureSet.captures
            let savedFiles = try self.savedFiles(for: responseCaptureSet, request: request)

            let response = try self.buildCaptureResponse(
                format: request.format,
                savedFiles: savedFiles,
                captureResults: captureResults,
                actionResult: responseCaptureSet.actionResult)
            if let callerOutputPath {
                try self.publishCapture(responseCaptureSet, to: callerOutputPath)
            }
            return response
        } catch PeekabooError.permissionDeniedScreenRecording {
            return self.screenRecordingPermissionError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let completedActionResult,
               let response = try self.emptyInlineCaptureResponse(
                   for: error,
                   request: request,
                   actionResult: completedActionResult)
            {
                return response
            }
            let presentedError = ObservationActionResultSupport.preservingFailure(
                error,
                after: completedActionResult,
                operation: "image")
            guard let failure = presentedError as? DesktopActionFailure else {
                throw presentedError
            }
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: nil,
                additionalFields: ObservationActionResultSupport.standardErrorFields(error))
        }
    }

    private func screenRecordingPermissionError() -> ToolResponse {
        let responseText = "Screen Recording permission is required. " +
            "Grant via: System Settings > Privacy & Security > Screen Recording"
        let summary = ToolEventSummary(actionDescription: "Image Capture", notes: "Screen Recording missing")
        return ToolResponse.error(responseText, meta: ToolEventSummary.merge(summary: summary, into: nil))
    }

    private func emptyInlineCaptureResponse(
        for error: any Error,
        request: ImageRequest,
        actionResult: UIAutomationActionResult<DesktopObservationResult>) throws -> ToolResponse?
    {
        guard request.format == .data,
              let peekabooError = error as? PeekabooError,
              case let .captureFailed(reason) = peekabooError,
              reason == Self.emptyFinalImageReason
        else {
            return nil
        }

        let captured = actionResult.payload.capture
        let emptyCapture = CaptureResult(
            imageData: Data(),
            metadata: captured.metadata,
            warning: captured.warning)
        return try self.buildCaptureResponse(
            format: .data,
            savedFiles: [],
            captureResults: [emptyCapture],
            actionResult: actionResult)
    }
}
