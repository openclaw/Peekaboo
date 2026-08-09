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
}
