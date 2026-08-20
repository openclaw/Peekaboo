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

    /// One snapshot/observation identity bound to live mutation authority.
    ///
    /// `targetIdentity` is the canonical coalescing of the immutable source receipt and the
    /// catalog-selected authority. Revalidation repeats that coalescing so callers cannot retain
    /// live authority while accidentally dropping the receipt that originally constrained it.
    public struct ReceiptBoundMutationAuthorityPlan: Equatable, Sendable {
        public let sourceIdentity: DesktopTargetIdentity
        public let authority: MutationAuthorityPlan
        public let targetIdentity: DesktopTargetIdentity

        public var selectedWindow: ServiceWindowInfo? {
            self.authority.window?.selectionWindow
        }

        fileprivate init(
            sourceIdentity: DesktopTargetIdentity,
            authority: MutationAuthorityPlan,
            targetIdentity: DesktopTargetIdentity)
        {
            self.sourceIdentity = sourceIdentity
            self.authority = authority
            self.targetIdentity = targetIdentity
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

        /// Resolves live mutation authority from one immutable source receipt and binds both identities.
        public func bind(
            identity sourceIdentity: DesktopTargetIdentity,
            requirement: MutationAuthorityRequirement = .mostSpecific) async throws
            -> ReceiptBoundMutationAuthorityPlan
        {
            let sourceIdentity = try Self.validated(sourceIdentity)
            let authority = try await self.plan(
                selector: InteractionTargetSelector(
                    processIdentifier: Int(sourceIdentity.processIdentity.processIdentifier),
                    windowID: sourceIdentity.exactWindow?.identity.windowID),
                requirement: requirement,
                expectedProcessIdentity: sourceIdentity.processIdentity)
            return try self.bind(identity: sourceIdentity, authority: authority)
        }

        /// Binds an already-selected authority without repeating its inventory lookup.
        public func bind(
            identity sourceIdentity: DesktopTargetIdentity,
            authority: MutationAuthorityPlan) throws -> ReceiptBoundMutationAuthorityPlan
        {
            let sourceIdentity = try Self.validated(sourceIdentity)
            if let exactWindow = sourceIdentity.exactWindow, authority.window == nil {
                throw DesktopTargetPlanningError.underScopedMutationAuthority(
                    windowID: exactWindow.identity.windowID)
            }
            let targetIdentity = try sourceIdentity.coalescing(authority.targetIdentity)
            return ReceiptBoundMutationAuthorityPlan(
                sourceIdentity: sourceIdentity,
                authority: authority,
                targetIdentity: targetIdentity)
        }

        /// Normalizes selector-only authority into the same receipt-bound representation.
        public func bind(authority: MutationAuthorityPlan) throws -> ReceiptBoundMutationAuthorityPlan {
            try self.bind(identity: authority.targetIdentity, authority: authority)
        }

        public func revalidate(_ plan: MutationAuthorityPlan) async throws -> MutationAuthorityPlan {
            switch plan {
            case let .application(application):
                try await .application(self.applications.revalidate(application))
            case let .window(window):
                try await .window(self.windows.revalidate(window))
            }
        }

        /// Revalidates live authority and rebinds it to the original immutable source receipt.
        public func revalidate(
            _ plan: ReceiptBoundMutationAuthorityPlan) async throws -> ReceiptBoundMutationAuthorityPlan
        {
            let authority = try await self.revalidate(plan.authority)
            let current = try self.bind(identity: plan.targetIdentity, authority: authority)
            return try ReceiptBoundMutationAuthorityPlan(
                sourceIdentity: plan.sourceIdentity,
                authority: authority,
                targetIdentity: plan.sourceIdentity.coalescing(current.targetIdentity))
        }

        private static func requireExpectedProcessIdentity(
            _ expected: ApplicationProcessIdentity?,
            actual: ApplicationProcessIdentity) throws
        {
            guard let expected, expected != actual else { return }
            throw DesktopTargetPlanningError.staleApplication(expected: expected)
        }

        private static func validated(_ identity: DesktopTargetIdentity) throws -> DesktopTargetIdentity {
            guard let validated = try DesktopTargetIdentityCoalescer.coalesce([identity]) else {
                preconditionFailure("A desktop target identity cannot normalize to missing evidence")
            }
            return validated
        }
    }
}
