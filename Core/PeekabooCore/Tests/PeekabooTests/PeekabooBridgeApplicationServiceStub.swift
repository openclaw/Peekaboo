import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
class StubApplicationService: ApplicationServiceProtocol, ApplicationServiceActionResultProviding,
    ApplicationServiceTargetedActionResultProviding
{
    let supportsApplicationLaunchOptions: Bool
    let supportsApplicationRelaunch: Bool
    var supportsProcessGenerationPinnedApplicationQuit: Bool {
        true
    }

    var supportsProcessGenerationPinnedApplicationActivation: Bool {
        true
    }

    var supportsProcessGenerationPinnedApplicationHide: Bool {
        true
    }

    var supportsSafeBackgroundApplicationLaunchNoOp: Bool {
        false
    }

    private(set) var relaunchRequests: [ApplicationRelaunchRequest] = []
    private(set) var quitRequests: [ApplicationQuitRequest] = []
    private(set) var activationRequests: [ApplicationActivationRequest] = []
    private(set) var targetedActivationResultCount = 0
    private(set) var hideResultCount = 0
    private(set) var targetedHideResultCount = 0
    private(set) var targetedHideRequests: [ApplicationHideRequest] = []
    var actionOutcome: DesktopActionOutcome? = .confirmedChange(
        delivery: .init(mechanism: .nativeFramework, mode: .background),
        unitCount: .one)
    var quitResultError: (any Error)?
    var quitResultPayload = true
    var targetedHideError: DesktopActionFailure?
    var relaunchResult: ServiceApplicationInfo?

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

    func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        self.app.withUniqueTestSelectorProof(for: identifier)
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
        if let relaunchResult {
            return relaunchResult
        }
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
        return self.quitResultPayload
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
        self.hideResultCount += 1
        try await self.hideApplication(identifier: identifier)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func unhideApplicationActionResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.unhideApplication(identifier: identifier)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func activateApplicationTargetedActionResult(
        request: ApplicationActivationRequest) async throws -> UIAutomationActionResult<Void>
    {
        self.targetedActivationResultCount += 1
        let result = try await self.activateApplicationActionResult(request: request)
        return try UIAutomationActionResult(
            payload: result.payload,
            outcome: result.outcome,
            targetIdentity: self.targetIdentity())
    }

    func hideApplicationTargetedActionResult(identifier: String) async throws -> UIAutomationActionResult<Void> {
        self.targetedHideResultCount += 1
        let result = try await self.hideApplicationActionResult(identifier: identifier)
        return try UIAutomationActionResult(
            payload: result.payload,
            outcome: result.outcome,
            targetIdentity: self.targetIdentity())
    }

    func hideApplicationTargetedActionResult(
        request: ApplicationHideRequest) async throws -> UIAutomationActionResult<Void>
    {
        self.targetedHideResultCount += 1
        self.targetedHideRequests.append(request)
        if let targetedHideError {
            throw targetedHideError
        }
        let result = try await self.hideApplicationActionResult(identifier: request.identifier)
        return try UIAutomationActionResult(
            payload: result.payload,
            outcome: result.outcome,
            targetIdentity: DesktopTargetIdentity(processIdentity: request.expectedIdentity))
    }

    func hideOtherApplicationsActionResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.hideOtherApplications(identifier: identifier)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func showAllApplicationsActionResult() async throws -> DesktopActionResult<Void> {
        try await self.showAllApplications()
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    private func targetIdentity() throws -> DesktopTargetIdentity {
        guard let processIdentity = self.app.processIdentity else {
            throw PeekabooError.commandFailed("Stub application has no process-generation identity")
        }
        return try DesktopTargetIdentity(processIdentity: processIdentity)
    }
}

extension ServiceApplicationInfo {
    func withUniqueTestSelectorProof(for identifier: String) -> ServiceApplicationInfo {
        guard let processIdentity = self.processIdentity,
              let matchKind = ApplicationIdentifierMatcher.matchKind(
                  for: .init(self),
                  identifier: identifier)
        else { return self }
        return self.withSelectorResolutionProofs([SelectorResolutionProof(
            scope: .application,
            normalizedSelector: ApplicationIdentifierMatcher.normalized(identifier),
            matchKind: matchKind,
            matchPrecedence: matchKind.precedence,
            selectedProcessIdentity: processIdentity,
            candidateSetSHA256: String(repeating: "a", count: 64),
            candidateCount: 1,
            winningCandidateCount: 1,
            hasWinningTie: false)])
    }
}
