import CoreGraphics
import PeekabooAutomationKitTestSupport
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@MainActor
struct FocusApplicationSelectionTests {
    @Test(arguments: [true, false])
    func `remote app focus ignores helper inventory order`(helperFirst: Bool) async throws {
        let visible = Self.window(id: 77, index: 2)
        let helper = Self.helper
        let windows = Self.service(helperFirst ? [helper, visible] : [visible, helper])

        let result = try await Self.focus(windows)

        try Self.expectSelection(visible, result: result, windows: windows)
        #expect(windows.listWindowRequests == [.application("Fixture")])
    }

    @Test
    func `remote app focus uses shared best-window ranking among renderable windows`() async throws {
        let first = Self.window(id: 78)
        let keyWindow = ServiceWindowInfo(
            windowID: 77,
            title: "Key",
            bounds: Self.bounds,
            isKeyWindow: true,
            index: 2,
            mutationIdentity: Self.identity(id: 77)
        )
        let windows = Self.service([first, keyWindow])

        let result = try await Self.focus(windows)

        try Self.expectSelection(keyWindow, result: result, windows: windows)
        #expect(windows.listWindowRequests == [.application("Fixture")])
    }

    @Test(arguments: [true, false])
    func `remote app focus retains first-row fallback without renderable windows`(minimized: Bool) async throws {
        let first = ServiceWindowInfo(
            windowID: 77,
            title: "Fallback",
            bounds: Self.bounds,
            isMinimized: minimized,
            isOnScreen: minimized,
            mutationIdentity: Self.identity(id: 77)
        )
        let windows = Self.service([first, Self.helper])

        let result = try await Self.focus(windows)

        try Self.expectSelection(first, result: result, windows: windows)
    }

    @Test
    func `explicit off-screen window ID stays exact`() async throws {
        let windows = Self.service([Self.window(id: 77), Self.helper])

        let result = try await Self.focus(windows, windowID: CGWindowID(Self.helper.windowID))

        try Self.expectSelection(Self.helper, result: result, windows: windows)
        #expect(windows.listWindowRequests == [.windowId(Self.helper.windowID)])
    }

    @Test
    func `prepared exact selection bypasses broad app ranking`() async throws {
        let windows = Self.service([Self.window(id: 77), Self.helper])
        let prepared = try PreparedFocusSelection(window: Self.helper)

        let result = try await Self.focus(windows, preparedSelection: prepared)

        try Self.expectSelection(Self.helper, result: result, windows: windows)
        #expect(windows.listWindowRequests.isEmpty)
    }

    @Test
    func `unique explicit title retains its non-renderable window`() async throws {
        let windows = Self.service([Self.window(id: 77), Self.helper])

        let result = try await Self.focus(windows, windowTitle: "Helper")

        try Self.expectSelection(Self.helper, result: result, windows: windows)
        #expect(windows.listWindowRequests == [.applicationAndTitle(app: "Fixture", title: "Helper")])
    }

    @Test
    func `ambiguous title refuses instead of ranking its matches`() async {
        let windows = Self.service([Self.window(id: 77, title: "Helper document"), Self.helper])

        await #expect(throws: DesktopActionFailure.self) {
            try await Self.focus(windows, windowTitle: "Helper")
        }

