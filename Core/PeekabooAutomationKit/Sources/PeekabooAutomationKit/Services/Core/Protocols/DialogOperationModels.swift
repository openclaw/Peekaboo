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
        self.applicationIdentifier = Self.normalized(applicationIdentifier)
        self.processIdentifier = processIdentifier
        self.windowID = windowID
        self.windowTitle = Self.normalized(windowTitle)
        self.windowIndex = windowIndex
        try self.validate(originalApplication: applicationIdentifier, originalWindowTitle: windowTitle)
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

    private func validate(originalApplication: String?, originalWindowTitle: String?) throws {
        if originalApplication != nil, self.applicationIdentifier == nil {
            throw PeekabooError.invalidInput("Dialog target application must not be empty")
        }
        if originalWindowTitle != nil, self.windowTitle == nil {
            throw PeekabooError.invalidInput("Dialog target window title must not be empty")
        }
        do {
            try InteractionTargetSelectorValidator.validate(
                hasApplication: self.applicationIdentifier != nil,
                hasProcessIdentifier: self.processIdentifier != nil,
                hasWindowID: self.windowID != nil,
                hasWindowTitle: self.windowTitle != nil,
                hasWindowIndex: self.windowIndex != nil)
        } catch let error as InteractionTargetSelectorValidationError {
            let reason = switch error {
            case .applicationAndProcessIdentifier:
                "Dialog app and PID selectors are mutually exclusive"
            case .multipleWindowSelectors:
                "Dialog window ID, title, and index selectors are mutually exclusive"
            case .windowSelectorRequiresApplication:
                "Dialog window title and index selectors require an app or PID"
            }
            throw PeekabooError.invalidInput(reason)
        }
        if let processIdentifier, processIdentifier <= 0 {
            throw PeekabooError.invalidInput("Dialog target PID must be positive")
        }
        if let windowID, windowID <= 0 || UInt32(exactly: windowID) == nil {
            throw PeekabooError.invalidInput("Dialog target window ID must be between 1 and \(UInt32.max)")
        }
        if let windowIndex, windowIndex < 0 {
            throw PeekabooError.invalidInput("Dialog target window index must be 0 or greater")
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
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
