import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import Testing

/// Snapshot/authentication fixtures must not initialize native capture, configuration, or AI services.
@MainActor
final class CLISnapshotBridgeServices: PeekabooBridgeServiceProviding {
    static let snapshotOperations: Set<PeekabooBridgeOperation> = [
        .ownsSnapshot, .invalidateImplicitLatestSnapshot, .permissionsStatus,
    ]

    let snapshots: any SnapshotManagerProtocol
    let automation: any UIAutomationServiceProtocol = MockTargetedAutomationService()
    let applications: any ApplicationServiceProtocol
    let dialogs: any DialogServiceProtocol
    let supportsDesktopObservationCaptureEngine = false
    let supportsScreenCaptureKitProcessOwnership = false

    init(snapshots: any SnapshotManagerProtocol, directory: URL) {
        self.snapshots = snapshots
        // Handshake inspects these adapters' false capability flags, without connecting or a local fallback.
        let client = PeekabooBridgeClient(socketPath: directory.appendingPathComponent("absent.sock").path)
        self.applications = RemoteApplicationService(client: client)
        self.dialogs = RemoteDialogService(client: client)
    }

    static func grantedPermissions() -> PermissionsStatus {
        PermissionsStatus(screenRecording: true, accessibility: true, appleScript: true, postEvent: true)
    }

    nonisolated static func unexpectedScreenCaptureKitClaim() throws -> ScreenCaptureKitOwnerLease.OwnerReceipt {
        Issue.record("Snapshot Bridge fixture must not claim ScreenCaptureKit ownership")
        throw POSIXError(.ENOTSUP)
    }

    var permissions: PermissionsService {
        fatalError("Inject the fixture permission evaluator")
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        fatalError("Capture is not advertised by this fixture")
    }

    var desktopObservation: any DesktopObservationServiceProtocol {
        fatalError("Observation is not advertised by this fixture")
    }

    var windows: any WindowManagementServiceProtocol {
        fatalError("Windows are not advertised by this fixture")
    }

    var menu: any MenuServiceProtocol {
        fatalError("Menus are not advertised by this fixture")
    }

    var dock: any DockServiceProtocol {
        fatalError("Dock operations are not advertised by this fixture")
    }
}
