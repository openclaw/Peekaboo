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
    // Note: element-detection boxes are gated in the sender (SeeTool /
    // VisualizationClient), not the renderer, so there is intentionally no
    // `elementDetectionEnabled` member here. See `displayElementOverlays`.
    var annotatedScreenshotEnabled: Bool { get }
    var watchCaptureHUDEnabled: Bool { get }
}
