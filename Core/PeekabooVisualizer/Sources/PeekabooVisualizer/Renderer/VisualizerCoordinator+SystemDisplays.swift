import AppKit
import CoreGraphics
import Foundation
import PeekabooProtocols
import SwiftUI

@available(macOS 14.0, *)
extension VisualizerCoordinator {
    func displayElementOverlays(elements: [String: CGRect], duration: TimeInterval) async -> Bool {
        guard self.settings?.visualizerEnabled ?? true else { return false }

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
            _ = self.overlayManager.showAnimation(
                at: screenFrame,
                content: ElementOverlaySheetView(elements: positioned, duration: highlightDuration),
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
        guard self.settings?.visualizerEnabled ?? true else { return false }
        let overlayBounds = Self.paddedRect(windowBounds, padding: Self.OverlayPadding.annotatedScreenshot)
        let annotatedView = AnnotatedScreenshotView(
            imageData: imageData,
            elements: elements.filter(\.isEnabled),
            windowBounds: overlayBounds)
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
