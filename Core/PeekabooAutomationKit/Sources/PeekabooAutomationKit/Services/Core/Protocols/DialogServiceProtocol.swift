import CoreGraphics
import Foundation
import PeekabooFoundation

/// Protocol defining dialog and alert management operations
@MainActor
public protocol DialogServiceProtocol: Sendable {
    /// Whether the legacy `appName` parameter accepts an exact `PID:<n>` sentinel.
    ///
    /// Remote and third-party providers default to false so callers preserve the established
    /// bundle/name contract until the provider explicitly opts into exact PID hints.
    var supportsExactProcessIdentifierAppHint: Bool { get }

    /// Canonical route for conservative outcomes synthesized from legacy foreground responses.
    var foregroundOutcomeRoute: DesktopActionOutcome.Route { get }

    /// Whether exact dialog input is guaranteed to use background AXValue delivery.
    ///
    /// Protocol 1.29 relies on this host-side capability before waiving the legacy PostEvent
    /// requirement. Older providers default to false and retain protocol 1.28 foreground behavior.
    var supportsBackgroundExactDialogInput: Bool { get }

    /// Find and return information about the active dialog
    /// - Parameter windowTitle: Optional specific window title to target
    /// - Returns: Information about the active dialog
    func findActiveDialog(
        windowTitle: String?,
        appName: String?) async throws -> DialogInfo

    /// Click a button in the active dialog
    /// - Parameters:
    ///   - buttonText: Text of the button to click (e.g., "OK", "Cancel", "Save")
    ///   - windowTitle: Optional specific window title to target
    /// - Returns: Result of the click operation
    func clickButton(
        buttonText: String,
        windowTitle: String?,
        appName: String?) async throws -> DialogActionResult

    /// Click a dialog button, optionally allowing a foreground screen-coordinate fallback.
    /// Background callers must leave `allowGlobalFallback` false so the action remains AX-only.
    func clickButton(
        buttonText: String,
        windowTitle: String?,
        appName: String?,
        allowGlobalFallback: Bool) async throws -> DialogActionResult

    /// Enter text in a dialog field
    /// - Parameters:
    ///   - text: Text to enter
    ///   - fieldIdentifier: Field label, placeholder, or index to target
    ///   - clearExisting: Whether to clear existing text first
    ///   - windowTitle: Optional specific window title to target
    /// - Returns: Result of the input operation
    func enterText(
        text: String,
        fieldIdentifier: String?,
        clearExisting: Bool,
        windowTitle: String?,
        appName: String?) async throws -> DialogActionResult

    /// Enter text through the legacy foreground target while preserving the caller's focus policy.
    func enterText(_ request: DialogLegacyInputExecutionRequest) async throws -> DialogActionResult

    /// Resolve and execute text entry against one exact dialog target on this runtime host.
    func enterText(_ request: DialogInputExecutionRequest) async throws -> DialogActionResult

    /// Preserve the protocol 1.28 exact foreground-keyboard contract.
    /// Current receipt-carrying requests use background `enterText(_:)` instead.
    func enterTextForegroundCompatible(_ request: DialogInputExecutionRequest) async throws -> DialogActionResult

    /// Resolve, focus, verify, and force-dismiss one retained dialog on this runtime host.
    func forceDismissDialog(_ request: DialogForcedDismissExecutionRequest) async throws -> DialogActionResult

    /// Handle file save/open dialogs
    /// - Parameters:
    ///   - path: Full path to navigate to
    ///   - filename: File name to enter (for save dialogs)
    ///   - actionButton: Button to click after entering path/name. Pass nil (or "default") to click the OKButton.
    ///   - ensureExpanded: Ensure the dialog is expanded ("Show Details") before interacting with path fields.
    /// - Returns: Result of the file dialog operation
    func handleFileDialog(
        path: String?,
        filename: String?,
        actionButton: String?,
        ensureExpanded: Bool,
        appName: String?) async throws -> DialogActionResult

