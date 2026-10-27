import AppKit
import Foundation
import PeekabooFoundation

@_spi(Testing) public protocol ApplicationResolving: Sendable {
    func findApplication(identifier: String) async throws -> ServiceApplicationInfo
    func frontmostApplication() async throws -> ServiceApplicationInfo
}

struct PeekabooApplicationResolver: ApplicationResolving {
    private let runningApplicationsProvider: ApplicationService.RunningApplicationsProvider
    private let processIdentifierResolver: ApplicationService.ApplicationProcessIdentifierResolver

    init(
        runningApplicationsProvider: @escaping ApplicationService.RunningApplicationsProvider = {
            NSWorkspace.shared.runningApplications
        },
        processIdentifierResolver: @escaping ApplicationService.ApplicationProcessIdentifierResolver =
            RunningApplicationProcessIdentity.resolve)
    {
        self.runningApplicationsProvider = runningApplicationsProvider
        self.processIdentifierResolver = processIdentifierResolver
    }

    @MainActor
    func frontmostApplication() async throws -> ServiceApplicationInfo {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            throw NotFoundError.application("frontmost")
        }
        guard let pid = self.processIdentifierResolver(frontmost), pid > 0 else {
            throw NotFoundError.application("frontmost")
        }
        return Self.applicationInfo(from: frontmost, processIdentifier: pid)
    }

    func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        let census = RunningApplicationSelectorCensus(
            applications: self.runningApplicationsProvider(),
            processIdentifierResolver: self.processIdentifierResolver)
        let selected = try census.resolve(identifier: identifier)
        let application = Self.applicationInfo(
            from: selected.application,
            processIdentifier: selected.processIdentifier)
        let proof = application.processIdentity.map {
            selected.resolution.proof(selectedProcessIdentity: $0)
        }
        return application.withSelectorResolutionProofs(proof.map { [$0] })
    }

    private static func applicationInfo(
        from app: NSRunningApplication,
        processIdentifier: pid_t) -> ServiceApplicationInfo
    {
        ServiceApplicationInfo(
            processIdentifier: processIdentifier,
            processStartIdentity: SystemIdentityResolver.processStartIdentity(processIdentifier),
            bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
            bundlePath: app.bundleURL?.path,
            executablePath: app.executableURL?.path,
            isActive: app.isActive,
            isHidden: app.isHidden,
            windowCount: 0,
            activationPolicy: ApplicationService.serviceActivationPolicy(from: app.activationPolicy))
    }
}
