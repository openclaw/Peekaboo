import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
class StubApplicationService: ApplicationServiceProtocol, ApplicationServiceActionResultProviding {
    let supportsApplicationLaunchOptions: Bool
    let supportsApplicationRelaunch: Bool
    var supportsProcessGenerationPinnedApplicationQuit: Bool {
        true
    }

    var supportsProcessGenerationPinnedApplicationActivation: Bool {
        true
    }

    private(set) var relaunchRequests: [ApplicationRelaunchRequest] = []
    private(set) var quitRequests: [ApplicationQuitRequest] = []
    private(set) var activationRequests: [ApplicationActivationRequest] = []
    var actionOutcome: DesktopActionOutcome? = .confirmedChange(
        delivery: .init(mechanism: .nativeFramework, mode: .background),
        unitCount: .one)
    var quitResultError: (any Error)?

    private let app = ServiceApplicationInfo(
        processIdentifier: 123,
        processStartIdentity: 456,
        bundleIdentifier: "dev.stub",
        name: "StubApp",
        bundlePath: nil,
        isActive: true,
        isHidden: false,
        windowCount: 1)
    init(
        supportsApplicationLaunchOptions: Bool = true,
        supportsApplicationRelaunch: Bool = true)
    {
        self.supportsApplicationLaunchOptions = supportsApplicationLaunchOptions
        self.supportsApplicationRelaunch = supportsApplicationRelaunch
    }

    func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        UnifiedToolOutput(
            data: ServiceApplicationListData(applications: [self.app]),
            summary: .init(brief: "1 app", status: .success, counts: ["applications": 1]),
            metadata: .init(duration: 0))
    }

    func findApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        self.app
    }

    func listWindows(for _: String, timeout _: Float?) async throws -> UnifiedToolOutput<ServiceWindowListData> {
        UnifiedToolOutput(
            data: ServiceWindowListData(windows: [], targetApplication: self.app),
            summary: .init(brief: "0 windows", status: .success, counts: [:]),
            metadata: .init(duration: 0))
    }

    func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        self.app
    }

    func isApplicationRunning(identifier _: String) async -> Bool {
        true
    }

    func launchApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        self.app
    }

    func launchApplication(request: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo {
        try await self.launchApplication(identifier: request.applicationIdentifier ?? "StubApp")
    }

    func relaunchApplication(request: ApplicationRelaunchRequest) async throws -> ServiceApplicationInfo {
        self.relaunchRequests.append(request)
        return try await self.launchApplication(request: request.launchRequest)
    }

    func activateApplication(identifier _: String) async throws {}
    func activateApplication(request: ApplicationActivationRequest) async throws {
        self.activationRequests.append(request)
    }

    func quitApplication(identifier _: String, force _: Bool) async throws -> Bool {
        true
    }

    func quitApplication(request: ApplicationQuitRequest) async throws -> Bool {
        self.quitRequests.append(request)
        return true
    }

    func hideApplication(identifier _: String) async throws {}
    func unhideApplication(identifier _: String) async throws {}
    func hideOtherApplications(identifier _: String) async throws {}
    func showAllApplications() async throws {}

    func launchApplicationActionResult(
        request: ApplicationLaunchRequest) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        try await DesktopActionResult(payload: self.launchApplication(request: request), outcome: self.actionOutcome)
    }

    func relaunchApplicationActionResult(
        request: ApplicationRelaunchRequest) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        try await DesktopActionResult(payload: self.relaunchApplication(request: request), outcome: self.actionOutcome)
    }

    func activateApplicationActionResult(
        request: ApplicationActivationRequest) async throws -> DesktopActionResult<Void>
    {
        try await self.activateApplication(request: request)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func quitApplicationActionResult(
        request: ApplicationQuitRequest) async throws -> DesktopActionResult<Bool>
    {
        let payload = try await self.quitApplication(request: request)
        if let quitResultError {
            throw quitResultError
        }
        return DesktopActionResult(payload: payload, outcome: self.actionOutcome)
    }

    func hideApplicationActionResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.hideApplication(identifier: identifier)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func unhideApplicationActionResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.unhideApplication(identifier: identifier)
        return DesktopActionResult(outcome: self.actionOutcome)
    }
}
