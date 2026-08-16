import CoreGraphics
import Foundation
import PeekabooFoundation

public struct ApplicationLaunchRequest: Sendable, Codable, Equatable {
    public let applicationIdentifier: String?
    public let applicationBundleIdentifier: String?
    public let openURLs: [URL]
    public let activates: Bool
    public let waitUntilReady: Bool
    public let waitForWindow: Bool
    public let createsNewInstance: Bool

    public init(
        applicationIdentifier: String? = nil,
        applicationBundleIdentifier: String? = nil,
        openURLs: [URL] = [],
        activates: Bool = false,
        waitUntilReady: Bool = false,
        waitForWindow: Bool = false,
        createsNewInstance: Bool = false)
    {
        self.applicationIdentifier = applicationIdentifier
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.openURLs = openURLs
        self.activates = activates
        self.waitUntilReady = waitUntilReady
        self.waitForWindow = waitForWindow
        self.createsNewInstance = createsNewInstance
    }

    /// This request can only verify an existing process; it cannot dispatch a launch or target delivery.
    public var isSafeBackgroundNoOp: Bool {
        !self.activates && self.openURLs.isEmpty && !self.createsNewInstance
    }

    private enum CodingKeys: String, CodingKey {
        case applicationIdentifier
        case applicationBundleIdentifier
        case openURLs
        case activates
        case waitUntilReady
        case waitForWindow
        case createsNewInstance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.applicationIdentifier = try container.decodeIfPresent(String.self, forKey: .applicationIdentifier)
        self.applicationBundleIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .applicationBundleIdentifier)
        self.openURLs = try container.decode([URL].self, forKey: .openURLs)
        self.activates = try container.decode(Bool.self, forKey: .activates)
        self.waitUntilReady = try container.decode(Bool.self, forKey: .waitUntilReady)
        self.waitForWindow = try container.decodeIfPresent(Bool.self, forKey: .waitForWindow) ?? false
        self.createsNewInstance = try container.decodeIfPresent(Bool.self, forKey: .createsNewInstance) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.applicationIdentifier, forKey: .applicationIdentifier)
        try container.encodeIfPresent(self.applicationBundleIdentifier, forKey: .applicationBundleIdentifier)
        try container.encode(self.openURLs, forKey: .openURLs)
        try container.encode(self.activates, forKey: .activates)
        try container.encode(self.waitUntilReady, forKey: .waitUntilReady)
        try container.encode(self.waitForWindow, forKey: .waitForWindow)
        try container.encode(self.createsNewInstance, forKey: .createsNewInstance)
    }
}

public struct ApplicationRelaunchRequest: Sendable, Codable, Equatable {
    public let targetIdentifier: String
    public let expectedTargetIdentity: ApplicationProcessIdentity?
    public let launchRequest: ApplicationLaunchRequest
    public let force: Bool
    public let waitSeconds: TimeInterval

    public init(
        targetIdentifier: String,
        expectedTargetIdentity: ApplicationProcessIdentity? = nil,
        launchRequest: ApplicationLaunchRequest,
        force: Bool = false,
        waitSeconds: TimeInterval = 2)
    {
        self.targetIdentifier = targetIdentifier
        self.expectedTargetIdentity = expectedTargetIdentity
        self.launchRequest = launchRequest
        self.force = force
        self.waitSeconds = waitSeconds
    }
}

/// Pins an application mutation to one process generation.
///
/// PIDs are reusable. Destructive callers must retain this receipt from application discovery and
/// hosts must revalidate it immediately before dispatching the mutation.
public struct ApplicationProcessIdentity: Sendable, Codable, Equatable {
    public let processIdentifier: Int32
    public let processStartIdentity: UInt64

    public init(processIdentifier: Int32, processStartIdentity: UInt64) {
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
    }
}

public struct ApplicationQuitRequest: Sendable, Codable, Equatable {
    public let identifier: String
    public let force: Bool
    public let expectedIdentity: ApplicationProcessIdentity?

    public init(
        identifier: String,
        force: Bool = false,
        expectedIdentity: ApplicationProcessIdentity? = nil)
    {
        self.identifier = identifier
        self.force = force
        self.expectedIdentity = expectedIdentity
    }
}

public struct ApplicationActivationRequest: Sendable, Codable, Equatable {
    public let identifier: String
    public let expectedIdentity: ApplicationProcessIdentity?

    public init(
        identifier: String,
        expectedIdentity: ApplicationProcessIdentity? = nil)
    {
        self.identifier = identifier
        self.expectedIdentity = expectedIdentity
    }

