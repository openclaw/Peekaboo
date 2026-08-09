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

    var agentCursorEnabled: Bool { get }
    var inputHUDEnabled: Bool { get }
    var captureIndicatorsEnabled: Bool { get }
    // Note: element-detection boxes are gated in the sender (SeeTool /
    // VisualizationClient), not the renderer, so there is intentionally no
    // `elementDetectionEnabled` member here. See `displayElementOverlays`.
}
