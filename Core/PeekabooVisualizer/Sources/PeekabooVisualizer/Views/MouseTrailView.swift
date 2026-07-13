//
//  MouseTrailView.swift
//  Peekaboo
//
//  A macOS-style cursor that follows the real pointer with a short fading tail.
//

import AppKit
import CoreGraphics
import SwiftUI

/// Mouse-movement feedback sampled from the live system cursor. Following the
/// real pointer keeps linear, human, and custom gesture paths visually honest.
struct MouseTrailView: View {
    let fromPoint: CGPoint
    let toPoint: CGPoint
    let duration: TimeInterval
    let windowRect: CGRect
    let primaryScreenFrame: CGRect?
    let tracksLivePointer: Bool

    @State private var trailPoints: [CGPoint]
    @State private var cursorPosition: CGPoint
    @State private var trailOpacity: Double = 1
    @State private var cursorOpacity: Double = 0

    init(
        from: CGPoint,
        to: CGPoint,
        duration: TimeInterval = 1.0,
        windowRect: CGRect,
        primaryScreenFrame: CGRect?,
        tracksLivePointer: Bool = true)
    {
        self.fromPoint = from
        self.toPoint = to
        self.duration = duration
        self.windowRect = windowRect
        self.primaryScreenFrame = primaryScreenFrame
        self.tracksLivePointer = tracksLivePointer
        self._trailPoints = State(initialValue: [from])
        self._cursorPosition = State(initialValue: from)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            self.trailPath
                .stroke(
                    VisualizerTheme.accent.opacity(0.14),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .blur(radius: 2)
                .opacity(self.trailOpacity)

            self.trailPath
                .stroke(
                    self.travelGradient,
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .opacity(self.trailOpacity)

            CursorGlyphView()
                .opacity(self.cursorOpacity)
                .offset(x: self.cursorPosition.x, y: self.cursorPosition.y)
        }
        .task {
            await self.followPointer()
        }
    }

    private var trailPath: Path {
        Path { path in
            guard let first = self.trailPoints.first else { return }
            path.move(to: first)
            for point in self.trailPoints.dropFirst() {
                path.addLine(to: point)
            }
        }
    }

    /// Gradient oriented along the sampled tail so it fades behind the cursor.
    private var travelGradient: LinearGradient {
        LinearGradient(
            colors: [VisualizerTheme.accent.opacity(0.05), VisualizerTheme.accentSecondary, .white],
            startPoint: self.unitPoint(for: self.trailPoints.first ?? self.fromPoint),
            endPoint: self.unitPoint(for: self.trailPoints.last ?? self.cursorPosition))
    }

    private func unitPoint(for point: CGPoint) -> UnitPoint {
        let bounds = self.trailPath.boundingRect.insetBy(dx: -1, dy: -1)
        return UnitPoint(
            x: (point.x - bounds.minX) / max(bounds.width, 1),
            y: (point.y - bounds.minY) / max(bounds.height, 1))
    }

    private func followPointer() async {
        let travel = max(self.duration, 0.12)
        let start = Date()
        let previewPath = PointerPreviewPath(from: self.fromPoint, to: self.toPoint)

        withAnimation(VisualizerMotion.enter(0.1)) {
            self.cursorOpacity = 1
        }

        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(start)
            guard elapsed < travel else { break }
            if self.tracksLivePointer {
                self.sampleCursor()
            } else {
                self.samplePreview(previewPath.point(at: elapsed / travel))
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        guard !Task.isCancelled else { return }
        if self.tracksLivePointer {
            self.sampleCursor()
        } else {
            self.samplePreview(previewPath.point(at: 1))
        }

        withAnimation(VisualizerMotion.exit(0.25)) {
            self.trailOpacity = 0
            self.cursorOpacity = 0
        }
    }

    private func sampleCursor() {
        guard let globalPoint = CGEvent(source: nil)?.location else { return }
        let appKitPoint = VisualizerScreenGeometry.appKitPoint(
            fromGlobalDisplay: globalPoint,
            primaryScreenFrame: self.primaryScreenFrame)
        let localPoint = CGPoint(
            x: appKitPoint.x - self.windowRect.minX,
            y: self.windowRect.maxY - appKitPoint.y)
        self.cursorPosition = localPoint
        self.trailPoints = PointerTrailSamples.appending(localPoint, to: self.trailPoints)
    }

    private func samplePreview(_ point: CGPoint) {
        self.cursorPosition = point
        self.trailPoints = PointerTrailSamples.appending(point, to: self.trailPoints)
    }
}

/// Bounds live pointer history by both visible length and sample count.
struct PointerTrailSamples {
    static let maximumLength: CGFloat = 84
    static let maximumCount = 32

    static func appending(_ point: CGPoint, to points: [CGPoint]) -> [CGPoint] {
        var result = points
        if let last = result.last, self.distance(last, point) < 0.25 {
            result[result.count - 1] = point
            return result
        }
        result.append(point)

        if result.count > self.maximumCount {
            result.removeFirst(result.count - self.maximumCount)
        }
        while result.count > 2, self.pathLength(result) > self.maximumLength {
            result.removeFirst()
        }

        let excess = self.pathLength(result) - self.maximumLength
        if excess > 0, result.count >= 2 {
            let segmentLength = self.distance(result[0], result[1])
            if segmentLength > 0 {
                let fraction = min(excess / segmentLength, 1)
                result[0] = CGPoint(
                    x: result[0].x + ((result[1].x - result[0].x) * fraction),
                    y: result[0].y + ((result[1].y - result[0].y) * fraction))
            }
        }
        return result
    }

    static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + self.distance(pair.0, pair.1)
        }
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
    }
}

