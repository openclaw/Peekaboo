import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore

enum MCPToolTestHelpers {
    static func makeContext(
        automation: (any UIAutomationServiceProtocol)? = nil,
        screenCapture: (any ScreenCaptureServiceProtocol)? = nil,
        applications: (any ApplicationServiceProtocol)? = nil,
        windows: (any WindowManagementServiceProtocol)? = nil,
        dialogs: (any DialogServiceProtocol)? = nil,
        screens: (any ScreenServiceProtocol)? = nil,
        clipboard: (any ClipboardServiceProtocol)? = nil,
        snapshots: (any SnapshotManagerProtocol)? = nil,
        permissionsStatusProvider: (any PermissionsStatusProviding)? = nil,
        snapshotMutationCoordinator: (any MCPToolSnapshotMutationCoordinating)? = nil,
        snapshotExecutionGate: MCPToolSnapshotExecutionGate = MCPToolSnapshotExecutionGate(),
        snapshotOwner: MCPToolSnapshotOwner = MCPToolSnapshotOwner(),
        executionPolicy: MCPToolExecutionPolicy = .backgroundOnly,
        exactWindowMetadataProvider: any ExactWindowMetadataProviding = SystemExactWindowMetadataProvider()) async
        -> MCPToolContext
    {
        await MainActor.run {
            let services = PeekabooServices()
            let resolvedWindows: any WindowManagementServiceProtocol = if let windows {
                windows
            } else if applications != nil {
                EmptyRecordingWindowService()
            } else {
                services.windows
            }
            let resolvedScreens = screens ?? services.screens
            let resolvedSnapshots = snapshots ?? services.snapshots
            return MCPToolContext(
                automation: automation ?? services.automation,
                menu: services.menu,
                windows: resolvedWindows,
                applications: applications ?? services.applications,
                dialogs: dialogs ?? services.dialogs,
                dock: services.dock,
                screenCapture: screenCapture ?? services.screenCapture,
                desktopObservation: DesktopObservationService(
                    screenCapture: screenCapture ?? services.screenCapture,
                    automation: automation ?? services.automation,
                    applications: applications ?? services.applications,
                    screens: resolvedScreens,
                    snapshotManager: snapshots,
                    exactWindowMetadataProvider: exactWindowMetadataProvider),
                snapshots: resolvedSnapshots,
                screens: resolvedScreens,
                agent: services.agent,
                permissions: services.permissions,
                clipboard: clipboard ?? services.clipboard,
                browser: services.browser,
                permissionsStatusProvider: permissionsStatusProvider,
                snapshotMutationCoordinator: snapshotMutationCoordinator,
                snapshotExecutionGate: snapshotExecutionGate,
                snapshotOwner: snapshotOwner,
                executionPolicy: executionPolicy)
        }
    }

    /// Builds a context against the process-compatibility snapshot namespace.
    ///
    /// Tests should use this only when the compatibility contract is the behavior under test. Ordinary tests receive
    /// a fresh owner from ``makeContext`` so implicit snapshots cannot leak between cases.
    static func makeLegacyContext(
        automation: (any UIAutomationServiceProtocol)? = nil,
        screenCapture: (any ScreenCaptureServiceProtocol)? = nil,
        applications: (any ApplicationServiceProtocol)? = nil,
        windows: (any WindowManagementServiceProtocol)? = nil,
        dialogs: (any DialogServiceProtocol)? = nil,
        screens: (any ScreenServiceProtocol)? = nil,
        clipboard: (any ClipboardServiceProtocol)? = nil,
        snapshots: (any SnapshotManagerProtocol)? = nil,
        permissionsStatusProvider: (any PermissionsStatusProviding)? = nil,
        snapshotMutationCoordinator: (any MCPToolSnapshotMutationCoordinating)? = nil,
        snapshotExecutionGate: MCPToolSnapshotExecutionGate = MCPToolSnapshotExecutionGate(),
        executionPolicy: MCPToolExecutionPolicy = .backgroundOnly,
        exactWindowMetadataProvider: any ExactWindowMetadataProviding = SystemExactWindowMetadataProvider()) async
        -> MCPToolContext
    {
        await self.makeContext(
            automation: automation,
            screenCapture: screenCapture,
            applications: applications,
            windows: windows,
            dialogs: dialogs,
            screens: screens,
            clipboard: clipboard,
            snapshots: snapshots,
            permissionsStatusProvider: permissionsStatusProvider,
            snapshotMutationCoordinator: snapshotMutationCoordinator,
            snapshotExecutionGate: snapshotExecutionGate,
            snapshotOwner: .legacyProcess,
            executionPolicy: executionPolicy,
            exactWindowMetadataProvider: exactWindowMetadataProvider)
    }

    static func expectCanonicalOutcomeMetadata(
        _ outcome: DesktopActionOutcome,
        in response: ToolResponse,
        sourceLocation: SourceLocation = #_sourceLocation) throws
    {
        let expected = try MCPToolResponseMetadataProjector.fields(for: outcome.projection)
        let actual = try #require(response.meta?.objectValue, sourceLocation: sourceLocation)
        for (key, value) in expected {
            #expect(
                actual[key] == value,
                "Canonical field \(key) was not preserved",
                sourceLocation: sourceLocation)
        }
    }

    static func expectCanonicalRefusalMetadata(
        reason: DesktopActionOutcome.RefusalReason,
        in response: ToolResponse,
        sourceLocation: SourceLocation = #_sourceLocation) throws
    {
        try self.expectCanonicalOutcomeMetadata(
            .refused(reason: reason),
            in: response,
            sourceLocation: sourceLocation)
    }

    static func withContext<T>(
        automation: (any UIAutomationServiceProtocol)? = nil,
        screenCapture: (any ScreenCaptureServiceProtocol)? = nil,
        applications: (any ApplicationServiceProtocol)? = nil,
        clipboard: (any ClipboardServiceProtocol)? = nil,
        _ operation: () async throws -> T) async rethrows -> T
    {
        let context = await self.makeContext(
            automation: automation,
            screenCapture: screenCapture,
            applications: applications,
            clipboard: clipboard)
        return try await MCPToolContext.withContext(context) {
            try await operation()
        }
    }
}
