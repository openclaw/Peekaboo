import CoreGraphics
import Foundation
import PeekabooFoundation

/// The caller's complete dialog selection constraints.
///
/// Application and PID selectors remain separate so an exact window can never erase an owner assertion.
public struct DialogTargetSelector: Sendable, Codable, Equatable {
    public let applicationIdentifier: String?
    public let processIdentifier: Int32?
    public let windowID: Int?
    public let windowTitle: String?
    public let windowIndex: Int?

    public init(
        applicationIdentifier: String? = nil,
        processIdentifier: Int32? = nil,
        windowID: Int? = nil,
        windowTitle: String? = nil,
        windowIndex: Int? = nil) throws
    {
        let selector = InteractionTargetSelector(
            applicationIdentifier: applicationIdentifier,
            processIdentifier: processIdentifier.map(Int.init),
            windowID: windowID,
            windowTitle: windowTitle,
            windowIndex: windowIndex)
        do {
            try selector.validate(policy: .dialogOwnerRequired)
        } catch let error as InteractionTargetSelector.ValidationError {
            throw PeekabooError.invalidInput(Self.validationMessage(for: error))
        }

        self.applicationIdentifier = selector.normalizedApplicationIdentifier
        self.processIdentifier = processIdentifier
        self.windowID = windowID
        self.windowTitle = selector.normalizedWindowTitle
        self.windowIndex = windowIndex
    }

    public var hasTarget: Bool {
        self.applicationIdentifier != nil || self.processIdentifier != nil || self.windowID != nil ||
            self.windowTitle != nil || self.windowIndex != nil
    }

    public var hasWindowSelector: Bool {
        self.windowID != nil || self.windowTitle != nil || self.windowIndex != nil
    }

    private enum CodingKeys: String, CodingKey {
        case applicationIdentifier
        case processIdentifier
        case windowID
        case windowTitle
        case windowIndex
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            applicationIdentifier: container.decodeIfPresent(String.self, forKey: .applicationIdentifier),
            processIdentifier: container.decodeIfPresent(Int32.self, forKey: .processIdentifier),
            windowID: container.decodeIfPresent(Int.self, forKey: .windowID),
            windowTitle: container.decodeIfPresent(String.self, forKey: .windowTitle),
            windowIndex: container.decodeIfPresent(Int.self, forKey: .windowIndex))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.applicationIdentifier, forKey: .applicationIdentifier)
        try container.encodeIfPresent(self.processIdentifier, forKey: .processIdentifier)
        try container.encodeIfPresent(self.windowID, forKey: .windowID)
        try container.encodeIfPresent(self.windowTitle, forKey: .windowTitle)
        try container.encodeIfPresent(self.windowIndex, forKey: .windowIndex)
    }

    private static func validationMessage(
        for error: InteractionTargetSelector.ValidationError) -> String
    {
        switch error {
        case .emptyApplication:
            "Dialog target application must not be empty"
        case .emptyWindowTitle:
            "Dialog target window title must not be empty"
        case .applicationAndProcessIdentifier,
             .conflictingProcessIdentifiers,
             .invalidApplicationProcessIdentifier:
            "Dialog app and PID selectors are mutually exclusive"
        case .multipleWindowSelectors:
            "Dialog window ID, title, and index selectors are mutually exclusive"
        case .windowSelectorRequiresApplication:
            "Dialog window title and index selectors require an app or PID"
        case .invalidProcessIdentifier:
            "Dialog target PID must be positive"
        case .invalidWindowID:
            "Dialog target window ID must be between 1 and \(UInt32.max)"
        case .invalidWindowIndex:
            "Dialog target window index must be 0 or greater"
        case .missingTarget:
            "Dialog target is required"
        }
    }
}

/// Foreground-focus behavior for one exact dialog input execution.
///
/// Dialog text entry ultimately uses global keyboard events, so disabling automatic focus does not
/// weaken verification: the selected parent/dialog must already own foreground focus before dispatch.
public struct DialogForegroundFocusPolicy: Sendable, Codable, Equatable {
    public let autoFocus: Bool
    public let timeout: TimeInterval
    public let retryCount: Int
    public let switchSpace: Bool
    public let bringToCurrentSpace: Bool

