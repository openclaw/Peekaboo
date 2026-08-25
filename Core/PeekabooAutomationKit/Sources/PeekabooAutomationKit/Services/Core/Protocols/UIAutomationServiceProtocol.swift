import CoreGraphics
import Darwin
import Foundation
import PeekabooFoundation

public enum DragButton: String, Sendable, Equatable, Codable {
    case left
    case right
}

public struct DragOperationRequest: Sendable, Equatable {
    public let from: CGPoint
    public let to: CGPoint
    public let duration: Int
    public let steps: Int
    public let modifiers: String?
    public let button: DragButton
    public let profile: MouseMovementProfile

    public init(
        from: CGPoint,
        to: CGPoint,
        duration: Int,
        steps: Int,
        modifiers: String?,
        button: DragButton = .left,
        profile: MouseMovementProfile)
    {
        self.from = from
        self.to = to
        self.duration = duration
        self.steps = steps
        self.modifiers = modifiers
        self.button = button
        self.profile = profile
    }
}

/// Protocol defining UI automation operations
@MainActor
public protocol UIAutomationServiceProtocol: Sendable {
    /// Detect UI elements in a screenshot
    /// - Parameters:
    ///   - imageData: The screenshot image data
    ///   - snapshotId: Optional snapshot ID to use for caching
    ///   - windowContext: Optional window context for coordinate mapping
    /// - Returns: Detection result with identified elements
    func detectElements(in imageData: Data, snapshotId: String?, windowContext: WindowContext?) async throws
        -> ElementDetectionResult

    /// Click at a specific point or element
    /// - Parameters:
    ///   - target: Click target (element ID, coordinates, or query)
    ///   - clickType: Type of click (single, double, right)
    ///   - snapshotId: Snapshot ID for element resolution
    func click(target: ClickTarget, clickType: ClickType, snapshotId: String?) async throws

    /// Type text at current focus or specific element
    /// - Parameters:
    ///   - text: Text to type (supports special keys)
    ///   - target: Optional target element
    ///   - clearExisting: Whether to clear existing text first
    ///   - typingDelay: Delay between keystrokes in milliseconds
    ///   - snapshotId: Snapshot ID for element resolution
    func type(text: String, target: String?, clearExisting: Bool, typingDelay: Int, snapshotId: String?) async throws

    /// Type using advanced typing actions (text, special keys, key sequences)
    /// - Parameters:
    ///   - actions: Array of typing actions to perform
    ///   - cadence: Typing cadence (fixed delay or human WPM)
    ///   - snapshotId: Snapshot ID for element resolution
    func typeActions(_ actions: [TypeAction], cadence: TypingCadence, snapshotId: String?) async throws -> TypeResult

    /// Scroll in a specific direction with the supplied configuration.
    /// - Parameter request: Scroll configuration including direction, amount, options, and snapshot context.
    func scroll(_ request: ScrollRequest) async throws

    /// Press a hotkey combination
    /// - Parameters:
    ///   - keys: Comma-separated key combination (e.g., "cmd,c")
    ///   - holdDuration: How long to hold the keys in milliseconds
    func hotkey(keys: String, holdDuration: Int) async throws

    /// Perform a swipe/drag gesture
    /// - Parameters:
    ///   - from: Starting point
    ///   - to: Ending point
    ///   - duration: Duration of the swipe in milliseconds
    ///   - steps: Number of intermediate steps
    ///   - profile: Movement profile for the swipe path
    func swipe(from: CGPoint, to: CGPoint, duration: Int, steps: Int, profile: MouseMovementProfile) async throws

    /// Check if accessibility permission is granted
    /// - Returns: True if permission is granted
    func hasAccessibilityPermission() async -> Bool

    /// Wait for an element to appear and become actionable
    /// - Parameters:
    ///   - target: The element target to wait for
    ///   - timeout: Maximum time to wait in seconds
    ///   - snapshotId: Snapshot ID for element resolution
    /// - Returns: Result indicating if element was found with timing info
    func waitForElement(target: ClickTarget, timeout: TimeInterval, snapshotId: String?) async throws
        -> WaitForElementResult

