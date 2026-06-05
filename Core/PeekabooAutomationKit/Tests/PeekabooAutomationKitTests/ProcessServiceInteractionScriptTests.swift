import CoreGraphics
import Foundation
import PeekabooFoundation
import UniformTypeIdentifiers
import XCTest
@testable import PeekabooAutomationKit

@available(macOS 14.0, *)
@MainActor
final class ProcessServiceInteractionScriptTests: XCTestCase {
    func testMenuGenericParametersCombineMenuAndItemPath() async throws {
        let menuService = RecordingMenuService()
        let processService = ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: UnusedScreenCaptureService(),
            snapshotManager: UnusedSnapshotManager(),
            uiAutomationService: UnusedUIAutomationService(),
            windowManagementService: UnusedWindowManagementService(),
            menuService: menuService,
            dockService: UnusedDockService(),
            clipboardService: UnusedClipboardService())

        _ = try await processService.executeStep(
            ScriptStep(stepId: "menu", comment: nil, command: "menu", params: .generic([
                "app": "Finder",
                "menu": "File",
                "item": "New Finder Window",
            ])),
            snapshotId: nil)

        XCTAssertEqual(menuService.clicks, [
            RecordingMenuService.Click(app: "Finder", itemPath: "File > New Finder Window"),
        ])
    }

    func testMenuGenericParametersPreserveMenuPathWithoutItem() async throws {
        let menuService = RecordingMenuService()
        let processService = ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: UnusedScreenCaptureService(),
            snapshotManager: UnusedSnapshotManager(),
            uiAutomationService: UnusedUIAutomationService(),
            windowManagementService: UnusedWindowManagementService(),
            menuService: menuService,
            dockService: UnusedDockService(),
            clipboardService: UnusedClipboardService())

        _ = try await processService.executeStep(
            ScriptStep(stepId: "menu", comment: nil, command: "menu", params: .generic([
                "app": "Finder",
                "menu": "File > New Finder Window",
            ])),
            snapshotId: nil)

        XCTAssertEqual(menuService.clicks, [
            RecordingMenuService.Click(app: "Finder", itemPath: "File > New Finder Window"),
        ])
    }

    func testHotkeyGenericParametersParseModifiersList() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let processService = ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: UnusedScreenCaptureService(),
            snapshotManager: UnusedSnapshotManager(),
            uiAutomationService: automation,
            windowManagementService: UnusedWindowManagementService(),
            menuService: UnusedMenuService(),
            dockService: UnusedDockService(),
            clipboardService: UnusedClipboardService())

        _ = try await processService.executeStep(
            ScriptStep(stepId: "hotkey", comment: nil, command: "hotkey", params: .generic([
                "key": "p",
                "modifiers": "command,shift",
            ])),
            snapshotId: nil)

        XCTAssertEqual(automation.hotkeys, ["cmd,shift,p"])
    }

    func testTypeGenericParametersParseCamelCaseControlFlags() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let processService = ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: UnusedScreenCaptureService(),
            snapshotManager: UnusedSnapshotManager(),
            uiAutomationService: automation,
            windowManagementService: UnusedWindowManagementService(),
            menuService: UnusedMenuService(),
            dockService: UnusedDockService(),
            clipboardService: UnusedClipboardService())

        _ = try await processService.executeStep(
            ScriptStep(stepId: "type", comment: nil, command: "type", params: .generic([
                "text": "hello",
                "field": "Search",
                "clearFirst": "true",
                "pressEnter": "true",
            ])),
            snapshotId: "snapshot-1")

        XCTAssertEqual(automation.typedText, [
            RecordingInteractionUIAutomationService.TypeCall(
                text: "hello",
                target: "Search",
                clearExisting: true,
                snapshotId: "snapshot-1"),
        ])
        XCTAssertEqual(automation.typeActionCounts, [1])
    }

    func testSwipeWithoutExplicitStartUsesPrimaryScreenServiceCenter() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let processService = ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: UnusedScreenCaptureService(),
            snapshotManager: UnusedSnapshotManager(),
            uiAutomationService: automation,
            windowManagementService: UnusedWindowManagementService(),
            menuService: UnusedMenuService(),
            dockService: UnusedDockService(),
            clipboardService: UnusedClipboardService(),
            screenService: StaticScreenService(frame: CGRect(x: 100, y: 50, width: 600, height: 400)))

        _ = try await processService.executeStep(
            ScriptStep(stepId: "swipe", comment: nil, command: "swipe", params: .generic([
                "direction": "left",
                "distance": "40",
                "duration": "0.25",
            ])),
            snapshotId: nil)

        XCTAssertEqual(automation.swipes.count, 1)
        XCTAssertEqual(automation.swipes[0].from, CGPoint(x: 400, y: 250))
        XCTAssertEqual(automation.swipes[0].to, CGPoint(x: 360, y: 250))
        XCTAssertEqual(automation.swipes[0].duration, 250)
    }

    func testDragGenericParametersParseModifiersList() async throws {
        let automation = RecordingInteractionUIAutomationService()
        let processService = ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: UnusedScreenCaptureService(),
            snapshotManager: UnusedSnapshotManager(),
            uiAutomationService: automation,
            windowManagementService: UnusedWindowManagementService(),
            menuService: UnusedMenuService(),
            dockService: UnusedDockService(),
            clipboardService: UnusedClipboardService())

        _ = try await processService.executeStep(
            ScriptStep(stepId: "drag", comment: nil, command: "drag", params: .generic([
                "from-x": "10",
                "from-y": "20",
                "to-x": "30",
                "to-y": "40",
                "modifiers": "command,shift",
            ])),
            snapshotId: nil)

        XCTAssertEqual(automation.drags, [
            RecordingInteractionUIAutomationService.DragCall(
                from: CGPoint(x: 10, y: 20),
                to: CGPoint(x: 30, y: 40),
                modifiers: "cmd,shift"),
        ])
    }
}

