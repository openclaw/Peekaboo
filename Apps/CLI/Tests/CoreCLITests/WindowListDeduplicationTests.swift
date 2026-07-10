import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

/// Regression tests for duplicate / mis-ordered window IDs leaking out of window enumeration.
///
/// `peekaboo list windows` returned the same CGWindowID twice (with distinct indexes) because the
/// CG/AX merge in `WindowEnumerationContext` associated AX windows to CG entries by title alone.
/// Two windows sharing a title collapsed onto a single CG entry, so one was dropped from its AX
/// position and re-appended later as a leftover — unique IDs, but the emitted order no longer
/// matched the CG/frontmost enumeration, which is exactly what `--window-index` indexes into.
///
/// The fix preserves CGWindowList order and only uses reliable signals to associate AX windows:
/// an exact `CGWindowID` (from `_AXUIElementGetWindow`) or a CG-snapshot title+bounds — never a
/// synthesized ID — then assigns contiguous indexes after deduplication.
///
/// `normalizeWindowIndices` and `WindowManagementService` are `@MainActor`; pin the whole suite so
/// the isolation is explicit rather than relying on the target's default MainActor isolation.
@MainActor
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
    func `Same-titled windows keep distinct positions in CG order on the hybrid merge path`() {
        // Playground reproduction: two real windows share the title "Text Fixture" and an untitled
        // CG utility window forces the CG+AX hybrid path (the fast path only fires when every CG
        // window already has a title). Association by title alone previously reordered these; the
        // merge must keep CGWindowList order and enrich the untitled window from its AX counterpart
        // (matched here by exact CGWindowID).
        let cgWindows = [
            Self.window(id: 3459, title: "Text Fixture", index: 0),
            Self.window(id: 3460, title: "Text Fixture", index: 1),
            Self.window(id: 99, title: "", index: 2),
        ]
        let axDescriptors = [
            Self.descriptor(id: 3459, title: "Text Fixture"),
            Self.descriptor(id: 3460, title: "Text Fixture"),
            Self.descriptor(id: 99, title: "Utility Panel"),
        ]

        let merged = WindowEnumerationContext.mergeWindows(cgWindows: cgWindows, axDescriptors: axDescriptors)

        #expect(merged.map(\.windowID) == [3459, 3460, 99])
        #expect(merged.map(\.title) == ["Text Fixture", "Text Fixture", "Utility Panel"])

        let normalized = ApplicationService.normalizeWindowIndices(merged)
        #expect(normalized.map(\.index) == [0, 1, 2])
        #expect(normalized.map(\.windowID) == [3459, 3460, 99])
    }

    @Test
    func `Untitled CG window is enriched by bounds when AX cannot expose a window id`() {
        let cgWindows = [
            Self.window(id: 501, title: "Editor", index: 0),
            Self.window(id: 502, title: "", index: 1, bounds: CGRect(x: 40, y: 40, width: 600, height: 400)),
        ]
        let axDescriptors = [
            Self.descriptor(id: 501, title: "Editor"),
            Self.descriptor(id: nil, title: "Palette", bounds: CGRect(x: 42, y: 41, width: 600, height: 400)),
        ]

        let merged = WindowEnumerationContext.mergeWindows(cgWindows: cgWindows, axDescriptors: axDescriptors)

        #expect(merged.map(\.windowID) == [501, 502])
        #expect(merged.map(\.title) == ["Editor", "Palette"])
    }

    @Test
    func `AX-only window with a reliable CG id is appended after the CG enumeration`() {
        // A window CGWindowList did not report but which AX resolved to a real CGWindowID (2) is a
        // genuine, targetable window, so it is appended with its reliable identity.
        let cgWindows = [Self.window(id: 1, title: "Main", index: 0)]
        let axDescriptors = [
            Self.descriptor(id: 1, title: "Main"),
            Self.descriptor(id: 2, title: "Detached", standaloneInfo: Self.window(id: 2, title: "Detached", index: 0)),
        ]

        let merged = WindowEnumerationContext.mergeWindows(cgWindows: cgWindows, axDescriptors: axDescriptors)

        #expect(merged.map(\.windowID) == [1, 2])
        #expect(merged.map(\.title) == ["Main", "Detached"])
    }

    @Test
    func `AX window without a resolvable id and no CG bounds match is not emitted`() {
        // Principled tradeoff: an AX window CGWindowList never reported and whose CGWindowID cannot be
        // resolved has no stable identity — createWindowInfo would synthesize an index-based ID and
        // produce a phantom/duplicate entry (the bug class this change fixes). With no untitled CG
        // window to enrich, it is dropped rather than emitted with a meaningless ID.
        let cgWindows = [Self.window(id: 1, title: "Main", index: 0)]
        let axDescriptors = [
            Self.descriptor(id: 1, title: "Main"),
            Self.descriptor(id: nil, title: "Ghost", bounds: CGRect(x: 900, y: 900, width: 300, height: 200)),
        ]

        let merged = WindowEnumerationContext.mergeWindows(cgWindows: cgWindows, axDescriptors: axDescriptors)

        #expect(merged.map(\.windowID) == [1])
        #expect(merged.map(\.title) == ["Main"])
    }

    @Test
    func `Bounds fallback title is consumed once so identical frames are not all relabeled`() {
        // Two untitled CG windows share an identical frame (stacked/maximized). A single AX
        // descriptor without a resolvable CGWindowID matches that frame. It must relabel exactly one
        // window; the other stays untitled rather than borrowing the same title and mislabeling.
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let cgWindows = [
            Self.window(id: 11, title: "", index: 0, bounds: frame),
            Self.window(id: 12, title: "", index: 1, bounds: frame),
        ]
        let axDescriptors = [Self.descriptor(id: nil, title: "Document", bounds: frame)]

        let merged = WindowEnumerationContext.mergeWindows(cgWindows: cgWindows, axDescriptors: axDescriptors)

        #expect(merged.map(\.windowID) == [11, 12])
        #expect(merged.map(\.title) == ["Document", ""])
    }

    @Test
    func `Bounds fallback assigns distinct titles to identically framed windows in order`() {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let cgWindows = [
            Self.window(id: 11, title: "", index: 0, bounds: frame),
            Self.window(id: 12, title: "", index: 1, bounds: frame),
        ]
        let axDescriptors = [
            Self.descriptor(id: nil, title: "First", bounds: frame),
            Self.descriptor(id: nil, title: "Second", bounds: frame),
        ]

        let merged = WindowEnumerationContext.mergeWindows(cgWindows: cgWindows, axDescriptors: axDescriptors)

        #expect(merged.map(\.windowID) == [11, 12])
        #expect(merged.map(\.title) == ["First", "Second"])
    }

    @Test
    func `Bounds fallback does not hijack a title already owned by another CG window`() {
        // An untitled CG window (100) shares a frame with a titled CG window (200) that already owns
        // the title "Overlay". A nil-id AX "Overlay" descriptor really belongs to 200, so it must NOT
        // relabel 100: window 100 stays untitled, 200 keeps its title, nothing is duplicated.
        let frame = CGRect(x: 10, y: 10, width: 500, height: 400)
        let cgWindows = [
            Self.window(id: 100, title: "", index: 0, bounds: frame),
            Self.window(id: 200, title: "Overlay", index: 1, bounds: frame),
        ]
        let axDescriptors = [Self.descriptor(id: nil, title: "Overlay", bounds: frame)]

        let merged = WindowEnumerationContext.mergeWindows(cgWindows: cgWindows, axDescriptors: axDescriptors)

        #expect(merged.map(\.windowID) == [100, 200])
        #expect(merged.map(\.title) == ["", "Overlay"])
    }

    @Test
    func `--window-index resolves to the window printed at that position`() async throws {
        // Drive the real WindowManagementService.listWindows(.index) path over the real merge +
        // normalize output, so a positional target genuinely lands on the printed window.
        let cgWindows = [
            Self.window(id: 3459, title: "Text Fixture", index: 0),
            Self.window(id: 3460, title: "Text Fixture", index: 1),
            Self.window(id: 42, title: "Playground", index: 2),
            Self.window(id: 99, title: "", index: 3),
        ]
        let axDescriptors = [
            Self.descriptor(id: 3459, title: "Text Fixture"),
            Self.descriptor(id: 3460, title: "Text Fixture"),
            Self.descriptor(id: 42, title: "Playground"),
            Self.descriptor(id: 99, title: "Utility Panel"),
        ]

        let merged = WindowEnumerationContext.mergeWindows(cgWindows: cgWindows, axDescriptors: axDescriptors)
        let enumeration = ApplicationService.normalizeWindowIndices(merged)

        let appService = FakeApplicationService(windows: enumeration)
        let windowService = WindowManagementService(applicationService: appService)

        for position in enumeration.indices {
            let resolved = try await windowService.listWindows(target: .index(app: "Playground", index: position))
            #expect(resolved.count == 1)
            #expect(resolved.first?.windowID == enumeration[position].windowID)
            #expect(resolved.first?.index == position)
        }
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
        layer: Int = 0,
        bounds: CGRect = CGRect(x: 14, y: 59, width: 1200, height: 832)
    ) -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: id,
            title: title,
            bounds: bounds,
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

    private static func descriptor(
        id: Int?,
        title: String,
        bounds: CGRect? = nil,
        standaloneInfo: ServiceWindowInfo? = nil
    ) -> WindowEnumerationContext.AXWindowDescriptor {
        WindowEnumerationContext.AXWindowDescriptor(
            windowID: id,
            title: title,
            bounds: bounds,
            standaloneInfo: standaloneInfo
        )
    }
}

