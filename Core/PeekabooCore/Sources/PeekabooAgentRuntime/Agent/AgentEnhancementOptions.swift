//
//  AgentEnhancementOptions.swift
//  PeekabooCore
//
//  Configuration options for agent enhancements:
//  - Context injection
//  - Visual verification
//  - Smart screenshots
//

import Foundation

/// Options for controlling agent enhancement features.
@available(macOS 14.0, *)
public struct AgentEnhancementOptions: Sendable {
    // MARK: - Context Injection (Enhancement #1)

    /// Whether to auto-inject desktop context before each LLM turn.
    /// When enabled, injects focused app, window title, cursor position, and clipboard.
    public var contextAware: Bool

    // MARK: - Visual Verification (Enhancement #2)

    /// Whether to verify actions with screenshots after execution.
    public var verifyActions: Bool

    /// Maximum retry attempts when verification fails.
    public var maxVerificationRetries: Int

    /// Which action types to verify (empty = all mutating actions).
    public var verifyActionTypes: Set<VerifiableActionType>

    // MARK: - Smart Screenshots (Enhancement #3)

    /// Whether to use diff-aware capture (skip if screen unchanged).
    public var smartCapture: Bool

    /// Threshold for detecting screen changes (0.0 - 1.0).
    /// Lower = more sensitive to changes.
    public var changeThreshold: Float

    /// Whether to use region-focused capture after actions.
    public var regionFocusAfterAction: Bool

    /// Default radius for region capture (in pixels).
    public var regionCaptureRadius: CGFloat

    // MARK: - Initialization

    public init(
        contextAware: Bool = true,
        verifyActions: Bool = false,
        maxVerificationRetries: Int = 1,
        verifyActionTypes: Set<VerifiableActionType> = [],
        smartCapture: Bool = false,
        changeThreshold: Float = 0.05,
        regionFocusAfterAction: Bool = false,
        regionCaptureRadius: CGFloat = 300)
    {
        self.contextAware = contextAware
        self.verifyActions = verifyActions
        self.maxVerificationRetries = maxVerificationRetries
        self.verifyActionTypes = verifyActionTypes
        self.smartCapture = smartCapture
        self.changeThreshold = changeThreshold
        self.regionFocusAfterAction = regionFocusAfterAction
        self.regionCaptureRadius = regionCaptureRadius
    }

    // MARK: - Presets

    /// Default options: context-aware enabled, no verification, no smart capture.
    public static let `default` = AgentEnhancementOptions()

    /// Minimal options: all enhancements disabled.
    public static let minimal = AgentEnhancementOptions(
        contextAware: false,
        verifyActions: false,
        smartCapture: false)

    /// Full options: all enhancements enabled.
    public static let full = AgentEnhancementOptions(
        contextAware: true,
        verifyActions: true,
        maxVerificationRetries: 2,
        smartCapture: true,
        regionFocusAfterAction: true)

    /// Verification-focused: context + verification, no smart capture.
    public static let verified = AgentEnhancementOptions(
        contextAware: true,
        verifyActions: true,
        maxVerificationRetries: 2)
}

/// Action types that can be verified with screenshots.
public enum VerifiableActionType: String, Sendable, Hashable, CaseIterable {
    case app
    case browser
    case click
    case dialog
    case dock
    case drag
    case hotkey
    case launchApp = "launch_app"
    case menu
    case paste
    case performAction = "perform_action"
    case scroll
    case setValue = "set_value"
    case space
    case swipe
    case type
    case window

    private static let appReadOnlyActions: Set<String> = ["list"]
    private static let browserReadOnlyActions: Set<String> = [
        "status",
        "connect",
        "disconnect",
        "list_pages",
        "snapshot",
        "console",
        "network",
        "screenshot",
        "performance_trace",
        "wait_for",
    ]
    private static let dialogReadOnlyActions: Set<String> = ["list"]
    private static let dockReadOnlyActions: Set<String> = ["list"]
    private static let menuReadOnlyActions: Set<String> = ["list", "list-all", "list_all"]
    private static let spaceReadOnlyActions: Set<String> = ["list"]

    /// Whether this tool can modify state and should be verified by default when action details are unavailable.
    public var isMutating: Bool {
        true
    }

    /// Whether this invocation modifies state and should be verified by default.
    public func isMutating(arguments: [String: String]) -> Bool {
        switch self {
        case .app:
            !Self.appReadOnlyActions.contains(Self.actionName(in: arguments))
        case .browser:
            !Self.browserReadOnlyActions.contains(Self.actionName(in: arguments))
        case .dialog:
            !Self.dialogReadOnlyActions.contains(Self.actionName(in: arguments))
        case .dock:
            !Self.dockReadOnlyActions.contains(Self.actionName(in: arguments))
        case .menu:
            !Self.menuReadOnlyActions.contains(Self.actionName(in: arguments))
        case .space:
            !Self.spaceReadOnlyActions.contains(Self.actionName(in: arguments))
        default:
            true
        }
    }

    private static func actionName(in arguments: [String: String]) -> String {
        arguments["action"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }
}
