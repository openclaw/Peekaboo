//
//  ElementHighlightView.swift
//  Peekaboo
//
//  A single detected-element highlight: accent outline plus an ID tag.
//

import SwiftUI

/// Element-detection feedback: an accent outline sized exactly to the element
/// with a small ID tag above it, replacing the old free-floating orange boxes.
struct ElementHighlightView: View {
    let elementID: String
    let size: CGSize
    let duration: TimeInterval

    @State private var highlightScale: CGFloat = 1.05
    @State private var highlightOpacity: Double = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(VisualizerTheme.accent, lineWidth: 2)
                .frame(width: self.size.width, height: self.size.height)
                .shadow(color: VisualizerTheme.accent.opacity(0.35), radius: 6)

            Text(self.elementID)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(VisualizerTheme.hudText)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .hudChip(cornerRadius: 6)
                .offset(y: -(self.size.height / 2) - 16)
        }
        .scaleEffect(self.highlightScale)
        .opacity(self.highlightOpacity)
        .onAppear {
            withAnimation(VisualizerMotion.pop()) {
                self.highlightScale = 1.0
                self.highlightOpacity = 1
            }
            withAnimation(VisualizerMotion.exit(0.3).delay(max(self.duration - 0.35, 0.4))) {
                self.highlightOpacity = 0
            }
        }
    }
}

/// All element highlights for one screen in a single overlay window.
/// One window per detection pass keeps hundreds of elements cheap and lets a
/// refreshed detection crossfade the whole sheet at once.
struct ElementOverlaySheetView: View {
    struct PositionedElement: Identifiable {
        let id: String
        /// Window-local SwiftUI rect (top-left origin).
        let rect: CGRect
    }

    let elements: [PositionedElement]
    let duration: TimeInterval

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            ForEach(self.elements) { element in
                ElementHighlightView(
                    elementID: element.id,
                    size: element.rect.size,
                    duration: self.duration)
                    .position(x: element.rect.midX, y: element.rect.midY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG && !SWIFT_PACKAGE
#Preview {
    ElementOverlaySheetView(
        elements: [
            .init(id: "B7", rect: CGRect(x: 40, y: 40, width: 160, height: 44)),
            .init(id: "T2", rect: CGRect(x: 240, y: 120, width: 120, height: 30)),
        ],
        duration: 3.0)
        .frame(width: 420, height: 220)
        .background(Color.gray.opacity(0.3))
}
#endif
