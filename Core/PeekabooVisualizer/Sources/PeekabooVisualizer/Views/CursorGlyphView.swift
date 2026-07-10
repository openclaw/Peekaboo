//
//  CursorGlyphView.swift
//  Peekaboo
//
//  A crisp macOS-style arrow cursor whose tip is its top-leading hotspot.
//

import SwiftUI

/// Classic arrow-pointer polygon with its hotspot at the path's top-leading origin.
struct CursorShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 13, rect.height / 20)

        return Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 17.5 * scale))
            path.addLine(to: CGPoint(x: rect.minX + 4.2 * scale, y: rect.minY + 13.6 * scale))
            path.addLine(to: CGPoint(x: rect.minX + 7 * scale, y: rect.minY + 19.8 * scale))
            path.addLine(to: CGPoint(x: rect.minX + 9.8 * scale, y: rect.minY + 18.6 * scale))
            path.addLine(to: CGPoint(x: rect.minX + 7 * scale, y: rect.minY + 12.5 * scale))
            path.addLine(to: CGPoint(x: rect.minX + 12.6 * scale, y: rect.minY + 12.5 * scale))
            path.closeSubpath()
        }
    }
}

/// macOS-style cursor glyph. Position and scale from `.topLeading` to keep the tip on the hotspot.
struct CursorGlyphView: View {
    let height: CGFloat

    init(height: CGFloat = 22) {
        self.height = height
    }

    var body: some View {
        CursorShape()
            .fill(.black)
            .overlay {
                CursorShape()
                    .stroke(.white, lineWidth: 1.5)
            }
            .frame(width: self.height * 13 / 20, height: self.height)
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
    }
}
