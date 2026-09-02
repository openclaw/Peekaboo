import Commander
import Foundation
import PeekabooBridge
import PeekabooBridgeTestSupport
import PeekabooCore
import Testing
@testable import PeekabooCLI

@MainActor
struct BridgeReceiptCommandTests {
    @Test
    func `validator binds exact socket trust teams and global JSON output`() throws {
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: BridgeCommand.ValidateSubcommand.self,
            parsedValues: ParsedValues(
                positional: [],
                options: [
                    "bundle": ["/private/tmp/receipt.json"],
                    "bridge-socket": ["/private/tmp/bridge.sock"],
                    "trustedHostTeamIDs": ["TEAMONE", "TEAMTWO"],
                ],
                flags: ["jsonOutput"]
            )
        )

        #expect(command.bundle == "/private/tmp/receipt.json")
        #expect(command.bridgeSocket == "/private/tmp/bridge.sock")
        #expect(command.trustedHostTeamIDs == ["TEAMONE", "TEAMTWO"])
        #expect(command.jsonOutput)
    }

    @Test
    func `Commander resolves nested anchored receipt validation`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let invocation = try Program(descriptors: descriptors.map(\.metadata)).resolve(argv: [
            "peekaboo", "bridge", "receipt", "validate",
            "--bundle", "/private/tmp/receipt.json",
            "--bridge-socket", "/private/tmp/bridge.sock",
            "--trusted-host-team-id", "TEAMONE",
            "--trusted-host-team-id", "TEAMTWO",
            "--json",
        ])

        #expect(invocation.path == ["bridge", "receipt", "validate"])
        #expect(invocation.parsedValues.options["bundle"] == ["/private/tmp/receipt.json"])
        #expect(invocation.parsedValues.options["bridge-socket"] == ["/private/tmp/bridge.sock"])
        #expect(invocation.parsedValues.options["trustedHostTeamIDs"] == ["TEAMONE", "TEAMTWO"])
        #expect(invocation.parsedValues.flags.contains("jsonOutput"))
    }

    @Test
    func `help requires an exact authenticated listener socket`() {
        #expect(BridgeCommand.helpMessage().contains("bridge receipt validate"))
        let help = BridgeCommand.ValidateSubcommand.helpMessage()
        #expect(help.contains("--bundle"))
        #expect(help.contains("--bridge-socket"))
        #expect(help.contains("--trusted-host-team-id"))
    }

    @Test
    func `matching authenticated listener accepts signed read-only bundle with truthful nil outcome`() throws {
        let data = try Self.fixtureData("valid-read-only-receipt")
        let bundle = try Self.decodeBundle(data)

        let report = try BridgeReceiptVerifier.validate(
            data: data,
            trustAnchor: .listenerAttestation(bundle.operationAttestation)
        )

        #expect(report.valid)
        #expect(report.trustSource == "authenticated_live_listener")
        #expect(report.operation == "permissionsStatus")
        #expect(report.hostSourceCommit == nil)
        #expect(report.hostProtocolVersion == nil)
        #expect(report.terminalReceiptAttested)
        #expect(report.targetAttested)
        #expect(!report.outcomeAttested)
    }

    #if DEBUG
    @Test
    func `validator authenticates a live listener independently from the exported bundle`() async throws {
        try await CLIBridgeHostFixture.withHosts { fixture in
            let root = fixture.desktop.root
            let socketPath = root.appendingPathComponent("bridge.sock").path
            let exportDirectory = root.appendingPathComponent("exports", isDirectory: true)

            let server = PeekabooBridgeServer(
                services: CLISnapshotBridgeServices(snapshots: InMemorySnapshotManager(), directory: root),
                allowlistedTeams: [],
                allowlistedBundles: [],
                allowedOperations: [.permissionsStatus],
                desktopOperationLaneCoordinator: fixture.desktop.laneCoordinator,
                screenCaptureKitProcessCapabilityRegistrar: {},
                screenCaptureKitOwnershipPreparer: {},
                screenCaptureKitOwnerClaimProvider: CLISnapshotBridgeServices.unexpectedScreenCaptureKitClaim,
                permissionStatusEvaluator: { _ in CLISnapshotBridgeServices.grantedPermissions() }
            )
            let host = PeekabooBridgeHost(
                socketPath: socketPath,
                server: server,
                allowedTeamIDs: [],
                requestTimeoutSec: 2
            )
            try await fixture.start(host)

            let exportingClient = BridgeTestFixtures.authenticatedClient(
                socketPath: socketPath,
                requestTimeoutSec: 2,
                operationReceiptExportDirectory: exportDirectory
            )
            let handshake = try await exportingClient.handshake(client: BridgeDiagnostics.currentClientIdentity())
            _ = try await exportingClient.permissionsStatus()
            let bundle = try #require(await exportingClient.lastOperationReceiptBundle())
            let bundlePath = exportDirectory
                .appendingPathComponent(bundle.receipt.payload.requestID.uuidString.lowercased())
                .appendingPathExtension("json")
                .path

            let report = try await BridgeReceiptVerifier.validate(
                bundlePath: bundlePath,
                bridgeSocket: socketPath,
                trustedHostTeamIDs: [BridgeTestFixtures.authenticatedHostTeamIdentifier],
                makeClient: Self.authenticatedClient
            )

            #expect(report.valid)
            #expect(report.trustSource == "authenticated_live_listener")
            #expect(report.listenerInstanceID == bundle.operationAttestation.listenerInstanceID.uuidString.lowercased())
            #expect(report.operation == PeekabooBridgeOperation.permissionsStatus.rawValue)
            #expect(report.hostSourceCommit == handshake.hostIdentity?.sourceCommit)
            #expect(
                report.hostProtocolVersion ==
                    "\(handshake.negotiatedVersion.major).\(handshake.negotiatedVersion.minor)"
            )

            await host.stop()
            await host.waitUntilFullyStopped()
            try await host.startChecked()
            await #expect(throws: BridgeReceiptValidationError.invalidBundle) {
                _ = try await BridgeReceiptVerifier.validate(
                    bundlePath: bundlePath,
                    bridgeSocket: socketPath,
                    trustedHostTeamIDs: [BridgeTestFixtures.authenticatedHostTeamIdentifier],
                    makeClient: Self.authenticatedClient
                )
            }
        }
    }
    #endif

    @Test
    func `different valid listener rejects an otherwise valid bundle`() throws {
        let data = try Self.fixtureData("valid-read-only-receipt")
        let otherListener = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeListenerAttestation.self,
            from: Self.fixtureData("other-listener-attestation")
        )

        #expect(throws: BridgeReceiptValidationError.invalidBundle) {
            _ = try BridgeReceiptVerifier.validate(
                data: data,
                trustAnchor: .listenerAttestation(otherListener)
            )
        }
    }

    @Test
    func `matching listener still rejects canonical response tampering`() throws {
        let data = try Self.fixtureData("valid-read-only-receipt")
        let bundle = try Self.decodeBundle(data)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["canonicalResponse"] = Data(#"{"permissionsStatus":{}}"#.utf8).base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        #expect(throws: BridgeReceiptValidationError.invalidBundle) {
            _ = try BridgeReceiptVerifier.validate(
                data: tampered,
                trustAnchor: .listenerAttestation(bundle.operationAttestation)
            )
        }
    }

    @Test
    func `legacy and unattested handshakes cannot become trust anchors`() throws {
        let legacy = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 28),
            supportedOperations: []
        )
        #expect(throws: BridgeReceiptValidationError.unsupportedProtocol) {
            _ = try BridgeReceiptVerifier.trustAnchor(from: legacy)
        }

        let unattested = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.attestedOperationReceiptVersion,
            supportedOperations: []
        )
        #expect(throws: BridgeReceiptValidationError.listenerTrustUnavailable) {
            _ = try BridgeReceiptVerifier.trustAnchor(from: unattested)
        }
    }

    @Test
    func `legacy or incomplete bundle reports its local schema failure`() {
        let data = Data(#"{"operationAttestation":{}}"#.utf8)

        #expect(throws: BridgeReceiptValidationError.invalidBundleSchema) {
            _ = try BridgeReceiptVerifier.validate(
                data: data,
                trustAnchor: .listenerPublicKey(Data(repeating: 0, count: 32))
            )
        }
    }

    @Test
    func `incomplete private bundle fails before client construction`() async throws {
        let bundle = try Self.privateBundleFile(Data(#"{"operationAttestation":{}}"#.utf8))
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        var clientConstructed = false

        await #expect(throws: BridgeReceiptValidationError.invalidBundleSchema) {
            _ = try await BridgeReceiptVerifier.validate(
                bundlePath: bundle.path,
                bridgeSocket: "/private/tmp/missing-bridge.sock",
                trustedHostTeamIDs: ["TEAMID"],
                makeClient: { socketPath, timeout, teams in
                    clientConstructed = true
                    return PeekabooBridgeClient(
                        socketPath: socketPath,
                        requestTimeoutSec: timeout,
                        trustedHostTeamIDs: teams
                    )
                }
            )
        }
        #expect(!clientConstructed)
    }

    @Test
    func `custom socket without explicit trust fails before bundle access or client construction`() async {
        let missingBundle = "/private/tmp/missing-receipt-\(UUID().uuidString).json"
        var clientConstructed = false

        await #expect(throws: BridgeReceiptValidationError.missingTrustedHostTeamIDForCustomSocket) {
            _ = try await BridgeReceiptVerifier.validate(
                bundlePath: missingBundle,
                bridgeSocket: "/private/tmp/custom-bridge-\(UUID().uuidString).sock",
                trustedHostTeamIDs: [],
                makeClient: { socketPath, timeout, teams in
                    clientConstructed = true
                    return PeekabooBridgeClient(
                        socketPath: socketPath,
                        requestTimeoutSec: timeout,
                        trustedHostTeamIDs: teams
                    )
                }
            )
        }
        #expect(!clientConstructed)
    }

    @Test
    func `receipt validator reuses canonical socket trust policy and normalizes explicit teams`() throws {
        #expect(
            try BridgeReceiptVerifier.trustedHostTeamIDs(
                for: PeekabooBridgeConstants.peekabooSocketPath,
                explicitValues: []
            ) == PeekabooBridgeConstants.trustedReleaseTeamIDs
        )
        #expect(
            try BridgeReceiptVerifier.trustedHostTeamIDs(
                for: (PeekabooBridgeConstants.peekabooSocketPath as NSString).abbreviatingWithTildeInPath,
                explicitValues: []
            ) == PeekabooBridgeConstants.trustedReleaseTeamIDs
        )
        #expect(
            try BridgeReceiptVerifier.trustedHostTeamIDs(
                for: "/private/tmp/custom.sock",
                explicitValues: [" TEAMONE ", "TEAMTWO"]
            ) == ["TEAMONE", "TEAMTWO"]
        )
        #expect(throws: BridgeReceiptValidationError.invalidTrustedHostTeamID) {
            _ = try BridgeReceiptVerifier.trustedHostTeamIDs(
                for: "/private/tmp/custom.sock",
                explicitValues: ["   "]
            )
        }
        #expect(throws: BridgeReceiptValidationError.missingTrustedHostTeamIDForCustomSocket) {
            _ = try BridgeReceiptVerifier.trustedHostTeamIDs(
                for: "/private/tmp/custom.sock",
                explicitValues: []
            )
        }
    }

    @Test
    func `validator expands tilde bundle and socket paths before file or client access`() async throws {
        let relativeRoot = ".peekaboo-receipt-path-tests-\(UUID().uuidString)"
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            relativeRoot,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("bundle.json")
        try Self.fixtureData("valid-read-only-receipt").write(to: bundle)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundle.path)
        let expectedSocket = root.appendingPathComponent("missing.sock").path
        var receivedSocket: String?

        await #expect(throws: (any Error).self) {
            _ = try await BridgeReceiptVerifier.validate(
                bundlePath: "~/\(relativeRoot)/bundle.json",
                bridgeSocket: "~/\(relativeRoot)/missing.sock",
                trustedHostTeamIDs: ["TEAMID"],
                makeClient: { socketPath, timeout, teams in
                    receivedSocket = socketPath
                    return PeekabooBridgeClient(
                        socketPath: socketPath,
                        requestTimeoutSec: timeout,
                        trustedHostTeamIDs: teams
                    )
                }
            )
        }
        #expect(receivedSocket == expectedSocket)
    }

    @Test
    func `bundle file must be private and cannot be a symlink`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-receipt-file-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("bundle.json")
        let link = directory.appendingPathComponent("bundle-link.json")
        try Data("{}".utf8).write(to: bundle)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bundle.path)

        await #expect(throws: BridgeReceiptValidationError.unsafeBundleFile(
            "file must be owner-private, regular, nonempty, and at most 256 MiB"
        )) {
            _ = try await BridgeReceiptVerifier.validate(
                bundlePath: bundle.path,
                bridgeSocket: "/private/tmp/missing-bridge.sock",
                trustedHostTeamIDs: ["TEAMID"]
            )
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundle.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)
        await #expect(throws: BridgeReceiptValidationError.unsafeBundleFile(
            "symbolic links are not accepted"
        )) {
            _ = try await BridgeReceiptVerifier.validate(
                bundlePath: link.path,
                bridgeSocket: "/private/tmp/missing-bridge.sock",
                trustedHostTeamIDs: ["TEAMID"]
            )
        }
    }

    @Test
    func `bundle file cannot grant access through an extended ACL`() async throws {
        let bundle = try Self.privateBundleFile(Data("{}".utf8))
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        try Self.addReadableACL(to: bundle)

        await #expect(throws: BridgeReceiptValidationError.unsafeBundleFile(
            "extended access-control entries are not accepted"
        )) {
            _ = try await BridgeReceiptVerifier.validate(
                bundlePath: bundle.path,
                bridgeSocket: "/private/tmp/missing-bridge.sock",
                trustedHostTeamIDs: ["TEAMID"]
            )
        }
    }

    private static func fixtureData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }

    #if DEBUG
    private static func authenticatedClient(
        socketPath: String,
        requestTimeoutSec: TimeInterval,
        trustedHostTeamIDs: Set<String>
    ) -> PeekabooBridgeClient {
        BridgeTestFixtures.authenticatedClient(
            socketPath: socketPath,
            requestTimeoutSec: requestTimeoutSec,
            trustedHostTeamIDs: trustedHostTeamIDs
        )
    }
    #endif

    private static func addReadableACL(to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow read", url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func privateBundleFile(_ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-receipt-preflight-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bundle = directory.appendingPathComponent("bundle.json")
        try data.write(to: bundle)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundle.path)
        return bundle
    }

    private static func decodeBundle(_ data: Data) throws -> PeekabooBridgeOperationReceiptBundle {
        try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeOperationReceiptBundle.self, from: data)
    }
}
