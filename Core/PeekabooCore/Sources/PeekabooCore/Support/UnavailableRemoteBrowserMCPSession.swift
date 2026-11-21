import Foundation
import PeekabooAgentRuntime
import TachikomaMCP

/// A caller-owned, inert browser slot for a Bridge without scoped browser support.
/// It holds no Bridge client, provider or connection and cannot issue remote calls.
/// Native tools retain their original authenticated Bridge and permission checks.
@MainActor
final class UnavailableRemoteBrowserMCPSession: BrowserMCPScopedSessionEnding {
    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        BrowserMCPStatus(
            isConnected: false,
            toolCount: 0,
            detectedBrowsers: [],
            error: RemoteBrowserMCPSessionError.unavailable.localizedDescription)
    }

    func connect(channel _: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        throw RemoteBrowserMCPSessionError.unavailable
    }

    func connect(channel _: BrowserMCPChannel?, browserURL _: String?) async throws -> BrowserMCPStatus {
        throw RemoteBrowserMCPSessionError.unavailable
    }

    func execute(
        toolName _: String,
        arguments _: [String: Any],
        channel _: BrowserMCPChannel?) async throws -> ToolResponse
    {
        throw RemoteBrowserMCPSessionError.unavailable
    }

    func executeSequence(
        _ calls: [BrowserMCPMappedCall],
        channel _: BrowserMCPChannel?) async throws -> ToolResponse
    {
        throw RemoteBrowserMCPSessionError.unavailable
    }

    func executeSequence(
        _ calls: [BrowserMCPMappedCall],
        channel _: BrowserMCPChannel?,
        expectedConnectionReceipt _: BrowserMCPConnectionReceipt) async throws -> BrowserMCPExecutionResult
    {
        throw RemoteBrowserMCPSessionError.unavailable
    }

    func disconnect() async {}

    @discardableResult
    func endBrowserMCPScopedSession() async -> Bool {
        true
    }
}
