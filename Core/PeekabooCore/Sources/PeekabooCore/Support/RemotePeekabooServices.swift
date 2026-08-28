import CoreGraphics
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

@MainActor
public final class RemotePeekabooServices: PeekabooServiceProviding {
    public let executionHost: PeekabooServiceExecutionHost = .remote
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
        supportsProcessGenerationPinnedInteractions: Bool = false,
        targetedTypeUnavailableReason: String? = nil,
        targetedTypeRequiresEventSynthesizingPermission: Bool = false,
        supportsTargetedClicks: Bool = false,
        supportsStatelessClickVariants: Bool = false,
        supportsTargetedClickAccessibilityValueDelivery: Bool = false,
        targetedClickUnavailableReason: String? = nil,
        targetedClickRequiresEventSynthesizingPermission: Bool = false,
        supportsExactWindowTargetedClicks: Bool = false,
        supportsBackgroundWindowClose: Bool = false,
        supportsPinnedWindowMutations: Bool = false,
        supportsWindowRestore: Bool = false,
        dialogCapabilities: RemoteDialogCapabilities = RemoteDialogCapabilities(),
        supportsBackgroundDialogClick: Bool = false,
        supportsTargetedScroll: Bool = false,
        supportsRequestPinnedExactWindowScrollReceipt: Bool = false,
        supportsInspectAccessibilityTree: Bool = false,
        inspectAccessibilityTreeUnavailableReason: String? = nil,
        supportsExactWindowTargetedKeyboard: Bool = false,
        exactWindowTargetedKeyboardUnavailableReason: String? = nil,
        supportsExactWindowCompositeTypeDelivery: Bool = false,
        exactWindowCompositeTypeDeliveryUnavailableReason: String? = nil,
        supportsExactWindowPixelFocusTyping: Bool = false,
        exactWindowPixelFocusTypingUnavailableReason: String? = nil,
        supportsForegroundModifierClick: Bool = false,
        foregroundModifierClickUnavailableReason: String? = nil,
        supportsExactWindowHeldPointerLifecycle: Bool = false,
        supportsPostEventPermissionRequest: Bool = false,
        supportsElementActions: Bool = false,
        supportsSetValueResultTargetBinding: Bool = false,
        supportsDesktopObservation: Bool = false,
        supportsDesktopObservationOCR: Bool = false,
        supportsDesktopObservationCaptureEngine: Bool = false,
        supportsExactWindowROIObservation: Bool = false,
        supportsImplicitLatestSnapshotInvalidation: Bool = false,
        supportsSnapshotMutationLeases: Bool = false,
        supportsExplicitSnapshotPublication: Bool = false,
        supportsProducerBoundSnapshotReferences: Bool = false,
        supportsApplicationLaunchOptions: Bool = false,
        supportsSafeBackgroundApplicationLaunchNoOp: Bool = false,
        supportsNewApplicationInstanceLaunch: Bool = false,
        supportsApplicationWindowReadiness: Bool = false,
        supportsApplicationRelaunch: Bool = false,
        supportsProcessGenerationPinnedApplicationQuit: Bool = false,
        supportsProcessGenerationPinnedApplicationActivation: Bool = false,
        supportsProcessGenerationPinnedApplicationHide: Bool = false,
        allowLocalApplicationFallback: Bool = false,
        browserSessionTransport: (any RemoteBrowserMCPSessionTransport)? = nil,
        desktopMutationWatermarkStore: DesktopMutationWatermarkStore? = nil)
    {
        self.client = client
        self.supportsPostEventPermissionRequest = supportsPostEventPermissionRequest
        let supportsRemoteDesktopObservationOCR = supportsDesktopObservation && supportsDesktopObservationOCR
        let supportsRemoteCaptureEnginePreference = supportsDesktopObservation &&
            supportsDesktopObservationCaptureEngine

        self.logging = LoggingService()
        self.screenCapture = RemoteScreenCaptureService(client: client)
        self.applications = RemoteApplicationService(
            client: client,
            localFallback: allowLocalApplicationFallback ? ApplicationService() : nil,
            supportsLaunchOptions: supportsApplicationLaunchOptions,
            supportsSafeBackgroundLaunchNoOp: supportsSafeBackgroundApplicationLaunchNoOp,
            supportsNewInstanceLaunch: supportsNewApplicationInstanceLaunch,
            supportsWindowReadiness: supportsApplicationWindowReadiness,
            supportsRelaunch: supportsApplicationRelaunch,
            supportsPinnedQuit: supportsProcessGenerationPinnedApplicationQuit,
            supportsPinnedActivation: supportsProcessGenerationPinnedApplicationActivation,
            supportsPinnedHide: supportsProcessGenerationPinnedApplicationHide)
        self.automation = if supportsElementActions {
            RemoteElementActionUIAutomationService(
                client: client,
                supportsTargetedHotkeys: supportsTargetedHotkeys,
                supportsProcessGenerationPinnedHotkeys: supportsProcessGenerationPinnedHotkeys,
                targetedHotkeyUnavailableReason: targetedHotkeyUnavailableReason,
                targetedHotkeyRequiresEventSynthesizingPermission: targetedHotkeyRequiresEventSynthesizingPermission,
                supportsTargetedTypeActions: supportsTargetedTypeActions,
                supportsProcessGenerationPinnedTypeActions: supportsProcessGenerationPinnedInteractions &&
                    supportsTargetedTypeActions,
                targetedTypeUnavailableReason: targetedTypeUnavailableReason,
                targetedTypeRequiresEventSynthesizingPermission: targetedTypeRequiresEventSynthesizingPermission,
                supportsTargetedClicks: supportsTargetedClicks,
                supportsProcessGenerationPinnedClicks: supportsProcessGenerationPinnedInteractions &&
                    supportsTargetedClicks,
                supportsStatelessClickVariants: supportsStatelessClickVariants,
                supportsTargetedClickAccessibilityValueDelivery: supportsTargetedClickAccessibilityValueDelivery,
                targetedClickUnavailableReason: targetedClickUnavailableReason,
                targetedClickRequiresEventSynthesizingPermission: targetedClickRequiresEventSynthesizingPermission,
                supportsExactWindowTargetedClicks: supportsExactWindowTargetedClicks,
                supportsTargetedScroll: supportsTargetedScroll,
                supportsRequestPinnedExactWindowScrollReceipt: supportsRequestPinnedExactWindowScrollReceipt,
                supportsInspectAccessibilityTree: supportsInspectAccessibilityTree,
                inspectAccessibilityTreeUnavailableReason: inspectAccessibilityTreeUnavailableReason,
                supportsExactWindowTargetedKeyboard: supportsExactWindowTargetedKeyboard,
                exactWindowTargetedKeyboardUnavailableReason: exactWindowTargetedKeyboardUnavailableReason,
                supportsExactWindowCompositeTypeDelivery: supportsExactWindowCompositeTypeDelivery,
                exactWindowCompositeTypeDeliveryUnavailableReason: exactWindowCompositeTypeDeliveryUnavailableReason,
                supportsExactWindowPixelFocusTyping: supportsExactWindowPixelFocusTyping,
                exactWindowPixelFocusTypingUnavailableReason: exactWindowPixelFocusTypingUnavailableReason,
                supportsForegroundModifierClick: supportsForegroundModifierClick,
                foregroundModifierClickUnavailableReason: foregroundModifierClickUnavailableReason,
                supportsExactWindowHeldPointerLifecycle: supportsExactWindowHeldPointerLifecycle,
                supportsSetValueResultTargetBinding: supportsSetValueResultTargetBinding)
        } else {
            RemoteUIAutomationService(
                client: client,
                supportsTargetedHotkeys: supportsTargetedHotkeys,
                supportsProcessGenerationPinnedHotkeys: supportsProcessGenerationPinnedHotkeys,
                targetedHotkeyUnavailableReason: targetedHotkeyUnavailableReason,
                targetedHotkeyRequiresEventSynthesizingPermission: targetedHotkeyRequiresEventSynthesizingPermission,
                supportsTargetedTypeActions: supportsTargetedTypeActions,
                supportsProcessGenerationPinnedTypeActions: supportsProcessGenerationPinnedInteractions &&
                    supportsTargetedTypeActions,
                targetedTypeUnavailableReason: targetedTypeUnavailableReason,
                targetedTypeRequiresEventSynthesizingPermission: targetedTypeRequiresEventSynthesizingPermission,
                supportsTargetedClicks: supportsTargetedClicks,
                supportsProcessGenerationPinnedClicks: supportsProcessGenerationPinnedInteractions &&
                    supportsTargetedClicks,
                supportsStatelessClickVariants: supportsStatelessClickVariants,
                supportsTargetedClickAccessibilityValueDelivery: supportsTargetedClickAccessibilityValueDelivery,
                targetedClickUnavailableReason: targetedClickUnavailableReason,
                targetedClickRequiresEventSynthesizingPermission: targetedClickRequiresEventSynthesizingPermission,
                supportsExactWindowTargetedClicks: supportsExactWindowTargetedClicks,
                supportsTargetedScroll: supportsTargetedScroll,
                supportsRequestPinnedExactWindowScrollReceipt: supportsRequestPinnedExactWindowScrollReceipt,
                supportsInspectAccessibilityTree: supportsInspectAccessibilityTree,
                inspectAccessibilityTreeUnavailableReason: inspectAccessibilityTreeUnavailableReason,
                supportsExactWindowTargetedKeyboard: supportsExactWindowTargetedKeyboard,
                exactWindowTargetedKeyboardUnavailableReason: exactWindowTargetedKeyboardUnavailableReason,
                supportsExactWindowCompositeTypeDelivery: supportsExactWindowCompositeTypeDelivery,
                exactWindowCompositeTypeDeliveryUnavailableReason: exactWindowCompositeTypeDeliveryUnavailableReason,
                supportsExactWindowPixelFocusTyping: supportsExactWindowPixelFocusTyping,
                exactWindowPixelFocusTypingUnavailableReason: exactWindowPixelFocusTypingUnavailableReason,
                supportsForegroundModifierClick: supportsForegroundModifierClick,
                foregroundModifierClickUnavailableReason: foregroundModifierClickUnavailableReason,
                supportsExactWindowHeldPointerLifecycle: supportsExactWindowHeldPointerLifecycle)
        }
        self.windows = RemoteWindowManagementService(
            client: client,
            supportsBackgroundClose: supportsBackgroundWindowClose,
            supportsPinnedWindowMutations: supportsPinnedWindowMutations,
            supportsWindowRestore: supportsWindowRestore)
        let snapshotManager = RemoteSnapshotManager(
            client: client,
            supportsImplicitLatestSnapshotInvalidation: supportsImplicitLatestSnapshotInvalidation,
            supportsSnapshotMutationLeases: supportsSnapshotMutationLeases,
            supportsExplicitSnapshotPublication: supportsExplicitSnapshotPublication,
            supportsProducerBoundSnapshotReferences: supportsProducerBoundSnapshotReferences,
            desktopMutationWatermarkStore: desktopMutationWatermarkStore)
        let menuService = RemoteMenuService(client: client)
        let screenService = ScreenService()

        self.desktopObservation = if supportsDesktopObservation {
            RemoteDesktopObservationService(
                client: client,
                supportsDesktopObservationOCR: supportsRemoteDesktopObservationOCR,
                supportsDesktopObservationCaptureEngine: supportsRemoteCaptureEnginePreference,
                supportsExactWindowROIObservation: supportsExactWindowROIObservation)
        } else {
            LegacyRemoteDesktopObservationService(delegate: DesktopObservationService(
                screenCapture: self.screenCapture,
                automation: self.automation,
                applications: self.applications,
                menu: menuService,
                screens: screenService,
                snapshotManager: snapshotManager))
        }
        self.menu = menuService
        self.dock = RemoteDockService(client: client)
        let resolvedDialogCapabilities = RemoteDialogCapabilities(
            backgroundButtonClick: dialogCapabilities.backgroundButtonClick || supportsBackgroundDialogClick,
            targetedList: dialogCapabilities.targetedList,
            prepareAction: dialogCapabilities.prepareAction,
            exactClick: dialogCapabilities.exactClick,
            exactDismiss: dialogCapabilities.exactDismiss,
            exactInput: dialogCapabilities.exactInput,
            backgroundExactInput: dialogCapabilities.backgroundExactInput,
            exactForceDismiss: dialogCapabilities.exactForceDismiss,
            legacyInputFocusPolicy: dialogCapabilities.legacyInputFocusPolicy)
        self.dialogs = RemoteDialogService(client: client, capabilities: resolvedDialogCapabilities)
        self.snapshots = snapshotManager
        self.files = FileService()
        self.clipboard = ClipboardService()
        self.configuration = ConfigurationManager.shared
        self.permissions = PermissionsService()
        self.audioInput = AudioInputService(aiService: PeekabooAIService())
        self.screens = screenService
        self.browser = RemoteBrowserMCPClient(
            client: client,
            sessionTransport: browserSessionTransport)
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
private final class LegacyRemoteDesktopObservationService: DesktopObservationServiceProtocol {
    private let delegate: any DesktopObservationServiceProtocol

    init(delegate: any DesktopObservationServiceProtocol) {
        self.delegate = delegate
    }

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        guard !RemoteDesktopObservationCapabilityPolicy.requiresCaptureEnginePreferenceCapability(request) else {
            throw RemoteDesktopObservationCapabilityPolicy.captureEnginePreferenceUnavailableError()
        }
        guard !RemoteDesktopObservationCapabilityPolicy.requiresOCRCapability(request) else {
            throw RemoteDesktopObservationCapabilityPolicy.ocrUnavailableError()
        }
        guard request.capture.roi == nil else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge host lacks protocol 1.21 exact-window ROI observation support")
        }
        return try await self.delegate.observe(request)
    }
}
