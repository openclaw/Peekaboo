import PeekabooFoundation
import SwiftUI

/// A single quiet pulse centered on the click point.
struct ClickAnimationView: View {
    let clickType: ClickType

    @State private var scale: CGFloat = 0.35
    @State private var opacity = 0.0

    private var tint: Color {
        self.clickType == .right ? VisualizerTheme.accentSecondary : VisualizerTheme.accent
    }

    var body: some View {
        Circle()
            .stroke(self.tint, lineWidth: 1.5)
            .frame(width: 30, height: 30)
            .scaleEffect(self.scale)
            .opacity(self.opacity)
            .onAppear {
                self.opacity = 0.9
                withAnimation(.easeOut(duration: 0.3)) {
                    self.scale = 1
                    self.opacity = 0
                }
            }
    }
}