        #expect(windows.listWindowRequests == [.applicationAndTitle(app: "Fixture", title: "Helper")])
        #expect(windows.pinnedIdentities.isEmpty)
        #expect(windows.focusRequests.isEmpty)
    }

    @Test(arguments: InvalidReceipt.allCases)
    func `invalid preferred receipt refuses without selecting a sibling`(receipt: InvalidReceipt) async {
        let invalid = ServiceWindowInfo(
            windowID: 77,
            title: "Preferred",
            bounds: Self.bounds,
            isKeyWindow: true,
            mutationIdentity: receipt.identity
        )
        let windows = Self.service([Self.helper, invalid, Self.window(id: 79)])

        await #expect(throws: PeekabooError.self) {
            try await Self.focus(windows)
        }

        #expect(windows.listWindowRequests == [.application("Fixture")])
        #expect(windows.pinnedIdentities.isEmpty)
        #expect(windows.focusRequests.isEmpty)
    }

    @Test
    func `empty app inventory refuses before focus`() async {
        let windows = Self.service([])

        await #expect(throws: PeekabooError.self) {
            try await Self.focus(windows)
        }

        #expect(windows.listWindowRequests == [.application("Fixture")])
        #expect(windows.pinnedIdentities.isEmpty)
        #expect(windows.focusRequests.isEmpty)
    }

    enum InvalidReceipt: CaseIterable, Sendable {
        case missing, wrongWindowID, missingBounds, changedBounds

        var identity: WindowMutationIdentity? {
            switch self {
            case .missing:
                nil
            case .wrongWindowID:
                FocusApplicationSelectionTests.identity(id: 80)
            case .missingBounds:
                WindowMutationIdentity(windowID: 77, ownerProcessIdentifier: 42, ownerProcessStartIdentity: 9001)
            case .changedBounds:
                WindowMutationIdentity(
                    windowID: 77,
                    ownerProcessIdentifier: 42,
                    ownerProcessStartIdentity: 9001,
                    capturedBounds: CGRect(x: 0, y: 0, width: 600, height: 400)
                )
            }
        }
    }

    private static let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
    private static let helper: ServiceWindowInfo = {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 30)
        return ServiceWindowInfo(
            windowID: 78,
            title: "Helper",
            bounds: bounds,
            isOffScreen: true,
            isOnScreen: false,
            mutationIdentity: .init(
                windowID: 78, ownerProcessIdentifier: 42, ownerProcessStartIdentity: 9001, capturedBounds: bounds
            )
        )
    }()

    private static func identity(id: Int) -> WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: id, ownerProcessIdentifier: 42, ownerProcessStartIdentity: 9001, capturedBounds: self.bounds
        )
    }

    private static func window(id: Int, index: Int = 0, title: String = "Fixture") -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: id, title: title, bounds: self.bounds, index: index, mutationIdentity: self.identity(id: id)
        )
    }

    private static func service(_ windows: [ServiceWindowInfo]) -> ApplicationSelectionWindows {
        ApplicationSelectionWindows(windowsByIdentifier: ["Fixture": windows])
    }

    private static func focus(
        _ windows: ApplicationSelectionWindows,
        windowID: CGWindowID? = nil,
        windowTitle: String? = nil,
        preparedSelection: PreparedFocusSelection? = nil
    ) async throws -> UIAutomationActionResult<Void> {
        try await ensureFocused(
            windowID: windowID,
            applicationName: "Fixture",
            windowTitle: windowTitle,
            options: FocusOptions(
                autoFocus: true,
                focusTimeout: nil,
                focusRetryCount: nil,
                spaceSwitch: false,
                bringToCurrentSpace: false
            ),
            services: FocusProofPressServices(windows: windows, automation: MockAutomationService()),
            preparedSelection: preparedSelection
        )
    }

    private static func expectSelection(
        _ window: ServiceWindowInfo,
        result: UIAutomationActionResult<Void>,
        windows: ApplicationSelectionWindows
    ) throws {
        let identity = try #require(window.mutationIdentity)
        #expect(windows.pinnedIdentities == [identity])
        #expect(windows.focusRequests.isEmpty)
        #expect(result.targetIdentity?.exactWindow?.identity == identity)
        #expect(result.outcome?.route == .bridge)
    }
}

@MainActor
private final class ApplicationSelectionWindows: ScriptedWindowInventoryService,
WindowManagementPinnedFocusActionResultProviding {
    private(set) var pinnedIdentities: [WindowMutationIdentity] = []

    @MainActor
    func focusWindowActionResult(target: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        Issue.record("Remote focus must retain the selected window receipt")
        throw PeekabooError.commandFailed("Unexpected unpinned focus")
    }

    @MainActor
    func focusWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity
    ) async throws -> UIAutomationActionResult<Void> {
        #expect(target == .windowId(expectedIdentity.windowID))
        self.pinnedIdentities.append(expectedIdentity)
        let bounds = try #require(expectedIdentity.capturedBounds)
        return try UIAutomationActionResult(
            payload: (),
            outcome: .dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .composite, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one
            ),
            targetIdentity: DesktopTargetIdentity(
                exactWindow: UIAutomationTarget.ExactWindow(identity: expectedIdentity, bounds: bounds)
            )
        )
    }
}
