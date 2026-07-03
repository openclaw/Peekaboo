import CoreGraphics
import Foundation
import PeekabooFoundation

public enum SpaceSwitchDirection: String, Sendable, Codable {
    case left
    case right
}

public enum WindowOperationKind: String, Sendable, Codable {
    case close
    case minimize
    case maximize
    case move
    case resize
    case setBounds
    case focus
}

@MainActor
public protocol AutomationFeedbackClient: Sendable {
    func connect()

    func showClickFeedback(at point: CGPoint, type: ClickType) async -> Bool

    /// `masksTypedText` marks the keys as sensitive (e.g. typed into a secure
    /// text field) so downstream displays render bullets instead of content.
    func showTypingFeedback(
        keys: [String],
        duration: TimeInterval,
        cadence: TypingCadence,
        masksTypedText: Bool) async -> Bool
    func showScrollFeedback(at point: CGPoint, direction: ScrollDirection, amount: Int) async -> Bool
    func showHotkeyDisplay(keys: [String], duration: TimeInterval) async -> Bool
    func showSwipeGesture(from: CGPoint, to: CGPoint, duration: TimeInterval) async -> Bool
    func showMouseMovement(from: CGPoint, to: CGPoint, duration: TimeInterval) async -> Bool

    func showWindowOperation(_ kind: WindowOperationKind, windowRect: CGRect, duration: TimeInterval) async -> Bool

    func showDialogInteraction(
        element: DialogElementType,
        elementRect: CGRect,
        action: DialogActionType) async -> Bool

    func showMenuNavigation(menuPath: [String]) async -> Bool
    func showSpaceSwitch(from: Int, to: Int, direction: SpaceSwitchDirection) async -> Bool

    func showAppLaunch(appName: String, iconPath: String?) async -> Bool
    func showAppQuit(appName: String, iconPath: String?) async -> Bool

    func showScreenshotFlash(in rect: CGRect) async -> Bool
    func showWatchCapture(in rect: CGRect) async -> Bool
}

extension AutomationFeedbackClient {
    public func connect() {}

    public func showClickFeedback(at _: CGPoint, type _: ClickType) async -> Bool {
        false
    }

    public func showTypingFeedback(
        keys _: [String],
        duration _: TimeInterval,
        cadence _: TypingCadence,
        masksTypedText _: Bool) async -> Bool
    {
        false
    }

    public func showScrollFeedback(at _: CGPoint, direction _: ScrollDirection, amount _: Int) async -> Bool {
        false
    }

    public func showHotkeyDisplay(keys _: [String], duration _: TimeInterval) async -> Bool {
        false
    }

    public func showSwipeGesture(from _: CGPoint, to _: CGPoint, duration _: TimeInterval) async -> Bool {
        false
    }

    public func showMouseMovement(from _: CGPoint, to _: CGPoint, duration _: TimeInterval) async -> Bool {
        false
    }

    public func showWindowOperation(
        _: WindowOperationKind,
        windowRect _: CGRect,
        duration _: TimeInterval) async -> Bool
    {
        false
    }

    public func showDialogInteraction(
        element _: DialogElementType,
        elementRect _: CGRect,
        action _: DialogActionType) async -> Bool
    {
        false
    }

    public func showMenuNavigation(menuPath _: [String]) async -> Bool {
        false
    }

    public func showSpaceSwitch(from _: Int, to _: Int, direction _: SpaceSwitchDirection) async -> Bool {
        false
    }

    public func showAppLaunch(appName _: String, iconPath _: String?) async -> Bool {
        false
    }

    public func showAppQuit(appName _: String, iconPath _: String?) async -> Bool {
        false
    }

    public func showScreenshotFlash(in _: CGRect) async -> Bool {
        false
    }

    public func showWatchCapture(in _: CGRect) async -> Bool {
        false
    }
}

@MainActor
public final class NoopAutomationFeedbackClient: AutomationFeedbackClient {
    public init() {}
}
