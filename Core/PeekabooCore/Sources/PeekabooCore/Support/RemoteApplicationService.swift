import CoreGraphics
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

@MainActor
public final class RemoteApplicationService: ApplicationServiceProtocol,
    ApplicationMutationInventoryProviding,
    ApplicationServiceActionResultProviding,
    ApplicationServiceTargetedActionResultProviding
{
    private let client: PeekabooBridgeClient
    private let localFallback: (any ApplicationServiceProtocol)?
    private let supportsLaunchOptions: Bool
    private let supportsSafeBackgroundLaunchNoOp: Bool
    private let supportsNewInstanceLaunch: Bool
    private let supportsWindowReadiness: Bool
    private let supportsRelaunch: Bool
    private let supportsPinnedQuit: Bool
    private let supportsPinnedActivation: Bool
    private let supportsPinnedHide: Bool

    public var supportsApplicationLaunchOptions: Bool {
        self.supportsLaunchOptions
    }

    public var supportsSafeBackgroundApplicationLaunchNoOp: Bool {
        self.supportsSafeBackgroundLaunchNoOp
    }

    public var supportsApplicationRelaunch: Bool {
        self.supportsRelaunch
    }

    public var supportsNewApplicationInstanceLaunch: Bool {
        self.supportsNewInstanceLaunch
    }

    public var supportsApplicationWindowReadiness: Bool {
        self.supportsWindowReadiness
    }

    public var supportsProcessGenerationPinnedApplicationQuit: Bool {
        self.supportsPinnedQuit
    }

    public var supportsProcessGenerationPinnedApplicationActivation: Bool {
        self.supportsPinnedActivation
    }

    public var supportsProcessGenerationPinnedApplicationHide: Bool {
        self.supportsPinnedHide
    }

    public init(
        client: PeekabooBridgeClient,
        localFallback: (any ApplicationServiceProtocol)? = nil,
        supportsLaunchOptions: Bool = false,
        supportsSafeBackgroundLaunchNoOp: Bool = false,
        supportsNewInstanceLaunch: Bool = false,
        supportsWindowReadiness: Bool = false,
        supportsRelaunch: Bool = false,
        supportsPinnedQuit: Bool = false,
        supportsPinnedActivation: Bool = false,
        supportsPinnedHide: Bool = false)
    {
        self.client = client
        self.localFallback = localFallback
        self.supportsLaunchOptions = supportsLaunchOptions
        self.supportsSafeBackgroundLaunchNoOp = supportsSafeBackgroundLaunchNoOp
        self.supportsNewInstanceLaunch = supportsNewInstanceLaunch
        self.supportsWindowReadiness = supportsWindowReadiness
        self.supportsRelaunch = supportsRelaunch
        self.supportsPinnedQuit = supportsPinnedQuit
        self.supportsPinnedActivation = supportsPinnedActivation
        self.supportsPinnedHide = supportsPinnedHide
    }

    public func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        let apps = try await self.client.listApplications()
        let warnings = apps.reduce(into: [String]()) { result, app in
            for warning in app.metadataWarnings ?? [] where !result.contains(warning) {
                result.append(warning)
            }
        }
        return UnifiedToolOutput(
            data: ServiceApplicationListData(applications: apps),
            summary: .init(
                brief: "Found \(apps.count) apps",
                status: warnings.isEmpty ? .success : .partial,
                counts: [
                    "applications": apps.count,
                    "incompleteApplications": apps.count(where: { !($0.metadataWarnings ?? []).isEmpty }),
                ]),
            metadata: .init(duration: 0, warnings: warnings))
    }

    public func applicationMutationInventory() async throws
        -> DesktopTargetPlanning.Inventory<ServiceApplicationInfo>
    {
        try await self.client.listApplicationMutationInventory()
    }

    public func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        try await self.client.findApplication(identifier: identifier)
    }

    public func listWindows(for appIdentifier: String, timeout: Float?) async throws
        -> UnifiedToolOutput<ServiceWindowListData>
    {
        // Reuse window listing filtered by application via WindowTarget.application
        let windows = try await self.client.listWindows(target: .application(appIdentifier))
        let data = ServiceWindowListData(windows: windows, targetApplication: nil)
        return UnifiedToolOutput(
            data: data,
            summary: .init(
                brief: "Found \(windows.count) windows",
                status: .success,
                counts: ["windows": windows.count]),
            metadata: .init(duration: 0))
    }

    public func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        try await self.client.getFrontmostApplication()
    }

    public func isApplicationRunning(identifier: String) async throws -> Bool {
        try await self.client.isApplicationRunning(identifier: identifier)
    }

    public func launchApplication(identifier: String) async throws -> ServiceApplicationInfo {
        try await self.client.launchApplication(identifier: identifier)
    }

    public func launchApplication(request: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo {
        try await self.launchApplicationResult(request: request).payload
    }

    public func launchApplicationActionResult(
        request: ApplicationLaunchRequest) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        try self.validateAdvancedLaunchOptions(request)
        if !request.activates, !self.supportsSafeBackgroundLaunchNoOp {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "The selected Peekaboo host cannot prove safe background launch semantics; " +
                    "update or relaunch it")
        }
        if self.supportsLaunchOptions {
            return try await self.client.launchApplicationResult(request: request)
        }

        if let identifier = request.applicationIdentifier,
           request.openURLs.isEmpty,
           request.activates,
           !request.waitUntilReady,
           !request.waitForWindow,
           !request.createsNewInstance
        {
            let application = try await self.client.launchApplication(identifier: identifier)
            return DesktopActionResult(payload: application, outcome: nil)
        }

        throw PeekabooBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "The selected Peekaboo host does not support background launch options; update or relaunch it")
    }

    public func relaunchApplication(request: ApplicationRelaunchRequest) async throws -> ServiceApplicationInfo {
        try await self.relaunchApplicationResult(request: request).payload
    }

    public func relaunchApplicationActionResult(
        request: ApplicationRelaunchRequest) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        guard self.supportsRelaunch else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "The selected Peekaboo host does not support atomic relaunch; update or relaunch it")
        }
        guard request.expectedTargetIdentity != nil else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Atomic remote relaunch requires the initially selected process-generation receipt")
        }
        try self.validateAdvancedLaunchOptions(request.launchRequest)
        return try await self.client.relaunchApplicationResult(request: request)
    }

    private func validateAdvancedLaunchOptions(_ request: ApplicationLaunchRequest) throws {
        if request.createsNewInstance, !self.supportsNewInstanceLaunch {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "The selected Peekaboo host does not support new-instance launch; update or relaunch it")
        }
        if request.waitForWindow, !self.supportsWindowReadiness {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "The selected Peekaboo host does not support window-ready launch; update or relaunch it")
        }
    }

    public func activateApplication(identifier: String) async throws {
        try await self.runWithLifecycleFallback {
            try await self.client.activateApplication(identifier: identifier)
        } fallback: { fallback in
            try await fallback.activateApplication(identifier: identifier)
        }
    }

    public func activateApplication(request: ApplicationActivationRequest) async throws {
        _ = try await self.activateApplicationResult(request: request)
    }

    public func activateApplicationActionResult(
        request: ApplicationActivationRequest) async throws -> DesktopActionResult<Void>
    {
        try await self.activateApplicationTargetedActionResult(request: request).desktopActionResult
    }

    public func activateApplicationTargetedActionResult(
        request: ApplicationActivationRequest) async throws -> UIAutomationActionResult<Void>
    {
        guard request.expectedIdentity == nil || self.supportsPinnedActivation else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "The selected Peekaboo host does not support process-generation-pinned activation")
        }
        return try await self.runWithLifecycleFallback {
            try await self.client.activateApplicationTargetedResult(request: request)
        } fallback: { fallback in
            try await fallback.activateApplicationTargetedResult(request: request)
        }
    }

    public func quitApplication(identifier: String, force: Bool) async throws -> Bool {
        try await self.client.quitApplication(
            identifier: identifier,
            force: force,
            supportsPinnedQuit: self.supportsPinnedQuit)
    }

    public func quitApplication(request: ApplicationQuitRequest) async throws -> Bool {
        try await self.quitApplicationResult(request: request).payload
    }

    public func quitApplicationActionResult(
        request: ApplicationQuitRequest) async throws -> DesktopActionResult<Bool>
    {
        guard self.supportsPinnedQuit else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Remote host lacks process-generation-pinned application quit; update the host")
        }
        guard request.expectedIdentity != nil else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Remote application quit requires a process-generation identity; resolve the app again")
        }
        return try await self.client.quitApplicationResult(request: request, supportsPinnedQuit: true)
    }

    public func hideApplication(identifier: String) async throws {
        _ = try await self.hideApplicationResult(identifier: identifier)
    }

    public func hideApplicationActionResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.hideApplicationTargetedActionResult(identifier: identifier).desktopActionResult
    }

    public func hideApplicationTargetedActionResult(
        identifier: String) async throws -> UIAutomationActionResult<Void>
    {
        try await self.runWithLifecycleFallback {
            try await self.client.hideApplicationTargetedResult(identifier: identifier)
        } fallback: { fallback in
            try await fallback.hideApplicationTargetedResult(identifier: identifier)
        }
    }

    public func hideApplicationTargetedActionResult(
        request: ApplicationHideRequest) async throws -> UIAutomationActionResult<Void>
    {
        guard self.supportsPinnedHide else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "The selected Peekaboo host does not support process-generation-pinned application hide")
        }
        return try await self.runWithLifecycleFallback {
            try await self.client.hideApplicationTargetedResult(request: request)
        } fallback: { fallback in
            try await fallback.hideApplicationTargetedResult(request: request)
        }
    }

    public func unhideApplication(identifier: String) async throws {
        _ = try await self.unhideApplicationResult(identifier: identifier)
    }

    public func unhideApplicationActionResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.runWithLifecycleFallback {
            try await self.client.unhideApplicationResult(identifier: identifier)
        } fallback: { fallback in
            try await fallback.unhideApplicationResult(identifier: identifier)
        }
    }

    public func hideOtherApplications(identifier: String) async throws {
        _ = try await self.hideOtherApplicationsActionResult(identifier: identifier)
    }

    public func hideOtherApplicationsActionResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.runWithLifecycleFallback {
            try await self.client.hideOtherApplicationsResult(identifier: identifier)
        } fallback: { fallback in
            try await fallback.hideOtherApplicationsResult(identifier: identifier)
        }
    }

    public func showAllApplications() async throws {
        _ = try await self.showAllApplicationsActionResult()
    }

    public func showAllApplicationsActionResult() async throws -> DesktopActionResult<Void> {
        try await self.runWithLifecycleFallback {
            try await self.client.showAllApplicationsResult()
        } fallback: { fallback in
            try await fallback.showAllApplicationsResult()
        }
    }

    private func runWithLifecycleFallback<Payload: Sendable>(
        operation: () async throws -> Payload,
        fallback: (any ApplicationServiceProtocol) async throws -> Payload) async throws -> Payload
    {
        do {
            return try await operation()
        } catch {
            guard let localFallback, Self.shouldUseLocalFallback(for: error) else {
                throw error
            }
            return try await fallback(localFallback)
        }
    }

    private static func shouldUseLocalFallback(for error: any Error) -> Bool {
        guard let envelope = error as? PeekabooBridgeErrorEnvelope else {
            return false
        }
        switch envelope.code {
        case .internalError:
            return !envelope.mayCompleteSnapshotWorkAfterFailure
        case .permissionDenied:
            return envelope.permission == .appleScript
        default:
            return false
        }
    }
}
