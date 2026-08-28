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

/// Lifecycle surface used by MCP and Agent teardown without coupling the runtime to a concrete transport.
public protocol BrowserMCPScopedSessionEnding: BrowserMCPClientProviding {
    @MainActor
    @discardableResult
    func endBrowserMCPScopedSession() async -> Bool
}

/// Additive surface for browser providers that can create a fresh, end-capable caller-scoped provider child.
public protocol BrowserMCPScopedSessionOpening: BrowserMCPClientProviding {
    /// Whether the most recent root open may still own a remote child whose response was not observed.
    ///
    /// Callers that serialize multiple logical sessions use this to retain the exact logical owner until
    /// recovery or teardown resolves the open. Providers without indeterminate-open semantics use the default.
    @MainActor
    var browserMCPScopedSessionOpenAttemptRequiresRecovery: Bool { get }

    @MainActor
    func openBrowserMCPScopedSession(
        handoff: BrowserMCPHandoffGrant?) async throws -> any BrowserMCPScopedSessionEnding
}

extension BrowserMCPScopedSessionOpening {
    @MainActor
    public var browserMCPScopedSessionOpenAttemptRequiresRecovery: Bool {
        false
    }
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
