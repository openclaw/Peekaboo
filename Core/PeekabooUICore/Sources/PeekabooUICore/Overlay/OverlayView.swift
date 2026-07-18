//
//  OverlayView.swift
//  PeekabooUICore
//
//  Individual element overlay visualization
//

import AppKit
import PeekabooCore
import SwiftUI

public struct OverlayView: View {
    let element: OverlayManager.UIElement
    let preset: any ElementStyleProvider
    @State private var isHovered = false
    @State private var animateIn = false

    public init(element: OverlayManager.UIElement, preset: any ElementStyleProvider = InspectorVisualizationPreset()) {
        self.element = element
        self.preset = preset
    }

    public var body: some View {
        let style = self.preset.style(
            for: self.roleToCategory(self.element.role),
            state: self.elementState)

        ZStack(alignment: .topLeading) {
            // Main overlay shape
            self.overlayShape(style: style)

            // Label if enabled
            if self.preset.showsLabels || self.isHovered {
                self.labelView(style: style)
                    .offset(x: 0, y: -28)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .frame(width: self.element.frame.width, height: self.element.frame.height)
        .scaleEffect(self.animateIn ? 1.0 : 0.95)
        .opacity(self.animateIn ? 1.0 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) {
                self.animateIn = true
            }

            // Debug logging for troubleshooting
            #if DEBUG
            if self.element.elementID.hasPrefix("B") || self.element.elementID.hasPrefix("C") || self.element.elementID
                .hasPrefix("Peekaboo")
            {
                self.logElementInfo()
            }
            #endif
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                self.isHovered = hovering
            }
        }
    }

    private var elementState: ElementVisualizationState {
        if !self.element.isEnabled {
            .disabled
        } else if self.isHovered, self.preset.supportsHoverState {
            .hovered
        } else {
            .normal
        }
    }

    @ViewBuilder
    private func overlayShape(style: ElementStyle) -> some View {
        switch self.preset.indicatorStyle {
        case .rectangle:
            RoundedRectangle(cornerRadius: style.cornerRadius)
                .fill(Color(cgColor: style.primaryColor).opacity(style.fillOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: style.cornerRadius)
                        .strokeBorder(
                            Color(cgColor: style.primaryColor).opacity(style.strokeOpacity),
                            lineWidth: style.strokeWidth))
                .shadow(
                    color: self.shadowColor(from: style.shadow),
                    radius: style.shadow?.radius ?? 0,
                    x: style.shadow?.offsetX ?? 0,
                    y: style.shadow?.offsetY ?? 0)
        case .circle, .custom:
            // Corner indicators
            CornerIndicatorsView(
                style: style,
                size: CGSize(width: self.element.frame.width, height: self.element.frame.height))
        }
    }

    @ViewBuilder
    private func labelView(style: ElementStyle) -> some View {
        let labelStyle = style.labelStyle
        HStack(spacing: 4) {
            Text(self.element.elementID)
                .font(.system(size: labelStyle.fontSize, weight: self.fontWeight(labelStyle.fontWeight)))
                .foregroundColor(Color(cgColor: labelStyle.textColor))

            if !self.element.displayName.isEmpty, self.element.displayName != self.element.role {
                Text("•")
                    .foregroundColor(Color(cgColor: labelStyle.textColor).opacity(0.5))

                Text(self.element.displayName)
                    .font(.system(size: labelStyle.fontSize - 1))
                    .foregroundColor(Color(cgColor: labelStyle.textColor).opacity(0.9))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, labelStyle.padding.horizontal)
        .padding(.vertical, labelStyle.padding.vertical)
        .background(
            labelStyle.backgroundColor.map { Color(cgColor: $0) }?
                .cornerRadius(4))
    }

    private func shadowColor(from shadow: PeekabooCore.ShadowStyle?) -> Color {
        guard let shadow else { return .clear }
        return Color(cgColor: shadow.color)
    }

    private func fontWeight(_ weight: PeekabooCore.LabelStyle.FontWeight) -> Font.Weight {
        switch weight {
        case .regular: .regular
        case .medium: .medium
        case .bold: .bold
        }
    }

    private func roleToCategory(_ role: String) -> ElementCategory {
        switch role {
        case "AXButton", "AXPopUpButton":
            .button
        case "AXTextField", "AXTextArea":
            .textInput
        case "AXLink":
            .link
        case "AXStaticText":
            .text
        case "AXGroup":
            .container
        case "AXSlider":
            .slider
        case "AXCheckBox":
            .checkbox
        case "AXRadioButton":
            .radioButton
        case "AXMenu", "AXMenuItem", "AXMenuBar":
            .menu
        case "AXTable", "AXOutline", "AXScrollArea":
            .container
        default:
            .text
        }
    }

    #if DEBUG
    private func logElementInfo() {
        print("🔍 Element \(self.element.elementID) (\(self.element.displayName)): frame = \(self.element.frame)")
        print("   App: \(self.element.appBundleID)")
        print("   Role: \(self.element.role)")
        print("   Enabled: \(self.element.isEnabled)")
        print("   Actionable: \(self.element.isActionable)")
    }
    #endif
}

// MARK: - Corner Indicators View

struct CornerIndicatorsView: View {
    let style: ElementStyle
    let size: CGSize

    private let cornerSize: CGFloat = 16
    private let cornerThickness: CGFloat = 3

    var body: some View {
        ZStack {
            // Top-left corner
            CornerShape(corner: .topLeft)
                .stroke(Color(cgColor: self.style.primaryColor), lineWidth: self.cornerThickness)
                .frame(width: self.cornerSize, height: self.cornerSize)
                .position(x: 0, y: 0)

            // Top-right corner
            CornerShape(corner: .topRight)
                .stroke(Color(cgColor: self.style.primaryColor), lineWidth: self.cornerThickness)
                .frame(width: self.cornerSize, height: self.cornerSize)
                .position(x: self.size.width, y: 0)

            // Bottom-left corner
            CornerShape(corner: .bottomLeft)
                .stroke(Color(cgColor: self.style.primaryColor), lineWidth: self.cornerThickness)
                .frame(width: self.cornerSize, height: self.cornerSize)
                .position(x: 0, y: self.size.height)

            // Bottom-right corner
            CornerShape(corner: .bottomRight)
                .stroke(Color(cgColor: self.style.primaryColor), lineWidth: self.cornerThickness)
                .frame(width: self.cornerSize, height: self.cornerSize)
                .position(x: self.size.width, y: self.size.height)
        }
    }

    struct CornerShape: Shape {
        enum Corner {
            case topLeft, topRight, bottomLeft, bottomRight
        }

        let corner: Corner

        nonisolated func path(in rect: CGRect) -> SwiftUI.Path {
            var path = SwiftUI.Path()

            switch self.corner {
            case .topLeft:
                path.move(to: CGPoint(x: 0, y: rect.height))
                path.addLine(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: rect.width, y: 0))
            case .topRight:
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: rect.width, y: 0))
                path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            case .bottomLeft:
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: rect.height))
                path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            case .bottomRight:
                path.move(to: CGPoint(x: 0, y: rect.height))
                path.addLine(to: CGPoint(x: rect.width, y: rect.height))
                path.addLine(to: CGPoint(x: rect.width, y: 0))
            }

            return path
        }
    }
}
