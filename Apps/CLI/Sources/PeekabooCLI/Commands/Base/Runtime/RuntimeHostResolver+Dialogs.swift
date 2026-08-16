import PeekabooBridge
import PeekabooCore

extension RuntimeHostResolver {
    static func remoteDialogCapabilities(
        for handshake: PeekabooBridgeHandshakeResponse
    ) -> RemoteDialogCapabilities {
        let exactInput =
            handshake.negotiatedVersion >= PeekabooBridgeConstants.exactDialogInputExecutionVersion &&
            handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.exactDialogInputExecution) == true
        let exactForceDismiss =
            handshake.negotiatedVersion >= PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion &&
            handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.exactForcedDialogDismissExecution
            ) == true
        let legacyInputFocusPolicy =
            handshake.negotiatedVersion >= PeekabooBridgeConstants.dialogInputFocusPolicyVersion &&
            handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.dialogInputFocusPolicy) == true
        let usesAttestedReceipts =
            handshake.negotiatedVersion >= PeekabooBridgeConstants.attestedOperationReceiptVersion &&
            handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.attestedOperationReceipts) == true
        return RemoteDialogCapabilities(
            backgroundButtonClick: BridgeCapabilityPolicy.supportsOperation(
                .backgroundDialogClickButton,
                for: handshake
            ),
            targetedList: BridgeCapabilityPolicy.supportsOperation(.targetedDialogListElements, for: handshake),
            prepareAction: BridgeCapabilityPolicy.supportsOperation(.prepareDialogAction, for: handshake),
            exactClick: BridgeCapabilityPolicy.supportsOperation(.exactDialogClickButton, for: handshake),
            exactDismiss: BridgeCapabilityPolicy.supportsOperation(.exactDialogDismiss, for: handshake),
            exactInput: exactInput &&
                BridgeCapabilityPolicy.supportsOperation(.exactDialogEnterText, for: handshake),
            backgroundExactInput: usesAttestedReceipts && exactInput &&
                BridgeCapabilityPolicy.supportsOperation(.exactDialogEnterText, for: handshake),
            exactForceDismiss: exactForceDismiss &&
                BridgeCapabilityPolicy.supportsOperation(.exactDialogForceDismiss, for: handshake),
            legacyInputFocusPolicy: legacyInputFocusPolicy &&
                BridgeCapabilityPolicy.supportsOperation(.dialogEnterText, for: handshake)
        )
    }
}
