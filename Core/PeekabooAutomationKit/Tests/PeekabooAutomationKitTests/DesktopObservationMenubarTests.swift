import CoreGraphics
import PeekabooFoundation
import XCTest
@testable import PeekabooAutomationKit

@MainActor
final class DesktopObservationMenubarTests: XCTestCase {
    func testObservationCapturesResolvedMenuBarBoundsAsArea() async throws {
        let menuBarBounds = CGRect(x: 0, y: 1080, width: 1728, height: 37)
        let capture = MenuBarRecordingScreenCaptureService()
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: MenuBarRecordingAutomationService(),
            targetResolver: MenuBarTargetResolver(
                target: ResolvedObservationTarget(kind: .menubar, bounds: menuBarBounds)))

        let result = try await service.observe(DesktopObservationRequest(
            target: .menubar,
            detection: DesktopDetectionOptions(mode: .none)))

        XCTAssertEqual(capture.capturedAreas, [menuBarBounds])
        XCTAssertEqual(result.target.kind, .menubar)
        XCTAssertEqual(result.target.bounds, menuBarBounds)
        XCTAssertEqual(result.timings.spans.map(\.name), [
            "state.snapshot",
            "target.resolve",
            "capture.area",
            "desktop.observe",
        ])
    }

    func testMenuBarObservationReportsSharedTargetDiagnostics() async throws {
        let capture = MenuBarRecordingScreenCaptureService()
        let screen = Self.primaryScreen()
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: MenuBarRecordingAutomationService(),
            applications: UnusedApplicationService(),
            screens: MenuBarRecordingScreenService(screens: [screen]))

        let result = try await service.observe(DesktopObservationRequest(
            target: .menubar,
            detection: DesktopDetectionOptions(mode: .none)))

        let target = try XCTUnwrap(result.diagnostics.target)
        XCTAssertEqual(target.requestedKind, "menubar")
        XCTAssertEqual(target.resolvedKind, "menubar")
        XCTAssertEqual(target.source, "primary-screen")
        XCTAssertEqual(target.bounds, ObservationTargetResolver.menuBarBounds(for: screen))
        XCTAssertEqual(target.captureScaleHint, screen.scaleFactor)
    }

    func testPopoverObservationCapturesResolvedWindowID() async throws {
        let capture = MenuBarRecordingScreenCaptureService()
        let bounds = CGRect(x: 1200, y: 920, width: 320, height: 260)
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: MenuBarRecordingAutomationService(),
            targetResolver: MenuBarTargetResolver(target: ResolvedObservationTarget(
                kind: .menubarPopover,
                app: ApplicationIdentity(processIdentifier: 123, bundleIdentifier: nil, name: "Trimmy"),
                window: WindowIdentity(windowID: 42, title: "", bounds: bounds, index: 0),
                bounds: bounds)))

        let result = try await service.observe(DesktopObservationRequest(
            target: .menubarPopover(hints: ["Trimmy"]),
            detection: DesktopDetectionOptions(mode: .none)))

        XCTAssertEqual(capture.capturedWindowIDs, [42])
        XCTAssertEqual(result.target.kind, .menubarPopover)
        XCTAssertEqual(result.target.bounds, bounds)
        XCTAssertEqual(result.timings.spans.map(\.name), [
            "state.snapshot",
            "target.resolve",
            "capture.area",
            "desktop.observe",
        ])
        XCTAssertEqual(result.diagnostics.target?.source, "window-list")
        XCTAssertEqual(result.diagnostics.target?.windowID, 42)
    }

    func testPopoverResolverPrefersHintedOwnerNearMenuBar() {
        let screen = ScreenInfo(
            index: 0,
            name: "Main",
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080),
            isPrimary: true,
            scaleFactor: 2,
            displayID: 1)
        let windows = [
            Self.windowInfo(
                id: 1,
                ownerPID: 100,
                ownerName: "Other",
                bounds: CGRect(x: 100, y: 900, width: 260, height: 180)),
            Self.windowInfo(
                id: 2,
                ownerPID: 200,
                ownerName: "Trimmy",
                bounds: CGRect(x: 1100, y: 860, width: 300, height: 220)),
            Self.windowInfo(
                id: 3,
                ownerPID: 300,
                ownerName: "Window Server",
                title: "Menubar",
                bounds: CGRect(x: 0, y: 1080, width: 1728, height: 37),
                layer: 24),
        ]

        let candidate = ObservationMenuBarPopoverResolver.resolve(
            hints: ["Trimmy"],
            windowList: windows,
            screens: [screen])

        XCTAssertEqual(candidate?.windowID, 2)
        XCTAssertEqual(candidate?.ownerPID, 200)
    }

    func testPopoverResolverRejectsUnmatchedHints() {
        let screen = Self.primaryScreen()
        let windows = [
            Self.windowInfo(
                id: 1,
                ownerPID: 100,
                ownerName: "Other",
                bounds: CGRect(x: 100, y: 900, width: 260, height: 180)),
        ]

        let candidate = ObservationMenuBarPopoverResolver.resolve(
            hints: ["Definitely Not Open Menu Extra For Test"],
            windowList: windows,
            screens: [screen])

        XCTAssertNil(candidate)
    }

    func testPopoverResolverSelectsFromCatalogCandidates() {
        let candidates = [
            ObservationMenuBarPopoverCandidate(
                windowID: 1,
                ownerPID: 100,
                ownerName: "Other",
                title: nil,
                bounds: CGRect(x: 100, y: 900, width: 260, height: 180),
                layer: 0),
            ObservationMenuBarPopoverCandidate(
                windowID: 2,
                ownerPID: 200,
                ownerName: "Trimmy",
                title: "Menu",
                bounds: CGRect(x: 1100, y: 860, width: 300, height: 220),
                layer: 0),
        ]

        let candidate = ObservationMenuBarPopoverResolver.resolve(
            hints: ["Trimmy"],
            candidates: candidates)

        XCTAssertEqual(candidate?.windowID, 2)
    }

    func testMenuBarWindowCatalogBuildsTypedSnapshot() {
        let screen = Self.primaryScreen()
        let windows = [
            Self.windowInfo(
                id: 1,
                ownerPID: 100,
                ownerName: "Other",
                bounds: CGRect(x: 100, y: 900, width: 260, height: 180)),
            Self.windowInfo(
                id: 2,
                ownerPID: 200,
                ownerName: "Trimmy",
                title: "Menu",
                bounds: CGRect(x: 1100, y: 860, width: 300, height: 220)),
        ]

        let snapshot = ObservationMenuBarWindowCatalog.snapshot(
            windowList: windows,
            screens: [screen])

        XCTAssertEqual(snapshot.candidates.map(\.windowID), [1, 2])
        XCTAssertEqual(snapshot.windowInfoByID[2]?.ownerName, "Trimmy")
        XCTAssertEqual(snapshot.windowInfoByID[2]?.title, "Menu")
    }

    func testMenuBarWindowCatalogFiltersSnapshotByOwnerPID() {
        let screen = Self.primaryScreen()
        let windows = [
            Self.windowInfo(
                id: 1,
                ownerPID: 100,
                ownerName: "Other",
                bounds: CGRect(x: 100, y: 900, width: 260, height: 180)),
            Self.windowInfo(
                id: 2,
                ownerPID: 200,
                ownerName: "Trimmy",
                bounds: CGRect(x: 1100, y: 860, width: 300, height: 220)),
        ]

        let snapshot = ObservationMenuBarWindowCatalog.snapshot(
            windowList: windows,
            screens: [screen],
            ownerPID: 200)

        XCTAssertEqual(snapshot.candidates.map(\.windowID), [2])
        XCTAssertEqual(snapshot.windowInfoByID[1]?.ownerName, "Other")
    }

    func testMenuBarWindowCatalogFindsWindowIDsByOwnerAndTitle() {
        let windows = [
            Self.windowInfo(
                id: 1,
                ownerPID: 100,
                ownerName: "Other",
                bounds: CGRect(x: 100, y: 900, width: 260, height: 180)),
            Self.windowInfo(
                id: 2,
                ownerPID: 200,
                ownerName: "Trimmy",
                title: "Battery Menu",
                bounds: CGRect(x: 1100, y: 860, width: 300, height: 220)),
        ]

        XCTAssertEqual(ObservationMenuBarWindowCatalog.windowIDsForPID(
            ownerPID: 200,
            windowList: windows), [2])
        XCTAssertEqual(ObservationMenuBarWindowCatalog.windowIDsMatchingOwnerNameOrTitle(
            "battery",
            windowList: windows), [2])
    }

    func testMenuBarWindowCatalogBandCandidatesUsePreferredX() {
        let screen = Self.primaryScreen()
        let windows = [
            Self.windowInfo(
                id: 1,
                ownerPID: 100,
                ownerName: "Far",
                bounds: CGRect(x: 100, y: 940, width: 220, height: 160)),
            Self.windowInfo(
                id: 2,
                ownerPID: 200,
                ownerName: "Near",
                bounds: CGRect(x: 1160, y: 940, width: 240, height: 180)),
        ]

        let candidates = ObservationMenuBarWindowCatalog.bandCandidates(
            windowList: windows,
            preferredX: 1200,
            screens: [screen])

        XCTAssertEqual(candidates.map(\.windowID), [2])
    }

    func testPopoverOCRSelectorMatchesCandidateWindow() async throws {
        let capture = MenuBarRecordingScreenCaptureService()
        let ocr = MenuBarRecordingOCRRecognizer(text: "Battery Sound")
        let selector = ObservationMenuBarPopoverOCRSelector(
            screenCapture: capture,
            screens: [Self.primaryScreen()],
            ocrRecognizer: ocr)
        let bounds = CGRect(x: 1000, y: 880, width: 320, height: 220)

        let match = try await selector.matchCandidate(
            windowID: 42,
            bounds: bounds,
            hints: ["battery"])

        XCTAssertEqual(capture.capturedWindowIDs, [42])
        XCTAssertEqual(match?.bounds, bounds)
        XCTAssertEqual(match?.windowID, CGWindowID(42))
    }

    func testPopoverOCRSelectorCapturesPreferredArea() async throws {
        let capture = MenuBarRecordingScreenCaptureService()
        let ocr = MenuBarRecordingOCRRecognizer(text: "Wi-Fi Bluetooth")
        let screen = Self.primaryScreen()
        let selector = ObservationMenuBarPopoverOCRSelector(
            screenCapture: capture,
            screens: [screen],
            ocrRecognizer: ocr)

        let match = try await selector.matchArea(preferredX: 1600, hints: ["bluetooth"])

        let expected = try XCTUnwrap(ObservationMenuBarPopoverOCRSelector.popoverAreaRect(
            preferredX: 1600,
            screens: [screen]))
        XCTAssertEqual(capture.capturedAreas, [expected])
        XCTAssertEqual(match?.bounds, expected)
    }

    func testPopoverObservationCanOpenMenuExtraAndCaptureClickAreaFallback() async throws {
        let capture = MenuBarRecordingScreenCaptureService()
        let menu = MenuBarRecordingMenuService(location: CGPoint(x: 1600, y: 1098))
        let screen = Self.primaryScreen()
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: MenuBarRecordingAutomationService(),
            applications: UnusedApplicationService(),
            menu: menu,
            screens: MenuBarRecordingScreenService(screens: [screen]),
            ocrRecognizer: MenuBarRecordingOCRRecognizer(text: "Definitely Not Open Menu Extra For Test"))
        let expected = try XCTUnwrap(ObservationMenuBarPopoverOCRSelector.popoverAreaRect(
            preferredX: 1600,
            screens: [screen]))

        let result = try await service.observe(DesktopObservationRequest(
            target: .menubarPopover(
                hints: ["Definitely Not Open Menu Extra For Test"],
                openIfNeeded: MenuBarPopoverOpenOptions(
                    clickHint: "Definitely Not Open Menu Extra For Test",
                    settleDelayNanoseconds: 0)),
            detection: DesktopDetectionOptions(mode: .none)))

        XCTAssertEqual(menu.clickedNames, ["Definitely Not Open Menu Extra For Test"])
        XCTAssertEqual(capture.capturedAreas, [expected])
        XCTAssertEqual(result.target.kind, .menubarPopover)
        XCTAssertEqual(result.target.bounds, expected)
        XCTAssertEqual(result.diagnostics.target?.requestedKind, "menubar-popover")
        XCTAssertEqual(result.diagnostics.target?.resolvedKind, "menubar-popover")
        XCTAssertEqual(result.diagnostics.target?.source, "click-location-area-fallback")
        XCTAssertEqual(result.diagnostics.target?.hints, ["Definitely Not Open Menu Extra For Test"])
        XCTAssertEqual(result.diagnostics.target?.openIfNeeded, true)
        XCTAssertEqual(result.diagnostics.target?.clickHint, "Definitely Not Open Menu Extra For Test")
        XCTAssertNil(result.diagnostics.target?.windowID)
    }

    private static func windowInfo(
        id: Int,
        ownerPID: Int,
        ownerName: String,
        title: String = "",
        bounds: CGRect,
        layer: Int = 0) -> [String: Any]
    {
        [
            kCGWindowNumber as String: id,
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowOwnerName as String: ownerName,
            kCGWindowName as String: title,
            kCGWindowLayer as String: layer,
            kCGWindowIsOnscreen as String: true,
            kCGWindowAlpha as String: 1.0,
            kCGWindowBounds as String: [
                "X": bounds.origin.x,
                "Y": bounds.origin.y,
                "Width": bounds.width,
                "Height": bounds.height,
            ],
        ]
    }

    private static func primaryScreen() -> ScreenInfo {
        ScreenInfo(
            index: 0,
            name: "Main",
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080),
            isPrimary: true,
            scaleFactor: 2,
            displayID: 1)
    }
}

