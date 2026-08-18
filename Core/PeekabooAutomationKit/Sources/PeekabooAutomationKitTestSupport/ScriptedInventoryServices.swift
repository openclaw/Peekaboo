import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

private enum ScriptedApplicationIdentifier {
    static func canonicalKey(_ identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let pidText = trimmed.uppercased().hasPrefix("PID:")
            ? String(trimmed.dropFirst(4))
            : trimmed
        if let processIdentifier = Int32(pidText), processIdentifier > 0 {
            return "pid:\(processIdentifier)"
        }
        return "literal:\(trimmed)"
    }
}

public enum LinkedApplicationInventoryGraphError: Error, Equatable, LocalizedError, Sendable {
    case invalidProcessIdentity(processIdentifier: Int32, processStartIdentity: UInt64?)
    case duplicateProcessIdentifier(Int32)
    case contradictoryApplicationMetadata(processIdentifier: Int32)
    case ambiguousApplicationIdentifier(String)
    case invalidWindowIdentifier(Int)
    case duplicateWindowIdentifier(Int)
    case invalidWindowBounds(windowID: Int)
    case contradictoryWindowReceipt(windowID: Int)
    case contradictoryApplicationWindowIDs(processIdentifier: Int32)

    public var errorDescription: String? {
        switch self {
        case let .invalidProcessIdentity(processIdentifier, processStartIdentity):
            "Application PID \(processIdentifier) has invalid process-generation identity " +
                (processStartIdentity.map(String.init) ?? "nil") + "."
        case let .duplicateProcessIdentifier(processIdentifier):
            "Application inventory contains duplicate PID \(processIdentifier)."
        case let .contradictoryApplicationMetadata(processIdentifier):
            "Application inventory contains contradictory metadata for PID \(processIdentifier)."
        case let .ambiguousApplicationIdentifier(identifier):
            "Application inventory maps identifier '\(identifier)' to multiple process generations."
        case let .invalidWindowIdentifier(windowID):
            "Window inventory contains invalid WindowServer ID \(windowID)."
        case let .duplicateWindowIdentifier(windowID):
            "Window inventory contains duplicate WindowServer ID \(windowID)."
        case let .invalidWindowBounds(windowID):
            "Window \(windowID) has invalid bounds."
        case let .contradictoryWindowReceipt(windowID):
            "Window \(windowID) has a receipt that contradicts its application or geometry."
        case let .contradictoryApplicationWindowIDs(processIdentifier):
            "Application PID \(processIdentifier) has window IDs that contradict its linked windows."
        }
    }
}

/// A coherent application, window, and process-generation graph for inventory-driven tests.
///
/// The graph rejects contradictory identity evidence and supplies a missing mutation receipt for a
/// window when its owning application has a valid process generation. Application window counts and
/// an omitted `windowIDs` catalog are normalized from the linked windows.
public struct LinkedApplicationInventoryGraph: Sendable {
    public struct Node: Sendable {
        public let application: ServiceApplicationInfo
        public let windows: [ServiceWindowInfo]

        public init(application: ServiceApplicationInfo, windows: [ServiceWindowInfo]) {
            self.application = application
            self.windows = windows
        }

        public init(linkedTarget: LinkedDesktopTargetFixture) {
            self.init(
                application: linkedTarget.application,
                windows: [linkedTarget.window])
        }
    }

    public let nodes: [Node]
    public let applications: [ServiceApplicationInfo]
    public let windowsByIdentifier: [String: [ServiceWindowInfo]]