    /// Dismiss the active dialog
    /// - Parameters:
    ///   - force: Use Escape key to force dismiss
    ///   - windowTitle: Optional specific window title to target
    /// - Returns: Result of the dismiss operation
    func dismissDialog(
        force: Bool,
        windowTitle: String?,
        appName: String?) async throws -> DialogActionResult

    /// List all elements in the active dialog
    /// - Parameter windowTitle: Optional specific window title to target
    /// - Returns: Information about all dialog elements
    func listDialogElements(
        windowTitle: String?,
        appName: String?) async throws -> DialogElements

    /// Resolve one exact window/dialog/button tuple without dispatching a mutation.
    func prepareDialogAction(_ request: DialogActionPreparationRequest) async throws
        -> PreparedDialogActionReceipt

    /// Atomically consume and execute a previously prepared one-shot dialog action.
    func performPreparedDialogAction(_ receipt: PreparedDialogActionReceipt) async throws -> DialogActionResult

    /// List one uniquely targeted dialog without creating mutation or snapshot debt.
    func listDialogElements(target: DialogTargetSelector) async throws -> DialogElements
}

extension DialogServiceProtocol {
    public var supportsExactProcessIdentifierAppHint: Bool {
        false
    }

    public var foregroundOutcomeRoute: DesktopActionOutcome.Route {
        .local
    }

    public var supportsBackgroundExactDialogInput: Bool {
        false
    }

    public func clickButton(
        buttonText: String,
        windowTitle: String?,
        appName: String?,
        allowGlobalFallback: Bool) async throws -> DialogActionResult
    {
        guard allowGlobalFallback else {
            throw PeekabooError.operationError(
                message: "This dialog service does not implement AX-only background button clicks")
        }
        return try await self.clickButton(buttonText: buttonText, windowTitle: windowTitle, appName: appName)
    }

    public func findActiveDialog(windowTitle: String?) async throws -> DialogInfo {
        try await self.findActiveDialog(windowTitle: windowTitle, appName: nil)
    }

    public func clickButton(buttonText: String, windowTitle: String?) async throws -> DialogActionResult {
        try await self.clickButton(buttonText: buttonText, windowTitle: windowTitle, appName: nil)
    }

    public func enterText(
        text: String,
        fieldIdentifier: String?,
        clearExisting: Bool,
        windowTitle: String?) async throws -> DialogActionResult
    {
        try await self.enterText(
            text: text,
            fieldIdentifier: fieldIdentifier,
            clearExisting: clearExisting,
            windowTitle: windowTitle,
            appName: nil)
    }

    public func enterText(_ request: DialogLegacyInputExecutionRequest) async throws -> DialogActionResult {
        guard request.focus == DialogForegroundFocusPolicy() else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "This dialog service cannot preserve a custom foreground focus policy.",
                hint: "Update the selected runtime host before retrying.")
        }
        return try await self.enterText(
            text: request.text,
            fieldIdentifier: request.fieldIdentifier,
            clearExisting: request.clearExisting,
            windowTitle: request.windowTitle,
            appName: request.appName)
    }

    public func enterText(_ request: DialogInputExecutionRequest) async throws -> DialogActionResult {
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .runtimeIncompatible,
            message: "This dialog service does not support exact host-executed dialog input.",
            hint: "Update the selected runtime host before retrying.")
    }

    public func enterTextForegroundCompatible(
        _ request: DialogInputExecutionRequest) async throws -> DialogActionResult
    {
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .runtimeIncompatible,
            message: "This dialog service does not support foreground-compatible exact dialog input.",
            hint: "Use background exact input or select a provider that explicitly supports foreground input.")
    }

    public func forceDismissDialog(_ request: DialogForcedDismissExecutionRequest) async throws -> DialogActionResult {
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .runtimeIncompatible,
            message: "This dialog service does not support exact host-executed forced dismissal.",
            hint: "Update the selected runtime host before retrying.")
    }

    public func handleFileDialog(
        path: String?,
        filename: String?,
        actionButton: String?,
        ensureExpanded: Bool = false) async throws -> DialogActionResult
    {
        try await self.handleFileDialog(
            path: path,
            filename: filename,
            actionButton: actionButton,
            ensureExpanded: ensureExpanded,
            appName: nil)
    }

    public func dismissDialog(force: Bool, windowTitle: String?) async throws -> DialogActionResult {
        try await self.dismissDialog(force: force, windowTitle: windowTitle, appName: nil)
    }

    public func listDialogElements(windowTitle: String?) async throws -> DialogElements {
        try await self.listDialogElements(windowTitle: windowTitle, appName: nil)
    }

    public func prepareDialogAction(_ request: DialogActionPreparationRequest) async throws
        -> PreparedDialogActionReceipt
    {
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .runtimeIncompatible,
            message: "This dialog service does not support receipt-pinned background actions.",
            hint: "Update the selected runtime host before retrying.")
    }

    public func performPreparedDialogAction(_ receipt: PreparedDialogActionReceipt) async throws
        -> DialogActionResult
    {
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .runtimeIncompatible,
            message: "This dialog service does not support receipt-pinned background actions.",
            hint: "Update the selected runtime host before retrying.")
    }

    public func listDialogElements(target: DialogTargetSelector) async throws -> DialogElements {
        throw PeekabooError.serviceUnavailable(
            "This dialog service does not support uniquely targeted dialog reads")
    }
}

