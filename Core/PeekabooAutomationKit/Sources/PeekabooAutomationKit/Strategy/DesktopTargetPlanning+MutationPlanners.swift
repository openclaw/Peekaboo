import CoreGraphics
import Foundation
import PeekabooFoundation

extension DesktopTargetPlanning {
    public struct ApplicationMutationPlan: Equatable, Sendable {
        public let application: ServiceApplicationInfo
        public let processIdentity: ApplicationProcessIdentity
        public let selectorProof: SelectorResolutionProof

        public var target: String {
            "PID:\(self.processIdentity.processIdentifier)"
        }

        public var expectedTargetIdentity: DesktopTargetIdentity {
            get throws {
                try DesktopTargetIdentity(processIdentity: self.processIdentity)
            }
        }

        init(
            application: ServiceApplicationInfo,
            processIdentity: ApplicationProcessIdentity,
            selectorProof: SelectorResolutionProof)
        {
            self.application = application
            self.processIdentity = processIdentity
            self.selectorProof = selectorProof
        }
    }

    @MainActor
    public struct ApplicationMutationPlanner {
        public typealias InventoryProvider =
            @MainActor @Sendable () async throws -> Inventory<ServiceApplicationInfo>
        public typealias FrontmostProvider = @MainActor @Sendable () async throws -> ServiceApplicationInfo
        public typealias ExactIdentifierProvider =
            @MainActor @Sendable (_ identifier: String) async throws -> ServiceApplicationInfo

        private let inventoryProvider: InventoryProvider
        private let frontmostProvider: FrontmostProvider?
        private let exactIdentifierProvider: ExactIdentifierProvider?

        public init(applications: any ApplicationServiceProtocol) {
            self.inventoryProvider = {
                try await applications.mutationApplicationInventory()
            }
            self.frontmostProvider = {
                try await applications.getFrontmostApplication()
            }
            self.exactIdentifierProvider = { identifier in
                try await applications.findApplication(identifier: identifier)
            }
        }

        public init(
            inventoryProvider: @escaping InventoryProvider,
            frontmostProvider: FrontmostProvider? = nil,
            exactIdentifierProvider: ExactIdentifierProvider? = nil)
        {
            self.inventoryProvider = inventoryProvider
            self.frontmostProvider = frontmostProvider
            self.exactIdentifierProvider = exactIdentifierProvider
        }

        func plan(
            selector: InteractionTargetSelector,
            expectedIdentity: ApplicationProcessIdentity? = nil) async throws -> ApplicationMutationPlan
        {
            try await self.resolve(
                selector: selector,
                expectedIdentity: expectedIdentity,
                revalidateBeforeReturn: true)
        }

        public func plan(
            identifier: String,
            expectedIdentity: ApplicationProcessIdentity? = nil) async throws -> ApplicationMutationPlan
        {
            try await self.plan(
                selector: InteractionTargetSelector(applicationIdentifier: identifier),
                expectedIdentity: expectedIdentity)
        }

        public func plan(
            processIdentifier: Int32,
            expectedIdentity: ApplicationProcessIdentity? = nil) async throws -> ApplicationMutationPlan
        {
            try await self.plan(
                selector: InteractionTargetSelector(processIdentifier: Int(processIdentifier)),
                expectedIdentity: expectedIdentity)
        }

        public func revalidate(_ plan: ApplicationMutationPlan) async throws -> ApplicationMutationPlan {
            let originalIdentifier = plan.selectorProof.normalizedSelector
            let inventory: Inventory<ServiceApplicationInfo> = if let exactIdentifierProvider {
                try await .complete([self.exactApplication(
                    identifier: plan.target,
                    staleIdentity: plan.processIdentity,
                    provider: exactIdentifierProvider)])
            } else {
                try await self.applicationInventory(identifier: plan.target)
            }
            guard inventory.isComplete else {
                throw DesktopTargetPlanningError.incompleteApplicationInventory(
                    identifier: plan.target,
                    warnings: inventory.warnings)
            }
            let selection: ApplicationSelection
            do {
                selection = try ApplicationMutationSelector.select(
                    identifier: plan.target,
                    applications: inventory.items)
            } catch let error as DesktopTargetPlanningError {
                if case .applicationNotFound = error {
                    throw DesktopTargetPlanningError.staleApplication(expected: plan.processIdentity)
                }
                throw error
            }
            let application = inventory.items[selection.index]
            let identity = try Self.validatedIdentity(application)
            guard identity == plan.processIdentity,
                  plan.selectorProof.applicationMismatch(
                      identifier: originalIdentifier,
                      selectedCandidate: ApplicationIdentifierMatcher.Candidate(application),
                      processIdentity: identity) == nil
            else {
                throw DesktopTargetPlanningError.staleApplication(expected: plan.processIdentity)
            }
            return ApplicationMutationPlan(
                application: application,
                processIdentity: identity,
                selectorProof: plan.selectorProof)
        }

