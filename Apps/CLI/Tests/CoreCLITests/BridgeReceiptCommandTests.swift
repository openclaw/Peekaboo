import Commander
import Foundation
import PeekabooBridge
import PeekabooBridgeTestSupport
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
        #expect(report.terminalReceiptAttested)
        #expect(report.targetAttested)
        #expect(!report.outcomeAttested)
    }

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
    func `legacy or incomplete bundle refuses before trust validation`() {
        let data = Data(#"{"operationAttestation":{}}"#.utf8)

        #expect(throws: BridgeReceiptValidationError.unsupportedProtocol) {
            _ = try BridgeReceiptVerifier.validate(
                data: data,
                trustAnchor: .listenerPublicKey(Data(repeating: 0, count: 32))
            )
        }
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

        await #expect(throws: BridgeReceiptValidationError.self) {
            _ = try await BridgeReceiptVerifier.validate(
                bundlePath: bundle.path,
                bridgeSocket: "/private/tmp/missing-bridge.sock",
                trustedHostTeamIDs: []
            )
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundle.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)
        await #expect(throws: BridgeReceiptValidationError.self) {
            _ = try await BridgeReceiptVerifier.validate(
                bundlePath: link.path,
                bridgeSocket: "/private/tmp/missing-bridge.sock",
                trustedHostTeamIDs: []
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

    private static func decodeBundle(_ data: Data) throws -> PeekabooBridgeOperationReceiptBundle {
        try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeOperationReceiptBundle.self, from: data)
    }
}
