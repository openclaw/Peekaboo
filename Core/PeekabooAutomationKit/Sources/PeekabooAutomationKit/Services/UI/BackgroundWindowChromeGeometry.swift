import CoreGraphics

/// Geometry only: the reader must separately prove complete AX state and an exact native window hit.
struct BackgroundWindowChromeGeometry: Sendable {
    let bounds: CGRect
    let windowControls: [CGRect]
    let occupiedFrames: [CGRect]

    private static let clearance: CGFloat = 4

    func candidatePoint() -> CGPoint? {
        guard let row = self.controlRow else { return nil }
        let y = row.lowerBound + (row.upperBound - row.lowerBound) / 2
        guard let gap = self.gaps(at: y)?.max(by: { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound })
        else { return nil }
        let point = CGPoint(x: gap.lowerBound + (gap.upperBound - gap.lowerBound) / 2, y: y)
        return self.admits(point) ? point : nil
    }

    func admits(_ point: CGPoint) -> Bool {
        guard point.x.isFinite, point.y.isFinite, self.bounds.contains(point),
              let row = self.controlRow, row.contains(point.y),
              let gaps = self.gaps(at: point.y)
        else { return false }
        return gaps.contains { $0.contains(point.x) }
    }

    private var controlRow: ClosedRange<CGFloat>? {
        guard Self.isUsable(self.bounds), self.windowControls.count == 3,
              self.windowControls.allSatisfy({ Self.isUsable($0) && self.bounds.contains($0) }),
              self.occupiedFrames.allSatisfy(Self.isUsable),
              let top = self.windowControls.map(\.minY).max(),
              let bottom = self.windowControls.map(\.maxY).min()
        else { return nil }
        let lower = top + Self.clearance
        let upper = bottom - Self.clearance
        return lower < upper ? lower...upper : nil
    }

    private func gaps(at y: CGFloat) -> [ClosedRange<CGFloat>]? {
        guard let row = self.controlRow, row.contains(y) else { return nil }
        let left = self.bounds.minX + Self.clearance
        let right = self.bounds.maxX - Self.clearance
        guard left < right else { return nil }
        var gaps = [left...right]
        for frame in self.windowControls + self.occupiedFrames {
            let excluded = frame.insetBy(dx: -Self.clearance, dy: -Self.clearance)
            guard y >= excluded.minY, y <= excluded.maxY else { continue }
            gaps = gaps.flatMap { gap -> [ClosedRange<CGFloat>] in
                guard excluded.maxX > gap.lowerBound, excluded.minX < gap.upperBound else { return [gap] }
                var remaining: [ClosedRange<CGFloat>] = []
                if excluded.minX > gap.lowerBound {
                    remaining.append(gap.lowerBound...min(gap.upperBound, excluded.minX))
                }
                if excluded.maxX < gap.upperBound {
                    remaining.append(max(gap.lowerBound, excluded.maxX)...gap.upperBound)
                }
                return remaining
            }
        }
        return gaps.filter { $0.upperBound - $0.lowerBound >= Self.clearance * 2 }
    }

    private static func isUsable(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height, frame.maxX, frame.maxY]
            .allSatisfy(\.isFinite) && frame.size.width > 0 && frame.size.height > 0
    }
}
