import SwiftUI

/// A brief border around the exact captured region.
struct ScreenshotFlashView: View {
    let intensity: Double

    @State private var opacity = 0.0

    var body: some View {
        Rectangle()
            .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
            .overlay {
                Rectangle()
                    .strokeBorder(VisualizerTheme.accent.opacity(0.35), lineWidth: 3)
                    .blur(radius: 2)
            }
            .opacity(self.opacity * min(max(self.intensity, 0.1), 2))
            .onAppear {
                withAnimation(.easeOut(duration: 0.04)) { self.opacity = 1 }
                withAnimation(.easeIn(duration: 0.16).delay(0.04)) { self.opacity = 0 }
            }
    }
}
