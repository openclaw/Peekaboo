import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

/// Instance-owned responses for an outcome-capable automation test double.
@MainActor
public final class UIAutomationOutcomeScript {
    public enum Operation: String, CaseIterable, Sendable {
        case click
        case type
        case typeActions
        case scroll
        case hotkey
        case setValue
        case performAction
    }

    /// A failure is a pre-dispatch refusal. The default implementations below do not call the
    /// wrapped legacy operation after consuming one.
    public enum Response {
        case outcome(DesktopActionOutcome?)
        case failure(any Error)
    }

    private var responses: [Operation: [Response]]
    private var defaultResponse: Response
    private var callCounts: [Operation: Int] = [:]

    public init(
        responses: [Operation: [Response]] = [:],
        defaultResponse: Response = .outcome(nil))
    {
        self.responses = responses
        self.defaultResponse = defaultResponse
    }

    public convenience init(
        outcomes: [Operation: [DesktopActionOutcome?]],
        defaultOutcome: DesktopActionOutcome? = nil)
    {
        self.init(
            responses: outcomes.mapValues { $0.map(Response.outcome) },
            defaultResponse: .outcome(defaultOutcome))
    }

    public func append(_ response: Response, for operation: Operation) {
        self.responses[operation, default: []].append(response)
    }

    public func append(_ outcome: DesktopActionOutcome?, for operation: Operation) {
        self.append(.outcome(outcome), for: operation)
    }

    public func appendFailure(_ error: any Error, for operation: Operation) {
        self.append(.failure(error), for: operation)
    }

    public func setDefaultResponse(_ response: Response) {
        self.defaultResponse = response
    }

    public func setDefaultOutcome(_ outcome: DesktopActionOutcome?) {
        self.setDefaultResponse(.outcome(outcome))
    }

    public func callCount(for operation: Operation) -> Int {
        self.callCounts[operation, default: 0]
    }

    public var totalCallCount: Int {
        self.callCounts.values.reduce(0, +)
    }

    public func remainingResponseCount(for operation: Operation) -> Int {
        self.responses[operation]?.count ?? 0
    }

    func nextOutcome(for operation: Operation) throws -> DesktopActionOutcome? {
        self.callCounts[operation, default: 0] += 1
        let response = self.popResponse(for: operation)

        switch response {
        case let .outcome(outcome):
            return outcome
        case let .failure(error):
            throw error
        }
    }

    private func popResponse(for operation: Operation) -> Response {
        guard var queuedResponses = self.responses[operation], !queuedResponses.isEmpty else {
            return self.defaultResponse
        }
        let response = queuedResponses.removeFirst()
        self.responses[operation] = queuedResponses
        return response
    }
}

/// Test-only default implementations for the complete action-outcome capability.
///
/// Targeted overloads dynamically require the matching legacy capability. They never fall back to
/// a foreground or less-specific overload when the requested target cannot be preserved.
@MainActor
public protocol ScriptedUIAutomationActionOutcomeProviding: UIAutomationActionOutcomeProviding {
    var uiAutomationOutcomeScript: UIAutomationOutcomeScript { get }
}

