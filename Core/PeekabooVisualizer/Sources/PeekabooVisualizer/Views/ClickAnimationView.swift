//
//  ClickAnimationView.swift
//  Peekaboo
//
//  A macOS-style cursor that glides to the click point and visibly presses.
//

import PeekabooFoundation
import SwiftUI

/// Click feedback: a cursor glides onto the point, presses, and emits a subtle ripple.
/// Double-click presses twice; right-click uses the secondary accent.
struct ClickAnimationView: View {
    // MARK: - Properties

    /// Type of click
    let clickType: ClickType

    /// Multiplier applied to all baseline durations (larger = slower).
    let durationScale: Double

    /// Animation state
    @State private var cursorOffset = CGSize(width: 60, height: 50)
    @State private var cursorOpacity: Double = 0
    @State private var cursorScale: CGFloat = 1.12

    private let clickPoint = CGPoint(x: 160, y: 160)

    private var tint: Color {
        self.clickType == .right ? VisualizerTheme.accentSecondary : VisualizerTheme.accent
    }

    private var pressDelays: [Double] {
        self.clickType == .double ? [0.36, 0.62] : [0.36]
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(self.pressDelays.enumerated()), id: \.offset) { _, delay in
                ClickRippleView(
                    tint: self.tint,
                    delay: delay * self.durationScale,
                    duration: 0.3 * self.durationScale)
                    .position(self.clickPoint)
            }

            CursorGlyphView()
                .scaleEffect(self.cursorScale, anchor: .topLeading)
                .opacity(self.cursorOpacity)
                .offset(
                    x: self.clickPoint.x + self.cursorOffset.width,
                    y: self.clickPoint.y + self.cursorOffset.height)
        }
        .frame(width: 320, height: 320)
        .task {
            await self.startAnimation()
        }
    }

    // MARK: - Methods

    private func startAnimation() async {
        let scale = self.durationScale

        withAnimation(VisualizerMotion.enter(0.12 * scale)) {
            self.cursorOpacity = 1
        }
        withAnimation(VisualizerMotion.glide(0.32 * scale)) {
            self.cursorOffset = .zero
            self.cursorScale = 1
        }

        await self.sleep(0.36 * scale)
        guard !Task.isCancelled else { return }
        withAnimation(VisualizerMotion.pop(0.1 * scale)) {
            self.cursorScale = 0.82
        }

        await self.sleep(0.14 * scale)
        guard !Task.isCancelled else { return }
        withAnimation(VisualizerMotion.settle(0.16 * scale)) {
            self.cursorScale = 1
        }

        if self.clickType == .double {
            await self.sleep(0.12 * scale)
            guard !Task.isCancelled else { return }
            withAnimation(VisualizerMotion.pop(0.1 * scale)) {
                self.cursorScale = 0.82
            }

            await self.sleep(0.14 * scale)
            guard !Task.isCancelled else { return }
            withAnimation(VisualizerMotion.settle(0.16 * scale)) {
                self.cursorScale = 1
            }
        }

        await self.sleep(0.2 * scale)
        guard !Task.isCancelled else { return }
        withAnimation(VisualizerMotion.exit(0.15 * scale)) {
            self.cursorOpacity = 0
        }
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// A small expanding click ring centered on the cursor hotspot.
private struct ClickRippleView: View {
    let tint: Color
    let delay: Double
    let duration: Double

    @State private var diameter: CGFloat = 10
    @State private var rippleOpacity: Double = 0

    var body: some View {
        Circle()
            .stroke(self.tint, lineWidth: 1.5)
            .frame(width: self.diameter, height: self.diameter)
            .opacity(self.rippleOpacity)
            .task {
                await self.animateRipple()
            }
    }

    private func animateRipple() async {
        await self.sleep(self.delay)
        guard !Task.isCancelled else { return }
        withAnimation(VisualizerMotion.enter(0.02 * self.duration / 0.3)) {
            self.rippleOpacity = 0.85
        }
        withAnimation(VisualizerMotion.glide(self.duration)) {
            self.diameter = 34
        }

        await self.sleep(self.duration * 0.1)
        guard !Task.isCancelled else { return }
        withAnimation(VisualizerMotion.exit(self.duration * 0.9)) {
            self.rippleOpacity = 0
        }
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - Preview

#if DEBUG && !SWIFT_PACKAGE
#Preview("Single Click") {
    ClickAnimationView(clickType: .single, durationScale: 3.0)
        .frame(width: 320, height: 320)
        .background(Color.gray.opacity(0.3))
}

#Preview("Double Click") {
    ClickAnimationView(clickType: .double, durationScale: 3.0)
        .frame(width: 320, height: 320)
        .background(Color.gray.opacity(0.3))
}

#Preview("Right Click") {
    ClickAnimationView(clickType: .right, durationScale: 3.0)
        .frame(width: 320, height: 320)
        .background(Color.gray.opacity(0.3))
}
#endif
