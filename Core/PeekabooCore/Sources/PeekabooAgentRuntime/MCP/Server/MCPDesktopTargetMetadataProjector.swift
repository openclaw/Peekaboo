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
        return try [
            "target_identity": Value(identity.projection),
            "target_receipt": Value(identity.actionTargetReceipt),
        ]
    }
}
