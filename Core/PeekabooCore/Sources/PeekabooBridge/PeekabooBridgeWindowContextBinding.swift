import Foundation
import PeekabooAutomationKit

enum PeekabooBridgeWindowContextBinding {
    private static let defaultAccessibilityTimeoutSeconds: TimeInterval = 20

    static func matches(_ actual: WindowContext?, requested: WindowContext?) -> Bool {
        guard let requested else { return actual == nil }
        guard let actual else { return false }
        return actual.applicationName == requested.applicationName &&
            actual.applicationBundleId == requested.applicationBundleId &&
            actual.applicationBundlePath == requested.applicationBundlePath &&
            actual.applicationExecutablePath == requested.applicationExecutablePath &&
            actual.applicationProcessId == requested.applicationProcessId &&
            actual.windowTitle == requested.windowTitle &&
            actual.windowID == requested.windowID &&
            actual.windowBounds == requested.windowBounds &&
            actual.windowMutationIdentity == requested.windowMutationIdentity &&
            actual.focusedElement == requested.focusedElement &&
            actual.shouldFocusWebContent == requested.shouldFocusWebContent &&
            actual.includeMenuBarElements == requested.includeMenuBarElements &&
            actual.traversalBudget == requested.traversalBudget &&
            actual.requiresFreshAccessibilityTree == requested.requiresFreshAccessibilityTree &&
            actual.accessibilityTimeoutSeconds == requested.accessibilityTimeoutSeconds
    }

    static func refines(_ actual: WindowContext?, requested: WindowContext?) -> Bool {
        guard let requested else { return actual == nil }
        guard let actual else { return false }
        return self.applicationSelector(in: requested, matches: actual) &&
            self.satisfies(requested.applicationBundlePath, with: actual.applicationBundlePath) &&
            self.satisfies(requested.applicationExecutablePath, with: actual.applicationExecutablePath) &&
            self.satisfies(requested.applicationProcessId, with: actual.applicationProcessId) &&
            self.windowTitle(actual.windowTitle, matches: requested.windowTitle) &&
            self.satisfies(requested.windowID, with: actual.windowID) &&
            self.satisfies(requested.windowBounds, with: actual.windowBounds) &&
            self.satisfies(requested.windowMutationIdentity, with: actual.windowMutationIdentity) &&
            self.satisfies(requested.focusedElement, with: actual.focusedElement) &&
            self.satisfies(
                requested.shouldFocusWebContent,
                with: actual.shouldFocusWebContent,
                defaultingTo: false) &&
            self.satisfies(
                requested.includeMenuBarElements,
                with: actual.includeMenuBarElements,
                defaultingTo: true) &&
            self.traversalBudget(actual.traversalBudget, matches: requested.traversalBudget) &&
            self.satisfies(
                requested.requiresFreshAccessibilityTree,
                with: actual.requiresFreshAccessibilityTree,
                defaultingTo: false) &&
            self.satisfies(
                requested.accessibilityTimeoutSeconds,
                with: actual.accessibilityTimeoutSeconds,
                defaultingTo: self.defaultAccessibilityTimeoutSeconds)
    }

    private static func satisfies<Value: Equatable>(_ constraint: Value?, with actual: Value?) -> Bool {
        constraint.map { $0 == actual } ?? true
    }

    private static func satisfies<Value: Equatable>(
        _ constraint: Value?,
        with actual: Value?,
        defaultingTo defaultValue: Value) -> Bool
    {
        if let constraint {
            return actual == constraint
        }
        return actual == nil || actual == defaultValue
    }

    private static func applicationSelector(in requested: WindowContext, matches actual: WindowContext) -> Bool {
        if let bundleIdentifier = requested.applicationBundleId,
           actual.applicationBundleId != bundleIdentifier
        {
            return false
        }
        guard let identifier = requested.applicationName else { return true }
        guard let processIdentifier = actual.applicationProcessId, processIdentifier > 0 else { return false }
        let name = actual.applicationName ?? actual.applicationBundleId ?? "PID:\(processIdentifier)"
        return ApplicationIdentifierMatcher.matches(
            .init(
                processIdentifier: processIdentifier,
                bundleIdentifier: actual.applicationBundleId,
                name: name,
                bundlePath: actual.applicationBundlePath,
                executablePath: actual.applicationExecutablePath,
                allowsFuzzyMatching: true,
                isRegularApplication: true),
            identifier: identifier)
    }

    private static func windowTitle(_ actual: String?, matches requested: String?) -> Bool {
        guard let requested else { return true }
        guard let actual else { return false }
        return actual.localizedCaseInsensitiveCompare(requested) == .orderedSame ||
            (!requested.isEmpty && actual.localizedCaseInsensitiveContains(requested))
    }

    private static func traversalBudget(_ actual: AXTraversalBudget?, matches requested: AXTraversalBudget?) -> Bool {
        if let requested {
            return actual == AXTraversalBudget(
                maxDepth: max(0, requested.maxDepth),
                maxElementCount: max(0, requested.maxElementCount),
                maxChildrenPerNode: max(0, requested.maxChildrenPerNode))
        }
        guard let actual else { return true }
        return actual.maxDepth > 0 && actual.maxElementCount > 0 && actual.maxChildrenPerNode > 0
    }
}
