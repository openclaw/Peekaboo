import Commander
import Foundation
import MCP
import PeekabooCore
import PeekabooFoundation
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
    private struct EnvelopeMetadata {
        let outcome: DesktopActionOutcome.Projection?
        let targetIdentity: DesktopTargetIdentityProjection?
        let targetReceipt: DesktopActionTargetReceipt?
        let errorCode: String?

        init(_ value: Value?) {
            self.outcome = Self.decode(DesktopActionOutcome.Projection.self, from: value)
            guard case let .object(fields)? = value else {
                self.targetIdentity = nil
                self.targetReceipt = nil
                self.errorCode = nil
                return
            }
            self.targetIdentity = Self.decode(
                DesktopTargetIdentityProjection.self,
                from: fields["target_identity"]
            )
            self.targetReceipt = Self.decode(
                DesktopActionTargetReceipt.self,
                from: fields["target_receipt"]
            )
            if case let .string(rawCode)? = fields["error_code"] {
                let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
                self.errorCode = code.isEmpty ? nil : code
            } else {
                self.errorCode = nil
            }
        }

        private static func decode<T: Decodable>(_ type: T.Type, from value: Value?) -> T? {
            guard let value,
                  let data = try? JSONEncoder().encode(value)
            else {
                return nil
            }
            return try? JSONDecoder().decode(type, from: data)
        }
    }

    static func payload(tool: String, response: ToolResponse) -> MCPToolCommandPayload {
        MCPToolCommandPayload(
            tool: tool,
            isError: response.isError,
            content: response.content,
            text: response.content.map(self.summary).joined(separator: "\n"),
            meta: response.meta
        )
    }

    static func envelope(
        tool: String,
        response: ToolResponse,
        debugLogs: [String] = []
    ) -> ResultEnvelope<MCPToolCommandPayload> {
        let payload = self.payload(tool: tool, response: response)
        return self.envelope(payload: payload, response: response, debugLogs: debugLogs)
    }

    private static func envelope(
        payload: MCPToolCommandPayload,
        response: ToolResponse,
        debugLogs: [String]
    ) -> ResultEnvelope<MCPToolCommandPayload> {
        let metadata = EnvelopeMetadata(response.meta)
        let error: ErrorInfo? = if response.isError {
            ErrorInfo(
                message: payload.text,
                code: metadata.errorCode ?? (metadata.outcome == nil
                    ? ErrorCode.VALIDATION_ERROR.rawValue
                    : ErrorCode.INTERACTION_FAILED.rawValue),
                retrySafe: metadata.outcome?.retrySafe,
                mutationDispatched: metadata.outcome?.mutationDispatched
            )
        } else {
            nil
        }
        return ResultEnvelope(
            success: !response.isError,
            effect: metadata.outcome?.effect,
            outcome: metadata.outcome,
            data: payload,
            target_identity: metadata.targetIdentity,
            target_receipt: metadata.targetReceipt,
            debug_logs: debugLogs,
            error: error
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
            let envelope = self.envelope(
                payload: payload,
                response: response,
                debugLogs: logger.getDebugLogs()
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