    public init(application: ServiceApplicationInfo) throws {
        guard let processIdentity = application.processIdentity else {
            throw PeekabooError.serviceUnavailable(
                "Application discovery did not return a process-generation identity for exact activation")
        }
        self.init(
            identifier: "PID:\(application.processIdentifier)",
            expectedIdentity: processIdentity)
    }
}

/// Pins an application hide to the process generation selected by the caller.
public struct ApplicationHideRequest: Sendable, Codable, Equatable {
    public let identifier: String
    public let expectedIdentity: ApplicationProcessIdentity

    public init(identifier: String, expectedIdentity: ApplicationProcessIdentity) throws {
        guard identifier == "PID:\(expectedIdentity.processIdentifier)" else {
            throw PeekabooError.invalidInput(
                "Exact application hide identifier must match its process-generation identity")
        }
        self.identifier = identifier
        self.expectedIdentity = expectedIdentity
    }

    public init(application: ServiceApplicationInfo) throws {
        guard let processIdentity = application.processIdentity else {
            throw PeekabooError.serviceUnavailable(
                "Application discovery did not return a process-generation identity for exact hide")
        }
        try self.init(
            identifier: "PID:\(processIdentity.processIdentifier)",
            expectedIdentity: processIdentity)
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case expectedIdentity
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let identifier = try container.decode(String.self, forKey: .identifier)
        let expectedIdentity = try container.decode(ApplicationProcessIdentity.self, forKey: .expectedIdentity)
        do {
            try self.init(identifier: identifier, expectedIdentity: expectedIdentity)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .identifier,
                in: container,
                debugDescription: "Exact application hide identifier contradicts its process identity")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.identifier, forKey: .identifier)
        try container.encode(self.expectedIdentity, forKey: .expectedIdentity)
    }
}

/// Shared success policy for application lifecycle result consumers.
public enum ApplicationActionResultSemantics {
    public static func requireSuccessfulOutcome(
        _ outcome: DesktopActionOutcome?,
        operation: String) throws
    {
        guard let outcome else { return }
        guard !outcome.isAccepted(by: .confirmedOrDispatched) else { return }
        guard let failure = DesktopActionFailure(
            outcome: outcome,
            message: "\(operation) did not return a successful application outcome.",
            hint: "Follow the canonical escalation metadata before deciding whether to retry.")
        else { return }
        throw failure
    }

    public static func requireSuccessfulExactProcessResult(
        _ result: UIAutomationActionResult<some Sendable>,
        expectedIdentity: ApplicationProcessIdentity,
        operation: String) throws
    {
        guard let outcome = result.outcome else {
            throw DesktopActionFailure.indeterminate(
                evidence: .completionUnknown,
                message: "\(operation) returned without a canonical outcome.",
                hint: "Observe the selected application before retrying and update the runtime host.")
        }
        if outcome.state == .refused, outcome.dispatchState == .none {
            try self.requireSuccessfulOutcome(outcome, operation: operation)
        }
        if let returnedIdentity = result.targetIdentity?.processIdentity,
           returnedIdentity != expectedIdentity
        {
            throw DesktopActionFailure.indeterminate(
                route: outcome.route,
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "\(operation) returned a different process-generation target.",
                hint: "Observe the selected application before retrying and update the runtime host.")
        }
        do {
            try self.requireSuccessfulOutcome(outcome, operation: operation)
        } catch let failure as DesktopActionFailure {
            throw failure.attributed(to: expectedIdentity)
        }
        guard result.targetIdentity?.processIdentity == expectedIdentity else {
            throw DesktopActionFailure.indeterminate(
                route: outcome.route,
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "\(operation) returned without the exact process-generation target.",
                hint: "Observe the selected application before retrying and update the runtime host.")
        }
    }

    public static func requireConsistentQuitResult(
        _ result: DesktopActionResult<Bool>,
        expectedIdentity: ApplicationProcessIdentity,
        operation: String,
        requiresCanonicalOutcome: Bool = true,
        missingOutcomeRoute: DesktopActionOutcome.Route = .local) throws
    {
        guard let outcome = result.outcome else {
            guard requiresCanonicalOutcome else { return }
            throw DesktopActionFailure.indeterminate(
                route: missingOutcomeRoute,
                evidence: .completionUnknown,
                message: "\(operation) returned without a canonical outcome.",
                hint: "Observe the pinned application before retrying and update the runtime host.")
                .attributed(to: expectedIdentity)
        }
        if !result.payload, outcome.isAccepted(by: .confirmedOrDispatched) {
            throw DesktopActionFailure.indeterminate(
                route: outcome.route,
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "\(operation) returned false with a successful canonical outcome.",
                hint: "Observe the pinned application before retrying and update the runtime host.")
                .attributed(to: expectedIdentity)
        }
        do {
            try self.requireSuccessfulOutcome(outcome, operation: operation)
        } catch let failure as DesktopActionFailure {
            throw failure.attributed(to: expectedIdentity)
        }
    }
}

