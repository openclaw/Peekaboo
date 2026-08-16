import PeekabooAutomationKit
import PeekabooFoundation

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
    func browserConnect(channel: String?, browserURL: String?) async throws -> PeekabooBridgeBrowserStatus
    func browserDisconnect() async throws
    func browserExecute(_ request: PeekabooBridgeBrowserExecuteRequest) async throws
        -> PeekabooBridgeBrowserToolResponse
    func browserExecute(
        _ request: PeekabooBridgeBrowserExecuteRequest,
        expectedConnectionReceipt: PeekabooBridgeBrowserConnectionReceipt) async throws
        -> PeekabooBridgeBrowserExecutionResult
}

@MainActor
public protocol PeekabooBridgeBrowserConnectionResultProviding: PeekabooBridgeServiceProviding {
    func browserConnectResult(
        channel: String?,
        browserURL: String?) async throws -> DesktopActionResult<PeekabooBridgeBrowserStatus>
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

    public func browserConnect(channel: String?, browserURL: String?) async throws -> PeekabooBridgeBrowserStatus {
        guard browserURL == nil else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "This bridge host cannot carry an exact browser endpoint")
        }
        return try await self.browserConnect(channel: channel)
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

    public func browserExecute(
        _: PeekabooBridgeBrowserExecuteRequest,
        expectedConnectionReceipt _: PeekabooBridgeBrowserConnectionReceipt) async throws
        -> PeekabooBridgeBrowserExecutionResult
    {
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .operationUnsupported,
            message: "This Bridge browser provider cannot bind execution to an exact connection receipt.",
            hint: "Update the runtime host before retrying target-attested browser execution.")
    }
}
