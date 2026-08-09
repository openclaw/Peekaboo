import CoreGraphics
import Foundation
import PeekabooFoundation
import SwiftUI

@available(macOS 14.0, *)
extension VisualizerCoordinator {
    func displayScreenshotBorder(in rect: CGRect) async -> Bool {
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.captureIndicatorsEnabled ?? true
        else {
            return false
        }

        _ = self.overlayManager.showAnimation(
            at: rect,
            content: ScreenshotFlashView(intensity: self.settings?.visualizerEffectIntensity ?? 1),
            duration: 0.2,
            fadeOut: false,
            chromeMargin: 0)
        return true
    }

    func displayWatchHUD(in rect: CGRect, sequence: Int) async -> Bool {
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.captureIndicatorsEnabled ?? true
        else {
            return false
        }
        _ = self.overlayManager.showAnimation(
            at: Self.paddedRect(rect, padding: Self.OverlayPadding.watchHUD),
            content: WatchCaptureHUDView(sequence: sequence),
            duration: self.scaledDuration(2.4),
            fadeOut: true,
            replaceKey: OverlaySlot.watchHUD)
        return true
    }

    func displayClickPulse(at point: CGPoint, type: ClickType) async -> Bool {
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.agentCursorEnabled ?? true
        else {
            return false
        }
        let size: CGFloat = 40
        _ = self.overlayManager.showAnimation(
            at: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size),
            content: ClickAnimationView(clickType: type),
            duration: 0.3,
            fadeOut: false,
            chromeMargin: 0,
            replaceKey: OverlaySlot.click)
        return true
    }

    func displayInputHUD(
        _ content: InputHUDView.Content,
        target: VisualizerTargetWindow,
        duration: TimeInterval) async -> Bool
    {
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.inputHUDEnabled ?? true
        else {
            return false
        }

        let frame = target.frame
        let width = min(420, max(frame.width - 32, 1))
        guard width >= 120, frame.height >= 60 else { return false }
        let rect = CGRect(
            x: frame.midX - width / 2,
            y: frame.minY + 16,
            width: width,
            height: 42)
        _ = self.overlayManager.showAnimation(
            at: rect,
            content: InputHUDView(content: content),
            duration: duration,
            fadeOut: true,
            chromeMargin: 0,
            replaceKey: OverlaySlot.inputHUD)
        return true
    }

    func displayAgentCursor(
        from: CGPoint,
        to: CGPoint,
        duration: TimeInterval,
        isPressed: Bool) async -> Bool
    {
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.agentCursorEnabled ?? true
        else {
            return false
        }
        let windowRect = Self.travelWindowRect(from: from, to: to, padding: Self.OverlayPadding.agentCursor)
        let movementDuration = self.scaledDuration(
            for: duration,
            minimum: AnimationBaseline.agentCursor,
            applySlowdown: false)
        _ = self.overlayManager.showAnimation(
            at: windowRect,
            content: AgentCursorView(
                from: Self.windowLocalPoint(from, in: windowRect),
                to: Self.windowLocalPoint(to, in: windowRect),
                duration: movementDuration,
                isPressed: isPressed),
            duration: movementDuration + 0.14,
            fadeOut: false,
            chromeMargin: 0,
            replaceKey: OverlaySlot.pointer)
        return true
    }
}
