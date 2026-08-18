import CoreGraphics
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct MutationAuthorityPlannerTests {
    @Test
    func `most-specific authority preserves application and exact-window scope`() async throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            applicationName: "Editor",
            windowID: 42)
        let script = MutationAuthorityCatalogScript(
            applications: [fixture.application],
            windowInventories: [.complete([fixture.window])])
        let planner = script.planner()

        let application = try await planner.plan(
            selector: InteractionTargetSelector(applicationIdentifier: "Editor"))
        let window = try await planner.plan(
            selector: InteractionTargetSelector(
                applicationIdentifier: "Editor",
                windowID: fixture.window.windowID))

        #expect(application.window == nil)
        #expect(try application.targetIdentity == fixture.processTargetIdentity)
        #expect(window.window?.identity == fixture.windowIdentity)
        #expect(try window.targetIdentity == fixture.windowTargetIdentity)
    }

    @Test
    func `exact-window authority resolves the preferred window from a complete catalog`() async throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            applicationName: "Editor",
            windowID: 42)
        let script = MutationAuthorityCatalogScript(
            applications: [fixture.application],
            windowInventories: [.complete([fixture.window])])

        let authority = try await script.planner().plan(
            selector: InteractionTargetSelector(applicationIdentifier: "Editor"),
            requirement: .exactWindow(automaticSelection: .preferredMutationWindow(.general)))

        #expect(authority.window?.identity == fixture.windowIdentity)
        #expect(try authority.targetIdentity == fixture.windowTargetIdentity)
    }

    @Test
    func `broad exact-window authority refuses a partial catalog while direct ID remains admissible`() async throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            applicationName: "Editor",
            windowID: 42)
        let warning = "AX enumeration timed out"
        let broadScript = MutationAuthorityCatalogScript(
            applications: [fixture.application],
            windowInventories: [.partial([fixture.window], warnings: [warning])])

        await #expect(throws: DesktopTargetPlanningError.incompleteWindowInventory(
            selector: "window title 'Test Window'",
            warnings: [warning]))
        {
            _ = try await broadScript.planner().plan(
                selector: InteractionTargetSelector(
                    applicationIdentifier: "Editor",
                    windowTitle: fixture.window.title),
                requirement: .exactWindow(automaticSelection: .preferredMutationWindow(.general)))
        }

        let directScript = MutationAuthorityCatalogScript(
            applications: [fixture.application],
            windowInventories: [.partial([fixture.window], warnings: [warning])])
        let direct = try await directScript.planner().plan(
            selector: InteractionTargetSelector(windowID: fixture.window.windowID),
            requirement: .exactWindow(automaticSelection: .preferredMutationWindow(.general)))

        #expect(direct.window?.identity == fixture.windowIdentity)
    }

    @Test
    func `authority revalidation rejects same-ID bounds drift`() async throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            applicationName: "Editor",
            windowID: 42)
        let replacement = AutomationTestFixtures.window(
            copying: fixture.window,
            bounds: CGRect(x: 40, y: 20, width: 640, height: 480))
        let script = MutationAuthorityCatalogScript(
            applications: [fixture.application],
            windowInventories: [
                .complete([fixture.window]),
                .complete([replacement]),
            ])
        let planner = script.planner()
        let authority = try await planner.plan(
            selector: InteractionTargetSelector(
                applicationIdentifier: "Editor",
                windowID: fixture.window.windowID),
            requirement: .exactWindow(automaticSelection: .preferredMutationWindow(.general)))

        await #expect(throws: DesktopTargetPlanningError.staleWindow(expected: fixture.windowIdentity)) {
            _ = try await planner.revalidate(authority)
        }
    }
}
