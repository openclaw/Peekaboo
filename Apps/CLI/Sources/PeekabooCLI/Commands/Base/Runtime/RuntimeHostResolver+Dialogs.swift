import PeekabooBridge
import PeekabooCore

extension RuntimeHostResolver {
    static func remoteDialogCapabilities(
        for handshake: PeekabooBridgeHandshakeResponse
    ) -> RemoteDialogCapabilities {
        RemoteDialogCapabilities(
            backgroundButtonClick: BridgeCapabilityPolicy.supportsOperation(
                .backgroundDialogClickButton,
                for: handshake
            ),
            targetedList: BridgeCapabilityPolicy.supportsOperation(.targetedDialogListElements, for: handshake),
            prepareAction: BridgeCapabilityPolicy.supportsOperation(.prepareDialogAction, for: handshake),
            exactClick: BridgeCapabilityPolicy.supportsOperation(.exactDialogClickButton, for: handshake),
            exactDismiss: BridgeCapabilityPolicy.supportsOperation(.exactDialogDismiss, for: handshake),
            exactInput: handshake.negotiatedVersion >= PeekabooBridgeConstants.exactDialogInputExecutionVersion &&
                BridgeCapabilityPolicy.supportsOperation(.exactDialogEnterText, for: handshake) &&
                handshake.hostCapabilities?.contains(
                    PeekabooBridgeHostCapability.exactDialogInputExecution
                ) == true
        )
    }
}