        func resolve(
            selector: InteractionTargetSelector,
            expectedIdentity: ApplicationProcessIdentity?,
            revalidateBeforeReturn: Bool) async throws -> ApplicationMutationPlan
        {
            do {
                try selector.validate(policy: .mutationSafe)
            } catch let error as InteractionTargetSelector.ValidationError {
                throw DesktopTargetPlanningError.invalidSelector(error)
            }
            guard selector.hasOwnerInput else {
                throw DesktopTargetPlanningError.missingApplicationTarget
            }
            let normalizedTarget = try selector.normalizedApplicationTarget(policy: .mutationSafe).map {
                try ApplicationMutationSelector.normalizedIdentifier($0)
            }
            let isExactPID = normalizedTarget?.uppercased().hasPrefix("PID:") == true
            let inventory: Inventory<ServiceApplicationInfo> = if let normalizedTarget,
                                                                  isExactPID,
                                                                  let exactIdentifierProvider
            {
                try await .complete([self.exactApplication(
                    identifier: normalizedTarget,
                    staleIdentity: expectedIdentity,
                    provider: exactIdentifierProvider)])
            } else {
                try await self.applicationInventory(identifier: normalizedTarget ?? "application target")
            }
            guard inventory.isComplete else {
                throw DesktopTargetPlanningError.incompleteApplicationInventory(
                    identifier: normalizedTarget ?? "application target",
                    warnings: inventory.warnings)
            }
            guard let normalizedTarget else {
                throw DesktopTargetPlanningError.missingApplicationTarget
            }
            let selection = try ApplicationMutationSelector.select(
                identifier: normalizedTarget,
                applications: inventory.items)
            let application = inventory.items[selection.index]
            let processIdentity = try Self.validatedIdentity(application)
            if let expectedIdentity, processIdentity != expectedIdentity {
                throw DesktopTargetPlanningError.staleApplication(expected: expectedIdentity)
            }
            let plan = ApplicationMutationPlan(
                application: application,
                processIdentity: processIdentity,
                selectorProof: selection.resolution.proof(selectedProcessIdentity: processIdentity))
            return if revalidateBeforeReturn {
                try await self.revalidate(plan)
            } else {
                plan
            }
        }

        func frontmost() async throws -> ServiceApplicationInfo {
            guard let frontmostProvider else {
                throw DesktopTargetPlanningError.unsupportedFrontmostTarget
            }
            return try await frontmostProvider()
        }

        private func exactApplication(
            identifier: String,
            staleIdentity: ApplicationProcessIdentity?,
            provider: ExactIdentifierProvider) async throws -> ServiceApplicationInfo
        {
            do {
                return try await provider(identifier)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as DesktopActionFailure {
                throw failure
            } catch let error as DesktopTargetPlanningError {
                throw error
            } catch let error as PeekabooError {
                guard case .appNotFound = error else {
                    throw DesktopTargetPlanningError.applicationInventoryUnavailable(identifier: identifier)
                }
                if let staleIdentity {
                    throw DesktopTargetPlanningError.staleApplication(expected: staleIdentity)
                }
                throw DesktopTargetPlanningError.applicationNotFound(
                    identifier: identifier,
                    candidatePIDs: [])
            } catch {
                throw DesktopTargetPlanningError.applicationInventoryUnavailable(identifier: identifier)
            }
        }

        private func applicationInventory(
            identifier: String) async throws -> Inventory<ServiceApplicationInfo>
        {
            do {
                return try await self.inventoryProvider()
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as DesktopActionFailure {
                throw failure
            } catch let error as DesktopTargetPlanningError {
                throw error
            } catch {
                throw DesktopTargetPlanningError.applicationInventoryUnavailable(identifier: identifier)
            }
        }

        static func validatedIdentity(
            _ application: ServiceApplicationInfo) throws -> ApplicationProcessIdentity
        {
            guard let identity = application.processIdentity else {
                throw DesktopTargetPlanningError.missingProcessIdentity(
                    processIdentifier: application.processIdentifier)
            }
            guard identity.processIdentifier > 0, identity.processStartIdentity > 0 else {
                throw DesktopTargetPlanningError.invalidProcessIdentity(
                    processIdentifier: identity.processIdentifier,
                    processStartIdentity: identity.processStartIdentity)
            }
            return identity
        }
    }

    public struct WindowMutationPlan: Equatable, Sendable {
        public let selectionWindow: ServiceWindowInfo
        public let identity: WindowMutationIdentity
        public let owner: ApplicationMutationPlan
        public let selection: WindowMutationSelection
        public let selectorProof: SelectorResolutionProof?

        public var target: WindowTarget {
            .windowId(self.identity.windowID)
        }

        public var expectedTargetIdentity: DesktopTargetIdentity {
            get throws {
                guard let bounds = self.identity.capturedBounds else {
                    throw DesktopTargetPlanningError.incompleteWindowIdentity(windowID: self.identity.windowID)
                }
                return try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                    identity: self.identity,
                    bounds: bounds))
            }
        }

