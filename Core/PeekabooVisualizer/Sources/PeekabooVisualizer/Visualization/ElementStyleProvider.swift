//
import PeekabooFoundation

//  ElementStyleProvider.swift
//  PeekabooCore
//
//  Unified styling system for element visualization
//

import CoreGraphics
import Foundation

// MARK: - Style Provider Protocol

/// Protocol for providing visual styles for elements
@MainActor
public protocol ElementStyleProvider: Sendable {
    /// Get style for an element in a given state
    func style(for category: ElementCategory, state: ElementVisualizationState) -> ElementStyle

    /// Get indicator style for the visualization
    var indicatorStyle: IndicatorStyle {
        // Get style for an element in a given state
        get
    }

    /// Whether to show labels
    var showsLabels: Bool { get }

    /// Whether to show hover effects
    var supportsHoverState: Bool { get }
}

/// Style for element indicators
public enum IndicatorStyle: Sendable {
    /// Circle indicator in corner (Inspector style)
    case circle(diameter: Double, position: CornerPosition)

    /// Rectangle overlay (Annotation style)
    case rectangle

    /// Custom shape
    case custom

    public enum CornerPosition: Sendable {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }
}

// MARK: - Default Color Provider

/// Standard Peekaboo color palette
public enum PeekabooColorPalette {
    /// Blue - #007AFF (Buttons, Links, Menus)
    public static let interactive = CGColor(red: 0, green: 0.48, blue: 1.0, alpha: 1.0)

    /// Green - #34C759 (Text Fields, Text Areas)
    public static let input = CGColor(red: 0.204, green: 0.78, blue: 0.349, alpha: 1.0)

    /// Gray - #8E8E93 (Controls, Sliders, Checkboxes)
    public static let control = CGColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1.0)

    /// Orange - #FF9500 (Default, Other elements)
    public static let `default` = CGColor(red: 1.0, green: 0.584, blue: 0, alpha: 1.0)

    /// Get color for element category
    public static func color(for category: ElementCategory) -> CGColor {
        // Get color for element category
        switch category {
        case .button, .link, .menu:
            self.interactive
        case .textInput:
            self.input
        case .checkbox, .radioButton, .slider:
            self.control
        case .image, .container, .text, .custom:
            self.default
        }
    }
}

// MARK: - Default Style Provider

/// Default implementation of element style provider
@MainActor
public struct DefaultElementStyleProvider: ElementStyleProvider {
    public let indicatorStyle: IndicatorStyle
    public let showsLabels: Bool
    public let supportsHoverState: Bool

    private let baseOpacity: Double
    private let hoverOpacity: Double

    public init(
        indicatorStyle: IndicatorStyle = .rectangle,
        showsLabels: Bool = true,
        supportsHoverState: Bool = true,
        baseOpacity: Double = 0.2,
        hoverOpacity: Double = 0.3)
    {
        self.indicatorStyle = indicatorStyle
        self.showsLabels = showsLabels
        self.supportsHoverState = supportsHoverState
        self.baseOpacity = baseOpacity
        self.hoverOpacity = hoverOpacity
    }

    public func style(for category: ElementCategory, state: ElementVisualizationState) -> ElementStyle {
        let baseColor = PeekabooColorPalette.color(for: category)

        switch state {
        case .normal:
            return self.normalStyle(baseColor: baseColor)
        case .hovered:
            return self.hoverStyle(baseColor: baseColor)
        case .selected:
            return self.selectedStyle(baseColor: baseColor)
        case .disabled:
            return self.disabledStyle()
        }
    }
}

extension DefaultElementStyleProvider {
    private func normalStyle(baseColor: CGColor) -> ElementStyle {
        ElementStyle(
            primaryColor: baseColor,
            fillOpacity: self.baseOpacity,
            strokeWidth: 2.0,
            strokeOpacity: 1.0,
            cornerRadius: 4.0,
            shadow: nil,
            labelStyle: .default)
    }

    private func hoverStyle(baseColor: CGColor) -> ElementStyle {
        ElementStyle(
            primaryColor: baseColor,
            fillOpacity: self.hoverOpacity,
            strokeWidth: 2.5,
            strokeOpacity: 1.0,
            cornerRadius: 4.0,
            shadow: ShadowStyle(
                color: CGColor(gray: 0, alpha: 0.3),
                radius: 4,
                offsetX: 0,
                offsetY: 2),
            labelStyle: LabelStyle(
                fontSize: 12,
                fontWeight: .bold,
                backgroundColor: baseColor,
                textColor: CGColor(gray: 1, alpha: 1),
                padding: LabelStyle.EdgeInsets(horizontal: 8, vertical: 4)))
    }

    private func selectedStyle(baseColor: CGColor) -> ElementStyle {
        ElementStyle(
            primaryColor: baseColor,
            fillOpacity: 0.4,
            strokeWidth: 3.0,
            strokeOpacity: 1.0,
            cornerRadius: 4.0,
            shadow: ShadowStyle(
                color: baseColor.copy(alpha: 0.5)!,
                radius: 8,
                offsetX: 0,
                offsetY: 2),
            labelStyle: LabelStyle(
                fontSize: 12,
                fontWeight: .bold,
                backgroundColor: baseColor,
                textColor: CGColor(gray: 1, alpha: 1),
                padding: LabelStyle.EdgeInsets(horizontal: 8, vertical: 4)))
    }

    private func disabledStyle() -> ElementStyle {
        ElementStyle(
            primaryColor: PeekabooColorPalette.control,
            fillOpacity: 0.1,
            strokeWidth: 1.5,
            strokeOpacity: 0.5,
            cornerRadius: 4.0,
            shadow: nil,
            labelStyle: LabelStyle(
                fontSize: 11,
                fontWeight: .regular,
                backgroundColor: CGColor(gray: 0.5, alpha: 0.7),
                textColor: CGColor(gray: 1, alpha: 0.8),
                padding: LabelStyle.EdgeInsets(horizontal: 6, vertical: 3)))
    }
}
