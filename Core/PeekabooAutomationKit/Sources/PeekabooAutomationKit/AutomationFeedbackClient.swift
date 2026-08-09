import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
public protocol AutomationFeedbackClient: Sendable {
    /// Spatial arguments use the global Core Graphics / Accessibility display
    /// coordinate space: upper-left origin on the primary display, in points.
    /// Concrete visualizer clients convert once at the AppKit window boundary.
    func connect()

    func showClickFeedback(
        at point: CGPoint,
        type: ClickType,
        target: VisualizerTargetWindow?) async -> Bool

    /// `masksTypedText` marks the keys as sensitive (e.g. typed into a secure
    /// text field) so downstream displays render bullets instead of content.
    func showTypingFeedback(
        keys: [String],
        duration: TimeInterval,
        cadence: TypingCadence,
        masksTypedText: Bool,
        target: VisualizerTargetWindow?) async -> Bool
    func showScrollFeedback(
        at point: CGPoint,
        direction: ScrollDirection,
        amount: Int,
        target: VisualizerTargetWindow?) async -> Bool
    func showHotkeyDisplay(
        keys: [String],
        duration: TimeInterval,
        target: VisualizerTargetWindow?) async -> Bool
    func showSwipeGesture(
        from: CGPoint,
        to: CGPoint,
        duration: TimeInterval,
        target: VisualizerTargetWindow?) async -> Bool
    func showMouseMovement(
        from: CGPoint,
        to: CGPoint,
        duration: TimeInterval,
        target: VisualizerTargetWindow?) async -> Bool

    func showScreenshotFlash(in rect: CGRect) async -> Bool
    func showWatchCapture(in rect: CGRect) async -> Bool
}

extension AutomationFeedbackClient {
    public func connect() {}

    public func showClickFeedback(
        at _: CGPoint,
        type _: ClickType,
        target _: VisualizerTargetWindow? = nil) async -> Bool
    {
        false
    }

    public func showTypingFeedback(
        keys _: [String],
        duration _: TimeInterval,
        cadence _: TypingCadence,
        masksTypedText _: Bool,
        target _: VisualizerTargetWindow? = nil) async -> Bool
    {
        false
    }

    public func showScrollFeedback(
        at _: CGPoint,
        direction _: ScrollDirection,
        amount _: Int,
        target _: VisualizerTargetWindow? = nil) async -> Bool
    {
        false
    }

    public func showHotkeyDisplay(
        keys _: [String],
        duration _: TimeInterval,
        target _: VisualizerTargetWindow? = nil) async -> Bool
    {
        false
    }

    public func showSwipeGesture(
        from _: CGPoint,
        to _: CGPoint,
        duration _: TimeInterval,
        target _: VisualizerTargetWindow? = nil) async -> Bool
    {
        false
    }

    public func showMouseMovement(
        from _: CGPoint,
        to _: CGPoint,
        duration _: TimeInterval,
        target _: VisualizerTargetWindow? = nil) async -> Bool
    {
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
