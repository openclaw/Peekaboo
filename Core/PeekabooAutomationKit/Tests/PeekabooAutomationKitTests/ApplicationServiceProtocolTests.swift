import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct ApplicationServiceProtocolTests {
    @Test
    func `hide request rejects a selector from another process`() {
        #expect(throws: PeekabooError.self) {
            _ = try ApplicationHideRequest(
                identifier: "PID:43",
                expectedIdentity: .init(processIdentifier: 42, processStartIdentity: 7))
        }
    }

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
    func `exact quit rejects missing canonical outcome`() {
        let identity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 7)

        do {
            try ApplicationActionResultSemantics.requireConsistentQuitResult(
                DesktopActionResult(payload: true, outcome: nil),
                expectedIdentity: identity,
                operation: "Quit application")
            Issue.record("Expected missing-outcome failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: nil))
            #expect(failure.targetReceipt == .init(
                processIdentifier: identity.processIdentifier,
                processStartIdentity: identity.processStartIdentity))
        } catch {
            Issue.record(error)
        }
    }

    @Test
    func `legacy bulk quit may retain a receiptless result`() throws {
        let identity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 7)

        try ApplicationActionResultSemantics.requireConsistentQuitResult(
            DesktopActionResult(payload: false, outcome: nil),
            expectedIdentity: identity,
            operation: "Bulk quit application",
            requiresCanonicalOutcome: false)
    }

    @Test
    func `exact quit rejects false payload with successful outcome`() {
        let identity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 7)
        let outcome = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one)

        do {
            try ApplicationActionResultSemantics.requireConsistentQuitResult(
                DesktopActionResult(payload: false, outcome: outcome),
                expectedIdentity: identity,
                operation: "Quit application")
            Issue.record("Expected contradictory false-payload failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == outcome.delivery)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
            #expect(failure.targetReceipt?.processStartIdentity == identity.processStartIdentity)
        } catch {
            Issue.record(error)
        }
    }

    @Test
    func `exact quit preserves false payload non-success outcome`() {
        let identity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 7)
        let outcome = DesktopActionOutcome.suspectedNoop(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one)

        do {
            try ApplicationActionResultSemantics.requireConsistentQuitResult(
                DesktopActionResult(payload: false, outcome: outcome),
                expectedIdentity: identity,
                operation: "Quit application")
            Issue.record("Expected canonical non-success failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == outcome)
            #expect(failure.targetReceipt?.processStartIdentity == identity.processStartIdentity)
        } catch {
            Issue.record(error)
        }
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