/// Protocol defining application and window management operations
@MainActor
public protocol ApplicationServiceProtocol: Sendable {
    /// Whether this service implements the full `ApplicationLaunchRequest` contract.
    var supportsApplicationLaunchOptions: Bool { get }

    /// Whether a non-activating launch is guaranteed to be an exact already-running read-only no-op.
    var supportsSafeBackgroundApplicationLaunchNoOp: Bool { get }

    /// Whether launch requests can require a distinct process even when the app is already running.
    var supportsNewApplicationInstanceLaunch: Bool { get }

    /// Whether launch requests can wait for a regular app to expose a real window.
    var supportsApplicationWindowReadiness: Bool { get }

    /// Whether this service keeps quit/wait/launch in one host-side transaction.
    var supportsApplicationRelaunch: Bool { get }

    /// Whether quit requests can be pinned to an exact process generation.
    var supportsProcessGenerationPinnedApplicationQuit: Bool { get }

    /// Whether activation requests can be pinned to an exact process generation.
    var supportsProcessGenerationPinnedApplicationActivation: Bool { get }

    /// Whether hide requests can be pinned to an exact caller-selected process generation.
    var supportsProcessGenerationPinnedApplicationHide: Bool { get }

    /// List all running applications
    /// - Returns: UnifiedToolOutput containing application information
    func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData>

    /// Find an application by name or bundle ID
    /// - Parameter identifier: Application name or bundle ID (supports fuzzy matching)
    /// - Returns: Application information if found
    func findApplication(identifier: String) async throws -> ServiceApplicationInfo

    /// List all windows for a specific application
    /// - Parameters:
    ///   - appIdentifier: Application name or bundle ID
    ///   - timeout: Optional timeout in seconds (defaults to 2 seconds)
    /// - Returns: UnifiedToolOutput containing window information
    func listWindows(for appIdentifier: String, timeout: Float?) async throws
        -> UnifiedToolOutput<ServiceWindowListData>

    /// Get information about the frontmost application
    /// - Returns: Application information
    func getFrontmostApplication() async throws -> ServiceApplicationInfo

    /// Check if an application is running
    /// - Parameter identifier: Application name or bundle ID
    /// - Returns: True if the application is running
    func isApplicationRunning(identifier: String) async throws -> Bool

    /// Launch an application
    /// - Parameter identifier: Application name or bundle ID
    /// - Returns: Application information after launch
    func launchApplication(identifier: String) async throws -> ServiceApplicationInfo

    /// Launch an application or open URLs using the runtime host's GUI session.
    func launchApplication(request: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo

    /// Quit, wait, and launch while keeping the runtime host alive for the entire transaction.
    func relaunchApplication(request: ApplicationRelaunchRequest) async throws -> ServiceApplicationInfo

    /// Activate (bring to front) an application
    /// - Parameter identifier: Application name or bundle ID
    func activateApplication(identifier: String) async throws

    /// Activate only while the selected process still matches its discovery receipt.
    func activateApplication(request: ApplicationActivationRequest) async throws

    /// Quit an application
    /// - Parameters:
    ///   - identifier: Application name or bundle ID
    ///   - force: Force quit without saving
    /// - Returns: True if the application was successfully quit
    func quitApplication(identifier: String, force: Bool) async throws -> Bool

    /// Quit only while the resolved process still matches the discovery receipt.
    func quitApplication(request: ApplicationQuitRequest) async throws -> Bool

    /// Hide an application
    /// - Parameter identifier: Application name or bundle ID
    func hideApplication(identifier: String) async throws

    /// Unhide an application
    /// - Parameter identifier: Application name or bundle ID
    func unhideApplication(identifier: String) async throws

    /// Hide all other applications
    /// - Parameter identifier: Application to keep visible
    func hideOtherApplications(identifier: String) async throws

    /// Show all hidden applications
    func showAllApplications() async throws
}

/// Additive catalog capability for exact mutation target selection.
///
/// The inventory covers process identity and exact application membership. Optional window or
/// presentation metadata must not make an otherwise complete application catalog look incomplete.
public protocol ApplicationMutationInventoryProviding: ApplicationServiceProtocol {
    func applicationMutationInventory() async throws
        -> DesktopTargetPlanning.Inventory<ServiceApplicationInfo>
}

extension ApplicationServiceProtocol {
    /// Returns application rows together with explicit completeness evidence.
    ///
    /// Legacy conformers expose rows only. Mutation planners therefore treat their broad catalog as
    /// partial while still allowing a direct exact-PID lookup through `findApplication`.
    public func mutationApplicationInventory() async throws
        -> DesktopTargetPlanning.Inventory<ServiceApplicationInfo>
    {
        if let provider = self as? any ApplicationMutationInventoryProviding {
            return try await provider.applicationMutationInventory()
        }
        return try await .partial(
            self.listApplications().data.applications,
            warnings: ["Application mutation inventory completeness was not reported by this service."])
    }
}

/// Additive capability for application mutations that return the shared action-result carrier.
///
/// Requirement names intentionally differ from the public `*Result` adapters below. Keeping the
/// capability witnesses distinct prevents an adapter default from satisfying this protocol and
/// recursively redispatching to itself.
public protocol ApplicationServiceActionResultProviding: ApplicationServiceProtocol {
    func launchApplicationActionResult(
        request: ApplicationLaunchRequest) async throws -> DesktopActionResult<ServiceApplicationInfo>

