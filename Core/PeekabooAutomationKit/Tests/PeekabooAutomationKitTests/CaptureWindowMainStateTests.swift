import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@_spi(Testing) @testable import PeekabooAutomationKit

@MainActor
struct CaptureWindowMainStateTests {
    @Test(arguments: [0, 3], [false, true])
    func `classic capture does not invent main state for its selected window`(
        index: Int,
        isOnScreen: Bool)
    {
        let window = Self.window(id: 41 + index, isOnScreen: isOnScreen)
        let identity = Self.mutationIdentity(window)
        let info = LegacyScreenCaptureOperator.captureWindowInfo(
            from: Self.cgWindow(window),
            windowID: window.windowID,
            bounds: window.bounds,
            index: index,
            mutationIdentity: identity)

        #expect(!info.isMainWindow)
        #expect(info.windowID == Int(window.windowID))
        #expect(info.title == window.title)
        #expect(info.index == index)
        #expect(info.bounds == window.bounds)
        #expect(info.isOnScreen == isOnScreen)
        #expect(info.isOffScreen == !isOnScreen)
        #expect(info.mutationIdentity == identity)
    }

    @Test
    func `classic filtering keeps two visible windows without calling the first main`() throws {
        let windows = [Self.window(id: 41), Self.window(id: 42)].map(Self.cgWindow)
        let first = try #require(LegacyScreenCaptureOperator.makeFilteringInfo(from: windows[0], index: 0))
        let second = try #require(LegacyScreenCaptureOperator.makeFilteringInfo(from: windows[1], index: 1))

        #expect(!first.isMainWindow)
        #expect(!second.isMainWindow)
        #expect(first.isOnScreen && second.isOnScreen)
        #expect(LegacyScreenCaptureOperator.firstRenderableWindowIndex(in: windows) == 0)
    }

    @Test(arguments: [0, 3], [false, true])
    func `ScreenCaptureKit metadata keeps visibility separate from main state`(
        index: Int,
        isOnScreen: Bool) throws
    {
        let window = Self.window(id: 41 + index, isOnScreen: isOnScreen)
        let identity = Self.mutationIdentity(window)
        let display = ScreenCaptureDisplayTopology.Display(
            displayID: 1,
            bounds: CGRect(x: 0, y: 0, width: 1200, height: 900),
            pixelWidth: 1200,
            pixelHeight: 900,
            rotation: 0)
        let metadata = try ScreenCaptureKitOperator.windowMetadata(
            image: Self.image(),
            context: ScreenCaptureKitOperator.WindowMetadataContext(
                mode: .window,
                applicationInfo: nil,
                window: ScreenCaptureKitOperator.WindowMetadataIdentity(window),
                windowIndex: index,
                display: ScreenCaptureKitOperator.DisplayMetadataIdentity(display),
                displayIndex: 0,
                scalePlan: .init(preference: .logical1x, nativeScale: 1, outputScale: 1, source: .fallback1x),
                mutationIdentity: identity))
        let info = try #require(metadata.windowInfo)

        #expect(!info.isMainWindow)
        #expect(info.windowID == Int(window.windowID))
        #expect(info.index == index)
        #expect(info.bounds == window.bounds)
        #expect(info.isOnScreen == isOnScreen)
        #expect(info.isOffScreen == !isOnScreen)
        #expect(info.mutationIdentity == identity)
    }

    @Test
    func `normalization preserves supplied main state on a non-first window`() throws {
        let captured = [
            ServiceWindowInfo(windowID: 41, title: "Other", bounds: .zero, isMainWindow: false, index: 0),
            ServiceWindowInfo(windowID: 42, title: "Main", bounds: .zero, isMainWindow: true, index: 3),
        ]

        for window in captured {
            let result = Self.normalized(window, resolvedIndex: window.index + 1)
            let normalized = try #require(result.metadata.windowInfo)
            #expect(normalized.isMainWindow == window.isMainWindow)
            #expect(normalized.windowID == window.windowID)
            #expect(normalized.index == window.index + 1)
        }
    }

    @Test(arguments: [0, 3])
    func `normalization does not promote a selected visible window without main evidence`(resolvedIndex: Int) throws {
        let window = ServiceWindowInfo(
            windowID: 42,
            title: "Selected window",
            bounds: CGRect(x: 32, y: 70, width: 580, height: 392),
            isMainWindow: false,
            index: 3,
            isOnScreen: true)
        let result = Self.normalized(window, resolvedIndex: resolvedIndex)
        let normalized = try #require(result.metadata.windowInfo)

        #expect(!normalized.isMainWindow)
        #expect(normalized.isOnScreen)
        #expect(normalized.index == resolvedIndex)
    }

    @Test
    func `normalization cannot transfer supplied main state to a different window`() {
        let window = ServiceWindowInfo(windowID: 42, title: "Main", bounds: .zero, isMainWindow: true, index: 3)
        let capture = CaptureResult(
            imageData: Data([1]),
            metadata: CaptureMetadata(size: .zero, mode: .window, windowInfo: window))
        let result = DesktopObservationService.normalize(
            capture: capture,
            for: ResolvedObservationTarget(
                kind: .windowID(43),
                window: WindowIdentity(windowID: 43, title: "Other", bounds: .zero, index: 0)),
            requestedTarget: .windowID(43))

        #expect(result.metadata.windowInfo == window)
    }

    private static func window(id: Int, isOnScreen: Bool = true) -> SystemWindowIdentity {
        SystemWindowIdentity(
            windowID: CGWindowID(id),
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 456,
            title: "Window \(id)",
            bounds: CGRect(x: CGFloat(id), y: 70, width: 580, height: 392),
            layer: 0,
            alpha: 1,
            isOnScreen: isOnScreen,
            sharingState: .readOnly)
    }

    private static func mutationIdentity(_ window: SystemWindowIdentity) -> WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: Int(window.windowID),
            ownerProcessIdentifier: window.ownerProcessIdentifier,
            ownerProcessStartIdentity: 456,
            capturedBounds: window.bounds,
            isMinimized: false)
    }

    private static func cgWindow(_ window: SystemWindowIdentity) -> [String: Any] {
        [
            kCGWindowNumber as String: Int(window.windowID),
            kCGWindowName as String: window.title,
            kCGWindowBounds as String: [
                "X": window.bounds.minX,
                "Y": window.bounds.minY,
                "Width": window.bounds.width,
                "Height": window.bounds.height,
            ],
            kCGWindowLayer as String: window.layer,
            kCGWindowAlpha as String: window.alpha,
            kCGWindowIsOnscreen as String: window.isOnScreen,
            kCGWindowSharingState as String: 1,
        ]
    }

    private static func normalized(_ window: ServiceWindowInfo, resolvedIndex: Int) -> CaptureResult {
        DesktopObservationService.normalize(
            capture: CaptureResult(
                imageData: Data([1]),
                metadata: CaptureMetadata(size: window.bounds.size, mode: .window, windowInfo: window)),
            for: ResolvedObservationTarget(
                kind: .windowID(CGWindowID(window.windowID)),
                window: WindowIdentity(
                    windowID: window.windowID,
                    title: window.title,
                    bounds: window.bounds,
                    index: resolvedIndex)),
            requestedTarget: .windowID(CGWindowID(window.windowID)))
    }

    private static func image() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }
}
