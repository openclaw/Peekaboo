import Foundation

extension PeekabooBridgeOperationResultSemantics.ResponseFamily {
    func matches(_ response: PeekabooBridgeResponse) -> Bool {
        switch (self, response) {
        case (.agentExecutionTrace, .agentExecutionTrace),
             (.application, .application),
             (.applicationMutationInventory, .applicationMutationInventory),
             (.applications, .applications),
             (.bool, .bool),
             (.browserStatus, .browserStatus),
             (.browserToolResponse, .browserToolResponse),
             (.browserSessionBootstrap, .browserSessionBootstrap),
             (.capture, .capture),
             (.clickResult, .clickResult),
             (.daemonStatus, .daemonStatus),
             (.detection, .detection),
             (.desktopObservation, .desktopObservation),
             (.dialogElements, .dialogElements),
             (.dialogInfo, .dialogInfo),
             (.dialogResult, .dialogResult),
             (.dockItem, .dockItem),
             (.dockItems, .dockItems),
             (.elementActionResult, .elementActionResult),
             (.elementDetection, .elementDetection),
             (.focusedElement, .focusedElement),
             (.heldPointerOwner, .exactWindowHeldPointerOwner),
             (.heldPointerReceipt, .exactWindowHeldPointerReceipt),
             (.heldPointerTermination, .exactWindowHeldPointerTermination),
             (.int, .int),
             (.menuBarItems, .menuBarItems),
             (.menuExtras, .menuExtras),
             (.menuStructure, .menuStructure),
             (.modifierClickResult, .foregroundModifierClickResult),
             (.ok, .ok),
             (.permissionsStatus, .permissionsStatus),
             (.processGenerationObservation, .processGenerationObservation),
             (.certificationProducerAttestation, .certificationProducerAttestation),
             (.preparedDialogAction, .preparedDialogAction),
             (.rect, .rect),
             (.snapshotID, .snapshotId),
             (.snapshotMutationLease, .snapshotMutationLease),
             (.snapshots, .snapshots),
             (.typeResult, .typeResult),
             (.waitResult, .waitResult),
             (.window, .window),
             (.windowMutationInventory, .windowMutationInventory),
             (.windows, .windows):
            true
        default:
            false
        }
    }
}
