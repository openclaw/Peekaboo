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
public final class DockService: DockServiceProtocol {
    let feedbackClient: any AutomationFeedbackClient
    let logger = Logger(subsystem: "boo.peekaboo.core", category: "DockService")
    let operationLaneCoordinator: DesktopOperationLaneCoordinator

    public convenience init(feedbackClient: any AutomationFeedbackClient = NoopAutomationFeedbackClient()) {
        self.init(feedbackClient: feedbackClient, operationLaneCoordinator: .shared)
    }

    init(
        feedbackClient: any AutomationFeedbackClient = NoopAutomationFeedbackClient(),
        operationLaneCoordinator: DesktopOperationLaneCoordinator)
    {
        self.feedbackClient = feedbackClient
        self.operationLaneCoordinator = operationLaneCoordinator
        Task { @MainActor in
            self.feedbackClient.connect()
        }
    }

    public func listDockItems(includeAll: Bool = false) async throws -> [DockItem] {
        try await self.listDockItemsImpl(includeAll: includeAll)
    }

    public func launchFromDock(appName: String) async throws {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            try await self.launchFromDockImpl(appName: appName)
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
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            try await self.rightClickDockItemImpl(appName: appName, menuItem: menuItem)
        }
    }

    public func hideDock() async throws {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            try await self.hideDockImpl()
        }
    }

    public func showDock() async throws {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            try await self.showDockImpl()
        }
    }

    public func isDockAutoHidden() async -> Bool {
        await self.isDockAutoHiddenImpl()
    }

    public func findDockItem(name: String) async throws -> DockItem {
        try await self.findDockItemImpl(name: name)
    }
}
