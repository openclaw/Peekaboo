import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation
import Testing

@Suite(.serialized)
struct RemoteInspectUIBridgeTests {
    @Test
    func `remote inspect accessibility tree routes through bridge without screenshot payload`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-client-\(UUID().uuidString).sock"
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                detectionResult: ElementDetectionResult(
                    snapshotId: "s",
                    screenshotPath: "/tmp/s.png",
                    elements: DetectedElements(),
                    metadata: DetectionMetadata(
                        detectionTime: 0,
                        elementCount: 0,
                        method: "stub",
                        warnings: [],
                        windowContext: nil,
                        isDialog: false)))
        }
        let services = await MainActor.run { InspectUIBridgeServices(automation: automation) }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: false,
                        accessibility: true,
                        appleScript: false,
                        postEvent: false)
                })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)

        try await host.startChecked()
        do {
            let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
            let remote = await MainActor.run {
                RemoteUIAutomationService(client: client, supportsInspectAccessibilityTree: true)
            }
            let result = try await remote.inspectAccessibilityTree(
                windowContext: WindowContext(applicationName: "Safari", windowTitle: "Main"))

            #expect(result.snapshotId == "s")
            let recorded = await MainActor.run {
                (
                    automation.lastDetectImageDataCount,
                    automation.lastDetectSnapshotId,
                    automation.lastInspectWindowContext)
            }
            #expect(recorded.0 == nil)
            #expect(recorded.1 == nil)
            #expect(recorded.2?.applicationName == "Safari")
            #expect(recorded.2?.windowTitle == "Main")
            await host.stop()
        } catch {
            await host.stop()
            throw error
        }
    }

    @Test
    @MainActor
    func `remote inspect accessibility tree reports unsupported host before bridge request`() async throws {
        let client = PeekabooBridgeClient(
            socketPath: "/tmp/nonexistent-\(UUID().uuidString).sock",
            requestTimeoutSec: 1)
        let remote = RemoteUIAutomationService(client: client, supportsInspectAccessibilityTree: false)

        do {
            _ = try await remote.inspectAccessibilityTree(windowContext: nil)
            Issue.record("Expected service unavailable error")
        } catch let PeekabooError.serviceUnavailable(message) {
            #expect(message.contains("does not support inspect_ui"))
        }
    }
}

@MainActor
private final class InspectUIBridgeServices: PeekabooBridgeServiceProviding {
    private let backing = PeekabooServices()
    private let automationStub: InspectUITestAutomationService

    init(automation: InspectUITestAutomationService) {
        self.automationStub = automation
    }

    var permissions: PermissionsService {
        self.backing.permissions
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        self.backing.screenCapture
    }

    var automation: any UIAutomationServiceProtocol {
        self.automationStub
    }

    var windows: any WindowManagementServiceProtocol {
        self.backing.windows
    }

    var applications: any ApplicationServiceProtocol {
        self.backing.applications
    }

    var menu: any MenuServiceProtocol {
        self.backing.menu
    }

    var dock: any DockServiceProtocol {
        self.backing.dock
    }

    var dialogs: any DialogServiceProtocol {
        self.backing.dialogs
    }

    var snapshots: any SnapshotManagerProtocol {
        self.backing.snapshots
    }

    var desktopObservation: any DesktopObservationServiceProtocol {
        self.backing.desktopObservation
    }
}