@MainActor
private final class MenuBarTargetResolver: ObservationTargetResolving {
    private let target: ResolvedObservationTarget

    init(target: ResolvedObservationTarget) {
        self.target = target
    }

    func resolve(
        _: DesktopObservationTargetRequest,
        snapshot _: DesktopStateSnapshot) async throws -> ResolvedObservationTarget
    {
        self.target
    }
}

@MainActor
private final class MenuBarRecordingScreenCaptureService: ScreenCaptureServiceProtocol {
    var capturedAreas: [CGRect] = []
    var capturedWindowIDs: [CGWindowID] = []

    func captureScreen(
        displayIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw DesktopObservationError.unsupportedTarget("screen")
    }

    func captureWindow(
        appIdentifier _: String,
        windowIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw DesktopObservationError.unsupportedTarget("window")
    }

    func captureWindow(
        windowID: CGWindowID,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.capturedWindowIDs.append(windowID)
        return CaptureResult(
            imageData: Data([4, 5, 6]),
            metadata: CaptureMetadata(size: CGSize(width: 320, height: 260), mode: .window))
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw DesktopObservationError.unsupportedTarget("frontmost")
    }

    func captureArea(
        _ rect: CGRect,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.capturedAreas.append(rect)
        return CaptureResult(
            imageData: Data([1, 2, 3]),
            metadata: CaptureMetadata(size: rect.size, mode: .area))
    }

