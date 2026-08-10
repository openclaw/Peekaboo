import CoreGraphics
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

@MainActor
public final class RemotePeekabooServices: PeekabooServiceProviding {
    public let logging: any LoggingServiceProtocol
    public let desktopObservation: any DesktopObservationServiceProtocol
    public let screenCapture: any ScreenCaptureServiceProtocol
    public let applications: any ApplicationServiceProtocol
    public let automation: any UIAutomationServiceProtocol
    public let windows: any WindowManagementServiceProtocol
    public let menu: any MenuServiceProtocol
    public let dock: any DockServiceProtocol
    public let dialogs: any DialogServiceProtocol
    public let snapshots: any SnapshotManagerProtocol
    public let files: any FileServiceProtocol
    public let clipboard: any ClipboardServiceProtocol
    public let configuration: ConfigurationManager
    public let permissions: PermissionsService
    public let audioInput: AudioInputService
    public let screens: any ScreenServiceProtocol
    public let browser: any BrowserMCPClientProviding
    public let agent: (any AgentServiceProtocol)?

    private let client: PeekabooBridgeClient
    private let supportsPostEventPermissionRequest: Bool

    public init(
        client: PeekabooBridgeClient,
        supportsTargetedHotkeys: Bool = false,
        supportsProcessGenerationPinnedHotkeys: Bool = false,
        targetedHotkeyUnavailableReason: String? = nil,
        targetedHotkeyRequiresEventSynthesizingPermission: Bool = false,
        supportsTargetedTypeActions: Bool = false,
        targetedTypeUnavailableReason: String? = nil,
        targetedTypeRequiresEventSynthesizingPermission: Bool = false,
        supportsTargetedClicks: Bool = false,
        targetedClickUnavailableReason: String? = nil,
        targetedClickRequiresEventSynthesizingPermission: Bool = false,
        supportsExactWindowTargetedClicks: Bool = false,
        supportsBackgroundWindowClose: Bool = false,
        supportsPinnedWindowMutations: Bool = false,
        supportsWindowRestore: Bool = false,
        supportsBackgroundDialogClick: Bool = false,
        supportsTargetedScroll: Bool = false,
        supportsInspectAccessibilityTree: Bool = false,
        inspectAccessibilityTreeUnavailableReason: String? = nil,
        supportsExactWindowTargetedKeyboard: Bool = false,
        exactWindowTargetedKeyboardUnavailableReason: String? = nil,
        supportsPostEventPermissionRequest: Bool = false,
        supportsElementActions: Bool = false,
        supportsDesktopObservation: Bool = false,
        supportsExactWindowROIObservation: Bool = false,
        supportsImplicitLatestSnapshotInvalidation: Bool = false,
        supportsApplicationLaunchOptions: Bool = false,
        supportsNewApplicationInstanceLaunch: Bool = false,
        supportsApplicationWindowReadiness: Bool = false,
        supportsApplicationRelaunch: Bool = false,
        supportsProcessGenerationPinnedApplicationQuit: Bool = false,
        allowLocalApplicationFallback: Bool = false,
        desktopMutationWatermarkStore: DesktopMutationWatermarkStore? = nil)
    {
        self.client = client
        self.supportsPostEventPermissionRequest = supportsPostEventPermissionRequest

        self.logging = LoggingService()
        self.screenCapture = RemoteScreenCaptureService(client: client)
        self.applications = RemoteApplicationService(
            client: client,
            localFallback: allowLocalApplicationFallback ? ApplicationService() : nil,
            supportsLaunchOptions: supportsApplicationLaunchOptions,
            supportsNewInstanceLaunch: supportsNewApplicationInstanceLaunch,
            supportsWindowReadiness: supportsApplicationWindowReadiness,
            supportsRelaunch: supportsApplicationRelaunch,
            supportsPinnedQuit: supportsProcessGenerationPinnedApplicationQuit)
        self.automation = if supportsElementActions {
            RemoteElementActionUIAutomationService(
                client: client,
                supportsTargetedHotkeys: supportsTargetedHotkeys,
                supportsProcessGenerationPinnedHotkeys: supportsProcessGenerationPinnedHotkeys,
                targetedHotkeyUnavailableReason: targetedHotkeyUnavailableReason,
                targetedHotkeyRequiresEventSynthesizingPermission: targetedHotkeyRequiresEventSynthesizingPermission,
                supportsTargetedTypeActions: supportsTargetedTypeActions,
                targetedTypeUnavailableReason: targetedTypeUnavailableReason,
                targetedTypeRequiresEventSynthesizingPermission: targetedTypeRequiresEventSynthesizingPermission,
                supportsTargetedClicks: supportsTargetedClicks,
                targetedClickUnavailableReason: targetedClickUnavailableReason,
                targetedClickRequiresEventSynthesizingPermission: targetedClickRequiresEventSynthesizingPermission,
                supportsExactWindowTargetedClicks: supportsExactWindowTargetedClicks,
                supportsTargetedScroll: supportsTargetedScroll,
                supportsInspectAccessibilityTree: supportsInspectAccessibilityTree,
                inspectAccessibilityTreeUnavailableReason: inspectAccessibilityTreeUnavailableReason,
                supportsExactWindowTargetedKeyboard: supportsExactWindowTargetedKeyboard,
                exactWindowTargetedKeyboardUnavailableReason: exactWindowTargetedKeyboardUnavailableReason)
        } else {
            RemoteUIAutomationService(
                client: client,
                supportsTargetedHotkeys: supportsTargetedHotkeys,
                supportsProcessGenerationPinnedHotkeys: supportsProcessGenerationPinnedHotkeys,
                targetedHotkeyUnavailableReason: targetedHotkeyUnavailableReason,
                targetedHotkeyRequiresEventSynthesizingPermission: targetedHotkeyRequiresEventSynthesizingPermission,
                supportsTargetedTypeActions: supportsTargetedTypeActions,
                targetedTypeUnavailableReason: targetedTypeUnavailableReason,
                targetedTypeRequiresEventSynthesizingPermission: targetedTypeRequiresEventSynthesizingPermission,
                supportsTargetedClicks: supportsTargetedClicks,
                targetedClickUnavailableReason: targetedClickUnavailableReason,
                targetedClickRequiresEventSynthesizingPermission: targetedClickRequiresEventSynthesizingPermission,
                supportsExactWindowTargetedClicks: supportsExactWindowTargetedClicks,
                supportsTargetedScroll: supportsTargetedScroll,
                supportsInspectAccessibilityTree: supportsInspectAccessibilityTree,
                inspectAccessibilityTreeUnavailableReason: inspectAccessibilityTreeUnavailableReason,
                supportsExactWindowTargetedKeyboard: supportsExactWindowTargetedKeyboard,
                exactWindowTargetedKeyboardUnavailableReason: exactWindowTargetedKeyboardUnavailableReason)
        }
        self.windows = RemoteWindowManagementService(
            client: client,
            supportsBackgroundClose: supportsBackgroundWindowClose,
            supportsPinnedWindowMutations: supportsPinnedWindowMutations,
            supportsWindowRestore: supportsWindowRestore)
        let snapshotManager = RemoteSnapshotManager(
            client: client,
            supportsImplicitLatestSnapshotInvalidation: supportsImplicitLatestSnapshotInvalidation,
            desktopMutationWatermarkStore: desktopMutationWatermarkStore)
        let menuService = RemoteMenuService(client: client)
        let screenService = ScreenService()

        self.desktopObservation = if supportsDesktopObservation {
            RemoteDesktopObservationService(
                client: client,
                supportsExactWindowROIObservation: supportsExactWindowROIObservation)
        } else {
            ExactWindowROIUnsupportedDesktopObservationService(delegate: DesktopObservationService(
                screenCapture: self.screenCapture,
                automation: self.automation,
                applications: self.applications,
                menu: menuService,
                screens: screenService,
                snapshotManager: snapshotManager))
        }
        self.menu = menuService
        self.dock = RemoteDockService(client: client)
        self.dialogs = RemoteDialogService(
            client: client,
            supportsBackgroundButtonClick: supportsBackgroundDialogClick)
        self.snapshots = snapshotManager
        self.files = FileService()
        self.clipboard = ClipboardService()
        self.configuration = ConfigurationManager.shared
        self.permissions = PermissionsService()
        self.audioInput = AudioInputService(aiService: PeekabooAIService())
        self.screens = screenService
        self.browser = RemoteBrowserMCPClient(client: client)
        self.agent = nil
    }

    public func ensureVisualizerConnection() {
        // Remote helper already holds TCC; no-op for client-side container.
    }

    public func permissionsStatus() async throws -> PermissionsStatus {
        try await self.client.permissionsStatus()
    }

    public func requestPostEventPermission() async throws -> Bool {
        guard self.supportsPostEventPermissionRequest else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: """
                Remote bridge host cannot request Event Synthesizing permission. \
                Update the host or run with --no-remote to request it for the local CLI.
                """)
        }

        return try await self.client.requestPostEventPermission()
    }
}

@MainActor
private final class ExactWindowROIUnsupportedDesktopObservationService: DesktopObservationServiceProtocol {
    private let delegate: any DesktopObservationServiceProtocol

    init(delegate: any DesktopObservationServiceProtocol) {
        self.delegate = delegate
    }

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        guard request.capture.roi == nil else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge host lacks protocol 1.21 exact-window ROI observation support")
        }
        return try await self.delegate.observe(request)
    }
}
