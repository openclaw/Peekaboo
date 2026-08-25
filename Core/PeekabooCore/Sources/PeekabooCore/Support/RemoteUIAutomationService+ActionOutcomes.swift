import CoreGraphics
import Darwin
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

extension RemoteUIAutomationService: UIAutomationActionOutcomeProviding,
UIAutomationGlobalPointerActionResultProviding {
    public func foregroundModifierClickWithOutcome(
        _ request: ForegroundModifierClickRequest) async throws
        -> UIAutomationActionResult<ForegroundModifierClickResult>
    {
        guard self.supportsForegroundModifierClick else {
            throw PeekabooError.serviceUnavailable(
                self.foregroundModifierClickUnavailableReason ??
                    "Remote Bridge host does not support foreground modifier-click")
        }
        return try await self.remoteAction(snapshotId: request.snapshotID) {
            try await self.client.foregroundModifierClickWithOutcome(request)
        }
    }

    public func typeActionsByFocusingPixelWithOutcome(
        _ request: ExactWindowPixelFocusTypeRequest) async throws -> UIAutomationActionResult<TypeResult>
    {
        guard self.supportsExactWindowPixelFocusTyping else {
            throw PeekabooError.serviceUnavailable(
                self.exactWindowPixelFocusTypingUnavailableReason ??
                    "Remote Bridge host does not support atomic exact-window pixel-focus typing")
        }
        return try await self.remoteAction(snapshotId: request.snapshotID) {
            try await self.client.typeActionsByFocusingPixelWithOutcome(request)
        }
    }

    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?) async throws -> UIAutomationActionResult<Void>
    {
        try await self.remoteAction(snapshotId: snapshotId) {
            try await self.client.clickWithOutcome(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId)
        }
    }

    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity,
        allowsAccessibilityValueDelivery: Bool) async throws -> UIAutomationActionResult<Void>
    {
        guard self.supportsProcessGenerationPinnedClicks else {
            throw PeekabooError.serviceUnavailable(
                "Remote bridge host does not support process-generation-pinned background clicks; update the host")
        }
        try self.requireAccessibilityValueDeliveryPolicySupport()
        return try await self.remoteAction(snapshotId: snapshotId) {
            try await self.client.clickWithOutcome(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                expectedProcessIdentity: expectedProcessIdentity,
                allowsAccessibilityValueDelivery: allowsAccessibilityValueDelivery)
        }
    }

    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws -> UIAutomationActionResult<Void>
    {
        try self.requireTargetedClicks()
        return try await self.remoteAction(snapshotId: snapshotId) {
            try await self.client.clickWithOutcome(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                targetProcessIdentifier: targetProcessIdentifier)
        }
    }

    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect,
        allowsAccessibilityValueDelivery: Bool) async throws -> UIAutomationActionResult<Void>
    {
        guard self.supportsExactWindowTargetedClicks else {
            throw PeekabooError.serviceUnavailable(
                "Remote bridge host does not support exact-window background clicks")
        }
        try self.requireAccessibilityValueDeliveryPolicySupport()
        return try await self.remoteAction(snapshotId: snapshotId) {
            try await self.client.clickWithOutcome(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                expectedWindowIdentity: expectedWindowIdentity,
                expectedWindowBounds: expectedWindowBounds,
                allowsAccessibilityValueDelivery: allowsAccessibilityValueDelivery)
        }
    }

    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<Void>
    {
        guard self.supportsProcessGenerationPinnedClicks else {
            throw PeekabooError.serviceUnavailable(
                "Remote bridge host does not support process-generation-pinned background clicks; update the host")
        }
        return try await self.remoteAction(snapshotId: snapshotId) {
            try await self.client.clickWithOutcome(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                expectedProcessIdentity: expectedProcessIdentity)
        }
    }

    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<Void>
    {
        guard self.supportsExactWindowTargetedClicks else {
            throw PeekabooError.serviceUnavailable(
                "Remote bridge host does not support exact-window background clicks")
        }
        try self.requireTargetedClicks()
        return try await self.remoteAction(snapshotId: snapshotId) {
            try await self.client.clickWithOutcome(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                expectedWindowIdentity: expectedWindowIdentity,
                expectedWindowBounds: expectedWindowBounds)
        }
    }

    public func typeWithOutcome(
        text: String,
        target: String?,
        clearExisting: Bool,
        typingDelay: Int,
        snapshotId: String?) async throws -> UIAutomationActionResult<Void>
    {
        try await self.remoteAction(snapshotId: snapshotId) {
            try await self.client.typeWithOutcome(
                text: text,
                target: target,
                clearExisting: clearExisting,
                typingDelay: typingDelay,
                snapshotId: snapshotId)
        }
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?) async throws -> UIAutomationActionResult<TypeResult>
    {
        try await self.remoteAction(snapshotId: snapshotId) {
            try await self.client.typeActionsWithOutcome(
                actions,
                cadence: cadence,
                snapshotId: snapshotId)
        }
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws -> UIAutomationActionResult<TypeResult>
    {
        try self.requireTargetedTypeActions()
        return try await self.remoteAction(snapshotId: snapshotId) {
            try await self.client.typeActionsWithOutcome(
                actions,
                cadence: cadence,
                snapshotId: snapshotId,
                targetProcessIdentifier: targetProcessIdentifier)
        }
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<TypeResult>
    {
        guard self.supportsProcessGenerationPinnedTypeActions else {
            throw PeekabooError.serviceUnavailable(
                "Remote bridge host does not support process-generation-pinned background typing; update the host")
        }
        return try await self.remoteAction(snapshotId: snapshotId) {
            try await self.client.typeActionsWithOutcome(
                actions,
                cadence: cadence,
                snapshotId: snapshotId,
                expectedProcessIdentity: expectedProcessIdentity)
        }
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<TypeResult>
    {
        try self.requireExactWindowKeyboard()
        try self.requireCompositeTypeDeliveryIfNeeded(actions)
        return try await self.remoteAction(snapshotId: snapshotId) {
            try await self.client.typeActionsWithOutcome(
                actions,
                cadence: cadence,
                snapshotId: snapshotId,
                expectedWindowIdentity: expectedWindowIdentity,
                expectedWindowBounds: expectedWindowBounds)
        }
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        target: ExactWindowKeyboardTarget) async throws -> UIAutomationActionResult<TypeResult>
    {
        try self.requireExactWindowKeyboard()
        try self.requireCompositeTypeDeliveryIfNeeded(actions)
        return try await self.remoteAction(snapshotId: snapshotId) {
            try await self.client.typeActionsWithOutcome(
                actions,
                cadence: cadence,
                snapshotId: snapshotId,
                target: target)
        }
    }

    public func scrollWithOutcome(_ request: ScrollRequest) async throws -> UIAutomationActionResult<Void> {
        if !request.foreground,
           !self.supportsTargetedScroll || !self.supportsRequestPinnedExactWindowScrollReceipt
        {
            throw PeekabooError.serviceUnavailable(
                "Remote bridge host cannot preserve exact-window background scroll receipts; relaunch or update " +
                    "Peekaboo.")
        }
        return try await self.remoteAction(snapshotId: request.snapshotId) {
            try await self.client.scrollWithOutcome(request)
        }
    }

    public func dragWithOutcome(_ request: DragOperationRequest) async throws -> UIAutomationActionResult<Void> {
        try await self.remoteAction(snapshotId: nil) {
            try await self.client.dragWithOutcome(PeekabooBridgeDragRequest(request))
        }
    }

    public func moveMouseWithOutcome(
        to: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws -> UIAutomationActionResult<Void>
    {
        try await self.remoteAction(snapshotId: nil) {
            try await self.client.moveMouseWithOutcome(
                to: to,
                duration: duration,
                steps: steps,
                profile: profile)
        }
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int) async throws -> UIAutomationActionResult<Void>
    {
        try await self.remoteAction(snapshotId: nil) {
            try await self.client.hotkeyWithOutcome(keys: keys, holdDuration: holdDuration)
        }
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        targetProcessIdentifier: pid_t) async throws -> UIAutomationActionResult<Void>
    {
        try self.requireTargetedHotkeys()
        return try await self.remoteAction(snapshotId: nil) {
            try await self.client.hotkeyWithOutcome(
                keys: keys,
                holdDuration: holdDuration,
                targetProcessIdentifier: targetProcessIdentifier)
        }
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<Void>
    {
        guard self.supportsProcessGenerationPinnedHotkeys else {
            throw PeekabooError.serviceUnavailable(
                "Remote bridge host does not support process-generation-pinned background hotkeys; " +
                    "use --no-remote or update the host")
        }
        return try await self.remoteAction(snapshotId: nil) {
            try await self.client.hotkeyWithOutcome(
                keys: keys,
                holdDuration: holdDuration,
                expectedProcessIdentity: expectedProcessIdentity)
        }
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<Void>
    {
        try self.requireExactWindowKeyboard()
        return try await self.remoteAction(snapshotId: nil) {
            try await self.client.hotkeyWithOutcome(
                keys: keys,
                holdDuration: holdDuration,
                expectedWindowIdentity: expectedWindowIdentity,
                expectedWindowBounds: expectedWindowBounds)
        }
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        target: ExactWindowKeyboardTarget) async throws -> UIAutomationActionResult<Void>
    {
        try self.requireExactWindowKeyboard()
        return try await self.remoteAction(snapshotId: nil) {
            try await self.client.hotkeyWithOutcome(keys: keys, holdDuration: holdDuration, target: target)
        }
    }

    public func setValueWithOutcome(
        target: String,
        value: UIElementValue,
        snapshotId: String?) async throws -> UIAutomationActionResult<ElementActionResult>
    {
        try await self.remoteAction(snapshotId: snapshotId) {
            try await self.client.setValueWithOutcome(target: target, value: value, snapshotId: snapshotId)
        }
    }

    public func performActionWithOutcome(
        target: String,
        actionName: String,
        snapshotId: String?) async throws -> UIAutomationActionResult<ElementActionResult>
    {
        try await self.remoteAction(snapshotId: snapshotId) {
            try await self.client.performActionWithOutcome(
                target: target,
                actionName: actionName,
                snapshotId: snapshotId)
        }
    }

    private func remoteAction<Payload: Sendable>(
        snapshotId: String?,
        operation: () async throws -> UIAutomationActionResult<Payload>) async throws
        -> UIAutomationActionResult<Payload>
    {
        do {
            return try await operation()
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw Self.automationError(for: envelope, snapshotId: snapshotId)
        }
    }

    private func requireTargetedClicks() throws {
        guard self.supportsTargetedClicks else {
            throw Self.unavailableError(
                reason: self.targetedClickUnavailableReason,
                requiresEventSynthesizingPermission: self.targetedClickRequiresEventSynthesizingPermission,
                fallback: "Remote bridge host does not support background clicks; use --no-remote or update the host")
        }
    }

    private func requireTargetedTypeActions() throws {
        guard self.supportsTargetedTypeActions else {
            throw Self.unavailableError(
                reason: self.targetedTypeUnavailableReason,
                requiresEventSynthesizingPermission: self.targetedTypeRequiresEventSynthesizingPermission,
                fallback: "Remote bridge host does not support background typing; use --no-remote or update the host")
        }
    }

    private func requireTargetedHotkeys() throws {
        guard self.supportsTargetedHotkeys else {
            throw Self.unavailableError(
                reason: self.targetedHotkeyUnavailableReason,
                requiresEventSynthesizingPermission: self.targetedHotkeyRequiresEventSynthesizingPermission,
                fallback: "Remote bridge host does not support background hotkeys; use --no-remote or update the host")
        }
    }

    private func requireExactWindowKeyboard() throws {
        guard self.supportsExactWindowTargetedKeyboard else {
            throw PeekabooError.serviceUnavailable(
                self.exactWindowTargetedKeyboardUnavailableReason ??
                    "Atomic exact-window background keyboard delivery is unavailable")
        }
    }

    private static func unavailableError(
        reason: String?,
        requiresEventSynthesizingPermission: Bool,
        fallback: String) -> PeekabooError
    {
        requiresEventSynthesizingPermission
            ? .permissionDeniedEventSynthesizing
            : .serviceUnavailable(reason ?? fallback)
    }
}
