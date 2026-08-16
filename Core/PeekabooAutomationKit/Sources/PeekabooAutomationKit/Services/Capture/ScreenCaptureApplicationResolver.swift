import AppKit
import Foundation
import PeekabooFoundation

@_spi(Testing) public protocol ApplicationResolving: Sendable {
    func findApplication(identifier: String) async throws -> ServiceApplicationInfo
    func frontmostApplication() async throws -> ServiceApplicationInfo
}

struct PeekabooApplicationResolver: ApplicationResolving {
    @MainActor
    func frontmostApplication() async throws -> ServiceApplicationInfo {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            throw NotFoundError.application("frontmost")
        }
        return Self.applicationInfo(from: frontmost)
    }

    func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        let runningApps = NSWorkspace.shared.runningApplications.filter { app in
            !app.isTerminated
        }
        let candidates = runningApps.map(Self.identifierCandidate)
        if let resolution = try ApplicationIdentifierMatcher.resolution(for: identifier, in: candidates) {
            guard !resolution.hasWinningTie else {
                throw PeekabooError.ambiguousAppIdentifier(
                    identifier,
                    suggestions: candidates.map(\.name))
            }
            let application = Self.applicationInfo(from: runningApps[resolution.index])
            let proof = application.processIdentity.map {
                resolution.proof(selectedProcessIdentity: $0)
            }
            return application.withSelectorResolutionProofs(proof.map { [$0] })
        }

        throw PeekabooError.appNotFound(identifier)
    }

    private static func identifierCandidate(_ app: NSRunningApplication) -> ApplicationIdentifierMatcher.Candidate {
        .init(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
            bundlePath: app.bundleURL?.path,
            executablePath: app.executableURL?.path,
            allowsFuzzyMatching: app.activationPolicy != .prohibited,
            isRegularApplication: app.activationPolicy == .regular)
    }

    private static func applicationInfo(from app: NSRunningApplication) -> ServiceApplicationInfo {
        ServiceApplicationInfo(
            processIdentifier: app.processIdentifier,
            processStartIdentity: SystemIdentityResolver.processStartIdentity(app.processIdentifier),
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
