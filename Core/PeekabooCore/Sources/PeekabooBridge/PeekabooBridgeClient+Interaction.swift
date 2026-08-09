import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

extension PeekabooBridgeClient {
    public func click(target: ClickTarget, clickType: ClickType, snapshotId: String?) async throws {
        let payload = PeekabooBridgeClickRequest(target: target, clickType: clickType, snapshotId: snapshotId)
        try await self.sendExpectOK(.click(payload))
    }

    public func type(
        text: String,
        target: String?,
        clearExisting: Bool,
        typingDelay: Int,
        snapshotId: String?) async throws
    {
        let payload = PeekabooBridgeTypeRequest(
            text: text,
            target: target,
            clearExisting: clearExisting,
            typingDelay: typingDelay,
            snapshotId: snapshotId)
        try await self.sendExpectOK(.type(payload))
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?) async throws -> TypeResult
    {
        let payload = PeekabooBridgeTypeActionsRequest(actions: actions, cadence: cadence, snapshotId: snapshotId)
        let response = try await self.send(.typeActions(payload))
        switch response {
        case let .typeResult(result):
            return result
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected typeActions response")
        }
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws -> TypeResult
    {
        let payload = PeekabooBridgeTargetedTypeActionsRequest(
            actions: actions,
            cadence: cadence,
            snapshotId: snapshotId,
            targetProcessIdentifier: Int32(targetProcessIdentifier))
        let response = try await self.send(.targetedTypeActions(payload))
        switch response {
        case let .typeResult(result):
            return result
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected targetedTypeActions response")
        }
    }

    public func setValue(
        target: String,
        value: UIElementValue,
        snapshotId: String?) async throws -> ElementActionResult
    {
        let payload = PeekabooBridgeSetValueRequest(target: target, value: value, snapshotId: snapshotId)
        let response = try await self.send(.setValue(payload))
        switch response {
        case let .elementActionResult(result):
            return result
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected setValue response")
        }
    }

    public func performAction(target: String, actionName: String, snapshotId: String?) async throws
        -> ElementActionResult
    {
        let payload = PeekabooBridgePerformActionRequest(
            target: target,
            actionName: actionName,
            snapshotId: snapshotId)
        let response = try await self.send(.performAction(payload))
        switch response {
        case let .elementActionResult(result):
            return result
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected performAction response")
        }
    }

    public func scroll(_ request: ScrollRequest) async throws {
        let payload = PeekabooBridgeScrollRequest(request: request)
        try await self.sendExpectOK(request.foreground ? .scroll(payload) : .targetedScroll(payload))
    }

    public func hotkey(keys: String, holdDuration: Int) async throws {
        try await self.sendExpectOK(.hotkey(PeekabooBridgeHotkeyRequest(keys: keys, holdDuration: holdDuration)))
    }

    public func hotkey(keys: String, holdDuration: Int, targetProcessIdentifier: pid_t) async throws {
        try await self.sendExpectOK(
            .targetedHotkey(PeekabooBridgeTargetedHotkeyRequest(
                keys: keys,
                holdDuration: holdDuration,
                targetProcessIdentifier: Int32(targetProcessIdentifier))))
    }

    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws
    {
        try await self.sendExpectOK(
            .targetedClick(PeekabooBridgeTargetedClickRequest(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                targetProcessIdentifier: Int32(targetProcessIdentifier))))
    }

    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t,
        targetWindowID: Int) async throws
    {
        try await self.sendExpectOK(
            .targetedClick(PeekabooBridgeTargetedClickRequest(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                targetProcessIdentifier: Int32(targetProcessIdentifier),
                targetWindowID: targetWindowID)))
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
        try await self.sendExpectOK(.drag(request))
    }

    public func moveMouse(
        to point: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws
    {
        let payload = PeekabooBridgeMoveMouseRequest(to: point, duration: duration, steps: steps, profile: profile)
        try await self.sendExpectOK(.moveMouse(payload))
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