    /// Perform a drag operation between two points
    /// - Parameter request: Drag configuration including coordinates, timing, modifiers, and profile.
    func drag(_ request: DragOperationRequest) async throws

    /// Move the mouse cursor to a specific location
    /// - Parameters:
    ///   - to: Target location for the mouse cursor
    ///   - duration: Duration of the movement in milliseconds (0 for instant)
    ///   - steps: Number of intermediate steps for smooth movement
    ///   - profile: Movement profile that controls path generation
    func moveMouse(to: CGPoint, duration: Int, steps: Int, profile: MouseMovementProfile) async throws

    /// Read the current mouse cursor location in global display coordinates.
    func currentMouseLocation() -> CGPoint?

    /// Get information about the currently focused UI element
    /// - Returns: Information about the focused element, or nil if no element has focus
    func getFocusedElement() -> UIFocusInfo?

    /// Find an element matching the given criteria
    /// - Parameters:
    ///   - criteria: Search criteria for finding the element
    ///   - appName: Optional application name to search within
    /// - Returns: The first element matching the criteria
    /// - Throws: PeekabooError.elementNotFound if no matching element is found
    func findElement(matching criteria: UIElementSearchCriteria, in appName: String?) async throws -> DetectedElement

    /// Inspect the accessibility tree of the current or target window without capturing a screenshot.
    /// - Parameter windowContext: Optional window context to narrow the inspection target.
    /// - Returns: Detection result with accessibility-derived elements.
    /// - Throws: PeekabooError if the inspection fails.
    func inspectAccessibilityTree(windowContext: WindowContext?) async throws -> ElementDetectionResult
}

extension UIAutomationServiceProtocol {
    public func currentMouseLocation() -> CGPoint? {
        nil
    }

    public func inspectAccessibilityTree(windowContext: WindowContext?) async throws -> ElementDetectionResult {
        throw PeekabooError.notImplemented("inspectAccessibilityTree")
    }
}

/// Embedding-only exact-window split pointer lifecycle.
///
/// Standalone CLI and MCP tools intentionally do not expose these primitives. Callers must retain
/// the opaque owner and hold receipt, and the concrete service keeps the exact-window mutation lane
/// until one terminal cleanup wins.
@MainActor
public protocol ExactWindowHeldPointerLifecycleServiceProtocol: UIAutomationServiceProtocol {
    var supportsExactWindowHeldPointerLifecycle: Bool { get }

    func createExactWindowHeldPointerOwner(
        boundTo processIdentity: ApplicationProcessIdentity?) async throws -> ExactWindowHeldPointerOwner

    func beginExactWindowPointerHold(
        owner: ExactWindowHeldPointerOwner,
        request: ExactWindowHeldPointerRequest) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerReceipt>

    func releaseExactWindowPointerHold(
        owner: ExactWindowHeldPointerOwner,
        receipt: ExactWindowHeldPointerReceipt) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination>

    func revokeExactWindowPointerHold(
        owner: ExactWindowHeldPointerOwner,
        receipt: ExactWindowHeldPointerReceipt) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination>

    func disconnectExactWindowHeldPointerOwner(
        _ owner: ExactWindowHeldPointerOwner) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination?>
}

/// Additive capability for observations that can conditionally focus embedded web content.
///
/// The original observation methods remain source compatible. Result-aware callers use this
/// capability so a transport-backed service cannot discard a signed mutation outcome or target.
@MainActor
public protocol UIAutomationObservationActionResultProviding: UIAutomationServiceProtocol {
    func detectElementsActionResult(
        in imageData: Data,
        snapshotId: String?,
        windowContext: WindowContext?,
        requestTimeoutSec: TimeInterval?) async throws -> UIAutomationActionResult<ElementDetectionResult>

    func inspectAccessibilityTreeActionResult(
        windowContext: WindowContext?) async throws -> UIAutomationActionResult<ElementDetectionResult>
}

