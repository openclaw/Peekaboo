import CoreGraphics
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooBridge
import PeekabooFoundation

@MainActor
public class RemoteUIAutomationService: DetectElementsRequestTimeoutAdjusting, TargetedHotkeyServiceProtocol,
    TargetedTypeServiceProtocol,
    ExactWindowTargetedClickServiceProtocol,
    TargetedFocusedElementServiceProtocol,
    ExactWindowTargetedKeyboardServiceProtocol,
    ExactWindowPixelFocusTypingServiceProtocol,
    ForegroundModifierClickServiceProtocol,
    UIAutomationObservationActionResultProviding
{
    let client: PeekabooBridgeClient
    public let supportsTargetedHotkeys: Bool
    public let supportsProcessGenerationPinnedHotkeys: Bool
    public let targetedHotkeyUnavailableReason: String?
    public let targetedHotkeyRequiresEventSynthesizingPermission: Bool
    public let supportsTargetedTypeActions: Bool
    public let supportsProcessGenerationPinnedTypeActions: Bool
    public let targetedTypeUnavailableReason: String?
    public let targetedTypeRequiresEventSynthesizingPermission: Bool
    public let supportsTargetedClicks: Bool
    public let supportsProcessGenerationPinnedClicks: Bool
    public let supportsStatelessClickVariants: Bool
    public let supportsTargetedClickAccessibilityValueDelivery: Bool
    public let targetedClickUnavailableReason: String?
    public let targetedClickRequiresEventSynthesizingPermission: Bool
    public let supportsExactWindowTargetedClicks: Bool
    public let supportsTargetedScroll: Bool
    public let supportsRequestPinnedExactWindowScrollReceipt: Bool
    public let supportsInspectAccessibilityTree: Bool
    public let inspectAccessibilityTreeUnavailableReason: String?
    public let supportsExactWindowTargetedKeyboard: Bool
    public let exactWindowTargetedKeyboardUnavailableReason: String?
    public let supportsExactWindowCompositeTypeDelivery: Bool
    public let exactWindowCompositeTypeDeliveryUnavailableReason: String?
    public let supportsExactWindowPixelFocusTyping: Bool
    public let exactWindowPixelFocusTypingUnavailableReason: String?
    public let supportsForegroundModifierClick: Bool
    public let supportsForegroundModifierClickSnapshotLease: Bool
    public let foregroundModifierClickUnavailableReason: String?
    public let supportsExactWindowHeldPointerLifecycle: Bool
    public let supportsSetValueResultTargetBinding: Bool

    public init(
        client: PeekabooBridgeClient,
        supportsTargetedHotkeys: Bool = false,
        supportsProcessGenerationPinnedHotkeys: Bool = false,
        targetedHotkeyUnavailableReason: String? = nil,
        targetedHotkeyRequiresEventSynthesizingPermission: Bool = false,
        supportsTargetedTypeActions: Bool = false,
        supportsProcessGenerationPinnedTypeActions: Bool = false,
        targetedTypeUnavailableReason: String? = nil,
        targetedTypeRequiresEventSynthesizingPermission: Bool = false,
        supportsTargetedClicks: Bool = false,
        supportsProcessGenerationPinnedClicks: Bool = false,
        supportsStatelessClickVariants: Bool = false,
        supportsTargetedClickAccessibilityValueDelivery: Bool = false,
        targetedClickUnavailableReason: String? = nil,
        targetedClickRequiresEventSynthesizingPermission: Bool = false,
        supportsExactWindowTargetedClicks: Bool = false,
        supportsTargetedScroll: Bool = false,
        supportsRequestPinnedExactWindowScrollReceipt: Bool = false,
        supportsInspectAccessibilityTree: Bool = false,
        inspectAccessibilityTreeUnavailableReason: String? = nil,
        supportsExactWindowTargetedKeyboard: Bool = false,
        exactWindowTargetedKeyboardUnavailableReason: String? = nil,
        supportsExactWindowCompositeTypeDelivery: Bool = false,
        exactWindowCompositeTypeDeliveryUnavailableReason: String? = nil,
        supportsExactWindowPixelFocusTyping: Bool = false,
        exactWindowPixelFocusTypingUnavailableReason: String? = nil,
        supportsForegroundModifierClick: Bool = false,
        foregroundModifierClickUnavailableReason: String? = nil,
        supportsExactWindowHeldPointerLifecycle: Bool = false,
        supportsSetValueResultTargetBinding: Bool = false)
    {
        self.client = client
        self.supportsTargetedHotkeys = supportsTargetedHotkeys
        self.supportsProcessGenerationPinnedHotkeys = supportsProcessGenerationPinnedHotkeys
        self.targetedHotkeyUnavailableReason = targetedHotkeyUnavailableReason
        self.targetedHotkeyRequiresEventSynthesizingPermission = targetedHotkeyRequiresEventSynthesizingPermission
        self.supportsTargetedTypeActions = supportsTargetedTypeActions
        self.supportsProcessGenerationPinnedTypeActions = supportsProcessGenerationPinnedTypeActions
        self.targetedTypeUnavailableReason = targetedTypeUnavailableReason
        self.targetedTypeRequiresEventSynthesizingPermission = targetedTypeRequiresEventSynthesizingPermission
        self.supportsTargetedClicks = supportsTargetedClicks
        self.supportsProcessGenerationPinnedClicks = supportsProcessGenerationPinnedClicks
        self.supportsStatelessClickVariants = supportsStatelessClickVariants
        self.supportsTargetedClickAccessibilityValueDelivery = supportsTargetedClickAccessibilityValueDelivery
        self.targetedClickUnavailableReason = targetedClickUnavailableReason
        self.targetedClickRequiresEventSynthesizingPermission = targetedClickRequiresEventSynthesizingPermission
        self.supportsExactWindowTargetedClicks = supportsExactWindowTargetedClicks
        self.supportsTargetedScroll = supportsTargetedScroll
        self.supportsRequestPinnedExactWindowScrollReceipt = supportsRequestPinnedExactWindowScrollReceipt
        self.supportsInspectAccessibilityTree = supportsInspectAccessibilityTree
        self.inspectAccessibilityTreeUnavailableReason = inspectAccessibilityTreeUnavailableReason
        self.supportsExactWindowTargetedKeyboard = supportsExactWindowTargetedKeyboard
        self.exactWindowTargetedKeyboardUnavailableReason = exactWindowTargetedKeyboardUnavailableReason
        self.supportsExactWindowCompositeTypeDelivery = supportsExactWindowCompositeTypeDelivery
        self.exactWindowCompositeTypeDeliveryUnavailableReason = exactWindowCompositeTypeDeliveryUnavailableReason
        self.supportsExactWindowPixelFocusTyping = supportsExactWindowPixelFocusTyping
        self.exactWindowPixelFocusTypingUnavailableReason = exactWindowPixelFocusTypingUnavailableReason
        self.supportsForegroundModifierClick = supportsForegroundModifierClick
        self.supportsForegroundModifierClickSnapshotLease = supportsForegroundModifierClick
        self.foregroundModifierClickUnavailableReason = foregroundModifierClickUnavailableReason
        self.supportsExactWindowHeldPointerLifecycle = supportsExactWindowHeldPointerLifecycle
        self.supportsSetValueResultTargetBinding = supportsSetValueResultTargetBinding
    }

    public func detectElements(
        in imageData: Data,
        snapshotId: String?,
        windowContext: WindowContext?) async throws -> ElementDetectionResult
    {
        try await self.detectElementsActionResult(
            in: imageData,
            snapshotId: snapshotId,
            windowContext: windowContext,
            requestTimeoutSec: 30).payload
    }

    public func detectElements(
        in imageData: Data,
        snapshotId: String?,
        windowContext: WindowContext?,
        requestTimeoutSec: TimeInterval) async throws -> ElementDetectionResult
    {
        try await self.detectElementsActionResult(
            in: imageData,
            snapshotId: snapshotId,
            windowContext: windowContext,
            requestTimeoutSec: requestTimeoutSec).payload
    }

    public func detectElementsActionResult(
        in imageData: Data,
        snapshotId: String?,
        windowContext: WindowContext?,
        requestTimeoutSec: TimeInterval?) async throws -> UIAutomationActionResult<ElementDetectionResult>
    {
        try await self.client.detectElementsWithOutcome(
            in: imageData,
            snapshotId: snapshotId,
            windowContext: windowContext,
            requestTimeoutSec: requestTimeoutSec)
    }

    public func inspectAccessibilityTree(windowContext: WindowContext?) async throws -> ElementDetectionResult {
        try await self.inspectAccessibilityTreeActionResult(windowContext: windowContext).payload
    }

    public func inspectAccessibilityTreeActionResult(
        windowContext: WindowContext?) async throws -> UIAutomationActionResult<ElementDetectionResult>
    {
        guard self.supportsInspectAccessibilityTree else {
            throw Self.inspectAccessibilityTreeUnavailableError(reason: self.inspectAccessibilityTreeUnavailableReason)
        }

        do {
            return try await self.client.inspectAccessibilityTreeWithOutcome(
                windowContext: windowContext,
                requestTimeoutSec: Self.inspectAccessibilityTreeRequestTimeoutSeconds(
                    accessibilityTimeoutSeconds: windowContext?.accessibilityTimeoutSeconds))
        } catch let error as PeekabooBridgeErrorEnvelope
            where error.standardizedErrorCode == .accessibilityIncomplete
        {
            throw PeekabooError.accessibilityIncomplete(error.message)
        }
    }

    nonisolated static func inspectAccessibilityTreeRequestTimeoutSeconds(
        accessibilityTimeoutSeconds: TimeInterval?) -> TimeInterval
    {
        let defaultTimeout: TimeInterval = 30
        let completionGrace: TimeInterval = 5
        guard let accessibilityTimeoutSeconds,
              accessibilityTimeoutSeconds.isFinite,
              accessibilityTimeoutSeconds > 0
        else {
            return defaultTimeout
        }
        return max(defaultTimeout, accessibilityTimeoutSeconds + completionGrace)
    }

    public func click(target: ClickTarget, clickType: ClickType, snapshotId: String?) async throws {
        do {
            try await self.client.click(target: target, clickType: clickType, snapshotId: snapshotId)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw Self.automationError(for: envelope, snapshotId: snapshotId)
        }
    }

    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws
    {
        guard self.supportsTargetedClicks else {
            throw Self.targetedClickUnavailableError(
                reason: self.targetedClickUnavailableReason,
                requiresEventSynthesizingPermission: self.targetedClickRequiresEventSynthesizingPermission)
        }

        // The server owns request-specific permission checks: semantic single/right clicks can
        // remain Accessibility-only, while exact-window routed variants also require PostEvent.
        do {
            try await self.client.click(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                targetProcessIdentifier: targetProcessIdentifier)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw Self.automationError(for: envelope, snapshotId: snapshotId)
        }
    }

    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws
    {
        guard self.supportsProcessGenerationPinnedClicks else {
            throw PeekabooError.serviceUnavailable(
                "Remote bridge host does not support process-generation-pinned background clicks; update the host")
        }
        do {
            try await self.client.click(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                expectedProcessIdentity: expectedProcessIdentity)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw Self.automationError(for: envelope, snapshotId: snapshotId)
        }
    }

    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity,
        allowsAccessibilityValueDelivery: Bool) async throws
    {
        guard self.supportsProcessGenerationPinnedClicks else {
            throw PeekabooError.serviceUnavailable(
                "Remote bridge host does not support process-generation-pinned background clicks; update the host")
        }
        try self.requireAccessibilityValueDeliveryPolicySupport()
        do {
            try await self.client.click(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                expectedProcessIdentity: expectedProcessIdentity,
                allowsAccessibilityValueDelivery: allowsAccessibilityValueDelivery)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw Self.automationError(for: envelope, snapshotId: snapshotId)
        }
    }

    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws
    {
        guard self.supportsExactWindowTargetedClicks else {
            throw PeekabooError.serviceUnavailable(
                "Remote bridge host does not support exact-window background clicks")
        }
        guard self.supportsTargetedClicks else {
            throw Self.targetedClickUnavailableError(
                reason: self.targetedClickUnavailableReason,
                requiresEventSynthesizingPermission: self.targetedClickRequiresEventSynthesizingPermission)
        }

        // See the process-targeted overload: request-specific Event Synthesizing checks stay server-owned.
        do {
            try await self.client.click(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                expectedWindowIdentity: expectedWindowIdentity,
                expectedWindowBounds: expectedWindowBounds)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw Self.automationError(for: envelope, snapshotId: snapshotId)
        }
    }

    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        windowEvidence: ExactWindowClickEvidence,
        allowsAccessibilityValueDelivery: Bool) async throws
    {
        guard self.supportsExactWindowTargetedClicks else {
            throw PeekabooError.serviceUnavailable(
                "Remote bridge host does not support exact-window background clicks")
        }
        guard self.supportsTargetedClicks else {
            throw Self.targetedClickUnavailableError(
                reason: self.targetedClickUnavailableReason,
                requiresEventSynthesizingPermission: self.targetedClickRequiresEventSynthesizingPermission)
        }
        try self.requireAccessibilityValueDeliveryPolicySupport()
        do {
            try await self.client.click(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                windowEvidence: windowEvidence,
                allowsAccessibilityValueDelivery: allowsAccessibilityValueDelivery)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw Self.automationError(for: envelope, snapshotId: snapshotId)
        }
    }

    func requireAccessibilityValueDeliveryPolicySupport() throws {
        guard self.supportsTargetedClickAccessibilityValueDelivery else {
            throw PeekabooError.serviceUnavailable(
                "Remote bridge host cannot honor an explicit accessibility-value click policy")
        }
    }

    public func type(
        text: String,
        target: String?,
        clearExisting: Bool,
        typingDelay: Int,
        snapshotId: String?) async throws
    {
        do {
            try await self.client.type(
                text: text,
                target: target,
                clearExisting: clearExisting,
                typingDelay: typingDelay,
                snapshotId: snapshotId)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw Self.automationError(for: envelope, snapshotId: snapshotId)
        }
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?) async throws -> TypeResult
    {
        do {
            return try await self.client.typeActions(actions, cadence: cadence, snapshotId: snapshotId)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw Self.automationError(for: envelope, snapshotId: snapshotId)
        }
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> TypeResult
    {
        guard self.supportsProcessGenerationPinnedTypeActions else {
            throw PeekabooError.serviceUnavailable(
                "Remote bridge host does not support process-generation-pinned background typing; update the host")
        }
        do {
            return try await self.client.typeActions(
                actions,
                cadence: cadence,
                snapshotId: snapshotId,
                expectedProcessIdentity: expectedProcessIdentity)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw Self.automationError(for: envelope, snapshotId: snapshotId)
        }
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws -> TypeResult
    {
        guard self.supportsTargetedTypeActions else {
            throw Self.targetedTypeUnavailableError(
                reason: self.targetedTypeUnavailableReason,
                requiresEventSynthesizingPermission: self.targetedTypeRequiresEventSynthesizingPermission)
        }

        do {
            return try await self.client.typeActions(
                actions,
                cadence: cadence,
                snapshotId: snapshotId,
                targetProcessIdentifier: targetProcessIdentifier)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw Self.automationError(for: envelope, snapshotId: snapshotId)
        }
    }

    public func scroll(_ request: ScrollRequest) async throws {
        if !request.foreground,
           !self.supportsTargetedScroll || !self.supportsRequestPinnedExactWindowScrollReceipt
        {
            throw PeekabooError.serviceUnavailable(
                "Remote bridge host cannot preserve exact-window background scroll receipts; relaunch or update " +
                    "Peekaboo.")
        }
        do {
            try await self.client.scroll(request)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw Self.automationError(for: envelope, snapshotId: request.snapshotId)
        }
    }

    public func hotkey(keys: String, holdDuration: Int) async throws {
        try await self.client.hotkey(keys: keys, holdDuration: holdDuration)
    }

    public func hotkey(keys: String, holdDuration: Int, targetProcessIdentifier: pid_t) async throws {
        guard self.supportsTargetedHotkeys else {
            throw Self.targetedHotkeyUnavailableError(
                reason: self.targetedHotkeyUnavailableReason,
                requiresEventSynthesizingPermission: self.targetedHotkeyRequiresEventSynthesizingPermission)
        }

        do {
            try await self.client.hotkey(
                keys: keys,
                holdDuration: holdDuration,
                targetProcessIdentifier: targetProcessIdentifier)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            switch envelope.code {
            case .permissionDenied:
                throw Self.permissionDeniedError(for: envelope)
            case .invalidRequest:
                throw PeekabooError.invalidInput(envelope.message)
            case .operationNotSupported:
                throw PeekabooError.serviceUnavailable(envelope.message)
            default:
                throw envelope
            }
        }
    }

    public func hotkey(
        keys: String,
        holdDuration: Int,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws
    {
        guard self.supportsProcessGenerationPinnedHotkeys else {
            throw PeekabooError.serviceUnavailable(
                "Remote bridge host does not support process-generation-pinned background hotkeys; " +
                    "use --no-remote or update the host")
        }

        do {
            try await self.client.hotkey(
                keys: keys,
                holdDuration: holdDuration,
                expectedProcessIdentity: expectedProcessIdentity)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            switch envelope.code {
            case .permissionDenied:
                throw Self.permissionDeniedError(for: envelope)
            case .invalidRequest:
                throw PeekabooError.invalidInput(envelope.message)
            case .operationNotSupported:
                throw PeekabooError.serviceUnavailable(envelope.message)
            default:
                throw envelope
            }
        }
    }

    static func automationError(
        for envelope: PeekabooBridgeErrorEnvelope,
        snapshotId: String?) -> any Error
    {
        if let failure = envelope.desktopActionFailure {
            return failure
        }

        switch envelope.kind {
        case .elementNotFound:
            return PeekabooError.elementNotFound(envelope.context ?? envelope.message)
        case .snapshotNotFound:
            return PeekabooError.snapshotNotFound(envelope.context ?? snapshotId ?? envelope.message)
        case .snapshotStale:
            return PeekabooError.snapshotStale(envelope.context ?? envelope.message)
        case .appNotFound, .windowNotFound, .menuNotFound, .menuItemNotFound,
             .dockNotFound, .dockListNotFound, .dockItemNotFound, .positionNotFound:
            break
        case nil:
            break
        }

        return switch envelope.code {
        case .permissionDenied:
            self.permissionDeniedError(for: envelope)
        case .invalidRequest:
            PeekabooError.invalidInput(envelope.message)
        case .operationNotSupported:
            PeekabooError.serviceUnavailable(envelope.message)
        default:
            envelope
        }
    }

    private static func targetedHotkeyUnavailableError(
        reason: String?,
        requiresEventSynthesizingPermission: Bool) -> PeekabooError
    {
        if requiresEventSynthesizingPermission {
            return .permissionDeniedEventSynthesizing
        }

        return .serviceUnavailable(
            reason ?? "Remote bridge host does not support background hotkeys; use --no-remote or update the host")
    }

    private static func targetedTypeUnavailableError(
        reason: String?,
        requiresEventSynthesizingPermission: Bool) -> PeekabooError
    {
        if requiresEventSynthesizingPermission {
            return .permissionDeniedEventSynthesizing
        }

        return .serviceUnavailable(
            reason ?? "Remote bridge host does not support background typing; use --no-remote or update the host")
    }

    private static func targetedClickUnavailableError(
        reason: String?,
        requiresEventSynthesizingPermission: Bool) -> PeekabooError
    {
        if requiresEventSynthesizingPermission {
            return .permissionDeniedEventSynthesizing
        }

        return .serviceUnavailable(
            reason ?? "Remote bridge host does not support background clicks; use --no-remote or update the host")
    }

    private static func inspectAccessibilityTreeUnavailableError(reason: String?) -> PeekabooError {
        .serviceUnavailable(
            reason ?? "Remote bridge host does not support inspect_ui; use `see`, --no-remote, or update the host")
    }

    private static func permissionDeniedError(for envelope: PeekabooBridgeErrorEnvelope) -> PeekabooError {
        switch envelope.permission {
        case .postEvent:
            .permissionDeniedEventSynthesizing
        case .accessibility:
            .permissionDeniedAccessibility
        case .screenRecording:
            .permissionDeniedScreenRecording
        case .appleScript, .none:
            .permissionDeniedEventSynthesizing
        }
    }

    public func swipe(
        from: CGPoint,
        to: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws
    {
        try await self.client.swipe(from: from, to: to, duration: duration, steps: steps, profile: profile)
    }

    public func hasAccessibilityPermission() async -> Bool {
        do {
            let status = try await self.client.permissionsStatus()
            return status.accessibility
        } catch {
            return false
        }
    }

    public func waitForElement(
        target: ClickTarget,
        timeout: TimeInterval,
        snapshotId: String?) async throws -> WaitForElementResult
    {
        do {
            return try await self.client.waitForElement(target: target, timeout: timeout, snapshotId: snapshotId)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw Self.automationError(for: envelope, snapshotId: snapshotId)
        }
    }

    public func drag(_ request: DragOperationRequest) async throws {
        _ = try await self.dragWithOutcome(request)
    }

    public func moveMouse(to: CGPoint, duration: Int, steps: Int, profile: MouseMovementProfile) async throws {
        _ = try await self.moveMouseWithOutcome(to: to, duration: duration, steps: steps, profile: profile)
    }

    public func getFocusedElement() -> UIFocusInfo? {
        // Not yet implemented over XPC; fall back to nil to avoid blocking callers.
        nil
    }

    public func getFocusedElement(targetProcessIdentifier: pid_t) async -> UIFocusInfo? {
        try? await self.client.getFocusedElement(targetProcessIdentifier: targetProcessIdentifier)
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> TypeResult
    {
        guard self.supportsExactWindowTargetedKeyboard else {
            throw PeekabooError.serviceUnavailable(
                self.exactWindowTargetedKeyboardUnavailableReason ??
                    "Atomic exact-window background typing is unavailable")
        }
        try self.requireCompositeTypeDeliveryIfNeeded(actions)
        return try await self.client.typeActions(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds)
    }

    public func hotkey(
        keys: String,
        holdDuration: Int,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws
    {
        guard self.supportsExactWindowTargetedKeyboard else {
            throw PeekabooError.serviceUnavailable(
                self.exactWindowTargetedKeyboardUnavailableReason ??
                    "Atomic exact-window background hotkeys are unavailable")
        }
        try await self.client.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds)
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        target: ExactWindowKeyboardTarget) async throws -> TypeResult
    {
        guard self.supportsExactWindowTargetedKeyboard else {
            throw PeekabooError.serviceUnavailable(
                self.exactWindowTargetedKeyboardUnavailableReason ??
                    "Atomic exact-window background typing is unavailable")
        }
        try self.requireCompositeTypeDeliveryIfNeeded(actions)
        return try await self.client.typeActions(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            target: target)
    }

    public func hotkey(
        keys: String,
        holdDuration: Int,
        target: ExactWindowKeyboardTarget) async throws
    {
        guard self.supportsExactWindowTargetedKeyboard else {
            throw PeekabooError.serviceUnavailable(
                self.exactWindowTargetedKeyboardUnavailableReason ??
                    "Atomic exact-window background hotkeys are unavailable")
        }
        try await self.client.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            target: target)
    }

    func requireCompositeTypeDeliveryIfNeeded(_ actions: [TypeAction]) throws {
        guard actions.contains(where: \.mayUseAccessibilityValueDelivery) else { return }
        guard self.supportsExactWindowCompositeTypeDelivery else {
            throw PeekabooError.serviceUnavailable(
                self.exactWindowCompositeTypeDeliveryUnavailableReason ??
                    "Remote bridge host cannot return truthful composite exact-window typing receipts")
        }
    }

    public func findElement(matching criteria: UIElementSearchCriteria, in appName: String?) async throws
        -> DetectedElement
    {
        // Currently unsupported over XPC; this path is rarely used by CLI.
        throw PeekabooError.operationError(message: "findElement is not available over XPC yet")
    }
}

@MainActor
public final class RemoteElementActionUIAutomationService: RemoteUIAutomationService,
ElementActionAutomationServiceProtocol {
    public var supportsProcessGenerationBoundElementMutations: Bool {
        true
    }

    public func setValue(target: String, value: UIElementValue, snapshotId: String?) async throws
        -> ElementActionResult
    {
        do {
            return try await self.client.setValue(target: target, value: value, snapshotId: snapshotId)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw Self.automationError(for: envelope, snapshotId: snapshotId)
        }
    }

    public func performAction(target: String, actionName: String, snapshotId: String?) async throws
        -> ElementActionResult
    {
        do {
            return try await self.client.performAction(
                target: target,
                actionName: actionName,
                snapshotId: snapshotId)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw Self.automationError(for: envelope, snapshotId: snapshotId)
        }
    }
}

extension RemoteUIAutomationService: ExactWindowHeldPointerLifecycleServiceProtocol {
    public func createExactWindowHeldPointerOwner(
        boundTo _: ApplicationProcessIdentity?) async throws -> ExactWindowHeldPointerOwner
    {
        try await self.client.createExactWindowHeldPointerOwner()
    }

    public func beginExactWindowPointerHold(
        owner: ExactWindowHeldPointerOwner,
        request: ExactWindowHeldPointerRequest) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerReceipt>
    {
        try await self.client.beginExactWindowPointerHold(owner: owner, request: request)
    }

    public func releaseExactWindowPointerHold(
        owner: ExactWindowHeldPointerOwner,
        receipt: ExactWindowHeldPointerReceipt) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination>
    {
        try await self.client.releaseExactWindowPointerHold(owner: owner, receipt: receipt)
    }

    public func revokeExactWindowPointerHold(
        owner: ExactWindowHeldPointerOwner,
        receipt: ExactWindowHeldPointerReceipt) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination>
    {
        try await self.client.revokeExactWindowPointerHold(owner: owner, receipt: receipt)
    }

    public func disconnectExactWindowHeldPointerOwner(
        _ owner: ExactWindowHeldPointerOwner) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination?>
    {
        try await self.client.disconnectExactWindowHeldPointerOwner(owner)
    }
}
