import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct ApplicationServiceProtocolTests {
    @Test
    func `safe background launch shape excludes every dispatching option`() {
        #expect(ApplicationLaunchRequest(applicationIdentifier: "Fixture").isSafeBackgroundNoOp)
        #expect(ApplicationLaunchRequest(
            applicationIdentifier: "Fixture",
            waitUntilReady: true,
            waitForWindow: true).isSafeBackgroundNoOp)
        #expect(!ApplicationLaunchRequest(
            applicationIdentifier: "Fixture",
            activates: true).isSafeBackgroundNoOp)
        #expect(!ApplicationLaunchRequest(
            applicationIdentifier: "Fixture",
            openURLs: [URL(fileURLWithPath: "/tmp/fixture")]).isSafeBackgroundNoOp)
        #expect(!ApplicationLaunchRequest(
            applicationIdentifier: "Fixture",
            createsNewInstance: true).isSafeBackgroundNoOp)
    }

    @Test
    @MainActor
    func `result adapters dispatch explicit capability witnesses`() async throws {
        let provider = ApplicationActionResultProbe()
        let service: any ApplicationServiceProtocol = provider
        let outcomes = try await self.invokeResultAdapters(on: service)

        #expect(outcomes == Array(repeating: provider.outcome, count: ApplicationAdapterOperation.allCases.count))
        #expect(provider.providerCalls == ApplicationAdapterOperation.allCases)
        #expect(provider.legacyCalls.isEmpty)
    }

    @Test
    @MainActor
    func `result adapters fall back to legacy application requirements without claiming outcomes`() async throws {
        let legacy = LegacyApplicationResultProbe()
        let service: any ApplicationServiceProtocol = legacy
        let outcomes = try await self.invokeResultAdapters(on: service)

        #expect(outcomes == Array(repeating: nil, count: ApplicationAdapterOperation.allCases.count))
        #expect(legacy.legacyCalls == ApplicationAdapterOperation.allCases)
        #expect((service as? any ApplicationServiceActionResultProviding) == nil)
    }

    @MainActor
    private func invokeResultAdapters(
        on service: any ApplicationServiceProtocol) async throws -> [DesktopActionOutcome?]
    {
        let launchRequest = ApplicationLaunchRequest(applicationIdentifier: "Fixture")
        let relaunchRequest = ApplicationRelaunchRequest(
            targetIdentifier: "Fixture",
            launchRequest: launchRequest)
        return try await [
            service.launchApplicationResult(request: launchRequest).outcome,
            service.relaunchApplicationResult(request: relaunchRequest).outcome,
            service.activateApplicationResult(
                request: ApplicationActivationRequest(identifier: "Fixture")).outcome,
            service.quitApplicationResult(
                request: ApplicationQuitRequest(identifier: "Fixture")).outcome,
            service.hideApplicationResult(identifier: "Fixture").outcome,
            service.unhideApplicationResult(identifier: "Fixture").outcome,
        ]
    }
}

private enum ApplicationAdapterOperation: CaseIterable, Sendable {
    case launch
    case relaunch
    case activate
    case quit
    case hide
    case unhide
}

@MainActor
private class LegacyApplicationResultProbe: ApplicationServiceProtocol {
    let application = ServiceApplicationInfo(
        processIdentifier: 42,
        processStartIdentity: 7,
        bundleIdentifier: "dev.peekaboo.fixture",
        name: "Fixture")
    private(set) var legacyCalls: [ApplicationAdapterOperation] = []

    func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        UnifiedToolOutput(
            data: ServiceApplicationListData(applications: [self.application]),
            summary: .init(brief: "1 app", status: .success, counts: ["applications": 1]),
            metadata: .init(duration: 0))
    }

    func findApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        self.application
    }

    func listWindows(for _: String, timeout _: Float?) async throws -> UnifiedToolOutput<ServiceWindowListData> {
        UnifiedToolOutput(
            data: ServiceWindowListData(windows: [], targetApplication: self.application),
            summary: .init(brief: "0 windows", status: .success, counts: [:]),
            metadata: .init(duration: 0))
    }

    func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        self.application
    }

    func isApplicationRunning(identifier _: String) async throws -> Bool {
        true
    }

    func launchApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        self.legacyCalls.append(.launch)
        return self.application
    }

    func launchApplication(request _: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo {
        self.legacyCalls.append(.launch)
        return self.application
    }

    func relaunchApplication(request _: ApplicationRelaunchRequest) async throws -> ServiceApplicationInfo {
        self.legacyCalls.append(.relaunch)
        return self.application
    }

    func activateApplication(identifier _: String) async throws {
        self.legacyCalls.append(.activate)
    }

    func activateApplication(request _: ApplicationActivationRequest) async throws {
        self.legacyCalls.append(.activate)
    }

    func quitApplication(identifier _: String, force _: Bool) async throws -> Bool {
        self.legacyCalls.append(.quit)
        return true
    }

    func quitApplication(request _: ApplicationQuitRequest) async throws -> Bool {
        self.legacyCalls.append(.quit)
        return true
    }

    func hideApplication(identifier _: String) async throws {
        self.legacyCalls.append(.hide)
    }

    func unhideApplication(identifier _: String) async throws {
        self.legacyCalls.append(.unhide)
    }

    func hideOtherApplications(identifier _: String) async throws {}
    func showAllApplications() async throws {}
}

@MainActor
private final class ApplicationActionResultProbe: LegacyApplicationResultProbe,
    ApplicationServiceActionResultProviding
{
    let outcome = DesktopActionOutcome.confirmedChange(
        delivery: .init(mechanism: .nativeFramework, mode: .background),
        unitCount: .one)
    private(set) var providerCalls: [ApplicationAdapterOperation] = []

    func launchApplicationActionResult(
        request _: ApplicationLaunchRequest) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        self.providerCalls.append(.launch)
        return DesktopActionResult(payload: self.application, outcome: self.outcome)
    }

    func relaunchApplicationActionResult(
        request _: ApplicationRelaunchRequest) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        self.providerCalls.append(.relaunch)
        return DesktopActionResult(payload: self.application, outcome: self.outcome)
    }

    func activateApplicationActionResult(
        request _: ApplicationActivationRequest) async throws -> DesktopActionResult<Void>
    {
        self.providerCalls.append(.activate)
        return DesktopActionResult(outcome: self.outcome)
    }

    func quitApplicationActionResult(
        request _: ApplicationQuitRequest) async throws -> DesktopActionResult<Bool>
    {
        self.providerCalls.append(.quit)
        return DesktopActionResult(payload: true, outcome: self.outcome)
    }

    func hideApplicationActionResult(identifier _: String) async throws -> DesktopActionResult<Void> {
        self.providerCalls.append(.hide)
        return DesktopActionResult(outcome: self.outcome)
    }

    func unhideApplicationActionResult(identifier _: String) async throws -> DesktopActionResult<Void> {
        self.providerCalls.append(.unhide)
        return DesktopActionResult(outcome: self.outcome)
    }
}
