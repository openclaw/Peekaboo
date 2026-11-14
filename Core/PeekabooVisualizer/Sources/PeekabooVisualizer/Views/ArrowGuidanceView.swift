import CoreGraphics
import SwiftUI

struct ArrowGuidanceLayout: Equatable {
    let tip: CGPoint
    let tail: CGPoint
    let labelCenter: CGPoint
    let targetRect: CGRect?

    static func make(targetPoint: CGPoint, targetRect: CGRect?, size: CGSize) -> Self? {
        guard size.width >= 160, size.height >= 220 else { return nil }

        let point = targetRect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? targetPoint
        let tailX = min(max(point.x, 48), size.width - 48)
        let arrowAboveTarget = point.y >= 112
        let tailY = point.y + (arrowAboveTarget ? -72 : 72)
        let labelY = tailY + (arrowAboveTarget ? -30 : 30)

        return Self(
            tip: point,
            tail: CGPoint(x: tailX, y: tailY),
            labelCenter: CGPoint(x: min(max(tailX, 88), size.width - 88), y: labelY),
            targetRect: targetRect)
    }

    var arrowHead: (CGPoint, CGPoint) {
        let angle = atan2(self.tip.y - self.tail.y, self.tip.x - self.tail.x)
        let length: CGFloat = 16
        let spread: CGFloat = 0.58
        let first = CGPoint(
            x: self.tip.x - length * cos(angle - spread),
            y: self.tip.y - length * sin(angle - spread))
        let second = CGPoint(
            x: self.tip.x - length * cos(angle + spread),
            y: self.tip.y - length * sin(angle + spread))
        return (first, second)
    }
}

struct ArrowGuidanceView: View {
    let layout: ArrowGuidanceLayout
    let label: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                let head = self.layout.arrowHead
                var path = Path()
                path.move(to: self.layout.tail)
                path.addLine(to: self.layout.tip)
                path.move(to: head.0)
                path.addLine(to: self.layout.tip)
                path.addLine(to: head.1)
                context.stroke(
                    path,
                    with: .color(VisualizerTheme.accent),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }

            Circle()
                .fill(VisualizerTheme.accent)
                .frame(width: 10, height: 10)
                .position(self.layout.tip)

            if let targetRect = self.layout.targetRect {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(VisualizerTheme.accent, lineWidth: 3)
                    .frame(width: targetRect.width, height: targetRect.height)
                    .position(x: targetRect.midX, y: targetRect.midY)
            }

            if let label = self.label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.black.opacity(0.82), in: Capsule())
                    .frame(maxWidth: 360)
                    .position(self.layout.labelCenter)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