    func relaunchApplicationActionResult(
        request: ApplicationRelaunchRequest) async throws -> DesktopActionResult<ServiceApplicationInfo>

    func activateApplicationActionResult(
        request: ApplicationActivationRequest) async throws -> DesktopActionResult<Void>

    func quitApplicationActionResult(
        request: ApplicationQuitRequest) async throws -> DesktopActionResult<Bool>

    func hideApplicationActionResult(identifier: String) async throws -> DesktopActionResult<Void>

    func unhideApplicationActionResult(identifier: String) async throws -> DesktopActionResult<Void>
}

/// Additive capability for application mutations whose canonical result must retain its exact target.
///
/// The original action-result protocol predates target receipts and remains source compatible. Bridge
/// hosts use this capability when available so a successful action cannot be widened from one resolved
/// process generation to a global operation after dispatch.
public protocol ApplicationServiceTargetedActionResultProviding: ApplicationServiceProtocol {
    func activateApplicationTargetedActionResult(
        request: ApplicationActivationRequest) async throws -> UIAutomationActionResult<Void>

    func hideApplicationTargetedActionResult(identifier: String) async throws -> UIAutomationActionResult<Void>

    func hideApplicationTargetedActionResult(
        request: ApplicationHideRequest) async throws -> UIAutomationActionResult<Void>

    func hideOtherApplicationsActionResult(identifier: String) async throws -> DesktopActionResult<Void>

    func showAllApplicationsActionResult() async throws -> DesktopActionResult<Void>
}

extension ApplicationServiceTargetedActionResultProviding {
    public func hideApplicationTargetedActionResult(
        request _: ApplicationHideRequest) async throws -> UIAutomationActionResult<Void>
    {
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .runtimeIncompatible,
            message: "The application service cannot pin hide to the caller's process generation.",
            hint: "Update the runtime host before retrying this application mutation.")
    }
}

extension ApplicationServiceProtocol {
    public func activateApplicationTargetedResult(
        request: ApplicationActivationRequest) async throws -> UIAutomationActionResult<Void>
    {
        if let results = self as? any ApplicationServiceTargetedActionResultProviding {
            return try await results.activateApplicationTargetedActionResult(request: request)
        }
        let app = try await self.findApplication(identifier: request.identifier)
        guard let identity = request.expectedIdentity ?? app.processIdentity,
              app.processIdentity == identity
        else {
            throw PeekabooError.serviceUnavailable(
                "Application discovery did not return a stable process-generation identity for exact activation")
        }
        let pinnedRequest = ApplicationActivationRequest(
            identifier: "PID:\(identity.processIdentifier)",
            expectedIdentity: identity)
        let result = try await self.activateApplicationResult(request: pinnedRequest)
        return try UIAutomationActionResult(
            payload: result.payload,
            outcome: result.outcome,
            targetIdentity: DesktopTargetIdentity(processIdentity: identity))
    }

