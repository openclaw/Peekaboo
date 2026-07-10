//
//  VisualizerSettingsProviding.swift
//  PeekabooCore
//

import Foundation

@MainActor
public protocol VisualizerSettingsProviding: AnyObject {
    var visualizerEnabled: Bool { get }
    var visualizerAnimationSpeed: Double { get }
    var visualizerEffectIntensity: Double { get }

    var screenshotFlashEnabled: Bool { get }
    var clickAnimationEnabled: Bool { get }
    var typeAnimationEnabled: Bool { get }
    var scrollAnimationEnabled: Bool { get }
    var mouseTrailEnabled: Bool { get }
    var swipePathEnabled: Bool { get }
    var hotkeyOverlayEnabled: Bool { get }
    var appLifecycleEnabled: Bool { get }
    var windowOperationEnabled: Bool { get }
    var menuNavigationEnabled: Bool { get }
    var dialogInteractionEnabled: Bool { get }
    var spaceTransitionEnabled: Bool { get }
    /// Accessibility element bounding boxes during `see`. Off by default —
    /// outlining every detected control is visually noisy, so hosts (and the
    /// coordinator, when no settings source is connected) must opt in.
    var elementDetectionEnabled: Bool { get }
    var annotatedScreenshotEnabled: Bool { get }
    var watchCaptureHUDEnabled: Bool { get }
}
