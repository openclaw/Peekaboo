//
//  OverlayWindowController.swift
//  PeekabooUICore
//
//  Manages transparent overlay windows for UI element visualization
//

import AppKit
import SwiftUI

/// Controller for managing overlay windows
@MainActor
public class OverlayWindowController {
    private var overlayWindows: [NSScreen: NSWindow] = [:]
    private let overlayManager: OverlayManager
    private let preset: any ElementStyleProvider
    private let notificationCenter: NotificationCenter
    private var screenChangeObserver: (any NSObjectProtocol)?

    public convenience init(
        overlayManager: OverlayManager,
        preset: any ElementStyleProvider = InspectorVisualizationPreset())
    {
        self.init(overlayManager: overlayManager, preset: preset, notificationCenter: .default)
    }

    init(
        overlayManager: OverlayManager,
        preset: any ElementStyleProvider = InspectorVisualizationPreset(),
        notificationCenter: NotificationCenter)
    {
        self.overlayManager = overlayManager
        self.preset = preset
        self.notificationCenter = notificationCenter
    }

    isolated deinit {
        self.stopMonitoringScreenChanges()
    }

    /// Shows overlay windows on all screens
    public func showOverlays() {
        for screen in NSScreen.screens {
            self.showOverlay(on: screen)
        }
    }

    /// Hides all overlay windows
    public func hideOverlays() {
        for window in self.overlayWindows.values {
            window.orderOut(nil)
        }
    }

    /// Removes all overlay windows
    public func removeOverlays() {
        for window in self.overlayWindows.values {
            window.close()
        }
        self.overlayWindows.removeAll()
    }

    /// Updates overlay visibility based on manager state
    public func updateVisibility() {
        if self.overlayManager.isOverlayActive {
            self.showOverlays()
        } else {
            self.hideOverlays()
        }
    }

    // MARK: - Private Methods

    private func showOverlay(on screen: NSScreen) {
        let window = self.overlayWindows[screen] ?? self.createOverlayWindow(for: screen)

        // Update content
        let overlayView = AllAppsOverlayView(overlayManager: overlayManager, preset: preset)
        window.contentView = NSHostingView(rootView: overlayView)

        // Position and show
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()

        self.overlayWindows[screen] = window
    }

    private func createOverlayWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen)

        // Configure window
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        // Make window click-through
        window.styleMask.insert(.nonactivatingPanel)

        return window
    }
}

// MARK: - Screen Change Monitoring

extension OverlayWindowController {
    /// Starts monitoring for screen configuration changes
    public func startMonitoringScreenChanges() {
        guard self.screenChangeObserver == nil else { return }
        self.screenChangeObserver = self.notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main)
        { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenChange()
            }
        }
    }

    /// Stops monitoring screen changes
    public func stopMonitoringScreenChanges() {
        if let screenChangeObserver {
            self.notificationCenter.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
    }

    private func handleScreenChange() {
        // Remove windows for screens that no longer exist
        let currentScreens = Set(NSScreen.screens)
        let windowScreens = Set(overlayWindows.keys)

        for screen in windowScreens.subtracting(currentScreens) {
            self.overlayWindows[screen]?.close()
            self.overlayWindows.removeValue(forKey: screen)
        }

        // Update overlay visibility
        if self.overlayManager.isOverlayActive {
            self.showOverlays()
        }
    }
}
