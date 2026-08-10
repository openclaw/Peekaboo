import Commander
import Foundation
import MCP
import PeekabooCore
import TachikomaMCP

struct MCPToolCommandPayload: Codable {
    let tool: String
    let isError: Bool
    let content: [MCP.Tool.Content]
    let text: String
    let meta: Value?
}

@MainActor
enum MCPToolCommandOutput {
    static func payload(tool: String, response: ToolResponse) -> MCPToolCommandPayload {
        MCPToolCommandPayload(
            tool: tool,
            isError: response.isError,
            content: response.content,
            text: response.content.map(self.summary).joined(separator: "\n"),
            meta: response.meta
        )
    }

    static func output(
        tool: String,
        response: ToolResponse,
        jsonOutput: Bool,
        logger: Logger
    ) throws {
        let payload = self.payload(tool: tool, response: response)
        if jsonOutput {
            let error = response.isError
                ? ErrorInfo(message: payload.text, code: .VALIDATION_ERROR)
                : nil
            let envelope = ResultEnvelope(
                success: !response.isError,
                data: payload,
                messages: nil,
                debug_logs: logger.getDebugLogs(),
                error: error
            )
            outputJSONCodable(envelope, logger: logger)
        } else if !payload.text.isEmpty {
            print(payload.text)
        }

        if response.isError {
            throw ExitCode(1)
        }
    }

    private static func summary(for content: MCP.Tool.Content) -> String {
        switch content {
        case let .text(text, _, _):
            return text
        case let .image(data, mimeType, _, _):
            return "[Image: \(mimeType), base64 bytes: \(data.count)]"
        case let .audio(data, mimeType, _, _):
            return "[Audio: \(mimeType), base64 bytes: \(data.count)]"
        case let .resource(resource, _, _):
            if let text = resource.text {
                return text
            } else if let blob = resource.blob {
                return "[Resource: \(resource.uri), blob bytes: \(blob.count)]"
            } else {
                return "[Resource: \(resource.uri)]"
            }
        case let .resourceLink(uri, name, title, _, mimeType, _):
            let label = title ?? name
            if let mimeType {
                return "[Resource Link: \(label) \(uri), type: \(mimeType)]"
            } else {
                return "[Resource Link: \(label) \(uri)]"
            }
        }
    }
}
