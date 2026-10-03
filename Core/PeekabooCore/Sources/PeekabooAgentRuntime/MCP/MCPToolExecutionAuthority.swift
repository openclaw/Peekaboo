import Tachikoma
import TachikomaMCP

/// Trusted invocation authority. The UI policy remains independent of temporary clipboard access.
public struct MCPToolExecutionAuthority: Sendable, Equatable {
    public let basePolicy: MCPToolExecutionPolicy
    public let temporaryClipboardPasteGranted: Bool

    public init(
        basePolicy: MCPToolExecutionPolicy = .backgroundOnly,
        temporaryClipboardPasteGranted: Bool = false)
    {
        self.basePolicy = basePolicy
        self.temporaryClipboardPasteGranted = temporaryClipboardPasteGranted
    }

    public static let backgroundOnly = Self()

    public var permitsTemporaryClipboardPaste: Bool {
        self.basePolicy != .backgroundOnly || self.temporaryClipboardPasteGranted
    }

    public func permits(_ requested: Self) -> Bool {
        let permitsUI = switch self.basePolicy {
        case .unrestricted:
            true
        case .foregroundAllowed:
            requested.basePolicy != .unrestricted
        case .backgroundOnly:
            requested.basePolicy == .backgroundOnly
        }
        // Legacy foreground authority already permits clipboard-backed paste.
        return permitsUI && (!requested.temporaryClipboardPasteGranted || self.permitsTemporaryClipboardPaste)
    }

    func rejection(toolName: String, arguments: ToolArguments) -> ToolResponse? {
        self.basePolicy.rejection(
            toolName: toolName,
            arguments: arguments,
            temporaryClipboardPasteGranted: self.temporaryClipboardPasteGranted)
    }

    func rejection(toolName: String, agentArguments: [String: AnyAgentToolValue]) -> ToolResponse? {
        self.rejection(toolName: toolName, arguments: ToolArguments(from: AgentToolArguments(agentArguments)))
    }
}