    public init(
        autoFocus: Bool = true,
        timeout: TimeInterval = 5,
        retryCount: Int = 3,
        switchSpace: Bool = false,
        bringToCurrentSpace: Bool = false)
    {
        self.autoFocus = autoFocus
        self.timeout = timeout
        self.retryCount = retryCount
        self.switchSpace = switchSpace
        self.bringToCurrentSpace = bringToCurrentSpace
    }

    private enum CodingKeys: String, CodingKey {
        case autoFocus
        case timeout
        case retryCount
        case switchSpace
        case bringToCurrentSpace
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            autoFocus: container.decode(Bool.self, forKey: .autoFocus),
            timeout: container.decode(TimeInterval.self, forKey: .timeout),
            retryCount: container.decode(Int.self, forKey: .retryCount),
            switchSpace: container.decode(Bool.self, forKey: .switchSpace),
            bringToCurrentSpace: container.decode(Bool.self, forKey: .bringToCurrentSpace))
    }

    fileprivate func validate(operation: String) throws {
        guard self.timeout.isFinite, self.timeout > 0 else {
            throw PeekabooError.invalidInput("\(operation) focus timeout must be greater than zero")
        }
        guard self.retryCount > 0 else {
            throw PeekabooError.invalidInput("\(operation) focus retry count must be greater than zero")
        }
    }
}

/// Focus-aware request for the compatibility path that resolves the current foreground dialog.
public struct DialogLegacyInputExecutionRequest: Sendable, Codable, Equatable {
    public let text: String
    public let fieldIdentifier: String?
    public let clearExisting: Bool
    public let windowTitle: String?
    public let appName: String?
    public let focus: DialogForegroundFocusPolicy

    public init(
        text: String,
        fieldIdentifier: String? = nil,
        clearExisting: Bool = false,
        windowTitle: String? = nil,
        appName: String? = nil,
        focus: DialogForegroundFocusPolicy = DialogForegroundFocusPolicy()) throws
    {
        try focus.validate(operation: "Dialog input")
        self.text = text
        self.fieldIdentifier = fieldIdentifier
        self.clearExisting = clearExisting
        self.windowTitle = windowTitle
        self.appName = appName
        self.focus = focus
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case fieldIdentifier
        case clearExisting
        case windowTitle
        case appName
        case focus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            text: container.decode(String.self, forKey: .text),
            fieldIdentifier: container.decodeIfPresent(String.self, forKey: .fieldIdentifier),
            clearExisting: container.decode(Bool.self, forKey: .clearExisting),
            windowTitle: container.decodeIfPresent(String.self, forKey: .windowTitle),
            appName: container.decodeIfPresent(String.self, forKey: .appName),
            focus: container.decode(DialogForegroundFocusPolicy.self, forKey: .focus))
    }
}

/// Complete, host-executed request for exact dialog text entry.
///
/// The selector is intentionally unresolved on the wire. The execution host must resolve and retain
/// the parent window, structural dialog, field, and process-generation receipt in one operation lane.
public struct DialogInputExecutionRequest: Sendable, Codable, Equatable {
    public let target: DialogTargetSelector
    public let text: String
    public let fieldIdentifier: String?
    public let clearExisting: Bool
    public let focus: DialogForegroundFocusPolicy