/// Deterministic natural motion used only by the Settings preview, where no
/// real automation command exists for the overlay to follow.
struct PointerPreviewPath {
    let fromPoint: CGPoint
    let toPoint: CGPoint
    let control1: CGPoint
    let control2: CGPoint

    init(from: CGPoint, to: CGPoint) {
        self.fromPoint = from
        self.toPoint = to
        let delta = CGVector(dx: to.x - from.x, dy: to.y - from.y)
        let distance = max(hypot(delta.dx, delta.dy), 0.001)
        let normal = CGVector(dx: -delta.dy / distance, dy: delta.dx / distance)
        let curveDirection: CGFloat = (delta.dx * delta.dy) >= 0 ? -1 : 1
        let curvature = min(distance * 0.08, 28) * curveDirection
        self.control1 = CGPoint(
            x: from.x + (delta.dx * 0.30) + (normal.dx * curvature),
            y: from.y + (delta.dy * 0.30) + (normal.dy * curvature))
        self.control2 = CGPoint(
            x: from.x + (delta.dx * 0.72) - (normal.dx * curvature * 0.20),
            y: from.y + (delta.dy * 0.72) - (normal.dy * curvature * 0.20))
    }

    func point(at time: Double) -> CGPoint {
        let t = min(max(CGFloat(time), 0), 1)
        let progress = (10 * pow(t, 3)) - (15 * pow(t, 4)) + (6 * pow(t, 5))
        let inverse = 1 - progress
        return CGPoint(
            x: (self.fromPoint.x * pow(inverse, 3))
                + (self.control1.x * 3 * pow(inverse, 2) * progress)
                + (self.control2.x * 3 * inverse * pow(progress, 2))
                + (self.toPoint.x * pow(progress, 3)),
            y: (self.fromPoint.y * pow(inverse, 3))
                + (self.control1.y * 3 * pow(inverse, 2) * progress)
                + (self.control2.y * 3 * inverse * pow(progress, 2))
                + (self.toPoint.y * pow(progress, 3)))
    }
}

#if DEBUG && !SWIFT_PACKAGE
#Preview {
    MouseTrailView(
        from: CGPoint(x: 60, y: 80),
        to: CGPoint(x: 340, y: 320),
        duration: 1.2,
        windowRect: CGRect(x: 0, y: 0, width: 400, height: 400),
        primaryScreenFrame: NSScreen.screens.first?.frame,
        tracksLivePointer: false)
        .frame(width: 400, height: 400)
        .background(Color.gray.opacity(0.3))
}
#endif
