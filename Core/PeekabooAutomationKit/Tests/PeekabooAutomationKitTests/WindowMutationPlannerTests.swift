import CoreGraphics
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct WindowMutationPlannerTests {
    @Test
    func `partial window inventory refuses title and index uniqueness`() async {
        let application = AutomationTestFixtures.application()
        let window = AutomationTestFixtures.window()
        let applications = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { .complete([application]) })
        let planner = DesktopTargetPlanning.WindowMutationPlanner(
            applicationPlanner: applications,
            windowInventoryProvider: { _ in
                .partial([window], warnings: ["AX enumeration timed out"])
            })

        await #expect(throws: DesktopTargetPlanningError.incompleteWindowInventory(
            selector: "window title 'Test Window'",
            warnings: ["AX enumeration timed out"]))
        {
            _ = try await planner.plan(selector: InteractionTargetSelector(
                applicationIdentifier: "Test App",
                windowTitle: "Test Window"))
        }
        await #expect(throws: DesktopTargetPlanningError.incompleteWindowInventory(
            selector: "window index 0",
            warnings: ["AX enumeration timed out"]))
        {
            _ = try await planner.plan(selector: InteractionTargetSelector(
                applicationIdentifier: "Test App",
                windowIndex: 0))
        }
    }

    @Test
    func `exact window ID can use a partial direct lookup`() async throws {
        let application = AutomationTestFixtures.application()
        let window = AutomationTestFixtures.window()
        let applications = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { .complete([application]) })
        let planner = DesktopTargetPlanning.WindowMutationPlanner(
            applicationPlanner: applications,
            windowInventoryProvider: { target in
                #expect(target == .windowId(window.windowID))
                return .partial([window], warnings: ["broad catalog unavailable"])
            })

        let plan = try await planner.plan(selector: InteractionTargetSelector(windowID: window.windowID))

        #expect(plan.identity == window.mutationIdentity)
    }

    @Test
    func `window provider transport failures stay unavailable instead of impersonating target loss`() async throws {
        let application = AutomationTestFixtures.application()
        let window = AutomationTestFixtures.window()
        let shouldFail = AutomationTestLockedValue(true)
        let applications = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { .complete([application]) })
        let planner = DesktopTargetPlanning.WindowMutationPlanner(
            applicationPlanner: applications,
            windowInventoryProvider: { _ in
                if shouldFail.value {
                    throw PeekabooError.timeout("raw window timeout")
                }
                return .complete([window])
            })

        await #expect(throws: DesktopTargetPlanningError.windowInventoryUnavailable(
            selector: "window ID 201"))
        {
            _ = try await planner.plan(selector: InteractionTargetSelector(windowID: 201))
        }

        shouldFail.value = false
        let plan = try await planner.plan(selector: InteractionTargetSelector(windowID: 201))
        shouldFail.value = true
        await #expect(throws: DesktopTargetPlanningError.windowInventoryUnavailable(selector: "window ID 201")) {
            _ = try await planner.revalidate(plan)
        }
    }

    @Test
    func `exact window absence becomes not found initially and stale after selection`() async throws {
        let application = AutomationTestFixtures.application()
        let window = AutomationTestFixtures.window()
        let isMissing = AutomationTestLockedValue(true)
        let applications = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { .complete([application]) })
        let planner = DesktopTargetPlanning.WindowMutationPlanner(
            applicationPlanner: applications,
            windowInventoryProvider: { _ in
                guard !isMissing.value else { throw PeekabooError.windowNotFound(criteria: "fixture") }
                return .complete([window])
            })

        await #expect(throws: DesktopTargetPlanningError.windowNotFound(
            selector: "window ID 201",
            candidateWindowIDs: []))
        {
            _ = try await planner.plan(selector: InteractionTargetSelector(windowID: 201))
        }

        isMissing.value = false
        let plan = try await planner.plan(selector: InteractionTargetSelector(windowID: 201))
        isMissing.value = true
        await #expect(throws: DesktopTargetPlanningError.staleWindow(expected: plan.identity)) {
            _ = try await planner.revalidate(plan)
        }
    }

    @Test
    func `raw broad window inventory errors become canonical unavailable errors`() async {
        let application = AutomationTestFixtures.application()
        let applications = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { .complete([application]) })
        let planner = DesktopTargetPlanning.WindowMutationPlanner(
            applicationPlanner: applications,
            windowInventoryProvider: { _ in throw PeekabooError.timeout("raw window timeout") })

        await #expect(throws: DesktopTargetPlanningError.windowInventoryUnavailable(
            selector: "application 'PID:101'"))
        {
            _ = try await planner.plan(selector: InteractionTargetSelector(
                applicationIdentifier: "Test App",
                windowTitle: "Test Window"))
        }
    }

    @Test
    func `nonfinite unrelated candidate evidence becomes a canonical invalid inventory`() async {
        let application = AutomationTestFixtures.application()
        let selected = AutomationTestFixtures.window(title: "Target")
        let invalid = ServiceWindowInfo(
            windowID: 202,
            title: "Unrelated",
            bounds: CGRect(x: CGFloat.nan, y: 0, width: 640, height: 480))
        let spy = WindowPlannerInventorySpy(
            applicationInventories: [[application], [application]],
            windows: [.application("PID:101"): [selected, invalid]])

        await #expect(throws: DesktopTargetPlanningError.invalidWindowInventory(
            selector: "window title 'Target'",
            reason: "candidate evidence could not be encoded"))
        {
            _ = try await spy.planner().plan(selector: InteractionTargetSelector(
                applicationIdentifier: "Test App",
                windowTitle: "Target"))
        }
    }

    @Test
    func `relative selector lists only by canonical exact PID and returns exact target`() async throws {
        let application = AutomationTestFixtures.application()
        let window = AutomationTestFixtures.window()
        let spy = WindowPlannerInventorySpy(
            applicationInventories: [[application], [application]],
            windows: [.application("PID:101"): [window]])
        let planner = spy.planner()

        let plan = try await planner.plan(selector: InteractionTargetSelector(
            applicationIdentifier: "Test App",
            windowTitle: "Test Window"))

        #expect(plan.target == .windowId(201))
        #expect(plan.selectionWindow == window)
        #expect(plan.identity == window.mutationIdentity)
        #expect(plan.owner.selectorProof.matchKind == .exactName)
        let proof = try #require(plan.selectorProof)
        #expect(proof.scope == .window)
        #expect(proof.matchKind == .exactWindowTitle)
        #expect(proof.selectedWindowIdentity == window.mutationIdentity)
        #expect(!proof.hasWinningTie)
        #expect(spy.requestedWindowTargets == [.application("PID:101")])
        #expect(spy.mutationCallCount == 0)
    }

    @Test
    func `exact ID alone derives owner while a wrong explicit owner refuses`() async throws {
        let application = AutomationTestFixtures.application()
        let window = AutomationTestFixtures.window()
        let exactSpy = WindowPlannerInventorySpy(
            applicationInventories: [[application], [application]],
            windows: [.windowId(201): [window]])
        let exactPlan = try await exactSpy.planner().plan(
            selector: InteractionTargetSelector(windowID: 201))
        #expect(exactPlan.owner.processIdentity == application.processIdentity)

        let other = AutomationTestFixtures.application(
            processIdentifier: 202,
            processStartIdentity: 2002,
            bundleIdentifier: "com.example.Other",
            name: "Other")
        let wrongOwnerSpy = WindowPlannerInventorySpy(
            applicationInventories: [[other]],
            windows: [.windowId(201): [window]])
        await #expect(throws: try DesktopTargetPlanningError.windowOwnerMismatch(
            windowID: 201,
            expected: #require(other.processIdentity)))
        {
            _ = try await wrongOwnerSpy.planner().plan(selector: InteractionTargetSelector(
                applicationIdentifier: "Other",
                windowID: 201))
        }
    }

    @Test
    func `owner drift after window inventory refuses pre-dispatch`() async throws {
        let original = AutomationTestFixtures.application()
        let changed = AutomationTestFixtures.wrongGenerationApplication()
        let window = AutomationTestFixtures.window()
        let spy = WindowPlannerInventorySpy(
            applicationInventories: [[original], [changed]],
            windows: [.application("PID:101"): [window]])

        await #expect(throws: try DesktopTargetPlanningError.staleApplication(
            expected: #require(original.processIdentity)))
        {
            _ = try await spy.planner().plan(selector: InteractionTargetSelector(
                applicationIdentifier: "Test App",
                windowIndex: 0))
        }
        #expect(spy.mutationCallCount == 0)
    }

    @Test
    func `plan revalidation refuses moved bounds`() async throws {
        let application = AutomationTestFixtures.application()
        let original = AutomationTestFixtures.window()
        let moved = AutomationTestFixtures.window(
            bounds: original.bounds.offsetBy(dx: 1, dy: 0))
        let spy = WindowPlannerInventorySpy(
            applicationInventories: [[application], [application], [application]],
            windows: [.windowId(201): [original]])
        let planner = spy.planner()
        let plan = try await planner.plan(selector: InteractionTargetSelector(windowID: 201))
        spy.windows[.windowId(201)] = [moved]

        await #expect(throws: DesktopTargetPlanningError.staleWindow(expected: plan.identity)) {
            _ = try await planner.revalidate(plan)
        }
    }

    @Test
    func `revalidation reports a replacement owner as stale`() async throws {
        let application = AutomationTestFixtures.application()
        let original = AutomationTestFixtures.window()
        let replacementOwner = AutomationTestFixtures.processIdentity(
            processIdentifier: 202,
            processStartIdentity: 2002)
        let replacement = AutomationTestFixtures.window(processIdentity: replacementOwner)
        let spy = WindowPlannerInventorySpy(
            applicationInventories: [[application], [application]],
            windows: [.windowId(201): [original]])
        let planner = spy.planner()
        let plan = try await planner.plan(selector: InteractionTargetSelector(windowID: 201))
        spy.windows[.windowId(201)] = [replacement]

        await #expect(throws: DesktopTargetPlanningError.staleWindow(expected: plan.identity)) {
            _ = try await planner.revalidate(plan)
        }
    }

    @Test
    func `revalidation keeps historical selection evidence while refreshing exact execution state`() async throws {
        let application = AutomationTestFixtures.application()
        let original = AutomationTestFixtures.window(title: "Selected Document", isMinimized: false)
        let refreshed = AutomationTestFixtures.window(title: "Renamed Document", isMinimized: true)
        let sibling = AutomationTestFixtures.window(windowID: 202, title: "Selected Document", index: 0)
        let spy = WindowPlannerInventorySpy(
            applicationInventories: [[application], [application], [application]],
            windows: [.application("PID:101"): [original]])
        let planner = spy.planner()
        let plan = try await planner.plan(selector: InteractionTargetSelector(
            applicationIdentifier: "Test App",
            windowTitle: "Selected Document"))
        spy.windows[.application("PID:101")] = [sibling, original]
        spy.windows[.windowId(201)] = [refreshed]
        spy.partialWindowTargets = [.windowId(201)]

        let revalidated = try await planner.revalidate(plan)

        #expect(revalidated.selectionWindow == original)
        #expect(revalidated.selectorProof == plan.selectorProof)
        #expect(revalidated.identity.hasSameStableReceipt(as: plan.identity))
        #expect(revalidated.identity.isMinimized == true)
        #expect(spy.requestedWindowTargets == [.application("PID:101"), .windowId(201)])
    }

    @Test
    func `ownerless relative mutation selector refuses before inventory`() async {
        let spy = WindowPlannerInventorySpy(applicationInventories: [], windows: [:])

        await #expect(throws: DesktopTargetPlanningError.invalidSelector(.windowSelectorRequiresApplication)) {
            _ = try await spy.planner().plan(
                selector: InteractionTargetSelector(windowTitle: "Document"))
        }
        #expect(spy.applicationReadCount == 0)
        #expect(spy.requestedWindowTargets.isEmpty)
    }
}

