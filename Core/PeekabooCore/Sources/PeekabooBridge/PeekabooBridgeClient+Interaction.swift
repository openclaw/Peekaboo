import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

extension PeekabooBridgeClient {
    public func click(target: ClickTarget, clickType: ClickType, snapshotId: String?) async throws {
        _ = try await self.clickWithOutcome(target: target, clickType: clickType, snapshotId: snapshotId)
    }

    public func type(
        text: String,
        target: String?,
        clearExisting: Bool,
        typingDelay: Int,
        snapshotId: String?) async throws
    {
        _ = try await self.typeWithOutcome(
            text: text,
            target: target,
            clearExisting: clearExisting,
            typingDelay: typingDelay,
            snapshotId: snapshotId)
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?) async throws -> TypeResult
    {
        try await self.typeActionsWithOutcome(actions, cadence: cadence, snapshotId: snapshotId).payload
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> TypeResult
    {
        try await self.typeActionsWithOutcome(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            expectedProcessIdentity: expectedProcessIdentity).payload
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> TypeResult
    {
        try await self.typeActionsWithOutcome(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds).payload
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        target: ExactWindowKeyboardTarget) async throws -> TypeResult
    {
        try await self.typeActionsWithOutcome(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            target: target).payload
    }

    public func getFocusedElement(targetProcessIdentifier: pid_t) async throws -> UIFocusInfo? {
        let expectedIdentity = Self.currentProcessIdentity(targetProcessIdentifier)
        let response = try await self.send(.getFocusedElement(.init(
            targetProcessIdentifier: Int32(targetProcessIdentifier),
            expectedProcessIdentity: expectedIdentity)))
        switch response {
        case let .focusedElement(info):
            return info
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected getFocusedElement response")
        }
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws -> TypeResult
    {
        try await self.typeActionsWithOutcome(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier).payload
    }

    public func setValue(
        target: String,
        value: UIElementValue,
        snapshotId: String?) async throws -> ElementActionResult
    {
        try await self.setValueWithOutcome(target: target, value: value, snapshotId: snapshotId).payload
    }

    public func performAction(target: String, actionName: String, snapshotId: String?) async throws
        -> ElementActionResult
    {
        try await self.performActionWithOutcome(
            target: target,
            actionName: actionName,
            snapshotId: snapshotId).payload
    }

    public func scroll(_ request: ScrollRequest) async throws {
        _ = try await self.scrollWithOutcome(request)
    }

    public func hotkey(keys: String, holdDuration: Int) async throws {
        _ = try await self.hotkeyWithOutcome(keys: keys, holdDuration: holdDuration)
    }

    public func hotkey(keys: String, holdDuration: Int, targetProcessIdentifier: pid_t) async throws {
        _ = try await self.hotkeyWithOutcome(
            keys: keys,
            holdDuration: holdDuration,
            targetProcessIdentifier: targetProcessIdentifier)
    }

    public func hotkey(
        keys: String,
        holdDuration: Int,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws
    {
        _ = try await self.hotkeyWithOutcome(
            keys: keys,
            holdDuration: holdDuration,
            expectedProcessIdentity: expectedProcessIdentity)
    }

    public func hotkey(
        keys: String,
        holdDuration: Int,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws
    {
        _ = try await self.hotkeyWithOutcome(
            keys: keys,
            holdDuration: holdDuration,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds)
    }

    public func hotkey(
        keys: String,
        holdDuration: Int,
        target: ExactWindowKeyboardTarget) async throws
    {
        _ = try await self.hotkeyWithOutcome(
            keys: keys,
            holdDuration: holdDuration,
            target: target)
    }

    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws
    {
        _ = try await self.clickWithOutcome(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier)
    }

    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws
    {
        _ = try await self.clickWithOutcome(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            expectedProcessIdentity: expectedProcessIdentity)
    }

    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws
    {
        _ = try await self.clickWithOutcome(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds)
    }

    public func swipe(
        from: CGPoint,
        to: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws
    {
        let payload = PeekabooBridgeSwipeRequest(from: from, to: to, duration: duration, steps: steps, profile: profile)
        try await self.sendExpectOK(.swipe(payload))
    }

    public func drag(_ request: PeekabooBridgeDragRequest) async throws {
        _ = try await self.dragWithOutcome(request)
    }

    public func dragWithOutcome(
        _ request: PeekabooBridgeDragRequest) async throws -> UIAutomationActionResult<Void>
    {
        try await self.actionResult(
            for: .drag(request),
            expectedResponse: "drag")
        { response in
            guard case .ok = response else { return nil }
            return ()
        }
    }

    public func moveMouse(
        to point: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws
    {
        _ = try await self.moveMouseWithOutcome(
            to: point,
            duration: duration,
            steps: steps,
            profile: profile)
    }

    public func moveMouseWithOutcome(
        to point: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws -> UIAutomationActionResult<Void>
    {
        let payload = PeekabooBridgeMoveMouseRequest(to: point, duration: duration, steps: steps, profile: profile)
        return try await self.actionResult(
            for: .moveMouse(payload),
            expectedResponse: "cursor move")
        { response in
            guard case .ok = response else { return nil }
            return ()
        }
    }

    public func waitForElement(target: ClickTarget, timeout: TimeInterval, snapshotId: String?) async throws
        -> WaitForElementResult
    {
        let payload = PeekabooBridgeWaitRequest(target: target, timeout: timeout, snapshotId: snapshotId)
        let response = try await self.send(.waitForElement(payload))
        switch response {
        case let .waitResult(result):
            return result
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected waitForElement response")
        }
    }
}
