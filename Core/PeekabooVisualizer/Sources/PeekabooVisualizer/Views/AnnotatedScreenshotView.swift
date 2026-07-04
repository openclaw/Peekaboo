//
//  AnnotatedScreenshotView.swift
//  Peekaboo
//
//  Created by Peekaboo on 2025-01-30.
//

import Foundation
import PeekabooFoundation
import PeekabooProtocols
import SwiftUI

/// A view that displays live UI element annotations as an overlay
struct AnnotatedScreenshotView: View {
    // MARK: - Properties

    /// The screenshot image data (kept for compatibility but not used)
    let imageData: Data

    /// The detected UI elements to overlay
    let elements: [DetectedElement]

    /// Window bounds for coordinate mapping
    let windowBounds: CGRect

    /// Animation state
    @State private var elementOpacity: Double = 0
    @State private var labelScale: Double = 0.8

    // Use core visualization system
    private let styleProvider = AnnotationVisualizationPreset()
    private let layoutEngine = ElementLayoutEngine()
    private let idGenerator = ElementIDGenerator.shared

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Transparent background
                Color.clear

                // Element overlays only
                ForEach(self.elements, id: \.id) { element in
                    self.elementOverlay(for: element, in: geometry.size)
                }
            }
        }
        .background(Color.clear)
        .onAppear {
            self.startAnimation()
        }
    }

    // MARK: - Methods

    /// Create overlay for a single element
    @ViewBuilder
    private func elementOverlay(for element: DetectedElement, in viewSize: CGSize) -> some View {
        // Convert DetectedElement type to ElementCategory
        let category = self.elementCategoryFromType(element.type)

        // Get style from the preset
        let elementState: ElementVisualizationState = element.isEnabled ? .normal : .disabled
        let style = self.styleProvider.style(for: category, state: elementState)

        // Transform coordinates
        let transformedBounds = VisualizerScreenGeometry.windowLocalRect(
            element.bounds,
            in: self.windowBounds)

        // Convert CGColor to SwiftUI Color
        let primaryColor = Color(cgColor: style.primaryColor)

        // Element highlight box
        RoundedRectangle(cornerRadius: style.cornerRadius)
            .fill(primaryColor.opacity(style.fillOpacity))
            .overlay(
                RoundedRectangle(cornerRadius: style.cornerRadius)
                    .stroke(primaryColor.opacity(style.strokeOpacity), lineWidth: style.strokeWidth))
            .frame(width: transformedBounds.width, height: transformedBounds.height)
            .position(
                x: transformedBounds.midX,
                y: transformedBounds.midY)
            .opacity(self.elementOpacity)

        // Element ID label with style
        let labelStyle = style.labelStyle
        Text(element.id)
            .font(.system(
                size: labelStyle.fontSize,
                weight: labelStyle.fontWeight == .bold ? .bold : .regular,
                design: .monospaced))
            .foregroundColor(Color(cgColor: labelStyle.textColor))
            .padding(.horizontal, labelStyle.padding.horizontal)
            .padding(.vertical, labelStyle.padding.vertical)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(cgColor: labelStyle.backgroundColor ?? style.primaryColor))
                    .if(style.shadow != nil) { view in
                        view.shadow(
                            color: Color(cgColor: style.shadow!.color).opacity(Double(style.shadow!.color.alpha)),
                            radius: style.shadow!.radius,
                            x: style.shadow!.offsetX,
                            y: style.shadow!.offsetY)
                    })
            .scaleEffect(self.labelScale)
            .position(self.labelPosition(for: transformedBounds, in: viewSize))
            .opacity(self.elementOpacity)
    }

    /// Calculate label position (prefer above element)
    private func labelPosition(for rect: CGRect, in viewSize: CGSize) -> CGPoint {
        let labelHeight: CGFloat = 20
        let spacing: CGFloat = 4

        // Try above first
        let aboveY = rect.minY - spacing - labelHeight / 2
        if aboveY > labelHeight / 2 {
            return CGPoint(x: rect.midX, y: aboveY)
        }

        // Try below
        let belowY = rect.maxY + spacing + labelHeight / 2
        if belowY < viewSize.height - labelHeight / 2 {
            return CGPoint(x: rect.midX, y: belowY)
        }

        // Fall back to center
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// Convert DetectedElement type to ElementCategory
    private func elementCategoryFromType(_ type: ElementType) -> ElementCategory {
        switch type {
        case .button:
            .button
        case .textField:
            .textInput
        case .link:
            .link
        case .image:
            .image
        case .group:
            .container
        case .slider:
            .slider
        case .checkbox:
            .checkbox
        case .menu, .menuItem:
            .menu
        case .staticText:
            .custom("label")
        case .radioButton:
            .radioButton
        case .window:
            .custom("window")
        case .dialog:
            .custom("dialog")
        case .other:
            .custom("other")
        }
    }

    /// Start the fade-in animation
    private func startAnimation() {
        // Fade in elements
        withAnimation(.easeOut(duration: 0.3)) {
            self.elementOpacity = 1.0
        }

        // Scale up labels
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            self.labelScale = 1.0
        }
    }
}

// MARK: - Preview

#if DEBUG && !SWIFT_PACKAGE
#Preview("Annotated Screenshot") {
    // Create sample data
    let sampleElements = [
        DetectedElement(
            id: "B1",
            type: .button,
            bounds: CGRect(x: 100, y: 100, width: 80, height: 30),
            label: "Submit",
            isEnabled: true),
        DetectedElement(
            id: "T1",
            type: .textField,
            bounds: CGRect(x: 100, y: 200, width: 200, height: 30),
            label: "Email",
            isEnabled: true),
    ]

    // Use a placeholder image
    let placeholderImage = NSImage(systemSymbolName: "rectangle", accessibilityDescription: nil)!
    let imageData = placeholderImage.tiffRepresentation!

    AnnotatedScreenshotView(
        imageData: imageData,
        elements: sampleElements,
        windowBounds: CGRect(x: 0, y: 0, width: 400, height: 300))
        .frame(width: 400, height: 300)
}
#endif

// MARK: - View Extensions

extension View {
    /// Conditionally apply a modifier
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
