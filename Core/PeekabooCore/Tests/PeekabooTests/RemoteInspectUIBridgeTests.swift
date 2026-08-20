import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation
import Testing
@testable import PeekabooCore

@Suite(.serialized)
struct RemoteInspectUIBridgeTests {
    @Test
    func `remote inspect timeout follows explicit accessibility budget with completion grace`() {
        #expect(RemoteUIAutomationService.inspectAccessibilityTreeRequestTimeoutSeconds(
            accessibilityTimeoutSeconds: nil) == 30)
        #expect(RemoteUIAutomationService.inspectAccessibilityTreeRequestTimeoutSeconds(
            accessibilityTimeoutSeconds: 20) == 30)
        #expect(RemoteUIAutomationService.inspectAccessibilityTreeRequestTimeoutSeconds(
            accessibilityTimeoutSeconds: 60) == 65)
        #expect(RemoteUIAutomationService.inspectAccessibilityTreeRequestTimeoutSeconds(
            accessibilityTimeoutSeconds: .infinity) == 30)
        #expect(RemoteUIAutomationService.inspectAccessibilityTreeRequestTimeoutSeconds(
            accessibilityTimeoutSeconds: -1) == 30)
    }

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
            _ = try await client.handshake(
                client: Self.legacyClientIdentity,
                protocolVersion: PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion)
            let remote = await MainActor.run {
                RemoteUIAutomationService(client: client, supportsInspectAccessibilityTree: true)
            }
            let result = try await remote.inspectAccessibilityTree(
                windowContext: WindowContext(
                    applicationName: "Safari",
                    windowTitle: "Main",
                    accessibilityTimeoutSeconds: 60))

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
            #expect(recorded.2?.accessibilityTimeoutSeconds == 60)
            await host.stop()
        } catch {
            await host.stop()
            throw error
        }
    }

    @Test
    func `signed read only inspection resolves selector constraints from the response`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-read-only-inspect-\(UUID().uuidString).sock"
        let bounds = CGRect(x: 50, y: 75, width: 900, height: 650)
        let windowIdentity = WindowMutationIdentity(
            windowID: 4242,
            ownerProcessIdentifier: 5151,
            ownerProcessStartIdentity: 6161,
            capturedBounds: bounds)
        let resolvedContext = WindowContext(
            applicationName: "Fixture",
            applicationBundleId: "dev.peekaboo.fixture",
            applicationProcessId: windowIdentity.ownerProcessIdentifier,
            windowTitle: "Main",
            windowID: windowIdentity.windowID,
            windowBounds: bounds,
            windowMutationIdentity: windowIdentity)
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                detectionResult: ElementDetectionResult(
                    snapshotId: "signed-read-only",
                    screenshotPath: "",
                    elements: DetectedElements(),
                    metadata: DetectionMetadata(
                        detectionTime: 0,
                        elementCount: 0,
                        method: "stub",
                        windowContext: resolvedContext)))
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
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.remote-inspect-tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil))
        let remote = await MainActor.run {
            RemoteUIAutomationService(client: client, supportsInspectAccessibilityTree: true)
        }
        let selectorContexts = [
            WindowContext(windowID: windowIdentity.windowID),
            WindowContext(
                applicationProcessId: windowIdentity.ownerProcessIdentifier,
                windowID: windowIdentity.windowID),
            WindowContext(
                applicationBundleId: "dev.peekaboo.fixture",
                windowID: windowIdentity.windowID),
        ]

        for selectorContext in selectorContexts {
            let result = try await remote.inspectAccessibilityTreeActionResult(windowContext: selectorContext)
            #expect(result.payload.snapshotId == "signed-read-only")
            #expect(result.outcome == nil)
            #expect(result.targetIdentity?.exactWindow?.identity == windowIdentity)
            #expect(result.targetIdentity?.exactWindow?.bounds == bounds)
            let receipt = try #require(await client.lastOperationReceipt())
            #expect(receipt.payload.operation == .inspectAccessibilityTree)
            #expect(receipt.payload.target == .window(windowIdentity))
        }
        await host.stop()
    }

    @Test
    func `remote web focus inspection preserves signed outcome and exact target`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-web-focus-\(UUID().uuidString).sock"
        let bounds = CGRect(x: 50, y: 75, width: 900, height: 650)
        let windowIdentity = WindowMutationIdentity(
            windowID: 4242,
            ownerProcessIdentifier: 5151,
            ownerProcessStartIdentity: 6161,
            capturedBounds: bounds)
        let windowContext = WindowContext(
            applicationProcessId: windowIdentity.ownerProcessIdentifier,
            windowID: windowIdentity.windowID,
            windowBounds: bounds,
            windowMutationIdentity: windowIdentity,
            shouldFocusWebContent: true)
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                detectionResult: ElementDetectionResult(
                    snapshotId: "signed-web-focus",
                    screenshotPath: "",
                    elements: DetectedElements(),
                    metadata: DetectionMetadata(
                        detectionTime: 0,
                        elementCount: 0,
                        method: "stub",
                        windowContext: windowContext)))
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
                },
                windowOwnerProcessIdentifierProvider: { windowID in
                    windowID == CGWindowID(windowIdentity.windowID)
                        ? windowIdentity.ownerProcessIdentifier
                        : nil
                },
                windowBoundsProvider: { windowID in
                    windowID == CGWindowID(windowIdentity.windowID) ? bounds : nil
                },
                processStartIdentityProvider: { processID in
                    processID == windowIdentity.ownerProcessIdentifier
                        ? windowIdentity.ownerProcessStartIdentity
                        : nil
                })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.remote-inspect-tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil))
        let remote = await MainActor.run {
            RemoteUIAutomationService(client: client, supportsInspectAccessibilityTree: true)
        }

        let result = try await remote.inspectAccessibilityTreeActionResult(windowContext: windowContext)

        #expect(result.payload.snapshotId == "signed-web-focus")
        #expect(result.outcome?.route == .bridge)
        #expect(result.outcome?.state == .dispatchedUnverified)
        #expect(result.outcome?.dispatchState.mutationDispatched == true)
        #expect(result.outcome?.retrySafety == .unsafe)
        #expect(result.targetIdentity?.exactWindow?.identity == windowIdentity)
        #expect(result.targetIdentity?.exactWindow?.bounds == bounds)
        let coalesced = try ObservationActionResultSemantics.coalescedTarget(
            actionTarget: result.targetIdentity,
            payload: result.payload,
            outcome: result.outcome,
            operation: "Remote Inspect UI",
            requiresTarget: true)
        #expect(coalesced?.exactWindow?.identity == windowIdentity)
        #expect(coalesced?.exactWindow?.bounds == bounds)
        await host.stop()
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

    @Test
    func `remote inspect preserves incomplete Accessibility code without a protocol bump`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-incomplete-\(UUID().uuidString).sock"
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                inspectError: PeekabooError.accessibilityIncomplete(
                    "AX tree incomplete. Retry once to obtain a fresh observation."))
        }
        let services = await MainActor.run { InspectUIBridgeServices(automation: automation) }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(
            client: Self.legacyClientIdentity,
            protocolVersion: PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion)
        do {
            _ = try await client.inspectAccessibilityTree(windowContext: nil)
            Issue.record("Expected raw Bridge error")
        } catch let error as PeekabooBridgeErrorEnvelope {
            #expect(error.code == .internalError)
            #expect(error.standardizedErrorCode == .accessibilityIncomplete)
        }

        let remote = await MainActor.run {
            RemoteUIAutomationService(client: client, supportsInspectAccessibilityTree: true)
        }
        do {
            _ = try await remote.inspectAccessibilityTree(windowContext: nil)
            Issue.record("Expected standardized remote error")
        } catch let error as PeekabooError {
            #expect(error.code == .accessibilityIncomplete)
            #expect(error.localizedDescription.contains("fresh observation"))
        }
        await host.stop()
    }

    private static let legacyClientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.remote-inspect-legacy-tests",
        teamIdentifier: nil,
        processIdentifier: getpid(),
        hostname: nil)
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
