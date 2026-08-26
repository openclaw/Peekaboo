import CoreGraphics
import Foundation
import PeekabooBridge
import PeekabooBridgeTestSupport
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@MainActor
struct ServiceBridgeTests {
    private let processIdentity = ApplicationProcessIdentity(processIdentifier: 12345, processStartIdentity: 71)

    @Test func `automation click forwards calls`() async throws {
        let automation = MockAutomationService()
        _ = try await AutomationServiceBridge.click(
            automation: automation,
            target: .coordinates(CGPoint(x: 10, y: 20)),
            clickType: .double,
            snapshotId: "snapshot-123"
        )

        #expect(automation.clickCalls.count == 1)
        #expect(automation.clickCalls.first?.snapshotId == "snapshot-123")
    }

    @Test func `automation wait returns mock result`() async throws {
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "OK",
            value: nil,
            bounds: CGRect(x: 0, y: 0, width: 44, height: 20),
            isEnabled: true,
            isSelected: nil,
            attributes: [:]
        )
        let mock = MockAutomationService(waitResult: .init(found: true, element: element, waitTime: 0.25))

        let result = try await AutomationServiceBridge.waitForElement(
            automation: mock,
            target: .elementId("B1"),
            timeout: 1,
            snapshotId: "S42"
        )

        #expect(result.found)
        #expect(mock.waitCalls.count == 1)
    }

    @Test func `automation targeted hotkey forwards calls`() async throws {
        let automation = MockTargetedAutomationService()

        _ = try await AutomationServiceBridge.hotkey(
            automation: automation,
            keys: "cmd,l",
            holdDuration: 75,
            targetProcessIdentifier: 12345
        )

        #expect(automation.targetedHotkeyCalls.count == 1)
        #expect(automation.targetedHotkeyCalls.first?.keys == "cmd,l")
        #expect(automation.targetedHotkeyCalls.first?.holdDuration == 75)
        #expect(automation.targetedHotkeyCalls.first?.targetProcessIdentifier == 12345)
    }

    @Test func `automation targeted hotkey maps missing event synthesizing permission`() async throws {
        let automation = MockTargetedAutomationService()
        automation.supportsTargetedHotkeys = false
        automation.targetedHotkeyRequiresEventSynthesizingPermission = true
        automation.targetedHotkeyUnavailableReason =
            "Remote bridge host supports background hotkeys, but current permissions are missing: Event Synthesizing"

        do {
            _ = try await AutomationServiceBridge.hotkey(
                automation: automation,
                keys: "cmd,l",
                holdDuration: 75,
                targetProcessIdentifier: 12345
            )
            Issue.record("Expected Event Synthesizing permission error")
        } catch PeekabooError.permissionDeniedEventSynthesizing {
            #expect(automation.targetedHotkeyCalls.isEmpty)
        }
    }

    @Test func `automation targeted type forwards calls`() async throws {
        let automation = MockTargetedAutomationService()
        let request = TypeActionsRequest(
            actions: [.text("Hello"), .key(.return)],
            cadence: .fixed(milliseconds: 1),
            snapshotId: "snapshot-123"
        )

        let result = try await AutomationServiceBridge.typeActions(
            automation: automation,
            request: request,
            expectedProcessIdentity: self.processIdentity
        )

        #expect(result.payload.totalCharacters == 2)
        #expect(result.payload.keyPresses == 2)
        #expect(automation.targetedTypeActionsCalls.count == 1)
        #expect(automation.targetedTypeActionsCalls.first?.snapshotId == "snapshot-123")
        #expect(automation.targetedTypeActionsCalls.first?.targetProcessIdentifier == 12345)
    }

    @Test func `automation targeted type maps missing event synthesizing permission`() async throws {
        let automation = MockTargetedAutomationService()
        automation.supportsTargetedTypeActions = false
        automation.targetedTypeRequiresEventSynthesizingPermission = true
        automation.targetedTypeUnavailableReason =
            "Remote bridge host supports background typing, but current permissions are missing: Event Synthesizing"

        do {
            _ = try await AutomationServiceBridge.typeActions(
                automation: automation,
                request: TypeActionsRequest(
                    actions: [.text("Hello")],
                    cadence: .fixed(milliseconds: 1),
                    snapshotId: nil
                ),
                expectedProcessIdentity: self.processIdentity
            )
            Issue.record("Expected Event Synthesizing permission error")
        } catch PeekabooError.permissionDeniedEventSynthesizing {
            #expect(automation.targetedTypeActionsCalls.isEmpty)
        }
    }

    @Test func `automation targeted click forwards calls`() async throws {
        let automation = MockTargetedAutomationService()

        _ = try await AutomationServiceBridge.click(
            automation: automation,
            target: .coordinates(CGPoint(x: 10, y: 20)),
            clickType: .single,
            snapshotId: "snapshot-123",
            expectedProcessIdentity: self.processIdentity
        )

        #expect(automation.targetedClickCalls.count == 1)
        #expect(automation.targetedClickCalls.first?.snapshotId == "snapshot-123")
        #expect(automation.targetedClickCalls.first?.targetProcessIdentifier == 12345)
        #expect(automation.targetedClickCalls.first?.targetWindowID == nil)
        #expect(automation.targetedClickCalls.first?.allowsAccessibilityValueDelivery == true)
    }

    @Test func `automation targeted click forwards exact window`() async throws {
        let automation = MockTargetedAutomationService()

        _ = try await AutomationServiceBridge.click(
            automation: automation,
            target: .coordinates(CGPoint(x: 10, y: 20)),
            clickType: .single,
            snapshotId: nil,
            expectedProcessIdentity: ApplicationProcessIdentity(
                processIdentifier: 12345,
                processStartIdentity: 1
            ),
            targetWindowID: 42,
            expectedWindowIdentity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: 12345,
                ownerProcessStartIdentity: 1
            ),
            expectedWindowBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        #expect(automation.targetedClickCalls.first?.targetProcessIdentifier == 12345)
        #expect(automation.targetedClickCalls.first?.targetWindowID == 42)
        #expect(automation.targetedClickCalls.first?.allowsAccessibilityValueDelivery == true)
    }

    @Test func `automation targeted click refuses policy blind hosts before dispatch`() async throws {
        let automation = MockTargetedAutomationService()
        automation.supportsTargetedClickAccessibilityValueDelivery = false

        await #expect(throws: PeekabooError.self) {
            try await AutomationServiceBridge.click(
                automation: automation,
                target: .elementId("field"),
                clickType: .single,
                snapshotId: "snapshot-123",
                expectedProcessIdentity: self.processIdentity
            )
        }
        #expect(automation.targetedClickCalls.isEmpty)
    }

    @Test func `CLI click refuses old 1 34 value policy before remote provider entry`() async throws {
        let services = PolicyBlindBridgeServices()
        let socketPath = "/tmp/peekaboo-cli-old-value-policy-\(UUID().uuidString).sock"
        let version = PeekabooBridgeProtocolVersion(major: 1, minor: 34)
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: version...version
        )
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = BridgeTestFixtures.authenticatedClient(socketPath: socketPath, requestTimeoutSec: 1)
        let handshake = try await client.handshake(
            client: .init(
                bundleIdentifier: "boo.peekaboo.cli-policy-tests",
                teamIdentifier: nil,
                processIdentifier: getpid()
            ),
            protocolVersion: version
        )
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.targetedClickAccessibilityValueDelivery
        ) != true)
        let remote = RemoteUIAutomationService(
            client: client,
            supportsTargetedClicks: true,
            supportsProcessGenerationPinnedClicks: true
        )

        await #expect(throws: PeekabooError.self) {
            try await AutomationServiceBridge.click(
                automation: remote,
                target: .elementId("field"),
                clickType: .single,
                snapshotId: "snapshot-123",
                expectedProcessIdentity: self.processIdentity
            )
        }
        #expect(services.automationService.policyAwareClickEntryCount == 0)
        #expect(services.automationService.targetedClickCalls.isEmpty)
        await host.stop()
    }

    @Test func `automation targeted click maps missing event synthesizing permission`() async throws {
        let automation = MockTargetedAutomationService()
        automation.supportsTargetedClicks = false
        automation.targetedClickRequiresEventSynthesizingPermission = true
        automation.targetedClickUnavailableReason =
            "Remote bridge host supports background clicks, but current permissions are missing: Event Synthesizing"

        do {
            _ = try await AutomationServiceBridge.click(
                automation: automation,
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                expectedProcessIdentity: self.processIdentity
            )
            Issue.record("Expected Event Synthesizing permission error")
        } catch PeekabooError.permissionDeniedEventSynthesizing {
            #expect(automation.targetedClickCalls.isEmpty)
        }
    }

    @Test func `window bridge returns stubbed windows`() async throws {
        let window = ServiceWindowInfo(
            windowID: 101,
            title: "Main",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let windows = try await WindowServiceBridge.listWindows(
            windows: MockWindowService(result: [window]),
            target: .frontmost
        )
        #expect(windows == [window])
    }

    @Test func `window bridge propagates close cancellation`() async {
        let service = CancellableWindowService()
        let task = Task { @MainActor in
            try await WindowServiceBridge.closeWindow(windows: service, target: .frontmost)
        }

        while !service.closeStarted {
            await Task.yield()
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(service.observedCancellation)
    }

    @Test func `menu bridge lists menu bar items`() async throws {
        let menuItems = [MenuBarItemInfo(
            title: "Item",
            index: 0,
            isVisible: true,
            description: nil,
            rawTitle: "Item",
            bundleIdentifier: "com.test",
            ownerName: "Test",
            frame: nil,
            identifier: "com.test.item"
        )]
        let items = try await MenuServiceBridge.listMenuBarItems(menu: MockMenuService(barItems: menuItems))
        #expect(items.count == 1)
        #expect(items.first?.title == "Item")
    }

    @Test func `dock bridge lists items`() async throws {
        let dockItems = [DockItem(
            index: 0,
            title: "Peekaboo",
            itemType: .application,
            isRunning: true,
            bundleIdentifier: "boo.peekaboo",
            position: nil,
            size: nil
        )]
        let items = try await DockServiceBridge.listDockItems(
            dock: MockDockService(items: dockItems),
            includeAll: true
        )
        #expect(items == dockItems)
    }
}

@MainActor
class MockAutomationService: UIAutomationServiceProtocol {
    struct ClickCall { let target: ClickTarget; let clickType: ClickType; let snapshotId: String? }
    var clickCalls: [ClickCall] = []
    var waitCalls: [ClickTarget] = []
    var waitResult: WaitForElementResult

    init(waitResult: WaitForElementResult = .init(found: false, element: nil, waitTime: 0)) {
        self.waitResult = waitResult
    }

    func detectElements(
        in _: Data,
        snapshotId _: String?,
        windowContext _: WindowContext?
    ) async throws -> ElementDetectionResult {
        throw PeekabooError.notImplemented("mock detectElements")
    }

    func click(target: ClickTarget, clickType: ClickType, snapshotId: String?) async throws {
        self.clickCalls.append(.init(target: target, clickType: clickType, snapshotId: snapshotId))
    }

    func type(
        text _: String,
        target _: String?,
        clearExisting _: Bool,
        typingDelay _: Int,
        snapshotId _: String?
    ) async throws {}

    func typeActions(
        _ actions: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?
    ) async throws -> TypeResult {
        TypeResult(totalCharacters: actions.count, keyPresses: actions.count)
    }

    func scroll(_ request: ScrollRequest) async throws {
        _ = request
    }

    func hotkey(keys _: String, holdDuration _: Int) async throws {}

    func swipe(
        from _: CGPoint,
        to _: CGPoint,
        duration _: Int,
        steps _: Int,
        profile _: MouseMovementProfile
    ) async throws {}

    func hasAccessibilityPermission() async -> Bool {
        true
    }

    func waitForElement(
        target: ClickTarget,
        timeout _: TimeInterval,
        snapshotId _: String?
    ) async throws -> WaitForElementResult {
        self.waitCalls.append(target)
        return self.waitResult
    }

    func drag(_: DragOperationRequest) async throws {}

    func moveMouse(to _: CGPoint, duration _: Int, steps _: Int, profile _: MouseMovementProfile) async throws {}

    func getFocusedElement() -> UIFocusInfo? {
        nil
    }

    func findElement(matching _: UIElementSearchCriteria, in _: String?) async throws -> DetectedElement {
        throw PeekabooError.elementNotFound("not implemented")
    }
}

@MainActor
final class MockTargetedAutomationService: MockAutomationService, TargetedHotkeyServiceProtocol,
TargetedTypeServiceProtocol, ExactWindowTargetedClickServiceProtocol {
    struct TargetedHotkeyCall {
        let keys: String
        let holdDuration: Int
        let targetProcessIdentifier: pid_t
    }

    struct TargetedClickCall {
        let target: ClickTarget
        let clickType: ClickType
        let snapshotId: String?
        let targetProcessIdentifier: pid_t
        let targetWindowID: Int?
        let allowsAccessibilityValueDelivery: Bool?
    }

    struct TargetedTypeActionsCall {
        let actions: [TypeAction]
        let cadence: TypingCadence
        let snapshotId: String?
        let targetProcessIdentifier: pid_t
    }

    var targetedHotkeyCalls: [TargetedHotkeyCall] = []
    var targetedTypeActionsCalls: [TargetedTypeActionsCall] = []
    var targetedClickCalls: [TargetedClickCall] = []
    private(set) var policyAwareClickEntryCount = 0
    var supportsTargetedHotkeys = true
    var targetedHotkeyUnavailableReason: String?
    var targetedHotkeyRequiresEventSynthesizingPermission = false
    var supportsTargetedTypeActions = true
    var supportsProcessGenerationPinnedTypeActions = true
    var targetedTypeUnavailableReason: String?
    var targetedTypeRequiresEventSynthesizingPermission = false
    var supportsTargetedClicks = true
    var supportsProcessGenerationPinnedClicks = true
    var supportsTargetedClickAccessibilityValueDelivery = true
    var targetedClickUnavailableReason: String?
    var targetedClickRequiresEventSynthesizingPermission = false

    func hotkey(keys: String, holdDuration: Int, targetProcessIdentifier: pid_t) async throws {
        self.targetedHotkeyCalls.append(.init(
            keys: keys,
            holdDuration: holdDuration,
            targetProcessIdentifier: targetProcessIdentifier
        ))
    }

    func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: pid_t
    ) async throws -> TypeResult {
        self.targetedTypeActionsCalls.append(.init(
            actions: actions,
            cadence: cadence,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier
        ))
        return try await self.typeActions(actions, cadence: cadence, snapshotId: snapshotId)
    }

    func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity
    ) async throws -> TypeResult {
        self.targetedTypeActionsCalls.append(.init(
            actions: actions,
            cadence: cadence,
            snapshotId: snapshotId,
            targetProcessIdentifier: expectedProcessIdentity.processIdentifier
        ))
        return try await self.typeActions(actions, cadence: cadence, snapshotId: snapshotId)
    }

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t
    ) async throws {
        self.targetedClickCalls.append(.init(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier,
            targetWindowID: nil,
            allowsAccessibilityValueDelivery: nil
        ))
    }

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity
    ) async throws {
        self.targetedClickCalls.append(.init(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: expectedProcessIdentity.processIdentifier,
            targetWindowID: nil,
            allowsAccessibilityValueDelivery: nil
        ))
    }

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity,
        allowsAccessibilityValueDelivery: Bool
    ) async throws {
        self.policyAwareClickEntryCount += 1
        guard self.supportsTargetedClickAccessibilityValueDelivery else {
            throw PeekabooError.serviceUnavailable("Targeted click value-delivery policy is unavailable")
        }
        self.targetedClickCalls.append(.init(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: expectedProcessIdentity.processIdentifier,
            targetWindowID: nil,
            allowsAccessibilityValueDelivery: allowsAccessibilityValueDelivery
        ))
    }

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds _: CGRect
    ) async throws {
        self.targetedClickCalls.append(.init(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: expectedWindowIdentity.ownerProcessIdentifier,
            targetWindowID: expectedWindowIdentity.windowID,
            allowsAccessibilityValueDelivery: nil
        ))
    }

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds _: CGRect,
        allowsAccessibilityValueDelivery: Bool
    ) async throws {
        self.policyAwareClickEntryCount += 1
        guard self.supportsTargetedClickAccessibilityValueDelivery else {
            throw PeekabooError.serviceUnavailable("Targeted click value-delivery policy is unavailable")
        }
        self.targetedClickCalls.append(.init(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: expectedWindowIdentity.ownerProcessIdentifier,
            targetWindowID: expectedWindowIdentity.windowID,
            allowsAccessibilityValueDelivery: allowsAccessibilityValueDelivery
        ))
    }
}

