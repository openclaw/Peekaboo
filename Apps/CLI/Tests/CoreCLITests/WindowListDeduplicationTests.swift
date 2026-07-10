import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAutomationKit

/// Regression tests for duplicate window IDs leaking out of window enumeration.
///
/// `peekaboo list windows` returned the same CGWindowID twice (with distinct indexes) because the
/// CG/AX merge in `WindowEnumerationContext` appended one entry per AX window keyed by title only,
/// and indexes were assigned before any deduplication. `peekaboo window list` hid the duplicate via
/// `ObservationTargetResolver.filteredWindows(mode: .list)` but inherited the shifted indexes.
@Suite("Window list deduplication")
struct WindowListDeduplicationTests {
    @Test
    func `Duplicate window IDs collapse to a single entry keeping the first occurrence`() {
        let duplicateID = 3459
        let windows = [
            Self.window(id: 100, title: "Main", index: 0),
            Self.window(id: duplicateID, title: "Text Fixture", index: 1),
            Self.window(id: 200, title: "Inspector", index: 2),
            Self.window(id: duplicateID, title: "Text Fixture", index: 3),
            Self.window(id: 300, title: "Palette", index: 4),
        ]

        let normalized = ApplicationService.normalizeWindowIndices(windows)

        #expect(normalized.map(\.windowID) == [100, duplicateID, 200, 300])
        #expect(Set(normalized.map(\.windowID)).count == normalized.count)
    }

    @Test
    func `Indexes are contiguous after deduplication so a phantom entry cannot shift targets`() {
        let windows = [
            Self.window(id: 10, title: "A", index: 0),
            Self.window(id: 20, title: "B", index: 1),
            Self.window(id: 20, title: "B", index: 2),
            Self.window(id: 30, title: "C", index: 3),
            Self.window(id: 40, title: "D", index: 4),
        ]

        let normalized = ApplicationService.normalizeWindowIndices(windows)

        #expect(normalized.map(\.index) == Array(0..<normalized.count))
        #expect(normalized.map(\.windowID) == [10, 20, 30, 40])
    }

    @Test
    func `list windows and window list agree for renderable windows from the same source`() {
        // `list windows` renders the normalized enumeration; `window list` additionally applies
        // ObservationTargetResolver.filteredWindows(mode: .list). For renderable windows the two
        // command payloads must contain the identical window set, IDs, and indexes.
        let rawWindows = [
            Self.window(id: 3459, title: "Text Fixture", index: 0),
            Self.window(id: 3459, title: "Text Fixture", index: 1),
            Self.window(id: 42, title: "Playground", index: 2),
            Self.window(id: 7, title: "Console", index: 3),
        ]

        let listWindowsPayload = ApplicationService.normalizeWindowIndices(rawWindows)
        let windowListPayload = ObservationTargetResolver.filteredWindows(from: listWindowsPayload, mode: .list)

        #expect(listWindowsPayload.map(\.windowID) == [3459, 42, 7])
        #expect(windowListPayload.map(\.windowID) == listWindowsPayload.map(\.windowID))
        #expect(windowListPayload.map(\.index) == listWindowsPayload.map(\.index))
    }

    @Test
    func `window list keeps source indexes when it filters non-renderable windows`() {
        // Intentional difference: `window list` drops non-renderable windows (layer != 0, tiny,
        // fully transparent, excluded from the Windows menu) but must preserve the canonical
        // indexes assigned by the enumeration so --window-index targeting stays aligned.
        let rawWindows = [
            Self.window(id: 1, title: "Main", index: 0),
            Self.window(id: 2, title: "Status Item", index: 0, layer: 25),
            Self.window(id: 3, title: "Inspector", index: 0),
        ]

        let listWindowsPayload = ApplicationService.normalizeWindowIndices(rawWindows)
        let windowListPayload = ObservationTargetResolver.filteredWindows(from: listWindowsPayload, mode: .list)

        #expect(listWindowsPayload.map(\.windowID) == [1, 2, 3])
        #expect(windowListPayload.map(\.windowID) == [1, 3])
        #expect(windowListPayload.map(\.index) == [0, 2])
    }

    private static func window(
        id: Int,
        title: String,
        index: Int,
        layer: Int = 0
    ) -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: id,
            title: title,
            bounds: CGRect(x: 14, y: 59, width: 1200, height: 832),
            isMinimized: false,
            isMainWindow: false,
            windowLevel: layer,
            alpha: 1,
            index: index,
            layer: layer,
            isOnScreen: true,
            sharingState: .readOnly,
            isExcludedFromWindowsMenu: false
        )
    }
}
