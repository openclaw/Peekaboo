//
//  AnimationOverlayManager.swift
//  Peekaboo
//
//  Manages animation overlay windows for visualizer effects
//

import AppKit
import os
import SwiftUI

/// Manages overlay windows for animation effects
@MainActor
final class AnimationOverlayManager {
    private let logger = Logger(subsystem: "boo.peekaboo.visualizer", category: "AnimationOverlayManager")
    private var overlayWindows: [NSWindow] = []

    /// Live windows keyed by replace-key, so rapid streams of the same
    /// feedback kind crossfade into each other instead of stacking.
    private var replaceableWindows: [String: NSWindow] = [:]

    /// Extra breathing room added around every overlay so chip shadows and
    /// glows fade out naturally instead of getting cut off at the window edge.
    static let defaultChromeMargin: CGFloat = 40

    /// Shows an animation view in an overlay window.
    ///
    /// - Parameters:
    ///   - rect: Window rect in AppKit screen coordinates.
    ///   - content: The animation view; fixed-size content is centered.
    ///   - duration: How long the window stays before removal/fade.
    ///   - fadeOut: Whether to fade the window out at the end.
    ///   - chromeMargin: Extra margin added on all sides for shadows/glows.
    ///     Pass 0 for views that fill the window and position content in
    ///     window-local coordinates (trails, capture flashes).
    ///   - replaceKey: When set, an existing overlay with the same key is
    ///     quickly faded out and replaced, keeping at most one live window
    ///     per key (typing caption, hotkey chip, toasts, …).
    @discardableResult
    func showAnimation(
        at rect: CGRect,
        content: some View,
        duration: TimeInterval,
        fadeOut: Bool,
        chromeMargin: CGFloat = AnimationOverlayManager.defaultChromeMargin,
        replaceKey: String? = nil) -> NSWindow
    {
        self.logger
            .debug("Showing animation overlay at \(rect.debugDescription), duration: \(duration), fadeOut: \(fadeOut)")

        if let replaceKey, let previous = replaceableWindows.removeValue(forKey: replaceKey) {
            self.fadeOutAndRemove(previous, duration: 0.12)
        }

        let windowRect = chromeMargin > 0 ? rect.insetBy(dx: -chromeMargin, dy: -chromeMargin) : rect

        // Create overlay window
        let window = NSWindow(
            contentRect: windowRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)

        // Configure window
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false

        // Set content view. The root is wrapped in a flexible container so
        // fixed-size animation views center on the window instead of pinning
        // to its top-leading corner (which would offset them by the padding).
        let centeredContent = ZStack { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        let hostingView = NSHostingView(rootView: centeredContent)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.masksToBounds = false
        window.contentView = hostingView

        // Store window reference
        self.overlayWindows.append(window)
        if let replaceKey {
            self.replaceableWindows[replaceKey] = window
        }

        // Show window
        window.orderFront(nil)

        // Schedule removal
        Task { @MainActor in
            // Keep the overlay visible for the requested duration first.
            try? await Task.sleep(for: .seconds(duration))

            // A replacement may have already faded this window out.
            guard self.overlayWindows.contains(window) else { return }

            if let replaceKey, self.replaceableWindows[replaceKey] == window {
                self.replaceableWindows.removeValue(forKey: replaceKey)
            }

            guard fadeOut else {
                self.removeWindow(window)
                return
            }

            self.fadeOutAndRemove(window, duration: 0.3)
        }

        return window
    }

    /// Fades a window out over the given duration and removes it.
    private func fadeOutAndRemove(_ window: NSWindow, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            window.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                self.removeWindow(window)
            }
        }
    }

    /// Removes a specific overlay window
    private func removeWindow(_ window: NSWindow) {
        window.orderOut(nil)
        if let index = overlayWindows.firstIndex(of: window) {
            self.overlayWindows.remove(at: index)
        }
        self.replaceableWindows = self.replaceableWindows.filter { $0.value != window }
    }

    /// Removes all overlay windows
    func removeAllWindows() {
        for window in self.overlayWindows {
            window.orderOut(nil)
        }
        self.overlayWindows.removeAll()
        self.replaceableWindows.removeAll()
    }
}
