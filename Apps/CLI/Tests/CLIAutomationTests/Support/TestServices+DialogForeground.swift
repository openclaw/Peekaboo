import PeekabooCore

@MainActor
extension StubDialogService {
    func enterText(_ request: DialogLegacyInputExecutionRequest) async throws -> DialogActionResult {
        self.legacyInputFocusPolicies.append(request.focus)
        return try await self.enterText(
            text: request.text,
            fieldIdentifier: request.fieldIdentifier,
            clearExisting: request.clearExisting,
            windowTitle: request.windowTitle,
            appName: request.appName
        )
    }

    func forceDismissDialog(_ request: DialogForcedDismissExecutionRequest) async throws -> DialogActionResult {
        self.exactForcedDismissRequests.append(request)
        guard self.dialogElements != nil else {
            throw DialogError.noActiveDialog
        }
        if let result = self.dismissResult {
            return result
        }
        throw DialogError.noDismissButton
    }
}
