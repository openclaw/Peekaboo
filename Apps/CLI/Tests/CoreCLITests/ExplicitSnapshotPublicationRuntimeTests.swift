import Commander
import PeekabooBridge
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooCLI

struct ExplicitSnapshotPublicationRuntimeTests {
    @Test
    func `exact no-elements receipts require protocol 1_26 explicit publication`() throws {
        let exact = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["windowId": ["42"]],
                flags: ["noElements"]
            ),
            commandType: SeeCommand.self
        )
        let processOnly = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["pid": ["42"]],
                flags: ["noElements"]
            ),
            commandType: SeeCommand.self
        )
        let streamed = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["windowId": ["42"], "path": ["-"]],
                flags: ["noElements"]
            ),
            commandType: SeeCommand.self
        )
        let operations: [PeekabooBridgeOperation] = [.captureScreen, .desktopObservation]
        let oldHost = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 25),
            hostKind: .gui,
            build: "4.1.0",
            supportedOperations: operations,
            enabledOperations: operations,
            hostCapabilities: [PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership]
        )
        let publicationOnlyHost = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.explicitSnapshotPublicationVersion,
            hostKind: .gui,
            build: "current",
            supportedOperations: operations,
            enabledOperations: operations,
            hostCapabilities: [
                PeekabooBridgeHostCapability.explicitSnapshotPublication,
                PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
            ]
        )
        let currentHost = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: "current",
            supportedOperations: operations,
            enabledOperations: operations,
            hostCapabilities: [
                PeekabooBridgeHostCapability.explicitSnapshotPublication,
                PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
            ]
        ).withProducerBoundSnapshotFixture()

        #expect(exact.requiresExplicitSnapshotPublication)
        #expect(!processOnly.requiresExplicitSnapshotPublication)
        #expect(!streamed.requiresExplicitSnapshotPublication)
        #expect(!CommandRuntime.supportsRemoteRequirements(for: oldHost, options: exact))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: oldHost, options: processOnly))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: publicationOnlyHost, options: exact))
        #expect(CommandRuntime.supportsRemoteRequirements(for: currentHost, options: exact))
        #expect(RuntimeHostResolver.requiredHostFailure(
            explicitSocket: "/tmp/old.sock",
            options: exact
        )?.contains("protocol 1.26") == true)
        #expect(RuntimeHostResolver.requiredHostFailure(
            explicitSocket: "/tmp/old.sock",
            options: exact
        )?.contains("Update and relaunch Peekaboo") == true)
    }
}