@MainActor
private final class PolicyBlindBridgeServices: PeekabooBridgeServiceProviding {
    let base = PeekabooServices()
    let automationService = MockTargetedAutomationService()

    var permissions: PermissionsService {
        self.base.permissions
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        self.base.screenCapture
    }

    var automation: any UIAutomationServiceProtocol {
        self.automationService
    }

    var windows: any WindowManagementServiceProtocol {
        self.base.windows
    }

    var applications: any ApplicationServiceProtocol {
        self.base.applications
    }

    var menu: any MenuServiceProtocol {
        self.base.menu
    }

    var dock: any DockServiceProtocol {
        self.base.dock
    }

    var dialogs: any DialogServiceProtocol {
        self.base.dialogs
    }

    var snapshots: any SnapshotManagerProtocol {
        self.base.snapshots
    }

    var desktopObservation: any DesktopObservationServiceProtocol {
        self.base.desktopObservation
    }

    init() {
        self.automationService.supportsTargetedClickAccessibilityValueDelivery = false
    }
}

@MainActor
final class MockWindowService: WindowManagementServiceProtocol {
    let windowsResult: [ServiceWindowInfo]

    init(result: [ServiceWindowInfo]) {
        self.windowsResult = result
    }

    func closeWindow(target _: WindowTarget) async throws {}
    func minimizeWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}
    func focusWindow(target _: WindowTarget) async throws {}
    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        self.windowsResult
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        self.windowsResult.first
    }
}

