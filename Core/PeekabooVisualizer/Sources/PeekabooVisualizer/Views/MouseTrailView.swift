//
//  MouseTrailView.swift
//  Peekaboo
//
//  A macOS-style cursor tracing its travel with a subtle tapered trail.
//

import SwiftUI

/// Mouse-movement feedback: a cursor glides from start to destination,
/// stretching a soft gradient tail behind it. Points are window-local
/// SwiftUI coordinates (top-left origin).
struct MouseTrailView: View {
    let fromPoint: CGPoint
    let toPoint: CGPoint
    let duration: TimeInterval

    @State private var progress: CGFloat = 0
    @State private var trailOpacity: Double = 1
    @State private var cursorOpacity: Double = 0

    init(from: CGPoint, to: CGPoint, duration: TimeInterval = 1.0) {
        self.fromPoint = from
        self.toPoint = to
        self.duration = duration
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Soft afterglow beneath the trail
            self.trailPath
                .trim(from: max(0, self.progress - 0.35), to: self.progress)
                .stroke(
                    VisualizerTheme.accent.opacity(0.22),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .blur(radius: 5)
                .opacity(self.trailOpacity)

            // Tapered cursor trail
            self.trailPath
                .trim(from: max(0, self.progress - 0.35), to: self.progress)
                .stroke(
                    self.travelGradient,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .opacity(self.trailOpacity)

            CursorGlyphView()
                .opacity(self.cursorOpacity)
                .offset(x: self.cursorPosition.x, y: self.cursorPosition.y)
        }
        .task {
            await self.animateTrail()
        }
    }

    private var trailPath: Path {
        Path { path in
            path.move(to: self.fromPoint)
            path.addLine(to: self.toPoint)
        }
    }

    private var cursorPosition: CGPoint {
        CGPoint(
            x: self.fromPoint.x + (self.toPoint.x - self.fromPoint.x) * self.progress,
            y: self.fromPoint.y + (self.toPoint.y - self.fromPoint.y) * self.progress)
    }

    /// Gradient oriented along the travel direction so the tail fades out behind the cursor.
    private var travelGradient: LinearGradient {
        LinearGradient(
            colors: [VisualizerTheme.accent.opacity(0.05), VisualizerTheme.accentSecondary, .white],
            startPoint: self.unitPoint(for: self.fromPoint),
            endPoint: self.unitPoint(for: self.toPoint))
    }

    private func unitPoint(for point: CGPoint) -> UnitPoint {
        let bounds = self.trailPath.boundingRect.insetBy(dx: -1, dy: -1)
        return UnitPoint(
            x: (point.x - bounds.minX) / max(bounds.width, 1),
            y: (point.y - bounds.minY) / max(bounds.height, 1))
    }

    private func animateTrail() async {
        let travel = max(self.duration * 0.75, 0.15)

        withAnimation(VisualizerMotion.enter(0.1)) {
            self.cursorOpacity = 1
        }
        withAnimation(VisualizerMotion.glide(travel)) {
            self.progress = 1
        }

        await self.sleep(travel)
        guard !Task.isCancelled else { return }
        withAnimation(VisualizerMotion.exit(0.25)) {
            self.trailOpacity = 0
            self.cursorOpacity = 0
        }
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

#if DEBUG && !SWIFT_PACKAGE
#Preview {
    MouseTrailView(
        from: CGPoint(x: 60, y: 80),
        to: CGPoint(x: 340, y: 320),
        duration: 1.2)
        .frame(width: 400, height: 400)
        .background(Color.gray.opacity(0.3))
}
#endif