    public func hideApplicationTargetedResult(identifier: String) async throws -> UIAutomationActionResult<Void> {
        if let results = self as? any ApplicationServiceTargetedActionResultProviding {
            return try await results.hideApplicationTargetedActionResult(identifier: identifier)
        }
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .runtimeIncompatible,
            message: "The application service cannot return an exact hide target.",
            hint: "Update the runtime host before retrying this application mutation.")
    }

    public func hideApplicationTargetedResult(
        request: ApplicationHideRequest) async throws -> UIAutomationActionResult<Void>
    {
        if let results = self as? any ApplicationServiceTargetedActionResultProviding {
            return try await results.hideApplicationTargetedActionResult(request: request)
        }
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .runtimeIncompatible,
            message: "The application service cannot pin hide to the caller's process generation.",
            hint: "Update the runtime host before retrying this application mutation.")
    }

    public func hideOtherApplicationsResult(identifier: String) async throws -> DesktopActionResult<Void> {
        if let results = self as? any ApplicationServiceTargetedActionResultProviding {
            return try await results.hideOtherApplicationsActionResult(identifier: identifier)
        }
        try await self.hideOtherApplications(identifier: identifier)
        return DesktopActionResult(outcome: .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted))
    }

    public func showAllApplicationsResult() async throws -> DesktopActionResult<Void> {
        if let results = self as? any ApplicationServiceTargetedActionResultProviding {
            return try await results.showAllApplicationsActionResult()
        }
        try await self.showAllApplications()
        return DesktopActionResult(outcome: .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted))
    }

    public func launchApplicationResult(
        request: ApplicationLaunchRequest) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        if let results = self as? any ApplicationServiceActionResultProviding {
            return try await results.launchApplicationActionResult(request: request)
        }
        return try await DesktopActionResult(
            payload: self.launchApplication(request: request),
            outcome: nil)
    }

    public func relaunchApplicationResult(
        request: ApplicationRelaunchRequest) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        if let results = self as? any ApplicationServiceActionResultProviding {
            return try await results.relaunchApplicationActionResult(request: request)
        }
        return try await DesktopActionResult(
            payload: self.relaunchApplication(request: request),
            outcome: nil)
    }

    public func activateApplicationResult(
        request: ApplicationActivationRequest) async throws -> DesktopActionResult<Void>
    {
        if let results = self as? any ApplicationServiceActionResultProviding {
            return try await results.activateApplicationActionResult(request: request)
        }
        try await self.activateApplication(request: request)
        return DesktopActionResult(outcome: nil)
    }

    public func quitApplicationResult(
        request: ApplicationQuitRequest) async throws -> DesktopActionResult<Bool>
    {
        if let results = self as? any ApplicationServiceActionResultProviding {
            return try await results.quitApplicationActionResult(request: request)
        }
        return try await DesktopActionResult(
            payload: self.quitApplication(request: request),
            outcome: nil)
    }

    public func hideApplicationResult(identifier: String) async throws -> DesktopActionResult<Void> {
        if let results = self as? any ApplicationServiceActionResultProviding {
            return try await results.hideApplicationActionResult(identifier: identifier)
        }
        try await self.hideApplication(identifier: identifier)
        return DesktopActionResult(outcome: nil)
    }

    public func unhideApplicationResult(identifier: String) async throws -> DesktopActionResult<Void> {
        if let results = self as? any ApplicationServiceActionResultProviding {
            return try await results.unhideApplicationActionResult(identifier: identifier)
        }
        try await self.unhideApplication(identifier: identifier)
        return DesktopActionResult(outcome: nil)
    }

    public var supportsApplicationLaunchOptions: Bool {
        false
    }

    public var supportsSafeBackgroundApplicationLaunchNoOp: Bool {
        false
    }

    public var supportsNewApplicationInstanceLaunch: Bool {
        false
    }

    public var supportsApplicationWindowReadiness: Bool {
        false
    }

    public var supportsApplicationRelaunch: Bool {
        false
    }

    public var supportsProcessGenerationPinnedApplicationQuit: Bool {
        false
    }

    public var supportsProcessGenerationPinnedApplicationActivation: Bool {
        false
    }

    public var supportsProcessGenerationPinnedApplicationHide: Bool {
        false
    }

    public func activateApplication(request: ApplicationActivationRequest) async throws {
        guard request.expectedIdentity == nil else {
            throw PeekabooError.serviceUnavailable(
                "This application service does not support process-generation-pinned activation")
        }
        try await self.activateApplication(identifier: request.identifier)
    }

    public func launchApplication(request: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo {
        guard let identifier = request.applicationIdentifier,
              request.openURLs.isEmpty,
              request.activates,
              !request.waitUntilReady,
              !request.waitForWindow,
              !request.createsNewInstance
        else {
            throw PeekabooError.serviceUnavailable(
                "This application service does not support launch options; update the Peekaboo runtime host")
        }
        return try await self.launchApplication(identifier: identifier)
    }

    public func relaunchApplication(request _: ApplicationRelaunchRequest) async throws -> ServiceApplicationInfo {
        throw PeekabooError.serviceUnavailable(
            "This application service does not support atomic relaunch; update the Peekaboo runtime host")
    }

    public func quitApplication(request: ApplicationQuitRequest) async throws -> Bool {
        guard request.expectedIdentity == nil else {
            throw PeekabooError.serviceUnavailable(
                "This application service does not support process-generation-pinned quit; update the runtime host")
        }
        return try await self.quitApplication(identifier: request.identifier, force: request.force)
    }
}

