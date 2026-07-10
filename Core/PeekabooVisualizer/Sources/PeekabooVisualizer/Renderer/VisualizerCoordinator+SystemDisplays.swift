import CoreGraphics
import Foundation
import PeekabooFoundation
import PeekabooProtocols
import SwiftUI

// MARK: - System Display Methods

@available(macOS 14.0, *)
extension VisualizerCoordinator {
    func displayAppLaunchAnimation(appName: String, iconPath: String?) async -> Bool {
        // Check if enabled
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.appLifecycleEnabled ?? true
        else {
            return false
        }

        // Create app launch view
        let launchDuration = self.scaledDuration(AnimationBaseline.appLaunch)
        let launchView = AppLifecycleView(
            appName: appName,
            iconPath: iconPath,
            action: .launch,
            duration: launchDuration)

        // Position at center of screen where mouse is located
        let screen = self.getTargetScreen()
        let screenFrame = screen.frame
        let overlaySize = CGSize(width: 300, height: 300)
        let rect = CGRect(
            x: screenFrame.midX - overlaySize.width / 2,
            y: screenFrame.midY - overlaySize.height / 2,
            width: overlaySize.width,
            height: overlaySize.height)

        // Display using overlay manager
        _ = self.overlayManager.showAnimation(
            at: Self.paddedRect(rect, padding: Self.OverlayPadding.appLifecycle),
            content: launchView,
            duration: launchDuration,
            fadeOut: true,
            replaceKey: OverlaySlot.appLifecycle)

        return true
    }

    func displayAppQuitAnimation(appName: String, iconPath: String?) async -> Bool {
        // Check if enabled
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.appLifecycleEnabled ?? true
        else {
            return false
        }

        // Create app quit view
        let quitDuration = self.scaledDuration(AnimationBaseline.appQuit)
        let quitView = AppLifecycleView(
            appName: appName,
            iconPath: iconPath,
            action: .quit,
            duration: quitDuration)

        // Position at center of screen where mouse is located
        let screen = self.getTargetScreen()
        let screenFrame = screen.frame
        let overlaySize = CGSize(width: 300, height: 300)
        let rect = CGRect(
            x: screenFrame.midX - overlaySize.width / 2,
            y: screenFrame.midY - overlaySize.height / 2,
            width: overlaySize.width,
            height: overlaySize.height)

        // Display using overlay manager
        _ = self.overlayManager.showAnimation(
            at: Self.paddedRect(rect, padding: Self.OverlayPadding.appLifecycle),
            content: quitView,
            duration: quitDuration,
            fadeOut: true,
            replaceKey: OverlaySlot.appLifecycle)

        return true
    }

    func displayWindowOperation(
        _ operation: WindowOperation,
        windowRect: CGRect,
        duration: TimeInterval) async -> Bool
    {
        // Check if enabled
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.windowOperationEnabled ?? true
        else {
            return false
        }

        // Create window operation view
        let windowDuration = self.scaledDuration(for: duration, minimum: AnimationBaseline.windowOperation)
        let windowView = WindowOperationView(
            operation: operation,
            windowRect: windowRect,
            duration: windowDuration)

        // Display at window location
        _ = self.overlayManager.showAnimation(
            at: Self.paddedRect(windowRect, padding: Self.OverlayPadding.windowOperation),
            content: windowView,
            duration: windowDuration,
            fadeOut: true)

        return true
    }

    func displayMenuHighlights(menuPath: [String]) async -> Bool {
        // Check if enabled
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.menuNavigationEnabled ?? true
        else {
            return false
        }

        // Create menu navigation view
        let menuDuration = self.scaledDuration(AnimationBaseline.menuNavigation)
        let menuView = MenuNavigationView(
            menuPath: menuPath,
            duration: menuDuration)

        // Position at top of screen where mouse is located
        let screen = self.getTargetScreen()
        let screenFrame = screen.frame
        let overlaySize = Self.estimatedMenuOverlaySize(for: menuPath)
        let rect = CGRect(
            x: screenFrame.midX - overlaySize.width / 2,
            y: screenFrame.maxY - overlaySize.height - 50,
            width: overlaySize.width,
            height: overlaySize.height)

        // Display using overlay manager
        _ = self.overlayManager.showAnimation(
            at: Self.paddedRect(rect, padding: 0),
            content: menuView,
            duration: menuDuration,
            fadeOut: true,
            replaceKey: OverlaySlot.menu)

        return true
    }

    func displayDialogFeedback(
        element: DialogElementType,
        elementRect: CGRect,
        action: DialogActionType) async -> Bool
    {
        // Check if enabled
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.dialogInteractionEnabled ?? true
        else {
            return false
        }

        // Create dialog interaction view
        let dialogDuration = self.scaledDuration(AnimationBaseline.dialogInteraction)
        let dialogView = DialogInteractionView(
            element: element,
            elementRect: elementRect,
            action: action,
            duration: dialogDuration)

        // Display at element location
        _ = self.overlayManager.showAnimation(
            at: Self.paddedRect(elementRect, padding: Self.OverlayPadding.dialog),
            content: dialogView,
            duration: dialogDuration,
            fadeOut: true)

        return true
    }