@MainActor
private final class WindowPlannerInventorySpy {
    private var applicationInventories: [[ServiceApplicationInfo]]
    var windows: [WindowTarget: [ServiceWindowInfo]]
    var partialWindowTargets = Set<WindowTarget>()
    private(set) var applicationReadCount = 0
    private(set) var requestedWindowTargets: [WindowTarget] = []
    private(set) var mutationCallCount = 0

    init(
        applicationInventories: [[ServiceApplicationInfo]],
        windows: [WindowTarget: [ServiceWindowInfo]])
    {
        self.applicationInventories = applicationInventories
        self.windows = windows
    }

    func planner() -> DesktopTargetPlanning.WindowMutationPlanner {
        let applications = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { try .complete(self.nextApplications()) })
        return DesktopTargetPlanning.WindowMutationPlanner(
            applicationPlanner: applications,
            windowInventoryProvider: { target in
                self.requestedWindowTargets.append(target)
                let windows = self.windows[target] ?? []
                if self.partialWindowTargets.contains(target) {
                    return .partial(windows, warnings: ["Broad catalog became partial"])
                }
                return .complete(windows)
            })
    }

    func nextApplications() throws -> [ServiceApplicationInfo] {
        guard self.applicationReadCount < self.applicationInventories.count else {
            throw PeekabooError.commandFailed("Unexpected application inventory read")
        }
        defer { self.applicationReadCount += 1 }
        return self.applicationInventories[self.applicationReadCount]
    }
}
