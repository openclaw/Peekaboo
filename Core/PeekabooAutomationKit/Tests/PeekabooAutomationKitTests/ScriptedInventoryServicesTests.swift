import CoreGraphics
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct ScriptedInventoryServicesTests {
    @Test
    func `graph links missing receipts and normalizes application window metadata`() throws {
        let process = AutomationTestFixtures.processIdentity(
            processIdentifier: 42,
            processStartIdentity: 1001)
        let application = AutomationTestFixtures.application(
            processIdentifier: process.processIdentifier,
            processStartIdentity: process.processStartIdentity,
            bundleIdentifier: "com.example.Linked",
            name: "Linked App")
        let first = AutomationTestFixtures.window(
            windowID: 71,
            title: "First",
            processIdentity: process,
            includesMutationIdentity: false)
        let second = AutomationTestFixtures.window(
            windowID: 72,
            title: "Second",
            processIdentity: process,
            includesMutationIdentity: false,
            index: 1)

        let graph = try LinkedApplicationInventoryGraph(nodes: [
            .init(application: application, windows: [first, second]),
        ])
        let linkedApplication = try #require(graph.applications.first)
        let linkedWindows = try #require(graph.windowsByIdentifier["PID:42"])

        #expect(linkedApplication.windowCount == 2)
        #expect(linkedApplication.windowIDs == [71, 72])
        #expect(linkedWindows.map(\.mutationIdentity?.processIdentity) == [process, process])
        #expect(linkedWindows.map(\.mutationIdentity?.windowID) == [71, 72])
        #expect(graph.windowsByIdentifier["42"] == linkedWindows)
        #expect(graph.windowsByIdentifier["Linked App"] == linkedWindows)
        #expect(graph.windowsByIdentifier["com.example.Linked"] == linkedWindows)
    }

    @Test
    func `graph rejects explicit contradictory process and window evidence`() throws {
        let application = AutomationTestFixtures.application(windowIDs: [999])
        let window = AutomationTestFixtures.window(includesMutationIdentity: false)
        #expect(throws: LinkedApplicationInventoryGraphError.contradictoryApplicationWindowIDs(
            processIdentifier: application.processIdentifier))
        {
            _ = try LinkedApplicationInventoryGraph(nodes: [
                .init(application: application, windows: [window]),
            ])
        }

        let wrongOwner = AutomationTestFixtures.processIdentity(
            processIdentifier: 202,
            processStartIdentity: 2002)
        let wrongWindow = AutomationTestFixtures.window(processIdentity: wrongOwner)
        #expect(throws: LinkedApplicationInventoryGraphError.contradictoryWindowReceipt(
            windowID: wrongWindow.windowID))
        {
            _ = try LinkedApplicationInventoryGraph(nodes: [
                .init(application: AutomationTestFixtures.application(), windows: [wrongWindow]),
            ])
        }
    }

    @Test
    func `graph rejects aliases shared by distinct process generations`() throws {
        let firstProcess = AutomationTestFixtures.processIdentity()
        let secondProcess = AutomationTestFixtures.processIdentity(
            processIdentifier: 202,
            processStartIdentity: 2002)
        let firstApplication = AutomationTestFixtures.application(name: "Shared App")
        let secondApplication = AutomationTestFixtures.application(
            processIdentifier: secondProcess.processIdentifier,
            processStartIdentity: secondProcess.processStartIdentity,
            bundleIdentifier: "com.example.Second",
            name: "Shared App")
        let firstWindow = AutomationTestFixtures.window(processIdentity: firstProcess)
        let secondWindow = AutomationTestFixtures.window(
            windowID: 202,
            processIdentity: secondProcess)

        #expect(throws: LinkedApplicationInventoryGraphError.ambiguousApplicationIdentifier("Shared App")) {
            _ = try LinkedApplicationInventoryGraph(nodes: [
                .init(application: firstApplication, windows: [firstWindow]),
                .init(application: secondApplication, windows: [secondWindow]),
            ])
        }

        let pidAliasApplication = AutomationTestFixtures.application(
            processIdentifier: secondProcess.processIdentifier,
            processStartIdentity: secondProcess.processStartIdentity,
            bundleIdentifier: "com.example.PIDAlias",
            name: "pid:\(firstProcess.processIdentifier)")
        #expect(throws: LinkedApplicationInventoryGraphError.ambiguousApplicationIdentifier("pid:101")) {
            _ = try LinkedApplicationInventoryGraph(nodes: [
                .init(application: firstApplication, windows: [firstWindow]),
                .init(application: pidAliasApplication, windows: [secondWindow]),
            ])
        }
    }

    @Test
    func `graph groups linked windows for one process and rejects contradictory app metadata`() throws {
        let process = AutomationTestFixtures.processIdentity()
        let first = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: process,
            windowID: 201,
            windowTitle: "First")
        let second = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: process,
            windowID: 202,
            windowTitle: "Second",
            windowIndex: 1)

        let graph = try LinkedApplicationInventoryGraph(linkedTargets: [first, second])
        #expect(graph.nodes.count == 1)
        #expect(graph.applications.first?.windowIDs == [201, 202])
        #expect(graph.nodes.first?.windows.map(\.windowID) == [201, 202])

        let contradictory = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: process,
            applicationName: "Different App",
            windowID: 203)
        #expect(throws: LinkedApplicationInventoryGraphError.contradictoryApplicationMetadata(
            processIdentifier: process.processIdentifier))
        {
            _ = try LinkedApplicationInventoryGraph(linkedTargets: [first, contradictory])
        }
    }

    @Test
    func `application inventories sequence then saturate while dynamic inventory remains mutable`() async throws {
        let first = AutomationTestFixtures.application(name: "First")
        let second = AutomationTestFixtures.application(
            processIdentifier: 202,
            processStartIdentity: 2002,
            bundleIdentifier: "com.example.Second",
            name: "Second")
        let service = ScriptedApplicationInventoryService(
            applications: [first],
            applicationInventorySequence: [
                .complete([first]),
                .partial([second], warnings: ["bounded lookup timed out"]),
            ])

        #expect(try await service.applicationMutationInventory() == .complete([first]))
        let partial = try await service.applicationMutationInventory()
        #expect(partial == .partial([second], warnings: ["bounded lookup timed out"]))
        #expect(try await service.applicationMutationInventory() == partial)
        #expect(service.applicationMutationInventoryCallCount == 3)

        service.applicationInventorySequence = []
        service.replaceApplicationsForTesting([second])
        #expect(try await service.applicationMutationInventory() == .complete([second]))

        let warned = ServiceApplicationInfo(
            processIdentifier: 303,
            bundleIdentifier: nil,
            name: "Warned",
            metadataWarnings: ["metadata timed out"])
        let warningsSuppressed = ScriptedApplicationInventoryService(
            applications: [warned],
            propagatesApplicationMetadataWarnings: false)
        #expect(try await warningsSuppressed.applicationMutationInventory() == .complete([warned]))
        #expect(try await warningsSuppressed.listApplications().summary.status == .success)
    }

    @Test
    func `application service covers common reads and records lifecycle requests`() async throws {
        let graph = try AutomationTestFixtures.linkedApplicationInventoryGraph()
        let service = ScriptedApplicationInventoryService(graph: graph)
        let application = try #require(graph.applications.first)
        let identity = try #require(application.processIdentity)

        #expect(try await service.listApplications().data.applications == [application])
        #expect(try await service.findApplication(identifier: "PID:101") == application)
        #expect(try await service.findApplication(identifier: "  pid:101  ") == application)
        #expect(try await service.findApplication(identifier: "com.example.TestApp") == application)
        #expect(try await service.listWindows(for: "Test App", timeout: 0.5).data.windows.count == 1)
        #expect(try await service.getFrontmostApplication() == application)
        #expect(try await service.isApplicationRunning(identifier: "101"))

        try await service.activateApplication(request: ApplicationActivationRequest(
            identifier: "PID:101",
            expectedIdentity: identity))
        let launch = ApplicationLaunchRequest(
            applicationBundleIdentifier: "com.example.Launched",
            activates: false)
        _ = try await service.launchApplication(request: launch)
        let relaunch = ApplicationRelaunchRequest(
            targetIdentifier: "PID:101",
            expectedTargetIdentity: identity,
            launchRequest: launch)
        _ = try await service.relaunchApplication(request: relaunch)

        #expect(service.listApplicationsCallCount == 1)
        #expect(service.findApplicationRequests == [
            "PID:101",
            "  pid:101  ",
            "com.example.TestApp",
            "PID:101",
        ])
        #expect(service.listWindowsRequests.count == 1)
        #expect(service.frontmostApplicationCallCount == 1)
        #expect(service.runningApplicationRequests == ["101"])
        #expect(service.recordedActivationRequests.count == 1)
        #expect(service.launchRequests == [launch, launch])
        #expect(service.relaunchRequests == [relaunch])

        service.replaceApplicationsForTesting([AutomationTestFixtures.wrongGenerationApplication()])
        await #expect(throws: PeekabooError.self) {
            try await service.relaunchApplication(request: relaunch)
        }
        #expect(service.launchRequests == [launch, launch])

        let unsupportedPinning = ScriptedApplicationInventoryService(applications: [application])
        await #expect(throws: PeekabooError.self) {
            try await unsupportedPinning.quitApplication(request: ApplicationQuitRequest(
                identifier: "PID:101",
                force: false,
                expectedIdentity: identity))
        }
    }

    @Test
    func `window inventories saturate independently per target and list protocol filters`() async throws {
        let graph = try AutomationTestFixtures.linkedApplicationInventoryGraph()
        let window = try #require(graph.nodes.first?.windows.first)
        let renamed = AutomationTestFixtures.window(copying: window, title: "Renamed")
        let appTarget = WindowTarget.application("Test App")
        let idTarget = WindowTarget.windowId(window.windowID)
        let service = ScriptedWindowInventoryService(
            graph: graph,
            focusedWindow: window,
            inventorySequencesByTarget: [
                appTarget: [
                    .complete([window]),
                    .partial([renamed], warnings: ["AX timed out"]),
                ],
                idTarget: [.complete([window])],
            ])

        #expect(try await service.listWindows(target: .applicationAndTitle(
            app: "Test App",
            title: "test")) == [window])
        #expect(try await service.listWindows(target: .title("WINDOW")) == [window])
        #expect(try await service.listWindows(target: .index(app: "Test App", index: 0)) == [window])
        #expect(try await service.getFocusedWindow() == window)

        #expect(try await service.windowMutationInventory(target: appTarget) == .complete([window]))
        let partial = try await service.windowMutationInventory(target: appTarget)
        #expect(partial == .partial([renamed], warnings: ["AX timed out"]))
        #expect(try await service.windowMutationInventory(target: appTarget) == partial)
        #expect(try await service.windowMutationInventory(target: idTarget) == .complete([window]))
        #expect(try await service.windowMutationInventory(target: idTarget) == .complete([window]))

        #expect(service.listWindowRequests.count == 3)
        #expect(service.windowMutationInventoryRequests == [
            appTarget,
            appTarget,
            appTarget,
            idTarget,
            idTarget,
        ])
        #expect(service.focusedWindowCallCount == 1)
    }

    @Test
    func `application inventory service is subclassable from the importing test module`() async throws {
        let expected = AutomationTestFixtures.application(name: "Overridden")
        let service = OverridingApplicationInventoryService(expected: expected)

        #expect(try await service.findApplication(identifier: "anything") == expected)
        #expect(service.overrideRequests == ["anything"])
    }
}

@MainActor
private final class OverridingApplicationInventoryService: ScriptedApplicationInventoryService {
    let expected: ServiceApplicationInfo
    private(set) var overrideRequests: [String] = []

    init(expected: ServiceApplicationInfo) {
        self.expected = expected
        super.init()
    }

    override func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        self.overrideRequests.append(identifier)
        return self.expected
    }
}