extension UIAutomationServiceProtocol {
    public func detectElementsResult(
        in imageData: Data,
        snapshotId: String?,
        windowContext: WindowContext?,
        requestTimeoutSec: TimeInterval? = nil) async throws -> UIAutomationActionResult<ElementDetectionResult>
    {
        if let results = self as? any UIAutomationObservationActionResultProviding {
            return try await results.detectElementsActionResult(
                in: imageData,
                snapshotId: snapshotId,
                windowContext: windowContext,
                requestTimeoutSec: requestTimeoutSec)
        }
        let mayFocusWebContent = windowContext?.shouldFocusWebContent == true
        do {
            let payload: ElementDetectionResult = if let requestTimeoutSec,
                                                     let timeoutAdjusting =
                                                     self as? any DetectElementsRequestTimeoutAdjusting
            {
                try await timeoutAdjusting.detectElements(
                    in: imageData,
                    snapshotId: snapshotId,
                    windowContext: windowContext,
                    requestTimeoutSec: requestTimeoutSec)
            } else {
                try await self.detectElements(
                    in: imageData,
                    snapshotId: snapshotId,
                    windowContext: windowContext)
            }
            return UIAutomationActionResult(
                payload: payload,
                outcome: mayFocusWebContent ? Self.webFocusObservationOutcome : nil)
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch {
            guard mayFocusWebContent else { throw error }
            throw Self.webFocusObservationFailure(error, operation: "Element detection")
        }
    }

    public func inspectAccessibilityTreeResult(
        windowContext: WindowContext?) async throws -> UIAutomationActionResult<ElementDetectionResult>
    {
        if let results = self as? any UIAutomationObservationActionResultProviding {
            return try await results.inspectAccessibilityTreeActionResult(windowContext: windowContext)
        }
        let mayFocusWebContent = windowContext?.shouldFocusWebContent == true
        do {
            return try await UIAutomationActionResult(
                payload: self.inspectAccessibilityTree(windowContext: windowContext),
                outcome: mayFocusWebContent ? Self.webFocusObservationOutcome : nil)
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch {
            guard mayFocusWebContent else { throw error }
            throw Self.webFocusObservationFailure(error, operation: "Accessibility inspection")
        }
    }

    private static var webFocusObservationOutcome: DesktopActionOutcome {
        .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
    }

    private static func webFocusObservationFailure(
        _ error: any Error,
        operation: String) -> DesktopActionFailure
    {
        .indeterminate(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .completionUnknown,
            message: "\(operation) failed after web-content focus may have been dispatched.",
            hint: "Observe the target before retrying with web focus enabled.",
            causeDescription: error.localizedDescription)
    }
}

/// Additive capability for callers that need the canonical result of a successful automation action.
///
/// Existing protocol methods remain the compatibility surface. A caller can opt into this capability
/// without requiring older or transport-backed automation services to fabricate outcome evidence.
@MainActor
public protocol UIAutomationActionOutcomeProviding: UIAutomationServiceProtocol {
    /// The service binds an exact-window scroll request to the same complete snapshot receipt in
    /// both successful and retry-unsafe results.
    var supportsRequestPinnedExactWindowScrollReceipt: Bool { get }

    func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?) async throws -> UIAutomationActionResult<Void>

    func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws -> UIAutomationActionResult<Void>

    func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<Void>

    func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity,
        allowsAccessibilityValueDelivery: Bool) async throws -> UIAutomationActionResult<Void>

    func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<Void>

    func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect,
        allowsAccessibilityValueDelivery: Bool) async throws -> UIAutomationActionResult<Void>

    func typeWithOutcome(
        text: String,
        target: String?,
        clearExisting: Bool,
        typingDelay: Int,
        snapshotId: String?) async throws -> UIAutomationActionResult<Void>

    func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?) async throws -> UIAutomationActionResult<TypeResult>

    func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws -> UIAutomationActionResult<TypeResult>

    func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<TypeResult>

    func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<TypeResult>

    func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        target: ExactWindowKeyboardTarget) async throws -> UIAutomationActionResult<TypeResult>

    func scrollWithOutcome(_ request: ScrollRequest) async throws -> UIAutomationActionResult<Void>

    func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int) async throws -> UIAutomationActionResult<Void>

    func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        targetProcessIdentifier: pid_t) async throws -> UIAutomationActionResult<Void>

    func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<Void>

    func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<Void>

    func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        target: ExactWindowKeyboardTarget) async throws -> UIAutomationActionResult<Void>

    func setValueWithOutcome(
        target: String,
        value: UIElementValue,
        snapshotId: String?) async throws -> UIAutomationActionResult<ElementActionResult>

    func performActionWithOutcome(
        target: String,
        actionName: String,
        snapshotId: String?) async throws -> UIAutomationActionResult<ElementActionResult>
}

