import CoreGraphics
import PeekabooCore
import PeekabooFoundation

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
        let bounds = CGRect(x: 10, y: 20, width: 400, height: 300)
        let identity = WindowMutationIdentity(
            windowID: request.target.windowID ?? 73,
            ownerProcessIdentifier: request.target.processIdentifier ?? 42,
            ownerProcessStartIdentity: 9001,
            capturedBounds: bounds
        )
        let provided = self.dismissResult
        return DialogActionResult(
            success: provided?.success ?? true,
            action: provided?.action ?? .dismiss,
            details: provided?.details ?? [:],
            outcome: provided?.outcome ?? .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one
            ),
            targetReceipt: provided?.targetReceipt ?? .init(
                processIdentifier: identity.ownerProcessIdentifier,
                processStartIdentity: identity.ownerProcessStartIdentity,
                windowID: identity.windowID
            ),
            targetWindowIdentity: provided?.targetWindowIdentity ?? identity,
            targetWindowBounds: provided?.targetWindowBounds ?? bounds,
            focusedElement: provided?.focusedElement,
            resolvedTarget: provided?.resolvedTarget
        )
    }
}
