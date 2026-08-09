import AppKit
import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import PeekabooVisualizer

@MainActor
public final class VisualizerAutomationFeedbackClient: AutomationFeedbackClient {
    private let client: VisualizationClient

    public init(client: VisualizationClient = .shared) {
        self.client = client
    }

    public func connect() {
        self.client.connect()
    }

    public func showClickFeedback(
        at point: CGPoint,
        type: ClickType,
        target: VisualizerTargetWindow?) async -> Bool
    {
        await self.client.showClickFeedback(
            at: self.appKitPoint(point),
            type: type,
            target: self.appKitTarget(target))
    }

    public func showTypingFeedback(
        keys: [String],
        duration: TimeInterval,
        cadence: TypingCadence,
        masksTypedText: Bool,
        target: VisualizerTargetWindow?) async -> Bool
    {
        await self.client.showTypingFeedback(
            keys: keys,
            duration: duration,
            cadence: cadence,
            masksTypedText: masksTypedText,
            target: self.appKitTarget(target))
    }

    public func showScrollFeedback(
        at point: CGPoint,
        direction: ScrollDirection,
        amount: Int,
        target: VisualizerTargetWindow?) async -> Bool
    {
        await self.client.showScrollFeedback(
            at: self.appKitPoint(point),
            direction: direction,
            amount: amount,
            target: self.appKitTarget(target))
    }

    public func showHotkeyDisplay(
        keys: [String],
        duration: TimeInterval,
        target: VisualizerTargetWindow?) async -> Bool
    {
        await self.client.showHotkeyDisplay(keys: keys, duration: duration, target: self.appKitTarget(target))
    }

    public func showSwipeGesture(
        from: CGPoint,
        to: CGPoint,
        duration: TimeInterval,
        target: VisualizerTargetWindow?) async -> Bool
    {
        await self.client.showSwipeGesture(
            from: self.appKitPoint(from),
            to: self.appKitPoint(to),
            duration: duration,
            target: self.appKitTarget(target))
    }

    public func showMouseMovement(
        from: CGPoint,
        to: CGPoint,
        duration: TimeInterval,
        target: VisualizerTargetWindow?) async -> Bool
    {
        await self.client.showMouseMovement(
            from: self.appKitPoint(from),
            to: self.appKitPoint(to),
            duration: duration,
            target: self.appKitTarget(target))
    }

    public func showScreenshotFlash(in rect: CGRect) async -> Bool {
        await self.client.showScreenshotFlash(in: self.appKitRect(rect))
    }

    public func showWatchCapture(in rect: CGRect) async -> Bool {
        await self.client.showWatchCapture(in: self.appKitRect(rect))
    }

    private var primaryScreenFrame: CGRect? {
        // `NSScreen.main` follows keyboard focus. The first screen is the
        // primary display whose origin defines the CG/AppKit flip axis.
        NSScreen.screens.first?.frame
    }

    private func appKitPoint(_ point: CGPoint) -> CGPoint {
        VisualizerScreenGeometry.appKitPoint(
            fromGlobalDisplay: point,
            primaryScreenFrame: self.primaryScreenFrame)
    }

    private func appKitRect(_ rect: CGRect) -> CGRect {
        VisualizerScreenGeometry.appKitRect(
            fromGlobalDisplay: rect,
            primaryScreenFrame: self.primaryScreenFrame)
    }

    private func appKitTarget(_ target: VisualizerTargetWindow?) -> VisualizerTargetWindow? {
        target.map {
            VisualizerTargetWindow(
                processIdentifier: $0.processIdentifier,
                windowID: $0.windowID,
                frame: self.appKitRect($0.frame))
        }
    }
}
