import MCP
import TachikomaMCP

/// Trusted execution evidence added after a browser provider returns.
///
/// Provider metadata is untrusted and may not claim this key. BrowserTool preserves this object
/// separately from namespaced provider diagnostics so Agent/MCP consumers can attribute every
/// result to the exact persistent DevTools connection that produced it.
public enum BrowserMCPExecutionEvidence {
    public static let metadataKey = "browser_execution"

    public static func attaching(
        to response: ToolResponse,
        connectionReceipt: BrowserMCPConnectionReceipt,
        completedCallCount: Int,
        dispatchedCallCount: Int) -> ToolResponse
    {
        precondition(completedCallCount >= 0)
        precondition(dispatchedCallCount >= completedCallCount)

        var fields = response.meta?.objectValue ?? [:]
        if let meta = response.meta, meta.objectValue == nil {
            fields["provider_payload"] = meta
        }
        fields[self.metadataKey] = .object([
            "connection_receipt": .object(self.connectionReceiptFields(connectionReceipt)),
            "completed_call_count": .int(completedCallCount),
            "dispatched_call_count": .int(dispatchedCallCount),
        ])
        return ToolResponse(
            content: response.content,
            isError: response.isError,
            meta: .object(fields))
    }

    static func split(
        _ meta: Value?) -> (evidence: Value?, providerMeta: Value?)
    {
        guard case let .object(fields)? = meta else {
            return (nil, meta)
        }
        var providerFields = fields
        let evidence = providerFields.removeValue(forKey: self.metadataKey)
        return (
            evidence,
            providerFields.isEmpty ? nil : .object(providerFields))
    }

    private static func connectionReceiptFields(
        _ receipt: BrowserMCPConnectionReceipt) -> [String: Value]
    {
        var fields: [String: Value] = [:]
        if let channel = receipt.channel {
            fields["channel"] = .string(channel.rawValue)
        }
        if let processIdentifier = receipt.processIdentifier {
            fields["pid"] = .int(Int(processIdentifier))
        }
        if let processStartIdentity = receipt.processStartIdentity {
            fields["process_start_identity_decimal"] = .string(String(processStartIdentity))
        }
        if let bundleIdentifier = receipt.bundleIdentifier {
            fields["bundle_id"] = .string(bundleIdentifier)
        }
        if let browserURL = receipt.browserURL {
            fields["browser_url"] = .string(browserURL)
        }
        if let webSocketDebuggerURL = receipt.webSocketDebuggerURL {
            fields["websocket_debugger_url"] = .string(webSocketDebuggerURL)
        }
        if let devToolsBrowserID = receipt.devToolsBrowserID {
            fields["browser_id"] = .string(devToolsBrowserID)
        }
        if let browserVersion = receipt.browserVersion {
            fields["browser_version"] = .string(browserVersion)
        }
        if let protocolVersion = receipt.protocolVersion {
            fields["protocol_version"] = .string(protocolVersion)
        }
        return fields
    }
}
