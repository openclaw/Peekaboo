import MCP
import TachikomaMCP

enum BrowserMCPPrivateInteropError: Error, Equatable {
    case authorityUnavailable
    case providerError
    case missingTargetID
    case invalidTargetID
    case deadlineExceeded
    case publicDispatchRefused
}

/// Host-only access to the pinned provider's tab target identity.
///
/// The returned string is private CDP authority. It may be stored in a caller-scoped capability binding but must
/// never be projected into CLI, MCP, Bridge, logs, or provider diagnostics.
enum BrowserMCPPrivateInterop {
    static let targetIDToolName = "get_tab_id"

    static func targetIDCall(providerPageID: Int) -> BrowserMCPMappedCall {
        BrowserMCPMappedCall(
            toolName: self.targetIDToolName,
            arguments: ["pageId": providerPageID])
    }

    static func targetID(from response: ToolResponse) throws -> String {
        guard !response.isError else { throw BrowserMCPPrivateInteropError.providerError }
        guard let value = response.structuredContent?.objectValue?["tabId"]?.stringValue else {
            throw BrowserMCPPrivateInteropError.missingTargetID
        }
        guard self.isValidPrivateTargetID(value) else {
            throw BrowserMCPPrivateInteropError.invalidTargetID
        }
        return value
    }

    private static func isValidPrivateTargetID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.utf8.allSatisfy { byte in
            byte >= 0x30 && byte <= 0x39 ||
                byte >= 0x41 && byte <= 0x5A ||
                byte >= 0x61 && byte <= 0x7A ||
                byte == 0x2D || byte == 0x2E || byte == 0x5F
        }
    }
}