    public init(nodes: [Node]) throws {
        var processIdentifiers = Set<Int32>()
        var windowIdentifiers = Set<Int>()
        var normalizedNodes: [Node] = []

        for node in nodes {
            guard let processIdentity = node.application.processIdentity,
                  processIdentity.processIdentifier > 0,
                  processIdentity.processStartIdentity > 0
            else {
                throw LinkedApplicationInventoryGraphError.invalidProcessIdentity(
                    processIdentifier: node.application.processIdentifier,
                    processStartIdentity: node.application.processStartIdentity)
            }
            guard processIdentifiers.insert(processIdentity.processIdentifier).inserted else {
                throw LinkedApplicationInventoryGraphError.duplicateProcessIdentifier(
                    processIdentity.processIdentifier)
            }

            var normalizedWindows: [ServiceWindowInfo] = []
            for window in node.windows {
                guard window.windowID > 0, UInt64(window.windowID) <= UInt64(UInt32.max) else {
                    throw LinkedApplicationInventoryGraphError.invalidWindowIdentifier(window.windowID)
                }
                guard windowIdentifiers.insert(window.windowID).inserted else {
                    throw LinkedApplicationInventoryGraphError.duplicateWindowIdentifier(window.windowID)
                }
                guard Self.hasValidBounds(window.bounds) else {
                    throw LinkedApplicationInventoryGraphError.invalidWindowBounds(windowID: window.windowID)
                }

                if let receipt = window.mutationIdentity {
                    guard receipt.windowID == window.windowID,
                          receipt.processIdentity == processIdentity,
                          receipt.capturedBounds == window.bounds,
                          receipt.isMinimized == nil || receipt.isMinimized == window.isMinimized
                    else {
                        throw LinkedApplicationInventoryGraphError.contradictoryWindowReceipt(
                            windowID: window.windowID)
                    }
                    normalizedWindows.append(window)
                } else {
                    normalizedWindows.append(AutomationTestFixtures.window(
                        copying: window,
                        processIdentity: processIdentity))
                }
            }

            let linkedWindowIDs = normalizedWindows.map(\.windowID)
            if let reportedWindowIDs = node.application.windowIDs,
               Set(reportedWindowIDs) != Set(linkedWindowIDs) || reportedWindowIDs.count != linkedWindowIDs.count
            {
                throw LinkedApplicationInventoryGraphError.contradictoryApplicationWindowIDs(
                    processIdentifier: processIdentity.processIdentifier)
            }
            let normalizedApplication = Self.application(
                copying: node.application,
                windowCount: normalizedWindows.count,
                windowIDs: linkedWindowIDs)
            normalizedNodes.append(Node(
                application: normalizedApplication,
                windows: normalizedWindows))
        }

        var windowsByIdentifier: [String: [ServiceWindowInfo]] = [:]
        var processIdentifierByAlias: [String: Int32] = [:]
        for node in normalizedNodes {
            let application = node.application
            var seenIdentifiers = Set<String>()
            let identifiers = [
                "PID:\(application.processIdentifier)",
                String(application.processIdentifier),
                application.name,
                application.bundleIdentifier,
            ].compactMap(\.self).filter { seenIdentifiers.insert($0).inserted }
            for identifier in identifiers {
                guard let canonicalIdentifier = ScriptedApplicationIdentifier.canonicalKey(identifier) else {
                    continue
                }
                if let existingProcessIdentifier = processIdentifierByAlias[canonicalIdentifier],
                   existingProcessIdentifier != application.processIdentifier
                {
                    throw LinkedApplicationInventoryGraphError.ambiguousApplicationIdentifier(identifier)
                }
                processIdentifierByAlias[canonicalIdentifier] = application.processIdentifier
                windowsByIdentifier[identifier] = node.windows
            }
        }

        self.nodes = normalizedNodes
        self.applications = normalizedNodes.map(\.application)
        self.windowsByIdentifier = windowsByIdentifier
    }

    public init(linkedTargets: [LinkedDesktopTargetFixture]) throws {
        var nodes: [Node] = []
        var nodeIndexByProcessIdentifier: [Int32: Int] = [:]

        for target in linkedTargets {
            let processIdentifier = target.processIdentity.processIdentifier
            if let index = nodeIndexByProcessIdentifier[processIdentifier] {
                let node = nodes[index]
                guard node.application.processIdentity == target.processIdentity else {
                    throw LinkedApplicationInventoryGraphError.duplicateProcessIdentifier(processIdentifier)
                }
                guard Self.hasMatchingNonWindowMetadata(node.application, target.application) else {
                    throw LinkedApplicationInventoryGraphError.contradictoryApplicationMetadata(
                        processIdentifier: processIdentifier)
                }
                let windows = node.windows + [target.window]
                nodes[index] = Node(
                    application: Self.application(
                        copying: node.application,
                        windowCount: windows.count,
                        windowIDs: windows.map(\.windowID)),
                    windows: windows)
            } else {
                nodeIndexByProcessIdentifier[processIdentifier] = nodes.count
                nodes.append(Node(linkedTarget: target))
            }
        }

        try self.init(nodes: nodes)
    }

