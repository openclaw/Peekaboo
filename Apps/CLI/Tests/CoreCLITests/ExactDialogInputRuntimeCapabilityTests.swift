import PeekabooAutomationKit
import PeekabooBridge
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct ExactDialogForegroundRuntimeCapabilityTests {
    @Test
    func `exact input requires protocol operation enablement and distinct host capability`() {
        let capable = Self.handshake(
            operations: [.dialogEnterText, .exactDialogEnterText, .exactDialogForceDismiss],
            capabilities: [
                PeekabooBridgeHostCapability.exactDialogInputExecution,
                PeekabooBridgeHostCapability.exactForcedDialogDismissExecution,
                PeekabooBridgeHostCapability.dialogInputFocusPolicy,
            ]
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
        let legacyFocusOnly = Self.handshake(
            operations: [.dialogEnterText],
            capabilities: [PeekabooBridgeHostCapability.dialogInputFocusPolicy]
        )

        #expect(RuntimeHostResolver.remoteDialogCapabilities(for: capable).exactInput)
        #expect(RuntimeHostResolver.remoteDialogCapabilities(for: capable).exactForceDismiss)
        #expect(RuntimeHostResolver.remoteDialogCapabilities(for: capable).legacyInputFocusPolicy)
        #expect(!RuntimeHostResolver.remoteDialogCapabilities(for: missingCapability).exactInput)
        #expect(!RuntimeHostResolver.remoteDialogCapabilities(for: missingCapability).exactForceDismiss)
        #expect(!RuntimeHostResolver.remoteDialogCapabilities(for: missingCapability).legacyInputFocusPolicy)
        #expect(!RuntimeHostResolver.remoteDialogCapabilities(for: missingOperation).exactInput)
        #expect(!RuntimeHostResolver.remoteDialogCapabilities(for: disabledOperation).exactInput)
        #expect(!RuntimeHostResolver.remoteDialogCapabilities(for: legacyFocusOnly).exactInput)
        #expect(RuntimeHostResolver.remoteDialogCapabilities(for: legacyFocusOnly).legacyInputFocusPolicy)
    }

    @Test
    func `protocol versions keep 1 27 exact input while gating 1 28 additions`() {
        let oldHost = Self.handshake(
            version: .init(major: 1, minor: 27),
            operations: [.dialogEnterText, .exactDialogEnterText],
            capabilities: [PeekabooBridgeHostCapability.exactDialogInputExecution]
        )

        let capabilities = RuntimeHostResolver.remoteDialogCapabilities(for: oldHost)
        #expect(capabilities.exactInput)
        #expect(!capabilities.exactForceDismiss)
        #expect(!capabilities.legacyInputFocusPolicy)
    }

    @Test
    func `exact forced dismiss enablement requires 1 28 operation enablement and capability`() {
        let operation = PeekabooBridgeOperation.exactDialogForceDismiss
        let capability = PeekabooBridgeHostCapability.exactForcedDialogDismissExecution
        let protocol127 = Self.handshake(
            version: .init(major: 1, minor: 27),
            operations: [operation],
            capabilities: [capability]
        )
        let missingOperation = Self.handshake(
            operations: [.dialogEnterText],
            capabilities: [capability]
        )
        let disabledOperation = Self.handshake(
            operations: [operation],
            enabledOperations: [],
            capabilities: [capability]
        )
        let missingCapability = Self.handshake(
            operations: [operation],
            capabilities: []
        )
        let capable = Self.handshake(
            operations: [operation],
            capabilities: [capability]
        )

        #expect(!RuntimeHostResolver.remoteDialogCapabilities(for: protocol127).exactForceDismiss)
        #expect(!RuntimeHostResolver.remoteDialogCapabilities(for: missingOperation).exactForceDismiss)
        #expect(!RuntimeHostResolver.remoteDialogCapabilities(for: disabledOperation).exactForceDismiss)
        #expect(!RuntimeHostResolver.remoteDialogCapabilities(for: missingCapability).exactForceDismiss)
        #expect(RuntimeHostResolver.remoteDialogCapabilities(for: capable).exactForceDismiss)
    }

    @Test
    func `exact input fallback permissions follow attested receipt mode`() {
        let permissions = PermissionsStatus(
            screenRecording: false,
            accessibility: true,
            postEvent: false
        )
        let attested = Self.handshake(
            operations: [.exactDialogEnterText],
            capabilities: [
                PeekabooBridgeHostCapability.exactDialogInputExecution,
                PeekabooBridgeHostCapability.attestedOperationReceipts,
            ],
            permissions: permissions
        )
        let receiptless129 = Self.handshake(
            operations: [.exactDialogEnterText],
            capabilities: [PeekabooBridgeHostCapability.exactDialogInputExecution],
            permissions: permissions
        )
        let protocol128 = Self.handshake(
            version: .init(major: 1, minor: 28),
            operations: [.exactDialogEnterText],
            capabilities: [PeekabooBridgeHostCapability.exactDialogInputExecution],
            permissions: permissions
        )

        #expect(BridgeCapabilityPolicy.requiredPermissions(
            for: .exactDialogEnterText,
            handshake: attested
        ) == [.accessibility])
        #expect(BridgeCapabilityPolicy.requiredPermissions(
            for: .exactDialogEnterText,
            handshake: receiptless129
        ) == [.accessibility, .postEvent])
        #expect(BridgeCapabilityPolicy.requiredPermissions(
            for: .exactDialogEnterText,
            handshake: protocol128
        ) == [.accessibility, .postEvent])
        #expect(RuntimeHostResolver.remoteDialogCapabilities(for: attested).backgroundExactInput)
        #expect(!RuntimeHostResolver.remoteDialogCapabilities(for: receiptless129).backgroundExactInput)
        #expect(!RuntimeHostResolver.remoteDialogCapabilities(for: protocol128).backgroundExactInput)
    }

    private static func handshake(
        version: PeekabooBridgeProtocolVersion = PeekabooBridgeConstants.protocolVersion,
        operations: [PeekabooBridgeOperation],
        enabledOperations: [PeekabooBridgeOperation]? = nil,
        capabilities: [String]?,
        permissions: PermissionsStatus? = nil
    ) -> PeekabooBridgeHandshakeResponse {
        BridgeTestFixtures.handshake(
            negotiatedVersion: version,
            hostKind: .gui,
            build: nil,
            supportedOperations: operations,
            permissions: permissions,
            enabledOperations: enabledOperations ?? operations,
            hostCapabilities: capabilities
        )
    }
}