        init(
            selectionWindow: ServiceWindowInfo,
            identity: WindowMutationIdentity,
            owner: ApplicationMutationPlan,
            selection: WindowMutationSelection,
            selectorProof: SelectorResolutionProof?)
        {
            self.selectionWindow = selectionWindow
            self.identity = identity
            self.owner = owner
            self.selection = selection
            self.selectorProof = selectorProof
        }
    }

    @MainActor
    public struct WindowMutationPlanner {
        public typealias WindowInventoryProvider =
            @MainActor @Sendable (_ target: WindowTarget) async throws -> Inventory<ServiceWindowInfo>

        private let applications: ApplicationMutationPlanner
        private let windowInventoryProvider: WindowInventoryProvider

        public init(
            applications: any ApplicationServiceProtocol,
            windows: any WindowManagementServiceProtocol)
        {
            self.applications = ApplicationMutationPlanner(applications: applications)
            self.windowInventoryProvider = { target in
                try await windows.mutationInventory(target: target)
            }
        }

        public init(
            applicationPlanner: ApplicationMutationPlanner,
            windowInventoryProvider: @escaping WindowInventoryProvider)
        {
            self.applications = applicationPlanner
            self.windowInventoryProvider = windowInventoryProvider
        }

        public func plan(
            selector: InteractionTargetSelector,
            automaticSelection: WindowSelectionPolicy = .preferredMutationWindow(.general)) async throws
            -> WindowMutationPlan
        {
            do {
                try selector.validate(policy: .mutationSafe)
            } catch let error as InteractionTargetSelector.ValidationError {
                throw DesktopTargetPlanningError.invalidSelector(error)
            }
            let windowSelector: InteractionTargetSelector.WindowSelector?
            do {
                windowSelector = try selector.normalizedWindowSelector(policy: .mutationSafe)
            } catch let error as InteractionTargetSelector.ValidationError {
                throw DesktopTargetPlanningError.invalidSelector(error)
            }

            var owner: ApplicationMutationPlan?
            if selector.hasOwnerInput {
                owner = try await self.applications.resolve(
                    selector: selector,
                    expectedIdentity: nil,
                    revalidateBeforeReturn: false)
            }

            let inventoryTarget: WindowTarget
            switch windowSelector {
            case let .id(windowID):
                inventoryTarget = .windowId(windowID)
            case .title, .index, nil:
                guard let owner else {
                    throw DesktopTargetPlanningError.missingApplicationTarget
                }
                inventoryTarget = .application(owner.target)
            }

            let selectorDescription = Self.selectorDescription(windowSelector)
            let inventory = try await self.windowInventory(
                target: inventoryTarget,
                expectedOwner: owner?.processIdentity,
                directSelectorDescription: {
                    if case .id = windowSelector {
                        return selectorDescription
                    }
                    return nil
                }())
            let isDirectWindowIDLookup = if case .id = windowSelector,
                                            case .windowId = inventoryTarget
            {
                true
            } else {
                false
            }
            guard inventory.isComplete || isDirectWindowIDLookup else {
                throw DesktopTargetPlanningError.incompleteWindowInventory(
                    selector: selectorDescription,
                    warnings: inventory.warnings)
            }
            let selected: ServiceWindowInfo
            do {
                selected = try WindowCandidateSelector.select(
                    candidates: inventory.items,
                    selector: windowSelector,
                    policy: windowSelector == nil ? automaticSelection : .explicit,
                    expectedOwner: owner?.processIdentity)
            } catch {
                if let owner {
                    _ = try await self.applications.revalidate(owner)
                }
                throw error
            }
            guard let selectedIdentity = selected.mutationIdentity else {
                throw DesktopTargetPlanningError.missingWindowIdentity(windowID: selected.windowID)
            }

            if owner == nil {
                owner = try await self.applications.resolve(
                    selector: InteractionTargetSelector(
                        processIdentifier: Int(selectedIdentity.ownerProcessIdentifier)),
                    expectedIdentity: selectedIdentity.processIdentity,
                    revalidateBeforeReturn: false)
            }
            guard let owner else {
                preconditionFailure("Window planning must resolve an owner")
            }
            let revalidatedOwner = try await self.applications.revalidate(owner)
            guard selectedIdentity.processIdentity == revalidatedOwner.processIdentity else {
                throw DesktopTargetPlanningError.windowOwnerMismatch(
                    windowID: selected.windowID,
                    expected: revalidatedOwner.processIdentity)
            }
            let selection = Self.windowSelection(for: windowSelector)
            let selectorProof = try Self.selectorProof(
                selection: selection,
                candidates: inventory.items,
                selected: selected,
                processIdentity: revalidatedOwner.processIdentity)

            return WindowMutationPlan(
                selectionWindow: selected,
                identity: selectedIdentity,
                owner: revalidatedOwner,
                selection: selection,
                selectorProof: selectorProof)
        }

