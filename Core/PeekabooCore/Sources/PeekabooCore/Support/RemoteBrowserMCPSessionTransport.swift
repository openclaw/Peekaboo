import Foundation
import PeekabooAgentRuntime
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

/// Opaque Bridge-owned session selected for one authenticated client generation.
///
/// The target digest is attribution, not authority. Every operation must still carry this handle over the
/// authenticated transport, where the Bridge binds it to the connected peer.
public struct RemoteBrowserMCPSessionHandle: Hashable, Sendable {
    public let sessionID: UUID
    public let targetReceiptSHA256: String?

    public init(sessionID: UUID, targetReceiptSHA256: String? = nil) {
        self.sessionID = sessionID
        self.targetReceiptSHA256 = targetReceiptSHA256
    }

    var isCanonical: Bool {
        guard self.sessionID != Self.zeroUUID else { return false }
        guard let targetReceiptSHA256 else { return true }
        return targetReceiptSHA256.count == 64 &&
            targetReceiptSHA256 == targetReceiptSHA256.lowercased() &&
            targetReceiptSHA256.allSatisfy(\.isHexDigit)
    }

    private static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

/// Narrow adapter between caller-scoped browser semantics and the evolving Bridge wire.
///
/// Concrete Bridge code owns request/response enums and must authenticate the session handle against the
/// operation client instance and exact peer generation on every call.
@MainActor
public protocol RemoteBrowserMCPSessionTransport: AnyObject, Sendable {
    func openSession(
        handoff: BrowserMCPHandoffGrant?,
        claimID: UUID) async throws -> RemoteBrowserMCPSessionHandle

    func status(
        session: RemoteBrowserMCPSessionHandle,
        channel: BrowserMCPChannel?) async throws -> BrowserMCPStatus

    func connectWithOutcome(
        session: RemoteBrowserMCPSessionHandle,
        channel: BrowserMCPChannel?,
        browserURL: String?) async throws -> DesktopActionResult<BrowserMCPStatus>

    func executeSequenceWithOutcome(
        session: RemoteBrowserMCPSessionHandle,
        calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        expectedSessionBinding: BrowserMCPExecutionSessionBinding,
        elementPreflight: BrowserMCPElementPreflight?) async throws -> DesktopActionResult<ToolResponse>

    func disconnect(session: RemoteBrowserMCPSessionHandle) async
    func endSession(_ session: RemoteBrowserMCPSessionHandle) async
}

enum RemoteBrowserMCPSessionError: LocalizedError {
    case unavailable
    case invalidHandle
    case invalidStatus
    case ended

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The selected Bridge does not support caller-scoped browser sessions."
        case .invalidHandle:
            "The Bridge returned an invalid browser session handle."
        case .invalidStatus:
            "The Bridge returned contradictory browser session status."
        case .ended:
            "The caller-scoped browser session has ended."
        }
    }
}
