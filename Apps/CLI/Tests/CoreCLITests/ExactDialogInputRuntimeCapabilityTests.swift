import PeekabooBridge
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct ExactDialogInputRuntimeCapabilityTests {
    @Test
    func `exact input requires protocol operation enablement and distinct host capability`() {
        let capable = Self.handshake(
            operations: [.dialogEnterText, .exactDialogEnterText],
            capabilities: [PeekabooBridgeHostCapability.exactDialogInputExecution]
        )
        let missingCapability = Self.handshake(
            operations: [.dialogEnterText, .exactDialogEnterText],
            capabilities: []
        )
        let missingOperation = Self.handshake(
            operations: [.dialogEnterText],
            capabilities: [PeekabooBridgeHostCapability.exactDialogInputExecution]
        )
        let disabledOperation = Self.handshake(
            operations: [.dialogEnterText, .exactDialogEnterText],
            enabledOperations: [.dialogEnterText],
            capabilities: [PeekabooBridgeHostCapability.exactDialogInputExecution]
        )

        #expect(RuntimeHostResolver.remoteDialogCapabilities(for: capable).exactInput)
        #expect(!RuntimeHostResolver.remoteDialogCapabilities(for: missingCapability).exactInput)
        #expect(!RuntimeHostResolver.remoteDialogCapabilities(for: missingOperation).exactInput)
        #expect(!RuntimeHostResolver.remoteDialogCapabilities(for: disabledOperation).exactInput)
    }

    @Test
    func `old host capability mapping retains legacy input without enabling exact input`() {
        let oldHost = Self.handshake(
            version: .init(major: 1, minor: 26),
            operations: [.dialogEnterText, .exactDialogEnterText],
            capabilities: [PeekabooBridgeHostCapability.exactDialogInputExecution]
        )

        let capabilities = RuntimeHostResolver.remoteDialogCapabilities(for: oldHost)
        #expect(!capabilities.exactInput)
    }

    private static func handshake(
        version: PeekabooBridgeProtocolVersion = PeekabooBridgeConstants.protocolVersion,
        operations: [PeekabooBridgeOperation],
        enabledOperations: [PeekabooBridgeOperation]? = nil,
        capabilities: [String]?
    ) -> PeekabooBridgeHandshakeResponse {
        BridgeTestFixtures.handshake(
            negotiatedVersion: version,
            hostKind: .gui,
            build: nil,
            supportedOperations: operations,
            enabledOperations: enabledOperations ?? operations,
            hostCapabilities: capabilities
        )
    }
}