    private static func hasValidBounds(_ bounds: CGRect) -> Bool {
        !bounds.isEmpty &&
            bounds.origin.x.isFinite &&
            bounds.origin.y.isFinite &&
            bounds.width.isFinite &&
            bounds.height.isFinite
    }

    private static func hasMatchingNonWindowMetadata(
        _ lhs: ServiceApplicationInfo,
        _ rhs: ServiceApplicationInfo) -> Bool
    {
        self.application(copying: lhs, windowCount: 0, windowIDs: []) ==
            self.application(copying: rhs, windowCount: 0, windowIDs: [])
    }

    private static func application(
        copying application: ServiceApplicationInfo,
        windowCount: Int,
        windowIDs: [Int]) -> ServiceApplicationInfo
    {
        ServiceApplicationInfo(
            processIdentifier: application.processIdentifier,
            processStartIdentity: application.processStartIdentity,
            bundleIdentifier: application.bundleIdentifier,
            name: application.name,
            bundlePath: application.bundlePath,
            executablePath: application.executablePath,
            isActive: application.isActive,
            isHidden: application.isHidden,
            isHiddenKnown: application.isHiddenKnown,
            windowCount: windowCount,
            windowIDs: windowIDs,
            activationPolicy: application.activationPolicy,
            isFinishedLaunching: application.isFinishedLaunching,
            metadataWarnings: application.metadataWarnings,
            selectorResolutionProofs: application.selectorResolutionProofs)
    }
}

extension AutomationTestFixtures {
    public static func linkedApplicationInventoryGraph(
        processIdentity: ApplicationProcessIdentity = Self.processIdentity(),
        bundleIdentifier: String? = "com.example.TestApp",
        applicationName: String = "Test App",
        windowID: Int = 201,
        windowTitle: String = "Test Window",
        bounds: CGRect = CGRect(x: 10, y: 20, width: 640, height: 480)) throws
        -> LinkedApplicationInventoryGraph
    {
        let linkedTarget = self.linkedDesktopTarget(
            processIdentity: processIdentity,
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            windowID: windowID,
            windowTitle: windowTitle,
            bounds: bounds)
        return try LinkedApplicationInventoryGraph(linkedTargets: [linkedTarget])
    }
}