/// Information about an application for service layer
public struct ServiceApplicationInfo: Sendable, Codable, Equatable {
    /// Process identifier
    public let processIdentifier: Int32

    /// Process-generation token captured while this application was resolved.
    ///
    /// Older Bridge hosts omit this field. Destructive callers must treat `nil` as unpinned and
    /// fail closed instead of relying on the reusable numeric PID alone.
    public let processStartIdentity: UInt64?

    /// Bundle identifier (e.g., "com.apple.Safari")
    public let bundleIdentifier: String?

    /// Application name
    public let name: String

    /// Path to the application bundle
    public let bundlePath: String?

    /// Path to the running process executable, captured directly from LaunchServices when available.
    ///
    /// This is distinct from ``bundlePath``: an application's executable name can differ from its
    /// bundle name and is valid selector evidence for capture operations.
    public let executablePath: String?

    /// Whether the application is currently active (frontmost)
    public let isActive: Bool

    /// Whether the application is hidden
    public let isHidden: Bool

    /// Whether `isHidden` was read from this exact process generation.
    ///
    /// A current host sets this to `false` when per-process metadata exceeded its bounded
    /// inventory deadline. Older hosts omit the field; their required `isHidden` value remains
    /// authoritative for compatibility.
    public let isHiddenKnown: Bool?

    /// Number of windows
    public var windowCount: Int

    /// Exact WindowServer identifiers known for the application's current windows.
    ///
    /// Older Bridge hosts omit this field, so callers must treat `nil` as unknown rather than
    /// claiming the application has no windows. A non-`nil` value is a point-in-time snapshot.
    public let windowIDs: [Int]?

    /// macOS activation policy, when known.
    public let activationPolicy: ServiceApplicationActivationPolicy?

    /// Whether LaunchServices reports that the app has finished launching.
    public let isFinishedLaunching: Bool?

    /// Bounded enrichment warnings scoped to this application.
    ///
    /// Keeping warnings on the row preserves partial-result truth across older Bridge response
    /// envelopes that carry an application array without `UnifiedToolOutput` metadata.
    public let metadataWarnings: [String]?

    /// Signed-selector evidence produced when this row is the result of an authoritative lookup.
    ///
    /// Inventory rows and older Bridge hosts omit this field. A current targeted lookup carries it
    /// so receipt validation can bind the returned process to cross-candidate discovery precedence.
    public let selectorResolutionProofs: [SelectorResolutionProof]?

    public init(
        processIdentifier: Int32,
        processStartIdentity: UInt64? = nil,
        bundleIdentifier: String?,
        name: String,
        bundlePath: String? = nil,
        executablePath: String? = nil,
        isActive: Bool = false,
        isHidden: Bool = false,
        isHiddenKnown: Bool? = nil,
        windowCount: Int = 0,
        windowIDs: [Int]? = nil,
        activationPolicy: ServiceApplicationActivationPolicy? = nil,
        isFinishedLaunching: Bool? = nil,
        metadataWarnings: [String]? = nil,
        selectorResolutionProofs: [SelectorResolutionProof]? = nil)
    {
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.isActive = isActive
        self.isHidden = isHidden
        self.isHiddenKnown = isHiddenKnown
        self.windowCount = windowCount
        self.windowIDs = windowIDs
        self.activationPolicy = activationPolicy
        self.isFinishedLaunching = isFinishedLaunching
        self.metadataWarnings = metadataWarnings
        self.selectorResolutionProofs = selectorResolutionProofs
    }

    public var processIdentity: ApplicationProcessIdentity? {
        self.processStartIdentity.map {
            ApplicationProcessIdentity(
                processIdentifier: self.processIdentifier,
                processStartIdentity: $0)
        }
    }

    public func withSelectorResolutionProofs(_ proofs: [SelectorResolutionProof]?) -> Self {
        Self(
            processIdentifier: self.processIdentifier,
            processStartIdentity: self.processStartIdentity,
            bundleIdentifier: self.bundleIdentifier,
            name: self.name,
            bundlePath: self.bundlePath,
            executablePath: self.executablePath,
            isActive: self.isActive,
            isHidden: self.isHidden,
            isHiddenKnown: self.isHiddenKnown,
            windowCount: self.windowCount,
            windowIDs: self.windowIDs,
            activationPolicy: self.activationPolicy,
            isFinishedLaunching: self.isFinishedLaunching,
            metadataWarnings: self.metadataWarnings,
            selectorResolutionProofs: proofs)
    }
}

