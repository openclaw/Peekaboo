import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

/// The exact desktop target authorized by the background policy immediately before leaf dispatch.
///
/// Tool arguments retain compatibility selectors such as `PID:<n>`, but those selectors cannot carry a process
/// generation. Mutation leaves must therefore coalesce the target they resolve with this task-local authority before
/// dispatching. A reused PID or window ID then fails closed instead of silently retargeting the replacement process.
struct AuthorizedDesktopTargetPlan: Sendable, Equatable {
    let targetIdentity: DesktopTargetIdentity
    let selectedWindow: ServiceWindowInfo?
    let mutationAuthority: DesktopTargetPlanning.MutationAuthorityPlan?

    init(
        targetIdentity: DesktopTargetIdentity,
        selectedWindow: ServiceWindowInfo? = nil)
    {
        self.targetIdentity = targetIdentity
        self.selectedWindow = selectedWindow
        self.mutationAuthority = nil
    }

    init(mutationAuthority: DesktopTargetPlanning.MutationAuthorityPlan) throws {
        self.targetIdentity = try mutationAuthority.targetIdentity
        self.selectedWindow = mutationAuthority.window?.selectionWindow
        self.mutationAuthority = mutationAuthority
    }

    @TaskLocal
    static var current: AuthorizedDesktopTargetPlan?

    var processIdentity: ApplicationProcessIdentity {
        self.targetIdentity.processIdentity
    }

    func requireExactWindow(operation: String) throws -> UIAutomationTarget.ExactWindow {
        guard let exactWindow = self.targetIdentity.exactWindow else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "\(operation) requires an authorized exact-window target.",
                hint: "Select the window by ID after refreshing the window inventory.")
        }
        return exactWindow
    }

    func requireSelectedWindow(operation: String) throws -> ServiceWindowInfo {
        let exactWindow = try self.requireExactWindow(operation: operation)
        guard let selectedWindow,
              selectedWindow.windowID == exactWindow.identity.windowID,
              let selectedIdentity = selectedWindow.mutationIdentity,
              selectedIdentity.hasSameStableReceipt(as: exactWindow.identity),
              selectedIdentity.capturedBounds == selectedWindow.bounds,
              selectedWindow.bounds == exactWindow.bounds
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "\(operation) lost its authorized exact-window inventory record.",
                hint: "Refresh the window inventory before retrying.")
        }
        return selectedWindow
    }

    func coalescing(
        _ candidate: DesktopTargetIdentity,
        operation: String) throws -> DesktopTargetIdentity
    {
        do {
            return try self.targetIdentity.coalescing(candidate)
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "\(operation) target changed after background authorization.",
                hint: "Refresh the target inventory before retrying.",
                causeDescription: error.localizedDescription)
        }
    }
}

extension MCPToolContext {
    /// Returns the task-local target for a background mutation, or nil for an unrestricted execution.
    func authorizedDesktopTargetPlan(operation: String) throws -> AuthorizedDesktopTargetPlan? {
        guard self.executionPolicy == .backgroundOnly else { return nil }
        guard let plan = AuthorizedDesktopTargetPlan.current else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "\(operation) reached its mutation leaf without background target authority.",
                hint: "Dispatch the tool through MCPToolContext so target authorization can be retained.")
        }
        return plan
    }

    /// Refines a leaf-resolved target with the generation-pinned background authority when one is required.
    func coalesceAuthorizedDesktopTarget(
        _ candidate: DesktopTargetIdentity,
        operation: String) throws -> DesktopTargetIdentity
    {
        guard let plan = try self.authorizedDesktopTargetPlan(operation: operation) else { return candidate }
        return try plan.coalescing(candidate, operation: operation)
    }
}