/// Mutable application inventory double with finite, saturating inventory scripts.
///
/// Empty scripts derive their result from `applications` on every read. Nonempty scripts advance one
/// response per mutation-inventory request and repeat the last response after exhaustion.
@MainActor
open class ScriptedApplicationInventoryService:
    ApplicationServiceProtocol,
    ApplicationMutationInventoryProviding
{
    public typealias Inventory = DesktopTargetPlanning.Inventory<ServiceApplicationInfo>

    public var applications: [ServiceApplicationInfo]
    public var windowsByIdentifier: [String: [ServiceWindowInfo]]
    public var inventoryCompleteness: Inventory.Completeness
    public var inventoryWarnings: [String]
    public var applicationInventorySequence: [Inventory] {
        didSet { self.applicationInventorySequenceIndex = 0 }
    }

    private let launchOptionsSupported: Bool
    private let relaunchSupported: Bool
    private let pinnedQuitSupported: Bool
    private let pinnedActivationSupported: Bool
    private let applicationMetadataWarningsPropagated: Bool

    public private(set) var listApplicationsCallCount = 0
    public private(set) var applicationMutationInventoryCallCount = 0
    public private(set) var findApplicationRequests: [String] = []
    public private(set) var listWindowsRequests: [(identifier: String, timeout: Float?)] = []
    public private(set) var frontmostApplicationCallCount = 0
    public private(set) var runningApplicationRequests: [String] = []
    public private(set) var launchIdentifiers: [String] = []
    public private(set) var launchRequests: [ApplicationLaunchRequest] = []
    public private(set) var relaunchRequests: [ApplicationRelaunchRequest] = []
    public private(set) var activationIdentifiers: [String] = []
    public private(set) var recordedActivationRequests: [ApplicationActivationRequest] = []
    public private(set) var recordedQuitRequests: [ApplicationQuitRequest] = []
    public private(set) var hideRequests: [String] = []
    public private(set) var unhideRequests: [String] = []
    public private(set) var hideOtherRequests: [String] = []
    public private(set) var showAllApplicationsCallCount = 0

    private var applicationInventorySequenceIndex = 0

    public init(
        applications: [ServiceApplicationInfo] = [],
        windowsByIdentifier: [String: [ServiceWindowInfo]] = [:],
        inventoryCompleteness: Inventory.Completeness = .complete,
        inventoryWarnings: [String] = [],
        applicationInventorySequence: [Inventory] = [],
        propagatesApplicationMetadataWarnings: Bool = true,
        supportsApplicationLaunchOptions: Bool = false,
        supportsApplicationRelaunch: Bool = false,
        supportsProcessGenerationPinnedApplicationQuit: Bool = false,
        supportsProcessGenerationPinnedApplicationActivation: Bool = true)
    {
        self.applications = applications
        self.windowsByIdentifier = windowsByIdentifier
        self.inventoryCompleteness = inventoryCompleteness
        self.inventoryWarnings = inventoryWarnings
        self.applicationInventorySequence = applicationInventorySequence
        self.applicationMetadataWarningsPropagated = propagatesApplicationMetadataWarnings
        self.launchOptionsSupported = supportsApplicationLaunchOptions
        self.relaunchSupported = supportsApplicationRelaunch
        self.pinnedQuitSupported = supportsProcessGenerationPinnedApplicationQuit
        self.pinnedActivationSupported = supportsProcessGenerationPinnedApplicationActivation
    }

    public convenience init(
        graph: LinkedApplicationInventoryGraph,
        inventoryCompleteness: Inventory.Completeness = .complete,
        inventoryWarnings: [String] = [],
        applicationInventorySequence: [Inventory] = [],
        propagatesApplicationMetadataWarnings: Bool = true,
        supportsApplicationLaunchOptions: Bool = false,
        supportsApplicationRelaunch: Bool = false,
        supportsProcessGenerationPinnedApplicationQuit: Bool = false,
        supportsProcessGenerationPinnedApplicationActivation: Bool = true)
    {
        self.init(
            applications: graph.applications,
            windowsByIdentifier: graph.windowsByIdentifier,
            inventoryCompleteness: inventoryCompleteness,
            inventoryWarnings: inventoryWarnings,
            applicationInventorySequence: applicationInventorySequence,
            propagatesApplicationMetadataWarnings: propagatesApplicationMetadataWarnings,
            supportsApplicationLaunchOptions: supportsApplicationLaunchOptions,
            supportsApplicationRelaunch: supportsApplicationRelaunch,
            supportsProcessGenerationPinnedApplicationQuit: supportsProcessGenerationPinnedApplicationQuit,
            supportsProcessGenerationPinnedApplicationActivation:
            supportsProcessGenerationPinnedApplicationActivation)
    }

    open var supportsApplicationLaunchOptions: Bool {
        self.launchOptionsSupported
    }

    open var supportsApplicationRelaunch: Bool {
        self.relaunchSupported
    }

    open var supportsProcessGenerationPinnedApplicationQuit: Bool {
        self.pinnedQuitSupported
    }

    open var supportsProcessGenerationPinnedApplicationActivation: Bool {
        self.pinnedActivationSupported
    }

    open func replaceApplicationsForTesting(_ applications: [ServiceApplicationInfo]) {
        self.applications = applications
    }

    open func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        self.listApplicationsCallCount += 1
        let warnings = self.effectiveInventoryWarnings()
        return UnifiedToolOutput(
            data: ServiceApplicationListData(applications: self.applications),
            summary: .init(
                brief: "Found \(self.applications.count) apps",
                status: warnings.isEmpty ? .success : .partial,
                counts: ["applications": self.applications.count]),
            metadata: .init(duration: 0, warnings: warnings))
    }

    open func applicationMutationInventory() async throws -> Inventory {
        self.applicationMutationInventoryCallCount += 1
        guard !self.applicationInventorySequence.isEmpty else {
            let warnings = self.effectiveInventoryWarnings()
            let completeness: Inventory.Completeness = warnings.isEmpty
                ? self.inventoryCompleteness
                : .partial
            return Inventory(
                items: self.applications,
                completeness: completeness,
                warnings: warnings)
        }
        let index = min(
            self.applicationInventorySequenceIndex,
            self.applicationInventorySequence.count - 1)
        self.applicationInventorySequenceIndex = min(
            self.applicationInventorySequenceIndex + 1,
            self.applicationInventorySequence.count - 1)
        return self.applicationInventorySequence[index]
    }

    open func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        self.findApplicationRequests.append(identifier)
        guard let application = self.resolvedApplication(identifier: identifier) else {
            throw PeekabooError.appNotFound(identifier)
        }
        return application
    }

    open func listWindows(
        for appIdentifier: String,
        timeout: Float?) async throws -> UnifiedToolOutput<ServiceWindowListData>
    {
        self.listWindowsRequests.append((appIdentifier, timeout))
        let application = self.resolvedApplication(identifier: appIdentifier)
        let windows = self.resolvedWindows(
            directIdentifier: appIdentifier,
            application: application)
        return UnifiedToolOutput(
            data: ServiceWindowListData(windows: windows, targetApplication: application),
            summary: .init(
                brief: "Found \(windows.count) windows",
                status: .success,
                counts: ["windows": windows.count]),
            metadata: .init(duration: 0))
    }

    open func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        self.frontmostApplicationCallCount += 1
        guard let application = self.applications.first(where: \.isActive) ?? self.applications.first else {
            throw PeekabooError.appNotFound("frontmost")
        }
        return application
    }

    /// Keeps the protocol's throwing signature so importing test targets can override with scripted failures.
    open func isApplicationRunning(identifier: String) async throws -> Bool {
        self.runningApplicationRequests.append(identifier)
        return self.resolvedApplication(identifier: identifier) != nil
    }

    open func launchApplication(identifier: String) async throws -> ServiceApplicationInfo {
        self.launchIdentifiers.append(identifier)
        if let existing = self.resolvedApplication(identifier: identifier) {
            return existing
        }
        let application = self.syntheticApplication(
            identifier: identifier,
            bundleIdentifier: identifier,
            activates: true)
        self.applications.append(application)
        return application
    }

    open func launchApplication(request: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo {
        self.launchRequests.append(request)
        let identifier = request.applicationBundleIdentifier ??
            request.applicationIdentifier ??
            "Default Handler"
        let application = self.syntheticApplication(
            identifier: identifier,
            bundleIdentifier: request.applicationBundleIdentifier,
            activates: request.activates)
        self.applications.append(application)
        return application
    }

    open func relaunchApplication(request: ApplicationRelaunchRequest) async throws -> ServiceApplicationInfo {
        self.relaunchRequests.append(request)
        guard let application = self.resolvedApplication(identifier: request.targetIdentifier) else {
            throw PeekabooError.appNotFound(request.targetIdentifier)
        }
        if let expectedIdentity = request.expectedTargetIdentity,
           application.processIdentity != expectedIdentity
        {
            throw PeekabooError.commandFailed("Application process generation changed before relaunch")
        }
        return try await self.launchApplication(request: request.launchRequest)
    }

    open func activateApplication(identifier: String) async throws {
        self.activationIdentifiers.append(identifier)
        guard self.resolvedApplication(identifier: identifier) != nil else {
            throw PeekabooError.appNotFound(identifier)
        }
    }

    open func activateApplication(request: ApplicationActivationRequest) async throws {
        self.recordedActivationRequests.append(request)
        if request.expectedIdentity != nil, !self.pinnedActivationSupported {
            throw PeekabooError.serviceUnavailable(
                "Scripted application service does not support process-generation-pinned activation")
        }
        let application = try await self.findApplication(identifier: request.identifier)
        if let expectedIdentity = request.expectedIdentity,
           application.processIdentity != expectedIdentity
        {
            throw PeekabooError.commandFailed("Application process generation changed before activation")
        }
    }

    open func quitApplication(identifier: String, force: Bool) async throws -> Bool {
        try await self.quitApplication(request: ApplicationQuitRequest(
            identifier: identifier,
            force: force))
    }

    open func quitApplication(request: ApplicationQuitRequest) async throws -> Bool {
        self.recordedQuitRequests.append(request)
        if request.expectedIdentity != nil, !self.pinnedQuitSupported {
            throw PeekabooError.serviceUnavailable(
                "Scripted application service does not support process-generation-pinned quit")
        }
        guard let application = self.resolvedApplication(identifier: request.identifier) else {
            throw PeekabooError.appNotFound(request.identifier)
        }
        if let expectedIdentity = request.expectedIdentity,
           application.processIdentity != expectedIdentity
        {
            throw PeekabooError.commandFailed("Application process generation changed before quit")
        }
        return true
    }

    open func hideApplication(identifier: String) async throws {
        self.hideRequests.append(identifier)
    }

    open func unhideApplication(identifier: String) async throws {
        self.unhideRequests.append(identifier)
    }

    open func hideOtherApplications(identifier: String) async throws {
        self.hideOtherRequests.append(identifier)
    }

    open func showAllApplications() async throws {
        self.showAllApplicationsCallCount += 1
    }

    open func resetRecordedCalls() {
        self.listApplicationsCallCount = 0
        self.applicationMutationInventoryCallCount = 0
        self.findApplicationRequests = []
        self.listWindowsRequests = []
        self.frontmostApplicationCallCount = 0
        self.runningApplicationRequests = []
        self.launchIdentifiers = []
        self.launchRequests = []
        self.relaunchRequests = []
        self.activationIdentifiers = []
        self.recordedActivationRequests = []
        self.recordedQuitRequests = []
        self.hideRequests = []
        self.unhideRequests = []
        self.hideOtherRequests = []
        self.showAllApplicationsCallCount = 0
    }

    private func resolvedApplication(identifier: String) -> ServiceApplicationInfo? {
        guard let canonicalIdentifier = ScriptedApplicationIdentifier.canonicalKey(identifier) else {
            return nil
        }
        return self.applications.first {
            ScriptedApplicationIdentifier.canonicalKey($0.name) == canonicalIdentifier ||
                $0.bundleIdentifier.flatMap(ScriptedApplicationIdentifier.canonicalKey) == canonicalIdentifier ||
                ScriptedApplicationIdentifier.canonicalKey("PID:\($0.processIdentifier)") == canonicalIdentifier
        }
    }

    private func resolvedWindows(
        directIdentifier: String,
        application: ServiceApplicationInfo?) -> [ServiceWindowInfo]
    {
        if let windows = self.windowsByIdentifier[directIdentifier] {
            return windows
        }
        let aliases = [
            application.map { "PID:\($0.processIdentifier)" },
            application.map { String($0.processIdentifier) },
            application?.bundleIdentifier,
            application?.name,
        ].compactMap(\.self)
        for alias in aliases {
            if let windows = self.windowsByIdentifier[alias] {
                return windows
            }
        }
        return []
    }

    private func syntheticApplication(
        identifier: String,
        bundleIdentifier: String?,
        activates: Bool) -> ServiceApplicationInfo
    {
        let processIdentifier = max(self.applications.map(\.processIdentifier).max() ?? 0, 0) + 1
        return ServiceApplicationInfo(
            processIdentifier: processIdentifier,
            processStartIdentity: UInt64(processIdentifier) * 1000,
            bundleIdentifier: bundleIdentifier,
            name: identifier,
            isActive: activates,
            isFinishedLaunching: true)
    }

    private func effectiveInventoryWarnings() -> [String] {
        let applicationWarnings = self.applicationMetadataWarningsPropagated
            ? self.applications.flatMap { $0.metadataWarnings ?? [] }
            : []
        return Self.uniqueWarnings(self.inventoryWarnings + applicationWarnings)
    }

    private static func uniqueWarnings(_ warnings: [String]) -> [String] {
        var seen = Set<String>()
        return warnings.filter { seen.insert($0).inserted }
    }
}