/// Minimal `ApplicationServiceProtocol` that returns a fixed, pre-computed window enumeration so the
/// real `WindowManagementService.listWindows(.index)` selection can be exercised without live AX/CG.
@MainActor
private final class FakeApplicationService: ApplicationServiceProtocol {
    private let windows: [ServiceWindowInfo]
    private let app = ServiceApplicationInfo(
        processIdentifier: 4242,
        bundleIdentifier: "boo.peekaboo.playground.debug",
        name: "Playground",
        isActive: true,
        windowCount: 4
    )

    init(windows: [ServiceWindowInfo]) {
        self.windows = windows
    }

    func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        UnifiedToolOutput(
            data: ServiceApplicationListData(applications: [self.app]),
            summary: .init(brief: "1 app", status: .success, counts: ["applications": 1]),
            metadata: .init(duration: 0)
        )
    }

    func findApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        self.app
    }

    func listWindows(for _: String, timeout _: Float?) async throws -> UnifiedToolOutput<ServiceWindowListData> {
        UnifiedToolOutput(
            data: ServiceWindowListData(windows: self.windows, targetApplication: self.app),
            summary: .init(
                brief: "\(self.windows.count) windows",
                status: .success,
                counts: ["windows": self.windows.count]
            ),
            metadata: .init(duration: 0)
        )
    }

    func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        self.app
    }

    func isApplicationRunning(identifier _: String) async -> Bool {
        true
    }

    func launchApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        self.app
    }

    func activateApplication(identifier _: String) async throws {}
    func quitApplication(identifier _: String, force _: Bool) async throws -> Bool {
        true
    }

    func hideApplication(identifier _: String) async throws {}
    func unhideApplication(identifier _: String) async throws {}
    func hideOtherApplications(identifier _: String) async throws {}
    func showAllApplications() async throws {}
}