    func displaySpaceTransition(from: Int, to: Int, direction: SpaceDirection) async -> Bool {
        // Check if enabled
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.spaceTransitionEnabled ?? true
        else {
            return false
        }

        // Create space transition view
        let spaceDuration = self.scaledDuration(AnimationBaseline.spaceTransition)
        let spaceView = SpaceTransitionView(
            from: from,
            to: to,
            direction: direction,
            duration: spaceDuration)

        // Display as a compact HUD centered on the screen where the mouse is
        let screen = self.getTargetScreen()
        let screenFrame = screen.frame
        let overlaySize = CGSize(width: 420, height: 180)
        let rect = CGRect(
            x: screenFrame.midX - overlaySize.width / 2,
            y: screenFrame.midY - overlaySize.height / 2,
            width: overlaySize.width,
            height: overlaySize.height)

        // Display using overlay manager
        _ = self.overlayManager.showAnimation(
            at: rect,
            content: spaceView,
            duration: spaceDuration,
            fadeOut: true,
            replaceKey: OverlaySlot.space)

        return true
    }

    func displayElementOverlays(elements: [String: CGRect], duration: TimeInterval) async -> Bool {
        // The default-off decision for element boxes lives in the *sender*
        // (SeeTool + VisualizationClient, gated by `PEEKABOO_VISUAL_ELEMENT_BOXES`
        // / `visualizer.elementDetectionEnabled`), mirroring how
        // `PEEKABOO_VISUAL_SCREENSHOTS` works: the receiver renders whatever
        // element-detection event it is handed once the top-level visualizer
        // switch is on. A second gate here would swallow the env/config opt-in.
        guard self.settings?.visualizerEnabled ?? true else {
            return false
        }

        // One overlay window per screen holds every highlight: hundreds of
        // per-element windows would crush the window server, and a refreshed
        // detection can crossfade the whole sheet via its replace slot.
        let highlightDuration = self.scaledDuration(for: duration, minimum: AnimationBaseline.elementHighlight)
        self.overlayManager.fadeOutAnimations(replaceKeyPrefix: OverlaySlot.elementSheetPrefix)
        for (index, screen) in NSScreen.screens.enumerated() {
            let screenFrame = screen.frame
            let onScreen = elements.filter { screenFrame.intersects($0.value) }
            let filtered = Self.filteredElementOverlays(
                onScreen,
                screenArea: screenFrame.width * screenFrame.height)
            guard !filtered.isEmpty else { continue }

            let positioned = filtered
                .map { id, rect in
                    ElementOverlaySheetView.PositionedElement(
                        id: id,
                        rect: Self.windowLocalRect(rect, in: screenFrame))
                }
                .sorted { $0.id < $1.id }

            let sheet = ElementOverlaySheetView(elements: positioned, duration: highlightDuration)
            _ = self.overlayManager.showAnimation(
                at: screenFrame,
                content: sheet,
                duration: highlightDuration,
                fadeOut: true,
                chromeMargin: 0,
                replaceKey: OverlaySlot.elementSheet(screenIndex: index))
        }

        return true
    }

    func displayAnnotatedScreenshot(
        imageData: Data,
        elements: [DetectedElement],
        windowBounds: CGRect,
        duration: TimeInterval) async -> Bool
    {
        // Check if enabled
        guard self.settings?.visualizerEnabled ?? true else {
            self.logger.info("🎯 Visualizer: Visualizer disabled in settings")
            return false
        }

        // Check if annotated screenshots are specifically enabled
        guard self.settings?.annotatedScreenshotEnabled ?? true else {
            self.logger.info("🎯 Visualizer: Annotated screenshot disabled in settings")
            return false
        }

        self.logger.info("🎯 Visualizer: Creating annotated screenshot view with \(elements.count) elements")

        // Filter to only enabled elements
        let enabledElements = elements.filter(\.isEnabled)

        // Create annotated screenshot view
        let overlayBounds = Self.paddedRect(windowBounds, padding: Self.OverlayPadding.annotatedScreenshot)
        let annotatedView = AnnotatedScreenshotView(
            imageData: imageData,
            elements: enabledElements,
            windowBounds: overlayBounds)

        // Display using overlay manager
        _ = self.overlayManager.showAnimation(
            at: overlayBounds,
            content: annotatedView,
            duration: self.scaledDuration(for: duration, minimum: AnimationBaseline.annotatedScreenshot),
            fadeOut: true,
            chromeMargin: 0,
            replaceKey: OverlaySlot.annotatedScreenshot)

        return true
    }
}