extension UIAutomationActionOutcomeProviding {
    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity,
        allowsAccessibilityValueDelivery: Bool) async throws -> UIAutomationActionResult<Void>
    {
        guard allowsAccessibilityValueDelivery else {
            throw PeekabooError.serviceUnavailable(
                "This automation service cannot enforce an accessibility-value click opt-out")
        }
        return try await self.clickWithOutcome(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            expectedProcessIdentity: expectedProcessIdentity)
    }

    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect,
        allowsAccessibilityValueDelivery: Bool) async throws -> UIAutomationActionResult<Void>
    {
        guard allowsAccessibilityValueDelivery else {
            throw PeekabooError.serviceUnavailable(
                "This automation service cannot enforce an accessibility-value click opt-out")
        }
        return try await self.clickWithOutcome(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds)
    }

    public var supportsRequestPinnedExactWindowScrollReceipt: Bool {
        false
    }
}

/// Additive result capability for shared-pointer operations.
///
/// Drag and cursor movement remain foreground-only global mutations. Keeping this capability
/// separate from `UIAutomationActionOutcomeProviding` lets older providers retain their void
/// compatibility methods without claiming a canonical result they cannot produce.
@MainActor
public protocol UIAutomationGlobalPointerActionResultProviding: UIAutomationServiceProtocol {
    func dragWithOutcome(_ request: DragOperationRequest) async throws -> UIAutomationActionResult<Void>

    func moveMouseWithOutcome(
        to: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws -> UIAutomationActionResult<Void>
}

/// Optional capability for querying the focused element of a specific background application.
/// A system-wide focus query reports the user's foreground app and is not a valid substitute.
@MainActor
public protocol TargetedFocusedElementServiceProtocol: UIAutomationServiceProtocol {
    func getFocusedElement(targetProcessIdentifier: pid_t) async -> UIFocusInfo?
}

/// Additive capability for exact semantic element focus with a verified per-window AXFocused receipt.
@MainActor
public protocol ExactWindowFocusedElementServiceProtocol: UIAutomationServiceProtocol {
    var supportsExactWindowFocusedElementFocus: Bool { get }

    func focusExactElementWithOutcome(
        target: ClickTarget,
        snapshotId: String,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<FocusedElementIdentity>
}

/// Atomically focuses one capture-owned pixel in an exact background window and types into it.
///
/// The operation never activates the application or falls back to global input. Providers must
/// retain one exact-target lane across the focus-only Accessibility write, focused-element proof,
/// and every keyboard unit, and must preserve any completed prefix as retry-unsafe failure state.
@MainActor
public protocol ExactWindowPixelFocusTypingServiceProtocol: UIAutomationServiceProtocol {
    var supportsExactWindowPixelFocusTyping: Bool { get }
    var exactWindowPixelFocusTypingUnavailableReason: String? { get }

    func typeActionsByFocusingPixelWithOutcome(
        _ request: ExactWindowPixelFocusTypeRequest) async throws -> UIAutomationActionResult<TypeResult>
}

/// Explicit foreground modifier-click with exact target preflight and compare-and-swap restoration.
@MainActor
public protocol ForegroundModifierClickServiceProtocol: UIAutomationServiceProtocol {
    var supportsForegroundModifierClick: Bool { get }
    var supportsForegroundModifierClickSnapshotLease: Bool { get }
    var foregroundModifierClickUnavailableReason: String? { get }

