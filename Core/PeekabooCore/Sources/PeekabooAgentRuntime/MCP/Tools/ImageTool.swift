import Foundation
import MCP
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

/// MCP tool for capturing screenshots
public struct ImageTool: MCPTool {
    let context: MCPToolContext

    public let name = "image"

    public var description: String {
        """
        Screenshot only; use see for element detection.
        Captures macOS screen content without building an element map or running AI analysis.
        Targets include entire displays, the frontmost window, app-specific windows (`app_target`),
        or the menu bar. Capture is background-only by default; set `capture_focus` to `foreground`
        to activate the target before capture.
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

        var captureSet: ImageCaptureSet
        do {
            captureSet = try await self.captureImages(for: request)
        } catch PeekabooError.permissionDeniedScreenRecording {
            return self.screenRecordingPermissionError()
        }

        captureSet = try self.downscaledCaptureSetIfNeeded(captureSet, request: request)
        let captureResults = captureSet.captures
        let savedFiles = try self.savedFiles(for: captureSet, request: request)

        return self.buildCaptureResponse(
            format: request.format,
            savedFiles: savedFiles,
            captureResults: captureResults,
            observation: captureSet.observation)
    }

    private func screenRecordingPermissionError() -> ToolResponse {
        let responseText = "Screen Recording permission is required. " +
            "Grant via: System Settings > Privacy & Security > Screen Recording"
        let summary = ToolEventSummary(actionDescription: "Image Capture", notes: "Screen Recording missing")
        return ToolResponse.error(responseText, meta: ToolEventSummary.merge(summary: summary, into: nil))
    }
}
