//
//  MenuService+Models.swift
//  PeekabooCore
//

import Foundation
import os
import PeekabooFoundation

private let menuClock = ContinuousClock()

@_spi(Testing) public struct MenuTraversalLimits: Sendable {
    public let maxDepth: Int
    public let maxChildren: Int
    public let timeBudget: TimeInterval

    public init(maxDepth: Int, maxChildren: Int, timeBudget: TimeInterval) {
        self.maxDepth = maxDepth
        self.maxChildren = maxChildren
        self.timeBudget = timeBudget
    }

    @_spi(Testing) public static func from(policy: SearchPolicy) -> MenuTraversalLimits {
        switch policy {
        case .balanced:
            MenuTraversalLimits(maxDepth: 8, maxChildren: 500, timeBudget: 3.0)
        case .debug:
            MenuTraversalLimits(maxDepth: 16, maxChildren: 1500, timeBudget: 10.0)
        }
    }
}

@_spi(Testing) public struct MenuTraversalBudget {
    private(set) var visitedChildren: Int = 0
    private let startInstant = menuClock.now
    let limits: MenuTraversalLimits

    public init(limits: MenuTraversalLimits) {
        self.limits = limits
    }

    @_spi(Testing) public mutating func allowVisit(depth: Int, logger: Logger, context: String) -> Bool {
        let elapsed: Duration = menuClock.now - self.startInstant
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) /
            1_000_000_000_000_000_000
        let budget = self.limits.timeBudget
        guard elapsedSeconds <= budget else {
            let elapsedText = String(format: "%.2f", elapsedSeconds)
            logger.warning("Menu traversal aborted after \(elapsedText)s (budget: \(budget)s) @\(context)")
            return false
        }

        let maxDepth = self.limits.maxDepth
        guard depth <= maxDepth else {
            logger.warning("Menu traversal depth \(depth) exceeded limit \(maxDepth) @\(context)")
            return false
        }

        let maxChildren = self.limits.maxChildren
        let seen = self.visitedChildren
        guard seen < maxChildren else {
            logger.warning("Menu traversal halted after \(seen) children (max: \(maxChildren)) @\(context)")
            return false
        }

        self.visitedChildren += 1
        return true
    }
}

struct MenuTraversalContext {
    var menuPath: [String]
    let fullPath: String
    let appInfo: ServiceApplicationInfo
    let processIdentity: ApplicationProcessIdentity
    let delivery: DesktopActionOutcome.Delivery
    var budget: MenuTraversalBudget
    var submittedUnitCount: Int = 0
}