    func foregroundModifierClickWithOutcome(
        _ request: ForegroundModifierClickRequest) async throws
        -> UIAutomationActionResult<ForegroundModifierClickResult>
}

extension ForegroundModifierClickServiceProtocol {
    public var supportsForegroundModifierClickSnapshotLease: Bool {
        false
    }
}

/// Atomically validates an exact background window's focused element and dispatches keyboard input.
@MainActor
public protocol ExactWindowTargetedKeyboardServiceProtocol: UIAutomationServiceProtocol {
    var supportsExactWindowTargetedKeyboard: Bool { get }
    var exactWindowTargetedKeyboardUnavailableReason: String? { get }

    func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> TypeResult

    func hotkey(
        keys: String,
        holdDuration: Int,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws

    func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        target: ExactWindowKeyboardTarget) async throws -> TypeResult

    func hotkey(
        keys: String,
        holdDuration: Int,
        target: ExactWindowKeyboardTarget) async throws
}

extension ExactWindowTargetedKeyboardServiceProtocol {
    public func typeActions(
        _: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?,
        expectedWindowIdentity _: WindowMutationIdentity,
        expectedWindowBounds _: CGRect) async throws -> TypeResult
    {
        throw PeekabooError.serviceUnavailable(
            "Exact-window typing requires process-generation identity support")
    }

    public func hotkey(
        keys _: String,
        holdDuration _: Int,
        expectedWindowIdentity _: WindowMutationIdentity,
        expectedWindowBounds _: CGRect) async throws
    {
        throw PeekabooError.serviceUnavailable(
            "Exact-window hotkeys require process-generation identity support")
    }

    public func typeActions(
        _: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?,
        target _: ExactWindowKeyboardTarget) async throws -> TypeResult
    {
        throw PeekabooError.serviceUnavailable(
            "Exact-window typing requires clicked-destination identity support")
    }

    public func hotkey(
        keys _: String,
        holdDuration _: Int,
        target _: ExactWindowKeyboardTarget) async throws
    {
        throw PeekabooError.serviceUnavailable(
            "Exact-window hotkeys require clicked-destination identity support")
    }
}

/// Optional capability for automation services that can override the transport timeout used for element detection.
@MainActor
public protocol DetectElementsRequestTimeoutAdjusting: UIAutomationServiceProtocol {
    func detectElements(
        in imageData: Data,
        snapshotId: String?,
        windowContext: WindowContext?,
        requestTimeoutSec: TimeInterval) async throws -> ElementDetectionResult
}

/// Optional capability for automation services that can send hotkeys to a process without focusing it.
@MainActor
public protocol TargetedHotkeyServiceProtocol: UIAutomationServiceProtocol {
    var supportsTargetedHotkeys: Bool { get }
    var supportsProcessGenerationPinnedHotkeys: Bool { get }
    var targetedHotkeyUnavailableReason: String? { get }
    var targetedHotkeyRequiresEventSynthesizingPermission: Bool { get }

    func hotkey(keys: String, holdDuration: Int, targetProcessIdentifier: pid_t) async throws

    func hotkey(
        keys: String,
        holdDuration: Int,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws
}

extension TargetedHotkeyServiceProtocol {
    public var supportsTargetedHotkeys: Bool {
        true
    }

    public var supportsProcessGenerationPinnedHotkeys: Bool {
        false
    }

    public var targetedHotkeyUnavailableReason: String? {
        nil
    }

    public var targetedHotkeyRequiresEventSynthesizingPermission: Bool {
        false
    }

    public func hotkey(
        keys _: String,
        holdDuration _: Int,
        expectedProcessIdentity _: ApplicationProcessIdentity) async throws
    {
        throw PeekabooError.serviceUnavailable(
            "This automation service does not support process-generation-pinned hotkeys")
    }
}

/// Optional capability for automation services that can send typing actions to a process without focusing it.
@MainActor
public protocol TargetedTypeServiceProtocol: UIAutomationServiceProtocol {
    var supportsTargetedTypeActions: Bool { get }
    var supportsProcessGenerationPinnedTypeActions: Bool { get }
    var targetedTypeUnavailableReason: String? { get }
    var targetedTypeRequiresEventSynthesizingPermission: Bool { get }

    func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws -> TypeResult

