//
//  ModernEffects.swift
//  Peekaboo
//

import AppKit
import SwiftUI

// MARK: - Modern Visual Effects with Platform-Appropriate Styling

/// Provides modern visual effects that look native on each macOS version
/// - macOS 14-25: Uses native materials and standard macOS styling
/// - macOS 26+: Uses new Liquid Glass effects when available
@available(macOS 14.0, *)
struct ModernEffectView<Content: View>: View {
    let style: ModernEffectStyle
    let cornerRadius: CGFloat
    let content: Content

    init(
        style: ModernEffectStyle = .automatic,
        cornerRadius: CGFloat = 10, // macOS standard corner radius
        @ViewBuilder content: () -> Content)
    {
        self.style = style
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            // Use new Liquid Glass on macOS 26+
            NativeGlassWrapper(
                style: self.style,
                cornerRadius: self.cornerRadius,
                content: self.content)
        } else {
            // Use standard macOS materials for 14-25
            self.content
                .background {
                    RoundedRectangle(cornerRadius: self.cornerRadius)
                        .fill(self.style.nativeMaterial)
                }
                .clipShape(RoundedRectangle(cornerRadius: self.cornerRadius))
        }
    }
}

// MARK: - Effect Styles

enum ModernEffectStyle {
    case automatic
    case sidebar
    case content
    case popover
    case hudWindow
    case toolbar
    case selection

    /// Returns the appropriate native material for macOS 14-25
    var nativeMaterial: Material {
        switch self {
        case .automatic:
            .regular
        case .sidebar:
            .bar // Sidebar-appropriate material
        case .content:
            .regularMaterial
        case .popover:
            .ultraThinMaterial // Light material for popovers
        case .hudWindow:
            .ultraThickMaterial // Heavy material for HUD
        case .toolbar:
            .bar // Toolbar-appropriate material
        case .selection:
            .thick // Selection highlighting
        }
    }

    /// Returns the glass style for macOS 26+
    @available(macOS 26.0, *)
    var glassStyle: NSGlassEffectView.Style {
        // This will map to appropriate glass styles when available
        // For now, using placeholder since the enum isn't defined yet
        NSGlassEffectView.Style(rawValue: 0)!
    }
}

// MARK: - Native Glass Wrapper for macOS 26+

private let nativeGlassHostingViewIdentifier = NSUserInterfaceItemIdentifier("Peekaboo.NativeGlassHostingView")

@available(macOS 26.0, *)
struct NativeGlassWrapper<Content: View>: NSViewRepresentable {
    let style: ModernEffectStyle
    let cornerRadius: CGFloat
    let content: Content

    func makeNSView(context: Context) -> NSGlassEffectView {
        let glassView = NSGlassEffectView()
        glassView.cornerRadius = self.cornerRadius
        glassView.style = self.style.glassStyle

        let hostingView = makeHostedContentView(content, identifier: nativeGlassHostingViewIdentifier)

        if let contentView = glassView.contentView {
            contentView.addSubview(hostingView)
            pinHostedContentView(hostingView, to: contentView)
        } else {
            glassView.addSubview(hostingView)
            pinHostedContentView(hostingView, to: glassView)
        }

        return glassView
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        nsView.cornerRadius = self.cornerRadius
        nsView.style = self.style.glassStyle
        hostedContentView(
            identifiedBy: nativeGlassHostingViewIdentifier,
            in: nsView.contentView,
            fallbackView: nsView)?.rootView = self.content
    }
}

// MARK: - View Extensions for Easy Adoption

extension View {
    /// Applies platform-appropriate modern background
    func modernBackground(
        style: ModernEffectStyle = .automatic,
        cornerRadius: CGFloat = 10) -> some View
    {
        background {
            ModernEffectView(style: style, cornerRadius: cornerRadius) {
                Color.clear
            }
        }
    }
}
