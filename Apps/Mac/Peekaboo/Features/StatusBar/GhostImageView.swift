import SwiftUI

// MARK: - Ghost Silhouette

/// The Peekaboo ghost silhouette: a smooth dome with gently flared sides and a
/// three-scoop scalloped hem. Drawn in normalized coordinates so it scales from
/// menu-bar sizes up to the empty-state hero.
struct GhostShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * width, y: rect.minY + y * height)
        }

        var path = Path()
        path.move(to: point(0.5, 0.02))
        // Dome, right half
        path.addCurve(to: point(0.94, 0.40), control1: point(0.76, 0.02), control2: point(0.94, 0.18))
        // Right side, flaring gently into the hem
        path.addCurve(to: point(0.92, 0.965), control1: point(0.945, 0.60), control2: point(0.975, 0.84))
        // Scalloped hem: three scoops between four tips
        path.addCurve(to: point(0.64, 0.965), control1: point(0.85, 0.845), control2: point(0.71, 0.845))
        path.addCurve(to: point(0.36, 0.965), control1: point(0.57, 0.845), control2: point(0.43, 0.845))
        path.addCurve(to: point(0.08, 0.965), control1: point(0.29, 0.845), control2: point(0.15, 0.845))
        // Left side back up to the dome
        path.addCurve(to: point(0.06, 0.40), control1: point(0.025, 0.84), control2: point(0.055, 0.60))
        path.addCurve(to: point(0.5, 0.02), control1: point(0.06, 0.18), control2: point(0.24, 0.02))
        path.closeSubpath()
        return path
    }
}

// MARK: - Ghost Eyes

/// Capsule eyes positioned relative to the ghost silhouette. `glance` shifts
/// both pupils sideways (-1 left … 1 right); `wide` is the startled look.
/// Color comes from the environment foreground style.
struct GhostEyesView: View {
    var glance: CGFloat = 0
    var wide = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let eyeWidth = width * (self.wide ? 0.115 : 0.10)
            let eyeHeight = height * (self.wide ? 0.20 : 0.17)
            let shift = self.glance * width * 0.045

            Capsule(style: .continuous)
                .frame(width: eyeWidth, height: eyeHeight)
                .position(x: width * 0.38 + shift, y: height * 0.40)
            Capsule(style: .continuous)
                .frame(width: eyeWidth, height: eyeHeight)
                .position(x: width * 0.62 + shift, y: height * 0.40)
        }
    }
}

// MARK: - Ghost Image

/// A SwiftUI view that provides ghost images for different states
struct GhostImageView: View {
    enum GhostState {
        case idle
        case peek1
        case peek2
    }

    let state: GhostState
    let size: CGSize

    @Environment(\.colorScheme) private var colorScheme

    init(state: GhostState = .idle, size: CGSize = CGSize(width: 64, height: 64)) {
        self.state = state
        self.size = size
    }

    var body: some View {
        ZStack {
            GhostShape()
                .fill(self.bodyGradient)
            if self.colorScheme == .light {
                GhostShape()
                    .stroke(Color.black.opacity(0.07), lineWidth: 0.5)
            }
            GhostEyesView(glance: self.state == .peek1 ? 1 : 0, wide: self.state == .peek2)
                .foregroundStyle(Color.black.opacity(0.82))
        }
        .compositingGroup()
        .shadow(
            color: .black.opacity(self.colorScheme == .dark ? 0.30 : 0.14),
            radius: self.size.height * 0.05,
            y: self.size.height * 0.03)
        .frame(width: self.size.width, height: self.size.height)
        .accessibilityHidden(true)
    }

    private var bodyGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white, location: 0.0),
                .init(color: Color(white: self.colorScheme == .dark ? 0.78 : 0.90), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom)
    }
}

// MARK: - Animated Glass Ghost

/// The hero ghost for empty states: a Liquid Glass surface on macOS 26+,
/// gently floating above a soft shadow while occasionally glancing around.
/// Falls back to a translucent material ghost on older systems.
struct AnimatedGhostView: View {
    var size: CGFloat = 108

    @State private var isFloating = false
    @State private var glance: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: self.size * 0.13) {
            self.ghostBody
                .frame(width: self.size, height: self.size * 1.06)
                .offset(y: self.isFloating ? -self.size * 0.04 : self.size * 0.04)

            Ellipse()
                .fill(.black.opacity(0.20))
                .frame(width: self.size * 0.52, height: self.size * 0.075)
                .blur(radius: self.size * 0.04)
                .scaleEffect(self.isFloating ? 0.78 : 1.02)
                .opacity(self.isFloating ? 0.65 : 1)
        }
        .onAppear {
            guard !self.reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                self.isFloating = true
            }
        }
        .task { await self.glanceAround() }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var ghostBody: some View {
        if #available(macOS 26.0, *) {
            GhostEyesView(glance: self.glance)
                .foregroundStyle(.primary.opacity(0.70))
                .glassEffect(.regular.tint(.white.opacity(0.25)).interactive(), in: GhostShape())
        } else {
            ZStack {
                GhostShape()
                    .fill(.ultraThinMaterial)
                GhostShape()
                    .fill(LinearGradient(
                        colors: [.white.opacity(0.45), .white.opacity(0.12)],
                        startPoint: .top,
                        endPoint: .bottom))
                GhostEyesView(glance: self.glance)
                    .foregroundStyle(.primary.opacity(0.70))
            }
        }
    }

    /// Peekaboo! Glance to a random side every few seconds, then back.
    private func glanceAround() async {
        guard !self.reduceMotion else { return }
        let spring = Animation.spring(response: 0.35, dampingFraction: 0.7)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.4...4.4)))
            guard !Task.isCancelled else { return }
            let direction: CGFloat = Bool.random() ? 1 : -1
            withAnimation(spring) { self.glance = direction }

            try? await Task.sleep(for: .seconds(Double.random(in: 0.8...1.3)))
            guard !Task.isCancelled else { return }
            withAnimation(spring) { self.glance = 0 }
        }
    }
}

#Preview("Ghost states") {
    HStack(spacing: 24) {
        GhostImageView(state: .idle, size: CGSize(width: 80, height: 80))
        GhostImageView(state: .peek1, size: CGSize(width: 80, height: 80))
        GhostImageView(state: .peek2, size: CGSize(width: 80, height: 80))
        AnimatedGhostView(size: 108)
    }
    .padding(40)
}