public enum ServiceApplicationActivationPolicy: String, Sendable, Codable, Equatable {
    case regular
    case accessory
    case prohibited
    case unknown
}

extension ServiceApplicationInfo {
    /// Broad searches must not expand into system-only helpers or rows whose bounded metadata is unknown.
    public var isUsableForBroadAutomationDiscovery: Bool {
        self.activationPolicy != .prohibited && self.isHiddenKnown != false
    }

    /// Background input must not target system-only helpers or rows whose bounded metadata is incomplete.
    public var isEligibleForBackgroundInput: Bool {
        self.activationPolicy != .prohibited && self.isHiddenKnown != false
    }

    /// Bulk termination is fail-closed: only an explicitly regular app with known metadata is eligible.
    public var isEligibleForBulkQuit: Bool {
        self.activationPolicy == .regular && self.isHiddenKnown != false
    }
}

/// Information about a window for service layer
public enum WindowSharingState: Int, Codable, Sendable {
    case none = 0
    case readOnly = 1
    case readWrite = 2
}

/// Pins a destructive window mutation to one WindowServer ID and one process generation.
///
/// A PID can be recycled, so its process-start generation is required. CGWindowID is Apple's
/// session-scoped WindowServer identifier and has no stronger public incarnation token; callers retain
/// owner generation and immutable capture-time bounds as fail-closed change evidence. `isMinimized` is
/// only a state hint and is never identity evidence.
public struct WindowMutationIdentity: Sendable, Codable, Equatable {
    public let windowID: Int
    public let ownerProcessIdentifier: Int32
    public let ownerProcessStartIdentity: UInt64
    public let capturedBounds: CGRect?
    public let isMinimized: Bool?

    public init(
        windowID: Int,
        ownerProcessIdentifier: Int32,
        ownerProcessStartIdentity: UInt64,
        capturedBounds: CGRect? = nil,
        isMinimized: Bool? = nil)
    {
        self.windowID = windowID
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.ownerProcessStartIdentity = ownerProcessStartIdentity
        self.capturedBounds = capturedBounds
        self.isMinimized = isMinimized
    }

    public func withMinimizedState(_ isMinimized: Bool) -> WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: self.windowID,
            ownerProcessIdentifier: self.ownerProcessIdentifier,
            ownerProcessStartIdentity: self.ownerProcessStartIdentity,
            capturedBounds: self.capturedBounds,
            isMinimized: isMinimized)
    }

    /// The generation-bound process receipt embedded in this window receipt.
    public var processIdentity: ApplicationProcessIdentity {
        ApplicationProcessIdentity(
            processIdentifier: self.ownerProcessIdentifier,
            processStartIdentity: self.ownerProcessStartIdentity)
    }

    /// Compares the stable receipt fields while intentionally ignoring minimized state.
    ///
    /// Minimized state is mutable window state, not evidence that a WindowServer identifier or
    /// owner process generation changed.
    public func hasSameStableReceipt(as other: WindowMutationIdentity) -> Bool {
        self.windowID == other.windowID &&
            self.processIdentity == other.processIdentity &&
            self.capturedBounds == other.capturedBounds
    }
}

extension DesktopActionFailure {
    func attributed(to processIdentity: ApplicationProcessIdentity) -> DesktopActionFailure {
        self.attributed(to: DesktopActionTargetReceipt(
            processIdentifier: processIdentity.processIdentifier,
            processStartIdentity: processIdentity.processStartIdentity))
    }

    func attributed(to windowIdentity: WindowMutationIdentity) -> DesktopActionFailure {
        self.attributed(to: DesktopActionTargetReceipt(
            processIdentifier: windowIdentity.ownerProcessIdentifier,
            processStartIdentity: windowIdentity.ownerProcessStartIdentity,
            windowID: windowIdentity.windowID))
    }
}

public struct ServiceWindowInfo: Sendable, Codable, Equatable {
    /// Window identifier
    public let windowID: Int

    /// Window title
    public let title: String

    /// Window bounds in screen coordinates
    public let bounds: CGRect

    /// Whether the window is minimized
    public let isMinimized: Bool

    /// Whether the window is the main window
    public let isMainWindow: Bool

    /// Whether Accessibility reports this as the app's focused/key window
    public let isKeyWindow: Bool?

    /// Whether this is the key window of the frontmost application
    public let isFrontmost: Bool?

    /// Accessibility subrole, such as AXStandardWindow or AXDialog
    public let subrole: String?

    /// Window level (z-order)
    public let windowLevel: Int