/// Information about a dialog
public struct DialogInfo: Sendable, Codable {
    /// Dialog title
    public let title: String

    /// Dialog role (e.g., "AXDialog", "AXSheet")
    public let role: String

    /// Dialog subrole if available
    public let subrole: String?

    /// Whether this is a file dialog
    public let isFileDialog: Bool

    /// Dialog bounds in screen coordinates
    public let bounds: CGRect

    public init(
        title: String,
        role: String,
        subrole: String? = nil,
        isFileDialog: Bool = false,
        bounds: CGRect)
    {
        self.title = title
        self.role = role
        self.subrole = subrole
        self.isFileDialog = isFileDialog
        self.bounds = bounds
    }
}

/// Result of a dialog action
public struct DialogActionResult: Sendable, Codable {
    /// Whether the action was successful
    public let success: Bool

    /// Type of action performed
    public let action: DialogActionType

    /// Additional details about the action
    public let details: [String: String]

    /// Canonical action evidence. Legacy foreground paths may omit it; receipt-pinned actions may not.
    public let outcome: DesktopActionOutcome?

    /// Exact generation-bound window receipt resolved by the execution host, when available.
    public let targetReceipt: DesktopActionTargetReceipt?

    /// Full stable target retained by exact execution paths for operation-level attestation.
    public let targetWindowIdentity: WindowMutationIdentity?
    public let targetWindowBounds: CGRect?
    public let focusedElement: FocusedElementIdentity?
    public let resolvedTarget: ResolvedDialogTargetEvidence?

    public init(
        success: Bool,
        action: DialogActionType,
        details: [String: String] = [:],
        outcome: DesktopActionOutcome? = nil,
        targetReceipt: DesktopActionTargetReceipt? = nil)
    {
        self.init(
            success: success,
            action: action,
            details: details,
            outcome: outcome,
            targetReceipt: targetReceipt,
            targetWindowIdentity: nil,
            targetWindowBounds: nil,
            focusedElement: nil,
            resolvedTarget: nil)
    }

    public init(
        success: Bool,
        action: DialogActionType,
        details: [String: String],
        outcome: DesktopActionOutcome?,
        targetReceipt: DesktopActionTargetReceipt?,
        targetWindowIdentity: WindowMutationIdentity?,
        targetWindowBounds: CGRect?,
        focusedElement: FocusedElementIdentity?,
        resolvedTarget: ResolvedDialogTargetEvidence? = nil)
    {
        self.success = success
        self.action = action
        self.details = details
        self.outcome = outcome
        self.targetReceipt = targetReceipt
        self.targetWindowIdentity = targetWindowIdentity
        self.targetWindowBounds = targetWindowBounds
        self.focusedElement = focusedElement
        self.resolvedTarget = resolvedTarget
    }
}