    func hasScreenRecordingPermission() async -> Bool {
        true
    }
}

@MainActor
private final class MenuBarRecordingAutomationService: UIAutomationServiceProtocol {
    func detectElements(
        in _: Data,
        snapshotId _: String?,
        windowContext _: WindowContext?) async throws -> ElementDetectionResult
    {
        throw DesktopObservationError.unsupportedTarget("detection")
    }

    func click(target _: ClickTarget, clickType _: ClickType, snapshotId _: String?) async throws {}
    func type(
        text _: String,
        target _: String?,
        clearExisting _: Bool,
        typingDelay _: Int,
        snapshotId _: String?) async throws {}
    func typeActions(_: [TypeAction], cadence _: TypingCadence, snapshotId _: String?) async throws -> TypeResult {
        TypeResult(totalCharacters: 0, keyPresses: 0)
    }

    func scroll(_: ScrollRequest) async throws {}
    func hotkey(keys _: String, holdDuration _: Int) async throws {}
    func swipe(
        from _: CGPoint,
        to _: CGPoint,
        duration _: Int,
        steps _: Int,
        profile _: MouseMovementProfile) async throws {}
    func hasAccessibilityPermission() async -> Bool {
        true
    }

    func waitForElement(target _: ClickTarget, timeout _: TimeInterval, snapshotId _: String?) async throws
        -> WaitForElementResult
    {
        WaitForElementResult(found: false, element: nil, waitTime: 0)
    }

