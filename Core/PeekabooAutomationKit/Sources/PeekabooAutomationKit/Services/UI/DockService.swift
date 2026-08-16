import AppKit
import Foundation
import os
import PeekabooFoundation

/// Dock-specific errors
public enum DockError: LocalizedError {
    case dockNotFound
    case dockListNotFound
    case itemNotFound(String)
    case menuItemNotFound(String)
    case positionNotFound
    case launchFailed(String)
    case scriptError(String)

    public var errorDescription: String? {
        switch self {
        case .dockNotFound:
            "Dock not found"
        case .dockListNotFound:
            "Dock list not found"
        case let .itemNotFound(name):
            "Dock item not found: \(name)"
        case let .menuItemNotFound(name):
            "Dock menu item not found: \(name)"
        case .positionNotFound:
            "Dock item position not found"
        case let .launchFailed(message):
            "Failed to launch Dock item: \(message)"
        case let .scriptError(message):
            "Dock script failed: \(message)"
        }
    }
}

/// Default implementation of Dock interaction operations using AXorcist
@MainActor
public final class DockService: DockServiceProtocol, DockServiceActionResultProviding {
    let feedbackClient: any AutomationFeedbackClient
    let logger = Logger(subsystem: "boo.peekaboo.core", category: "DockService")
    let operationLaneCoordinator: DesktopOperationLaneCoordinator
    let dockVisibilityCommandRunner: DockVisibilityCommandRunner

    public convenience init(feedbackClient: any AutomationFeedbackClient = NoopAutomationFeedbackClient()) {
        self.init(feedbackClient: feedbackClient, operationLaneCoordinator: .shared)
    }

    init(
        feedbackClient: any AutomationFeedbackClient = NoopAutomationFeedbackClient(),
        operationLaneCoordinator: DesktopOperationLaneCoordinator,
        dockVisibilityCommandRunner: @escaping DockVisibilityCommandRunner = DockService.executeDockVisibilityCommand)
    {
        self.feedbackClient = feedbackClient
        self.operationLaneCoordinator = operationLaneCoordinator
        self.dockVisibilityCommandRunner = dockVisibilityCommandRunner
        Task { @MainActor in
            self.feedbackClient.connect()
        }
    }

    public func listDockItems(includeAll: Bool = false) async throws -> [DockItem] {
        try await self.listDockItemsImpl(includeAll: includeAll)
    }

    public func launchFromDock(appName: String) async throws {
        _ = try await self.launchFromDockActionResult(appName: appName)
    }

    public func launchFromDockActionResult(appName: String) async throws -> UIAutomationActionResult<Void> {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            let target = try self.resolveDockElement(appName: appName)
            let selectedLeafEvidence = try await Self.withDockFailureAttribution(
                processIdentity: target.identity,
                selectedLeafEvidence: [target.evidence])
            {
                try await self.launchFromDockImpl(target: target, appName: appName)
            }
            return try UIAutomationActionResult(
                payload: (),
                outcome: .dispatchedUnverified(
                    delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                    evidence: .deliveryAccepted,
                    unitCount: .one),
                targetIdentity: DesktopTargetIdentity(processIdentity: target.identity),
                selectedLeafEvidence: [selectedLeafEvidence])
        }
    }

    public func addToDock(path: String, persistent: Bool = true) async throws {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            try await self.addToDockImpl(path: path, persistent: persistent)
        }
    }

    public func removeFromDock(appName: String) async throws {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            try await self.removeFromDockImpl(appName: appName)
        }
    }

    public func rightClickDockItem(appName: String, menuItem: String?) async throws {
        _ = try await self.rightClickDockItemActionResult(appName: appName, menuItem: menuItem)
    }

    public func rightClickDockItemActionResult(
        appName: String,
        menuItem: String?) async throws -> UIAutomationActionResult<Void>
    {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            let target = try self.resolveDockElement(appName: appName)
            let selectedLeafEvidence = try await Self.withDockFailureAttribution(
                processIdentity: target.identity,
                selectedLeafEvidence: [target.evidence])
            {
                try await self.rightClickDockItemImpl(target: target, appName: appName, menuItem: menuItem)
            }
            return try UIAutomationActionResult(
                payload: (),
                outcome: DockContextMenuActionSemantics.successfulOutcome(
                    selectingMenuItem: menuItem != nil),
                targetIdentity: DesktopTargetIdentity(processIdentity: target.identity),
                selectedLeafEvidence: selectedLeafEvidence)
        }
    }

    public func hideDock() async throws {
        _ = try await self.hideDockActionResult()
    }

    public func showDock() async throws {
        _ = try await self.showDockActionResult()
    }

    public func isDockAutoHidden() async -> Bool {
        await self.isDockAutoHiddenImpl()
    }

    public func findDockItem(name: String) async throws -> DockItem {
        try await self.findDockItemImpl(name: name)
    }

    static func withDockFailureAttribution<Result>(
        processIdentity: ApplicationProcessIdentity,
        selectedLeafEvidence: [DesktopSelectedLeafEvidence]? = nil,
        operation: () async throws -> Result) async throws -> Result
    {
        do {
            return try await operation()
        } catch let failure as DesktopActionFailure {
            let combinedEvidence = (selectedLeafEvidence ?? []) + (failure.selectedLeafEvidence ?? [])
            throw failure
                .attributed(to: processIdentity)
                .selectingLeaves(combinedEvidence.isEmpty ? nil : combinedEvidence)
        }
    }
}