extension ScriptedUIAutomationActionOutcomeProviding {
    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?) async throws -> UIAutomationActionResult<Void>
    {
        let outcome = try self.uiAutomationOutcomeScript.nextOutcome(for: .click)
        try await self.click(target: target, clickType: clickType, snapshotId: snapshotId)
        return UIAutomationActionResult(payload: (), outcome: outcome)
    }

    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws -> UIAutomationActionResult<Void>
    {
        guard let service = self as? any TargetedClickServiceProtocol,
              service.supportsTargetedClicks
        else {
            throw PeekabooError.serviceUnavailable(
                self.targetedCapabilityReason(
                    (self as? any TargetedClickServiceProtocol)?.targetedClickUnavailableReason,
                    fallback: "This automation test double does not support process-targeted clicks"))
        }
        let outcome = try self.uiAutomationOutcomeScript.nextOutcome(for: .click)
        try await service.click(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier)
        return UIAutomationActionResult(payload: (), outcome: outcome)
    }

    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<Void>
    {
        guard let service = self as? any TargetedClickServiceProtocol,
              service.supportsTargetedClicks,
              service.supportsProcessGenerationPinnedClicks
        else {
            throw PeekabooError.serviceUnavailable(
                self.targetedCapabilityReason(
                    (self as? any TargetedClickServiceProtocol)?.targetedClickUnavailableReason,
                    fallback: "This automation test double does not support process-generation-pinned clicks"))
        }
        let outcome = try self.uiAutomationOutcomeScript.nextOutcome(for: .click)
        try await service.click(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            expectedProcessIdentity: expectedProcessIdentity)
        return UIAutomationActionResult(payload: (), outcome: outcome)
    }

    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<Void>
    {
        guard let service = self as? any ExactWindowTargetedClickServiceProtocol,
              service.supportsExactWindowTargetedClicks
        else {
            throw PeekabooError.serviceUnavailable(
                self.targetedCapabilityReason(
                    (self as? any TargetedClickServiceProtocol)?.targetedClickUnavailableReason,
                    fallback: "This automation test double does not support exact-window clicks"))
        }
        let outcome = try self.uiAutomationOutcomeScript.nextOutcome(for: .click)
        try await service.click(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds)
        return UIAutomationActionResult(payload: (), outcome: outcome)
    }

    public func typeWithOutcome(
        text: String,
        target: String?,
        clearExisting: Bool,
        typingDelay: Int,
        snapshotId: String?) async throws -> UIAutomationActionResult<Void>
    {
        let outcome = try self.uiAutomationOutcomeScript.nextOutcome(for: .type)
        try await self.type(
            text: text,
            target: target,
            clearExisting: clearExisting,
            typingDelay: typingDelay,
            snapshotId: snapshotId)
        return UIAutomationActionResult(payload: (), outcome: outcome)
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?) async throws -> UIAutomationActionResult<TypeResult>
    {
        let outcome = try self.uiAutomationOutcomeScript.nextOutcome(for: .typeActions)
        let payload = try await self.typeActions(actions, cadence: cadence, snapshotId: snapshotId)
        return UIAutomationActionResult(payload: payload, outcome: outcome)
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws -> UIAutomationActionResult<TypeResult>
    {
        guard let service = self as? any TargetedTypeServiceProtocol,
              service.supportsTargetedTypeActions
        else {
            throw PeekabooError.serviceUnavailable(
                self.targetedCapabilityReason(
                    (self as? any TargetedTypeServiceProtocol)?.targetedTypeUnavailableReason,
                    fallback: "This automation test double does not support process-targeted typing"))
        }
        let outcome = try self.uiAutomationOutcomeScript.nextOutcome(for: .typeActions)
        let payload = try await service.typeActions(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier)
        return UIAutomationActionResult(payload: payload, outcome: outcome)
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<TypeResult>
    {
        guard let service = self as? any TargetedTypeServiceProtocol,
              service.supportsTargetedTypeActions,
              service.supportsProcessGenerationPinnedTypeActions
        else {
            throw PeekabooError.serviceUnavailable(
                self.targetedCapabilityReason(
                    (self as? any TargetedTypeServiceProtocol)?.targetedTypeUnavailableReason,
                    fallback: "This automation test double does not support process-generation-pinned typing"))
        }
        let outcome = try self.uiAutomationOutcomeScript.nextOutcome(for: .typeActions)
        let payload = try await service.typeActions(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            expectedProcessIdentity: expectedProcessIdentity)
        return UIAutomationActionResult(payload: payload, outcome: outcome)
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<TypeResult>
    {
        let service = try self.exactWindowKeyboardService(for: "typing")
        let outcome = try self.uiAutomationOutcomeScript.nextOutcome(for: .typeActions)
        let payload = try await service.typeActions(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds)
        return UIAutomationActionResult(payload: payload, outcome: outcome)
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        target: ExactWindowKeyboardTarget) async throws -> UIAutomationActionResult<TypeResult>
    {
        let service = try self.exactWindowKeyboardService(for: "typing")
        let outcome = try self.uiAutomationOutcomeScript.nextOutcome(for: .typeActions)
        let payload = try await service.typeActions(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            target: target)
        return UIAutomationActionResult(payload: payload, outcome: outcome)
    }

    public func scrollWithOutcome(_ request: ScrollRequest) async throws -> UIAutomationActionResult<Void> {
        let outcome = try self.uiAutomationOutcomeScript.nextOutcome(for: .scroll)
        try await self.scroll(request)
        return UIAutomationActionResult(payload: (), outcome: outcome)
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int) async throws -> UIAutomationActionResult<Void>
    {
        let outcome = try self.uiAutomationOutcomeScript.nextOutcome(for: .hotkey)
        try await self.hotkey(keys: keys, holdDuration: holdDuration)
        return UIAutomationActionResult(payload: (), outcome: outcome)
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        targetProcessIdentifier: pid_t) async throws -> UIAutomationActionResult<Void>
    {
        guard let service = self as? any TargetedHotkeyServiceProtocol,
              service.supportsTargetedHotkeys
        else {
            throw PeekabooError.serviceUnavailable(
                self.targetedCapabilityReason(
                    (self as? any TargetedHotkeyServiceProtocol)?.targetedHotkeyUnavailableReason,
                    fallback: "This automation test double does not support process-targeted hotkeys"))
        }
        let outcome = try self.uiAutomationOutcomeScript.nextOutcome(for: .hotkey)
        try await service.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            targetProcessIdentifier: targetProcessIdentifier)
        return UIAutomationActionResult(payload: (), outcome: outcome)
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<Void>
    {
        guard let service = self as? any TargetedHotkeyServiceProtocol,
              service.supportsTargetedHotkeys,
              service.supportsProcessGenerationPinnedHotkeys
        else {
            throw PeekabooError.serviceUnavailable(
                self.targetedCapabilityReason(
                    (self as? any TargetedHotkeyServiceProtocol)?.targetedHotkeyUnavailableReason,
                    fallback: "This automation test double does not support process-generation-pinned hotkeys"))
        }
        let outcome = try self.uiAutomationOutcomeScript.nextOutcome(for: .hotkey)
        try await service.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            expectedProcessIdentity: expectedProcessIdentity)
        return UIAutomationActionResult(payload: (), outcome: outcome)
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<Void>
    {
        let service = try self.exactWindowKeyboardService(for: "hotkeys")
        let outcome = try self.uiAutomationOutcomeScript.nextOutcome(for: .hotkey)
        try await service.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds)
        return UIAutomationActionResult(payload: (), outcome: outcome)
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        target: ExactWindowKeyboardTarget) async throws -> UIAutomationActionResult<Void>
    {
        let service = try self.exactWindowKeyboardService(for: "hotkeys")
        let outcome = try self.uiAutomationOutcomeScript.nextOutcome(for: .hotkey)
        try await service.hotkey(keys: keys, holdDuration: holdDuration, target: target)
        return UIAutomationActionResult(payload: (), outcome: outcome)
    }

    public func setValueWithOutcome(
        target: String,
        value: UIElementValue,
        snapshotId: String?) async throws -> UIAutomationActionResult<ElementActionResult>
    {
        guard let service = self as? any ElementActionAutomationServiceProtocol else {
            throw PeekabooError.serviceUnavailable(
                "This automation test double does not support accessibility value mutation")
        }
        let outcome = try self.uiAutomationOutcomeScript.nextOutcome(for: .setValue)
        let payload = try await service.setValue(target: target, value: value, snapshotId: snapshotId)
        return UIAutomationActionResult(payload: payload, outcome: outcome)
    }

    public func performActionWithOutcome(
        target: String,
        actionName: String,
        snapshotId: String?) async throws -> UIAutomationActionResult<ElementActionResult>
    {
        guard let service = self as? any ElementActionAutomationServiceProtocol else {
            throw PeekabooError.serviceUnavailable(
                "This automation test double does not support accessibility actions")
        }
        let outcome = try self.uiAutomationOutcomeScript.nextOutcome(for: .performAction)
        let payload = try await service.performAction(
            target: target,
            actionName: actionName,
            snapshotId: snapshotId)
        return UIAutomationActionResult(payload: payload, outcome: outcome)
    }

    private func exactWindowKeyboardService(
        for operation: String) throws -> any ExactWindowTargetedKeyboardServiceProtocol
    {
        guard let service = self as? any ExactWindowTargetedKeyboardServiceProtocol,
              service.supportsExactWindowTargetedKeyboard
        else {
            throw PeekabooError.serviceUnavailable(
                self.targetedCapabilityReason(
                    (self as? any ExactWindowTargetedKeyboardServiceProtocol)?
                        .exactWindowTargetedKeyboardUnavailableReason,
                    fallback: "This automation test double does not support exact-window \(operation)"))
        }
        return service
    }

    private func targetedCapabilityReason(_ reason: String?, fallback: String) -> String {
        guard let reason, !reason.isEmpty else { return fallback }
        return reason
    }
}
