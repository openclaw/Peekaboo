import PeekabooAutomationKit

/// Narrow service surface required by `PeekabooBridgeServer`.
///
/// Bridge hosts (Peekaboo.app, ClawdBot.app, or in-process callers) provide concrete
/// implementations for these services.
@MainActor
public protocol PeekabooBridgeServiceProviding: AnyObject, Sendable {
    var permissions: PermissionsService { get }
    var screenCapture: any ScreenCaptureServiceProtocol { get }
    var automation: any UIAutomationServiceProtocol { get }
    var windows: any WindowManagementServiceProtocol { get }
    var applications: any ApplicationServiceProtocol { get }
    var menu: any MenuServiceProtocol { get }
    var dock: any DockServiceProtocol { get }
    var dialogs: any DialogServiceProtocol { get }
    var snapshots: any SnapshotManagerProtocol { get }
    var desktopObservation: any DesktopObservationServiceProtocol { get }
    var supportsDesktopObservationCaptureEngine: Bool { get }
    var supportsScreenCaptureKitProcessOwnership: Bool { get }

    /// Whether the concrete native service owns the lane for this exact operation.
    /// Test doubles and older hosts default to Bridge-owned conservative coordination.
    func ownsDesktopOperationLane(for operation: PeekabooBridgeOperation) -> Bool

    func browserStatus(channel: String?) async throws -> PeekabooBridgeBrowserStatus
    func browserConnect(channel: String?) async throws -> PeekabooBridgeBrowserStatus
    func browserDisconnect() async throws
    func browserExecute(_ request: PeekabooBridgeBrowserExecuteRequest) async throws
        -> PeekabooBridgeBrowserToolResponse
}

@MainActor
extension PeekabooBridgeServiceProviding {
    public var supportsDesktopObservationCaptureEngine: Bool {
        self.screenCapture is any EngineAwareScreenCaptureServiceProtocol
    }

    public var supportsScreenCaptureKitProcessOwnership: Bool {
        false
    }

    public func ownsDesktopOperationLane(for _: PeekabooBridgeOperation) -> Bool {
        false
    }

    public func browserStatus(channel _: String?) async throws -> PeekabooBridgeBrowserStatus {
        throw PeekabooBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "Browser MCP is not supported by this bridge host")
    }

    public func browserConnect(channel _: String?) async throws -> PeekabooBridgeBrowserStatus {
        throw PeekabooBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "Browser MCP is not supported by this bridge host")
    }

    public func browserDisconnect() async throws {
        throw PeekabooBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "Browser MCP is not supported by this bridge host")
    }

    public func browserExecute(_: PeekabooBridgeBrowserExecuteRequest) async throws
    -> PeekabooBridgeBrowserToolResponse {
        throw PeekabooBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "Browser MCP is not supported by this bridge host")
    }
}