    func drag(_: DragOperationRequest) async throws {}
    func moveMouse(to _: CGPoint, duration _: Int, steps _: Int, profile _: MouseMovementProfile) async throws {}
    func getFocusedElement() -> UIFocusInfo? {
        nil
    }

    func findElement(matching _: UIElementSearchCriteria, in _: String?) async throws -> DetectedElement {
        DetectedElement(id: "B1", type: .button, bounds: .zero)
    }
}

@MainActor
private final class MenuBarRecordingScreenService: ScreenServiceProtocol {
    private let screens: [ScreenInfo]

    init(screens: [ScreenInfo]) {
        self.screens = screens
    }

    var primaryScreen: ScreenInfo? {
        self.screens.first(where: \.isPrimary) ?? self.screens.first
    }

    func listScreens() -> [ScreenInfo] {
        self.screens
    }

    func screenContainingWindow(bounds: CGRect) -> ScreenInfo? {
        self.screens.first { $0.frame.intersects(bounds) }
    }

    func screen(at index: Int) -> ScreenInfo? {
        self.screens.first { $0.index == index }
    }
}

@MainActor
private final class MenuBarRecordingMenuService: MenuServiceProtocol {
    private let location: CGPoint
    var clickedNames: [String] = []

    init(location: CGPoint) {
        self.location = location
    }

