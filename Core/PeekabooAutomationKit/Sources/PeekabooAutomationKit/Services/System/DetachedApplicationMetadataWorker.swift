import AppKit
import Foundation
import PeekabooFoundation

struct DetachedApplicationMetadata: Sendable, Equatable {
    let bundleIdentifier: String?
    let name: String?
    let bundlePath: String?
    let isHidden: Bool
    let activationPolicy: ServiceApplicationActivationPolicy
    let isFinishedLaunching: Bool
}

struct DetachedApplicationMetadataRequest: Sendable {
    let processIdentifier: Int32
    let expectedProcessStartIdentity: UInt64?
}

enum DetachedApplicationMetadataCoordinator {
    static func run(
        processIdentifier: Int32,
        processStartIdentity: UInt64?,
        timeoutSeconds: TimeInterval,
        pool: DetachedApplicationMetadataPool = .shared,
        operation: @escaping @Sendable (DetachedApplicationMetadataRequest) throws
            -> DetachedApplicationMetadata = DetachedApplicationMetadataWorker.read) async throws
        -> DetachedApplicationMetadata
    {
        let request = DetachedApplicationMetadataRequest(
            processIdentifier: processIdentifier,
            expectedProcessStartIdentity: processStartIdentity)
        return try await pool.run(request: request, timeoutSeconds: timeoutSeconds, operation: operation)
    }
}

/// Reads LaunchServices metadata in the dedicated, generation-scoped metadata pool. `NSRunningApplication`
/// access is normally cheap, but a wedged or exiting process must not pin the Bridge MainActor or
/// prevent unrelated applications from appearing in inventory.
enum DetachedApplicationMetadataWorker {
    static func read(_ request: DetachedApplicationMetadataRequest) throws -> DetachedApplicationMetadata {
        try self.validateIdentity(request)
        guard let application = NSRunningApplication(processIdentifier: request.processIdentifier),
              !application.isTerminated
        else {
            throw PeekabooError.snapshotStale(
                "Application PID \(request.processIdentifier) terminated during inventory")
        }

        // Read classification first. If a later LaunchServices property stalls, callers must still
        // time out the whole descriptor rather than publish a mixture from different generations.
        let isHidden = application.isHidden
        let activationPolicy = ApplicationService.serviceActivationPolicy(from: application.activationPolicy)
        let name = application.localizedName
        let bundleIdentifier = application.bundleIdentifier
        let bundlePath = application.bundleURL?.path
        let isFinishedLaunching = application.isFinishedLaunching

        try self.validateIdentity(request)
        guard !application.isTerminated else {
            throw PeekabooError.snapshotStale(
                "Application PID \(request.processIdentifier) terminated during inventory")
        }
        return DetachedApplicationMetadata(
            bundleIdentifier: bundleIdentifier,
            name: name,
            bundlePath: bundlePath,
            isHidden: isHidden,
            activationPolicy: activationPolicy,
            isFinishedLaunching: isFinishedLaunching)
    }

    static func validateIdentity(
        _ request: DetachedApplicationMetadataRequest,
        processStartIdentityProvider: (pid_t) -> UInt64? = SystemIdentityResolver.processStartIdentity) throws
    {
        guard let expected = request.expectedProcessStartIdentity else { return }
        guard processStartIdentityProvider(request.processIdentifier) == expected else {
            throw PeekabooError.snapshotStale(
                "Application PID \(request.processIdentifier) changed process generation during inventory")
        }
    }
}
