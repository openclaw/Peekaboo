import Foundation
import PeekabooFoundation

extension DesktopTargetPlanning {
    /// One generation-pinned desktop mutation authority produced from a complete catalog.
    public enum MutationAuthorityPlan: Equatable, Sendable {
        case application(ApplicationMutationPlan)
        case window(WindowMutationPlan)

        public var application: ApplicationMutationPlan {
            switch self {
            case let .application(plan): plan
            case let .window(plan): plan.owner
            }
        }

        public var window: WindowMutationPlan? {
            guard case let .window(plan) = self else { return nil }
            return plan
        }

        public var targetIdentity: DesktopTargetIdentity {
            get throws {
                switch self {
                case let .application(plan):
                    try plan.expectedTargetIdentity
                case let .window(plan):
                    try plan.expectedTargetIdentity
                }
            }
        }
    }

    public enum MutationAuthorityRequirement: Equatable, Sendable {
        /// Preserve the most specific target explicitly supplied by the selector.
        case mostSpecific

        /// Resolve one exact window, using the supplied policy when the selector names only its owner.
        case exactWindow(automaticSelection: WindowSelectionPolicy)
    }

    /// Shared application/window authority planner for mutation surfaces.
    ///
    /// Surface adapters own argument parsing, policy, and presentation. This planner owns catalog
    /// completeness, exact selection, process-generation pinning, and pre-dispatch revalidation.
    @MainActor
    public struct MutationAuthorityPlanner {
        private let applications: ApplicationMutationPlanner
        private let windows: WindowMutationPlanner

        public init(
            applications: any ApplicationServiceProtocol,
            windows: any WindowManagementServiceProtocol)
        {
            let applicationPlanner = ApplicationMutationPlanner(applications: applications)
            self.applications = applicationPlanner
            self.windows = WindowMutationPlanner(
                applicationPlanner: applicationPlanner,
                windowInventoryProvider: { target in
                    try await windows.mutationInventory(target: target)
                })
        }

        public init(
            applicationPlanner: ApplicationMutationPlanner,
            windowPlanner: WindowMutationPlanner)
        {
            self.applications = applicationPlanner
            self.windows = windowPlanner
        }

        public func plan(
            selector: InteractionTargetSelector,
            requirement: MutationAuthorityRequirement = .mostSpecific,
            expectedProcessIdentity: ApplicationProcessIdentity? = nil) async throws -> MutationAuthorityPlan
        {
            switch requirement {
            case .mostSpecific where selector.hasWindowInput:
                let plan = try await self.windows.plan(selector: selector)
                try Self.requireExpectedProcessIdentity(expectedProcessIdentity, actual: plan.owner.processIdentity)
                return .window(plan)
            case .mostSpecific:
                return try await .application(self.applications.plan(
                    selector: selector,
                    expectedIdentity: expectedProcessIdentity))
            case let .exactWindow(automaticSelection):
                let plan = try await self.windows.plan(
                    selector: selector,
                    automaticSelection: automaticSelection)
                try Self.requireExpectedProcessIdentity(expectedProcessIdentity, actual: plan.owner.processIdentity)
                return .window(plan)
            }
        }

        public func revalidate(_ plan: MutationAuthorityPlan) async throws -> MutationAuthorityPlan {
            switch plan {
            case let .application(application):
                try await .application(self.applications.revalidate(application))
            case let .window(window):
                try await .window(self.windows.revalidate(window))
            }
        }

        private static func requireExpectedProcessIdentity(
            _ expected: ApplicationProcessIdentity?,
            actual: ApplicationProcessIdentity) throws
        {
            guard let expected, expected != actual else { return }
            throw DesktopTargetPlanningError.staleApplication(expected: expected)
        }
    }
}
