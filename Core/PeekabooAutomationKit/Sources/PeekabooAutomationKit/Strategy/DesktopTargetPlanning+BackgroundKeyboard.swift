import Foundation
import PeekabooFoundation

extension DesktopTargetPlanning {
    public enum BackgroundKeyboardTargetPlanningError: LocalizedError, Equatable, Sendable {
        case targetRequired
        case explicitExactWindowRequired
        case applicationIneligible(processIdentifier: Int32)

        public var errorDescription: String? {
            switch self {
            case .targetRequired:
                "Background keyboard input requires an application, process, window, or snapshot target."
            case .explicitExactWindowRequired:
                "Background raw key presses require an explicit exact-window or snapshot receipt."
            case let .applicationIneligible(processIdentifier):
                "Target process PID \(processIdentifier) cannot receive background input because it is a " +
                    "prohibited helper or its application metadata is incomplete."
            }
        }
    }

    /// One background keyboard destination selected from a complete, generation-pinned catalog.
    public struct BackgroundKeyboardTargetPlan: Equatable, Sendable {
        public let target: UIAutomationTarget
        public let application: ApplicationMutationPlan
        public let window: WindowMutationPlan?
        public let snapshotIdentity: DesktopTargetIdentity?

        init(
            target: UIAutomationTarget,
            application: ApplicationMutationPlan,
            window: WindowMutationPlan?,
            snapshotIdentity: DesktopTargetIdentity?)
        {
            self.target = target
            self.application = application
            self.window = window
            self.snapshotIdentity = snapshotIdentity
        }
    }

    /// Shared completeness-aware planner for CLI and MCP background keyboard delivery.
    ///
    /// Surface adapters own only parsing and error wording. This planner owns selector admission,
    /// application/window catalog completeness, process-generation coalescing, background-input
    /// eligibility, and implicit-window ambiguity.
    @MainActor
    public struct BackgroundKeyboardTargetPlanner {
        private let authorities: MutationAuthorityPlanner
        private let windowInventoryProvider: WindowMutationPlanner.WindowInventoryProvider

        public init(
            applications: any ApplicationServiceProtocol,
            windows: any WindowManagementServiceProtocol)
        {
            self.authorities = MutationAuthorityPlanner(applications: applications, windows: windows)
            self.windowInventoryProvider = { target in
                try await windows.mutationInventory(target: target)
            }
        }

        public init(
            applicationPlanner: ApplicationMutationPlanner,
            windowPlanner: WindowMutationPlanner,
            windowInventoryProvider: @escaping WindowMutationPlanner.WindowInventoryProvider)
        {
            self.authorities = MutationAuthorityPlanner(
                applicationPlanner: applicationPlanner,
                windowPlanner: windowPlanner)
            self.windowInventoryProvider = windowInventoryProvider
        }

        public func plan(
            selector: InteractionTargetSelector,
            snapshotProcessIdentity: ApplicationProcessIdentity? = nil,
            snapshotExactWindow: UIAutomationTarget.ExactWindow? = nil,
            requiresExplicitExactWindow: Bool = false) async throws -> BackgroundKeyboardTargetPlan
        {
            do {
                try selector.validate(policy: .mutationSafe)
            } catch let error as InteractionTargetSelector.ValidationError {
                throw DesktopTargetPlanningError.invalidSelector(error)
            }

            let snapshotIdentity = try Self.snapshotIdentity(
                processIdentity: snapshotProcessIdentity,
                exactWindow: snapshotExactWindow)
            let selectedAuthority = if selector.hasAnyInput {
                try await self.authorities.plan(selector: selector)
            } else {
                nil as MutationAuthorityPlan?
            }
            let selectedIdentity = try selectedAuthority?.targetIdentity

            guard let resolvedIdentity = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.coalesce([
                snapshotIdentity,
                selectedIdentity,
            ]) else {
                throw BackgroundKeyboardTargetPlanningError.targetRequired
            }

            var currentAuthority: MutationAuthorityPlan = if let selectedAuthority {
                selectedAuthority
            } else {
                try await self.authorities.plan(
                    selector: InteractionTargetSelector(
                        processIdentifier: Int(resolvedIdentity.processIdentity.processIdentifier)),
                    expectedProcessIdentity: resolvedIdentity.processIdentity)
            }
            currentAuthority = try await self.authorities.revalidate(currentAuthority)
            var currentApplication = currentAuthority.application
            try Self.requireBackgroundInputEligibility(currentApplication)

            if let exactWindow = resolvedIdentity.exactWindow {
                let process = try UIAutomationTarget.Process(
                    processIdentifier: currentApplication.processIdentity.processIdentifier,
                    identity: currentApplication.processIdentity)
                return try BackgroundKeyboardTargetPlan(
                    target: UIAutomationTarget.backgroundKeyboard(
                        process: process,
                        exactWindow: exactWindow),
                    application: currentApplication,
                    window: currentAuthority.window,
                    snapshotIdentity: snapshotIdentity)
            }

            guard !requiresExplicitExactWindow else {
                throw BackgroundKeyboardTargetPlanningError.explicitExactWindowRequired
            }

            let inventory = try await self.windowInventoryProvider(.application(currentApplication.target))
            guard inventory.isComplete else {
                throw DesktopTargetPlanningError.incompleteWindowInventory(
                    selector: "the application's eligible keyboard windows",
                    warnings: inventory.warnings)
            }
            let eligibleWindows = try ObservationTargetResolver.captureCandidates(from: inventory.items).map { window in
                guard let identity = window.mutationIdentity else {
                    throw DesktopTargetPlanningError.missingWindowIdentity(windowID: window.windowID)
                }
                guard identity.processIdentity == currentApplication.processIdentity else {
                    throw DesktopTargetPlanningError.windowOwnerMismatch(
                        windowID: window.windowID,
                        expected: currentApplication.processIdentity)
                }
                return try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.exactWindow(from: window)
            }

            // Window enumeration can race process exit/relaunch. Revalidate after the catalog read
            // before returning authority to a caller that will dispatch keyboard input.
            currentAuthority = try await self.authorities.revalidate(currentAuthority)
            currentApplication = currentAuthority.application
            try Self.requireBackgroundInputEligibility(currentApplication)
            let process = try UIAutomationTarget.Process(
                processIdentifier: currentApplication.processIdentity.processIdentifier,
                identity: currentApplication.processIdentity)
            return try BackgroundKeyboardTargetPlan(
                target: UIAutomationTarget.backgroundKeyboard(
                    process: process,
                    eligibleWindows: eligibleWindows),
                application: currentApplication,
                window: currentAuthority.window,
                snapshotIdentity: snapshotIdentity)
        }

        private static func snapshotIdentity(
            processIdentity: ApplicationProcessIdentity?,
            exactWindow: UIAutomationTarget.ExactWindow?) throws -> DesktopTargetIdentity?
        {
            try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.coalesce([
                processIdentity.map { try DesktopTargetIdentity(processIdentity: $0) },
                exactWindow.map(DesktopTargetIdentity.init(exactWindow:)),
            ])
        }

        private static func requireBackgroundInputEligibility(_ plan: ApplicationMutationPlan) throws {
            guard plan.application.isEligibleForBackgroundInput else {
                throw BackgroundKeyboardTargetPlanningError.applicationIneligible(
                    processIdentifier: plan.processIdentity.processIdentifier)
            }
        }
    }
}
