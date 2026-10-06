import PeekabooFoundation

extension PeekabooBridgeServer {
    func validateExactFileDialogExecutionAccess(_ request: PeekabooBridgeRequest) throws {
        guard request.requiresExactFileDialogExecution else { return }
        guard self.services.dialogs.supportsExactFileDialogExecution,
              PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics,
              let session = PeekabooBridgeRequestContext.negotiatedSessionCapabilities,
              session.protocolVersion >= PeekabooBridgeConstants.exactFileDialogExecutionVersion,
              session.exactFileDialogExecution
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "This Bridge session cannot preserve exact file-dialog execution; no input was sent.",
                hint: "Update and relaunch the selected runtime host before retrying.")
        }
    }
}
