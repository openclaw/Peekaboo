import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
@testable import PeekabooAgentRuntime

@MainActor
func makeAuthorizedDesktopTargetPlan(
    targetIdentity: DesktopTargetIdentity,
    applicationName: String = "Fixture") async throws -> AuthorizedDesktopTargetPlan
{
    let processIdentity = targetIdentity.processIdentity
    let selectedWindow = targetIdentity.exactWindow.map { exactWindow in
        ServiceWindowInfo(
            windowID: exactWindow.identity.windowID,
            title: "Authorized Window",
            bounds: exactWindow.bounds,
            mutationIdentity: exactWindow.identity)
    }
    let application = AutomationTestFixtures.application(
        processIdentifier: processIdentity.processIdentifier,
        processStartIdentity: processIdentity.processStartIdentity,
        bundleIdentifier: "com.example.Authorized",
        name: applicationName,
        windowCount: selectedWindow == nil ? 0 : 1,
        windowIDs: selectedWindow.map { [$0.windowID] })
    let windowInventories: [DesktopTargetPlanning.Inventory<ServiceWindowInfo>] = selectedWindow.map {
        [.complete([$0])]
    } ?? []
    let planner = MutationAuthorityCatalogScript(
        applications: [application],
        windowInventories: windowInventories).planner()
    return try await AuthorizedDesktopTargetPlan(
        mutationAuthority: planner.bind(identity: targetIdentity))
}
