import Commander
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct AXOnlySeeRuntimeRoutingTests {
    @Test
    func `AX-only see ignores capture grants but requires selected-host Accessibility`() async throws {
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/bridge.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: ["tree", "noScreenshot"]),
            commandType: SeeCommand.self
        )
        func handshake(accessibility: Bool) -> PeekabooBridgeHandshakeResponse {
            BridgeTestFixtures.handshake(
                negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
                hostKind: .onDemand,
                build: "ax-only-fixture",
                supportedOperations: [.inspectAccessibilityTree],
                permissions: PermissionsStatus(
                    screenRecording: false,
                    accessibility: accessibility,
                    appleScript: false,
                    postEvent: false
                ),
                enabledOperations: [.inspectAccessibilityTree],
                permissionTags: [
                    PeekabooBridgeOperation.inspectAccessibilityTree.rawValue: [.accessibility],
                ]
            ).withProducerBoundSnapshotFixture()
        }

        #expect(!options.requiresDesktopObservation)
        #expect(!options.requiresScreenCapturePermission)
        #expect(!options.requiresScreenCaptureKitOwnerCapability)
        #expect(!options.requiresSilentCapture)
        #expect(options.requiresInspectAccessibilityTree)
        #expect(!RuntimeHostResolver.requiresCallerLocalModernOwnerClaim(options: options, environment: [:]))
        #expect(!RuntimeHostResolver.requiresCallerLocalScreenCaptureKitSafetyCheck(options: options, environment: [:]))
        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: handshake(accessibility: true),
            options: options
        ) != nil)
        #expect(await RuntimeHostResolver.validateRemoteCandidate(
            candidate,
            handshake: handshake(accessibility: false),
            options: options
        ) == nil)
        #expect(BridgeCapabilityPolicy.explicitlyMissingRemotePermissions(
            for: handshake(accessibility: false),
            options: options
        ) == [.accessibility])
    }
}