/// Mutable window inventory double with target-specific, saturating inventory scripts.
@MainActor
open class ScriptedWindowInventoryService:
    WindowManagementServiceProtocol,
    WindowMutationInventoryProviding
{
    public typealias Inventory = DesktopTargetPlanning.Inventory<ServiceWindowInfo>

    public var windowsByIdentifier: [String: [ServiceWindowInfo]]
    public var focusedWindow: ServiceWindowInfo?
    public var inventoryCompleteness: Inventory.Completeness
    public var inventoryWarnings: [String]
    public var defaultInventorySequence: [Inventory] {
        didSet { self.defaultInventorySequenceIndex = 0 }
    }

    public var inventorySequencesByTarget: [WindowTarget: [Inventory]] {
        didSet { self.inventorySequenceIndicesByTarget = [:] }
    }

    public private(set) var listWindowRequests: [WindowTarget] = []
    public private(set) var windowMutationInventoryRequests: [WindowTarget] = []
    public private(set) var focusedWindowCallCount = 0
    public private(set) var closeRequests: [(target: WindowTarget, allowForegroundFallback: Bool)] = []
    public private(set) var minimizeRequests: [WindowTarget] = []
    public private(set) var restoreRequests: [WindowTarget] = []
    public private(set) var maximizeRequests: [WindowTarget] = []
    public private(set) var moveRequests: [(target: WindowTarget, position: CGPoint)] = []
    public private(set) var resizeRequests: [(target: WindowTarget, size: CGSize)] = []
    public private(set) var setBoundsRequests: [(target: WindowTarget, bounds: CGRect)] = []
    public private(set) var focusRequests: [WindowTarget] = []

    private var defaultInventorySequenceIndex = 0
    private var inventorySequenceIndicesByTarget: [WindowTarget: Int] = [:]

    public init(
        windowsByIdentifier: [String: [ServiceWindowInfo]] = [:],
        focusedWindow: ServiceWindowInfo? = nil,
        inventoryCompleteness: Inventory.Completeness = .complete,
        inventoryWarnings: [String] = [],
        defaultInventorySequence: [Inventory] = [],
        inventorySequencesByTarget: [WindowTarget: [Inventory]] = [:])
    {
        self.windowsByIdentifier = windowsByIdentifier
        self.focusedWindow = focusedWindow
        self.inventoryCompleteness = inventoryCompleteness
        self.inventoryWarnings = inventoryWarnings
        self.defaultInventorySequence = defaultInventorySequence
        self.inventorySequencesByTarget = inventorySequencesByTarget
    }

    public convenience init(
        graph: LinkedApplicationInventoryGraph,
        focusedWindow: ServiceWindowInfo? = nil,
        inventoryCompleteness: Inventory.Completeness = .complete,
        inventoryWarnings: [String] = [],
        defaultInventorySequence: [Inventory] = [],
        inventorySequencesByTarget: [WindowTarget: [Inventory]] = [:])
    {
        self.init(
            windowsByIdentifier: graph.windowsByIdentifier,
            focusedWindow: focusedWindow,
            inventoryCompleteness: inventoryCompleteness,
            inventoryWarnings: inventoryWarnings,
            defaultInventorySequence: defaultInventorySequence,
            inventorySequencesByTarget: inventorySequencesByTarget)
    }

    @MainActor
    open func replaceWindowsForTesting(_ windowsByIdentifier: [String: [ServiceWindowInfo]]) {
        self.windowsByIdentifier = windowsByIdentifier
    }

    @MainActor
    open func closeWindow(target: WindowTarget) async throws {
        try await self.closeWindow(target: target, allowForegroundFallback: false)
    }

    @MainActor
    open func closeWindow(target: WindowTarget, allowForegroundFallback: Bool) async throws {
        self.closeRequests.append((target, allowForegroundFallback))
    }

    @MainActor
    open func minimizeWindow(target: WindowTarget) async throws {
        self.minimizeRequests.append(target)
    }

    @MainActor
    open func restoreWindow(target: WindowTarget) async throws {
        self.restoreRequests.append(target)
    }

    @MainActor
    open func maximizeWindow(target: WindowTarget) async throws {
        self.maximizeRequests.append(target)
    }

    @MainActor
    open func moveWindow(target: WindowTarget, to position: CGPoint) async throws {
        self.moveRequests.append((target, position))
    }

    @MainActor
    open func resizeWindow(target: WindowTarget, to size: CGSize) async throws {
        self.resizeRequests.append((target, size))
    }

    @MainActor
    open func setWindowBounds(target: WindowTarget, bounds: CGRect) async throws {
        self.setBoundsRequests.append((target, bounds))
    }

    @MainActor
    open func focusWindow(target: WindowTarget) async throws {
        self.focusRequests.append(target)
    }

    @MainActor
    open func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        self.listWindowRequests.append(target)
        return self.resolvedWindows(target: target)
    }

    @MainActor
    open func windowMutationInventory(target: WindowTarget) async throws -> Inventory {
        self.windowMutationInventoryRequests.append(target)
        if let sequence = self.inventorySequencesByTarget[target], !sequence.isEmpty {
            let currentIndex = self.inventorySequenceIndicesByTarget[target] ?? 0
            let index = min(currentIndex, sequence.count - 1)
            self.inventorySequenceIndicesByTarget[target] = min(currentIndex + 1, sequence.count - 1)
            return sequence[index]
        }
        if !self.defaultInventorySequence.isEmpty {
            let index = min(
                self.defaultInventorySequenceIndex,
                self.defaultInventorySequence.count - 1)
            self.defaultInventorySequenceIndex = min(
                self.defaultInventorySequenceIndex + 1,
                self.defaultInventorySequence.count - 1)
            return self.defaultInventorySequence[index]
        }
        return Inventory(
            items: self.resolvedWindows(target: target),
            completeness: self.inventoryWarnings.isEmpty ? self.inventoryCompleteness : .partial,
            warnings: self.inventoryWarnings)
    }

    @MainActor
    open func getFocusedWindow() async throws -> ServiceWindowInfo? {
        self.focusedWindowCallCount += 1
        return self.focusedWindow
    }

    @MainActor
    open func resetRecordedCalls() {
        self.listWindowRequests = []
        self.windowMutationInventoryRequests = []
        self.focusedWindowCallCount = 0
        self.closeRequests = []
        self.minimizeRequests = []
        self.restoreRequests = []
        self.maximizeRequests = []
        self.moveRequests = []
        self.resizeRequests = []
        self.setBoundsRequests = []
        self.focusRequests = []
    }

    private func resolvedWindows(target: WindowTarget) -> [ServiceWindowInfo] {
        switch target {
        case let .application(identifier):
            return self.windowsByIdentifier[identifier] ?? []
        case let .applicationAndTitle(identifier, title):
            return (self.windowsByIdentifier[identifier] ?? []).filter {
                $0.title.localizedCaseInsensitiveContains(title)
            }
        case .frontmost:
            if let focusedWindow = self.focusedWindow {
                return [focusedWindow]
            }
            let windows = self.allWindows()
            if let frontmost = windows.first(where: { $0.isFrontmost == true }) ??
                windows.first(where: { $0.isKeyWindow == true }) ??
                windows.first(where: \.isMainWindow)
            {
                return [frontmost]
            }
            return Array(windows.prefix(1))
        case let .windowId(windowID):
            return self.allWindows().filter { $0.windowID == windowID }
        case let .title(title):
            return self.allWindows().filter { $0.title.localizedCaseInsensitiveContains(title) }
        case let .index(identifier, index):
            guard index >= 0,
                  let windows = self.windowsByIdentifier[identifier],
                  index < windows.count
            else { return [] }
            return [windows[index]]
        }
    }

    private func allWindows() -> [ServiceWindowInfo] {
        var seen = Set<Int>()
        return self.windowsByIdentifier.values
            .flatMap(\.self)
            .sorted { lhs, rhs in
                lhs.index == rhs.index ? lhs.windowID < rhs.windowID : lhs.index < rhs.index
            }
            .filter { seen.insert($0.windowID).inserted }
    }
}
