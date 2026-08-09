import SwiftUI

struct AgentCursorPath: Equatable {
    let from: CGPoint
    let to: CGPoint

    func point(at progress: CGFloat) -> CGPoint {
        guard progress > 0 else { return self.from }
        guard progress < 1 else { return self.to }
        let dx = self.to.x - self.from.x
        let dy = self.to.y - self.from.y
        let distance = hypot(dx, dy)
        let normal = CGVector(dx: -dy / max(distance, 1), dy: dx / max(distance, 1))
        let bend = min(max(distance * 0.09, 12), 54)
        let control = CGPoint(
            x: (self.from.x + self.to.x) / 2 + normal.dx * bend,
            y: (self.from.y + self.to.y) / 2 + normal.dy * bend)
        let inverse = 1 - progress
        return CGPoint(
            x: inverse * inverse * self.from.x + 2 * inverse * progress * control.x +
                progress * progress * self.to.x,
            y: inverse * inverse * self.from.y + 2 * inverse * progress * control.y +
                progress * progress * self.to.y)
    }
}

private struct AgentCursorMotion: GeometryEffect {
    let path: AgentCursorPath
    var progress: CGFloat

    var animatableData: CGFloat {
        get { self.progress }
        set { self.progress = newValue }
    }

    func effectValue(size _: CGSize) -> ProjectionTransform {
        let point = self.path.point(at: self.progress)
        return ProjectionTransform(CGAffineTransform(translationX: point.x, y: point.y))
    }
}

struct AgentCursorView: View {
    let from: CGPoint
    let to: CGPoint
    let duration: TimeInterval
    let isPressed: Bool

    @State private var progress: CGFloat = 0
    @State private var opacity = 0.0

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Circle()
                    .fill(VisualizerTheme.accent.opacity(self.isPressed ? 0.2 : 0.12))
                    .frame(width: self.isPressed ? 24 : 20, height: self.isPressed ? 24 : 20)
                    .offset(x: -10, y: -10)
                CursorGlyphView(height: self.isPressed ? 19 : 21)
                    .scaleEffect(self.isPressed ? 0.88 : 1, anchor: .topLeading)
            }
            .modifier(AgentCursorMotion(path: AgentCursorPath(from: self.from, to: self.to), progress: self.progress))
            .opacity(self.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            withAnimation(.easeOut(duration: 0.08)) { self.opacity = 1 }
            withAnimation(.easeInOut(duration: max(self.duration, 0.05))) { self.progress = 1 }
            withAnimation(.easeOut(duration: 0.12).delay(max(self.duration - 0.04, 0.05))) { self.opacity = 0 }
        }
    }
}
