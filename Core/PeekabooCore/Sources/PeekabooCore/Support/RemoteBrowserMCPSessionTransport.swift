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

    func disconnect(session: RemoteBrowserMCPSessionHandle) async throws
    func endSession(_ session: RemoteBrowserMCPSessionHandle) async throws
}

/// Authenticated Bridge refusals that conclusively end the local session capability.
///
/// Cancellation, timeout, response loss, and unclassified envelopes must not be projected as these cases because
/// their session state remains indeterminate.
public enum RemoteBrowserMCPSessionTransportError: Error, CaseIterable, Equatable, LocalizedError, Sendable {
    case invalidSession
    case sessionEnded
    case wrongOwner
    case hostGenerationChanged

    public var errorDescription: String? {
        switch self {
        case .invalidSession:
            "The Bridge confirmed that the browser session handle is invalid."
        case .sessionEnded:
            "The Bridge confirmed that the browser session has ended."
        case .wrongOwner:
            "The Bridge confirmed that the browser session belongs to another authenticated client generation."
        case .hostGenerationChanged:
            "The authenticated Bridge host generation changed."
        }
    }
}

enum RemoteBrowserMCPSessionError: LocalizedError {
    case unavailable
    case invalidHandle
    case invalidStatus
    case ended
    case openInProgress
    case openAttemptUnresolved

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
        case .openInProgress:
            "A caller-scoped browser session open is already in progress."
        case .openAttemptUnresolved:
            "A prior caller-scoped browser session open remains indeterminate."
        }
    }
}