    func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> TypeResult
}

extension TargetedTypeServiceProtocol {
    public var supportsTargetedTypeActions: Bool {
        true
    }

    public var supportsProcessGenerationPinnedTypeActions: Bool {
        false
    }

    public var targetedTypeUnavailableReason: String? {
        nil
    }

    public var targetedTypeRequiresEventSynthesizingPermission: Bool {
        true
    }

    public func typeActions(
        _: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?,
        expectedProcessIdentity _: ApplicationProcessIdentity) async throws -> TypeResult
    {
        throw PeekabooError.serviceUnavailable(
            "This automation service does not support process-generation-pinned typing")
    }
}

/// Optional capability for automation services that can send mouse clicks to a process without focusing it.
@MainActor
public protocol TargetedClickServiceProtocol: UIAutomationServiceProtocol {
    var supportsTargetedClicks: Bool { get }
    var supportsProcessGenerationPinnedClicks: Bool { get }
    var supportsStatelessClickVariants: Bool { get }
    var supportsTargetedClickAccessibilityValueDelivery: Bool { get }
    var targetedClickUnavailableReason: String? { get }
    var targetedClickRequiresEventSynthesizingPermission: Bool { get }

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity,
        allowsAccessibilityValueDelivery: Bool) async throws
}

/// Optional capability for preserving an exact target window during a background click.
@MainActor
public protocol ExactWindowTargetedClickServiceProtocol: TargetedClickServiceProtocol {
    var supportsExactWindowTargetedClicks: Bool { get }

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect,
        allowsAccessibilityValueDelivery: Bool) async throws
}

extension ExactWindowTargetedClickServiceProtocol {
    public var supportsExactWindowTargetedClicks: Bool {
        true
    }

    public func click(
        target _: ClickTarget,
        clickType _: ClickType,
        snapshotId _: String?,
        expectedWindowIdentity _: WindowMutationIdentity,
        expectedWindowBounds _: CGRect) async throws
    {
        throw PeekabooError.serviceUnavailable(
            "Exact-window clicks require process-generation identity support")
    }

    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect,
        allowsAccessibilityValueDelivery: Bool) async throws
    {
        guard allowsAccessibilityValueDelivery else {
            throw PeekabooError.serviceUnavailable(
                "This automation service cannot enforce an accessibility-value click opt-out")
        }
        try await self.click(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds)
    }
}

extension TargetedClickServiceProtocol {
    public var supportsTargetedClicks: Bool {
        true
    }

    public var supportsProcessGenerationPinnedClicks: Bool {
        false
    }

    public var supportsStatelessClickVariants: Bool {
        false
    }

    public var supportsTargetedClickAccessibilityValueDelivery: Bool {
        false
    }

    public var targetedClickUnavailableReason: String? {
        nil
    }

    public var targetedClickRequiresEventSynthesizingPermission: Bool {
        true
    }

    public func click(
        target _: ClickTarget,
        clickType _: ClickType,
        snapshotId _: String?,
        expectedProcessIdentity _: ApplicationProcessIdentity) async throws
    {
        throw PeekabooError.serviceUnavailable(
            "This automation service does not support process-generation-pinned clicks")
    }

    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity,
        allowsAccessibilityValueDelivery: Bool) async throws
    {
        guard allowsAccessibilityValueDelivery else {
            throw PeekabooError.serviceUnavailable(
                "This automation service cannot enforce an accessibility-value click opt-out")
        }
        try await self.click(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            expectedProcessIdentity: expectedProcessIdentity)
    }
}

/// Optional capability for automation services that can invoke accessibility actions directly.
@MainActor
public protocol ElementActionAutomationServiceProtocol: UIAutomationServiceProtocol {
    var supportsSetValueResultTargetBinding: Bool { get }

    func setValue(target: String, value: UIElementValue, snapshotId: String?) async throws -> ElementActionResult
    func performAction(target: String, actionName: String, snapshotId: String?) async throws -> ElementActionResult
}

extension ElementActionAutomationServiceProtocol {
    public var supportsSetValueResultTargetBinding: Bool {
        false
    }
}