extension DialogActionResult {
    /// Legacy foreground dialog providers may omit canonical outcomes. A successful return proves
    /// only that shared global input was accepted, never which controller caused the visible effect.
    public func foregroundOutcomeOrUnverified(route: DesktopActionOutcome.Route) -> DesktopActionOutcome {
        self.outcome?.routed(to: route) ?? .dispatchedUnverified(
            route: route,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: nil)
    }

    /// Validates the exact contract required from receipt-pinned background dialog actions.
    public func requiredPreparedOutcome(kind: DialogPreparedActionKind) throws -> DesktopActionOutcome {
        let expectedAction: DialogActionType = kind == .clickButton ? .clickButton : .dismiss
        guard let outcome = self.outcome else {
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Prepared dialog action returned without its canonical outcome.",
                hint: "Observe the dialog before retrying and update the runtime host.")
        }
        try DesktopActionFailure.requireConfirmedIfReported(outcome, operation: "Prepared dialog action")
        let expectedDelivery = DesktopActionOutcome.Delivery(
            mechanism: .accessibilityAction,
            mode: .background)
        guard self.success,
              self.action == expectedAction,
              outcome.state == .confirmedChange,
              outcome.delivery == expectedDelivery,
              outcome.dispatchState.unitCount == .one
        else {
            throw DesktopActionFailure.indeterminate(
                route: outcome.route,
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "Prepared dialog action returned contradictory confirmation evidence.",
                hint: "Observe the dialog before retrying and update the runtime host.")
        }
        return outcome
    }
}

/// Information about dialog elements
public struct DialogElements: Sendable, Codable {
    /// Dialog information
    public let dialogInfo: DialogInfo

    /// Available buttons
    public let buttons: [DialogButton]

    /// Text input fields
    public let textFields: [DialogTextField]

    /// Static text elements
    public let staticTexts: [String]

    /// Other UI elements
    public let otherElements: [DialogElement]

    /// Exact target and selector-resolution evidence for a targeted dialog list.
    public let resolvedTarget: ResolvedDialogTargetEvidence?

    public init(
        dialogInfo: DialogInfo,
        buttons: [DialogButton] = [],
        textFields: [DialogTextField] = [],
        staticTexts: [String] = [],
        otherElements: [DialogElement] = [],
        resolvedTarget: ResolvedDialogTargetEvidence? = nil)
    {
        self.dialogInfo = dialogInfo
        self.buttons = buttons
        self.textFields = textFields
        self.staticTexts = staticTexts
        self.otherElements = otherElements
        self.resolvedTarget = resolvedTarget
    }
}

/// Information about a dialog button
public struct DialogButton: Sendable, Codable {
    /// Button text
    public let title: String

    /// Whether the button is enabled
    public let isEnabled: Bool

    /// Whether this is the default button
    public let isDefault: Bool

    public init(
        title: String,
        isEnabled: Bool = true,
        isDefault: Bool = false)
    {
        self.title = title
        self.isEnabled = isEnabled
        self.isDefault = isDefault
    }
}

/// Information about a dialog text field
public struct DialogTextField: Sendable, Codable {
    /// Field label or title
    public let title: String?

    /// Current value
    public let value: String?

    /// Placeholder text
    public let placeholder: String?

    /// Field index (0-based)
    public let index: Int

    /// Whether the field is enabled
    public let isEnabled: Bool

    public init(
        title: String? = nil,
        value: String? = nil,
        placeholder: String? = nil,
        index: Int,
        isEnabled: Bool = true)
    {
        self.title = title
        self.value = value
        self.placeholder = placeholder
        self.index = index
        self.isEnabled = isEnabled
    }
}

/// Generic dialog element
public struct DialogElement: Sendable, Codable {
    /// Element role
    public let role: String

    /// Element title or label
    public let title: String?

    /// Element value
    public let value: String?

    public init(
        role: String,
        title: String? = nil,
        value: String? = nil)
    {
        self.role = role
        self.title = title
        self.value = value
    }
}
