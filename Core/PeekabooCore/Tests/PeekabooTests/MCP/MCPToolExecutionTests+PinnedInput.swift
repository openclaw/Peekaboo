import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
extension MockAutomationService {
    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws
    {
        self.targetedClickCalls.append(TargetedClickCall(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: expectedProcessIdentity.processIdentifier,
            targetWindowID: nil,
            expectedProcessIdentity: expectedProcessIdentity))
        if let error = self.pinnedClickError?(target) {
            throw error
        }
    }

    func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> TypeResult
    {
        self.targetedTypeActionsCalls.append(TargetedTypeActionsCall(
            actions: actions,
            cadence: cadence,
            snapshotId: snapshotId,
            targetProcessIdentifier: expectedProcessIdentity.processIdentifier,
            expectedProcessIdentity: expectedProcessIdentity))
        if let error = self.pinnedTypeError?(actions) {
            throw error
        }
        return try await self.typeActions(actions, cadence: cadence, snapshotId: snapshotId)
    }

    func hotkey(
        keys: String,
        holdDuration: Int,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws
    {
        if let currentProcessIdentity,
           currentProcessIdentity(expectedProcessIdentity.processIdentifier) != expectedProcessIdentity
        {
            throw PeekabooError.invalidInput(
                "Background hotkey target process exited or changed process generation")
        }
        self.targetedHotkeyCalls.append(TargetedHotkeyCall(
            keys: keys,
            holdDuration: holdDuration,
            targetProcessIdentifier: expectedProcessIdentity.processIdentifier,
            expectedProcessIdentity: expectedProcessIdentity))
        self.afterPinnedHotkey?()
        if let error = self.pinnedHotkeyError?(keys) {
            throw error
        }
    }
}
