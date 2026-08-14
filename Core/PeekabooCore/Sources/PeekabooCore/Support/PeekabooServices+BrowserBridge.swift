import Foundation
import MCP
import PeekabooAgentRuntime
import PeekabooBridge
import TachikomaMCP

@MainActor
extension PeekabooServices {
    public func browserStatus(channel: String?) async throws -> PeekabooBridgeBrowserStatus {
        let status = await self.browser.status(channel: channel.flatMap(BrowserMCPChannel.init(rawValue:)))
        return Self.bridgeStatus(from: status)
    }

    public func browserConnect(channel: String?) async throws -> PeekabooBridgeBrowserStatus {
        try await self.browserConnect(channel: channel, browserURL: nil)
    }

    public func browserConnect(channel: String?, browserURL: String?) async throws -> PeekabooBridgeBrowserStatus {
        let status = try await self.browser.connect(
            channel: channel.flatMap(BrowserMCPChannel.init(rawValue:)),
            browserURL: browserURL)
        return Self.bridgeStatus(from: status)
    }

    public func browserDisconnect() async throws {
        await self.browser.disconnect()
    }

    public func browserExecute(_ request: PeekabooBridgeBrowserExecuteRequest) async throws
        -> PeekabooBridgeBrowserToolResponse
    {
        let calls = request.resolvedCalls.map { call in
            BrowserMCPMappedCall(
                toolName: call.toolName,
                arguments: call.arguments.mapValues { $0.toAny() })
        }
        let response = try await self.browser.executeSequence(
            calls,
            channel: request.channel.flatMap(BrowserMCPChannel.init(rawValue:)))
        return try Self.bridgeToolResponse(from: response)
    }

    private static func bridgeStatus(from status: BrowserMCPStatus) -> PeekabooBridgeBrowserStatus {
        PeekabooBridgeBrowserStatus(
            isConnected: status.isConnected,
            toolCount: status.toolCount,
            detectedBrowsers: status.detectedBrowsers.map {
                PeekabooBridgeBrowserInfo(
                    name: $0.name,
                    bundleIdentifier: $0.bundleIdentifier,
                    processIdentifier: $0.processIdentifier,
                    version: $0.version,
                    channel: $0.channel.rawValue)
            },
            connectionReceipt: status.connectionReceipt.map {
                PeekabooBridgeBrowserConnectionReceipt(
                    channel: $0.channel?.rawValue,
                    processIdentifier: $0.processIdentifier,
                    processStartIdentity: $0.processStartIdentity,
                    bundleIdentifier: $0.bundleIdentifier,
                    browserURL: $0.browserURL,
                    webSocketDebuggerURL: $0.webSocketDebuggerURL,
                    devToolsBrowserID: $0.devToolsBrowserID,
                    browserVersion: $0.browserVersion,
                    protocolVersion: $0.protocolVersion)
            },
            error: status.error)
    }

    private static func bridgeToolResponse(from response: ToolResponse) throws -> PeekabooBridgeBrowserToolResponse {
        let content = try response.content.map { try PeekabooBridgeJSONValue.fromCodable($0) }
        return try PeekabooBridgeBrowserToolResponse(
            content: content,
            isError: response.isError,
            meta: response.meta.map { try PeekabooBridgeJSONValue.fromCodable($0) })
    }
}

extension PeekabooBridgeJSONValue {
    static func fromCodable(_ value: some Encodable) throws -> PeekabooBridgeJSONValue {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        return try self.fromAny(object)
    }

    static func fromAny(_ value: Any) throws -> PeekabooBridgeJSONValue {
        switch value {
        case is NSNull:
            return .null
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .int(value)
        case let value as Double:
            return .double(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            let double = value.doubleValue
            if double.rounded() == double {
                return .int(value.intValue)
            }
            return .double(double)
        case let value as String:
            return .string(value)
        case let value as [Any]:
            return try .array(value.map { try self.fromAny($0) })
        case let value as [String: Any]:
            return try .object(value.mapValues { try self.fromAny($0) })
        default:
            return .string(String(describing: value))
        }
    }

    func toAny() -> Any {
        switch self {
        case .null:
            NSNull()
        case let .bool(value):
            value
        case let .int(value):
            value
        case let .double(value):
            value
        case let .string(value):
            value
        case let .array(value):
            value.map { $0.toAny() }
        case let .object(value):
            value.mapValues { $0.toAny() }
        }
    }
}
