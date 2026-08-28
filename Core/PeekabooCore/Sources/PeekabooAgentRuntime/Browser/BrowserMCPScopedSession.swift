import Foundation

/// Opaque, owner-private authorization used only while opening a new browser provider session.
///
/// The Agent runtime deliberately does not decode this payload. A concrete transport must authenticate
/// and consume it before returning a caller-scoped browser client.
public struct BrowserMCPHandoffGrant: Sendable {
    public let payload: Data

    public init(payload: Data) {
        self.payload = payload
    }
}

/// Additive surface for browser providers that can create a fresh caller-scoped provider child.
public protocol BrowserMCPScopedSessionOpening: BrowserMCPClientProviding {
    @MainActor
    func openBrowserMCPScopedSession(
        handoff: BrowserMCPHandoffGrant?) async throws -> any BrowserMCPClientProviding
}

/// Lifecycle surface used by MCP teardown without coupling the Agent runtime to a concrete transport.
public protocol BrowserMCPScopedSessionEnding: BrowserMCPClientProviding {
    @MainActor
    func endBrowserMCPScopedSession() async
}

extension BrowserMCPProviderSessionEpoch {
    /// Constructs an epoch from an authenticated transport identifier.
    public init(transportID: UUID) {
        self.init(rawValue: transportID)
    }

    /// Opaque transport representation. This identifies a provider child but grants no authority by itself.
    public var transportID: UUID {
        self.rawValue
    }
}
