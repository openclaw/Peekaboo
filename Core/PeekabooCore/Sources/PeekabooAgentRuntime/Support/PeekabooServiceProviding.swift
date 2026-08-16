import Foundation
import PeekabooAutomation
import PeekabooAutomationKit

public enum PeekabooServiceExecutionHost: String, Codable, Sendable {
    case local
    case remote
}

/// Aggregated service provider protocol exposed to higher-level modules.
@MainActor
public protocol PeekabooServiceProviding: AnyObject, Sendable, PermissionsStatusProviding {
    var executionHost: PeekabooServiceExecutionHost { get }
    var logging: any LoggingServiceProtocol { get }
    var desktopObservation: any DesktopObservationServiceProtocol { get }
    var screenCapture: any ScreenCaptureServiceProtocol { get }
    var applications: any ApplicationServiceProtocol { get }
    var automation: any UIAutomationServiceProtocol { get }
    var windows: any WindowManagementServiceProtocol { get }
    var menu: any MenuServiceProtocol { get }
    var dock: any DockServiceProtocol { get }
    var dialogs: any DialogServiceProtocol { get }
    var snapshots: any SnapshotManagerProtocol { get }
    var files: any FileServiceProtocol { get }
    var clipboard: any ClipboardServiceProtocol { get }
    var configuration: ConfigurationManager { get }
    var permissions: PermissionsService { get }
    var audioInput: AudioInputService { get }
    var screens: any ScreenServiceProtocol { get }
    var browser: any BrowserMCPClientProviding { get }
    var agent: (any AgentServiceProtocol)? { get }

    func ensureVisualizerConnection()
}

@MainActor
extension PeekabooServiceProviding {
    public var executionHost: PeekabooServiceExecutionHost {
        .local
    }

    public func permissionsStatus() async throws -> PermissionsStatus {
        let screenRecording = await self.screenCapture.hasScreenRecordingPermission()
        let accessibility = await self.automation.hasAccessibilityPermission()
        let postEvent = self.permissions.checkPostEventPermission()
        return PermissionsStatus(
            screenRecording: screenRecording,
            accessibility: accessibility,
            postEvent: postEvent)
    }

    public var desktopObservation: any DesktopObservationServiceProtocol {
        DesktopObservationService(
            screenCapture: self.screenCapture,
            automation: self.automation,
            applications: self.applications,
            menu: self.menu,
            screens: self.screens,
            snapshotManager: self.snapshots)
    }

    /// Install this service container as the default provider for MCP tool contexts and registry helpers.
    public func installAgentRuntimeDefaults() {
        let fallbackSnapshotExecutionGate = MCPToolSnapshotExecutionGate()
        MCPToolContext.configureDefaultContext { [unowned services = self] in
            MCPToolContext(
                services: services,
                snapshotExecutionGate: (services.agent as? PeekabooAgentService)?.snapshotExecutionGate
                    ?? fallbackSnapshotExecutionGate,
                executionPolicy: .backgroundOnly)
        }

        ToolRegistry.configureDefaultServices { [unowned services = self] in
            services
        }
    }
}
