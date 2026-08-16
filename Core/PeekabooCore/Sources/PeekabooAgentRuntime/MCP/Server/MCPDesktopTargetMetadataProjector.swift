import MCP
import PeekabooAutomationKit
import TachikomaMCP

enum MCPDesktopTargetMetadataProjector {
    static func fields(
        _ identity: DesktopTargetIdentity?,
        merging base: [String: Value]) throws -> [String: Value]
    {
        try base.merging(self.fields(identity)) { _, target in target }
    }

    static func fields(_ identity: DesktopTargetIdentity?) throws -> [String: Value] {
        guard let identity else { return [:] }
        let process = identity.processIdentity
        var target: [String: Value] = [
            "kind": .string(identity.exactWindow == nil ? "process" : "window"),
            "pid": .int(Int(process.processIdentifier)),
            "process_start_identity_decimal": .string(String(process.processStartIdentity)),
        ]
        if let exactWindow = identity.exactWindow {
            target["window_id"] = .int(exactWindow.identity.windowID)
        }
        return try [
            "target_identity": .object(target),
            "target_receipt": Value(identity.actionTargetReceipt),
        ]
    }
}
