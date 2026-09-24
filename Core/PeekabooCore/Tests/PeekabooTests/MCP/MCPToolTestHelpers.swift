import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore

enum MCPToolTestHelpers {
    static let elementActionProcessIdentity = ApplicationProcessIdentity(
        processIdentifier: 42,
        processStartIdentity: 1001)

    static func createElementActionSnapshot(
        in snapshots: MCPToolUISnapshotStore,
        processIdentity: ApplicationProcessIdentity = MCPToolTestHelpers.elementActionProcessIdentity) async
        -> UISnapshot
    {
        let snapshot = await snapshots.createSnapshot()
        await snapshot.setTargetMetadata(from: WindowContext(
            applicationProcessId: processIdentity.processIdentifier,
            applicationProcessStartIdentity: processIdentity.processStartIdentity))
        return snapshot
    }

    @MainActor
    static func createElementActionSnapshot(
        in context: MCPToolContext,
        processIdentity: ApplicationProcessIdentity = MCPToolTestHelpers.elementActionProcessIdentity) async throws
        -> UISnapshot
    {
        let snapshot = try await self.createSnapshot(in: context)
        await snapshot.setTargetMetadata(from: WindowContext(
            applicationProcessId: processIdentity.processIdentifier,
            applicationProcessStartIdentity: processIdentity.processStartIdentity))
        try await self.publishSnapshotMetadata(snapshot, in: context)
        return snapshot
    }

    @MainActor
    static func createSnapshot(in context: MCPToolContext) async throws -> UISnapshot {
        guard let producer = context.snapshots as? InMemorySnapshotManager else {
            throw PeekabooError.commandFailed("Paired snapshot fixtures require an explicit in-memory producer")
        }
        let snapshotID = try await producer.createSnapshot()
        return await context.uiSnapshots.createSnapshot(id: snapshotID)
    }

    @MainActor
    static func publishSnapshotMetadata(_ snapshot: UISnapshot, in context: MCPToolContext) async throws {
        guard let producer = context.snapshots as? InMemorySnapshotManager else {
            throw PeekabooError.commandFailed("Paired snapshot fixtures require an explicit in-memory producer")
        }
        let screenshotMetadata = await snapshot.screenshotMetadata
        let windowContext = WindowContext(
            applicationName: snapshot.applicationName,
            applicationBundleId: screenshotMetadata?.applicationInfo?.bundleIdentifier,
            applicationProcessId: snapshot.applicationProcessId,
            applicationProcessStartIdentity: snapshot.applicationProcessIdentity?.processStartIdentity,
            windowTitle: snapshot.windowTitle,
            windowID: snapshot.windowID,
            windowBounds: snapshot.windowBounds,
            windowMutationIdentity: snapshot.windowMutationIdentity,
            focusedElement: snapshot.focusedElement)
        let result = await ElementDetectionResult(
            snapshotId: snapshot.id,
            screenshotPath: snapshot.screenshotPath ?? "/tmp/peekaboo-test.png",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 0,
                method: "paired-test-fixture",
                windowContext: windowContext,
                truncationInfo: nil,
                captureCoordinateContext: snapshot.screenshotCoordinateContext))
        try await producer.storeDetectionResult(snapshotId: snapshot.id, result: result)
    }

    static func makeContext(
        automation: (any UIAutomationServiceProtocol)? = nil,
        screenCapture: (any ScreenCaptureServiceProtocol)? = nil,
        applications: (any ApplicationServiceProtocol)? = nil,
        windows: (any WindowManagementServiceProtocol)? = nil,
        dialogs: (any DialogServiceProtocol)? = nil,
        screens: (any ScreenServiceProtocol)? = nil,
        clipboard: (any ClipboardServiceProtocol)? = nil,
        snapshots: (any SnapshotManagerProtocol)? = nil,
        desktopObservation: (any DesktopObservationServiceProtocol)? = nil,
        permissionsStatusProvider: (any PermissionsStatusProviding)? = nil,
        snapshotMutationCoordinator: (any MCPToolSnapshotMutationCoordinating)? = nil,
        snapshotExecutionGate: MCPToolSnapshotExecutionGate = MCPToolSnapshotExecutionGate(),
        snapshotOwner: MCPToolSnapshotOwner = MCPToolSnapshotOwner(),
        executionPolicy: MCPToolExecutionPolicy = .backgroundOnly,
        exactWindowMetadataProvider: any ExactWindowMetadataProviding = SystemExactWindowMetadataProvider(),
        capturePreflightRefusal: MCPToolCapturePreflightRefusal? = nil) async
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
                desktopObservation: desktopObservation ?? DesktopObservationService(
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
                executionPolicy: executionPolicy,
                capturePreflightRefusal: capturePreflightRefusal)
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
        desktopObservation: (any DesktopObservationServiceProtocol)? = nil,
        permissionsStatusProvider: (any PermissionsStatusProviding)? = nil,
        snapshotMutationCoordinator: (any MCPToolSnapshotMutationCoordinating)? = nil,
        snapshotExecutionGate: MCPToolSnapshotExecutionGate = MCPToolSnapshotExecutionGate(),
        executionPolicy: MCPToolExecutionPolicy = .backgroundOnly,
        exactWindowMetadataProvider: any ExactWindowMetadataProviding = SystemExactWindowMetadataProvider(),
        capturePreflightRefusal: MCPToolCapturePreflightRefusal? = nil) async
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
            desktopObservation: desktopObservation,
            permissionsStatusProvider: permissionsStatusProvider,
            snapshotMutationCoordinator: snapshotMutationCoordinator,
            snapshotExecutionGate: snapshotExecutionGate,
            snapshotOwner: .legacyProcess,
            executionPolicy: executionPolicy,
            exactWindowMetadataProvider: exactWindowMetadataProvider,
            capturePreflightRefusal: capturePreflightRefusal)
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

@MainActor
final class MissingDetectionObservationService: DesktopObservationServiceProtocol {
    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        let path = try #require(request.output.path)
        let imageData = Data("see-missing-detection".utf8)
        try imageData.write(to: URL(fileURLWithPath: path), options: .atomic)
        return DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: imageData,
                savedPath: path,
                metadata: CaptureMetadata(
                    size: CGSize(width: 1, height: 1),
                    mode: .screen,
                    timestamp: Date())),
            elements: nil,
            files: DesktopObservationFiles(rawScreenshotPath: path))
    }
}