@MainActor
final class CancellableWindowService: WindowManagementServiceProtocol {
    var closeStarted = false
    var observedCancellation = false

    func closeWindow(target: WindowTarget, allowForegroundFallback _: Bool) async throws {
        try await self.closeWindow(target: target)
    }

    func closeWindow(target _: WindowTarget) async throws {
        await MainActor.run {
            self.closeStarted = true
        }
        do {
            try await Task.sleep(nanoseconds: 30_000_000_000)
        } catch is CancellationError {
            await MainActor.run {
                self.observedCancellation = true
            }
            throw CancellationError()
        }
    }

    func minimizeWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}
    func focusWindow(target _: WindowTarget) async throws {}
    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        []
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}

@MainActor
final class MockMenuService: MenuServiceProtocol {
    var barItems: [MenuBarItemInfo]

    init(barItems: [MenuBarItemInfo]) {
        self.barItems = barItems
    }

    func listMenus(for _: String) async throws -> MenuStructure {
        self.emptyStructure
    }

    func listFrontmostMenus() async throws -> MenuStructure {
        self.emptyStructure
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
        self.barItems
    }

    func clickMenuBarItem(named _: String) async throws -> PeekabooCore.ClickResult {
        .init(
            elementDescription: "",
            location: nil
        )
    }

    func clickMenuBarItem(at _: Int) async throws -> PeekabooCore.ClickResult {
        .init(
            elementDescription: "",
            location: nil
        )
    }

    private var emptyStructure: MenuStructure {
        MenuStructure(
            application: ServiceApplicationInfo(processIdentifier: 1, bundleIdentifier: "test", name: "Test"),
            menus: []
        )
    }
}

@MainActor
final class MockDockService: DockServiceProtocol {
    var items: [DockItem]

    init(items: [DockItem]) {
        self.items = items
    }

    func listDockItems(includeAll _: Bool) async throws -> [DockItem] {
        self.items
    }

    func launchFromDock(appName _: String) async throws {}
    func addToDock(path _: String, persistent _: Bool) async throws {}
    func removeFromDock(appName _: String) async throws {}
    func rightClickDockItem(appName _: String, menuItem _: String?) async throws {}
    func hideDock() async throws {}
    func showDock() async throws {}
    func isDockAutoHidden() async -> Bool {
        false
    }

    func findDockItem(name _: String) async throws -> DockItem {
        self.items.first!
    }
}
