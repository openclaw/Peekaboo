import CoreGraphics
import Foundation

extension ObservationTargetResolver {
    func resolveWindowID(_ windowID: CGWindowID) -> ResolvedObservationTarget {
        guard let metadata = ObservationWindowMetadataCatalog.currentWindow(windowID: windowID) else {
            return ResolvedObservationTarget(kind: .windowID(windowID))
        }

        return ResolvedObservationTarget(
            kind: .windowID(windowID),
            app: metadata.app,
            window: metadata.window,
            bounds: metadata.bounds,
            detectionContext: metadata.context)
    }

    func selectWindow(
        from windows: [ServiceWindowInfo],
        selection: WindowSelection) throws -> ServiceWindowInfo?
    {
        switch selection {
        case .automatic:
            return Self.bestWindow(from: windows)

        case let .index(index):
            guard let window = windows.first(where: { $0.index == index }) ?? windows[safe: index] else {
                throw DesktopObservationError.targetNotFound("window index \(index)")
            }
            return window

        case let .title(title):
            guard let window = windows.first(where: { $0.title.localizedCaseInsensitiveContains(title) }) else {
                throw DesktopObservationError.targetNotFound("window title \(title)")
            }
            return window

        case let .id(windowID):
            guard let window = windows.first(where: { $0.windowID == Int(windowID) }) else {
                throw DesktopObservationError.targetNotFound("window id \(windowID)")
            }
            return window
        }
    }

    public nonisolated static func bestWindow(from windows: [ServiceWindowInfo]) -> ServiceWindowInfo? {
        let visible = self.captureCandidates(from: windows)

        return visible.max { lhs, rhs in
            let lhsScore = self.windowScore(lhs)
            let rhsScore = self.windowScore(rhs)
            if lhsScore == rhsScore {
                return lhs.index > rhs.index
            }
            return lhsScore < rhsScore
        }
    }

    public nonisolated static func captureCandidates(from windows: [ServiceWindowInfo]) -> [ServiceWindowInfo] {
        self.filteredWindows(from: windows, mode: .capture)
    }

    public nonisolated static func captureCandidateSummary(
        from windows: [ServiceWindowInfo],
        limit: Int = 5) -> String
    {
        guard !windows.isEmpty else {
            return "no windows returned"
        }

        return windows.prefix(limit).map { window in
            let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = title.isEmpty ? "<untitled>" : title
            let reason = WindowFiltering.disqualificationReason(for: window, mode: .capture) ?? "capture candidate"
            let size = "\(Int(window.bounds.width))x\(Int(window.bounds.height))"
            return "#\(window.index) id=\(window.windowID) '\(label)' \(size) " +
                "alpha=\(Self.format(window.alpha)) reason=\(reason)"
        }.joined(separator: "; ")
    }

    public nonisolated static func filteredWindows(
        from windows: [ServiceWindowInfo],
        mode: WindowFiltering.Mode) -> [ServiceWindowInfo]
    {
        self.deduplicate(windows.filter { WindowFiltering.isRenderable($0, mode: mode) })
    }

    private nonisolated static func windowScore(_ window: ServiceWindowInfo) -> Double {
        // Prefer the window a human would expect: titled, normal-level, non-minimized, large, and early in AX order.
        var score = 0.0

        if window.isFrontmost == true {
            score += 20000
        }

        if window.isKeyWindow == true {
            score += 10000
        }

        if window.isMainWindow {
            score += 2000
        }

        if window.windowLevel == 0 {
            score += 500
        }

        if window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score -= 500
        } else {
            score += 2500
        }

        if !window.isMinimized {
            score += 300
        }

        let area = window.bounds.width * window.bounds.height
        if area > .zero {
            score += min(Double(area) / 150.0, 4000)
        }

        score += max(0, 600 - Double(window.index) * 40)

        return score
    }

    private nonisolated static func format(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    private nonisolated static func deduplicate(_ windows: [ServiceWindowInfo]) -> [ServiceWindowInfo] {
        var seenWindowIDs = Set<Int>()
        var deduplicated: [ServiceWindowInfo] = []
        deduplicated.reserveCapacity(windows.count)

        for window in windows where seenWindowIDs.insert(window.windowID).inserted {
            deduplicated.append(window)
        }

        return deduplicated
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
