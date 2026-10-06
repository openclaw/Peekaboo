import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@MainActor
enum BridgeInputCapabilityFixture {
    static func startHost(
        services: any PeekabooBridgeServiceProviding,
        supportedVersions: ClosedRange<PeekabooBridgeProtocolVersion>,
        allowedOperations: Set<PeekabooBridgeOperation>,
        operationLaneCoordinator: DesktopOperationLaneCoordinator = .shared,
        permissions: PermissionsStatus = .init(
            screenRecording: true,
            accessibility: true,
            postEvent: true)) async throws
        -> (host: PeekabooBridgeHost, client: PeekabooBridgeClient)
    {
        let socketPath = "/tmp/peekaboo-input-capability-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: supportedVersions,
            allowedOperations: allowedOperations,
            desktopOperationLaneCoordinator: operationLaneCoordinator,
            permissionStatusEvaluator: { _ in permissions })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        return (host, TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2))
    }

    static func exactTarget() throws -> (
        exactWindow: UIAutomationTarget.ExactWindow,
        keyboardTarget: ExactWindowKeyboardTarget)
    {
        let generation = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 999_999,
            ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: generation,
            capturedBounds: bounds)
        let focused = FocusedElementIdentity(
            processIdentifier: getpid(),
            windowID: identity.windowID,
            role: "AXTextField",
            identifier: "editor",
            frame: CGRect(x: 30, y: 40, width: 120, height: 30))
        return try (
            UIAutomationTarget.ExactWindow(
                identity: identity,
                bounds: bounds,
                focusedElement: focused),
            ExactWindowKeyboardTarget(
                windowIdentity: identity,
                windowBounds: bounds,
                focusedElement: focused))
    }
}