    func listMenus(for _: String) async throws -> MenuStructure {
        fatalError("unused")
    }

    func listFrontmostMenus() async throws -> MenuStructure {
        fatalError("unused")
    }

    func clickMenuItem(app _: String, itemPath _: String) async throws {}

    func clickMenuItemByName(app _: String, itemName _: String) async throws {}

    func clickMenuExtra(title _: String) async throws {}

    func isMenuExtraMenuOpen(title _: String, ownerPID _: pid_t?) async throws -> Bool {
        false
    }

    func menuExtraOpenMenuFrame(title _: String, ownerPID _: pid_t?) async throws -> CGRect? {
        nil
    }

    func listMenuExtras() async throws -> [MenuExtraInfo] {
        []
    }

    func listMenuBarItems(includeRaw _: Bool) async throws -> [MenuBarItemInfo] {
        []
    }

    func clickMenuBarItem(named name: String) async throws -> ClickResult {
        self.clickedNames.append(name)
        return ClickResult(elementDescription: name, location: self.location)
    }

    func clickMenuBarItem(at _: Int) async throws -> ClickResult {
        fatalError("unused")
    }
}

@MainActor
private final class MenuBarRecordingOCRRecognizer: OCRRecognizing {
    private let text: String

    init(text: String) {
        self.text = text
    }

    func recognizeText(in _: Data, timeoutSeconds _: TimeInterval) async throws -> OCRTextResult {
        OCRTextResult(
            observations: [
                OCRTextObservation(
                    text: self.text,
                    confidence: 0.98,
                    boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.2)),
            ],
            imageSize: CGSize(width: 320, height: 220))
    }
}
