import CoreGraphics
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooBridge
import PeekabooFoundation

@MainActor
public class RemoteUIAutomationService: DetectElementsRequestTimeoutAdjusting, TargetedHotkeyServiceProtocol,
    TargetedTypeServiceProtocol,
    ExactWindowTargetedClickServiceProtocol
{
    let client: PeekabooBridgeClient
    public let supportsTargetedHotkeys: Bool
    public let targetedHotkeyUnavailableReason: String?
    public let targetedHotkeyRequiresEventSynthesizingPermission: Bool
    public let supportsTargetedTypeActions: Bool
    public let targetedTypeUnavailableReason: String?
    public let targetedTypeRequiresEventSynthesizingPermission: Bool
    public let supportsTargetedClicks: Bool
    public let targetedClickUnavailableReason: String?
    public let targetedClickRequiresEventSynthesizingPermission: Bool
    public let supportsExactWindowTargetedClicks: Bool
    public let supportsInspectAccessibilityTree: Bool
    public let inspectAccessibilityTreeUnavailableReason: String?

    public init(
        client: PeekabooBridgeClient,
        supportsTargetedHotkeys: Bool = false,
        targetedHotkeyUnavailableReason: String? = nil,
        targetedHotkeyRequiresEventSynthesizingPermission: Bool = false,
        supportsTargetedTypeActions: Bool = false,
        targetedTypeUnavailableReason: String? = nil,
        targetedTypeRequiresEventSynthesizingPermission: Bool = false,
        supportsTargetedClicks: Bool = false,
        targetedClickUnavailableReason: String? = nil,
        targetedClickRequiresEventSynthesizingPermission: Bool = false,
        supportsExactWindowTargetedClicks: Bool = false,
        supportsInspectAccessibilityTree: Bool = false,
        inspectAccessibilityTreeUnavailableReason: String? = nil)
    {
        self.client = client
        self.supportsTargetedHotkeys = supportsTargetedHotkeys
        self.targetedHotkeyUnavailableReason = targetedHotkeyUnavailableReason
        self.targetedHotkeyRequiresEventSynthesizingPermission = targetedHotkeyRequiresEventSynthesizingPermission
        self.supportsTargetedTypeActions = supportsTargetedTypeActions
        self.targetedTypeUnavailableReason = targetedTypeUnavailableReason
        self.targetedTypeRequiresEventSynthesizingPermission = targetedTypeRequiresEventSynthesizingPermission
        self.supportsTargetedClicks = supportsTargetedClicks
        self.targetedClickUnavailableReason = targetedClickUnavailableReason
        self.targetedClickRequiresEventSynthesizingPermission = targetedClickRequiresEventSynthesizingPermission
        self.supportsExactWindowTargetedClicks = supportsExactWindowTargetedClicks
        self.supportsInspectAccessibilityTree = supportsInspectAccessibilityTree
        self.inspectAccessibilityTreeUnavailableReason = inspectAccessibilityTreeUnavailableReason
    }

    public func detectElements(
        in imageData: Data,
        snapshotId: String?,
        windowContext: WindowContext?) async throws -> ElementDetectionResult
    {
        try await self.detectElements(
            in: imageData,
            snapshotId: snapshotId,
            windowContext: windowContext,
            requestTimeoutSec: 30)
    }

    public func detectElements(
        in imageData: Data,
        snapshotId: String?,
        windowContext: WindowContext?,
        requestTimeoutSec: TimeInterval) async throws -> ElementDetectionResult
    {
        try await self.client.detectElements(
            in: imageData,
            snapshotId: snapshotId,
            windowContext: windowContext,
            requestTimeoutSec: requestTimeoutSec)
    }

    public func inspectAccessibilityTree(windowContext: WindowContext?) async throws -> ElementDetectionResult {
        guard self.supportsInspectAccessibilityTree else {
            throw Self.inspectAccessibilityTreeUnavailableError(reason: self.inspectAccessibilityTreeUnavailableReason)
        }

        return try await self.client.inspectAccessibilityTree(
            windowContext: windowContext,
            requestTimeoutSec: 30)
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

        // No Event Synthesizing preflight: current hosts deliver every targeted click (coordinates
        // included) through accessibility, so a coordinate click on an Accessibility-only host must
        // reach the server rather than being rejected here. Variants the host genuinely cannot
        // deliver (e.g. background double-click) are rejected authoritatively by the server.
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
        targetProcessIdentifier: pid_t,
        targetWindowID: Int) async throws
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

        // See the process-targeted overload: no Event Synthesizing preflight, the server decides.
        do {
            try await self.client.click(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                targetProcessIdentifier: targetProcessIdentifier,
                targetWindowID: targetWindowID)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            throw Self.automationError(for: envelope, snapshotId: snapshotId)
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

    static func automationError(
        for envelope: PeekabooBridgeErrorEnvelope,
        snapshotId: String?) -> any Error
    {
        switch envelope.kind {
        case .elementNotFound:
            return PeekabooError.elementNotFound(envelope.context ?? envelope.message)
        case .snapshotNotFound:
            return PeekabooError.snapshotNotFound(envelope.context ?? snapshotId ?? envelope.message)
        case .snapshotStale:
            return PeekabooError.snapshotStale(envelope.context ?? envelope.message)
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
        try await self.client.drag(PeekabooBridgeDragRequest(request))
    }

    public func moveMouse(to: CGPoint, duration: Int, steps: Int, profile: MouseMovementProfile) async throws {
        try await self.client.moveMouse(to: to, duration: duration, steps: steps, profile: profile)
    }

    public func getFocusedElement() -> UIFocusInfo? {
        // Not yet implemented over XPC; fall back to nil to avoid blocking callers.
        nil
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