    public init(
        target: DialogTargetSelector,
        text: String,
        fieldIdentifier: String? = nil,
        clearExisting: Bool = false,
        focus: DialogForegroundFocusPolicy = DialogForegroundFocusPolicy()) throws
    {
        guard target.hasTarget else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Exact dialog input requires an explicit app, PID, or window target.",
                hint: "Add --app, --pid, or --window-id after listing the dialog.")
        }
        let normalizedFieldIdentifier = fieldIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        if fieldIdentifier != nil, normalizedFieldIdentifier?.isEmpty != false {
            throw PeekabooError.invalidInput("Dialog input field identifier must not be empty")
        }
        try focus.validate(operation: "Dialog input")
        self.target = target
        self.text = text
        self.fieldIdentifier = normalizedFieldIdentifier
        self.clearExisting = clearExisting
        self.focus = focus
    }

    private enum CodingKeys: String, CodingKey {
        case target
        case text
        case fieldIdentifier
        case clearExisting
        case focus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            target: container.decode(DialogTargetSelector.self, forKey: .target),
            text: container.decode(String.self, forKey: .text),
            fieldIdentifier: container.decodeIfPresent(String.self, forKey: .fieldIdentifier),
            clearExisting: container.decode(Bool.self, forKey: .clearExisting),
            focus: container.decode(DialogForegroundFocusPolicy.self, forKey: .focus))
    }
}

/// Complete, host-executed request for a foreground forced dialog dismissal.
///
/// The execution host resolves and retains one exact dialog, establishes the requested focus policy,
/// proves that retained dialog still owns foreground focus, and only then posts Escape.
public struct DialogForcedDismissExecutionRequest: Sendable, Codable, Equatable {
    public let target: DialogTargetSelector
    public let focus: DialogForegroundFocusPolicy

    public init(
        target: DialogTargetSelector,
        focus: DialogForegroundFocusPolicy = DialogForegroundFocusPolicy()) throws
    {
        guard target.hasTarget else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Exact forced dialog dismissal requires an explicit app, PID, or window target.",
                hint: "Add --app, --pid, or --window-id after listing the dialog.")
        }
        try focus.validate(operation: "Dialog dismissal")
        self.target = target
        self.focus = focus
    }

    private enum CodingKeys: String, CodingKey {
        case target
        case focus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            target: container.decode(DialogTargetSelector.self, forKey: .target),
            focus: container.decode(DialogForegroundFocusPolicy.self, forKey: .focus))
    }
}

public enum DialogPreparedActionKind: String, Sendable, Codable, Equatable {
    case clickButton = "click_button"
    case dismiss
}

/// A read-only request to resolve one exact dialog action before mutation transport.
public struct DialogActionPreparationRequest: Sendable, Codable, Equatable {
    public let target: DialogTargetSelector
    public let kind: DialogPreparedActionKind
    public let buttonText: String?

    public init(
        target: DialogTargetSelector,
        kind: DialogPreparedActionKind,
        buttonText: String? = nil) throws
    {
        let normalizedButton = buttonText?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.hasTarget else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Dialog mutations require an explicit app, PID, or window target.",
                hint: "Add --app, --pid, or --window-id after listing the dialog.")
        }
        switch kind {
        case .clickButton:
            guard let normalizedButton, !normalizedButton.isEmpty else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .invalidRequest,
                    message: "Dialog click requires a nonempty button name.",
                    hint: "Run dialog list, then provide one exact button name.")
            }
        case .dismiss:
            guard normalizedButton == nil else {
                throw PeekabooError.invalidInput("Prepared dialog dismiss cannot include button text")
            }
        }
        self.target = target
        self.kind = kind
        self.buttonText = normalizedButton
    }

    private enum CodingKeys: String, CodingKey {
        case target
        case kind
        case buttonText
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            target: container.decode(DialogTargetSelector.self, forKey: .target),
            kind: container.decode(DialogPreparedActionKind.self, forKey: .kind),
            buttonText: container.decodeIfPresent(String.self, forKey: .buttonText))
    }
}

/// Opaque, expiring authority for one host-retained dialog/button tuple.
public struct PreparedDialogActionReceipt: Sendable, Codable, Equatable {
    public let token: UUID
    public let kind: DialogPreparedActionKind
    public let target: UIAutomationTarget.ExactWindow

    public init(
        token: UUID,
        kind: DialogPreparedActionKind,
        target: UIAutomationTarget.ExactWindow)
    {
        self.token = token
        self.kind = kind
        self.target = target
    }
}