        public func plan(
            target: WindowTarget,
            automaticSelection: WindowSelectionPolicy = .preferredMutationWindow(.general)) async throws
            -> WindowMutationPlan
        {
            switch target {
            case let .application(application):
                return try await self.plan(
                    selector: InteractionTargetSelector(applicationIdentifier: application),
                    automaticSelection: automaticSelection)
            case .title:
                throw DesktopTargetPlanningError.unsupportedGlobalWindowTitle
            case let .index(application, index):
                return try await self.plan(
                    selector: InteractionTargetSelector(
                        applicationIdentifier: application,
                        windowIndex: index),
                    automaticSelection: automaticSelection)
            case let .applicationAndTitle(application, title):
                return try await self.plan(
                    selector: InteractionTargetSelector(
                        applicationIdentifier: application,
                        windowTitle: title),
                    automaticSelection: automaticSelection)
            case let .windowId(windowID):
                return try await self.plan(
                    selector: InteractionTargetSelector(windowID: windowID),
                    automaticSelection: automaticSelection)
            case .frontmost:
                return try await self.planFrontmost(automaticSelection: automaticSelection)
            }
        }

        public func revalidate(_ plan: WindowMutationPlan) async throws -> WindowMutationPlan {
            let inventory: Inventory<ServiceWindowInfo>
            do {
                inventory = try await self.windowInventoryProvider(plan.target)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as DesktopActionFailure {
                throw failure
            } catch let error as DesktopTargetPlanningError {
                throw error
            } catch let error as PeekabooError {
                switch error {
                case .windowNotFound, .appNotFound, .snapshotStale:
                    throw DesktopTargetPlanningError.staleWindow(expected: plan.identity)
                default:
                    throw DesktopTargetPlanningError.windowInventoryUnavailable(
                        selector: Self.targetDescription(plan.target))
                }
            } catch {
                throw DesktopTargetPlanningError.windowInventoryUnavailable(
                    selector: Self.targetDescription(plan.target))
            }
            let selected: ServiceWindowInfo
            do {
                selected = try WindowCandidateSelector.select(
                    candidates: inventory.items,
                    selector: .id(plan.identity.windowID),
                    policy: .explicit,
                    expectedOwner: plan.owner.processIdentity)
            } catch let error as DesktopTargetPlanningError {
                switch error {
                case .windowNotFound, .windowOwnerMismatch:
                    throw DesktopTargetPlanningError.staleWindow(expected: plan.identity)
                default:
                    throw error
                }
            }
            guard let identity = selected.mutationIdentity,
                  identity.hasSameStableReceipt(as: plan.identity)
            else {
                throw DesktopTargetPlanningError.staleWindow(expected: plan.identity)
            }
            let owner = try await self.applications.revalidate(plan.owner)
            return WindowMutationPlan(
                selectionWindow: plan.selectionWindow,
                identity: identity,
                owner: owner,
                selection: plan.selection,
                selectorProof: plan.selectorProof)
        }

        private func planFrontmost(
            automaticSelection: WindowSelectionPolicy) async throws -> WindowMutationPlan
        {
            let frontmost = try await self.applications.frontmost()
            let identity = try ApplicationMutationPlanner.validatedIdentity(frontmost)
            let owner = try await self.applications.resolve(
                selector: InteractionTargetSelector(processIdentifier: Int(frontmost.processIdentifier)),
                expectedIdentity: identity,
                revalidateBeforeReturn: false)
            let inventory = try await self.windowInventory(
                target: .application(owner.target),
                expectedOwner: owner.processIdentity,
                directSelectorDescription: nil)
            guard inventory.isComplete else {
                throw DesktopTargetPlanningError.incompleteWindowInventory(
                    selector: "the frontmost application's best window",
                    warnings: inventory.warnings)
            }
            let selected = try WindowCandidateSelector.select(
                candidates: inventory.items,
                selector: nil,
                policy: automaticSelection,
                expectedOwner: identity)
            guard let selectedIdentity = selected.mutationIdentity else {
                throw DesktopTargetPlanningError.missingWindowIdentity(windowID: selected.windowID)
            }
            let revalidatedOwner = try await self.applications.revalidate(owner)
            let selection = WindowMutationSelection.automatic
            return WindowMutationPlan(
                selectionWindow: selected,
                identity: selectedIdentity,
                owner: revalidatedOwner,
                selection: selection,
                selectorProof: nil)
        }

        private static func selectorProof(
            selection: WindowMutationSelection,
            candidates: [ServiceWindowInfo],
            selected: ServiceWindowInfo,
            processIdentity: ApplicationProcessIdentity) throws -> SelectorResolutionProof?
        {
            let proofSelection: WindowSelection
            switch selection {
            case .automatic:
                return nil
            case let .id(windowID):
                proofSelection = .id(CGWindowID(windowID))
            case let .title(title):
                proofSelection = .title(title)
            case let .index(index):
                proofSelection = .index(index)
            }
            do {
                return try WindowSelectorResolutionProof.make(
                    selection: proofSelection,
                    candidates: WindowCandidateSelector.canonicalizedCandidates(candidates),
                    selected: selected,
                    processIdentity: processIdentity)
            } catch let error as WindowSelectorResolutionProof.ResolutionError {
                throw DesktopTargetPlanningError.invalidWindowInventory(
                    selector: Self.selectorDescription(selection),
                    reason: String(describing: error))
            } catch {
                throw DesktopTargetPlanningError.invalidWindowInventory(
                    selector: Self.selectorDescription(selection),
                    reason: "candidate evidence could not be encoded")
            }
        }

        private static func windowSelection(
            for selector: InteractionTargetSelector.WindowSelector?) -> WindowMutationSelection
        {
            switch selector {
            case let .id(windowID): .id(windowID)
            case let .title(title): .title(title)
            case let .index(index): .index(index)
            case nil: .automatic
            }
        }

        private static func selectorDescription(
            _ selector: InteractionTargetSelector.WindowSelector?) -> String
        {
            switch selector {
            case let .id(windowID):
                "window ID \(windowID)"
            case let .title(title):
                "window title '\(title)'"
            case let .index(index):
                "window index \(index)"
            case nil:
                "the application's best window"
            }
        }

        private static func selectorDescription(_ selection: WindowMutationSelection) -> String {
            switch selection {
            case let .id(windowID): "window ID \(windowID)"
            case let .title(title): "window title '\(title)'"
            case let .index(index): "window index \(index)"
            case .automatic: "the application's preferred mutation window"
            }
        }

        private func windowInventory(
            target: WindowTarget,
            expectedOwner: ApplicationProcessIdentity?,
            directSelectorDescription: String?) async throws -> Inventory<ServiceWindowInfo>
        {
            do {
                return try await self.windowInventoryProvider(target)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as DesktopActionFailure {
                throw failure
            } catch let error as DesktopTargetPlanningError {
                throw error
            } catch let error as PeekabooError {
                if case .windowNotFound = error, let directSelectorDescription {
                    throw DesktopTargetPlanningError.windowNotFound(
                        selector: directSelectorDescription,
                        candidateWindowIDs: [])
                }
                if let expectedOwner {
                    switch error {
                    case .appNotFound, .snapshotStale:
                        throw DesktopTargetPlanningError.staleApplication(expected: expectedOwner)
                    default:
                        break
                    }
                }
                throw DesktopTargetPlanningError.windowInventoryUnavailable(
                    selector: Self.targetDescription(target))
            } catch {
                throw DesktopTargetPlanningError.windowInventoryUnavailable(
                    selector: Self.targetDescription(target))
            }
        }

        private static func targetDescription(_ target: WindowTarget) -> String {
            switch target {
            case let .application(application): "application '\(application)'"
            case let .title(title): "window title '\(title)'"
            case let .index(application, index): "window index \(index) for '\(application)'"
            case let .applicationAndTitle(application, title): "window title '\(title)' for '\(application)'"
            case let .windowId(windowID): "window ID \(windowID)"
            case .frontmost: "frontmost window"
            }
        }
    }
}
