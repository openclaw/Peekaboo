import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
final class OutcomeStubAutomationService: StubAutomationService {
    var actionOutcome: DesktopActionOutcome?
    var hotkeyOutcomeErrorProvider: ((Int) -> (any Error)?)?
    private(set) var outcomeHotkeyCallCount = 0
}

extension OutcomeStubAutomationService: UIAutomationActionOutcomeProviding {
    func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?
    ) async throws -> UIAutomationActionResult<Void> {
        try await self.click(target: target, clickType: clickType, snapshotId: snapshotId)
        return self.outcomeResult(payload: ())
    }

    func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t
    ) async throws -> UIAutomationActionResult<Void> {
        try await self.click(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier
        )
        return self.outcomeResult(payload: ())
    }

    func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity
    ) async throws -> UIAutomationActionResult<Void> {
        try await self.click(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            expectedProcessIdentity: expectedProcessIdentity
        )
        return self.outcomeResult(payload: ())
    }

    func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect
    ) async throws -> UIAutomationActionResult<Void> {
        try await self.click(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds
        )
        return self.outcomeResult(payload: ())
    }

    func typeWithOutcome(
        text: String,
        target: String?,
        clearExisting: Bool,
        typingDelay: Int,
        snapshotId: String?
    ) async throws -> UIAutomationActionResult<Void> {
        try await self.type(
            text: text,
            target: target,
            clearExisting: clearExisting,
            typingDelay: typingDelay,
            snapshotId: snapshotId
        )
        return self.outcomeResult(payload: ())
    }

    func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?
    ) async throws -> UIAutomationActionResult<TypeResult> {
        let payload = try await self.typeActions(actions, cadence: cadence, snapshotId: snapshotId)
        return self.outcomeResult(payload: payload)
    }

    func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: pid_t
    ) async throws -> UIAutomationActionResult<TypeResult> {
        let payload = try await self.typeActions(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier
        )
        return self.outcomeResult(payload: payload)
    }

    func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity
    ) async throws -> UIAutomationActionResult<TypeResult> {
        let payload = try await self.typeActions(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            expectedProcessIdentity: expectedProcessIdentity
        )
        return self.outcomeResult(payload: payload)
    }

    func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedWindowIdentity _: WindowMutationIdentity,
        expectedWindowBounds _: CGRect
    ) async throws -> UIAutomationActionResult<TypeResult> {
        try await self.typeActionsWithOutcome(actions, cadence: cadence, snapshotId: snapshotId)
    }

    func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        target _: ExactWindowKeyboardTarget
    ) async throws -> UIAutomationActionResult<TypeResult> {
        try await self.typeActionsWithOutcome(actions, cadence: cadence, snapshotId: snapshotId)
    }

    func scrollWithOutcome(_ request: ScrollRequest) async throws -> UIAutomationActionResult<Void> {
        try await self.scroll(request)
        return self.outcomeResult(payload: ())
    }

    func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int
    ) async throws -> UIAutomationActionResult<Void> {
        self.outcomeHotkeyCallCount += 1
        if let error = self.hotkeyOutcomeErrorProvider?(self.hotkeyCalls.count + 1) {
            self.hotkeyCalls.append(HotkeyCall(keys: keys, holdDuration: holdDuration))
            throw error
        }
        try await self.hotkey(keys: keys, holdDuration: holdDuration)
        return self.outcomeResult(payload: ())
    }

    func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        targetProcessIdentifier: pid_t
    ) async throws -> UIAutomationActionResult<Void> {
        self.outcomeHotkeyCallCount += 1
        try await self.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            targetProcessIdentifier: targetProcessIdentifier
        )
        return self.outcomeResult(payload: ())
    }

    func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        expectedProcessIdentity: ApplicationProcessIdentity
    ) async throws -> UIAutomationActionResult<Void> {
        self.outcomeHotkeyCallCount += 1
        try await self.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            expectedProcessIdentity: expectedProcessIdentity
        )
        return self.outcomeResult(payload: ())
    }

    func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        expectedWindowIdentity _: WindowMutationIdentity,
        expectedWindowBounds _: CGRect
    ) async throws -> UIAutomationActionResult<Void> {
        try await self.hotkeyWithOutcome(keys: keys, holdDuration: holdDuration)
    }

    func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        target _: ExactWindowKeyboardTarget
    ) async throws -> UIAutomationActionResult<Void> {
        try await self.hotkeyWithOutcome(keys: keys, holdDuration: holdDuration)
    }

    func setValueWithOutcome(
        target: String,
        value: UIElementValue,
        snapshotId: String?
    ) async throws -> UIAutomationActionResult<ElementActionResult> {
        let payload = try await self.setValue(target: target, value: value, snapshotId: snapshotId)
        return self.outcomeResult(payload: payload)
    }

    func performActionWithOutcome(
        target: String,
        actionName: String,
        snapshotId: String?
    ) async throws -> UIAutomationActionResult<ElementActionResult> {
        let payload = try await self.performAction(
            target: target,
            actionName: actionName,
            snapshotId: snapshotId
        )
        return self.outcomeResult(payload: payload)
    }

    private func outcomeResult<Payload: Sendable>(payload: Payload) -> UIAutomationActionResult<Payload> {
        UIAutomationActionResult(payload: payload, outcome: self.actionOutcome)
    }
}