    /// Alpha value (transparency)
    public let alpha: CGFloat

    /// Window index within the application (0 = frontmost)
    public let index: Int

    /// Space (virtual desktop) ID this window belongs to
    public let spaceID: UInt64?

    /// Human-readable name of the Space (if available)
    public let spaceName: String?

    /// Screen index (position in NSScreen.screens array)
    public let screenIndex: Int?

    /// Screen name (e.g., "Built-in Display", "LG UltraFine")
    public let screenName: String?

    /// Whether the window is off-screen
    public let isOffScreen: Bool

    /// CG window layer (0 == standard app window)
    public let layer: Int

    /// Whether CoreGraphics reports the window as on-screen
    public let isOnScreen: Bool

    /// Sharing state exposed by AppKit/CoreGraphics
    public let sharingState: WindowSharingState?

    /// Whether our own NSWindow asked to hide from the Windows menu
    public let isExcludedFromWindowsMenu: Bool

    /// Process-generation receipt captured with this listing for later destructive mutations.
    public let mutationIdentity: WindowMutationIdentity?

    /// Server-derived proof for a requested mutation postcondition. Ordinary listings leave this nil.
    public let mutationPostconditionEvidence: WindowMutationPostconditionEvidence?

    enum CodingKeys: String, CodingKey {
        case windowID = "window_id"
        case title
        case bounds
        case isMinimized
        case isMainWindow
        case isKeyWindow
        case isFrontmost
        case subrole
        case windowLevel
        case alpha
        case index
        case spaceID
        case spaceName
        case screenIndex
        case screenName
        case isOffScreen
        case layer
        case isOnScreen
        case sharingState
        case isExcludedFromWindowsMenu
        case mutationIdentity
        case mutationPostconditionEvidence
    }

    public init(
        windowID: Int,
        title: String,
        bounds: CGRect,
        isMinimized: Bool = false,
        isMainWindow: Bool = false,
        isKeyWindow: Bool? = nil,
        isFrontmost: Bool? = nil,
        subrole: String? = nil,
        windowLevel: Int = 0,
        alpha: CGFloat = 1.0,
        index: Int = 0,
        spaceID: UInt64? = nil,
        spaceName: String? = nil,
        screenIndex: Int? = nil,
        screenName: String? = nil,
        isOffScreen: Bool = false,
        layer: Int = 0,
        isOnScreen: Bool = true,
        sharingState: WindowSharingState? = nil,
        isExcludedFromWindowsMenu: Bool = false,
        mutationIdentity: WindowMutationIdentity? = nil,
        mutationPostconditionEvidence: WindowMutationPostconditionEvidence? = nil)
    {
        self.windowID = windowID
        self.title = title
        self.bounds = bounds
        self.isMinimized = isMinimized
        self.isMainWindow = isMainWindow
        self.isKeyWindow = isKeyWindow
        self.isFrontmost = isFrontmost
        self.subrole = subrole
        self.windowLevel = windowLevel
        self.alpha = alpha
        self.index = index
        self.spaceID = spaceID
        self.spaceName = spaceName
        self.screenIndex = screenIndex
        self.screenName = screenName
        self.isOffScreen = isOffScreen
        self.layer = layer
        self.isOnScreen = isOnScreen
        self.sharingState = sharingState
        self.isExcludedFromWindowsMenu = isExcludedFromWindowsMenu
        self.mutationIdentity = mutationIdentity
        self.mutationPostconditionEvidence = mutationPostconditionEvidence
    }

    public var isShareableWindow: Bool {
        guard let sharingState else {
            return true
        }
        return sharingState != .none
    }

    public func withMutationPostconditionEvidence(
        _ evidence: WindowMutationPostconditionEvidence?) -> Self
    {
        Self(
            windowID: self.windowID,
            title: self.title,
            bounds: self.bounds,
            isMinimized: self.isMinimized,
            isMainWindow: self.isMainWindow,
            isKeyWindow: self.isKeyWindow,
            isFrontmost: self.isFrontmost,
            subrole: self.subrole,
            windowLevel: self.windowLevel,
            alpha: self.alpha,
            index: self.index,
            spaceID: self.spaceID,
            spaceName: self.spaceName,
            screenIndex: self.screenIndex,
            screenName: self.screenName,
            isOffScreen: self.isOffScreen,
            layer: self.layer,
            isOnScreen: self.isOnScreen,
            sharingState: self.sharingState,
            isExcludedFromWindowsMenu: self.isExcludedFromWindowsMenu,
            mutationIdentity: self.mutationIdentity,
            mutationPostconditionEvidence: evidence)
    }
}
