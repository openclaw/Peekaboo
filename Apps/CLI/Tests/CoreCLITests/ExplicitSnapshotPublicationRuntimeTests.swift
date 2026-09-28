import Commander
import PeekabooBridge
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooCLI

struct ExplicitSnapshotPublicationRuntimeTests {
    @Test
    func `exact no-elements receipts require explicit publication and authenticated producer references`() throws {
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
        let unattestedHost = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 28),
            hostKind: .onDemand,
            build: "current",
            supportedOperations: operations,
            enabledOperations: operations,
            hostCapabilities: publicationOnlyHost.hostCapabilities
        )

        #expect(exact.requiresExplicitSnapshotPublication)
        #expect(!processOnly.requiresExplicitSnapshotPublication)
        #expect(!streamed.requiresExplicitSnapshotPublication)
        #expect(!CommandRuntime.supportsRemoteRequirements(for: oldHost, options: exact))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: oldHost, options: processOnly))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: publicationOnlyHost, options: exact))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: unattestedHost, options: exact))
        #expect(CommandRuntime.supportsRemoteRequirements(for: currentHost, options: exact))
        let failure = try #require(RuntimeHostResolver.requiredHostFailure(
            explicitSocket: "/tmp/old.sock",
            options: exact
        ))
        #expect(failure.contains("protocol 1.34"))
        #expect(failure.contains("authenticated, producer-bound snapshots"))
        #expect(failure.contains("standard socket"))
        #expect(failure.contains("host-signing policy"))
        #expect(!failure.contains("protocol 1.26"))
        #expect(RuntimeHostResolver.requiredHostFailure(explicitSocket: nil, options: exact) == nil)

        var producerOnly = CommandRuntimeOptions()
        producerOnly.requiresProducerBoundSnapshotReferences = true
        #expect(RuntimeHostResolver.requiredHostFailure(
            explicitSocket: "/tmp/old.sock", options: producerOnly
        ) == nil)

        var publicationOnly = CommandRuntimeOptions()
        publicationOnly.requiresExplicitSnapshotPublication = true
        #expect(RuntimeHostResolver.requiredHostFailure(
            explicitSocket: "/tmp/old.sock", options: publicationOnly
        )?.contains("protocol 1.26") == true)
    }
}
