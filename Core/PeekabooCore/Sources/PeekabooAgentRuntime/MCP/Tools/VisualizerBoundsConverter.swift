//
//  VisualizerBoundsConverter.swift
//  PeekabooAgentRuntime
//

import CoreGraphics
import PeekabooAutomation
import PeekabooProtocols
import PeekabooVisualizer

enum VisualizerBoundsConverter {
    static func convertGlobalAccessibilityRect(_ rect: CGRect, primaryScreenFrame: CGRect?) -> CGRect {
        VisualizerScreenGeometry.appKitRect(
            fromGlobalDisplay: rect,
            primaryScreenFrame: primaryScreenFrame)
    }

    /// Convert automation-detected elements into the bounds format expected by the visualizer overlay.
    @MainActor
    static func makeVisualizerElements(
        from elements: [PeekabooAutomation.DetectedElement],
        primaryScreenFrame: CGRect?) -> [PeekabooProtocols.DetectedElement]
    {
        elements.map { element in
            let convertedBounds = VisualizerScreenGeometry.appKitRect(
                fromGlobalDisplay: element.bounds,
                primaryScreenFrame: primaryScreenFrame)
            return PeekabooProtocols.DetectedElement(
                id: element.id,
                type: element.type,
                bounds: convertedBounds,
                label: element.label,
                value: element.value,
                isEnabled: element.isEnabled)
        }
    }
}
