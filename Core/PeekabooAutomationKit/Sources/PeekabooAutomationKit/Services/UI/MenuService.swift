//
//  MenuService.swift
//  PeekabooCore
//

import AppKit
import AXorcist
import CoreFoundation
import CoreGraphics
import Foundation
import os
import PeekabooFoundation

@MainActor
public final class MenuService: MenuServiceProtocol, MenuServiceGenerationPinnedActionResultProviding,
    MenuServiceGenerationPinnedMenuBarActionResultProviding, MenuServiceExactLeafActionResultProviding
{
    let applicationService: any ApplicationServiceProtocol
    let logger: Logger
    let feedbackClient: any AutomationFeedbackClient
    let operationLaneCoordinator: DesktopOperationLaneCoordinator

    // Traversal limits to avoid unbounded menu walks
    let traversalLimits: MenuTraversalLimits
    let partialMatchEnabled: Bool
    let cacheTTL: TimeInterval
    var menuCache: [String: (expiresAt: Date, structure: MenuStructure)] = [:]

    public convenience init(
        applicationService: (any ApplicationServiceProtocol)? = nil,
        traversalPolicy: SearchPolicy = .balanced,
        logger: Logger = Logger(subsystem: "boo.peekaboo.core", category: "MenuService"),
        feedbackClient: any AutomationFeedbackClient = NoopAutomationFeedbackClient(),
        partialMatchEnabled: Bool = true,
        cacheTTL: TimeInterval = 2.0)
    {
        self.init(
            applicationService: applicationService,
            traversalPolicy: traversalPolicy,
            logger: logger,
            feedbackClient: feedbackClient,
            partialMatchEnabled: partialMatchEnabled,
            cacheTTL: cacheTTL,
            operationLaneCoordinator: .shared)
    }

    init(
        applicationService: (any ApplicationServiceProtocol)? = nil,
        traversalPolicy: SearchPolicy = .balanced,
        logger: Logger = Logger(subsystem: "boo.peekaboo.core", category: "MenuService"),
        feedbackClient: any AutomationFeedbackClient = NoopAutomationFeedbackClient(),
        partialMatchEnabled: Bool = true,
        cacheTTL: TimeInterval = 2.0,
        operationLaneCoordinator: DesktopOperationLaneCoordinator)
    {
        self.applicationService = applicationService ?? ApplicationService()
        self.traversalLimits = MenuTraversalLimits.from(policy: traversalPolicy)
        self.logger = logger
        self.feedbackClient = feedbackClient
        self.partialMatchEnabled = partialMatchEnabled
        self.cacheTTL = cacheTTL
        self.operationLaneCoordinator = operationLaneCoordinator
        self.connectFeedbackIfNeeded()
    }

    private func connectFeedbackIfNeeded() {
        let isMacApp = Bundle.main.bundleIdentifier?.hasPrefix("boo.peekaboo.mac") == true
        if !isMacApp {
            self.logger.debug("Connecting to visualizer service (running as CLI/external tool)")
            self.feedbackClient.connect()
        } else {
            self.logger.debug("Skipping visualizer connection (running inside Mac app)")
        }
    }

    #if DEBUG
    @_spi(Testing) public func seedMenuCacheForTesting(
        appId: String,
        expiresAt: Date,
        structure: MenuStructure)
    {
        self.menuCache[appId] = (expiresAt: expiresAt, structure: structure)
    }

    public func clearMenuCache() {
        self.menuCache.removeAll()
    }
    #endif
}
