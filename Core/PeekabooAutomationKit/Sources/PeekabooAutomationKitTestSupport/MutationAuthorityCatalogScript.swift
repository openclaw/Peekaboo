import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

/// Instance-owned complete/partial catalog sequence for mutation-authority tests.
@MainActor
public final class MutationAuthorityCatalogScript {
    public private(set) var applicationInventoryRequestCount = 0
    public private(set) var exactApplicationRequests: [String] = []
    public private(set) var windowInventoryTargets: [WindowTarget] = []

    private let applicationInventories: [DesktopTargetPlanning.Inventory<ServiceApplicationInfo>]
    private let windowInventories: [DesktopTargetPlanning.Inventory<ServiceWindowInfo>]
    private var applicationInventoryIndex = 0
    private var windowInventoryIndex = 0
    private var currentApplications: [ServiceApplicationInfo]

    public init(
        applicationInventories: [DesktopTargetPlanning.Inventory<ServiceApplicationInfo>],
        windowInventories: [DesktopTargetPlanning.Inventory<ServiceWindowInfo>])
    {
        self.applicationInventories = applicationInventories
        self.windowInventories = windowInventories
        self.currentApplications = applicationInventories.first?.items ?? []
    }

    public convenience init(
        applications: [ServiceApplicationInfo],
        windowInventories: [DesktopTargetPlanning.Inventory<ServiceWindowInfo>])
    {
        self.init(
            applicationInventories: [.complete(applications)],
            windowInventories: windowInventories)
    }

    public func planner() -> DesktopTargetPlanning.MutationAuthorityPlanner {
        let applicationPlanner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { [self] in self.nextApplicationInventory() },
            exactIdentifierProvider: { [self] identifier in
                try self.exactApplication(identifier: identifier)
            })
        let windowProvider: DesktopTargetPlanning.WindowMutationPlanner.WindowInventoryProvider = { [self] target in
            self.nextWindowInventory(target: target)
        }
        return DesktopTargetPlanning.MutationAuthorityPlanner(
            applicationPlanner: applicationPlanner,
            windowPlanner: DesktopTargetPlanning.WindowMutationPlanner(
                applicationPlanner: applicationPlanner,
                windowInventoryProvider: windowProvider))
    }

    private func nextApplicationInventory() -> DesktopTargetPlanning.Inventory<ServiceApplicationInfo> {
        self.applicationInventoryRequestCount += 1
        let inventory = Self.step(self.applicationInventories, index: &self.applicationInventoryIndex)
        self.currentApplications = inventory.items
        return inventory
    }

    private func nextWindowInventory(
        target: WindowTarget) -> DesktopTargetPlanning.Inventory<ServiceWindowInfo>
    {
        self.windowInventoryTargets.append(target)
        return Self.step(self.windowInventories, index: &self.windowInventoryIndex)
    }

    private func exactApplication(identifier: String) throws -> ServiceApplicationInfo {
        self.exactApplicationRequests.append(identifier)
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = normalized.uppercased().hasPrefix("PID:")
            ? Int32(normalized.dropFirst(4))
            : nil
        let matches = self.currentApplications.filter { application in
            pid.map { application.processIdentifier == $0 } == true ||
                application.bundleIdentifier?.caseInsensitiveCompare(normalized) == .orderedSame ||
                application.name.caseInsensitiveCompare(normalized) == .orderedSame
        }
        guard matches.count == 1, let application = matches.first else {
            throw PeekabooError.appNotFound(identifier)
        }
        return application
    }

    private static func step<Element: Sendable>(
        _ steps: [DesktopTargetPlanning.Inventory<Element>],
        index: inout Int) -> DesktopTargetPlanning.Inventory<Element>
    {
        guard !steps.isEmpty else { return .complete([]) }
        let selected = steps[min(index, steps.count - 1)]
        index += 1
        return selected
    }
}
