import CoreGraphics
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct MutationAuthorityPlannerTests {
    @Test
    func `selector-only authority normalizes to its own receipt-bound identity`() async throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            applicationName: "Editor",
            windowID: 42)
        let script = MutationAuthorityCatalogScript(
            applications: [fixture.application],
            windowInventories: [.complete([fixture.window])])
        let planner = script.planner()
        let authority = try await planner.plan(
            selector: InteractionTargetSelector(applicationIdentifier: "Editor"))

        let plan = try planner.bind(authority: authority)

        #expect(plan.sourceIdentity == fixture.processTargetIdentity)
        #expect(plan.targetIdentity == fixture.processTargetIdentity)
        #expect(plan.authority == authority)
        #expect(plan.selectedWindow == nil)
    }

    @Test
    func `receipt-bound authority retains its source target and selected window`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(
            applicationName: "Editor",
            windowID: 42)
        let script = MutationAuthorityCatalogScript(
            applications: [fixture.desktopTarget.application],
            windowInventories: [.complete([fixture.desktopTarget.window])])
        let planner = script.planner()

        let plan = try await planner.bind(identity: fixture.targetIdentity)

        #expect(plan.sourceIdentity == fixture.desktopTarget.windowTargetIdentity)
        #expect(plan.targetIdentity == fixture.desktopTarget.windowTargetIdentity)
        #expect(plan.authority.window?.identity == fixture.desktopTarget.windowIdentity)
        #expect(plan.selectedWindow == fixture.desktopTarget.window)
    }

    @Test
    func `exact receipt rejects application-only live authority`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(
            applicationName: "Editor",
            windowID: 42)
        let script = MutationAuthorityCatalogScript(
            applications: [fixture.desktopTarget.application],
            windowInventories: [])
        let planner = script.planner()
        let applicationAuthority = try await planner.plan(
            selector: InteractionTargetSelector(applicationIdentifier: "Editor"))

        #expect(throws: DesktopTargetPlanningError.underScopedMutationAuthority(windowID: 42)) {
            _ = try planner.bind(identity: fixture.targetIdentity, authority: applicationAuthority)
        }
    }

    @Test
    func `malformed exact receipt rejects before live authority lookup`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let malformed = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: 101,
                ownerProcessStartIdentity: 7,
                capturedBounds: nil),
            bounds: bounds))
        let script = MutationAuthorityCatalogScript(
            applications: [],
            windowInventories: [])

        await #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try await script.planner().bind(identity: malformed)
        }
        #expect(script.applicationInventoryRequestCount == 0)
        #expect(script.exactApplicationRequests.isEmpty)
        #expect(script.windowInventoryTargets.isEmpty)
    }

    @Test
    func `direct binding cannot repair a malformed exact receipt from live authority`() async throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            applicationName: "Editor",
            windowID: 42)
        let script = MutationAuthorityCatalogScript(
            applications: [fixture.application],
            windowInventories: [.complete([fixture.window])])
        let planner = script.planner()
        let authority = try await planner.plan(
            selector: InteractionTargetSelector(windowID: fixture.window.windowID))
        let malformed = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: fixture.window.windowID,
                ownerProcessIdentifier: fixture.processIdentity.processIdentifier,
                ownerProcessStartIdentity: fixture.processIdentity.processStartIdentity,
                capturedBounds: nil),
            bounds: fixture.window.bounds))

        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try planner.bind(identity: malformed, authority: authority)
        }
    }

    @Test
    func `receipt binding rejects same window ID with substituted bounds`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(
            applicationName: "Editor",
            windowID: 42)
        let replacement = AutomationTestFixtures.window(
            copying: fixture.desktopTarget.window,
            bounds: CGRect(x: 40, y: 20, width: 640, height: 480))
        let script = MutationAuthorityCatalogScript(
            applications: [fixture.desktopTarget.application],
            windowInventories: [.complete([replacement])])

        await #expect(throws: DesktopTargetIdentityError.contradictoryWindowBounds) {
            _ = try await script.planner().bind(identity: fixture.targetIdentity)
        }
    }

    @Test
    func `receipt-bound revalidation retains the original source receipt`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(
            applicationName: "Editor",
            windowID: 42)
        let script = MutationAuthorityCatalogScript(
            applications: [fixture.desktopTarget.application],
            windowInventories: [
                .complete([fixture.desktopTarget.window]),
                .complete([fixture.desktopTarget.window]),
            ])
        let planner = script.planner()
        let plan = try await planner.bind(identity: fixture.targetIdentity)

        let current = try await planner.revalidate(plan)

        #expect(current.sourceIdentity == plan.sourceIdentity)
        #expect(current.targetIdentity == plan.targetIdentity)
        #expect(current.selectedWindow == fixture.desktopTarget.window)
    }

    @Test
    func `receipt-bound revalidation retains exact authority selected for a process receipt`() async throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            applicationName: "Editor",
            windowID: 42)
        let script = MutationAuthorityCatalogScript(
            applications: [fixture.application],
            windowInventories: [
                .complete([fixture.window]),
                .complete([fixture.window]),
            ])
        let planner = script.planner()
        let plan = try await planner.bind(
            identity: fixture.processTargetIdentity,
            requirement: .exactWindow(automaticSelection: .preferredMutationWindow(.general)))

        let current = try await planner.revalidate(plan)

        #expect(current.sourceIdentity == fixture.processTargetIdentity)
        #expect(current.targetIdentity == fixture.windowTargetIdentity)
        #expect(current.selectedWindow == fixture.window)
    }

    @Test(arguments: ["bounds", "generation", "window"])
    func `receipt-bound revalidation rejects exact drift after upgrading a process receipt`(
        drift: String) async throws
    {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            applicationName: "Editor",
            windowID: 42)
        let replacement = switch drift {
        case "bounds":
            AutomationTestFixtures.window(
                copying: fixture.window,
                bounds: CGRect(x: 40, y: 20, width: 640, height: 480))
        case "generation":
            AutomationTestFixtures.window(
                copying: fixture.window,
                processIdentity: ApplicationProcessIdentity(
                    processIdentifier: fixture.processIdentity.processIdentifier,
                    processStartIdentity: fixture.processIdentity.processStartIdentity + 1))
        case "window":
            AutomationTestFixtures.window(
                copying: fixture.window,
                windowID: fixture.window.windowID + 1)
        default:
            preconditionFailure("Unexpected drift fixture")
        }
        let script = MutationAuthorityCatalogScript(
            applications: [fixture.application],
            windowInventories: [
                .complete([fixture.window]),
                .complete([replacement]),
            ])
        let planner = script.planner()
        let plan = try await planner.bind(
            identity: fixture.processTargetIdentity,
            requirement: .exactWindow(automaticSelection: .preferredMutationWindow(.general)))

        await #expect(throws: DesktopTargetPlanningError.staleWindow(expected: fixture.windowIdentity)) {
            _ = try await planner.revalidate(plan)
        }
    }

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
        #expect(directScript.applicationInventoryRequestCount == 0)
        #expect(directScript.exactApplicationRequests == ["PID:101", "PID:101"])
    }

    @Test
    func `exact window owner ignores unrelated incomplete application rows`() async throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 2468, processStartIdentity: 7),
            applicationName: "Calculator",
            windowID: 42)
        let unpinnableSystemRow = AutomationTestFixtures.application(
            processIdentifier: 1,
            processStartIdentity: nil,
            bundleIdentifier: nil,
            name: "WindowServer",
            isHiddenKnown: false,
            activationPolicy: .prohibited)
        let warning = "Application PID 1 lacked process-generation identity and was omitted."
        let script = MutationAuthorityCatalogScript(
            applicationInventories: [
                .partial([fixture.application, unpinnableSystemRow], warnings: [warning]),
            ],
            windowInventories: [.complete([fixture.window])])

        let authority = try await script.planner().plan(selector: InteractionTargetSelector(
            applicationIdentifier: "Calculator",
            windowID: fixture.window.windowID))

        #expect(authority.window?.identity == fixture.windowIdentity)
        #expect(authority.application.processIdentity == fixture.processIdentity)
        #expect(authority.application.selectorProof.matchKind == .exactName)
        #expect(script.applicationInventoryRequestCount == 1)
        #expect(script.exactApplicationRequests == ["Calculator", "PID:2468"])
        #expect(script.windowInventoryTargets == [.windowId(fixture.window.windowID)])
    }

    @Test
    func `exact window owner still refuses known application ambiguity and selected row incompleteness`() async throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 2468, processStartIdentity: 7),
            applicationName: "Calculator",
            windowID: 42)
        let duplicate = AutomationTestFixtures.application(
            processIdentifier: 2469,
            processStartIdentity: 8,
            bundleIdentifier: "com.example.OtherCalculator",
            name: "Calculator")
        let ambiguous = MutationAuthorityCatalogScript(
            applicationInventories: [
                .partial([fixture.application, duplicate], warnings: ["unrelated row omitted"]),
            ],
            windowInventories: [.complete([fixture.window])])

        await #expect(throws: DesktopTargetPlanningError.ambiguousApplication(
            identifier: "Calculator",
            candidatePIDs: []))
        {
            _ = try await ambiguous.planner().plan(selector: InteractionTargetSelector(
                applicationIdentifier: "Calculator",
                windowID: fixture.window.windowID))
        }

        let incompleteApplication = AutomationTestFixtures.application(
            processIdentifier: fixture.processIdentity.processIdentifier,
            processStartIdentity: nil,
            bundleIdentifier: fixture.application.bundleIdentifier,
            name: fixture.application.name)
        let incomplete = MutationAuthorityCatalogScript(
            applicationInventories: [
                .partial([incompleteApplication], warnings: ["selected row was incomplete"]),
            ],
            windowInventories: [.complete([fixture.window])])

        await #expect(throws: DesktopTargetPlanningError.missingProcessIdentity(processIdentifier: 2468)) {
            _ = try await incomplete.planner().plan(selector: InteractionTargetSelector(
                applicationIdentifier: "Calculator",
                windowID: fixture.window.windowID))
        }
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
