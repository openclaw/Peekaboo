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

    public func showClickFeedback(at point: CGPoint, type: ClickType) async -> Bool {
        await self.client.showClickFeedback(at: self.appKitPoint(point), type: type)
    }

    public func showTypingFeedback(
        keys: [String],
        duration: TimeInterval,
        cadence: TypingCadence,
        masksTypedText: Bool) async -> Bool
    {
        await self.client.showTypingFeedback(
            keys: keys,
            duration: duration,
            cadence: cadence,
            masksTypedText: masksTypedText)
    }

    public func showScrollFeedback(at point: CGPoint, direction: ScrollDirection, amount: Int) async -> Bool {
        await self.client.showScrollFeedback(at: self.appKitPoint(point), direction: direction, amount: amount)
    }

    public func showHotkeyDisplay(keys: [String], duration: TimeInterval) async -> Bool {
        await self.client.showHotkeyDisplay(keys: keys, duration: duration)
    }

    public func showSwipeGesture(from: CGPoint, to: CGPoint, duration: TimeInterval) async -> Bool {
        await self.client.showSwipeGesture(
            from: self.appKitPoint(from),
            to: self.appKitPoint(to),
            duration: duration)
    }

    public func showMouseMovement(from: CGPoint, to: CGPoint, duration: TimeInterval) async -> Bool {
        await self.client.showMouseMovement(
            from: self.appKitPoint(from),
            to: self.appKitPoint(to),
            duration: duration)
    }

    public func showWindowOperation(
        _ kind: WindowOperationKind,
        windowRect: CGRect,
        duration: TimeInterval) async -> Bool
    {
        let op: WindowOperation = switch kind {
        case .close: .close
        case .minimize: .minimize
        case .maximize: .maximize
        case .move: .move
        case .resize: .resize
        case .setBounds: .setBounds
        case .focus: .focus
        }
        return await self.client.showWindowOperation(
            op,
            windowRect: self.appKitRect(windowRect),
            duration: duration)
    }

    public func showDialogInteraction(
        element: DialogElementType,
        elementRect: CGRect,
        action: DialogActionType) async -> Bool
    {
        await self.client.showDialogInteraction(
            element: element,
            elementRect: self.appKitRect(elementRect),
            action: action)
    }

    public func showMenuNavigation(menuPath: [String]) async -> Bool {
        await self.client.showMenuNavigation(menuPath: menuPath)
    }

    public func showSpaceSwitch(from: Int, to: Int, direction: SpaceSwitchDirection) async -> Bool {
        let mapped: SpaceDirection = switch direction {
        case .left: .left
        case .right: .right
        }
        return await self.client.showSpaceSwitch(from: from, to: to, direction: mapped)
    }

    public func showAppLaunch(appName: String, iconPath: String?) async -> Bool {
        await self.client.showAppLaunch(appName: appName, iconPath: iconPath)
    }

    public func showAppQuit(appName: String, iconPath: String?) async -> Bool {
        await self.client.showAppQuit(appName: appName, iconPath: iconPath)
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
}