@available(macOS 14.0, *)
@MainActor
private final class RecordingMenuService: MenuServiceProtocol {
    struct Click: Equatable {
        let app: String
        let itemPath: String
    }

    var clicks: [Click] = []

    func clickMenuItem(app: String, itemPath: String) async throws {
        self.clicks.append(Click(app: app, itemPath: itemPath))
    }

    func listMenus(for _: String) async throws -> MenuStructure {
        fatalError("unused")
    }

    func listFrontmostMenus() async throws -> MenuStructure {
        fatalError("unused")
    }

    func clickMenuItemByName(app _: String, itemName _: String) async throws {
        fatalError("unused")
    }

    func clickMenuExtra(title _: String) async throws {
        fatalError("unused")
    }

    func isMenuExtraMenuOpen(title _: String, ownerPID _: pid_t?) async throws -> Bool {
        fatalError("unused")
    }

    func menuExtraOpenMenuFrame(title _: String, ownerPID _: pid_t?) async throws -> CGRect? {
        fatalError("unused")
    }

    func listMenuExtras() async throws -> [MenuExtraInfo] {
        fatalError("unused")
    }

    func listMenuBarItems(includeRaw _: Bool) async throws -> [MenuBarItemInfo] {
        fatalError("unused")
    }

    func clickMenuBarItem(named _: String) async throws -> ClickResult {
        fatalError("unused")
    }

    func clickMenuBarItem(at _: Int) async throws -> ClickResult {
        fatalError("unused")
    }
}

@available(macOS 14.0, *)
@MainActor
private final class UnusedClipboardService: ClipboardServiceProtocol {
    func get(prefer _: UTType?) throws -> ClipboardReadResult? {
        fatalError("unused")
    }

    func set(_: ClipboardWriteRequest) throws -> ClipboardReadResult {
        fatalError("unused")
    }

    func clear() {
        fatalError("unused")
    }

    func save(slot _: String) throws {
        fatalError("unused")
    }

    func restore(slot _: String) throws -> ClipboardReadResult {
        fatalError("unused")
    }
}

@available(macOS 14.0, *)
@MainActor
private final class StaticScreenService: ScreenServiceProtocol {
    private let screen: ScreenInfo

    init(frame: CGRect) {
        self.screen = ScreenInfo(
            index: 0,
            name: "Test Display",
            frame: frame,
            visibleFrame: frame,
            isPrimary: true,
            scaleFactor: 2,
            displayID: 1)
    }

    func listScreens() -> [ScreenInfo] {
        [self.screen]
    }

    func screenContainingWindow(bounds: CGRect) -> ScreenInfo? {
        self.screen.frame.intersects(bounds) ? self.screen : nil
    }

    func screen(at index: Int) -> ScreenInfo? {
        index == 0 ? self.screen : nil
    }

    var primaryScreen: ScreenInfo? {
        self.screen
    }
}

@available(macOS 14.0, *)
@MainActor
private final class RecordingInteractionUIAutomationService: UIAutomationServiceProtocol {
    struct SwipeCall {
        let from: CGPoint
        let to: CGPoint
        let duration: Int
    }

    var swipes: [SwipeCall] = []
    var hotkeys: [String] = []
    var typedText: [TypeCall] = []
    var typeActionCounts: [Int] = []
    var drags: [DragCall] = []

    struct TypeCall: Equatable {
        let text: String
        let target: String?
        let clearExisting: Bool
        let snapshotId: String?
    }

    struct DragCall: Equatable {
        let from: CGPoint
        let to: CGPoint
        let modifiers: String?
    }

    func hotkey(keys: String, holdDuration _: Int) async throws {
        self.hotkeys.append(keys)
    }

    func type(text: String, target: String?, clearExisting: Bool, typingDelay _: Int, snapshotId: String?)
        async throws
    {
        self.typedText.append(TypeCall(
            text: text,
            target: target,
            clearExisting: clearExisting,
            snapshotId: snapshotId))
    }

    func typeActions(
        _ actions: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?) async throws -> TypeResult
    {
        self.typeActionCounts.append(actions.count)
        return TypeResult(totalCharacters: 0, keyPresses: actions.count)
    }

    func swipe(from: CGPoint, to: CGPoint, duration: Int, steps _: Int, profile _: MouseMovementProfile) async throws {
        self.swipes.append(SwipeCall(from: from, to: to, duration: duration))
    }

    func detectElements(in _: Data, snapshotId _: String?, windowContext _: WindowContext?) async throws
        -> ElementDetectionResult
    {
        fatalError("unused")
    }

    func click(target _: ClickTarget, clickType _: ClickType, snapshotId _: String?) async throws {
        fatalError("unused")
    }

    func scroll(_: ScrollRequest) async throws {
        fatalError("unused")
    }

    func hasAccessibilityPermission() async -> Bool {
        fatalError("unused")
    }

    func waitForElement(target _: ClickTarget, timeout _: TimeInterval, snapshotId _: String?) async throws
        -> WaitForElementResult
    {
        fatalError("unused")
    }

    func drag(_ request: DragOperationRequest) async throws {
        self.drags.append(DragCall(
            from: request.from,
            to: request.to,
            modifiers: request.modifiers))
    }

    func moveMouse(to _: CGPoint, duration _: Int, steps _: Int, profile _: MouseMovementProfile) async throws {
        fatalError("unused")
    }

    func getFocusedElement() -> UIFocusInfo? {
        fatalError("unused")
    }

    func findElement(matching _: UIElementSearchCriteria, in _: String?) async throws -> DetectedElement {
        fatalError("unused")
    }
}
