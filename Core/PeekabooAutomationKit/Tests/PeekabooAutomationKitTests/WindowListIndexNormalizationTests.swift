import CoreGraphics
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct WindowListIndexNormalizationTests {
    @Test
    func `normalizeWindowIndices keeps order and makes indices contiguous`() {
        let windows = [
            ServiceWindowInfo(
                windowID: 111,
                title: "First",
                bounds: .zero,
                isMinimized: false,
                isMainWindow: false,
                windowLevel: 0,
                alpha: 1.0,
                index: 5,
                spaceID: nil,
                spaceName: nil,
                screenIndex: nil,
                screenName: nil,
                isOffScreen: true,
                layer: 0,
                isOnScreen: true,
                sharingState: nil,
                isExcludedFromWindowsMenu: false,
                mutationIdentity: .init(
                    windowID: 111,
                    ownerProcessIdentifier: 42,
                    ownerProcessStartIdentity: 7)),
            ServiceWindowInfo(
                windowID: 222,
                title: "Second",
                bounds: .zero,
                isMinimized: false,
                isMainWindow: false,
                windowLevel: 0,
                alpha: 1.0,
                index: 0,
                spaceID: nil,
                spaceName: nil,
                screenIndex: nil,
                screenName: nil,
                layer: 0,
                isOnScreen: true,
                sharingState: nil,
                isExcludedFromWindowsMenu: false),
        ]

        let normalized = ApplicationService.normalizeWindowIndices(windows)

        #expect(normalized.map(\.windowID) == [111, 222])
        #expect(normalized.map(\.title) == ["First", "Second"])
        #expect(normalized.map(\.index) == [0, 1])
        #expect(normalized.map(\.isOffScreen) == [true, false])
        #expect(normalized.first?.mutationIdentity?.ownerProcessStartIdentity == 7)
    }

    @Test
    func `normalizeWindowIndices handles empty input`() {
        #expect(ApplicationService.normalizeWindowIndices([]).isEmpty)
    }

    @Test
    func `missing AX ID inference requires one unique CG sibling`() {
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let first = ApplicationService.WindowIDInferenceCandidate(
            windowID: 111,
            ownerProcessIdentifier: 42,
            title: "Duplicate",
            bounds: bounds)
        let second = ApplicationService.WindowIDInferenceCandidate(
            windowID: 222,
            ownerProcessIdentifier: 42,
            title: "Duplicate",
            bounds: bounds)

        #expect(ApplicationService.uniqueMatchingWindowID(
            pid: 42,
            title: "Duplicate",
            bounds: bounds,
            candidates: [first]) == 111)
        #expect(ApplicationService.uniqueMatchingWindowID(
            pid: 42,
            title: "Duplicate",
            bounds: bounds,
            candidates: [first, second]) == nil)
        #expect(ApplicationService.uniqueMatchingWindowID(
            pid: 42,
            title: "Duplicate",
            bounds: bounds,
            candidates: [second, first]) == nil)
    }

    @Test
    func `hybrid merge restores a missing CG receipt from exact AX ownership`() throws {
        let cgWindow = ServiceWindowInfo(
            windowID: 333,
            title: "Fixture",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            isOffScreen: true,
            isOnScreen: false)
        let receipt = WindowMutationIdentity(
            windowID: 333,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 7,
            capturedBounds: cgWindow.bounds,
            isMinimized: true)
        let descriptor = WindowEnumerationContext.AXWindowDescriptor(
            windowID: 333,
            title: "Fixture",
            bounds: cgWindow.bounds,
            standaloneInfo: nil,
            isMinimized: true,
            mutationIdentity: receipt)

        let merged = WindowEnumerationContext.mergeWindows(
            cgWindows: [cgWindow],
            axDescriptors: [descriptor])

        let window = try #require(merged.first)
        #expect(window.isMinimized)
        #expect(!window.isOnScreen)
        #expect(window.mutationIdentity == receipt)
    }

    @Test
    func `hybrid merge appends AX-only minimized exact window with receipt`() throws {
        let bounds = CGRect(x: 40, y: 50, width: 700, height: 500)
        let receipt = WindowMutationIdentity(
            windowID: 444,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 7,
            capturedBounds: bounds,
            isMinimized: true)
        let standalone = ServiceWindowInfo(
            windowID: 444,
            title: "Minimized Fixture",
            bounds: bounds,
            isMinimized: true,
            isOffScreen: true,
            isOnScreen: false,
            mutationIdentity: receipt)
        let descriptor = WindowEnumerationContext.AXWindowDescriptor(
            windowID: 444,
            title: standalone.title,
            bounds: bounds,
            standaloneInfo: standalone,
            isMinimized: true,
            mutationIdentity: receipt)

        let merged = WindowEnumerationContext.mergeWindows(cgWindows: [], axDescriptors: [descriptor])
        let window = try #require(merged.first)

        #expect(window.windowID == 444)
        #expect(window.isMinimized)
        #expect(window.mutationIdentity == receipt)
    }

    @Test
    func `matching titled CG row accounts for an AX descriptor without window ID`() {
        let bounds = CGRect(x: 40, y: 50, width: 700, height: 500)
        let cgWindow = ServiceWindowInfo(windowID: 445, title: "Fixture", bounds: bounds)
        let descriptor = WindowEnumerationContext.AXWindowDescriptor(
            windowID: nil,
            title: cgWindow.title,
            bounds: bounds,
            standaloneInfo: nil)

        let merged = WindowEnumerationContext.mergeWindowInventory(
            cgWindows: [cgWindow],
            axDescriptors: [descriptor])

        #expect(merged.windows == [cgWindow])
        #expect(merged.unmaterializedAXDescriptorCount == 0)
    }

    @Test
    func `one untitled CG row can borrow one unique AX title`() {
        let bounds = CGRect(x: 40, y: 50, width: 700, height: 500)
        let cgWindow = ServiceWindowInfo(windowID: 450, title: "", bounds: bounds)
        let descriptor = WindowEnumerationContext.AXWindowDescriptor(
            windowID: nil,
            title: "Fixture",
            bounds: bounds,
            standaloneInfo: nil)

        let merged = WindowEnumerationContext.mergeWindowInventory(
            cgWindows: [cgWindow],
            axDescriptors: [descriptor])

        #expect(merged.windows.map(\.title) == ["Fixture"])
        #expect(merged.unmaterializedAXDescriptorCount == 0)
    }

    @Test
    func `overlapping untitled CG rows do not consume ambiguous AX descriptors`() {
        let bounds = CGRect(x: 40, y: 50, width: 700, height: 500)
        let cgWindows = [
            ServiceWindowInfo(windowID: 451, title: "", bounds: bounds),
            ServiceWindowInfo(windowID: 452, title: "", bounds: bounds),
        ]
        let descriptors = ["First", "Second"].map {
            WindowEnumerationContext.AXWindowDescriptor(
                windowID: nil,
                title: $0,
                bounds: bounds,
                standaloneInfo: nil)
        }

        let merged = WindowEnumerationContext.mergeWindowInventory(
            cgWindows: cgWindows,
            axDescriptors: descriptors)

        #expect(merged.windows.map(\.title) == ["", ""])
        #expect(merged.unmaterializedAXDescriptorCount == 2)
    }

    @Test
    func `one titled CG row cannot account for two AX descriptors without IDs`() {
        let bounds = CGRect(x: 40, y: 50, width: 700, height: 500)
        let cgWindow = ServiceWindowInfo(windowID: 446, title: "Fixture", bounds: bounds)
        let descriptor = WindowEnumerationContext.AXWindowDescriptor(
            windowID: nil,
            title: cgWindow.title,
            bounds: bounds,
            standaloneInfo: nil)

        let merged = WindowEnumerationContext.mergeWindowInventory(
            cgWindows: [cgWindow],
            axDescriptors: [descriptor, descriptor])

        #expect(merged.windows == [cgWindow])
        #expect(merged.unmaterializedAXDescriptorCount == 1)
    }

    @Test
    func `one exact CG ID cannot account for two AX descriptors`() {
        let bounds = CGRect(x: 40, y: 50, width: 700, height: 500)
        let cgWindow = ServiceWindowInfo(windowID: 449, title: "Fixture", bounds: bounds)
        let descriptor = WindowEnumerationContext.AXWindowDescriptor(
            windowID: cgWindow.windowID,
            title: cgWindow.title,
            bounds: bounds,
            standaloneInfo: nil)

        let merged = WindowEnumerationContext.mergeWindowInventory(
            cgWindows: [cgWindow],
            axDescriptors: [descriptor, descriptor])

        #expect(merged.windows == [cgWindow])
        #expect(merged.unmaterializedAXDescriptorCount == 1)
    }

    @Test
    func `exact ID and unidentified AX rows cannot both claim one CG window`() {
        let bounds = CGRect(x: 40, y: 50, width: 700, height: 500)
        let cgWindow = ServiceWindowInfo(windowID: 447, title: "Fixture", bounds: bounds)
        let exact = WindowEnumerationContext.AXWindowDescriptor(
            windowID: cgWindow.windowID,
            title: cgWindow.title,
            bounds: bounds,
            standaloneInfo: nil)
        let unidentified = WindowEnumerationContext.AXWindowDescriptor(
            windowID: nil,
            title: cgWindow.title,
            bounds: bounds,
            standaloneInfo: nil)

        let merged = WindowEnumerationContext.mergeWindowInventory(
            cgWindows: [cgWindow],
            axDescriptors: [exact, unidentified])

        #expect(merged.windows == [cgWindow])
        #expect(merged.unmaterializedAXDescriptorCount == 1)
    }

    @Test
    func `unidentified AX title cannot relabel a CG window already claimed by an exact ID row`() {
        let bounds = CGRect(x: 40, y: 50, width: 700, height: 500)
        let cgWindow = ServiceWindowInfo(windowID: 448, title: "", bounds: bounds)
        let exact = WindowEnumerationContext.AXWindowDescriptor(
            windowID: cgWindow.windowID,
            title: "",
            bounds: bounds,
            standaloneInfo: nil)
        let unidentified = WindowEnumerationContext.AXWindowDescriptor(
            windowID: nil,
            title: "Borrowed title",
            bounds: bounds,
            standaloneInfo: nil)

        let merged = WindowEnumerationContext.mergeWindowInventory(
            cgWindows: [cgWindow],
            axDescriptors: [exact, unidentified])

        #expect(merged.windows == [cgWindow])
        #expect(merged.unmaterializedAXDescriptorCount == 1)
    }
}
